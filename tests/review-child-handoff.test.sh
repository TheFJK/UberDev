#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
REVIEW="$ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY="$ROOT/plugins/uberdev/commands/simplify.md"
POST="$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

. "$LIB"

# Native Windows Git and Git Bash can spell the same directory differently.
# The Windows-path fixture must compare shell-canonical paths rather than inode
# identity through two incompatible path syntaxes.
if grep -q -- '-''ef' "$0"; then
  echo 'review-child-handoff: native Windows path fixture uses a non-portable file-identity assertion' >&2
  exit 1
fi

if [ "${1:-}" = --windows-path-only ]; then
  windows_shell_directory() { (cd "$1" && pwd -P); }
  windows_create_verified_junction() {
    local root="$1" target="$2" junction="$3" driver="${4:-native}"
    python3 -I -B - "$root" "$target" "$junction" "$driver" <<'PY'
import os,stat,subprocess,sys
root,target,junction,driver=sys.argv[1:]

def fail(reason):
    print(f"review-child-handoff: junction {reason}",file=sys.stderr)
    raise SystemExit(1)

def run_junction_command(command):
    if driver=="launch-oserror":
        raise OSError("injected launch failure")
    if driver=="nonzero-exit":
        return subprocess.CompletedProcess(command,1)
    if driver!="native":
        fail("invalid test driver")
    return subprocess.run(
        command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,
    )

try:
    os.makedirs(root,exist_ok=True)
except (OSError,ValueError):
    fail("fixture setup failed")
if os.name=="nt" or driver!="native":
    command=["cmd.exe","/d","/s","/c",f'mklink /J "{junction}" "{target}"']
    try:
        completed=run_junction_command(command)
    except (OSError,ValueError,subprocess.SubprocessError):
        fail("command launch failed")
    if completed.returncode != 0:
        fail("command failed")
else:
    try:
        os.symlink(target,junction,target_is_directory=True)
    except (NotImplementedError,OSError,ValueError):
        fail("creation failed")
try:
    entry=os.lstat(junction)
    reparse=getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0x400)
    is_reparse=stat.S_ISLNK(entry.st_mode) or bool(
        getattr(entry,"st_file_attributes",0)&reparse
    )
    reaches_target=(
        os.path.normcase(os.path.realpath(junction))
        == os.path.normcase(os.path.realpath(target))
    )
except (OSError,ValueError):
    fail("verification failed")
if not is_reparse or not reaches_target:
    fail("verification failed")
PY
  }
  for WINDOWS_JUNCTION_FAILURE_CASE in \
    'launch-oserror:command launch failed' 'nonzero-exit:command failed'; do
    WINDOWS_JUNCTION_DRIVER="${WINDOWS_JUNCTION_FAILURE_CASE%%:*}"
    WINDOWS_JUNCTION_REASON="${WINDOWS_JUNCTION_FAILURE_CASE#*:}"
    WINDOWS_JUNCTION_TEST_ROOT="$TMP/junction-$WINDOWS_JUNCTION_DRIVER"
    WINDOWS_JUNCTION_TEST_TARGET="$TMP/junction-$WINDOWS_JUNCTION_DRIVER-target"
    WINDOWS_JUNCTION_TEST_PATH="$WINDOWS_JUNCTION_TEST_ROOT/state"
    WINDOWS_JUNCTION_TEST_STDOUT="$TMP/junction-$WINDOWS_JUNCTION_DRIVER.stdout"
    WINDOWS_JUNCTION_TEST_STDERR="$TMP/junction-$WINDOWS_JUNCTION_DRIVER.stderr"
    set +e
    windows_create_verified_junction \
      "$WINDOWS_JUNCTION_TEST_ROOT" "$WINDOWS_JUNCTION_TEST_TARGET" \
      "$WINDOWS_JUNCTION_TEST_PATH" "$WINDOWS_JUNCTION_DRIVER" \
      >"$WINDOWS_JUNCTION_TEST_STDOUT" 2>"$WINDOWS_JUNCTION_TEST_STDERR"
    WINDOWS_JUNCTION_TEST_RC=$?
    set -e
    if [ "$WINDOWS_JUNCTION_TEST_RC" -ne 1 ] \
      || [ -s "$WINDOWS_JUNCTION_TEST_STDOUT" ] \
      || [ "$(<"$WINDOWS_JUNCTION_TEST_STDERR")" != \
        "review-child-handoff: junction $WINDOWS_JUNCTION_REASON" ] \
      || [ "$(wc -c <"$WINDOWS_JUNCTION_TEST_STDERR" | tr -d ' ')" -gt 96 ]; then
      echo "review-child-handoff: junction $WINDOWS_JUNCTION_DRIVER was not rejected with a bounded path-free diagnostic" >&2
      exit 1
    fi
  done
  WINDOWS_REPO="$TMP/windows-repo"; mkdir -p "$WINDOWS_REPO"
  git -C "$WINDOWS_REPO" init -q
  git -C "$WINDOWS_REPO" config user.email fixture@example.invalid
  git -C "$WINDOWS_REPO" config user.name Fixture
  printf 'fixture\n' >"$WINDOWS_REPO/README.md"
  git -C "$WINDOWS_REPO" add README.md
  git -C "$WINDOWS_REPO" commit -qm fixture
  WINDOWS_REPO_ID="$(git -C "$WINDOWS_REPO" rev-parse --show-toplevel)"
  WINDOWS_SHELL_ID="$(windows_shell_directory "$WINDOWS_REPO")"
  [ "$(windows_shell_directory "$WINDOWS_REPO_ID")" = "$WINDOWS_SHELL_ID" ]
  python3 -I -B - "$ROOT/plugins/uberdev/lib/command-workspace.py" "$WINDOWS_REPO_ID" <<'PY'
import importlib.util,os,sys
helper,repo=sys.argv[1:]
if os.name!="nt":
    raise SystemExit(0)
spec=importlib.util.spec_from_file_location("windows_binding_probe",helper)
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
root_binding=module.portable_bind_existing_directory(repo,"repository_changed")
child_binding=None
probe=os.path.join(repo,".command-workspace-binding-probe")
try:
    child_binding,created=module.portable_bind_or_create_child(
        root_binding,repo,".command-workspace-binding-probe"
    )
    assert created
    try:
        os.replace(probe,probe+"-replacement")
    except OSError:
        pass
    else:
        raise AssertionError("bound directory was replaceable")
    assert module.windows_binding_matches_path(
        probe,child_binding,"unsafe_directory"
    )
    module.windows_mark_directory_for_deletion(
        child_binding,"unsafe_directory"
    )
finally:
    if child_binding is not None:
        module.close_directory_binding(child_binding)
    module.close_directory_binding(root_binding)
assert not os.path.lexists(probe)
assert not os.path.lexists(probe+"-replacement")

concurrent_probe=os.path.join(repo,".command-workspace-concurrency-probe")
first_root=module.portable_bind_existing_directory(repo,"repository_changed")
second_root=module.portable_bind_existing_directory(repo,"repository_changed")
first_child=None
second_child=None
real_sleep=module.time.sleep
sleep_calls=[]
try:
    first_child,first_created=module.portable_bind_or_create_child(
        first_root,repo,".command-workspace-concurrency-probe"
    )
    assert first_created
    expected_identity=first_child.handle_identity
    def release_creator(delay):
        sleep_calls.append(delay)
        module.close_directory_binding(first_child)
    module.time.sleep=release_creator
    second_child,second_created=module.portable_bind_or_create_child(
        second_root,repo,".command-workspace-concurrency-probe"
    )
    assert not second_created
    assert sleep_calls
    assert expected_identity==second_child.handle_identity
    for operation in (
        lambda: os.replace(concurrent_probe,concurrent_probe+"-replacement"),
        lambda: os.rmdir(concurrent_probe),
    ):
        try:
            operation()
        except OSError:
            pass
        else:
            raise AssertionError("fallback guard did not block rename/delete")
finally:
    module.time.sleep=real_sleep
    if second_child is not None:
        module.close_directory_binding(second_child)
    if first_child is not None:
        module.close_directory_binding(first_child)
    module.close_directory_binding(second_root)
    module.close_directory_binding(first_root)
os.rmdir(concurrent_probe)
assert not os.path.lexists(concurrent_probe+"-replacement")

existing_probe=os.path.join(repo,".command-workspace-existing-probe")
os.mkdir(existing_probe)
existing_root=module.portable_bind_existing_directory(repo,"repository_changed")
existing_child=None
try:
    existing_child,existing_created=module.portable_bind_or_create_child(
        existing_root,repo,".command-workspace-existing-probe"
    )
    assert not existing_created
    for operation in (
        lambda: os.replace(existing_probe,existing_probe+"-replacement"),
        lambda: os.rmdir(existing_probe),
    ):
        try:
            operation()
        except OSError:
            pass
        else:
            raise AssertionError("fallback-only binding was replaceable")
finally:
    if existing_child is not None:
        module.close_directory_binding(existing_child)
    module.close_directory_binding(existing_root)
os.rmdir(existing_probe)
assert not os.path.lexists(existing_probe+"-replacement")

mismatch_probe=os.path.join(repo,".command-workspace-mismatch-probe")
mismatch_original=mismatch_probe+"-original"
mismatch_creator_root=module.portable_bind_existing_directory(
    repo,"repository_changed"
)
mismatch_waiter_root=module.portable_bind_existing_directory(
    repo,"repository_changed"
)
mismatch_creator=None
real_sleep=module.time.sleep
try:
    mismatch_creator,mismatch_created=module.portable_bind_or_create_child(
        mismatch_creator_root,repo,".command-workspace-mismatch-probe"
    )
    assert mismatch_created
    def replace_during_handoff(_delay):
        module.close_directory_binding(mismatch_creator)
        os.replace(mismatch_probe,mismatch_original)
        os.mkdir(mismatch_probe)
        with open(os.path.join(mismatch_probe,"attacker-marker"),"wb") as stream:
            stream.write(b"replacement-must-survive")
    module.time.sleep=replace_during_handoff
    try:
        module.portable_bind_or_create_child(
            mismatch_waiter_root,repo,".command-workspace-mismatch-probe"
        )
    except module.Failure as error:
        assert str(error)=="unsafe_directory"
    else:
        raise AssertionError("tracker-to-guard identity mismatch was accepted")
finally:
    module.time.sleep=real_sleep
    if mismatch_creator is not None:
        module.close_directory_binding(mismatch_creator)
    module.close_directory_binding(mismatch_waiter_root)
    module.close_directory_binding(mismatch_creator_root)
with open(os.path.join(mismatch_probe,"attacker-marker"),"rb") as stream:
    assert stream.read()==b"replacement-must-survive"
os.unlink(os.path.join(mismatch_probe,"attacker-marker"))
os.rmdir(mismatch_probe)
os.rmdir(mismatch_original)

timeout_probe=os.path.join(repo,".command-workspace-timeout-probe")
timeout_creator_root=module.portable_bind_existing_directory(
    repo,"repository_changed"
)
timeout_waiter_root=module.portable_bind_existing_directory(
    repo,"repository_changed"
)
timeout_creator=None
real_monotonic=module.time.monotonic
try:
    timeout_creator,timeout_created=module.portable_bind_or_create_child(
        timeout_creator_root,repo,".command-workspace-timeout-probe"
    )
    assert timeout_created
    ticks=iter((0.0,module.WINDOWS_DIRECTORY_BIND_TIMEOUT_SECONDS))
    module.time.monotonic=lambda: next(ticks)
    try:
        module.portable_bind_or_create_child(
            timeout_waiter_root,repo,".command-workspace-timeout-probe"
        )
    except module.Failure as error:
        assert str(error)=="unsafe_directory"
    else:
        raise AssertionError("sharing timeout was accepted")
    assert os.path.isdir(timeout_probe)
    module.windows_mark_directory_for_deletion(
        timeout_creator,"unsafe_directory"
    )
finally:
    module.time.monotonic=real_monotonic
    if timeout_creator is not None:
        module.close_directory_binding(timeout_creator)
    module.close_directory_binding(timeout_waiter_root)
    module.close_directory_binding(timeout_creator_root)
assert not os.path.lexists(timeout_probe)
PY
  WINDOWS_REQUESTED_ROOT="$(python3 -I -B - "$WINDOWS_REPO_ID" <<'PY'
import os,sys
path=sys.argv[1]
if os.name=="nt":
    characters=list(path)
    for index,character in enumerate(characters):
        if character.isalpha():
            characters[index]=character.swapcase()
    variant="".join(characters)
    assert variant!=path
    assert os.path.normcase(os.path.abspath(variant))==os.path.normcase(os.path.abspath(path))
    assert os.path.samefile(variant,path)
    print(variant,end="")
else:
    print(path,end="")
PY
)"

  WINDOWS_RUN="$WINDOWS_REPO_ID/.uberdev/runs/windows-review-carrier"; mkdir -p "$WINDOWS_RUN"
  WINDOWS_REQUEST="$(jq -cn --arg run "$WINDOWS_RUN" --arg repo "$WINDOWS_REPO_ID" \
    '{schema_version:1,run_dir:$run,run_id:"windows-review-carrier",repository_id:$repo,backend:"codex",workflow:"review-pr",phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:91,issue_num:91,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
  WINDOWS_DECISION="$(uberdev_agent_resolve_request "$WINDOWS_REQUEST")"
  WINDOWS_METADATA="$(jq -cn --arg repo "$WINDOWS_REPO_ID" \
    '{run_id:"windows-review-carrier",repository_id:$repo,workflow:"review-pr",backend:"codex",issue_num:91,task_tier:"medium",risk_signals:[]}')"
  WINDOWS_CONTEXT_OUT="$(uberdev_agent_context_create "$WINDOWS_RUN" "$WINDOWS_REQUEST" "$WINDOWS_DECISION" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$WINDOWS_METADATA" '2026-07-26T00:00:00Z')"
  WINDOWS_CONTEXT="$(jq -r .context_file <<<"$WINDOWS_CONTEXT_OUT")"
  WINDOWS_CONTEXT_SHA="$(jq -r .context_sha256 <<<"$WINDOWS_CONTEXT_OUT")"

  windows_context_validation_must_reject() {
    local label="$1" candidate="$2" expected="$3" run_root="$4"
    local stdout_file="$TMP/windows-context-$label.stdout"
    local stderr_file="$TMP/windows-context-$label.stderr"
    local rc
    set +e
    uberdev_agent_context_validate "$candidate" "$expected" "$run_root" \
      >"$stdout_file" 2>"$stderr_file"
    rc=$?
    set -e
    if [ "$rc" -ne 2 ] || [ -s "$stdout_file" ] \
      || ! grep -qx 'uberdev agent dispatch: route_context_validation_failed' "$stderr_file"; then
      echo "review-child-handoff: route context $label was not rejected fail-closed (rc=$rc)" >&2
      exit 1
    fi
  }

  # This is the production validator, not a copied/extracted Python branch.
  # On windows-latest the paths below are native drive paths returned across
  # the Git Bash -> native Python boundary.
  WINDOWS_CONTEXT_VALIDATION_STDERR="$TMP/windows-context-valid.stderr"
  if ! WINDOWS_CONTEXT_VALIDATION="$(
    uberdev_agent_context_validate "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN" \
      2>"$WINDOWS_CONTEXT_VALIDATION_STDERR"
  )"; then
    echo 'review-child-handoff: valid native route context was rejected' >&2
    exit 1
  fi
  [ ! -s "$WINDOWS_CONTEXT_VALIDATION_STDERR" ]
  jq -e --arg context "$WINDOWS_CONTEXT" --arg sha "$WINDOWS_CONTEXT_SHA" \
    '.context_file==$context and .context_sha256==$sha and
     .run_id=="windows-review-carrier" and .workflow=="review-pr"' \
    <<<"$WINDOWS_CONTEXT_VALIDATION" >/dev/null
  WINDOWS_NATIVE_PATHS="$(python3 -I -B - "$WINDOWS_CONTEXT" "$WINDOWS_RUN" <<'PY'
import os,sys
for path in sys.argv[1:]:
    assert os.path.isabs(path), path
    if os.name == "nt":
        drive, _ = os.path.splitdrive(os.path.abspath(path))
        assert drive, path
print("1" if os.name == "nt" else "0", end="")
PY
)"
  WINDOWS_REPARSE_REJECTIONS=0

  # A same-file content mutation must be diagnosed only by the stable,
  # non-secret validation error. Restore the exact bytes before later link
  # identity probes.
  WINDOWS_CONTEXT_BACKUP="$TMP/windows-route-context-original.json"
  python3 -I -B - "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_BACKUP" <<'PY'
import json,pathlib,sys
context,backup=map(pathlib.Path,sys.argv[1:])
raw=context.read_bytes()
assert raw
backup.write_bytes(raw)
tampered=json.loads(raw)
tampered["metadata"]["run_id"] += "-tampered"
context.write_text(
    json.dumps(tampered,sort_keys=True,separators=(",",":")),
    encoding="utf-8",
)
PY
  windows_context_validation_must_reject \
    digest-tamper "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN"
  python3 -I -B - "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_BACKUP" <<'PY'
import pathlib,sys
path,backup=map(pathlib.Path,sys.argv[1:])
path.write_bytes(backup.read_bytes())
PY

  WINDOWS_CONTEXT_STATE="$(python3 -I -B -c \
    'import os,sys; print(os.path.dirname(sys.argv[1]),end="")' "$WINDOWS_CONTEXT")"
  WINDOWS_CONTEXT_NAME="$(python3 -I -B -c \
    'import os,sys; print(os.path.basename(sys.argv[1]),end="")' "$WINDOWS_CONTEXT")"

  # Hard-link creation is filesystem-dependent, but a link that is actually
  # created may never be skipped: prove the native link count changed, then
  # require the production validator to reject the candidate.
  WINDOWS_CONTEXT_HARDLINK="$(python3 -I -B -c \
    'import os,sys; print(os.path.join(sys.argv[1],"route-context-v1-hardlink.json"),end="")' \
    "$WINDOWS_CONTEXT_STATE")"
  set +e
  python3 -I -B - "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_HARDLINK" <<'PY'
import errno,os,sys
source,candidate=sys.argv[1:]
unsupported_errno={
    value for value in (
        getattr(errno,"EACCES",None),getattr(errno,"EPERM",None),
        getattr(errno,"ENOSYS",None),getattr(errno,"ENOTSUP",None),
        getattr(errno,"EOPNOTSUPP",None),getattr(errno,"EXDEV",None),
    ) if value is not None
}
try:
    os.link(source,candidate)
except OSError as error:
    if error.errno in unsupported_errno or getattr(error,"winerror",None) in {1,5,50,1314}:
        raise SystemExit(77)
    raise
assert os.path.samefile(source,candidate)
assert os.stat(source).st_nlink >= 2
PY
  WINDOWS_HARDLINK_RC=$?
  set -e
  case "$WINDOWS_HARDLINK_RC" in
    0)
      windows_context_validation_must_reject \
        hardlink "$WINDOWS_CONTEXT_HARDLINK" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN"
      python3 -I -B -c 'import os,sys; os.unlink(sys.argv[1])' "$WINDOWS_CONTEXT_HARDLINK"
      ;;
    77)
      echo 'review-child-handoff windows path: hardlink capability unavailable (SKIP)' >&2
      ;;
    *)
      echo "review-child-handoff: hardlink fixture failed (rc=$WINDOWS_HARDLINK_RC)" >&2
      exit 1
      ;;
  esac

  # Prefer a native file symlink/reparse point. If Windows policy forbids
  # symlink creation, try an unprivileged directory junction and validate a
  # context path through that reparse ancestor instead.
  WINDOWS_CONTEXT_SYMLINK="$(python3 -I -B -c \
    'import os,sys; print(os.path.join(sys.argv[1],"route-context-v1-symlink.json"),end="")' \
    "$WINDOWS_CONTEXT_STATE")"
  set +e
  python3 -I -B - "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_SYMLINK" <<'PY'
import errno,os,stat,sys
source,candidate=sys.argv[1:]
unsupported_errno={
    value for value in (
        getattr(errno,"EACCES",None),getattr(errno,"EPERM",None),
        getattr(errno,"ENOSYS",None),getattr(errno,"ENOTSUP",None),
        getattr(errno,"EOPNOTSUPP",None),
    ) if value is not None
}
try:
    os.symlink(source,candidate,target_is_directory=False)
except (NotImplementedError,OSError) as error:
    if isinstance(error,NotImplementedError) or error.errno in unsupported_errno \
       or getattr(error,"winerror",None) in {1,5,50,1314}:
        raise SystemExit(77)
    raise
entry=os.lstat(candidate)
reparse=getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0x400)
assert stat.S_ISLNK(entry.st_mode) or bool(getattr(entry,"st_file_attributes",0)&reparse)
PY
  WINDOWS_SYMLINK_RC=$?
  set -e
  case "$WINDOWS_SYMLINK_RC" in
    0)
      windows_context_validation_must_reject \
        symlink-reparse "$WINDOWS_CONTEXT_SYMLINK" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN"
      WINDOWS_REPARSE_REJECTIONS=$((WINDOWS_REPARSE_REJECTIONS + 1))
      python3 -I -B -c 'import os,sys; os.unlink(sys.argv[1])' "$WINDOWS_CONTEXT_SYMLINK"
      ;;
    77)
      WINDOWS_JUNCTION_RUN="$(python3 -I -B -c \
        'import os,sys; print(os.path.join(sys.argv[1],"windows-context-junction"),end="")' \
        "$WINDOWS_RUN")"
      WINDOWS_JUNCTION_STATE="$(python3 -I -B -c \
        'import os,sys; print(os.path.join(sys.argv[1],sys.argv[2]),end="")' \
        "$WINDOWS_JUNCTION_RUN" "$(python3 -I -B -c \
          'import os,sys; print(os.path.basename(sys.argv[1]),end="")' "$WINDOWS_CONTEXT_STATE")")"
      WINDOWS_JUNCTION_CONTEXT="$(python3 -I -B -c \
        'import os,sys; print(os.path.join(sys.argv[1],sys.argv[2]),end="")' \
        "$WINDOWS_JUNCTION_STATE" "$WINDOWS_CONTEXT_NAME")"
      set +e
      windows_create_verified_junction \
        "$WINDOWS_JUNCTION_RUN" "$WINDOWS_CONTEXT_STATE" "$WINDOWS_JUNCTION_STATE"
      WINDOWS_JUNCTION_RC=$?
      set -e
      case "$WINDOWS_JUNCTION_RC" in
        0)
          windows_context_validation_must_reject \
            junction-reparse "$WINDOWS_JUNCTION_CONTEXT" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_JUNCTION_RUN"
          WINDOWS_REPARSE_REJECTIONS=$((WINDOWS_REPARSE_REJECTIONS + 1))
          python3 -I -B - "$WINDOWS_JUNCTION_RUN" "$WINDOWS_JUNCTION_STATE" <<'PY'
import os,sys
root,junction=sys.argv[1:]
if os.name=="nt":
    os.rmdir(junction)
else:
    os.unlink(junction)
os.rmdir(root)
PY
          ;;
        *)
          echo "review-child-handoff: junction fixture failed (rc=$WINDOWS_JUNCTION_RC)" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "review-child-handoff: symlink fixture failed (rc=$WINDOWS_SYMLINK_RC)" >&2
      exit 1
      ;;
  esac
  if [ "$WINDOWS_NATIVE_PATHS" = 1 ] && [ "$WINDOWS_REPARSE_REJECTIONS" -lt 1 ]; then
    echo 'review-child-handoff: no native symlink or junction rejection assertion executed' >&2
    exit 1
  fi

  # Reject an existing context-shaped file reached through an escaped path.
  # On native Windows also reject a noncanonical spelling of the valid file
  # itself, which specifically exercises the drive-path lexical equality gate.
  WINDOWS_ESCAPED_CONTEXT="$(python3 -I -B - "$WINDOWS_CONTEXT_STATE" "$WINDOWS_RUN" <<'PY'
import os,pathlib,sys
state,root=sys.argv[1:]
outside=os.path.join(root,"route-context-v1-escaped.json")
pathlib.Path(outside).write_bytes(b'{"escaped":true}')
candidate=os.path.join(state,"..",os.path.basename(outside))
assert os.path.normcase(os.path.abspath(candidate))==os.path.normcase(os.path.abspath(outside))
assert os.path.normcase(candidate)!=os.path.normcase(os.path.abspath(candidate))
print(candidate,end="")
PY
)"
  WINDOWS_ESCAPED_SHA="$(python3 -I -B -c \
    'import hashlib,os,sys; print(hashlib.sha256(open(os.path.abspath(sys.argv[1]),"rb").read()).hexdigest(),end="")' \
    "$WINDOWS_ESCAPED_CONTEXT")"
  windows_context_validation_must_reject \
    escaped-path "$WINDOWS_ESCAPED_CONTEXT" "$WINDOWS_ESCAPED_SHA" "$WINDOWS_RUN"
  python3 -I -B -c \
    'import os,sys; os.unlink(os.path.abspath(sys.argv[1]))' "$WINDOWS_ESCAPED_CONTEXT"
  if [ "$WINDOWS_NATIVE_PATHS" = 1 ]; then
    WINDOWS_NONCANONICAL_CONTEXT="$(python3 -I -B - "$WINDOWS_CONTEXT" <<'PY'
import os,sys
path=sys.argv[1]
state=os.path.dirname(path)
candidate=os.path.join(state,"..",os.path.basename(state),os.path.basename(path))
assert os.path.normcase(os.path.abspath(candidate))==os.path.normcase(os.path.abspath(path))
assert os.path.normcase(candidate)!=os.path.normcase(os.path.abspath(candidate))
print(candidate,end="")
PY
)"
    windows_context_validation_must_reject \
      noncanonical-drive-path "$WINDOWS_NONCANONICAL_CONTEXT" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN"
  fi

  # The context remains usable after every rejected candidate.
  uberdev_agent_context_validate \
    "$WINDOWS_CONTEXT" "$WINDOWS_CONTEXT_SHA" "$WINDOWS_RUN" >/dev/null
  UBERDEV_RUN_CARRIER_JSON="$(jq -cn --arg context "$WINDOWS_CONTEXT" --arg sha "$WINDOWS_CONTEXT_SHA" \
    '{schema_version:1,run_id:"windows-review-carrier",workflow:"review-pr",issue_num:91,context_file:$context,context_sha256:$sha}')"
  export UBERDEV_RUN_CARRIER_JSON
  WINDOWS_WORKSPACE_JUNCTION_TARGET="$TMP/windows-workspace-junction-target"
  WINDOWS_WORKSPACE_JUNCTION="$WINDOWS_REPO_ID/.uberdev/research"
  mkdir -p "$WINDOWS_WORKSPACE_JUNCTION_TARGET"
  windows_create_verified_junction \
    "$WINDOWS_REPO_ID/.uberdev" "$WINDOWS_WORKSPACE_JUNCTION_TARGET" \
    "$WINDOWS_WORKSPACE_JUNCTION"
  if uberdev_command_workspace_prepare \
      review-pr 91 medium '[]' 20260726-010203-abcdeef "$WINDOWS_REPO_ID" \
      >/dev/null 2>&1; then
    echo 'review-child-handoff: workspace research junction was accepted' >&2
    exit 1
  fi
  python3 -I -B - "$WINDOWS_WORKSPACE_JUNCTION" "$WINDOWS_WORKSPACE_JUNCTION_TARGET" <<'PY'
import os,sys
junction,target=sys.argv[1:]
if os.name=="nt":
    os.rmdir(junction)
else:
    os.unlink(junction)
os.rmdir(target)
PY
  WINDOWS_WORKSPACE="$(uberdev_command_workspace_prepare review-pr 91 medium '[]' 20260726-010203-abcdef0 "$WINDOWS_REQUESTED_ROOT")"
  jq -e '.caller=="review-pr"' <<<"$WINDOWS_WORKSPACE" >/dev/null
  WINDOWS_WORKSPACE_ROOT="$(jq -r .repository_root <<<"$WINDOWS_WORKSPACE")"
  [ "$(windows_shell_directory "$WINDOWS_WORKSPACE_ROOT")" = "$WINDOWS_SHELL_ID" ]
  python3 -I -B - "$WINDOWS_WORKSPACE" <<'PY'
import json,os,stat,sys
descriptor=json.loads(sys.argv[1])
workspace=descriptor["research_dir"]
expected={
    "diff":b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n',
    "criteria":b"",
    "commit_range":b"",
    "phase1_disposition":b"{}\n",
    "phase2_disposition":b"{}\n",
}
assert set(descriptor["artifacts"])==set(expected)
reparse=getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0x400)
for key,path in descriptor["artifacts"].items():
    assert os.path.normcase(os.path.commonpath((workspace,path)))==os.path.normcase(workspace)
    entry=os.lstat(path)
    assert stat.S_ISREG(entry.st_mode) and entry.st_nlink==1
    assert not stat.S_ISLNK(entry.st_mode)
    assert not bool(getattr(entry,"st_file_attributes",0)&reparse)
    with open(path,"rb") as stream:
        assert stream.read()==expected[key]
PY

  WINDOWS_REVIEW_INPUT="$(jq -cn --arg p "$WINDOWS_REPO_ID/README.md" \
    '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
  uberdev_create_child_handoff review_pr.review.correctness windows-reviewer-iter1-attempt01 "$WINDOWS_REVIEW_INPUT" '[]' >/dev/null
  WINDOWS_REVIEW_HANDOFF="$UBERDEV_CHILD_HANDOFF"; WINDOWS_REVIEW_RESULT="$UBERDEV_CHILD_RESULT"; WINDOWS_REVIEW_STATUS="$UBERDEV_CHILD_STATUS"
  _uberdev_child_backend_cancellation_supported() { return 0; }
  uberdev_preflight_child_batch "$WINDOWS_REVIEW_HANDOFF"
  _uberdev_child_prepare review_pr.review.correctness "$WINDOWS_REVIEW_HANDOFF" "$WINDOWS_REVIEW_RESULT" "$WINDOWS_REVIEW_STATUS" dispatch >/dev/null
  printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' 'confidence: high' '```' >"$WINDOWS_REVIEW_RESULT"
  WINDOWS_VALIDATED="$(dirname "$WINDOWS_REVIEW_RESULT")/validated-result.md"
  WINDOWS_DIGEST="$(uberdev_child_validate_phase1_review_result "$WINDOWS_REVIEW_RESULT" '["README.md"]' "$WINDOWS_VALIDATED")"
  [[ "$WINDOWS_DIGEST" =~ ^[0-9a-f]{64}$ ]]
  cmp "$WINDOWS_REVIEW_RESULT" "$WINDOWS_VALIDATED"

  WINDOWS_FIX_INPUT="$(jq -cn --arg p "$WINDOWS_REPO_ID/README.md" --arg d "$WINDOWS_REPO_ID" \
    '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:91,disposition_path:$p}')"
  uberdev_create_child_handoff review_pr.fix.phase1 windows-fixer-iter1-attempt01 "$WINDOWS_FIX_INPUT" null >/dev/null
  WINDOWS_FIX_HANDOFF="$UBERDEV_CHILD_HANDOFF"; WINDOWS_FIX_RESULT="$UBERDEV_CHILD_RESULT"; WINDOWS_FIX_STATUS="$UBERDEV_CHILD_STATUS"
  uberdev_preflight_child_batch "$WINDOWS_FIX_HANDOFF"
  WINDOWS_FIX_PREPARED="$(_uberdev_child_prepare review_pr.fix.phase1 "$WINDOWS_FIX_HANDOFF" "$WINDOWS_FIX_RESULT" "$WINDOWS_FIX_STATUS" dispatch)"
  jq -e '.request.workspace_mode=="caller"' <<<"$WINDOWS_FIX_PREPARED" >/dev/null
  WINDOWS_FIX_ROOT="$(jq -r .request.workspace_dir <<<"$WINDOWS_FIX_PREPARED")"
  [ "$(windows_shell_directory "$WINDOWS_FIX_ROOT")" = "$WINDOWS_SHELL_ID" ]

  serialized_context="$(_uberdev_agent_json_get "$UBERDEV_RUN_CARRIER_JSON" context_file)"
  [ "$serialized_context" = "$WINDOWS_CONTEXT" ]
  ! _uberdev_child_context_run_dir 'C:\repo\.uberdev\runs\review-1\state\..\context.json' >/dev/null 2>&1
  echo 'review-child-handoff windows path: PASS'
  exit 0
fi

mkdir -p "$TMP/run"
TEST_REPO="$TMP/repo"; mkdir -p "$TEST_REPO"; TEST_REPO="$(cd "$TEST_REPO" && pwd -P)"
git -C "$TEST_REPO" init -q
printf 'fixture\n' >"$TEST_REPO/README.md"

# Phase 1 verdicts and blocker severity form a closed invariant: APPROVE has
# no blockers, while either red verdict must carry at least one blocker.
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'confidence: high' 'findings: []' '```' \
  >"$TMP/revisions-empty.md"
printf '%s\n' '```yaml' 'verdict: REJECT' 'confidence: high' 'findings:' \
  '  - severity: suggestion' '    location: README.md:1' \
  '    summary: advisory only' '    detail: no blocking evidence' '```' \
  >"$TMP/reject-suggestion-only.md"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'confidence: high' 'findings:' \
  '  - severity: blocker' '    location: README.md:1' \
  '    summary: blocking evidence' '    detail: requires a correction' '```' \
  >"$TMP/revisions-blocker.md"
! uberdev_child_validate_phase1_review_result "$TMP/revisions-empty.md"
! uberdev_child_validate_phase1_review_result "$TMP/reject-suggestion-only.md"
uberdev_child_validate_phase1_review_result "$TMP/revisions-blocker.md"
request="$(jq -cn --arg run "$TMP/run" --arg repo "$TEST_REPO" '{schema_version:1,run_dir:$run,run_id:"review-contract",repository_id:$repo,backend:"codex",workflow:"review-pr",phase:"review",role:"lead",task_tier:"medium",risk_signals:["security"],issue_or_pr:1,issue_num:1,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
decision="$(uberdev_agent_resolve_request "$request")"
metadata="$(jq -cn --arg repo "$TEST_REPO" '{run_id:"review-contract",repository_id:$repo,workflow:"review-pr",backend:"codex",issue_num:1,task_tier:"medium",risk_signals:["security"]}')"
context_out="$(uberdev_agent_context_create "$TMP/run" "$request" "$decision" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$metadata" '2026-07-10T00:00:00Z')"
ctx="$(jq -r .context_file <<<"$context_out")"; sha="$(jq -r .context_sha256 <<<"$context_out")"
UBERDEV_RUN_CARRIER_JSON="$(jq -cn --arg ctx "$ctx" --arg sha "$sha" '{schema_version:1,run_id:"review-contract",workflow:"review-pr",issue_num:1,context_file:$ctx,context_sha256:$sha}')"
export UBERDEV_RUN_CARRIER_JSON
REVIEW_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON"

mkdir -p "$TMP/simplify-run"
simplify_request="$(jq -cn --arg run "$TMP/simplify-run" --arg repo "$TEST_REPO" '{schema_version:1,run_dir:$run,run_id:"simplify-contract",repository_id:$repo,backend:"codex",workflow:"simplify",phase:"simplify",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:0,issue_num:0,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
simplify_decision="$(uberdev_agent_resolve_request "$simplify_request")"
simplify_metadata="$(jq -cn --arg repo "$TEST_REPO" '{run_id:"simplify-contract",repository_id:$repo,workflow:"simplify",backend:"codex",issue_num:0,task_tier:"medium",risk_signals:[]}')"
simplify_context_out="$(uberdev_agent_context_create "$TMP/simplify-run" "$simplify_request" "$simplify_decision" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$simplify_metadata" '2026-07-10T00:00:00Z')"
simplify_ctx="$(jq -r .context_file <<<"$simplify_context_out")"; simplify_sha="$(jq -r .context_sha256 <<<"$simplify_context_out")"
SIMPLIFY_CARRIER_JSON="$(jq -cn --arg ctx "$simplify_ctx" --arg sha "$simplify_sha" '{schema_version:1,run_id:"simplify-contract",workflow:"simplify",issue_num:0,context_file:$ctx,context_sha256:$sha}')"

# The accepted input boundary comes from the shared manifest, and the complete
# immutable handoff remains below the 65,536-byte reader ceiling at that
# maximum.
printf 'diff\n' >"$TEST_REPO/max-input.diff"
MAX_INPUTS="$(python3 -I -B - "$TEST_REPO/max-input.diff" "$TREE" <<'PY'
import json,sys
limit=json.load(open(sys.argv[2]))['input_limits']['max_serialized_bytes']
paths=[f"src/p{index:02d}-"+("x"*2990)+".ts" for index in range(16)]
base={"changed_paths":paths,"diff_path":sys.argv[1],"criteria_path":sys.argv[1],"emphasis":[]}
current=len(json.dumps(base,sort_keys=True,separators=(",",":")).encode())
base["changed_paths"][-1]=base["changed_paths"][-1][:-3]+("x"*(limit-current))+".ts"
payload=json.dumps(base,sort_keys=True,separators=(",",":"))
assert len(payload.encode())==limit
assert max(map(len,base["changed_paths"]))<=4096
print(payload,end="")
PY
)"
uberdev_create_child_handoff review_pr.review.correctness review-max-input-iter1-attempt01 "$MAX_INPUTS" '[]' >/dev/null
[ "$(wc -c <"$UBERDEV_CHILD_HANDOFF" | tr -d ' ')" -lt 65536 ]
_uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null

# Derive a limit-plus-one input from that same manifest boundary and prove the
# constructor rejects it before publishing a child directory.
MAX_PLUS_ONE_INPUTS="$(python3 -I -B - "$MAX_INPUTS" "$TREE" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
limit=json.load(open(sys.argv[2]))['input_limits']['max_serialized_bytes']
value["changed_paths"][-1]=value["changed_paths"][-1][:-3]+"x.ts"
payload=json.dumps(value,sort_keys=True,separators=(",",":"))
assert len(payload.encode())==limit+1
print(payload,end="")
PY
)"
! uberdev_create_child_handoff review_pr.review.correctness review-constructor-plus-one-iter1-attempt01 "$MAX_PLUS_ONE_INPUTS" '[]' >/dev/null 2>&1
[ ! -e "$TMP/run/children/review-constructor-plus-one-iter1-attempt01" ]

# Independently tamper a valid maximum-sized handoff after construction to prove
# the dispatcher enforces the shared limit instead of trusting the constructor.
uberdev_create_child_handoff review_pr.review.correctness review-max-input-plus-one-iter1-attempt01 "$MAX_INPUTS" '[]' >/dev/null
MAX_PLUS_ONE_HANDOFF="$UBERDEV_CHILD_HANDOFF"
python3 -I -B - "$MAX_PLUS_ONE_HANDOFF" "$TREE" <<'PY'
import json,sys
path,manifest_path=sys.argv[1:]
limit=json.load(open(manifest_path))['input_limits']['max_serialized_bytes']
with open(path,encoding='utf-8') as stream:
    value=json.load(stream)
value['inputs']['changed_paths'][-1]=value['inputs']['changed_paths'][-1][:-3]+'x.ts'
serialized=json.dumps(value['inputs'],sort_keys=True,separators=(',',':')).encode()
assert len(serialized)==limit+1
with open(path,'w',encoding='utf-8') as stream:
    json.dump(value,stream,separators=(',',':'))
PY
! _uberdev_child_prepare review_pr.review.correctness "$MAX_PLUS_ONE_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
[ ! -e "$TMP/run/children/review-max-input-plus-one-iter1-attempt01" ]

# Native Windows Python has neither getuid/geteuid nor descriptor-relative
# filesystem operations. Exercise the real carrier -> handoff -> prepare path
# through that capability profile, including replacement/tamper rejection.
(
  REAL_PORTABLE_PYTHON="$(command -v python3)"
  python3() {
    if [ "${1:-}" = -I ] && [ "${2:-}" = -B ] && [ "${3:-}" = - ]; then
      shift 3
      command "$REAL_PORTABLE_PYTHON" -I -B -c '
import builtins,errno,os,runpy,stat,sys,tempfile
source=sys.stdin.read()
if hasattr(os,"geteuid"): del os.geteuid
if hasattr(os,"getuid"): del os.getuid
if hasattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT"): del stat.FILE_ATTRIBUTE_REPARSE_POINT
os.supports_dir_fd=set()
real_open=os.open
real_read=os.read
real_lstat=os.lstat
real_fsync=os.fsync
real_unlink=os.unlink
swap_path=os.environ.get("UBERDEV_TEST_PORTABLE_SWAP_PATH")
swap_with=os.environ.get("UBERDEV_TEST_PORTABLE_SWAP_WITH")
swap_after_read_path=os.environ.get("UBERDEV_TEST_PORTABLE_SWAP_AFTER_READ_PATH")
swap_after_read_with=os.environ.get("UBERDEV_TEST_PORTABLE_SWAP_AFTER_READ_WITH")
replace_created_name=os.environ.get("UBERDEV_TEST_PORTABLE_REPLACE_CREATED_NAME")
reparse_path=os.environ.get("UBERDEV_TEST_PORTABLE_REPARSE_PATH")
manifest_swap_path=os.environ.get("UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_PATH")
manifest_swap_with=os.environ.get("UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_WITH")
parent_swap_path=os.environ.get("UBERDEV_TEST_PORTABLE_PARENT_SWAP_PATH")
parent_swap_with=os.environ.get("UBERDEV_TEST_PORTABLE_PARENT_SWAP_WITH")
parent_swap_original=os.environ.get("UBERDEV_TEST_PORTABLE_PARENT_SWAP_ORIGINAL")
parent_swap_on_name=os.environ.get("UBERDEV_TEST_PORTABLE_PARENT_SWAP_ON_NAME")
after_open_parent_swap_path=os.environ.get("UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_PATH")
after_open_parent_swap_with=os.environ.get("UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_WITH")
after_open_parent_swap_original=os.environ.get("UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_ORIGINAL")
after_open_parent_swap_on_name=os.environ.get("UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_ON_NAME")
publication_fail_name=os.environ.get("UBERDEV_TEST_PORTABLE_PUBLICATION_FAIL_NAME")
publication_errno=int(os.environ.get("UBERDEV_TEST_PORTABLE_PUBLICATION_ERRNO","0"))
unlink_fail_name=os.environ.get("UBERDEV_TEST_PORTABLE_UNLINK_FAIL_NAME")
if os.environ.get("UBERDEV_TEST_PORTABLE_SAMESTAT_FAIL") == "1":
 def failing_samestat(left,right): raise OSError("samestat unavailable")
 os.path.samestat=failing_samestat
swapped=False
manifest_swapped=False
parent_swapped=False
after_open_parent_swapped=False
fd_paths={}
def portable_open(path,flags,*args,**kwargs):
 global swapped,manifest_swapped,parent_swapped,after_open_parent_swapped
 if (not parent_swapped and parent_swap_path and parent_swap_with and isinstance(path,str)
     and os.path.dirname(os.path.abspath(path))==os.path.abspath(parent_swap_path)
     and (not parent_swap_on_name or os.path.basename(path)==parent_swap_on_name)
     and flags & os.O_EXCL):
  parent_swapped=True
  if parent_swap_original: os.rename(parent_swap_path,parent_swap_original)
  else: os.rmdir(parent_swap_path)
  os.symlink(parent_swap_with,parent_swap_path)
 fd=real_open(path,flags,*args,**kwargs)
 if isinstance(path,str): fd_paths[fd]=os.path.abspath(path)
 if (not after_open_parent_swapped and after_open_parent_swap_path and after_open_parent_swap_with
     and isinstance(path,str) and os.path.dirname(os.path.abspath(path))==os.path.abspath(after_open_parent_swap_path)
     and (not after_open_parent_swap_on_name or os.path.basename(path)==after_open_parent_swap_on_name)
     and flags & os.O_EXCL):
  after_open_parent_swapped=True
  if after_open_parent_swap_original: os.rename(after_open_parent_swap_path,after_open_parent_swap_original)
  else: os.rmdir(after_open_parent_swap_path)
  os.symlink(after_open_parent_swap_with,after_open_parent_swap_path)
 if (not manifest_swapped and manifest_swap_path and manifest_swap_with and isinstance(path,str)
     and os.path.abspath(path)==os.path.abspath(manifest_swap_path)
     and flags & os.O_ACCMODE == os.O_RDONLY):
  manifest_swapped=True
  os.replace(manifest_swap_with,manifest_swap_path)
 if (not swapped and swap_path and swap_with and isinstance(path,str)
     and os.path.abspath(path)==os.path.abspath(swap_path)
     and flags & os.O_ACCMODE == os.O_RDONLY):
  swapped=True
  os.replace(swap_with,swap_path)
 if (replace_created_name and isinstance(path,str) and os.path.basename(path)==replace_created_name
     and flags & os.O_EXCL):
  replacement=path+".replacement"
  with open(replacement,"wb") as stream: stream.write(b"replaced")
  os.replace(replacement,path)
 return fd
real_builtin_open=builtins.open
def portable_builtin_open(path,*args,**kwargs):
 global manifest_swapped
 stream=real_builtin_open(path,*args,**kwargs)
 mode=kwargs.get("mode",args[0] if args else "r")
 if (not manifest_swapped and manifest_swap_path and manifest_swap_with and isinstance(path,str)
     and os.path.abspath(path)==os.path.abspath(manifest_swap_path) and "r" in mode):
  manifest_swapped=True
  os.replace(manifest_swap_with,manifest_swap_path)
 return stream
def portable_read(fd,size):
 global swapped
 data=real_read(fd,size)
 if (not swapped and swap_after_read_path and swap_after_read_with
     and fd_paths.get(fd)==os.path.abspath(swap_after_read_path)):
  swapped=True
  os.replace(swap_after_read_with,swap_after_read_path)
 return data
def portable_lstat(path,*args,**kwargs):
 entry=real_lstat(path,*args,**kwargs)
 if reparse_path and isinstance(path,str) and os.path.abspath(path)==os.path.abspath(reparse_path):
  class ReparseEntry:
   st_file_attributes=0x400
   def __getattr__(self,name): return getattr(entry,name)
  return ReparseEntry()
 return entry
def portable_fsync(fd):
 if publication_fail_name and os.path.basename(fd_paths.get(fd,""))==publication_fail_name:
  raise OSError(publication_errno,"injected publication failure")
 return real_fsync(fd)
def portable_unlink(path,*args,**kwargs):
 if unlink_fail_name and isinstance(path,str) and os.path.basename(path)==unlink_fail_name:
  raise PermissionError(errno.EACCES,"injected rollback failure")
 return real_unlink(path,*args,**kwargs)
os.open=portable_open
os.read=portable_read
os.lstat=portable_lstat
os.fsync=portable_fsync
os.unlink=portable_unlink
builtins.open=portable_builtin_open
sys.argv=["-"]+sys.argv[1:]
source_fd,source_path=tempfile.mkstemp(prefix="portable-child-dispatch-",suffix=".py")
try:
 with os.fdopen(source_fd,"w",encoding="utf-8") as stream: stream.write(source)
 runpy.run_path(source_path,run_name="__main__")
finally:
 try: os.unlink(source_path)
 except FileNotFoundError: pass
' "$@"
    elif [ "${1:-}" = -I ] && [ "${2:-}" = -B ] && [ "${3:-}" = -c ]; then
      local portable_source="$4"; shift 4
      command "$REAL_PORTABLE_PYTHON" -I -B -c '
import os,runpy,sys,tempfile
source=sys.argv[1]
if hasattr(os,"geteuid"): del os.geteuid
if hasattr(os,"getuid"): del os.getuid
sys.argv=["-c"]+sys.argv[2:]
source_fd,source_path=tempfile.mkstemp(prefix="portable-carrier-",suffix=".py")
try:
 with os.fdopen(source_fd,"w",encoding="utf-8") as stream: stream.write(source)
 runpy.run_path(source_path,run_name="__main__")
finally:
 try: os.unlink(source_path)
 except FileNotFoundError: pass
' "$portable_source" "$@"
    else
      command "$REAL_PORTABLE_PYTHON" "$@"
    fi
  }

  portable_manifest="$ROOT/tests/_fixtures/.portable-child-run-tree-$$.json"
  portable_manifest_swap="$portable_manifest.swap"
  cp "$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json" "$portable_manifest"
  trap 'rm -f "$portable_manifest" "$portable_manifest_swap"' EXIT
  portable_manifest_real="$(cd "$(dirname "$portable_manifest")" && pwd -P)/$(basename "$portable_manifest")"
  [ "$(UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$portable_manifest" _uberdev_child_manifest_path)" = "$portable_manifest_real" ]
  ! UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$portable_manifest" \
    UBERDEV_TEST_PORTABLE_REPARSE_PATH="$portable_manifest" _uberdev_child_manifest_path >/dev/null 2>&1

  portable_run="$TMP/portable-run"; mkdir -p "$portable_run"; portable_run="$(cd "$portable_run" && pwd -P)"
  portable_request="$(jq -cn --arg run "$portable_run" --arg repo "$TEST_REPO" '{schema_version:1,run_dir:$run,run_id:"portable-review",repository_id:$repo,backend:"codex",workflow:"review-pr",phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:1,issue_num:1,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
  portable_decision="$(uberdev_agent_resolve_request "$portable_request")"
  portable_metadata="$(jq -cn --arg repo "$TEST_REPO" '{run_id:"portable-review",repository_id:$repo,workflow:"review-pr",backend:"codex",issue_num:1,task_tier:"medium",risk_signals:[]}')"
  portable_context_out="$(uberdev_agent_context_create "$portable_run" "$portable_request" "$portable_decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$portable_metadata" '2026-07-10T00:00:00Z')"
  portable_ctx="$(jq -r .context_file <<<"$portable_context_out")"
  portable_sha="$(jq -r .context_sha256 <<<"$portable_context_out")"
  UBERDEV_RUN_CARRIER_JSON="$(jq -cn --arg ctx "$portable_ctx" --arg sha "$portable_sha" '{schema_version:1,run_id:"portable-review",workflow:"review-pr",issue_num:1,context_file:$ctx,context_sha256:$sha}')"
  export UBERDEV_RUN_CARRIER_JSON
  portable_input="$(jq -cn --arg p "$TEST_REPO/README.md" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"

  uberdev_create_child_handoff review_pr.review.correctness portable-duplicate-iter1-attempt01 "$portable_input" '[]' >/dev/null
  duplicate_error="$(uberdev_create_child_handoff review_pr.review.correctness portable-duplicate-iter1-attempt01 "$portable_input" '[]' 2>&1)" \
    && { echo 'duplicate handoff identity was accepted' >&2; exit 1; }
  grep -q 'instance_exists' <<<"$duplicate_error"

  for publication_case in '13:publication_permission_denied' '28:publication_no_space' '5:publication_io_failed' '4:publication_interrupted'; do
    publication_errno_value="${publication_case%%:*}"
    publication_reason="${publication_case#*:}"
    publication_name="portable-publication-${publication_errno_value}-iter1-attempt01.json"
    publication_error="$(UBERDEV_TEST_PORTABLE_PUBLICATION_FAIL_NAME="$publication_name" \
      UBERDEV_TEST_PORTABLE_PUBLICATION_ERRNO="$publication_errno_value" \
      uberdev_create_child_handoff review_pr.review.correctness "${publication_name%.json}" "$portable_input" '[]' 2>&1)" \
      && { echo "publication errno $publication_errno_value was accepted" >&2; exit 1; }
    grep -q "$publication_reason" <<<"$publication_error"
    [ ! -e "$portable_run/handoffs/$publication_name" ]
  done

  rollback_name='portable-rollback-failed-iter1-attempt01.json'
  rollback_error="$(UBERDEV_TEST_PORTABLE_PUBLICATION_FAIL_NAME="$rollback_name" \
    UBERDEV_TEST_PORTABLE_PUBLICATION_ERRNO=28 UBERDEV_TEST_PORTABLE_UNLINK_FAIL_NAME="$rollback_name" \
    uberdev_create_child_handoff review_pr.review.correctness "${rollback_name%.json}" "$portable_input" '[]' 2>&1)" \
    && { echo 'publication with rollback failure was accepted' >&2; exit 1; }
  grep -q 'publication_no_space' <<<"$rollback_error"
  grep -q 'rollback_failed' <<<"$rollback_error"
  [ -e "$portable_run/handoffs/$rollback_name" ]
  rm -f "$portable_run/handoffs/$rollback_name"

  uberdev_create_child_handoff review_pr.review.correctness portable-prepare-rollback-iter1-attempt01 "$portable_input" '[]' >/dev/null
  prepare_rollback_error="$(UBERDEV_TEST_PORTABLE_PUBLICATION_FAIL_NAME=prompt.txt \
    UBERDEV_TEST_PORTABLE_PUBLICATION_ERRNO=28 UBERDEV_TEST_PORTABLE_UNLINK_FAIL_NAME=prompt.txt \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch 2>&1)" \
    && { echo 'child prepare with rollback failure was accepted' >&2; exit 1; }
  grep -q 'unsafe_child_dir' <<<"$prepare_rollback_error"
  grep -q 'rollback_failed' <<<"$prepare_rollback_error"
  rm -rf "$portable_run/children/portable-prepare-rollback-iter1-attempt01"

  cp "$portable_manifest" "$portable_manifest_swap"
  if UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$portable_manifest" \
    UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_PATH="$portable_manifest" UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_WITH="$portable_manifest_swap" \
    uberdev_create_child_handoff review_pr.review.correctness portable-manifest-build-swap-iter1-attempt01 "$portable_input" '[]' >/dev/null 2>&1; then
    echo 'manifest replacement accepted during handoff construction' >&2
    exit 1
  fi
  [ ! -e "$portable_run/handoffs/portable-manifest-build-swap-iter1-attempt01.json" ]

  UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$portable_manifest" \
    uberdev_create_child_handoff review_pr.review.correctness portable-manifest-prepare-swap-iter1-attempt01 "$portable_input" '[]' >/dev/null
  cp "$portable_manifest" "$portable_manifest_swap"
  ! UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$portable_manifest" \
    UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_PATH="$portable_manifest" UBERDEV_TEST_PORTABLE_MANIFEST_SWAP_WITH="$portable_manifest_swap" \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-manifest-prepare-swap-iter1-attempt01" ]

  handoff_parent="$portable_run/handoffs"
  handoff_parent_original="$TMP/portable-handoffs-original"
  handoff_parent_replacement="$TMP/portable-handoffs-replacement"; mkdir "$handoff_parent_replacement"
  if UBERDEV_TEST_PORTABLE_PARENT_SWAP_PATH="$handoff_parent" UBERDEV_TEST_PORTABLE_PARENT_SWAP_WITH="$handoff_parent_replacement" \
    UBERDEV_TEST_PORTABLE_PARENT_SWAP_ORIGINAL="$handoff_parent_original" \
    uberdev_create_child_handoff review_pr.review.correctness portable-handoff-parent-swap-iter1-attempt01 "$portable_input" '[]' >/dev/null 2>&1; then
    echo 'handoff parent replacement accepted during exclusive publication' >&2
    exit 1
  fi
  [ ! -e "$handoff_parent_original/portable-handoff-parent-swap-iter1-attempt01.json" ]
  [ ! -e "$handoff_parent_replacement/portable-handoff-parent-swap-iter1-attempt01.json" ]
  [ -L "$handoff_parent" ] && rm "$handoff_parent"
  mv "$handoff_parent_original" "$handoff_parent"

  handoff_after_open_original="$TMP/portable-handoffs-after-open-original"
  handoff_after_open_replacement="$TMP/portable-handoffs-after-open-replacement"; mkdir "$handoff_after_open_replacement"
  if UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_PATH="$handoff_parent" \
    UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_WITH="$handoff_after_open_replacement" \
    UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_ORIGINAL="$handoff_after_open_original" \
    UBERDEV_TEST_PORTABLE_AFTER_OPEN_PARENT_SWAP_ON_NAME=portable-handoff-parent-after-open-swap-iter1-attempt01.json \
    uberdev_create_child_handoff review_pr.review.correctness portable-handoff-parent-after-open-swap-iter1-attempt01 "$portable_input" '[]' >/dev/null 2>&1; then
    echo 'handoff parent replacement accepted after exclusive open' >&2
    exit 1
  fi
  if [ -e "$handoff_after_open_original/portable-handoff-parent-after-open-swap-iter1-attempt01.json" ]; then
    echo 'handoff publication stranded an artifact in the renamed original parent' >&2
    exit 1
  fi
  [ ! -e "$handoff_after_open_replacement/portable-handoff-parent-after-open-swap-iter1-attempt01.json" ]
  [ -L "$handoff_parent" ] && rm "$handoff_parent"
  mv "$handoff_after_open_original" "$handoff_parent"

  uberdev_create_child_handoff review_pr.review.correctness portable-valid-iter1-attempt01 "$portable_input" '[]' >/dev/null
  UBERDEV_TEST_PORTABLE_SAMESTAT_FAIL=1 \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null
  [ -s "$portable_run/children/portable-valid-iter1-attempt01/handoff.v1.json" ]
  [ -s "$portable_run/children/portable-valid-iter1-attempt01/prompt.txt" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-symlink-iter1-attempt01 "$portable_input" '[]' >/dev/null
  symlink_handoff="$UBERDEV_CHILD_HANDOFF"; mv "$symlink_handoff" "$symlink_handoff.real"; ln -s "$symlink_handoff.real" "$symlink_handoff"
  ! _uberdev_child_prepare review_pr.review.correctness "$symlink_handoff" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-symlink-iter1-attempt01" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-replaced-iter1-attempt01 "$portable_input" '[]' >/dev/null
  replaced_handoff="$UBERDEV_CHILD_HANDOFF"; cp "$replaced_handoff" "$replaced_handoff.swap"
  ! UBERDEV_TEST_PORTABLE_SWAP_PATH="$replaced_handoff" UBERDEV_TEST_PORTABLE_SWAP_WITH="$replaced_handoff.swap" \
    _uberdev_child_prepare review_pr.review.correctness "$replaced_handoff" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-replaced-iter1-attempt01" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-post-read-replaced-iter1-attempt01 "$portable_input" '[]' >/dev/null
  post_read_handoff="$UBERDEV_CHILD_HANDOFF"; cp "$post_read_handoff" "$post_read_handoff.swap"
  ! UBERDEV_TEST_PORTABLE_SWAP_AFTER_READ_PATH="$post_read_handoff" UBERDEV_TEST_PORTABLE_SWAP_AFTER_READ_WITH="$post_read_handoff.swap" \
    _uberdev_child_prepare review_pr.review.correctness "$post_read_handoff" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-post-read-replaced-iter1-attempt01" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-created-replaced-iter1-attempt01 "$portable_input" '[]' >/dev/null
  ! UBERDEV_TEST_PORTABLE_REPLACE_CREATED_NAME=handoff.v1.json \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-created-replaced-iter1-attempt01" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-parent-replaced-iter1-attempt01 "$portable_input" '[]' >/dev/null
  parent_replacement="$TMP/portable-parent-replacement"; mkdir "$parent_replacement"
  portable_child_dir="$portable_run/children/portable-parent-replaced-iter1-attempt01"
  ! UBERDEV_TEST_PORTABLE_PARENT_SWAP_PATH="$portable_child_dir" UBERDEV_TEST_PORTABLE_PARENT_SWAP_WITH="$parent_replacement" \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$parent_replacement/handoff.v1.json" ]
  [ ! -e "$parent_replacement/prompt.txt" ]
  [ ! -e "$portable_child_dir" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-prompt-parent-replaced-iter1-attempt01 "$portable_input" '[]' >/dev/null
  prompt_parent_replacement="$TMP/portable-prompt-parent-replacement"; mkdir "$prompt_parent_replacement"
  prompt_parent_original="$TMP/portable-prompt-parent-original"
  portable_prompt_child="$portable_run/children/portable-prompt-parent-replaced-iter1-attempt01"
  ! UBERDEV_TEST_PORTABLE_PARENT_SWAP_PATH="$portable_prompt_child" UBERDEV_TEST_PORTABLE_PARENT_SWAP_WITH="$prompt_parent_replacement" \
    UBERDEV_TEST_PORTABLE_PARENT_SWAP_ORIGINAL="$prompt_parent_original" UBERDEV_TEST_PORTABLE_PARENT_SWAP_ON_NAME=prompt.txt \
    _uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$prompt_parent_replacement/handoff.v1.json" ]
  [ ! -e "$prompt_parent_replacement/prompt.txt" ]
  [ ! -e "$prompt_parent_original/handoff.v1.json" ]
  [ ! -e "$prompt_parent_original/prompt.txt" ]
  [ ! -e "$portable_prompt_child" ]
  [ ! -e "$prompt_parent_original" ]

  uberdev_create_child_handoff review_pr.review.correctness portable-tampered-iter1-attempt01 "$portable_input" '[]' >/dev/null
  tampered_handoff="$UBERDEV_CHILD_HANDOFF"
  command "$REAL_PORTABLE_PYTHON" - "$tampered_handoff" <<'PY'
import json,sys
path=sys.argv[1]
with open(path,encoding='utf-8') as stream: value=json.load(stream)
value['edge_id']='review_pr.review.types'
with open(path,'w',encoding='utf-8') as stream: json.dump(value,stream,separators=(',',':'))
PY
  ! _uberdev_child_prepare review_pr.review.correctness "$tampered_handoff" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null 2>&1
  [ ! -e "$portable_run/children/portable-tampered-iter1-attempt01" ]
)

path="$TEST_REPO/README.md"; changed_path="README.md"; deleted_path="src/deleted-in-pr.ts"; dir="$TEST_REPO"
declare -a edges inputs risks
for lens in correctness silent_failures types comments tests; do
  edges+=("review_pr.review.$lens")
  inputs+=("$(jq -cn --arg changed "$changed_path" --arg deleted "$deleted_path" --arg p "$path" '{changed_paths:[$changed,$deleted],diff_path:$p,criteria_path:$p,emphasis:[]}')")
  risks+=('[]')
done
edges+=(review_pr.review.general)
inputs+=("$(jq -cn --arg changed "$changed_path" --arg deleted "$deleted_path" --arg p "$path" '{changed_paths:[$changed,$deleted],diff_path:$p,criteria_path:$p,emphasis:[],lens:"general"}')")
risks+=('[]')
for edge in review_pr.fix.phase1 review_pr.fix.phase2; do
  edges+=("$edge")
  inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')")
  risks+=(null)
done
for lens in reuse quality efficiency; do
  edges+=("review_pr.simplify.$lens")
  inputs+=("$(jq -cn --arg p "$path" --arg lens "$lens" '{diff_path:$p,lens:$lens,focus:"review"}')")
  risks+=('[]')
done
edges+=(review_pr.defer.findings)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{phase1_path:$p,phase2_path:$p,phase1_disposition_path:$p,phase2_disposition_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.classify)
inputs+=("$(jq -cn --arg p "$path" '{pr_number:1,run_id:"1",log_path:$p}')")
risks+=('[]')
edges+=(review_pr.ci.fix_code)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{classification_path:$p,log_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.rebase)
inputs+=("$(jq -cn --arg d "$dir" '{working_dir:$d,pr_number:1,head_sha:"0123456789012345678901234567890123456789",base_sha:"abcdefabcdefabcdefabcdefabcdefabcdefabcd"}')")
risks+=(null)
edges+=(review_pr.ci.defer_refusal)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{phase1_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.resolve_conflict)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{file_path:$p,working_dir:$d,pr_branch:"feature",integration_branch:"main",base_sha:"abcdefabcdefabcdefabcdefabcdefabcdefabcd"}')")
risks+=(null)

for i in "${!edges[@]}"; do
  instance="review-contract-${i}-iter1-attempt01"
  uberdev_create_child_handoff "${edges[$i]}" "$instance" "${inputs[$i]}" "${risks[$i]}" >/dev/null
  jq -e --arg edge "${edges[$i]}" '.edge_id==$edge and (.inputs|type)=="object"' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# Every required reviewer supports one unique, exact-input format retry.
for i in 0 1 2 3 4 5; do
  retry="$(jq -c '. + {format_retry:true}' <<<"${inputs[$i]}")"
  uberdev_create_child_handoff "${edges[$i]}" "review-contract-${i}-iter1-attempt02" "$retry" '[]' >/dev/null
  jq -e '.inputs.format_retry == true' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# changed_paths is Git diff metadata, not an existing-file capability. Accept
# normalized repo-relative entries (including deleted files), and reject every
# spelling that could escape or ambiguously reinterpret the repository scope.
base_review_input="$(jq -cn --arg p "$path" '{changed_paths:["src/deleted-in-pr.ts"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.correctness review-relative-deleted-iter1-attempt01 "$base_review_input" '[]' >/dev/null
jq -e '.inputs.changed_paths==["src/deleted-in-pr.ts"]' "$UBERDEV_CHILD_HANDOFF" >/dev/null
empty_review_input="$(jq -cn --arg p "$path" '{changed_paths:[],diff_path:$p,criteria_path:$p,emphasis:[]}')"
if uberdev_create_child_handoff review_pr.review.correctness review-empty-scope-iter1-attempt01 "$empty_review_input" '[]' >/dev/null 2>&1; then
  echo "empty changed_paths review scope accepted" >&2
  exit 1
fi
for unsafe in "$path" '../outside.ts' 'src/../outside.ts' './src/file.ts' 'src//file.ts' 'src\file.ts' 'C:\repo\file.ts' 'C:/repo/file.ts' $'src/tab\tfile.ts'; do
  unsafe_input="$(jq -cn --arg unsafe "$unsafe" --arg p "$path" '{changed_paths:[$unsafe],diff_path:$p,criteria_path:$p,emphasis:[]}')"
  if uberdev_create_child_handoff review_pr.review.correctness "review-unsafe-$RANDOM-iter1-attempt01" "$unsafe_input" '[]' >/dev/null 2>&1; then
    echo "unsafe changed_paths entry accepted: $unsafe" >&2
    exit 1
  fi
done

# Routed child prompt composition appends the exact shared contract immediately
# before the immutable execution directive.
contract="$ROOT/plugins/uberdev/shared/phase1-reviewer-output-v1.md"
contract_input="$(jq -cn --arg p "$path" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.correctness review-contract-prompt-iter1-attempt01 "$contract_input" '[]' >/dev/null
_uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null
prompt="$(dirname "$UBERDEV_CHILD_RESULT")/prompt.txt"
python3 -I -B - "$prompt" "$contract" <<'PY'
import pathlib,sys
prompt=pathlib.Path(sys.argv[1]).read_bytes(); contract=pathlib.Path(sys.argv[2]).read_bytes()
needle=b'\n\n'+contract+b'\n\n## Immutable routed execution directive\n'
assert prompt.count(contract)==1
assert needle in prompt
assert b'Return only a response matching the output contract above.' in prompt
assert b'Return completed, blocked, or refused.' not in prompt
PY

# Reviewer validation is bound to the exact changed-path snapshot and emits a
# byte-identical, digest-addressed canonical artifact for aggregation.
VALID_RESULT="$TMP/reviewer-valid.md"
OUT_OF_SCOPE_RESULT="$TMP/reviewer-out-of-scope.md"
VALIDATED_RESULT="$TMP/reviewer-validated.md"
cat >"$VALID_RESULT" <<'EOF_RESULT'
```yaml
verdict: REVISIONS_REQUIRED
findings:
  - severity: blocker
    location: README.md:1
    summary: bounded finding
    detail: bounded detail
confidence: high
```
EOF_RESULT
cat >"$OUT_OF_SCOPE_RESULT" <<'EOF_RESULT'
```yaml
verdict: REVISIONS_REQUIRED
findings:
  - severity: blocker
    location: src/outside.ts:1
    summary: out of scope
    detail: out of scope detail
confidence: high
```
EOF_RESULT
if uberdev_child_validate_phase1_review_result "$OUT_OF_SCOPE_RESULT" '["README.md"]' "$VALIDATED_RESULT" >/dev/null 2>&1; then
  echo 'phase1 validator accepted a finding outside the reviewed path snapshot' >&2
  exit 1
fi
VALIDATED_DIGEST="$(uberdev_child_validate_phase1_review_result "$VALID_RESULT" '["README.md"]' "$VALIDATED_RESULT")"
[[ "$VALIDATED_DIGEST" =~ ^[0-9a-f]{64}$ ]]
cmp "$VALID_RESULT" "$VALIDATED_RESULT"
[ "$(stat -c '%a' "$VALIDATED_RESULT" 2>/dev/null || stat -f '%Lp' "$VALIDATED_RESULT")" = 400 ]
for publication_stage in create write sync harden readback; do
  publication_target="$TMP/reviewer-publication-$publication_stage.md"
  set +e
  UBERDEV_CHILD_TEST_MODE=1 UBERDEV_TEST_VALIDATED_PUBLICATION_FAILURE="$publication_stage" \
    uberdev_child_validate_phase1_review_result "$VALID_RESULT" '["README.md"]' "$publication_target" \
      >"$TMP/reviewer-publication-$publication_stage.stdout" \
      2>"$TMP/reviewer-publication-$publication_stage.stderr"
  publication_rc=$?
  set -e
  [ "$publication_rc" -eq 74 ]
  [ ! -e "$publication_target" ]
  [ ! -s "$TMP/reviewer-publication-$publication_stage.stdout" ]
  grep -qx 'review_result_publication_failed' "$TMP/reviewer-publication-$publication_stage.stderr"
done
for publication_mode in short-read native-mode; do
  publication_target="$TMP/reviewer-publication-$publication_mode.md"
  publication_digest="$(
    UBERDEV_CHILD_TEST_MODE=1 UBERDEV_TEST_VALIDATED_PUBLICATION_FAILURE="$publication_mode" \
      uberdev_child_validate_phase1_review_result "$VALID_RESULT" '["README.md"]' "$publication_target"
  )"
  [[ "$publication_digest" =~ ^[0-9a-f]{64}$ ]]
  cmp "$VALID_RESULT" "$publication_target"
done
python3 -I -B - "$LIB" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
start=source.index('uberdev_child_validate_phase1_review_result() {')
end=source.index('\n_uberdev_child_find_lease() {',start)
validator=source[start:end]
assert validator.count("getattr(os,'O_BINARY',0)") >= 3
assert "injected=='short-read'" in validator
assert "premature publication readback EOF" in validator
assert "publication readback overflow" in validator
PY

# Mutating review edges execute against the carrier-selected caller repository
# identity and workspace binding. Reviewers remain isolated, and a different
# working_dir is rejected before dispatch.
caller_input="$(jq -cn --arg p "$path" --arg d "$TEST_REPO" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')"
uberdev_create_child_handoff review_pr.fix.phase1 review-caller-mode-iter1-attempt01 "$caller_input" null >/dev/null
caller_prepared="$(_uberdev_child_prepare review_pr.fix.phase1 "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch)"
jq -e --arg repo "$TEST_REPO" '.request.workspace_mode=="caller" and .request.workspace_dir==$repo' <<<"$caller_prepared" >/dev/null
reviewer_input="$(jq -cn --arg p "$path" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.types review-isolated-mode-iter1-attempt01 "$reviewer_input" '[]' >/dev/null
reviewer_prepared="$(_uberdev_child_prepare review_pr.review.types "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch)"
jq -e '.request.workspace_mode=="isolated" and (.request|has("workspace_dir")|not)' <<<"$reviewer_prepared" >/dev/null
OTHER_REPO="$TMP/other-repo"; mkdir -p "$OTHER_REPO"
mismatch_input="$(jq -cn --arg p "$path" --arg d "$OTHER_REPO" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')"
if uberdev_create_child_handoff review_pr.fix.phase1 review-mismatch-mode-iter1-attempt01 "$mismatch_input" null >/dev/null 2>&1; then
  echo 'caller workspace mismatch accepted' >&2
  exit 1
fi

# /solve and /turbo inherit the same immutable carrier through the actual
# reviewer, caller-workspace fixer, and deferred-findings edge lifecycles.
exercise_parent_review_carrier() {
  local workflow="$1" issue="$2" suffix="$3" parent_run
  parent_run="$TMP/$workflow-parent"
  local request decision metadata context_out context_file context_sha carrier workspace
  local reviewer_handoff reviewer_result reviewer_status reviewer_prepared
  local fixer_handoff fixer_result fixer_status fixer_prepared
  local defer_handoff defer_result defer_status defer_prepared
  mkdir -p "$parent_run"
  request="$(jq -cn --arg run "$parent_run" --arg repo "$TEST_REPO" --arg workflow "$workflow" --arg run_id "parent-$workflow" --argjson issue "$issue" \
    '{schema_version:1,run_dir:$run,run_id:$run_id,repository_id:$repo,backend:"codex",workflow:$workflow,phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:$issue,issue_num:$issue,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(jq -cn --arg repo "$TEST_REPO" --arg workflow "$workflow" --arg run_id "parent-$workflow" --argjson issue "$issue" \
    '{run_id:$run_id,repository_id:$repo,workflow:$workflow,backend:"codex",issue_num:$issue,task_tier:"medium",risk_signals:[]}')"
  context_out="$(uberdev_agent_context_create "$parent_run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-26T00:00:00Z')"
  context_file="$(jq -r .context_file <<<"$context_out")"
  context_sha="$(jq -r .context_sha256 <<<"$context_out")"
  carrier="$(jq -cn --arg workflow "$workflow" --arg run_id "parent-$workflow" --arg context "$context_file" --arg sha "$context_sha" --argjson issue "$issue" \
    '{schema_version:1,run_id:$run_id,workflow:$workflow,issue_num:$issue,context_file:$context,context_sha256:$sha}')"
  UBERDEV_RUN_CARRIER_JSON="$carrier"; export UBERDEV_RUN_CARRIER_JSON
  unset UBERDEV_COMMAND_WORKSPACE_JSON
  workspace="$(uberdev_command_workspace_prepare review-pr "$issue" medium '[]' "20260726-01020${suffix}-abcdef0" "$TEST_REPO")"
  jq -e --arg workflow "$workflow" --arg repo "$TEST_REPO" \
    '.caller=="review-pr" and .carrier_workflow==$workflow and .repository_root==$repo' <<<"$workspace" >/dev/null

  reviewer_input="$(jq -cn --arg p "$path" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
  uberdev_create_child_handoff review_pr.review.correctness "$workflow-reviewer-iter1-attempt01" "$reviewer_input" '[]' >/dev/null
  reviewer_handoff="$UBERDEV_CHILD_HANDOFF"; reviewer_result="$UBERDEV_CHILD_RESULT"; reviewer_status="$UBERDEV_CHILD_STATUS"
  _uberdev_child_backend_cancellation_supported() { return 0; }
  uberdev_preflight_child_batch "$reviewer_handoff"
  reviewer_prepared="$(_uberdev_child_prepare review_pr.review.correctness "$reviewer_handoff" "$reviewer_result" "$reviewer_status" dispatch)"
  jq -e --arg workflow "$workflow" --argjson issue "$issue" \
    '.carrier.workflow==$workflow and .carrier.issue_num==$issue and .edge_id=="review_pr.review.correctness"' "$reviewer_handoff" >/dev/null
  jq -e '.request.workspace_mode=="isolated"' <<<"$reviewer_prepared" >/dev/null

  fixer_input="$(jq -cn --arg p "$path" --arg d "$TEST_REPO" --argjson pr "$issue" \
    '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:$pr,disposition_path:$p}')"
  uberdev_create_child_handoff review_pr.fix.phase1 "$workflow-fixer-iter1-attempt01" "$fixer_input" null >/dev/null
  fixer_handoff="$UBERDEV_CHILD_HANDOFF"; fixer_result="$UBERDEV_CHILD_RESULT"; fixer_status="$UBERDEV_CHILD_STATUS"
  uberdev_preflight_child_batch "$fixer_handoff"
  fixer_prepared="$(_uberdev_child_prepare review_pr.fix.phase1 "$fixer_handoff" "$fixer_result" "$fixer_status" dispatch)"
  jq -e --arg workflow "$workflow" --arg context "$context_file" --arg sha "$context_sha" \
    '.carrier.workflow==$workflow and .carrier.context_file==$context and .carrier.context_sha256==$sha and .edge_id=="review_pr.fix.phase1"' "$fixer_handoff" >/dev/null
  jq -e --arg repo "$TEST_REPO" '.request.workspace_mode=="caller" and .request.workspace_dir==$repo' <<<"$fixer_prepared" >/dev/null

  defer_input="$(jq -cn --arg p "$path" --arg d "$TEST_REPO" --argjson pr "$issue" \
    '{phase1_path:$p,phase2_path:"",phase1_disposition_path:$p,phase2_disposition_path:"",working_dir:$d,pr_number:$pr}')"
  uberdev_create_child_handoff review_pr.defer.findings "$workflow-defer-iter1-attempt01" "$defer_input" null >/dev/null
  defer_handoff="$UBERDEV_CHILD_HANDOFF"; defer_result="$UBERDEV_CHILD_RESULT"; defer_status="$UBERDEV_CHILD_STATUS"
  uberdev_preflight_child_batch "$defer_handoff"
  defer_prepared="$(_uberdev_child_prepare review_pr.defer.findings "$defer_handoff" "$defer_result" "$defer_status" dispatch)"
  jq -e --arg workflow "$workflow" --arg context "$context_file" --arg sha "$context_sha" \
    '.carrier.workflow==$workflow and .carrier.context_file==$context and .carrier.context_sha256==$sha and .edge_id=="review_pr.defer.findings"' "$defer_handoff" >/dev/null
  jq -e '.request.workspace_mode=="isolated"' <<<"$defer_prepared" >/dev/null
}
exercise_parent_review_carrier solve 81 1
exercise_parent_review_carrier turbo 82 2
UBERDEV_RUN_CARRIER_JSON="$REVIEW_CARRIER_JSON"; export UBERDEV_RUN_CARRIER_JSON

# A standalone simplify run may omit an additional focus hint.
for lens in reuse quality efficiency; do
  edge="review_pr.simplify.$lens"
  input="$(jq -cn --arg p "$path" --arg lens "$lens" '{diff_path:$p,lens:$lens}')"
  uberdev_create_child_handoff "$edge" "simplify-no-focus-$lens-iter1-attempt01" "$input" '[]' >/dev/null
  jq -e '(.inputs | has("focus") | not)' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# Source/init precedes the builders, and all executable snippets are nounset-safe.
for doc in "$REVIEW" "$SIMPLIFY"; do
  setup_line="$(grep -n 'uberdev-executable setup=' "$doc" | head -1 | cut -d: -f1)"
  builder_line="$(grep -n 'review_child_record()' "$doc" | head -1 | cut -d: -f1)"
  [ "$setup_line" -lt "$builder_line" ]
done
# Extract each production setup fence.
for spec in "$REVIEW:review-pr" "$SIMPLIFY:simplify" "$POST:post-impl-review"; do
  doc="${spec%:*}"; name="${spec##*:}"; setup="$TMP/setup-$name.sh"
  awk -v marker="uberdev-executable setup=$name" '
    index($0,marker){active=1; next}
    active && /^```/{exit}
    active{print}
  ' "$doc" >"$setup"
  [ -s "$setup" ]
done

# Roster validation is a behavioral pre-aggregation gate, including repair
# waves whose expected count is smaller than the full six-reviewer roster.
awk '/^post_review_roster_complete\(\) \{/{active=1} active{print} active && /^\}/{exit}' \
  "$POST" >"$TMP/roster-runtime.sh"
awk '/^post_review_require_complete_wave\(\) \{/{active=1} active{print} active && /^\}/{exit}' \
  "$POST" >"$TMP/aggregate-gate-runtime.sh"
awk '/^post_review_init_ledger\(\) \{/{active=1} active && /^REVIEW_EDGES=\(/{exit} active{print}' \
  "$POST" >"$TMP/capped-fanout-runtime.sh"
awk '
  /^post_review_require_complete_wave\(\) \{/{active=1}
  active && /^```/{exit}
  active{print}
' "$POST" >"$TMP/aggregate-gate-production.sh"
. "$TMP/roster-runtime.sh"
. "$TMP/aggregate-gate-runtime.sh"
ROSTER_EDGES=(
  review_pr.review.correctness review_pr.review.silent_failures
  review_pr.review.types review_pr.review.comments
  review_pr.review.tests review_pr.review.general
)
roster_row() {
  local edge="$1" index
  for index in "${!ROSTER_EDGES[@]}"; do
    if [ "${ROSTER_EDGES[$index]}" = "$edge" ]; then
      printf '{"edge":"%s","index":%s}\n' "$edge" "$((index + 1))"
      return 0
    fi
  done
  printf '{"edge":"%s","index":999}\n' "$edge"
}
roster_must_block_aggregation() {
  local records expected aggregate
  records="$1"
  expected="$2"
  aggregate="$records.aggregate"
  rm -f "$aggregate"
  if post_review_roster_complete "$records" "$expected" "${ROSTER_EDGES[@]}"; then
    : >"$aggregate"
  fi
  [ ! -e "$aggregate" ]
}
ROSTER_VALID="$TMP/roster-valid.records"
for edge in "${ROSTER_EDGES[@]}"; do roster_row "$edge"; done >"$ROSTER_VALID"
post_review_roster_complete "$ROSTER_VALID" 6 "${ROSTER_EDGES[@]}"
sed '$d' "$ROSTER_VALID" >"$TMP/roster-missing.records"
roster_must_block_aggregation "$TMP/roster-missing.records" 6
{
  sed '$d' "$ROSTER_VALID"
  roster_row review_pr.review.correctness
} >"$TMP/roster-duplicate.records"
roster_must_block_aggregation "$TMP/roster-duplicate.records" 6
{
  sed '$d' "$ROSTER_VALID"
  roster_row review_pr.review.unknown
} >"$TMP/roster-unknown.records"
roster_must_block_aggregation "$TMP/roster-unknown.records" 6
head -1 "$ROSTER_VALID" >"$TMP/roster-truncated-repair.records"
roster_must_block_aggregation "$TMP/roster-truncated-repair.records" 2

# Validated evidence is independently bound to the exact launched roster.
# Duplicate indices, impersonated instances, reused canonical artifacts, and
# digest replacement must all fail before aggregation. A format repair keeps
# the original edge/index but may prove itself with the fresh launched instance.
awk '/^post_review_validated_evidence_complete\(\) \{/{active=1} active{print} active && /^\}/{exit}' \
  "$POST" >"$TMP/evidence-runtime.sh"
. "$TMP/evidence-runtime.sh"
REVIEW_EDGES=("${ROSTER_EDGES[@]}")
EVIDENCE_ROOT="$TMP/evidence"
mkdir -p "$EVIDENCE_ROOT"
python3 -I -B - "$EVIDENCE_ROOT" <<'PY'
import hashlib,json,os,pathlib,sys
root=pathlib.Path(os.path.realpath(sys.argv[1]))
children=root/"children"; children.mkdir()
edges=[
 "review_pr.review.correctness","review_pr.review.silent_failures",
 "review_pr.review.types","review_pr.review.comments",
 "review_pr.review.tests","review_pr.review.general",
]
launched=[]; validated=[]
for index,edge in enumerate(edges,1):
 child=children/f"review-{index}-attempt01"; child.mkdir()
 provider=child/"result.md"; provider.write_text("provider-owned\n")
 canonical=child/"validated-result.md"; payload=f"validated-{index}\n".encode()
 canonical.write_bytes(payload); canonical.chmod(0o400)
 instance=f"review-{index}-attempt01"
 (child/"status.json").write_text('{"state":"completed","exit_code":0}\n')
 launched.append({"edge":edge,"index":index,"instance":instance,"receipt":"fixture",
                  "result":str(provider),"status":str(child/"status.json")})
 validated.append({"edge":edge,"index":index,"instance":instance,
                   "result":str(canonical),"sha256":hashlib.sha256(payload).hexdigest()})
for name,rows in (("initial",launched),("validated",validated)):
 (root/name).write_text("".join(json.dumps(row,separators=(",",":"))+"\n" for row in rows))
(root/"repair").write_text("")
PY
POST_REVIEW_VALIDATED_LEDGER="$EVIDENCE_ROOT/validated"
REVIEW_LAUNCHED="$EVIDENCE_ROOT/initial"
REPAIR_LAUNCHED="$EVIDENCE_ROOT/repair"
post_review_validated_evidence_complete "$POST_REVIEW_VALIDATED_LEDGER" 6 \
  "$REVIEW_LAUNCHED" "$REPAIR_LAUNCHED" "$EVIDENCE_ROOT"

evidence_must_fail() {
  local label="$1" ledger="$2" initial="$3" repair="$4" expected_class="$5"
  local diagnostic="$EVIDENCE_ROOT/$label.stderr"
  if post_review_validated_evidence_complete "$ledger" 6 "$initial" "$repair" "$EVIDENCE_ROOT" 2>"$diagnostic"; then
    echo "evidence fixture unexpectedly passed: $label" >&2
    return 1
  fi
  grep -q "class=$expected_class" "$diagnostic"
}

python3 -I -B - "$EVIDENCE_ROOT" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
def rows(name): return [json.loads(line) for line in (root/name).read_text().splitlines()]
def write(name,value): (root/name).write_text("".join(json.dumps(row,separators=(",",":"))+"\n" for row in value))
value=rows("validated"); value[-1]["index"]=1; write("duplicate-index",value)
value=rows("validated"); value[-1]["instance"]="foreign-attempt"; write("foreign-instance",value)
value=rows("validated"); value[-1]["sha256"]="0"*64; write("bad-digest",value)
initial=rows("initial"); value=rows("validated")
initial[-1]["result"]=initial[0]["result"]; value[-1]["result"]=value[0]["result"]
write("duplicate-path-initial",initial); write("duplicate-path",value)

foreign=root/"foreign"; foreign.mkdir()
child=foreign/"children"/value[-1]["instance"]; child.mkdir(parents=True)
provider=child/"result.md"; provider.write_text("foreign provider\n")
canonical=child/"validated-result.md"; payload=b"foreign validated\n"
canonical.write_bytes(payload); canonical.chmod(0o400)
(child/"status.json").write_text('{"state":"completed","exit_code":0}\n')
initial=rows("initial"); value=rows("validated")
initial[-1]["result"]=str(provider); initial[-1]["status"]=str(child/"status.json")
value[-1]["result"]=str(canonical); value[-1]["sha256"]=hashlib.sha256(payload).hexdigest()
write("foreign-path-initial",initial); write("foreign-path",value)
PY
evidence_must_fail duplicate-index "$EVIDENCE_ROOT/duplicate-index" "$REVIEW_LAUNCHED" "$REPAIR_LAUNCHED" malformed-ledger
evidence_must_fail foreign-instance "$EVIDENCE_ROOT/foreign-instance" "$REVIEW_LAUNCHED" "$REPAIR_LAUNCHED" roster-mismatch
evidence_must_fail bad-digest "$EVIDENCE_ROOT/bad-digest" "$REVIEW_LAUNCHED" "$REPAIR_LAUNCHED" digest-mismatch
evidence_must_fail duplicate-path "$EVIDENCE_ROOT/duplicate-path" "$EVIDENCE_ROOT/duplicate-path-initial" "$REPAIR_LAUNCHED" duplicate-artifact
evidence_must_fail foreign-path "$EVIDENCE_ROOT/foreign-path" "$EVIDENCE_ROOT/foreign-path-initial" "$REPAIR_LAUNCHED" unsafe-artifact

python3 -I -B - "$EVIDENCE_ROOT" <<'PY'
import hashlib,json,os,pathlib,sys
root=pathlib.Path(os.path.realpath(sys.argv[1])); index=3
rows=[json.loads(line) for line in (root/"validated").read_text().splitlines()]
child=root/"children"/"review-3-attempt02"; child.mkdir()
provider=child/"result.md"; provider.write_text("provider-owned repair\n")
canonical=child/"validated-result.md"; payload=b"validated-repair-3\n"
canonical.write_bytes(payload); canonical.chmod(0o400)
instance="review-3-attempt02"
(child/"status.json").write_text('{"state":"completed","exit_code":0}\n')
repair={"edge":rows[index-1]["edge"],"index":index,"instance":instance,"receipt":"fixture",
        "result":str(provider),"status":str(child/"status.json")}
(root/"repair-valid").write_text(json.dumps(repair,separators=(",",":"))+"\n")
rows[index-1]={"edge":repair["edge"],"index":index,"instance":instance,
               "result":str(canonical),"sha256":hashlib.sha256(payload).hexdigest()}
(root/"validated-repair").write_text("".join(json.dumps(row,separators=(",",":"))+"\n" for row in rows))
PY
post_review_validated_evidence_complete "$EVIDENCE_ROOT/validated-repair" 6 \
  "$REVIEW_LAUNCHED" "$EVIDENCE_ROOT/repair-valid" "$EVIDENCE_ROOT"

# The configured cap is enforced by the production wave runner, not merely
# mentioned in prose. Cap one and cap two both wait before the next launch
# wave, and preserve global result indices for later format repair.
(
  . "$TMP/capped-fanout-runtime.sh"
  REVIEW_EDGES=(one two three four five six)
  post_review_roster_complete() { [ "$(wc -l <"$1" | tr -d ' ')" -eq "$2" ]; }
  post_review_fanout() {
    local count
    count="$(wc -l <"$1" | tr -d ' ')"
    printf 'dispatch:%s\n' "$count" >>"$CAP_EVENTS"
    cp "$1" "$2"; cp "$1" "$3"
  }
  post_review_wait_all() {
    local count indices
    [ "$#" -eq 3 ]
    count="$(wc -l <"$1" | tr -d ' ')"
    indices="$(jq -sr 'map(.index) | join(",")' "$1")"
    printf 'wait:%s:%s\n' "$count" "$indices" >>"$CAP_EVENTS"
    : >"$3"
    POST_REVIEW_VALID_COUNT="$count"
    POST_REVIEW_FORMAT_FAILURE_COUNT=0
    POST_REVIEW_INFRA_FAILURE=0
  }
  CAP_RECORDS="$TMP/cap.records"
  for index in "${!REVIEW_EDGES[@]}"; do
    printf '{"edge":"%s","index":%d}\n' "${REVIEW_EDGES[$index]}" "$((index + 1))"
  done >"$CAP_RECORDS"
  for cap in 1 2 4; do
    CAP_EVENTS="$TMP/cap-$cap.events"; : >"$CAP_EVENTS"
    post_review_run_capped "$CAP_RECORDS" 6 "$cap" "$TMP/cap-$cap.descriptors" \
      "$TMP/cap-$cap.launched" "$TMP/cap-$cap.failed" 10 "$TMP/cap-$cap"
    if [ "$cap" -eq 1 ]; then
      printf '%s\n' dispatch:1 wait:1:1 dispatch:1 wait:1:2 dispatch:1 wait:1:3 \
        dispatch:1 wait:1:4 dispatch:1 wait:1:5 dispatch:1 wait:1:6 >"$TMP/cap.expected"
    elif [ "$cap" -eq 2 ]; then
      printf '%s\n' dispatch:2 wait:2:1,2 dispatch:2 wait:2:3,4 \
        dispatch:2 wait:2:5,6 >"$TMP/cap.expected"
    else
      printf '%s\n' dispatch:4 wait:4:1,2,3,4 dispatch:2 wait:2:5,6 \
        >"$TMP/cap.expected"
    fi
    cmp "$TMP/cap.expected" "$CAP_EVENTS"
    [ "$POST_REVIEW_VALID_COUNT" -eq 6 ]
  done
)

# Provider and exhausted format-repair failures must leave the canonical
# aggregate absent, so neither the fixer nor trust emission can run.
aggregate_gate_must_block() {
  local label="$1" blocked="$2" initial="$3" repaired="$4"
  AGG_PATH="$TMP/$label/post-impl-review-final.md"
  mkdir -p "$(dirname "$AGG_PATH")"
  : >"$AGG_PATH"
  REVIEW_WAVE_BLOCKED="$blocked"
  REVIEW_INITIAL_VALID_COUNT="$initial"
  REVIEW_REPAIR_VALID_COUNT="$repaired"
  REVIEW_EXPECTED_COUNT=6
  if post_review_require_complete_wave; then
    : >"$TMP/$label/fixer-dispatched"
    : >"$TMP/$label/trust-emitted"
  fi
  [ ! -e "$AGG_PATH" ]
  [ ! -e "$TMP/$label/fixer-dispatched" ]
  [ ! -e "$TMP/$label/trust-emitted" ]
}
aggregate_gate_must_block provider-failure 1 5 0
aggregate_gate_must_block invalid-repair 1 5 0

# Execute the production Step 4 fence, including its invocation. Incomplete
# evidence must remove a pre-existing aggregate and return before any
# downstream consumer marker can be reached.
PRODUCTION_AGG="$TMP/production-gate/post-impl-review-final.md"
PRODUCTION_DOWNSTREAM="$TMP/production-gate/downstream-reached"
mkdir -p "$(dirname "$PRODUCTION_AGG")"; : >"$PRODUCTION_AGG"
set +e
(
  set -e
  AGG_PATH="$PRODUCTION_AGG"
  REVIEW_WAVE_BLOCKED=1
  REVIEW_INITIAL_VALID_COUNT=5
  REVIEW_REPAIR_VALID_COUNT=0
  REVIEW_EXPECTED_COUNT=6
  . "$TMP/aggregate-gate-production.sh"
  : >"$PRODUCTION_DOWNSTREAM"
)
PRODUCTION_GATE_RC=$?
set -e
[ "$PRODUCTION_GATE_RC" -eq 70 ]
[ ! -e "$PRODUCTION_AGG" ]
[ ! -e "$PRODUCTION_DOWNSTREAM" ]

RESEARCH_DIR_ABS="$TMP/derived-aggregate"
mkdir -p "$RESEARCH_DIR_ABS"
: >"$RESEARCH_DIR_ABS/post-impl-review-final.md"
unset AGG_PATH
REVIEW_WAVE_BLOCKED=1
REVIEW_INITIAL_VALID_COUNT=5
REVIEW_REPAIR_VALID_COUNT=0
REVIEW_EXPECTED_COUNT=6
! post_review_require_complete_wave
[ ! -e "$RESEARCH_DIR_ABS/post-impl-review-final.md" ]

# Suppression itself is fail closed. A directory collision cannot be reported
# as a successfully suppressed stale aggregate.
AGG_PATH="$TMP/suppression-failure/post-impl-review-final.md"
mkdir -p "$AGG_PATH"
REVIEW_WAVE_BLOCKED=1
REVIEW_INITIAL_VALID_COUNT=5
REVIEW_REPAIR_VALID_COUNT=0
REVIEW_EXPECTED_COUNT=6
set +e
SUPPRESSION_ERROR="$(post_review_require_complete_wave 2>&1)"
SUPPRESSION_RC=$?
set -e
[ "$SUPPRESSION_RC" -eq 71 ]
[ -d "$AGG_PATH" ]
printf '%s\n' "$SUPPRESSION_ERROR" | grep -Fq 'failed to suppress stale post-impl-review aggregate'

# Review and simplify execute with inherited carriers. Post-review attaches to
# the exact descriptor exported by its parent review setup.
REVIEW_RUN_ID=20260710-000000-abcdef0
REVIEW_DESCRIPTOR="$(env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID="$REVIEW_RUN_ID" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
  bash -c '. "$1"; printf "%s" "$UBERDEV_COMMAND_WORKSPACE_JSON"' _ "$TMP/setup-review-pr.sh")"
env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID=20260710-000001-abcdef0 PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$SIMPLIFY_CARRIER_JSON" \
  bash "$TMP/setup-simplify.sh"
env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID="$REVIEW_RUN_ID" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
  UBERDEV_COMMAND_WORKSPACE_JSON="$REVIEW_DESCRIPTOR" CHANGED_PATHS_JSON='["README.md"]' \
  bash "$TMP/setup-post-impl-review.sh"

# Setup is a fail-closed validation boundary. Neither a standalone carrier
# preparation failure nor an invalid/spoofed inherited carrier may create the
# command-owned research directory or any artifact beneath it.
FAKE_PLUGIN="$TMP/failing-plugin"
mkdir -p "$FAKE_PLUGIN/lib"
cat >"$FAKE_PLUGIN/lib/child-dispatch.sh" <<'SH'
uberdev_prepare_run_carrier() { return 17; }
SH
setup_index=0
for spec in "$REVIEW:review-pr" "$SIMPLIFY:simplify"; do
  setup_index=$((setup_index + 1))
  doc="${spec%:*}"; name="${spec##*:}"; setup="$TMP/setup-$name.sh"

  failed_run="$(printf '20260710-0001%02d-abcdef0' "$setup_index")"
  failed_target="$TEST_REPO/.uberdev/research/$failed_run"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="$failed_run" PR_NUMBER=1 ARGUMENTS='' bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly survived carrier preparation failure: $name" >&2
    exit 1
  fi
  [ ! -e "$failed_target" ]

  invalid_run="$(printf '20260710-0002%02d-abcdef0' "$setup_index")"
  invalid_target="$TEST_REPO/.uberdev/research/$invalid_run"
  invalid_carrier="$(jq -c '.context_sha256 = ("0" * 64)' <<<"$UBERDEV_RUN_CARRIER_JSON")"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="$invalid_run" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$invalid_carrier" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted invalid inherited carrier: $name" >&2
    exit 1
  fi
  [ ! -e "$invalid_target" ]

  spoof_root="$TMP/spoof-root-$name"; mkdir -p "$spoof_root"
  spoof_target="$TEST_REPO/.uberdev/research/20260710-000030-abcdef0"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$spoof_root" \
    RUN_ID="20260710-000030-abcdef0" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted spoofed inherited repository: $name" >&2
    exit 1
  fi
  [ ! -e "$spoof_target" ]

  escaped_target="$TMP/escaped-research-$name"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="20260710-000040-abcdef0" PR_NUMBER=1 ARGUMENTS='' \
    RESEARCH_DIR_ABS="$escaped_target" UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted research path outside verified roots: $name" >&2
    exit 1
  fi
  [ ! -e "$escaped_target" ]
done

# The executable builder preflights the complete immutable batch before the
# first launch and boundedly unwinds an earlier child when a later launch fails.
sed -n '/BEGIN review-child-builder-v1/,/END review-child-builder-v1/p' "$REVIEW" \
  | sed '/BEGIN review-child-builder-v1/d;/END review-child-builder-v1/d;/^```/d' >"$TMP/builder.sh"
cat >"$TMP/lifecycle.sh" <<'SH'
set -euo pipefail
. "$1"
log="$2"; run="$3"; mkdir -p "$run"
uberdev_create_child_handoff() {
  printf 'create %s\n' "$1" >>"$log"
  UBERDEV_CHILD_HANDOFF="$run/$2.handoff"; UBERDEV_CHILD_RESULT="$run/$2.result"; UBERDEV_CHILD_STATUS="$run/$2.status"
  : >"$UBERDEV_CHILD_HANDOFF"
}
uberdev_preflight_child_batch() { printf 'preflight %s\n' "$#" >>"$log"; [ "$#" -eq 2 ]; }
uberdev_dispatch_child() { printf 'dispatch %s\n' "$1" >>"$log"; [ "$1" != second.edge ] || return 9; printf 'receipt'; }
uberdev_unwind_child() { printf 'unwind %s %s %s\n' "$1" "$2" "$3" >>"$log"; [ "$3" -gt 0 ]; }
uberdev_wait_child() { return 0; }
records="$run/records"; : >"$records"
review_child_record first.edge first-iter1-attempt01 '{}' '[]' "$records"
review_child_record second.edge second-iter1-attempt01 '{}' '[]' "$records"
if review_child_fanout "$records" "$run/descriptors" "$run/launched" 17; then exit 20; fi
SH
bash "$TMP/lifecycle.sh" "$TMP/builder.sh" "$TMP/lifecycle.log" "$TMP/lifecycle"
[ "$(grep -n '^preflight ' "$TMP/lifecycle.log" | cut -d: -f1)" -lt "$(grep -n '^dispatch ' "$TMP/lifecycle.log" | head -1 | cut -d: -f1)" ]
[ "$(grep -c '^create ' "$TMP/lifecycle.log")" -eq 2 ]
grep -q '^preflight 2$' "$TMP/lifecycle.log"
grep -Eq '^unwind .+ .+ 17$' "$TMP/lifecycle.log"

# If receipt-ledger serialization fails after dispatch returns success, the
# controller must unwind the current child first, then every prior ledgered
# child, and preserve the serialization rc even when current cleanup fails.
sed -n '/BEGIN review-child-builder-v1/,/END review-child-builder-v1/p' "$SIMPLIFY" \
  | sed '/BEGIN review-child-builder-v1/d;/END review-child-builder-v1/d;/^```/d' >"$TMP/simplify-builder.sh"
awk '/^post_review_init_ledger\(\) \{/{active=1} active && /^post_review_wait_all\(\) \{/{exit} active{print}' \
  "$POST" >"$TMP/post-builder.sh"
awk '/^post_review_init_ledger\(\) \{/{active=1} active{print} /^post_review_wait_all\(\) \{/{wait_fn=1} active && wait_fn && /^\}/{exit}' \
  "$POST" >"$TMP/post-runtime.sh"
cat >"$TMP/ledger-failure.sh" <<'SH'
set -u
runtime="$1"; fanout="$2"; flavor="$3"; run="$4"; mkdir -p "$run"
log="$run/unwind.log"; marker="$run/fail-next-ledger"; dispatches="$run/dispatches"
: >"$log"; : >"$dispatches"
REAL_PYTHON="$(command -v python3)"; REAL_JQ="$(command -v jq)"
. "$runtime"
python3() {
  local arg
  for arg in "$@"; do
    if [ -e "$marker" ] && [ "$arg" = "$run/launched" ]; then rm -f "$marker"; return 73; fi
  done
  command "$REAL_PYTHON" "$@"
}
jq() {
  if [ -e "$marker" ] && [ "${1:-}" = -cn ]; then rm -f "$marker"; return 73; fi
  command "$REAL_JQ" "$@"
}
uberdev_create_child_handoff() {
  UBERDEV_CHILD_HANDOFF="$run/$2.handoff"; UBERDEV_CHILD_RESULT="$run/$2.result"; UBERDEV_CHILD_STATUS="$run/$2.status"
  : >"$UBERDEV_CHILD_HANDOFF"
}
uberdev_preflight_child_batch() { [ "$#" -eq 2 ]; }
uberdev_dispatch_child() {
  printf '%s\n' "$1" >>"$dispatches"
  if [ "$(wc -l <"$dispatches" | tr -d ' ')" -eq 2 ]; then : >"$marker"; fi
  printf 'receipt-%s' "$1"
}
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$log"
  case "$1" in *second.status) return 9 ;; *) return 0 ;; esac
}
printf '%s\n' \
  '{"edge":"first.edge","index":1,"instance":"first","inputs":{},"risks":[]}' \
  '{"edge":"second.edge","index":2,"instance":"second","inputs":{},"risks":[]}' >"$run/records"
set +e
"$fanout" "$run/records" "$run/descriptors" "$run/launched" 29 >"$run/stdout" 2>"$run/stderr"
rc=$?
set -e
if [ "$flavor" = post ]; then
  [ "$rc" -eq 70 ]
else
  [ "$rc" -eq 73 ]
fi
[ "$(wc -l <"$log" | tr -d ' ')" -eq 2 ]
[ "$(sed -n '1p' "$log")" = "$run/second.status	$run/second.result	29" ]
[ "$(sed -n '2p' "$log")" = "$run/first.status	$run/first.result	29" ]
if [ "$flavor" = post ]; then
  grep -Fq 'cleanup: edge=second.edge' "$run/stderr"
  grep -Fq "status=$run/second.status" "$run/stderr"
  grep -Fq 'origin_rc=73' "$run/stderr"
  grep -Fq 'cleanup_rc=9' "$run/stderr"
else
  grep -q 'current child cleanup failed' "$run/stderr"
fi
SH
bash "$TMP/ledger-failure.sh" "$TMP/builder.sh" review_child_fanout review "$TMP/ledger-review"
bash "$TMP/ledger-failure.sh" "$TMP/simplify-builder.sh" review_child_fanout simplify "$TMP/ledger-simplify"
bash "$TMP/ledger-failure.sh" "$TMP/post-builder.sh" post_review_fanout post "$TMP/ledger-post"

# Wait failures are drained current-by-current without abandoning later
# receipts. Preserve the first wait rc even when a cleanup fails.
cat >"$TMP/wait-ledger-failure.sh" <<'SH'
set -u
runtime="$1"; wait_all="$2"; run="$3"; flavor="$4"; mkdir -p "$run"
wait_log="$run/wait.log"; unwind_log="$run/unwind.log"; : >"$wait_log"; : >"$unwind_log"
. "$runtime"
if [ "$flavor" = post ]; then
  CHANGED_PATHS_JSON='["README.md"]'
  POST_REVIEW_VALIDATED_LEDGER="$run/validated"
  : >"$POST_REVIEW_VALIDATED_LEDGER"
fi
uberdev_wait_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$wait_log"
  case "$1" in *wait-fail-first.status) return 7 ;; *wait-fail-second.status) return 8 ;; *) return 0 ;; esac
}
# This fixture exercises wait-drain ordering only; reviewer-result validation
# has its own behavioral coverage in the six-child integration test.
uberdev_child_validate_phase1_review_result() {
  if [ -n "${3:-}" ]; then rm -f "$3"; printf 'validated fixture\n' >"$3"; chmod 400 "$3"; printf '%064d' 0; fi
  return 0
}
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$unwind_log"
  case "$1" in *wait-fail-first.status) return 9 ;; *) return 0 ;; esac
}
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"index\":1,\"instance\":\"first\",\"status\":\"$run/ok.status\",\"result\":\"$run/ok.result\"}" \
  "{\"edge\":\"second.edge\",\"index\":2,\"instance\":\"second\",\"status\":\"$run/wait-fail-first.status\",\"result\":\"$run/wait-fail-first.result\"}" \
  "{\"edge\":\"third.edge\",\"index\":3,\"instance\":\"third\",\"status\":\"$run/wait-fail-second.status\",\"result\":\"$run/wait-fail-second.result\"}" >"$run/launched"
unset FAILED_REVIEW_EDGE FAILED_REVIEW_INDEX
set +e
if [ "$flavor" = post ]; then
  "$wait_all" "$run/launched" 31 "$run/failed" >"$run/stdout" 2>"$run/stderr"
else
  "$wait_all" "$run/launched" 31 >"$run/stdout" 2>"$run/stderr"
fi
rc=$?
set -e
[ "$rc" -eq 7 ]
[ "$(wc -l <"$wait_log" | tr -d ' ')" -eq 3 ]
[ "$(wc -l <"$unwind_log" | tr -d ' ')" -eq 2 ]
[ "$(sed -n '1p' "$unwind_log")" = "$run/wait-fail-first.status	$run/wait-fail-first.result	31" ]
[ "$(sed -n '2p' "$unwind_log")" = "$run/wait-fail-second.status	$run/wait-fail-second.result	31" ]
grep -q 'cleanup failed after child wait' "$run/stderr"
if [ "$flavor" = post ]; then
  [ ! -s "$run/failed" ]
fi
SH
bash "$TMP/wait-ledger-failure.sh" "$TMP/builder.sh" review_child_wait_all "$TMP/wait-review" review
bash "$TMP/wait-ledger-failure.sh" "$TMP/simplify-builder.sh" review_child_wait_all "$TMP/wait-simplify" simplify
bash "$TMP/wait-ledger-failure.sh" "$TMP/post-runtime.sh" post_review_wait_all "$TMP/wait-post" post

# Only invalid output from a successfully terminal-and-unwound child enters the
# format-repair ledger. Lifecycle failures above remain unrepairable even when
# another failed row could otherwise make the ledger nonempty.
cat >"$TMP/format-repair-ledger.sh" <<'SH'
set -u
runtime="$1"; run="$2"; mkdir -p "$run"
. "$runtime"
CHANGED_PATHS_JSON='["README.md"]'
POST_REVIEW_VALIDATED_LEDGER="$run/validated"
: >"$POST_REVIEW_VALIDATED_LEDGER"
uberdev_wait_child() { return 0; }
uberdev_child_validate_phase1_review_result() {
  case "$1" in *invalid.result) return 2 ;; esac
  rm -f "$3"; printf 'validated fixture\n' >"$3"; chmod 400 "$3"; printf '%064d' 0
}
uberdev_unwind_child() { return 0; }
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"index\":1,\"instance\":\"first\",\"status\":\"$run/first.status\",\"result\":\"$run/first.result\"}" \
  "{\"edge\":\"second.edge\",\"index\":2,\"instance\":\"second\",\"status\":\"$run/second.status\",\"result\":\"$run/invalid.result\"}" \
  "{\"edge\":\"third.edge\",\"index\":3,\"instance\":\"third\",\"status\":\"$run/third.status\",\"result\":\"$run/third.result\"}" >"$run/launched"
set +e
post_review_wait_all "$run/launched" 31 "$run/failed"
rc=$?
set -e
[ "$rc" -eq 1 ]
[ "$POST_REVIEW_VALID_COUNT" -eq 2 ]
[ "$POST_REVIEW_FORMAT_FAILURE_COUNT" -eq 1 ]
python3 -I -B - "$run/failed" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8') if line.strip()]
assert [(row['edge'],row['index']) for row in rows]==[('second.edge',2)],rows
PY

real_jq="$(command -v jq)"; ledger_writes=0
jq() {
  case " $* " in
    *' --argjson index '*)
      ledger_writes=$((ledger_writes + 1))
      [ "$ledger_writes" -ne 2 ] || return 1
      ;;
  esac
  command "$real_jq" "$@"
}
uberdev_child_validate_phase1_review_result() { return 2; }
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"index\":1,\"instance\":\"first\",\"status\":\"$run/first.status\",\"result\":\"$run/first.result\"}" \
  "{\"edge\":\"second.edge\",\"index\":2,\"instance\":\"second\",\"status\":\"$run/second.status\",\"result\":\"$run/second.result\"}" >"$run/ledger-failure.launched"
set +e
post_review_wait_all "$run/ledger-failure.launched" 31 "$run/ledger-failure.failed"
rc=$?
set -e
[ "$rc" -eq 1 ]
[ "$POST_REVIEW_INFRA_FAILURE" -eq 1 ]
[ "$(wc -l <"$run/ledger-failure.failed" | tr -d ' ')" -eq 1 ]
SH
bash "$TMP/format-repair-ledger.sh" "$TMP/post-runtime.sh" "$TMP/format-repair-post"

# Once reviewer output has passed validation, failure to persist its digest is
# infrastructure failure. It must unwind the child without entering the
# format-repair ledger or incrementing the format-failure count.
cat >"$TMP/validated-ledger-failure.sh" <<'SH'
set -u
runtime="$1"; run="$2"; mkdir -p "$run"
. "$runtime"
CHANGED_PATHS_JSON='["README.md"]'
POST_REVIEW_VALIDATED_LEDGER="$run/validated"
: >"$POST_REVIEW_VALIDATED_LEDGER"
unwind_log="$run/unwind"
: >"$unwind_log"
uberdev_wait_child() { return 0; }
uberdev_child_validate_phase1_review_result() {
  rm -f "$3"; printf 'validated fixture\n' >"$3"; chmod 400 "$3"; printf '%064d' 0
}
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$unwind_log"
  return 0
}
real_jq="$(command -v jq)"
jq() {
  case " $* " in
    *' --arg sha256 '*) return 73 ;;
  esac
  command "$real_jq" "$@"
}
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"index\":1,\"instance\":\"first\",\"status\":\"$run/first.status\",\"result\":\"$run/first.result\"}" \
  >"$run/launched"
set +e
post_review_wait_all "$run/launched" 31 "$run/failed"
rc=$?
set -e
[ "$rc" -eq 73 ]
[ "$POST_REVIEW_INFRA_FAILURE" -eq 1 ]
[ "$POST_REVIEW_VALID_COUNT" -eq 0 ]
[ "$POST_REVIEW_FORMAT_FAILURE_COUNT" -eq 0 ]
[ ! -s "$run/failed" ]
[ "$(wc -l <"$unwind_log" | tr -d ' ')" -eq 1 ]
SH
bash "$TMP/validated-ledger-failure.sh" "$TMP/post-runtime.sh" "$TMP/validated-ledger-post"

# A validated-result publication I/O failure is also infrastructure failure,
# not malformed reviewer output eligible for a format repair.
cat >"$TMP/validated-publication-failure.sh" <<'SH'
set -u
runtime="$1"; run="$2"; mkdir -p "$run"
. "$runtime"
CHANGED_PATHS_JSON='["README.md"]'
POST_REVIEW_VALIDATED_LEDGER="$run/validated"; : >"$POST_REVIEW_VALIDATED_LEDGER"
unwind_log="$run/unwind"; : >"$unwind_log"
uberdev_wait_child() { return 0; }
uberdev_child_validate_phase1_review_result() { return 74; }
uberdev_unwind_child() { printf '%s\n' "$1" >>"$unwind_log"; return 0; }
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"index\":1,\"instance\":\"first\",\"status\":\"$run/first.status\",\"result\":\"$run/first.result\"}" \
  >"$run/launched"
set +e
post_review_wait_all "$run/launched" 31 "$run/failed"
rc=$?
set -e
[ "$rc" -eq 74 ]
[ "$POST_REVIEW_INFRA_FAILURE" -eq 1 ]
[ "$POST_REVIEW_VALID_COUNT" -eq 0 ]
[ "$POST_REVIEW_FORMAT_FAILURE_COUNT" -eq 0 ]
[ ! -s "$run/failed" ]
[ "$(wc -l <"$unwind_log" | tr -d ' ')" -eq 1 ]
SH
bash "$TMP/validated-publication-failure.sh" "$TMP/post-runtime.sh" "$TMP/validated-publication-post"

grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$REVIEW"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$SIMPLIFY"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$POST"
grep -q 'REVIEW_WAIT_RC.*-ne 1' "$POST"
[ "$(grep -c 'post_review_run_capped "' "$POST")" -eq 2 ]
grep -q 'post_review_roster_complete "$REVIEW_LAUNCHED" "$REVIEW_EXPECTED_COUNT"' "$POST"
! grep -En "wait_child .* 0|IFS='\\|'|additional_focus|brief_path|lens_index" "$REVIEW" "$SIMPLIFY" "$POST"
! grep -En 'format_repair' "$POST"
grep -Eq 'format_retry' "$POST"

echo 'review-child-handoff: PASS'
