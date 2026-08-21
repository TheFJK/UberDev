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
# BEGIN review-fixer-child-bound-v3
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
  # DISPATCH ONLY, as of v3 (#556). The disposition and applied-content paths
  # were arguments 9 and 10 for exactly one reason -- to feed the
  # `capture-review-terminal` call that used to sit in the successful-wait arm
  # below -- and that call has moved to review_fixer_terminal_outcome, which the
  # fences invoke themselves. It moved because capture is only ONE of three
  # answers: a child that refused writes neither artifact, and capturing is not
  # what a controller owes that terminal. Two of the four fixer fences never
  # called this helper at all, so the branch could not live in here.
  #
  # REVIEW_FIXER_TERMINAL went with it. A carrier set here and read two fences
  # later is the #427 shape; the terminal document is now produced and consumed
  # in the same shell, and this helper's post-condition is just
  # REVIEW_FIXER_LAUNCH_BINDING plus a returned child.
  [ "$#" -eq 8 ] || return 2
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" prefix="${@:5:1}" timeout_s="${@:6:1}"
  local authority_path="${@:7:1}" authority_sha256="${@:8:1}"
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
    return 0
  fi
  wait_rc=$?
  uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
  return "$wait_rc"
}
# END review-fixer-child-bound-v3
# BEGIN review-fixer-terminal-outcome-v1
# review_fixer_terminal_outcome BINDING AUTHORITY_PATH AUTHORITY_SHA256
#                               DISPOSITION_PATH APPLIED_CONTENT_PATH
#                               HEAD_BEFORE HEAD_AFTER
#
# Turns a returned fixer child into the ONE authenticated outcome document
# review_promote_validated_fixer_outcome consumes. Prints that document on
# stdout and nothing else; every diagnostic goes to stderr.
#
# WHY THIS EXISTS (#556). A child that returns `status: REFUSED` writes NEITHER
# artifact the controller binds by path: it restores the worktree to HEAD and
# stops, so the applied-content document is never created and the disposition
# is left at the zero bytes lib/command-workspace.py pre-created. Every fixer
# fence went straight to `capture-review-terminal`, whose --applied-content-path
# is required and whose disposition capture has minimum=1 -- so the one terminal
# where the findings most need to survive could not be captured at all, and the
# BLOCKER rows the child refused were dropped instead of deferred.
#
# WHY IT IS ONE FUNCTION. The terminal chain was written out four times (Phase 1
# and Phase 2 x routed and Workflow-native). Teaching four copies to tell three
# states apart is the #370 "one contract, N uncompared copies" shape; the branch
# gets a single owner and the fences call it.
#
# EXISTENCE IS TESTED SEPARATELY FROM SIZE, in the same vocabulary the Phase 2.5
# defer fence uses (commands/review-pr.md, the DEFER_ guard). `-s` alone
# collapses three states into one, and they demand opposite handling:
#
#   absent     the controller allocates this file, so a path naming none is
#              workspace loss or tampering. Publishing a "nothing was applied"
#              record over it would fabricate evidence about a run whose
#              artifacts are gone -- refuse, and run no contract verb at all.
#   non-empty  the child published its own disposition. Capture and validate it,
#              byte-for-byte as before.
#   empty      the child refused (or needed no fixes) and could not publish.
#              The controller publishes the record on its behalf and validates
#              it in the same call.
#
# The caller keeps its own `review_guard_failed_fixer_return` arm: this helper
# returns each sub-call's own rc (74 from a contract refusal, 2 from an arity
# error) and never normalises a residue-bearing failure itself, so a mutation
# left behind by a failed fixer still lands as MUTATED_BLOCKED where it always did.
review_fixer_terminal_outcome() {
  [ "$#" -eq 7 ] || return 2
  local binding="${@:1:1}" authority_path="${@:2:1}" authority_sha256="${@:3:1}"
  local disposition_path="${@:4:1}" applied_content_path="${@:5:1}"
  local head_before="${@:6:1}" head_after="${@:7:1}"
  local terminal status_sha256 result_sha256 disposition_sha256 applied_content_sha256
  if [ ! -e "$disposition_path" ]; then
    echo "error: the fixer disposition record is LOST (path '$disposition_path' is empty or names no file); the controller creates this file, so absence is infrastructure failure, not a refusal" >&2
    return 74
  fi
  if [ -s "$disposition_path" ]; then
    terminal="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-review-terminal \
      --launch-binding-json "$binding" \
      --disposition-path "$disposition_path" \
      --applied-content-path "$applied_content_path")" || return $?
    status_sha256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$terminal")" || return $?
    result_sha256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$terminal")" || return $?
    disposition_sha256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$terminal")" || return $?
    applied_content_sha256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$terminal")" || return $?
    python3 -I -B "$CODE_FIXER_CONTRACT" validate-review-outcome \
      --launch-binding-json "$binding" \
      --authority-path "$authority_path" --authority-sha256 "$authority_sha256" \
      --disposition-path "$disposition_path" --disposition-sha256 "$disposition_sha256" \
      --applied-content-path "$applied_content_path" --applied-content-sha256 "$applied_content_sha256" \
      --status-sha256 "$status_sha256" --result-sha256 "$result_sha256" \
      --working-dir "$WORKTREE_ROOT" --head-before "$head_before" --head-after "$head_after"
    return $?
  fi
  python3 -I -B "$CODE_FIXER_CONTRACT" publish-unapplied-terminal \
    --launch-binding-json "$binding" \
    --authority-path "$authority_path" --authority-sha256 "$authority_sha256" \
    --disposition-path "$disposition_path" \
    --applied-content-path "$applied_content_path" \
    --working-dir "$WORKTREE_ROOT" \
    --head-before "$head_before" --head-after "$head_after"
}
# END review-fixer-terminal-outcome-v1
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

# BEGIN review-pr-head-identity-v1
# review_pr_head_identity REPO_SLUG PR_NUMBER
#
# Prints the PR's head identity on stdout, ONE FIELD PER LINE:
#
#     <headRefOid>
#     <headRefName>
#     <isCrossRepository>
#     <headRepositoryOwner.login>/<headRepository.name>
#
#   rc 0   gh answered and the projection is well-formed
#   rc 80  gh NEVER ANSWERED -- every attempt died at the transport
#          (`net/http: TLS handshake timeout`, an auth expiry, a rate limit).
#          The identity is UNKNOWN, and "unknown" is a claim about GitHub's
#          reachability, not about this repository. rc 79 is the second claim;
#          a caller that cannot tell them apart tells the operator the wrong
#          thing about which recovery to attempt (#482).
#   rc 79  gh ANSWERED, but with a projection this gate will not route: short,
#          over-long, an empty field, or a head that is not a 40-hex object.
#   rc 2   malformed argument; gh is never invoked
#
# WHY A RETRY (#482). One TLS handshake timeout on one of the several gh calls
# a publication makes used to end the run. The same flakiness hit three further
# gh calls in the session this was found in, so the blip is not rare enough to
# spend a whole review cycle on. `PR_IDENTITY_ATTEMPTS = 3` and
# `PR_IDENTITY_INTERVAL_SEC = 3` are declared HERE as numeric literals, exactly
# like the 6c.1 `CI_SETTLE_AGE_SEC` / `CI_SETTLE_REPROBES` constants -- bash does
# not dereference prose.
#
# WHY ONE HELPER. The pre-push and post-push probes each used to carry a byte
# identical copy of this projection, with a comment asking the next editor to
# keep the two in step by hand. One definition cannot drift from itself.
#
# The head-repository identity is `headRepositoryOwner.login` +
# `headRepository.name`, NEVER `headRepository.nameWithOwner` (#429). gh
# DECLARES that last field and never populates it -- gh 2.83.1:
#
#     gh pr view 422 --repo TheFJK/UberDev --json headRepository
#     {"headRepository":{"id":"R_kgDOSOF5tw","name":"UberDev","nameWithOwner":""}}
#
# A gate keyed on the empty string can never pass, which turned "refuse forks"
# into "refuse everything": every /review-pr run exited 2 at publication, so no
# PR could ever obtain a trust trail and /merge gated all of them out. The
# owner/name composite is populated for every PR, fork and same-repo alike.
# Same resolution as `lib/review-push-target.sh` -- keep the two in step.
review_pr_head_identity() {
  [ "$#" -eq 2 ] || return 2
  local repo_slug="${@:1:1}" pr_number="${@:2:1}"
  local attempt=0 identity head_oid head_branch cross_repository head_repo extra
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
  while :; do
    attempt=$((attempt + 1))
    identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
         --json headRefOid,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
         --jq '.headRefOid, .headRefName, (.isCrossRepository | tostring),
               ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
         2>/dev/null)" && break
    if [ "$attempt" -ge 3 ]; then
      echo "error: gh did not answer for $repo_slug#$pr_number in 3 attempts; the live PR head is UNKNOWN, which is not the same finding as a head that disagrees" >&2
      return 80
    fi
    sleep 3
  done
  # One field per LINE, not one tab-separated line. Tab is IFS whitespace, so
  # a tab-joined projection with an empty field COLLAPSES under `read`: the
  # fields shift left and a malformed identity parses as a well-formed
  # DIFFERENT one. Line-per-field cannot shift -- git refuses a ref name
  # containing a newline, so a stray newline can only make the projection
  # over-long, which the trailing read refuses.
  {
    IFS= read -r head_oid || return 79
    IFS= read -r head_branch || return 79
    IFS= read -r cross_repository || return 79
    IFS= read -r head_repo || return 79
    if IFS= read -r extra; then return 79; fi
  } <<<"$identity"
  [[ "$head_oid" =~ ^[0-9a-f]{40}$ ]] || return 79
  [ -n "$head_branch" ] && [ -n "$cross_repository" ] && [ -n "$head_repo" ] || return 79
  printf '%s\n%s\n%s\n%s\n' "$head_oid" "$head_branch" "$cross_repository" "$head_repo"
}
# END review-pr-head-identity-v1
# BEGIN review-publish-settle-v1
# review_settle_live_pr_head REPO_SLUG PR_NUMBER PUBLISHED_SHA PRE_PUSH_SHA
#
# Re-projects the live PR head until GitHub reports PUBLISHED_SHA, then prints
# the settled identity -- the same four lines `review_pr_head_identity` prints.
#
#   rc 0   the live PR head is PUBLISHED_SHA
#   rc 79  a REAL refusal, one of two shapes:
#          - the live head is a THIRD object, neither the sha just pushed nor
#            the sha that was there before it. Some other writer owns the
#            branch; no amount of waiting makes that agree, so it is refused on
#            the FIRST answer rather than after the window.
#          - the settle budget expired with GitHub still serving the pre-push
#            head.
#   rc 80  gh never answered (propagated verbatim from review_pr_head_identity)
#   rc 2   malformed argument
#
# WHY (#482). `git push` exiting 0 and `ls-remote` agreeing prove the object is
# ON the remote ref. GitHub's API view of that same ref is a SEPARATE, eventually
# consistent projection: for the first seconds after a push, `gh pr view --json
# headRefOid` still serves the pre-push oid. Reading it once, immediately after
# the push, is a race -- and on TheFJK/WAGYAI PR #657 the gate lost it and
# refused a publication that had in fact landed, telling the operator publication
# had failed about a branch the remote had already moved. That is the reading
# that invites a reset or a force-push. Same class as the 6c.1 PROBE arm's
# `CI_SETTLE_AGE_SEC` / `CI_SETTLE_REPROBES` window, same remedy.
# `PUBLISH_SETTLE_ATTEMPTS = 5`, `PUBLISH_SETTLE_INTERVAL_SEC = 4`.
#
# The loop re-probes the API and NEVER re-pushes: a second push would spawn a
# duplicate CI check set while `test.yml` has no concurrency group (#302/#309).
review_settle_live_pr_head() {
  [ "$#" -eq 4 ] || return 2
  local repo_slug="${@:1:1}" pr_number="${@:2:1}" published_sha="${@:3:1}" pre_push_sha="${@:4:1}"
  local attempt=0 identity live_head
  [[ "$published_sha" =~ ^[0-9a-f]{40}$ && "$pre_push_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  while :; do
    attempt=$((attempt + 1))
    identity="$(review_pr_head_identity "$repo_slug" "$pr_number")" || return $?
    live_head="${identity%%$'\n'*}"
    if [ "$live_head" = "$published_sha" ]; then
      printf '%s\n' "$identity"
      return 0
    fi
    if [ "$live_head" != "$pre_push_sha" ]; then
      echo "error: $repo_slug#$pr_number reports head $live_head -- neither the published $published_sha nor the pre-push $pre_push_sha. A concurrent writer owns the branch, so this is a disagreement and not a propagation delay; waiting cannot resolve it" >&2
      return 79
    fi
    if [ "$attempt" -ge 5 ]; then
      echo "error: $repo_slug#$pr_number still reports the pre-push head $pre_push_sha after 5 probes across the settle window" >&2
      return 79
    fi
    sleep 4
  done
}
# END review-publish-settle-v1
review_publish_same_repo_pr_head() {
  [ "$#" -eq 7 ] || return 2
  local repo_slug="${@:1:1}" pr_number="${@:2:1}" expected_remote_head_sha="${@:3:1}" publish_sha="${@:4:1}"
  local worktree_root="${@:5:1}" contract_helper="${@:6:1}" evidence_dir="${@:7:1}"
  local live_identity live_head live_branch live_cross_repository live_head_repo settle_rc
  local remote_identity remote_head remote_ref remote_extra observed_head residue_receipt
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$expected_remote_head_sha" =~ ^[0-9a-f]{40}$ && "$publish_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  [[ "$worktree_root" = /* && "$contract_helper" = /* && "$evidence_dir" = /* ]] || return 2
  # Pre-push probe. rc is propagated rather than flattened to 79: `$?` here is
  # 80 when gh never answered, and the caller's operator-facing message depends
  # on being able to tell that from a head that disagrees (#482).
  live_identity="$(review_pr_head_identity "$repo_slug" "$pr_number")" || return $?
  # FOUR reads, not five. The helper prints exactly four lines and refuses a
  # projection of any other arity itself, so the over-length read that used to
  # sit here has moved rather than gone: it now guards both probes from one
  # place instead of being re-stated at each.
  {
    IFS= read -r live_head || return 79
    IFS= read -r live_branch || return 79
    IFS= read -r live_cross_repository || return 79
    IFS= read -r live_head_repo || return 79
  } <<<"$live_identity"
  [ "$live_head" = "$expected_remote_head_sha" ] || return 79
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
  # Post-push re-projection, THROUGH THE SETTLE WINDOW (#482). This is the proof
  # that the ref we just wrote is still the PR's head in the repository we think
  # it is -- but GitHub's view of the ref lags the ref itself by seconds, so a
  # single immediate read races a projection that is merely late. The settle
  # helper waits out exactly that lag and nothing else: a third object is still
  # refused on the first answer.
  live_identity="$(review_settle_live_pr_head "$repo_slug" "$pr_number" "$publish_sha" "$expected_remote_head_sha")" || {
    settle_rc=$?
    # The operator must not be told the push failed when it did not. `git push`
    # returned 0 and the ls-remote above proved the object is on the ref; what
    # failed is the API-side proof. Without this line the reported failure reads
    # as "publication failed", and the recoveries that invites -- reset, force
    # push -- are the two that would actually lose the work.
    echo "note: the push itself landed -- origin refs/heads/$live_branch carries $publish_sha, proved by ls-remote above. What failed is the post-push proof of GitHub's own view of that ref. Re-run /review-pr: publication is idempotent and republishes the same object. Do NOT reset or force-push this branch." >&2
    return "$settle_rc"
  }
  {
    IFS= read -r live_head || return 79
    IFS= read -r live_branch || return 79
    IFS= read -r live_cross_repository || return 79
    IFS= read -r live_head_repo || return 79
  } <<<"$live_identity"
  # Restated, not redundant: the settle helper guarantees this equality, and the
  # gate asserting its own conjunct keeps the proof readable in one place even
  # if the helper is ever re-pointed.
  [ "$live_head" = "$publish_sha" ] || return 79
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
# review_build_postfix_scope PHASE RANGE -- the post-fix reviewer's OWN scope.
#
# Writes exactly one artifact: $RESEARCH_DIR_ABS/postfix-diff-<phase>-iter<N>.md,
# holding `git diff <before>..<after>` inside the untrusted-input envelope the
# child reads it through. On success it sets two globals for the calling fence,
# the same shape review_refresh_phase1_scope uses for CHANGED_PATHS_JSON,
# because a fence cannot read both a value and an exit status off stdout:
#
#   REVIEW_POSTFIX_DIFF_PATH        what it wrote
#   REVIEW_POSTFIX_DIFF_SUMMARISED  `true` | `false`
#
# WHY THIS IS A SECOND SCOPE BUILDER AND NOT A CALL INTO THE FIRST.
# review_refresh_phase1_scope replace_private()s BOTH $DIFF_ARTIFACT_PATH and
# $COMMIT_RANGE_PATH in place, and those are the exact bytes the NEXT fixer's
# prepare-authority receipt digest-pins: `commit_range_sha256` is a declared
# input on review_pr.fix.phase1 and on review_pr.fix.phase2 alike. Re-running it
# between Phase 1 and Phase 2 merely to obtain a diff would break the Phase 2
# authority receipt, and it raises SystemExit(2) on an empty path set besides.
# So this function names NEITHER of those two paths as a write target. That is
# an invariant rather than a preference, and it is test-locked as one.
#
# The summarisation flag is REPORTED, not swallowed. A GREEN run whose post-fix
# pass read a 40-line summary instead of the diff has to be able to say so; a
# fallback that hides the degradation is a swallowed error.
#
# rc 2 = the caller named something this fence will not act on: a phase outside
# {phase1, phase2}, or an iteration it cannot key the artifact on.
# rc 74 = the artifact did not reach disk. A range that does not parse lands
# here rather than on rc 2 ON PURPOSE: by the time this fence runs, the range
# has already been read back through review_fleet_read_fixer_range's own 40-hex
# gate, so an unparseable one means that reader was bypassed -- a wiring bug
# that must halt, not an argument the caller can be asked to correct.
#
# THE HEREDOC BELOW SITS INSIDE A `$( )` CAPTURE, so every `'` and every
# backtick in it must BALANCE -- an apostrophe in a python comment is enough to
# break it. Every helper in this file is loaded by CARVING its bytes out and
# eval()ing them (lib/review-fleet-args.sh review_fleet_load_fence_library,
# which carves rather than sources because typeset -f re-emits heredocs
# unparseably on disjoint bash versions, #471), and bash 3.2 -- stock
# /bin/bash on macOS, where these fences actually run -- rescans a
# command-substitution body for quotes and backticks WITHOUT honouring the
# quoted heredoc delimiter inside it. An odd one parses as an unterminated
# quote, the eval fails, and the helper is left silently UNDEFINED until a
# fence calls it many relays downstream. bash 5 and zsh accept the same bytes
# and report nothing, so `bash -n` on PATH cannot see this: check with
# `/bin/bash -n lib/review-fences.sh`. review_write_postfix_aggregate below
# dodges the whole class by leaving its python as the function's LAST command
# instead of capturing it; do that here too if this ever needs a lone quote.
review_build_postfix_scope() {
  [ "$#" -eq 2 ] || return 2
  local postfix_phase="${@:1:1}" postfix_range="${@:2:1}" postfix_target postfix_summarised
  case "$postfix_phase" in phase1 | phase2) : ;; *) return 2 ;; esac
  # AC #7 again: no `:-1` default. An iteration this fence cannot name is a
  # refusal, because a defaulted one silently rebinds pass 2 onto pass 1's
  # artifact and every downstream equality still passes.
  case "${REVIEW_ITERATION:-}" in '' | *[!0-9]*) return 2 ;; esac
  [ -n "${RESEARCH_DIR_ABS:-}" ] && [ -n "${WORKTREE_ROOT:-}" ] || return 2
  postfix_target="$RESEARCH_DIR_ABS/postfix-diff-${postfix_phase}-iter${REVIEW_ITERATION}.md"
  postfix_summarised="$(python3 -I -B - "$WORKTREE_ROOT" "$postfix_range" "$postfix_target" <<'PY'
import os,re,subprocess,sys,tempfile
root,commit_range,target=sys.argv[1:]
MAX_DIFF_LINES=2000
MAX_DIFF_BYTES=8*1024*1024
MAX_WRAPPED_DIFF_BYTES=16*1024*1024
matched=re.fullmatch(r'([0-9a-f]{40})\.\.([0-9a-f]{40})',commit_range)
if matched is None: raise SystemExit(2)
before,after=matched.group(1),matched.group(2)
if before==after: raise SystemExit(2)
if not os.path.isabs(target): raise SystemExit(2)
# The carrier writer already proved this ancestry with both heads in hand.
# Re-asserting it here is not distrust of that proof: this argument reached the
# fence as a scalar, and a range whose halves are unrelated would otherwise be
# diffed as a two-sided comparison and reviewed as if it were one commit.
# (No apostrophe on "carrier" -- see the bash 3.2 note above this function.)
subprocess.run(['git','-C',root,'merge-base','--is-ancestor',before,after],check=True)
def escape_untrusted_diff_payload(payload):
    return payload.replace(b'&',b'&amp;').replace(b'<',b'&lt;')
def wrap_untrusted_diff(payload):
    escaped=escape_untrusted_diff_payload(payload)
    opening=b'<external-untrusted-input source="postfix-diff">'
    closing=b'</external-untrusted-input>'
    wrapped=opening+b'\n'+escaped+closing+b'\n'
    if wrapped.count(opening)!=1 or wrapped.count(closing)!=1: raise ValueError()
    return wrapped
def build_diff_summary():
    summary=['[diff summarized: full binary diff exceeded the 2000-line, 8-MiB raw, or 16-MiB wrapped review artifact limit]']
    summary_bytes=len((summary[0]+'\n').encode())
    summary_wrapped_bytes=len(wrap_untrusted_diff((summary[0]+'\n').encode()))
    omission_reserve=128
    stats=subprocess.Popen(['git','-C',root,'diff','--numstat','--no-renames',f'{before}..{after}'],
                           stdout=subprocess.PIPE,text=True,encoding='utf-8',errors='strict')
    omitted=0
    for line in stats.stdout:
        fields=line.rstrip('\n').split('\t',2)
        if len(fields)!=3: raise SystemExit(2)
        added,deleted,changed=fields
        detail='binary change' if added==deleted=='-' else f'{added} additions, {deleted} deletions'
        row=f'{changed} — {detail}'
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
def select_bounded_wrapped_diff(payload,summary_factory):
    # Returns (wrapped_bytes, used_summary), and the second element is NOT
    # optional for the caller. This is the one path that substitutes a summary
    # without the read loop above ever setting its own flag: a raw diff under
    # both the 2000-line and the 8-MiB cap whose ESCAPED, enveloped form still
    # overflows the 16-MiB wrapped cap. Inferring the flag from the read loop
    # alone published false there, so a GREEN run asserted the post-fix reviewer
    # had read the fixer diff when what reached it was a per-file summary --
    # exactly the degradation the header above says must be reported, not
    # swallowed. The wrapper reports which payload it returned; nobody guesses.
    wrapped=wrap_untrusted_diff(payload)
    if len(wrapped)<=MAX_WRAPPED_DIFF_BYTES: return wrapped,False
    wrapped=wrap_untrusted_diff(summary_factory())
    if len(wrapped)>MAX_WRAPPED_DIFF_BYTES: raise ValueError()
    return wrapped,True
process=subprocess.Popen(['git','-C',root,'diff','--binary','--no-ext-diff',f'{before}..{after}'],stdout=subprocess.PIPE)
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
wrapped_diff,wrapped_from_summary=select_bounded_wrapped_diff(diff,(lambda: diff) if summarized else build_diff_summary)
# The flag follows the payload that was actually WRITTEN, never the read loop
# alone. Where summarized was already true the factory hands back that same
# summary, so this can only confirm it; where it was false this is the
# wrapped-cap fallback the loop has no way to observe.
if wrapped_from_summary: summarized=True
def replace_private(destination,payload):
    parent=os.path.dirname(destination) or '.'
    fd,tmp=tempfile.mkstemp(prefix='.review-postfix-scope.',dir=parent)
    try:
        if os.name!='nt': os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp,destination)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
# The raw diff buffers are dead once the envelope above is built, and dropping
# them here rather than at exit stops them overlapping the read-back below.
del diff_buffer,diff
replace_private(target,wrapped_diff)
# VERIFIED WITHOUT MATERIALISING THE ARTIFACT A SECOND TIME. Near the 8-MiB raw
# and 16-MiB wrapped ceilings a whole-file read-back doubled peak memory to
# answer a yes-or-no question. Block by block gives the identical verdict -- a
# short file, a differing file and an over-long file all still raise
# SystemExit(2) -- at constant extra cost. The trailing one-byte read is what
# preserves the over-length half of that verdict, which the old read of one
# byte past the payload provided.
VERIFY_BLOCK=65536
with open(target,'rb') as stream:
    verified=0
    while verified<len(wrapped_diff):
        block=stream.read(VERIFY_BLOCK)
        if not block: raise SystemExit(2)
        if block!=wrapped_diff[verified:verified+len(block)]: raise SystemExit(2)
        verified+=len(block)
    if stream.read(1): raise SystemExit(2)
print('true' if summarized else 'false',end='')
PY
)" || return 74
  case "$postfix_summarised" in true | false) : ;; *) return 74 ;; esac
  REVIEW_POSTFIX_DIFF_PATH="$postfix_target"
  REVIEW_POSTFIX_DIFF_SUMMARISED="$postfix_summarised"
}
# review_write_postfix_aggregate PHASE ITER RESULT_PATH
#
# Transcribes one VALIDATED post-fix child result into the command-owned
# `postfix-aggregate` envelope at $RESEARCH_DIR_ABS/postfix-<phase>-iter<N>.md,
# and prints the counts the calling fence needs for its sidecar:
#
#   {"by_severity":{"blocker":B,"suggestion":S},"findings_count":N}
#
# so the fence never has to re-parse the document it just wrote.
#
# SEVERITY IS TRANSCRIBED, NEVER RE-SEVERITISED. shared/phase1-reviewer-output-v1.md
# fixes the child's vocabulary at `blocker | suggestion` and admits nothing
# else, so mapping a `suggestion` up to `major` would be this fence inventing a
# judgement the reviewer did not make. A row carrying any other severity is a
# malformed child return -- rc 2, which the caller records as `status: blocked`
# -- and it is never coerced into one of the two.
#
# TWO DISTINCT FAILURE RCs, because the caller must tell them apart:
#   rc 2  the child result is absent, unreadable or malformed. Advisory: the
#         caller publishes a `blocked` sidecar and the run continues.
#   rc 74 the aggregate did not reach disk. A finding that reached no sink is a
#         swallowed error, so this one halts.
#
# The write mirrors the ci-refused-synthetic writer byte for byte in discipline:
# exclusive create under `umask 077`, an lstat gate that refuses a symlink, a
# hard link, a foreign owner, a non-empty file or a mode other than 0600, an
# O_NOFOLLOW open, a device+inode identity re-check between the open descriptor
# and the path, a full-length os.write, an fsync, and a re-read proving the
# first 128 bytes carry the envelope marker findings-to-issues looks for.
#
# The rendered JSON escapes the envelope's own close marker as
# `\u003c/external-untrusted-input>` -- lib/report_primitives.py canonical_json
# does the same, for the same reason: `summary` and `detail` are reviewer prose,
# and prose that could close the envelope early could smuggle a second
# structural trailer past the consumer. Decoding the JSON restores the text.
#
# THE PYTHON BELOW IS A PLAIN COMMAND, NOT A `$( )` CAPTURE, and that is a
# correctness requirement rather than a style choice. Every helper in this file
# is loaded by CARVING its bytes out and eval()ing them
# (lib/review-fleet-args.sh review_fleet_load_fence_library, which carves rather
# than sources because typeset -f re-emits heredocs unparseably on disjoint bash
# versions, #471). bash 3.2 -- stock /bin/bash on macOS, which is where these
# fences actually run -- RESCANS a command-substitution body for backticks and
# single quotes WITHOUT honouring the quoted heredoc delimiter inside it. This
# grammar carries seven backticks and an odd number of bare `'` characters (the
# YAML doubled-apostrophe rule), so wrapped in `$( )` it parses as an
# unterminated quote: the eval fails, and the helper is left silently UNDEFINED
# until a fence calls it many relays downstream. bash 5 and zsh accept the same
# bytes and `bash -n` reports nothing on either, which is why this is written
# down rather than noticed. Leaving the python as the function's LAST command
# makes its stdout the function's stdout and its rc the function's rc, and the
# rescan never happens. Verify with `/bin/bash -n`, never with `bash -n`.
review_write_postfix_aggregate() {
  [ "$#" -eq 3 ] || return 2
  local postfix_phase="${@:1:1}" postfix_iter="${@:2:1}" postfix_result="${@:3:1}"
  local postfix_target
  case "$postfix_phase" in phase1 | phase2) : ;; *) return 2 ;; esac
  case "$postfix_iter" in '' | *[!0-9]*) return 2 ;; esac
  [ -n "${RESEARCH_DIR_ABS:-}" ] || return 2
  [ -r "$postfix_result" ] || return 2
  postfix_target="$RESEARCH_DIR_ABS/postfix-${postfix_phase}-iter${postfix_iter}.md"
  ( umask 077; set -C; : >"$postfix_target" ) || return 74
  python3 -I -B - "$postfix_target" "$postfix_result" <<'PY'
import json,os,re,stat,sys
target,result=sys.argv[1:]
MAX_FIELD=8192
MAX_RESULT_BYTES=1048576
EDGE='review_pr.postfix.correctness'
CLOSE='</external-untrusted-input>'
OPEN='<external-untrusted-input source="postfix-aggregate">'
# The child's own YAML grammar, transcribed from the canonical boundary in
# lib/child-dispatch.sh (uberdev_child_validate_phase1_review_result). The
# caller has already run that boundary and hands us the VALIDATED copy it
# published; re-parsing here is what turns those bytes into rows, and parsing
# them under any looser grammar than the one that admitted them would let a
# shape the validator refused reach the aggregate.
def scalar(raw):
 if not raw or raw.strip()!=raw or any(ord(char)<32 or ord(char)==127 for char in raw): raise ValueError()
 def checked(value):
  if (not isinstance(value,str) or not value or value.strip()!=value
      or any(ord(char)<32 or ord(char)==127 for char in value)): raise ValueError()
  return value
 if raw.startswith('"'): return checked(json.loads(raw))
 if raw.startswith("'"):
  if len(raw)<2 or not raw.endswith("'"): raise ValueError()
  inner=raw[1:-1]; value=''; index=0
  while index<len(inner):
   if inner[index]=="'":
    if index+1>=len(inner) or inner[index+1]!="'": raise ValueError()
    value+="'"; index+=2
   else:
    value+=inner[index]; index+=1
  return checked(value)
 if raw[0] in '-?:,[]{}#&*!|>@`' or ': ' in raw or ' #' in raw: raise ValueError()
 if re.fullmatch(r'(?i:null|true|false|~|[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]+)?(?:e[-+]?[0-9]+)?|[-+]?\.(?:inf|nan))',raw): raise ValueError()
 return checked(raw)
def parse_reviewer(content):
 match=re.fullmatch(r'\s*```yaml[ \t]*\r?\n(.*?)\r?\n```[ \t]*\s*',content,re.S)
 if match is None: raise ValueError()
 verdict=None; confidence=None; findings_mode=None; findings=[]; current=None
 for line in match.group(1).splitlines():
  if not line.strip(): continue
  top=re.fullmatch(r'(verdict|confidence):[ \t]*(\S(?:.*\S)?)',line)
  if top:
   key,value=top.groups(); value=scalar(value)
   if key=='verdict':
    if verdict is not None or value not in {'APPROVE','REVISIONS_REQUIRED','REJECT'}: raise ValueError()
    verdict=value
   else:
    if confidence is not None or value not in {'low','medium','high'}: raise ValueError()
    confidence=value
   continue
  found=re.fullmatch(r'findings:[ \t]*(\[\])?',line)
  if found:
   if findings_mode is not None: raise ValueError()
   findings_mode='empty' if found.group(1) else 'rows'
   continue
  severity=re.fullmatch(r'  - severity:[ \t]*(blocker|suggestion)',line)
  if severity and findings_mode=='rows':
   if current is not None: findings.append(current)
   current={'severity':severity.group(1)}
   continue
  field=re.fullmatch(r'    (location|summary|detail):[ \t]*(\S(?:.*\S)?)',line)
  if field and findings_mode=='rows' and current is not None:
   key,value=field.groups(); value=scalar(value)
   if key in current: raise ValueError()
   current[key]=value
   continue
  raise ValueError()
 if current is not None: findings.append(current)
 if verdict is None or confidence is None or findings_mode is None: raise ValueError()
 if findings_mode=='empty' and findings: raise ValueError()
 if findings_mode=='rows' and not findings: raise ValueError()
 for finding in findings:
  if set(finding)!={'severity','location','summary','detail'}: raise ValueError()
  if re.fullmatch(r'.+:[1-9][0-9]*',finding['location']) is None: raise ValueError()
 blockers=[finding for finding in findings if finding['severity']=='blocker']
 if (verdict=='APPROVE')==bool(blockers): raise ValueError()
 return findings
try:
 entry=os.lstat(result)
 if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode)
         or entry.st_size>MAX_RESULT_BYTES): raise ValueError()
 with open(result,'rb') as stream:
  raw_result=stream.read(MAX_RESULT_BYTES+1)
 if len(raw_result)>MAX_RESULT_BYTES: raise ValueError()
 rows=[]
 counts={'blocker':0,'suggestion':0}
 for finding in parse_reviewer(raw_result.decode('utf-8')):
  severity=finding['severity']
  if severity not in counts: raise ValueError()
  location=finding['location']; summary=finding['summary']; rationale=finding['detail']
  if any(len(value)>MAX_FIELD for value in (location,summary,rationale)): raise ValueError()
  counts[severity]+=1
  rows.append({'agent_name':'code-reviewer','disposition':'DEFERRED','location':location,
               'rationale':rationale,'severity':severity,'source_edges':[EDGE],
               'summary':summary,'tier':'BLOCKER' if severity=='blocker' else None})
except (OSError,UnicodeError,ValueError):
 # LEAVE NO HALF-MADE ARTIFACT. The caller created the target empty and
 # exclusively before invoking us, so a rc-2 return would otherwise strand a
 # zero-byte postfix-<phase>-iter<N>.md on disk -- a document with no envelope
 # marker, which findings-to-issues refuses, and which a Step 7 renderer would
 # read as "the pass ran and found nothing" rather than "the pass is blocked".
 # Only the exact empty regular file we were handed is removed; a symlink, a
 # hard-linked path or anything with bytes in it is left strictly alone.
 try:
  leftover=os.lstat(target)
  if stat.S_ISREG(leftover.st_mode) and leftover.st_size==0 and leftover.st_nlink==1:
   os.unlink(target)
 except OSError: pass
 raise SystemExit(2)
body=''.join(
    '- '+json.dumps(row,sort_keys=True,separators=(',',':'),ensure_ascii=True).replace(CLOSE,'\\u003c/external-untrusted-input>')+'\n'
    for row in rows)
payload=(OPEN+'\n'+body+CLOSE+'\n').encode('utf-8')
try:
 entry=os.lstat(target); uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
 if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode) or entry.st_nlink!=1
         or (uid is not None and entry.st_uid!=uid) or entry.st_size!=0
         or (os.name!='nt' and stat.S_IMODE(entry.st_mode)!=0o600)):
  raise OSError()
 descriptor=os.open(target,os.O_WRONLY|getattr(os,'O_NOFOLLOW',0))
 try:
  opened=os.fstat(descriptor); current=os.lstat(target)
  if (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino): raise OSError()
  if os.write(descriptor,payload)!=len(payload): raise OSError()
  os.fsync(descriptor)
 finally:
  os.close(descriptor)
 with open(target,'rb') as stream:
  if not stream.read(128).startswith(OPEN.encode('utf-8')): raise OSError()
except OSError:
 raise SystemExit(74)
print(json.dumps({'by_severity':counts,'findings_count':len(rows)},sort_keys=True,separators=(',',':')),end='')
PY
}
review_track_validated_fixer_head() {
  local child_status="${@:1:1}" before="${@:2:1}" after="${@:3:1}" declared_tip="${@:4:1}" phase="${@:5:1}" commit_count residue_receipt
  # `-eq 5`, NOT `-ge 5`, and the tightening from `-ge 3` is load-bearing rather
  # than tidying (#655). This function WRITES the post-fix commit-range carrier
  # below, and carrier ABSENCE is the whole zero-dispatch short-circuit: no
  # file means no applied commit. Under `-ge` a four-argument call from a site
  # someone forgot to update would pass silently with `phase` bound to the
  # empty string and write `fixer-range--iter1.txt` -- a name the post-fix
  # fences never look for -- so the short-circuit would report "nothing was
  # applied" about a run that applied a commit. A hard equality converts that
  # silent no-op into a loud `return 2` at the un-updated call site.
  # review_promote_validated_fixer_outcome is this function's only production
  # caller and always supplies five; `declared_tip` is the empty string on the
  # unapplied arms, which the `[ -z "$declared_tip" ]` check below expects.
  [ "$#" -eq 5 ] || return 2
  case "$phase" in phase1 | phase2) : ;; *) return 2 ;; esac
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
      # The post-fix pass's commit range, written at the ONE point where BOTH
      # heads have already been proven -- `before != after`, `declared_tip ==
      # after`, `merge-base --is-ancestor`, and `rev-list --count == 1`, all
      # four above. FIXER_HEAD_BEFORE has no other on-disk carrier on the routed
      # transport, and every fence is a fresh shell (#427/#418), so a later
      # fence that needed the range would have to RE-DERIVE it and would
      # re-derive it without those proofs. Fresh-shell handoffs are found, never
      # recomputed.
      #
      # It is written on the APPLIED arm ONLY. The NO_FIXES_NEEDED / REFUSED arm
      # writes nothing, so a no-op fixer leaves no carrier and the post-fix
      # fences dispatch nothing -- absence IS the short-circuit, structural
      # rather than a branch someone can forget to write. That reading is only
      # sound because this writer FAILS CLOSED (`|| return 74`): "no file" can
      # then mean "no applied commit" and nothing else.
      #
      # AC #7: the name is keyed on REVIEW_ITERATION, and an iteration this
      # fence cannot name is a REFUSAL, never a `:-1` default. Defaulting is the
      # stale-counter class RFC 0001 records -- a Phase 3 re-entry would rebind
      # pass 2 onto pass 1's artifact name and freeze the previous iteration's
      # evidence with every equality still passing.
      case "${REVIEW_ITERATION:-}" in
        '' | *[!0-9]*)
          echo "error: MUTATED_BLOCKED — no REVIEW_ITERATION reached this fence; review_fleet_load_ci_counters must run before a fixer outcome is promoted" >&2
          return 74
          ;;
      esac
      review_fleet_write_fixer_range \
        "$RESEARCH_DIR_ABS/fixer-range-${phase}-iter${REVIEW_ITERATION}.txt" \
        "$before" "$after" || return 74
      ;;
    NO_FIXES_NEEDED|REFUSED)
      [ -z "$declared_tip" ] && [ "$before" = "$after" ] || return 75
      ;;
    *) return 2 ;;
  esac
}
review_promote_validated_fixer_outcome() {
  # FOUR positionals since #655: the trailing `phase` names WHICH fixer this
  # outcome belongs to, and it is forwarded to review_track_validated_fixer_head
  # so the commit-range carrier it writes carries the phase in its name. The
  # four call sites are Phase 1 routed, Phase 1 Workflow (5w.2), Phase 2 routed
  # and Phase 2 Workflow (6bw); a hook wired at only two of them silently
  # no-ops under UBERDEV_CARRIER_BACKEND=workflow, and the hard arity equality
  # here is what converts that silent no-op into a loud refusal.
  [ "$#" -eq 4 ] || return 2
  local outcome="${@:1:1}" before="${@:2:1}" after="${@:3:1}" phase="${@:4:1}" parsed child_status declared_tip extra
  case "$phase" in phase1 | phase2) : ;; *) return 2 ;; esac
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
  review_track_validated_fixer_head "$child_status" "$before" "$after" "$declared_tip" "$phase"
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
