# plugins/uberdev/lib/dispatch.sh
#
# Dispatch-backend abstraction for /solve, /turbo, and routed /review-pr children
# (RFC 0004; review supervision extended by RFC 0012).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_dispatch_preflight                        -> resolves auto -> concrete backend
#   uberdev_dispatch_preflight_backend BACKEND FLOW   -> validates workflow/provider support
#   uberdev_dispatch_resolve_env                      -> sets the 6 dispatch-env vars; call after preflight
#   uberdev_dispatch_one  ISSUE_NUM TIER PROMPT_FILE  -> dispatch one issue
# Internal:
#   _uberdev_dispatch_wezterm / _uberdev_dispatch_background
#
# Sourced by:
#   - skills/solve-pipeline/SKILL.md Step 5b
#   - skills/goal-pipeline/SKILL.md Phase 0
#   - commands/review-pr.md executable setup and routed child adapter
#   - tests/dispatch-fallback.test.sh, dispatch-background.test.sh,
#     dispatch-wezterm.test.sh
#
# All variable expansions are double-quoted (mirrors lib/config-read.sh discipline).
# Source-time idempotent: the guard below makes repeat `source` calls cheap.

if [ "${_UBERDEV_DISPATCH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# The instrumented adapter is the sole detached-provider entry point.  Keep
# provider arms in this file so their mature argv/timeout behavior remains
# local and regression-testable.
_uberdev_dispatch_source_path() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    return 1
  fi
}
_UBERDEV_DISPATCH_FILE="$(_uberdev_dispatch_source_path)" || return 1
case "$_UBERDEV_DISPATCH_FILE" in
  */*) _UBERDEV_DISPATCH_LIB_DIR="${_UBERDEV_DISPATCH_FILE%/*}" ;;
  *) _UBERDEV_DISPATCH_LIB_DIR='.' ;;
esac
_UBERDEV_DISPATCH_LIB_DIR="$(cd "$_UBERDEV_DISPATCH_LIB_DIR" 2>/dev/null && pwd -P)"
# The plugin root is derived from this file's own location, NOT from
# CLAUDE_PLUGIN_ROOT/PLUGIN_ROOT. The workflow-engine probe below asks "can the
# install I was loaded from actually run this fleet?", and an env var set by a
# different install would answer for the wrong tree.
_UBERDEV_DISPATCH_PLUGIN_ROOT="${_UBERDEV_DISPATCH_LIB_DIR%/*}"
# shellcheck source=/dev/null
. "$_UBERDEV_DISPATCH_LIB_DIR/agent-dispatch.sh" || return 1
# shellcheck source=/dev/null
. "$_UBERDEV_DISPATCH_LIB_DIR/config-read.sh" || return 1
_UBERDEV_DISPATCH_LOADED=1

# A provider-managed worktree may finish its final git worktree unlock at the
# same time as the dispatching supervisor starts cleanup. Retry only transient
# Git metadata/probe failures (rc2); preservation decisions (rc3) are terminal.
# Shared by every dispatcher-owned worktree teardown, not just one backend's.
_UBERDEV_DISPATCH_CLEANUP_MAX_ATTEMPTS=3
_UBERDEV_DISPATCH_CLEANUP_RETRY_DELAY_1_S=0.05
_UBERDEV_DISPATCH_CLEANUP_RETRY_DELAY_2_S=0.10
# The long-poll / ownerless-generation reclaim budget that used to live here
# existed for ONE caller: the synchronous `claude --bg --worktree` bootstrap,
# which could legitimately own the repository metadata mutex for its whole
# provider timeout. That backend is gone (RFC 0015 §7), so every remaining
# caller is an ordinary short Git transaction served by the semaphore's own
# default acquisition policy.

_uberdev_dispatch_resolve_python() {
  local candidate='' prefix='' candidate_dir candidate_base
  if [ -n "${_UBERDEV_PYTHON_EXE:-}" ]; then
    case "${_UBERDEV_PYTHON_PREFIX:-}" in
      ''|-3) candidate="$_UBERDEV_PYTHON_EXE"; prefix="${_UBERDEV_PYTHON_PREFIX:-}" ;;
    esac
  fi
  if [ -z "$candidate" ]; then
    if command -v python3 >/dev/null 2>&1; then
      candidate="$(command -v python3)"; prefix=''
    elif command -v python >/dev/null 2>&1; then
      candidate="$(command -v python)"; prefix=''
    elif command -v py >/dev/null 2>&1; then
      candidate="$(command -v py)"; prefix='-3'
    else
      echo 'error: Python 3 is required (tried python3, python, and py -3)' >&2
      return 127
    fi
  fi
  case "$candidate" in
    /*|[A-Za-z]:[\\/]*) ;;
    *)
      candidate_dir="${candidate%/*}"
      [ "$candidate_dir" != "$candidate" ] || candidate_dir='.'
      candidate_base="${candidate##*/}"
      candidate_dir="$(cd "$candidate_dir" 2>/dev/null && pwd -P)" || {
        echo 'error: resolved Python launcher directory is unavailable' >&2
        return 127
      }
      candidate="$candidate_dir/$candidate_base"
      ;;
  esac
  if [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then
    echo 'error: resolved Python launcher is not an executable file' >&2
    return 127
  fi
  _UBERDEV_PYTHON_EXE="$candidate"
  _UBERDEV_PYTHON_PREFIX="$prefix"
}

_uberdev_dispatch_python() {
  _uberdev_dispatch_resolve_python || return $?
  if [ -n "$_UBERDEV_PYTHON_PREFIX" ]; then
    "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$@"
  else
    "$_UBERDEV_PYTHON_EXE" "$@"
  fi
}

# live-semaphore.sh also serves standalone callers. Inside dispatch, route every
# semaphore Python operation through the already-validated executable argv.
_uberdev_semaphore_python() {
  _uberdev_dispatch_python "$@"
}

# Convert one absolute shell path only when it crosses from Git Bash into a
# native Windows consumer. Keep all other pane argv in POSIX spelling: the
# spawned Git Bash owns those arguments and understands them directly.
_uberdev_dispatch_native_cli_path() {
  # `target`, NEVER `path`: zsh TIES the lowercase `path` array to $PATH, so a
  # `local path=` replaces the command search path for this whole call frame
  # and both `command -v cygpath` and `cygpath` become not-found. Same rule as
  # lib/status.sh:78-84, now enforced across every plugin library by
  # tests/crossplatform-shell-wrappers.test.sh instead of for status.sh alone.
  local target="$1"
  case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
    MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
      if ! command -v cygpath >/dev/null 2>&1; then
        echo 'error: cygpath is required to normalize a native-Windows dispatch path' >&2
        return 127
      fi
      cygpath -m "$target"
      ;;
    *) printf '%s' "$target" ;;
  esac
}

# Return a validated runtime root. The default lives below the platform temp
# root; POSIX creates or validates an EUID-owned, non-symlink directory locked
# to 0700. Native Windows relies on the current-user ACL only when this helper
# creates the default directory; a pre-existing default or caller override is
# checked for directory and ordinary-link safety but is not asserted private
# here. Reparse-aware artifact boundaries live in
# child-receipts.py:is_link_or_reparse, run_manifest.py:_secure_open_regular,
# and worktree_receipts.py:_is_link_or_reparse.
_uberdev_dispatch_runtime_root() {
  local target
  if [ -n "${UBERDEV_TMPDIR:-}" ]; then
    target="$UBERDEV_TMPDIR"
  else
    target="${TMPDIR:-/tmp}/uberdev-$(id -u 2>/dev/null || printf '0')"
  fi
  _uberdev_dispatch_python -I -B - "$target" <<'PY'
import os,stat,sys
path=os.path.abspath(os.path.expanduser(sys.argv[1]))
uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
display=repr(path[:512]+("..." if len(path)>512 else ""))
def reject(reason):
 print(f"error: unsafe runtime root ({reason}): {display}",file=sys.stderr)
 raise SystemExit(2)
try: os.mkdir(path,0o700)
except FileExistsError: pass
except OSError: reject("create-failed")
try: entry=os.lstat(path)
except OSError: reject("inspect-failed")
if stat.S_ISLNK(entry.st_mode): reject("symlink")
if not stat.S_ISDIR(entry.st_mode): reject("not-directory")
if uid is not None and entry.st_uid!=uid: reject("owner-mismatch")
if os.name!="nt":
 try: os.chmod(path,0o700)
 except OSError: reject("permission-update-failed")
print(os.path.realpath(path),end="")
PY
}

# Stable, branch-safe child identity. The readable prefix preserves the fanout
# instance at a glance; the digest disambiguates normalized prefixes and makes
# accidental collisions after truncation negligibly likely.
_uberdev_dispatch_instance_slug() {
  _uberdev_dispatch_python -I -B - "${UBERDEV_AGENT_INSTANCE_ID:-root}" <<'PY'
import hashlib,re,sys
raw=sys.argv[1]
prefix=re.sub(r"[^A-Za-z0-9]+","-",raw).strip("-").lower()[:40] or "agent"
print(f"{prefix}-{hashlib.sha256(raw.encode()).hexdigest()[:12]}",end="")
PY
}

# All worktrees of one repository share the same Git metadata directory. Git
# protects individual files, but sibling add/remove/branch-delete sequences are
# multi-command transactions and must not interleave. Keep one ownership-safe,
# process-reclaimable mutex below the canonical common directory so separate
# review runs and linked worktrees serialize the same metadata surface.
_uberdev_dispatch_git_metadata_mutex_scope() {
  local repo_root="$1" common_arg common_dir
  common_arg="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || return 2
  common_dir="$(_uberdev_dispatch_python -I -B - "$repo_root" "$common_arg" <<'PY'
import os,stat,sys
repo,common=sys.argv[1:]
candidate=common if os.path.isabs(common) else os.path.join(repo,common)
path=os.path.realpath(candidate)
try: entry=os.lstat(path)
except OSError: raise SystemExit(2)
uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
if not stat.S_ISDIR(entry.st_mode) or (uid is not None and entry.st_uid!=uid): raise SystemExit(2)
print(path,end="")
PY
)" || return 2
  _uberdev_semaphore_prepare_scope "$common_dir/.uberdev-worktree-metadata-locks" \
    "$common_dir" git-worktree-metadata
}

# Every remaining metadata transaction (worktree add, child-worktree
# cleanup) is a short synchronous Git command, so the semaphore's own default
# acquisition policy is the whole protocol. The long-poll + ownerless-generation
# reclaim path this used to carry was reachable ONLY from the `claude-bootstrap`
# phase, which no longer exists (RFC 0015 §7): it was there because a detached
# `claude --bg --worktree` bootstrap could hold the mutex for its full provider
# timeout, and nothing else ever asked for a wait budget that long.
_uberdev_dispatch_git_metadata_mutex_acquire() {
  _uberdev_semaphore_mutex_acquire "$1"
}

_uberdev_dispatch_with_git_metadata_mutex() {
  local repo_root="$1" phase="$2" scope rc release_rc
  shift 2
  [ "$#" -gt 0 ] || return 2
  case "$phase" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  scope="$(_uberdev_dispatch_git_metadata_mutex_scope "$repo_root")" || return 2
  (
    _uberdev_dispatch_git_metadata_mutex_acquire "$scope" || exit $?
    trap '_uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true' EXIT
    "$@"
    rc=$?
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1
    release_rc=$?
    [ "$release_rc" -eq 0 ] \
      || printf 'uberdev git metadata mutex: release failed after transaction\n' >&2 \
      || true
    [ "$release_rc" -eq 0 ] || [ "$rc" -ne 0 ] || rc=2
    [ "$release_rc" -ne 0 ] || trap - EXIT
    exit "$rc"
  )
}

# _uberdev_dispatch_git_worktree_add_locked REPO_ROOT TARGET BRANCH LOG_FILE [START_POINT]
# START_POINT is optional and additive: when supplied the new worktree is
# pinned to that exact commit, which is what makes the child teardown's
# "HEAD has not moved" preservation guard decidable. Omitting it keeps the
# historical "branch from current HEAD" behaviour for callers that own their
# worktree for the whole session and never tear it down.
_uberdev_dispatch_git_worktree_add_locked() {
  local repo_root="$1" target="$2" branch="$3" log_file="$4" start_point="${5:-}" native_target
  native_target="$(_uberdev_dispatch_native_cli_path "$target")" || return $?
  cd "$repo_root" || return 2
  if [ -n "$start_point" ]; then
    MSYS_NO_PATHCONV=1 git worktree add "$native_target" -b "$branch" "$start_point" >"$log_file" 2>&1
  else
    MSYS_NO_PATHCONV=1 git worktree add "$native_target" -b "$branch" >"$log_file" 2>&1
  fi
}

_uberdev_dispatch_git_worktree_add() {
  local repo_root="$1"
  _uberdev_dispatch_with_git_metadata_mutex "$repo_root" worktree-add \
    _uberdev_dispatch_git_worktree_add_locked "$@"
}

_uberdev_dispatch_classify_worktree_registry() {
  local repo_root="$1" target="$2" branch="$3" listing classified
  listing="$(cd "$repo_root" && git worktree list --porcelain)" || return 2
  classified="$(_uberdev_dispatch_python -I -B - "$target" "$branch" "$listing" <<'PY'
import os,sys
target,branch,raw=sys.argv[1:]
expected_ref="refs/heads/"+branch
records=[]
for block in raw.split("\n\n"):
 if not block: continue
 lines=block.splitlines()
 if not lines or not lines[0].startswith("worktree "): raise SystemExit(2)
 path=lines[0][9:]
 refs=[line[7:] for line in lines[1:] if line.startswith("branch ")]
 if len(refs)>1: raise SystemExit(2)
 records.append((path,refs[0] if refs else ""))
key=lambda value: os.path.normcase(os.path.normpath(value))
exact=[record for record in records if key(record[0])==key(target)]
if len(exact)>1: raise SystemExit(2)
exact_state="absent" if not exact else ("expected" if exact[0][1]==expected_ref else "wrong")
branch_state="present" if any(ref==expected_ref for _,ref in records) else "absent"
print(exact_state+"\t"+branch_state,end="")
PY
)" || return 2
  _UBERDEV_DISPATCH_REGISTRY_EXACT="${classified%%$'\t'*}"
  _UBERDEV_DISPATCH_REGISTRY_BRANCH="${classified#*$'\t'}"
  case "$_UBERDEV_DISPATCH_REGISTRY_EXACT:$_UBERDEV_DISPATCH_REGISTRY_BRANCH" in
    absent:absent|absent:present|expected:present|wrong:absent|wrong:present) ;;
    *) return 2 ;;
  esac
}

_uberdev_dispatch_validate_worktree_directory() {
  _uberdev_dispatch_python -I -B - "$1" <<'PY'
import os,stat,sys
path=sys.argv[1]
try: entry=os.lstat(path)
except OSError: raise SystemExit(2)
uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
reparse=getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0x400)
if (os.path.islink(path) or stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode)
    or bool(getattr(entry,"st_file_attributes",0)&reparse)
    or (uid is not None and entry.st_uid!=uid)): raise SystemExit(3)
PY
}

# _uberdev_dispatch_cleanup_child_worktree_locked REPO_ROOT RELATIVE BRANCH START_HEAD TERMINAL
#
# Backend-neutral teardown for a DISPATCHER-OWNED, CHILD-OWNED, isolated
# worktree (#381 RULING 4). Removes the worktree and its branch once the child
# reaches a terminal state — or, through `_uberdev_dispatch_fail_after_worktree`
# and its own `setup_failed` terminal, once the DISPATCHER gives up before any
# child could start — and refuses — loudly, with a distinct rc — whenever
# removing would destroy work or the on-disk state no longer matches what the
# dispatcher created.
#
# START_HEAD is the creation authority: the dispatcher captures the repository
# HEAD before it creates anything, pins the worktree to it, and threads it to
# the child through the child's own launch argv. Everything downstream of that
# authority — registry classification, symlink/ownership validation, the
# clean-tree and unmoved-HEAD preservation guards, the post-removal absence
# re-verification — is what actually keeps a teardown from deleting someone's
# work. (This replaced the retired codex arm's on-disk receipt transaction,
# which carried the same authority in a crash-safe file; #381 RULING 4.)
#
# rc 0  worktree and branch are gone (or were already gone).
# rc 2  transient/unexpected Git or filesystem failure — the caller retries.
# rc 3  PRESERVE: the state does not match what we created, or the worktree
#       holds work. Nothing was removed. This is a REPORTABLE outcome, never a
#       silent success.
_uberdev_dispatch_cleanup_child_worktree_locked() {
  local repo_root="$1" relative="$2" branch="$3" start_head="$4" terminal="$5"
  local target branch_exists=0 show_ref_rc branch_head local_status target_head native_target
  # `setup_failed` is this cleanup path's own extra arm, not a manifest
  # terminal status, so it is declared rather than smuggled in. Its caller is
  # `_uberdev_dispatch_fail_after_worktree` — the dispatcher-side door.
  # CONTRACT: run-terminal-status +setup_failed !case-arm
  case "$terminal" in completed|failed|timed_out|cancelled|setup_failed) ;; *) return 3 ;; esac
  case "$start_head" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 3 ;;
  esac
  [ -n "$relative" ] && [ -n "$branch" ] || return 3
  target="$(_uberdev_dispatch_python -I -B -c \
    'import os,sys; print(os.path.abspath(os.path.join(os.path.realpath(sys.argv[1]),*sys.argv[2].split("/"))),end="")' \
    "$repo_root" "$relative")" || return 2

  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    branch_exists=1
    branch_head="$(git -C "$repo_root" rev-parse "refs/heads/$branch")" || return 2
    # The child committed. Deleting the branch would drop those commits on the
    # floor, so preserve and report instead.
    [ "$branch_head" = "$start_head" ] || return 3
  else
    show_ref_rc=$?
    [ "$show_ref_rc" -eq 1 ] || return 2
  fi
  _uberdev_dispatch_classify_worktree_registry "$repo_root" "$target" "$branch" || return $?
  case "$_UBERDEV_DISPATCH_REGISTRY_EXACT:$_UBERDEV_DISPATCH_REGISTRY_BRANCH" in
    expected:present) [ "$branch_exists" -eq 1 ] || return 3 ;;
    absent:absent) ;;
    *) return 3 ;;
  esac
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ "$_UBERDEV_DISPATCH_REGISTRY_EXACT" = expected ] || return 3
    _uberdev_dispatch_validate_worktree_directory "$target" || return $?
    local_status="$(git -C "$target" status --porcelain --untracked-files=all)" || return 2
    [ -z "$local_status" ] || return 3
    target_head="$(git -C "$target" rev-parse HEAD)" || return 2
    [ "$target_head" = "$start_head" ] || return 3
  fi
  if [ "$_UBERDEV_DISPATCH_REGISTRY_EXACT" = expected ]; then
    native_target="$(_uberdev_dispatch_native_cli_path "$target")" || return 2
    cd "$repo_root" || return 2
    MSYS_NO_PATHCONV=1 git worktree remove --force "$native_target" || return 2
  fi
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 2
  _uberdev_dispatch_classify_worktree_registry "$repo_root" "$target" "$branch" || return $?
  [ "$_UBERDEV_DISPATCH_REGISTRY_EXACT" = absent ] \
    && [ "$_UBERDEV_DISPATCH_REGISTRY_BRANCH" = absent ] || return 2
  if [ "$branch_exists" -eq 1 ]; then
    branch_head="$(git -C "$repo_root" rev-parse "refs/heads/$branch")" || return 2
    [ "$branch_head" = "$start_head" ] || return 3
    cd "$repo_root" || return 2
    git branch -D "$branch" >/dev/null || return 2
  fi
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    return 2
  else
    show_ref_rc=$?
    [ "$show_ref_rc" -eq 1 ] || return 2
  fi
  return 0
}

# _uberdev_dispatch_cleanup_child_worktree REPO_ROOT RELATIVE BRANCH START_HEAD TERMINAL
# Mutex-serialized, transient-retrying wrapper around the locked transaction
# above. Same rc vocabulary.
_uberdev_dispatch_cleanup_child_worktree() {
  local repo_root="$1" scope rc release_rc attempt=1 retry_delay
  scope="$(_uberdev_dispatch_git_metadata_mutex_scope "$repo_root")" || return 2
  (
    _uberdev_semaphore_mutex_acquire "$scope" || exit $?
    trap '_uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true' EXIT
    while :; do
      if _uberdev_dispatch_cleanup_child_worktree_locked "$@"; then rc=0; else rc=$?; fi
      if [ "$rc" -ne 2 ] || [ "$attempt" -ge "$_UBERDEV_DISPATCH_CLEANUP_MAX_ATTEMPTS" ]; then
        break
      fi
      case "$attempt" in
        1) retry_delay="$_UBERDEV_DISPATCH_CLEANUP_RETRY_DELAY_1_S" ;;
        2) retry_delay="$_UBERDEV_DISPATCH_CLEANUP_RETRY_DELAY_2_S" ;;
        *) rc=2; break ;;
      esac
      printf 'uberdev child worktree cleanup: transient attempt %s/%s; retrying in %ss\n' \
        "$attempt" "$_UBERDEV_DISPATCH_CLEANUP_MAX_ATTEMPTS" "$retry_delay" >&2
      sleep "$retry_delay" || { rc=2; break; }
      attempt=$((attempt + 1))
    done
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1
    release_rc=$?
    [ "$release_rc" -eq 0 ] \
      || printf 'uberdev child worktree cleanup: mutex release failed after cleanup transaction\n' >&2 \
      || true
    [ "$release_rc" -eq 0 ] || [ "$rc" -ne 0 ] || rc=2
    [ "$release_rc" -ne 0 ] || trap - EXIT
    exit "$rc"
  )
}

# _uberdev_dispatch_fail_after_worktree ISSUE BACKEND PHASE SETUP_RC \
#                                       REPO_ROOT RELATIVE BRANCH START_HEAD CHILD_OWNED
#
# The DISPATCHER-side twin of the wrapper's `cleanup_child_worktree` (#381
# RULING 4). The wrapper's teardown only covers a child that actually started;
# every setup/launch failure BETWEEN a successful `git worktree add` and a
# running child is on this side of the fence, and before this helper existed
# each of those paths returned while the worktree and its branch stayed on
# disk. The leaked path derives purely from ISSUE_NUM, so the leak also blocks
# the next dispatch of the same issue — it does not merely accumulate.
#
# `setup_failed` is exactly the extra terminal this cleanup path declares at
# `_uberdev_dispatch_cleanup_child_worktree_locked`; the same preservation
# guards apply, so a worktree the child already dirtied is refused (rc 3), not
# destroyed. Cleanup failure is REPORTED — stderr + a `dispatch_cleanup_failed`
# audit naming the worktree and branch — and folded into the returned rc as 74.
# It is never swallowed into the plain setup rc.
#
# Emits the caller's `dispatch_setup_failed` audit first so the phase record is
# written even if the teardown itself then fails.
#
# rc SETUP_RC  the setup failure stands, and nothing was left behind.
# rc 74        the setup failure stands AND the worktree could not be removed.
_uberdev_dispatch_fail_after_worktree() {
  local issue="$1" backend="$2" phase="$3" setup_rc="$4"
  local repo_root="$5" relative="$6" branch="$7" start_head="$8" child_owned="$9"
  local cleanup_rc=0
  _uberdev_dispatch_audit dispatch_setup_failed \
    "{\"issue\":$issue,\"phase\":\"$phase\",\"backend\":\"$backend\",\"rc\":$setup_rc}"
  # CHILD_OWNED=0 is a top-level /solve dispatch: that worktree IS the operator's
  # deliverable workspace and survives a failed launch on purpose.
  [ "$child_owned" = "1" ] || return "$setup_rc"
  _uberdev_dispatch_cleanup_child_worktree \
    "$repo_root" "$relative" "$branch" "$start_head" setup_failed || cleanup_rc=$?
  [ "$cleanup_rc" -eq 0 ] || {
    printf '%s dispatch: failed to clean child worktree %s (%s) after %s setup failure\n' \
      "$backend" "$repo_root/$relative" "$branch" "$phase" >&2
    _uberdev_dispatch_audit dispatch_cleanup_failed \
      "{\"issue\":$issue,\"phase\":\"$phase\",\"backend\":\"$backend\",\"rc\":$cleanup_rc,\"worktree\":\"$repo_root/$relative\",\"branch\":\"$branch\"}"
    return 74
  }
  return "$setup_rc"
}

# The dispatch_backend enum — identical to the --backend= flag's accepted set.
# `workflow` is the DEFAULT (RFC 0015): the per-issue solver fleet runs inside
# the main session's Workflow runtime (skills/solve-fleet/workflow.js), so this
# library never spawns anything for it — the launcher emits the args envelope
# and the command file mandates the Workflow call.
# The `codex` backend is GONE (#381). It was the OpenAI Codex CLI transport
# (RFC 0012 §3.4 codex-port) and the last consumer of the codex-keyed routing
# catalog; the Codex distribution it served was retired first, and nothing on
# any default path resolved it once /review-pr and /simplify took `workflow`.
#
# The detached `claude --bg` backend is GONE (RFC 0015 §7 as amended). It was
# deprecated when `workflow` shipped for /solve, /turbo and /goal, and removed
# once /review-pr and /simplify resolved `workflow` too — at which point nothing
# on any default path could reach it and no workflow still required it. There is
# deliberately no deprecation shim left behind: a dormant alias is how a retired
# transport drifts back onto a default path. Naming it now fails the enum check
# below, loudly, listing the accepted set.
# CONTRACT: dispatch-backend
_UBERDEV_DISPATCH_BACKEND_ENUM='auto|workflow|wezterm|background'

# _uberdev_dispatch_os_class -> prints one of: macos | windows-native | wsl2 | linux
# WSL2 is detected via /proc/version containing "microsoft" (case-insensitive);
# native Windows via $OS=Windows_NT with no WSL marker; macOS via uname.
_uberdev_dispatch_os_class() {
  local _uname
  _uname="$(uname -s 2>/dev/null)"
  case "$_uname" in
    Darwin) printf 'macos'; return 0 ;;
  esac
  if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    printf 'wsl2'; return 0
  fi
  case "${OS:-}" in
    Windows_NT) printf 'windows-native'; return 0 ;;
  esac
  case "$_uname" in
    MINGW*|MSYS*|CYGWIN*) printf 'windows-native'; return 0 ;;
  esac
  printf 'linux'
}

# Numeric backends are supervised through POSIX process-group/session
# semantics. Native Windows identities intentionally do not pretend to supply
# those semantics: until a verifiable Win32 tree primitive exists, reject the
# backend before launch or cancellation. WSL remains POSIX-supervisable.
_uberdev_dispatch_numeric_supervision_supported() {
  case "${1:-}" in
    background) [ "$(_uberdev_dispatch_os_class)" != windows-native ] ;;
    wezterm) return 0 ;;
    # `workflow` spawns no OS process at all: the Workflow runtime owns every
    # agent's lifetime, cancellation and result capture in-session. There is
    # no process tree for this library to supervise, so the native-Windows
    # gate does not apply — this is the backend that makes native Windows
    # work without WezTerm (RFC 0015 §4).
    workflow) return 0 ;;
    *) return 2 ;;
  esac
}

# _uberdev_dispatch_audit EVENT JSON
# Delegate to the SKILL.md-defined _uberdev_audit_emit when present; else no-op.
# Keeps lib/dispatch.sh independently sourceable in tests.
_uberdev_dispatch_audit() {
  if command -v _uberdev_audit_emit >/dev/null 2>&1; then
    # _uberdev_audit_emit is defined but failed: the dispatch must still
    # proceed (audit is best-effort, not load-bearing), but a silently
    # dropped audit event leaves the run trail incomplete with no trace.
    # Emit a stderr warning so the gap is at least diagnosable. The
    # not-defined branch stays a deliberate graceful no-op (tests source
    # this file standalone without the SKILL.md audit harness).
    _uberdev_audit_emit "$1" "$2" || echo "warning: audit failed for event $1" >&2
  fi
}

# _uberdev_dispatch_wezterm_available -> exit 0 if wezterm usable, 1 otherwise.
# Usable = binary on PATH AND the `uberdev` mux domain answers list-clients
# within the poll budget (cold-start race guard, RFC §3.6). Starts
# wezterm-mux-server if the mux is not already up. EVERY `wezterm cli` call
# below MUST pass `--domain-name uberdev` so the probe targets the same mux
# domain the spawn step uses; querying the default (stray) WezTerm instance
# would defeat the fan-out-isolation guarantee (RFC §3.6, B1 fix).
_uberdev_dispatch_wezterm_available() {
  command -v wezterm >/dev/null 2>&1 || return 1
  # S9: the list-clients probe is needed twice (each poll iteration and the
  # final post-loop attempt). Defining it once structurally enforces the
  # `--domain-name uberdev` mux-pin invariant so the probe cannot drift to
  # the default (stray) WezTerm instance at one site but not the other. Pure
  # extraction — byte-identical command + redirections, same exit status.
  _wt_probe() { wezterm cli --domain-name uberdev list-clients >/dev/null 2>&1; }
  local i
  for i in 1 2 3 4 5; do
    if _wt_probe; then
      return 0
    fi
    wezterm-mux-server --daemonize >/dev/null 2>&1 || true
    sleep 1
  done
  _wt_probe
}

# _uberdev_dispatch_workflow_engine WORKFLOW -> prints the on-disk Workflow
# script that backend `workflow` would run for that workflow; returns 1 when the
# workflow has no fleet engine, meaning there is nothing for this shell to
# probe.
#
# This is the ONE capability of the workflow backend a shell can honestly test.
# The Workflow *tool* lives in the calling session and is not on PATH, so its
# presence is the model's No-Workflow fallback decision (commands/solve.md:86).
# The engine is different: it is a file this install either shipped or did not,
# and if it is missing the mandated `Workflow({scriptPath: ...})` call cannot be
# made at all. Resolving `workflow` in that state would burn a RUN_ID
# reservation and a workspace prepare before failing — so it is refused here.
_uberdev_dispatch_workflow_engine() {
  case "${1:-}" in
    review-pr|simplify) printf '%s' "$_UBERDEV_DISPATCH_PLUGIN_ROOT/skills/review-fleet/workflow.js" ;;
    *) return 1 ;;
  esac
}

# _uberdev_dispatch_require_workflow_engine WORKFLOW -> 0 when backend
# `workflow` is executable here, 1 with a loud, path-naming refusal otherwise.
# Shared by the `auto` arm, the explicit `workflow` arm, and
# uberdev_dispatch_preflight_backend so all three refuse identically.
_uberdev_dispatch_require_workflow_engine() {
  local wf="${1:-}" engine
  engine="$(_uberdev_dispatch_workflow_engine "$wf")" || return 0
  [ -f "$engine" ] && return 0
  echo "error: backend 'workflow' needs $engine, which is missing from this install" >&2
  echo "       (RFC 0012 §4.1). Reinstall the plugin, or select a transport this" >&2
  echo "       host can execute with --backend=wezterm or --backend=background." >&2
  return 1
}

# uberdev_dispatch_preflight [WORKFLOW]
# Resolves UBERDEV_DISPATCH_BACKEND_REQUESTED (auto|workflow|wezterm|background)
# to a concrete UBERDEV_RESOLVED_BACKEND, ONCE per invocation, committed for
# the whole batch (no mid-fanout switch). Hard-errors (return 1) when an
# explicit backend is unusable on this host, and (since #381) when `auto` would
# land on `workflow` but this install has no engine on disk to run — a refusal,
# never a silent demotion. Emits dispatch_backend_resolved.
uberdev_dispatch_preflight() {
  local requested="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-auto}"
  local workflow="${1:-}" os_class reason resolved
  os_class="$(_uberdev_dispatch_os_class)"
  case "$requested" in
    workflow)
      # The Workflow runtime lives in the calling session, not on PATH, so
      # there is no binary, no mux and no timeout(1) to probe. The caller
      # (solve-launcher Step 5b' / goal Phase 0) emits the args envelope and the
      # command file mandates the Workflow call; availability of the tool itself
      # is the model's No-Workflow fallback decision, documented in
      # commands/solve.md. What this shell CAN prove is that the engine the
      # mandate names is on disk — refuse here rather than at stage time.
      _uberdev_dispatch_require_workflow_engine "$workflow" || return 1
      resolved="workflow"; reason="explicit" ;;
    background)
      # background depends only on git + claude + shell — usable on every OS
      # class. No capability gate.
      resolved="$requested"; reason="explicit" ;;
    wezterm)
      # Explicit wezterm: validate mux usability AND the same-OS constraint.
      if [ "$os_class" = "wsl2" ]; then
        echo "error: --backend=wezterm from WSL2 cannot drive a native-Windows WezTerm" >&2
        echo "       (WSL2 dropped AF_UNIX mux interop; WSLg is GUI-only). Run /solve" >&2
        echo "       from the same OS side as WezTerm, or use --backend=background." >&2
        return 1
      fi
      if ! _uberdev_dispatch_wezterm_available; then
        echo "error: --backend=wezterm requested but WezTerm is unavailable" >&2
        echo "       (binary missing, or the mux failed to come up). Install WezTerm" >&2
        echo "       or use --backend=background. See RFC 0004 §3.6." >&2
        return 1
      fi
      resolved="wezterm"; reason="explicit" ;;
    auto)
      # RFC 0015: `auto` resolves to `workflow` on every Claude host and every
      # OS class. The historical per-OS matrix below it existed only to pick a
      # *detached process* supervisor for the retired default transport; the
      # Workflow runtime needs no supervisor, which is why native Windows no
      # longer hard-errors here.
      #
      # #381: the review-pr/simplify SPECIAL CASE IS GONE. It required the codex
      # CLI because those two workflows need an atomic child result artifact and
      # caller-workspace repair, and `workflow` had no wiring to provide either:
      # every child reached _uberdev_agent_dispatch_backend, which has no
      # workflow provider arm. Both halves now exist — commands/review-pr.md and
      # commands/simplify.md emit the args envelope and mandate the Workflow call
      # at every stage, and each bound child's result.md/status.json pair is
      # digested by lib/code_fixer_contract.py — so these two workflows now take
      # the same ladder as everything else.
      #
      # #381 also removed the two Codex-environment escapes that used to run
      # BEFORE the per-OS matrix (CODEX_HOME set, or claude absent with codex
      # present). Both resolved a backend that no longer exists; there is no
      # replacement, because `auto` has exactly one answer now.
      #
      # auto must never land on a backend this install cannot execute. The
      # engine gate is a REFUSAL, not a fallback: silently demoting the default
      # transport is how the retired per-OS matrix drifted back into a default
      # path, and the operator needs to know their install is broken rather
      # than discover it as a different backend's behaviour.
      _uberdev_dispatch_require_workflow_engine "$workflow" || return 1
      resolved="workflow"; reason="auto-workflow" ;;
    *)
      echo "error: dispatch backend '$requested' not in {$_UBERDEV_DISPATCH_BACKEND_ENUM}" >&2
      return 1 ;;
  esac
  if ! _uberdev_dispatch_numeric_supervision_supported "$resolved"; then
    echo "error: backend '$resolved' lacks verifiable process-tree supervision on native Windows" >&2
    echo "       use WezTerm, WSL2, or another POSIX host" >&2
    return 1
  fi
  export UBERDEV_RESOLVED_BACKEND="$resolved"
  _uberdev_dispatch_audit dispatch_backend_resolved \
    "{\"requested\":\"$requested\",\"resolved\":\"$resolved\",\"os_class\":\"$os_class\",\"reason\":\"$reason\"}"
  return 0
}

# RFC 0015 §5 — the workflow->detached DEMOTION HELPER IS GONE, DELIBERATELY.
#
# There used to be a `uberdev_dispatch_demote_workflow_to_detached` here. It
# existed for exactly one caller: /goal's Phase-1 loop, which drove
# uberdev_dispatch_one itself and therefore could not use the `workflow` backend
# (the fleet is spawned by the calling session's Workflow tool, not by this
# library). It re-resolved a `workflow` selection back down to the pre-RFC-0015
# per-OS detached matrix — which meant the since-removed detached default was
# still reachable from `auto` on the default /goal path.
#
# /goal no longer dispatches: lib/goal-phase1.sh claims only, and
# skills/goal-pipeline/workflow.js makes ONE nested workflow() call per cycle
# into skills/solve-fleet/workflow.js. With the last consumer gone the helper is
# deleted rather than left dormant — a dormant demotion is exactly how the
# retired per-OS matrix would drift back into a default path. Reaching a
# detached backend is now an EXPLICIT `--backend=<name>` choice on every surface.

# ---------------------------------------------------------------------------
# uberdev_dispatch_resolve_env [BACKEND]
# Resolves the five deterministic dispatch-env vars consumed by every backend:
#   MODEL, PERM_FLAG[], EFFORT_FLAG[], SOLVE_TIMEOUT, TIMEOUT_BIN.
# There used to be a sixth — the prompt-delivery mode. Its only consumer was
# the retired detached `claude --bg` provider arm's file/stdin/argv switch, so
# it went with it (RFC 0015 §7 as amended).
# SSOT for both solve-pipeline (replaces its inline Phase A block) and
# goal-pipeline (Phase 0). Sourced, NEVER exec'd — PERM_FLAG/EFFORT_FLAG are
# bash arrays that cannot survive an env(1)/fork+exec boundary, so they must be
# set in the caller's shell scope. Idempotent: deterministic scalars, arrays
# rebuilt each call. Returns 1 (fail-loud) when no timeout(1)/gtimeout(1) is on
# PATH for Claude-backed backends. Does NOT read or write
# UBERDEV_RESOLVED_BACKEND (that is preflight's; RFC 0005 D15 constrains
# backend resolution only — env resolution is exempt). Callers pass BACKEND
# explicitly so this helper can skip timeout(1) for transports that launch no
# OS process, without reading preflight's global.
# Inputs (read with safe defaults so goal-pipeline, which has no arg-parser,
# can call it). Exhaustive list — this is the SSOT for both solve-pipeline
# Phase A and goal-pipeline Phase 0 callers; any new opt-in env var must be
# added here AND threaded through both call sites:
#   SKIP_PERMISSIONS (default 0)  — bypass tier; /goal opts in (#241)
#   AUTO_PERMISSIONS (default 0)  — bypass tier (aliased to SKIP semantics post-#241
#                                   follow-up): /turbo/--auto and /solve/--auto opt
#                                   in. Historically mapped to `--permission-mode auto`,
#                                   but auto-mode is silently broken in cmux and refuses
#                                   some agent tools (e.g., Search) outside cmux too —
#                                   the middle tier was dead weight, so AUTO now resolves
#                                   to the same flag pair as SKIP. Env-var name preserved
#                                   for backward compat with /turbo --auto / /solve --auto
#                                   and any external callers. Post-#246 follow-up: both
#                                   tiers now resolve to the paired form
#                                   `--dangerously-skip-permissions --permission-mode
#                                   bypassPermissions` (see in-body PERM_FLAG block for
#                                   why pairing is required — bg-session UI cycle ring).
#   EFFORT_LEVEL     (default max)
uberdev_dispatch_resolve_env() {
  local _dispatch_env_backend="${1:-}"
  # MODEL: single-quoted to keep zsh from glob-evaluating [1m] under NOMATCH.
  MODEL='claude-opus-4-8[1m]'

  # PERM_FLAG: array form (zsh SH_WORD_SPLIT=off would treat a scalar at command
  # position as one argv slot). Empty by default; populated only when the caller
  # opted into a permission tier.
  #
  # (a) Why both env vars resolve to the same pair:
  #     SKIP_PERMISSIONS and AUTO_PERMISSIONS both populate
  #     `--dangerously-skip-permissions --permission-mode bypassPermissions`. The
  #     historical `--permission-mode auto` middle tier was removed post-#241 because
  #     Claude Code's auto-mode silently refuses some agent tools (notably Search)
  #     even when the operator opted in, and cmux's PermissionRequest hook intercepts
  #     auto-mode too — auto is dead in practice. /goal opts into the strict bypass
  #     so cmux PermissionRequest hooks cannot stall the autonomous loop on
  #     first-tool-use (#241); /turbo --auto and /solve --auto opt operators into the
  #     same pair for the same reason.
  #
  # (b) Why the if/elif shape is preserved:
  #     The two branches emit the same pair, but the if/elif structure is kept so
  #     PERM_DESC (see solve-pipeline/SKILL.md) can attribute the bypass to which
  #     env var the caller set — post-hoc grep can distinguish /goal (SKIP) vs
  #     /turbo --auto / /solve --auto (AUTO) in audit logs.
  #
  # (c) Why both flags in the pair are needed (#246):
  #     `--dangerously-skip-permissions` short-circuits the runtime permission
  #     *checks* but does NOT set `--permission-mode`. In Claude Code 2.1.152+, the
  #     bg session UI cycle ring is driven by --permission-mode; without an explicit
  #     setting it lands on `auto`, which is exactly the mode that silently breaks
  #     Search/etc. that we are trying to avoid. The two flags target different
  #     mechanisms (runtime-check short-circuit vs bg UI cycle-ring pin), so both
  #     are needed (belt-and-suspenders).
  SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-0}"
  AUTO_PERMISSIONS="${AUTO_PERMISSIONS:-0}"
  PERM_FLAG=()
  if [[ "$SKIP_PERMISSIONS" == "1" ]]; then
    PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )
  # Same pair as SKIP branch — kept distinct for caller-attribution observability via PERM_DESC; see (b) in the PERM_FLAG rationale block above.
  elif [[ "$AUTO_PERMISSIONS" == "1" ]]; then
    PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )
  fi

  # EFFORT_FLAG: threaded form of EFFORT_LEVEL (default max for callers without
  # an --effort parser, e.g. goal-pipeline). Bash+zsh array.
  EFFORT_LEVEL="${EFFORT_LEVEL:-max}"
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )

  # Wall-clock timeout: read command_timeouts.solve (env override
  # UBERDEV_SOLVE_TIMEOUT; default 3600s; range [60, 86400]). Guard with
  # `command -v` so this block is independently sourceable.
  if command -v uberdev_read_int_in_range >/dev/null 2>&1; then
    SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
  elif [ -r "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}/lib/config-read.sh" ]; then
    # Re-sourcing is safe even if config-read.sh was already loaded: it carries
    # its own idempotency guard (_UBERDEV_CONFIG_READ_LOADED), so no explicit
    # already-sourced check is needed here.
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT}}/lib/config-read.sh"
    SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
  else
    echo "warning: config-read.sh not found at ${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}/lib/; uberdev.local.md timeout settings ignored" >&2
    SOLVE_TIMEOUT=3600
  fi

  # `workflow` launches no OS process: the Workflow runtime owns each agent's
  # lifetime and cancellation, so there is nothing to wrap and no reason to
  # demand GNU coreutils on the host (RFC 0015 §4). SOLVE_TIMEOUT above is
  # still resolved — it is relayed into the args envelope as the per-issue
  # advisory budget the fleet script reports on. (`codex` shared this skip for
  # the same reason and went with the backend in #381.)
  if [ "$_dispatch_env_backend" = "workflow" ]; then
    TIMEOUT_BIN=""
    return 0
  fi

  # TIMEOUT_BIN probe (RFC 0004 §3.8 order — absolute /usr/bin/timeout FIRST
  # (MSYS coreutils on Windows, and Linux distros that ship it there),
  # then Unix `timeout` on PATH, then macOS Homebrew `gtimeout`).
  TIMEOUT_BIN=""
  if   [ -x /usr/bin/timeout ];                 then TIMEOUT_BIN=/usr/bin/timeout
  elif command -v timeout  >/dev/null 2>&1;     then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1;     then TIMEOUT_BIN=gtimeout
  fi

  # Runtime guard: fail-loud if neither timeout(1) nor gtimeout(1) is on PATH.
  # Regression guard: tests/config-override.test.sh I2f anchors on this
  # `if [[ -n "$TIMEOUT_BIN" ]]; then` pattern; do not collapse to `[[ … ]] ||`.
  if [[ -n "$TIMEOUT_BIN" ]]; then
    : # timeout(1) or gtimeout(1) available; bg dispatch arms wrap correctly
  else
    echo "error: neither timeout(1) nor gtimeout(1) found on PATH" >&2
    echo "       install with: brew install coreutils  # provides gtimeout" >&2
    return 1
  fi
  return 0
}

# Validate the selected provider environment before a governed workflow starts
# constructing children. `workflow` needs no Claude CLI model, permission, or
# timeout variables; every detached transport shares the resolver above.
uberdev_dispatch_preflight_backend() {
  local backend="${1:-}" workflow="${2:-}" backend_label
  # The supervision-capable subset: every backend EXCEPT the two that are
  # never a detached provider session. Declared, not silently narrower.
  # CONTRACT: dispatch-backend -auto -workflow !case-arm
  case "$backend" in
    background|wezterm)
      if ! _uberdev_dispatch_numeric_supervision_supported "$backend"; then
        backend_label="$backend"
        echo "error: $workflow cannot supervise native Windows $backend_label process trees" >&2
        echo "       use WezTerm, WSL2, or another POSIX host" >&2
        return 1
      fi
      ;;
  esac
  if [ "$workflow" = review-pr ] || [ "$workflow" = simplify ]; then
    # Also exhaustive over the resolved set, and its `*)`-less shape is the
    # reason it must be compared: a fifth backend with no arm here is silently
    # ADMITTED for /review-pr and /simplify, which is the #360 shape inverted.
    # `-auto` for the same reason as the switch below.
    # CONTRACT: dispatch-backend -auto !case-arm
    case "$backend" in
      # `workflow` admitted per #381. The bar these two workflows set is an
      # atomic result artifact plus caller-workspace repair, and the
      # Workflow-native transport now meets BOTH -- it is not being waived.
      # Result artifact: every bound child writes result.md.partial and
      # publishes it with a same-directory rename, then writes a nonce-bearing
      # status.json the same way, and the controller re-reads and digests both
      # through lib/code_fixer_contract.py (capture-bound-child /
      # capture-review-terminal / capture-standalone-terminal /
      # capture-persistence-terminal) before anything downstream runs.
      # Caller workspace: the code-fixer child commits onto the caller checkout
      # with no worktree isolation -- already admitted for this backend in
      # lib/agent-dispatch.sh's workspace_mode validator.
      #
      # #381 step 3 made this the DEFAULT: `auto` now resolves workflow for both
      # workflows too. The BREAKING Phase-3 gap that travelled with that flip is
      # CLOSED as of #383: review_pr.ci.* no longer take the routed adapter at
      # all. Half one built the four Phase 3 stages -- ci-classify, ci-fix,
      # ci-conflicts and ci-defer -- in skills/review-fleet/workflow.js with
      # their producer/capture/judges in lib/code_fixer_contract.py, and half
      # two re-pointed the caller: commands/review-pr.md's Phase 3 fences now
      # dispatch those stages the way Phase 1 and Phase 2 dispatch theirs. So
      # nothing in Phase 3 reaches _uberdev_agent_dispatch_backend's
      # hard-failing `workflow)` arm, the 6c.3 CLASSIFY transport refusal that
      # used to halt a red check is gone, and `--no-ci-fix` is a user choice
      # again rather than the only supported mode. The retired refusal is not
      # named here on purpose: tests/review-pr-workflow.test.sh G14a greps this
      # file for its reason string and fails on ANY occurrence, comments
      # included, so that a retired surface cannot survive as prose.
      # (The engine gate is applied once, in the backend case below, so it
      # covers every workflow rather than only these two.)
      workflow) ;;
      # STILL LIVE, and deliberately kept when `codex) ;;` was deleted in #381.
      # Both of these remain selectable via --backend=, and neither can publish
      # a governed child result artifact or repair the caller workspace, so
      # removing this arm would silently admit `/review-pr --backend=background`.
      wezterm|background)
        echo "error: $workflow needs a backend that publishes a governed child result artifact and can repair the caller workspace; '$backend' does neither" >&2
        echo "       use the default (workflow) for $workflow" >&2
        return 1
        ;;
    esac
  fi
  # The exhaustive resolved-backend dispatch: every member gets an arm and the
  # `*)` arm is a refusal, so adding a fifth backend and forgetting THIS switch
  # is exactly the #360 shape. `-auto` because `auto` is a REQUEST that
  # `uberdev_dispatch_preflight` has already resolved before anything reaches
  # here — the same delta `lib/goal-state.sh` declares for the same reason.
  # CONTRACT: dispatch-backend -auto !case-arm
  case "$backend" in
    workflow)
      # No provider binary, no permission tier to probe (the Workflow runtime
      # inherits the session's), no timeout(1). The one thing this shell can
      # prove is that the engine the command file mandates actually shipped —
      # same gate the resolver applies, so `--backend=workflow` and `auto`
      # refuse a broken install identically instead of at different stages.
      _uberdev_dispatch_require_workflow_engine "$workflow" || return 1
      return 0
      ;;
    wezterm|background) uberdev_dispatch_resolve_env "$backend" ;;
    *)
      echo "error: unsupported dispatch backend for workflow preflight: $backend" >&2
      return 1
      ;;
  esac
}

# _uberdev_agent_dispatch_backend BACKEND ISSUE TIER PROMPT RESULT STATUS DECISION
# Provider boundary consumed by agent-dispatch.sh. Exactly one case arm runs.
_uberdev_agent_dispatch_backend() {
  local backend="$1" issue_num="$2" tier="$3" prompt_file="$4"
  local result_file="$5" status_file="$6" decision="$7"
  DISPATCH_STATUS_CONTEXT=0
  DISPATCH_STATUS_LOG=''
  DISPATCH_STATUS_RESULT=''
  DISPATCH_STATUS_WORKTREE=''
  DISPATCH_STATUS_BRANCH=''
  DISPATCH_STATUS_WORKSPACE_MODE=''
  UBERDEV_AGENT_ROUTING_MODE="$(_uberdev_agent_json_get "$decision" routing_mode 2>/dev/null || true)"
  UBERDEV_AGENT_EFFECTIVE_POLICY="$(_uberdev_agent_json_get "$decision" effective_policy 2>/dev/null || true)"
  UBERDEV_AGENT_ROUTE_MODEL="$(_uberdev_agent_json_get "$decision" model 2>/dev/null || true)"
  UBERDEV_AGENT_ROUTE_EFFORT="$(_uberdev_agent_json_get "$decision" reasoning_effort 2>/dev/null || true)"
  UBERDEV_AGENT_SERVICE_TIER="$(_uberdev_agent_json_get "$decision" service_tier 2>/dev/null || true)"
  UBERDEV_AGENT_SANDBOX="$(_uberdev_agent_json_get "$decision" sandbox 2>/dev/null || true)"
  UBERDEV_AGENT_RESULT_FILE="$result_file"
  UBERDEV_AGENT_STATUS_FILE="$status_file"
  export UBERDEV_AGENT_ROUTING_MODE UBERDEV_AGENT_EFFECTIVE_POLICY UBERDEV_AGENT_ROUTE_MODEL UBERDEV_AGENT_ROUTE_EFFORT
  export UBERDEV_AGENT_SERVICE_TIER UBERDEV_AGENT_SANDBOX UBERDEV_AGENT_RESULT_FILE UBERDEV_AGENT_STATUS_FILE
  case "$backend" in
    wezterm)     _uberdev_dispatch_wezterm "$issue_num" "$tier" "$prompt_file" ;;
    background)  _uberdev_dispatch_background "$issue_num" "$tier" "$prompt_file" ;;
    # `workflow` has no provider arm BY CONSTRUCTION: the fleet is spawned by
    # the calling session's Workflow tool, not by this library. Reaching here
    # means a caller resolved `workflow` and then took the detached-dispatch
    # path anyway — a wiring bug, so fail loud rather than silently falling
    # through to a default provider (RFC 0015 §4).
    workflow)
      DISPATCH_RC=1; DISPATCH_ID=""
      DISPATCH_LOG="backend 'workflow' is dispatched by the session's Workflow tool (skills/solve-fleet/workflow.js), not by lib/dispatch.sh; the caller must emit the args envelope instead of calling uberdev_dispatch_one"
      echo "error: $DISPATCH_LOG" >&2
      return 1 ;;
    *) DISPATCH_RC=1; DISPATCH_ID=""; DISPATCH_LOG="unsupported backend: $backend"; return 1 ;;
  esac
}

_uberdev_dispatch_group_live() {
  _uberdev_dispatch_python -I -B - "$1" <<'PY'
import subprocess,sys
pgid=int(sys.argv[1]); live=False
try: rows=subprocess.check_output(["ps","-axo","pgid=,stat="],text=True).splitlines()
except Exception: raise SystemExit(2)
for row in rows:
 parts=row.split(None,1)
 if len(parts)==2 and parts[0].isdigit() and int(parts[0])==pgid and not parts[1].startswith("Z"):
  live=True; break
raise SystemExit(0 if live else 1)
PY
}

_uberdev_dispatch_group_owned_session() {
  _uberdev_dispatch_python -I -B - "$1" "$2" <<'PY'
import os,subprocess,sys
pgid,sid=map(int,sys.argv[1:]); live=[]
try: rows=subprocess.check_output(["ps","-axo","pid=,pgid=,stat="],text=True).splitlines()
except Exception: raise SystemExit(2)
for row in rows:
 parts=row.split(None,2)
 if len(parts)!=3 or not all(x.isdigit() for x in parts[:2]): continue
 proc_pid,proc_pgid=map(int,parts[:2])
 if proc_pgid==pgid and not parts[2].startswith("Z"):
  try: proc_sid=os.getsid(proc_pid)
  except ProcessLookupError: continue
  except OSError: raise SystemExit(2)
  live.append((proc_pid,proc_sid))
if not live: raise SystemExit(1)
if any(proc_sid!=sid for _,proc_sid in live): raise SystemExit(2)
raise SystemExit(0)
PY
}

# Authorize signaling only while the recorded leader is either still the exact
# launch-time process or is absent, and every surviving member of its recorded
# process group remains in that same session. An unavailable identity probe or
# a reused leader PID is never downgraded to group-only evidence.
_uberdev_dispatch_owned_group_state() {
  local handle="$1" expected_identity="$2" pgid="$3" sid="$4" current probe_rc group_rc
  if current="$(_uberdev_dispatch_process_identity "$handle" 2>/dev/null)"; then
    [ "$current" = "$expected_identity" ] || return 2
  else
    probe_rc=$?
    [ "$probe_rc" -eq 1 ] || return 2
  fi
  if _uberdev_dispatch_group_owned_session "$pgid" "$sid"; then
    return 0
  else
    group_rc=$?
  fi
  [ "$group_rc" -eq 1 ] && return 1
  return 2
}

_uberdev_dispatch_process_identity() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  _uberdev_dispatch_python -I -B "$_UBERDEV_AGENT_MANIFEST_TOOL" process-identity --pid "$pid"
}

_uberdev_dispatch_wait_owned_session() {
  local pid="$1" identity identity_pid identity_pgid identity_sid identity_started attempts=0
  while [ "$attempts" -lt 40 ]; do
    identity="$(_uberdev_dispatch_process_identity "$pid" 2>/dev/null || true)"
    if [ -n "$identity" ]; then
      IFS='|' read -r identity_pid identity_pgid identity_sid identity_started <<EOF_IDENTITY
$identity
EOF_IDENTITY
      if [ "$identity_pid" = "$pid" ] && [ "$identity_pgid" = "$pid" ] && [ "$identity_sid" = "$pid" ] && [ -n "$identity_started" ]; then
        return 0
      fi
    fi
    sleep 0.025; attempts=$((attempts + 1))
  done
  return 1
}


# A detached wrapper can write its final status and exit before the parent gets
# scheduled to observe the new session. Accept that race only from one secure,
# canonical terminal snapshot naming the exact PID we just launched. A live
# non-zombie PID is rejected because it may be reused or unisolated.
_uberdev_dispatch_accept_immediate_terminal() {
  local backend="$1" pid="$2" status_file="$3" result_file="${4:-}"
  _uberdev_dispatch_python -I -B - "$backend" "$pid" "$status_file" "$result_file" "$_UBERDEV_AGENT_MANIFEST_TOOL" <<'PY'
import json,os,stat,subprocess,sys
backend,pid,status_path,result_path,manifest_tool=sys.argv[1:]
if not pid.isdigit() or int(pid)<=0: raise SystemExit(2)
if os.name=="nt":
 probe=subprocess.run(
  [sys.executable,"-I","-B",manifest_tool,"process-identity","--pid",pid],
  stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,
 )
 if probe.returncode==0: raise SystemExit(1)
 if probe.returncode!=1: raise SystemExit(2)
else:
 try:
  process_state=subprocess.check_output(["ps","-o","stat=","-p",pid],text=True,stderr=subprocess.DEVNULL).strip()
 except (OSError,subprocess.CalledProcessError): process_state=""
 if process_state and not process_state.startswith("Z"): raise SystemExit(1)
def secure_read(path,limit):
 parent=os.path.dirname(os.path.abspath(path)); name=os.path.basename(path)
 if os.name=="nt":
  fd=os.open(os.path.abspath(path),os.O_RDONLY|getattr(os,"O_BINARY",0)); opened=os.fstat(fd)
  try:
   current=os.lstat(path); uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
   if (stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(opened.st_mode)
       or (uid is not None and opened.st_uid!=uid) or opened.st_nlink!=1
       or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise ValueError()
   raw=os.read(fd,limit+1)
   if len(raw)>limit: raise ValueError()
   return raw
  finally: os.close(fd)
 parent_fd=os.open(parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); fd=None
 try:
  fd=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent_fd)
  opened=os.fstat(fd); current=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
  if (not stat.S_ISREG(opened.st_mode) or opened.st_uid!=os.geteuid() or opened.st_nlink!=1
      or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise ValueError()
  raw=os.read(fd,limit+1)
  if len(raw)>limit: raise ValueError()
  return raw
 finally:
  if fd is not None: os.close(fd)
  os.close(parent_fd)
try:
 snapshot=json.loads(secure_read(status_path,65536))
 allowed={"issue","tier","backend","state","exit_code","pid","log","result","worktree","branch","workspace_mode","provider_exit_code","process_identity","lease_generation"}
 if not isinstance(snapshot,dict) or set(snapshot)-allowed: raise ValueError()
 if snapshot.get("backend")!=backend or str(snapshot.get("pid"))!=pid: raise ValueError()
 state=snapshot.get("state"); code=snapshot.get("exit_code")
 if isinstance(code,bool) or not isinstance(code,int): raise ValueError()
 if "provider_exit_code" in snapshot:
  provider_code=snapshot["provider_exit_code"]
  if isinstance(provider_code,bool) or not isinstance(provider_code,int): raise ValueError()
  if state!="failed" or code!=74: raise ValueError()
 if state=="completed":
  if code!=0 or not result_path or len(secure_read(result_path,16*1024*1024))==0: raise ValueError()
 elif state=="failed":
  if code==0: raise ValueError()
 else: raise ValueError()
except (OSError,ValueError,TypeError,json.JSONDecodeError): raise SystemExit(1)
print(state,end="")
PY
}

# Remove the one deterministic background-result staging file belonging to a
# verified-dead wrapper. The caller must first prove complete process-group
# death with _uberdev_dispatch_cancel_backend. This helper never globs and
# never follows a parent, result, or staging-file symlink.
_uberdev_dispatch_cleanup_dead_partial_result() {
  local result_file="$1" handle="$2"
  _uberdev_dispatch_python -I -B - "$result_file" "$handle" <<'PY'
import os,stat,sys
result,pid=sys.argv[1:]
if not os.path.isabs(result) or not pid.isdigit() or int(pid)<=0: raise SystemExit(2)
parent=os.path.dirname(result); result_name=os.path.basename(result)
partial_name=f"{result_name}.partial.{pid}"
parent_fd=os.open(parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
result_fd=partial_fd=None
try:
 result_fd=os.open(result_name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent_fd)
 result_entry=os.fstat(result_fd)
 if not stat.S_ISREG(result_entry.st_mode) or result_entry.st_uid!=os.geteuid() or result_entry.st_nlink!=1: raise ValueError()
 try: partial_fd=os.open(partial_name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent_fd)
 except FileNotFoundError: raise SystemExit(0)
 opened=os.fstat(partial_fd); current=os.stat(partial_name,dir_fd=parent_fd,follow_symlinks=False)
 if (not stat.S_ISREG(opened.st_mode) or opened.st_uid!=os.geteuid() or opened.st_nlink!=1
     or stat.S_IMODE(opened.st_mode)!=0o600
     or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise ValueError()
 os.unlink(partial_name,dir_fd=parent_fd)
finally:
 if partial_fd is not None: os.close(partial_fd)
 if result_fd is not None: os.close(result_fd)
 os.close(parent_fd)
PY
}

# Cancel one already-registered provider handle. Numeric processes require the
# launch-time process identity recorded by agent-dispatch; a reused PID is
# rejected before signaling. Opaque providers use their native handle API and
# prove the handle is no longer live before returning success.
_uberdev_dispatch_cancel_backend() {
  local backend="$1" handle="$2" expected_identity="${3:-}" pane attempts group_rc identity_pid identity_pgid identity_sid identity_started
  _UBERDEV_DISPATCH_CANCEL_REASON=''
  case "$backend" in
    background)
      _uberdev_dispatch_numeric_supervision_supported "$backend" || {
        _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed
        return 2
      }
      case "$handle" in ''|*[!0-9]*) _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2 ;; esac
      [ -n "$expected_identity" ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
      IFS='|' read -r identity_pid identity_pgid identity_sid identity_started <<EOF_IDENTITY
$expected_identity
EOF_IDENTITY
      [ "$identity_pid" = "$handle" ] && [ "$identity_pgid" = "$handle" ] && [ "$identity_sid" = "$handle" ] && [ -n "$identity_started" ] \
        || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
      if _uberdev_dispatch_owned_group_state "$handle" "$expected_identity" "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
      [ "$group_rc" -ne 1 ] || return 0
      [ "$group_rc" -eq 0 ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
      if ! kill -TERM "-$identity_pgid" 2>/dev/null; then
        if _uberdev_dispatch_owned_group_state "$handle" "$expected_identity" "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
        [ "$group_rc" -eq 1 ] && return 0
        _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed
        return 2
      fi
      attempts=0
      while [ "$attempts" -lt 40 ]; do
        if _uberdev_dispatch_group_owned_session "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
        [ "$group_rc" -ne 1 ] || return 0
        [ "$group_rc" -eq 0 ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
        sleep 0.05; attempts=$((attempts + 1))
      done
      if _uberdev_dispatch_owned_group_state "$handle" "$expected_identity" "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
      [ "$group_rc" -ne 1 ] || return 0
      [ "$group_rc" -eq 0 ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
      if ! kill -KILL "-$identity_pgid" 2>/dev/null; then
        if _uberdev_dispatch_owned_group_state "$handle" "$expected_identity" "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
        [ "$group_rc" -eq 1 ] && return 0
        _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed
        return 2
      fi
      attempts=0
      while [ "$attempts" -lt 40 ]; do
        if _uberdev_dispatch_group_owned_session "$identity_pgid" "$identity_sid"; then group_rc=0; else group_rc=$?; fi
        [ "$group_rc" -ne 1 ] || return 0
        [ "$group_rc" -eq 0 ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed; return 2; }
        sleep 0.05; attempts=$((attempts + 1))
      done
      _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed
      return 1
      ;;
    wezterm)
      pane="${handle#pane:}"; case "$pane" in ''|*[!0-9]*) return 2 ;; esac
      wezterm cli --domain-name uberdev kill-pane --pane-id "$pane" >/dev/null 2>&1 || return 2
      wezterm cli --domain-name uberdev list --format json 2>/dev/null | _uberdev_dispatch_python -I -B -c '
import json,sys
pane=int(sys.argv[1])
try: rows=json.load(sys.stdin)
except Exception: raise SystemExit(2)
if any(isinstance(row,dict) and row.get("pane_id")==pane for row in rows): raise SystemExit(1)
' "$pane"
      ;;
    # A Workflow child is awaited in-process by the calling session and is
    # cancelled by that session's own abort signal. There is no external
    # process to signal and no provider handle to resolve, so cancellation is
    # confirmed by construction: once the await is abandoned the child cannot
    # still be running.
    #
    # This arm pairs with _uberdev_child_backend_cancellation_supported's
    # `workflow) return 0` (lib/child-dispatch.sh). Without it the two
    # disagreed: the capability check admitted a workflow child through
    # uberdev_preflight_child_batch, and the actual cancel then fell to `*)`
    # and returned 2 -- provider_cancel_unconfirmed, capacity RETAINED. The
    # capability check claimed something the cancel path did not implement,
    # which is the same looks-correct-does-nothing shape this branch exists to
    # delete. Keep the two arms in step.
    workflow) return 0 ;;
    *) return 2 ;;
  esac
}

# uberdev_dispatch_one ISSUE_NUM TIER PROMPT_FILE
# Preserve the historical public globals while routing every provider through
# the lifecycle/capacity adapter.
uberdev_dispatch_one() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3" run_dir result_file status_file
  local repository_id request_json capacity timeout_s run_id provenance workflow_routes role_routes parent_run
  DISPATCH_RC=0
  DISPATCH_ID=""
  DISPATCH_LOG=""
  if [ -z "${UBERDEV_RESOLVED_BACKEND:-}" ]; then
    uberdev_dispatch_preflight || { DISPATCH_RC=1; return 1; }
  fi
  uberdev_read_model_routing >/dev/null || true
  if ! run_dir="$(_uberdev_dispatch_runtime_root)"; then
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"runtime_root\",\"backend\":\"$UBERDEV_RESOLVED_BACKEND\",\"rc\":1}"
    return 1
  fi
  UBERDEV_TMPDIR="$run_dir"
  export UBERDEV_TMPDIR
  # One naming scheme now that the codex arm (the only backend with its own
  # solve-codex-* pair) is gone (#381).
  result_file="$run_dir/solve-bg-result-$ISSUE_NUM.md"
  status_file="$run_dir/solve-bg-status-$ISSUE_NUM.json"
  repository_id="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  provenance="${UBERDEV_ROUTING_PROVENANCE_JSON:-}"; [ -n "$provenance" ] || provenance='{}'
  workflow_routes="${UBERDEV_ROUTING_WORKFLOWS:-}"; [ -n "$workflow_routes" ] || workflow_routes='{}'
  role_routes="${UBERDEV_ROUTING_ROLES:-}"; [ -n "$role_routes" ] || role_routes='{}'
  parent_run="${UBERDEV_AGENT_PARENT_RUN_JSON:-}"; [ -n "$parent_run" ] || parent_run='{}'
  capacity="${UBERDEV_AGENT_CAPACITY:-6}"
  timeout_s="${SOLVE_TIMEOUT:-3600}"
  run_id="solve-${UBERDEV_RESOLVED_BACKEND}-${ISSUE_NUM}-$$-${RANDOM:-0}"
  request_json="$(_uberdev_dispatch_python -I -c '
import json, sys
(run_dir,run_id,repository_id,backend,tier,issue,capacity,timeout,provenance_raw,
 cli_mode,cli_route,cli_model,cli_effort,cli_service,cli_fast,cli_sandbox,
 env_mode,env_route,env_model,env_effort,env_service,env_risk,env_fallback,env_shadow,
 effective_mode,effective_service,effective_risk,effective_fallback,effective_shadow,effective_workflows,effective_roles,
 workflow,phase,role,risks_raw,parent_raw,triage_raw)=sys.argv[1:]
provenance=json.loads(provenance_raw)
request = {
  "schema_version":1, "run_dir":run_dir, "run_id":run_id,
  "repository_id":repository_id, "backend":backend, "workflow":workflow,
  "phase":phase, "role":role, "task_tier":tier, "risk_signals":json.loads(risks_raw),
  "issue_or_pr":int(issue), "issue_num":int(issue),
  "capacity":int(capacity), "timeout_s":int(timeout),
}
for key,value in (("routing_mode",cli_mode),("explicit_route",cli_route),("explicit_model",cli_model),("explicit_effort",cli_effort),("explicit_service_tier",cli_service),("explicit_sandbox",cli_sandbox)):
 if value: request[key]=value
if cli_fast: request["fast"]=cli_fast=="true"
environment={}
for key,value in (("UBERDEV_ROUTE",env_route),("UBERDEV_MODEL",env_model),("UBERDEV_REASONING_EFFORT",env_effort)):
 if value: environment[key]=value
for provenance_key,key,value in (("mode","UBERDEV_MODEL_ROUTING_MODE",env_mode),("service_tier","UBERDEV_SERVICE_TIER",env_service)):
 if value and provenance.get(provenance_key,{}).get("source")=="env": environment[key]=value
for provenance_key,key,value in (("risk_escalation","UBERDEV_MODEL_ROUTING_RISK_ESCALATION",env_risk),("adaptive_fallback","UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK",env_fallback),("shadow","UBERDEV_MODEL_ROUTING_SHADOW",env_shadow)):
 if value and provenance.get(provenance_key,{}).get("source")=="env": environment[key]=value=="true"
for provenance_key,key,value in (("workflows","UBERDEV_MODEL_ROUTING_WORKFLOWS",effective_workflows),("roles","UBERDEV_MODEL_ROUTING_ROLES",effective_roles)):
 if provenance.get(provenance_key,{}).get("source")=="env": environment[key]=json.loads(value)
if environment: request["environment"]=environment
effective={"mode":effective_mode,"service_tier":effective_service,"risk_escalation":effective_risk=="true","adaptive_fallback":effective_fallback=="true","shadow":effective_shadow=="true","workflows":json.loads(effective_workflows),"roles":json.loads(effective_roles)}
project={key:value for key,value in effective.items() if provenance.get(key,{}).get("source") in {"project-codex","project-claude","explicit-config-file"}}
if project: request["project_routing"]=project
parent=json.loads(parent_raw)
if parent: request["parent_run"]=parent
if triage_raw: request["triage_decision"]=json.loads(triage_raw)
print(json.dumps(request, sort_keys=True, separators=(",", ":")))
' "$run_dir" "$run_id" "$repository_id" "$UBERDEV_RESOLVED_BACKEND" "$TIER" "$ISSUE_NUM" \
    "$capacity" "$timeout_s" "$provenance" \
    "${UBERDEV_DISPATCH_ROUTING_MODE:-}" "${UBERDEV_DISPATCH_ROUTE:-}" "${UBERDEV_DISPATCH_MODEL:-}" "${UBERDEV_DISPATCH_REASONING_EFFORT:-}" "${UBERDEV_DISPATCH_SERVICE_TIER:-}" "${UBERDEV_DISPATCH_FAST:-}" "${UBERDEV_DISPATCH_SANDBOX:-}" \
    "${UBERDEV_MODEL_ROUTING_MODE:-}" "${UBERDEV_ROUTE:-}" "${UBERDEV_MODEL:-}" "${UBERDEV_REASONING_EFFORT:-}" "${UBERDEV_SERVICE_TIER:-}" "${UBERDEV_MODEL_ROUTING_RISK_ESCALATION:-}" "${UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK:-}" "${UBERDEV_MODEL_ROUTING_SHADOW:-}" \
    "${UBERDEV_ROUTING_MODE:-inherit}" "${UBERDEV_ROUTING_SERVICE_TIER:-default}" "${UBERDEV_ROUTING_RISK_ESCALATION:-true}" "${UBERDEV_ROUTING_ADAPTIVE_FALLBACK:-true}" "${UBERDEV_ROUTING_SHADOW:-false}" "$workflow_routes" "$role_routes" \
    "${UBERDEV_AGENT_WORKFLOW:-solve}" "${UBERDEV_AGENT_PHASE:-lead}" "${UBERDEV_AGENT_ROLE:-lead}" "${UBERDEV_AGENT_RISK_SIGNALS_JSON:-[]}" "$parent_run" "${UBERDEV_AGENT_TRIAGE_DECISION_JSON:-}")" || {
      DISPATCH_RC=2; return 2;
    }
  if [ -n "${UBERDEV_AGENT_PREPARED_REQUEST_JSON:-}" ]; then
    request_json="$(_uberdev_dispatch_python -I -B -c '
import json,sys
request=json.loads(sys.argv[1]); issue=int(sys.argv[2]); tier=sys.argv[3]; backend=sys.argv[4]; workflow=sys.argv[5]
if request.get("issue_num")!=issue or request.get("issue_or_pr")!=issue or request.get("task_tier")!=tier or request.get("backend")!=backend or request.get("workflow")!=workflow:
 raise SystemExit(2)
print(json.dumps(request,sort_keys=True,separators=(",",":")),end="")
' "$UBERDEV_AGENT_PREPARED_REQUEST_JSON" "$ISSUE_NUM" "$TIER" "$UBERDEV_RESOLVED_BACKEND" "${UBERDEV_AGENT_WORKFLOW:-solve}")" || {
      echo "error: prepared route context does not match dispatch identity" >&2
      DISPATCH_RC=2; return 2
    }
  fi
  if [ "${UBERDEV_AGENT_PREPARE_ONLY:-0}" = "1" ]; then
    local decision context metadata created context_file context_sha
    decision="$(uberdev_agent_resolve_request "$request_json")" || { DISPATCH_RC=2; return 2; }
    metadata="$(_uberdev_dispatch_python -I -B -c '
import json,sys
r=json.loads(sys.argv[1]); m={"run_id":r["run_id"],"repository_id":r["repository_id"],"workflow":r["workflow"],"backend":r["backend"],"issue_num":r["issue_num"],"task_tier":r["task_tier"],"risk_signals":r.get("risk_signals",[])}
if "triage_decision" in r: m["triage_decision"]=r["triage_decision"]
print(json.dumps(m,sort_keys=True,separators=(",",":")),end="")
' "$request_json")" || { DISPATCH_RC=2; return 2; }
    created="$(date -u +%FT%TZ)"
    context="$(uberdev_agent_context_create "$run_dir" "$request_json" "$decision" "$provenance" "$metadata" "$created")" || { DISPATCH_RC=2; return 2; }
    context_file="$(_uberdev_agent_json_get "$context" context_file)" || { DISPATCH_RC=2; return 2; }
    context_sha="$(_uberdev_agent_json_get "$context" context_sha256)" || { DISPATCH_RC=2; return 2; }
    _uberdev_dispatch_python -I -B -c '
import json,sys
r=json.loads(sys.argv[1]); r["context_file"]=sys.argv[2]; r["context_sha256"]=sys.argv[3]; r["root_decision"]=json.loads(sys.argv[4])
print(json.dumps(r,sort_keys=True,separators=(",",":")),end="")
' "$request_json" "$context_file" "$context_sha" "$decision"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  uberdev_agent_dispatch "$request_json" "$PROMPT_FILE" "$result_file" "$status_file"
  DISPATCH_RC=$?
  return "$DISPATCH_RC"
}

# Resolve and persist one root request without launching a provider. The
# launcher calls this for every issue before the first claim mutation.
uberdev_dispatch_prepare_root() {
  local issue_num="$1" tier="$2" risk_json="$3" workflow="$4" triage_json="${5:-}" prepared rc saved_prepared had_prepared=0
  UBERDEV_AGENT_RISK_SIGNALS_JSON="$risk_json"
  UBERDEV_AGENT_WORKFLOW="$workflow"
  UBERDEV_AGENT_TRIAGE_DECISION_JSON="$triage_json"
  if [ "${UBERDEV_AGENT_PREPARED_REQUEST_JSON+x}" = x ]; then
    had_prepared=1; saved_prepared="$UBERDEV_AGENT_PREPARED_REQUEST_JSON"
  fi
  unset UBERDEV_AGENT_PREPARED_REQUEST_JSON
  UBERDEV_AGENT_PREPARE_ONLY=1
  export UBERDEV_AGENT_RISK_SIGNALS_JSON UBERDEV_AGENT_WORKFLOW UBERDEV_AGENT_TRIAGE_DECISION_JSON UBERDEV_AGENT_PREPARE_ONLY
  prepared="$(uberdev_dispatch_one "$issue_num" "$tier" /dev/null)"
  rc=$?
  unset UBERDEV_AGENT_PREPARE_ONLY
  if [ "$had_prepared" -eq 1 ]; then export UBERDEV_AGENT_PREPARED_REQUEST_JSON="$saved_prepared"; else unset UBERDEV_AGENT_PREPARED_REQUEST_JSON; fi
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  printf '%s' "$prepared"
}

# --- TOCTOU symlink-swap / pre-creation guard for predictable tmp paths (#155) ---
# Standard dispatch sets $UBERDEV_TMPDIR to a private EUID-owned directory.
# Caller overrides and legacy direct invocation can still select shared roots,
# while bg-stdout / status paths remain intentionally PREDICTABLE so the /goal
# watcher can poll them by name — mktemp-randomisation would break that discovery
# contract. Guard every predictable redirect target before writing: reject a
# symlink (an
# attacker can point it at a victim file so our `>` clobbers it, or so the
# DISPATCH_ID extraction reads attacker-chosen bytes) and reject an entry NOT
# owned by the current EUID (pre-creation in a non-sticky dir) or one that is
# not a regular file. A same-EUID regular file is allowed (legitimate
# re-dispatch — `>` truncates it). Returns non-zero on reject.
_uberdev_dispatch_tmp_target_safe() {
  local target="$1" owner_uid
  if [ -L "$target" ]; then
    echo "error: refusing to write through a symlink at the predicted path: $target (possible TOCTOU symlink-swap)" >&2
    return 1
  fi
  if [ -e "$target" ]; then
    # Probe GNU `stat -c` FIRST, then BSD `stat -f`. Ordering is load-bearing:
    # GNU stat treats `-f` as --file-system, so `stat -f '%u' FILE` on Linux
    # prints filesystem info (non-empty, with a non-zero rc from the bogus '%u'
    # operand) instead of failing cleanly — probing `-f` first there yields a
    # garbage owner_uid that never equals `id -u` and spuriously fail-closes
    # the happy path. The integer-validation below is the backstop: any
    # garbage / empty result → undeterminable → fail CLOSED.
    owner_uid="$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target" 2>/dev/null || true)"
    case "$owner_uid" in ''|*[!0-9]*) owner_uid="" ;; esac
    if [ -z "$owner_uid" ]; then
      # stat unavailable / unparseable in BOTH GNU (-c) and BSD (-f) forms
      # (e.g. busybox / minimal image). We cannot prove the entry is ours, so
      # fail CLOSED — an empty owner_uid must NOT skip the ownership gate (that
      # would let an attacker-owned pre-created file through). The symlink +
      # regular-file checks do NOT backstop ownership, so this is load-bearing.
      echo "error: cannot determine owner of predicted path (stat -c/-f both failed): $target — failing closed" >&2
      return 1
    fi
    if [ "$owner_uid" != "$(id -u)" ]; then
      echo "error: refusing predicted path owned by uid=$owner_uid (expected $(id -u)): $target (possible pre-creation attack)" >&2
      return 1
    fi
    if [ ! -f "$target" ]; then
      echo "error: predicted path exists and is not a regular file: $target" >&2
      return 1
    fi
  fi
  return 0
}

# _uberdev_dispatch_prepare_tmp_target PATH ISSUE_NUM BACKEND
#   Guard PATH (above), then (re)create it 0600-owned-by-us under `set -C`
#   (noclobber) so the create fails if anything races into the path after the
#   guard, and the sticky bit on $UBERDEV_TMPDIR then protects the file we own
#   from a later swap. Emits a dispatch_setup_failed audit + returns 3 on any
#   failure (fail-CLOSED). This is the spec-accepted mitigation (#155): it
#   decisively raises the bar without a C-level O_NOFOLLOW open, which bash
#   redirects cannot express; the residual guard→create window is closed by
#   `set -C`, and the create→use window by the sticky-dir ownership invariant.
_uberdev_dispatch_prepare_tmp_target() {
  local target="$1" issue="$2" backend="$3"
  if ! _uberdev_dispatch_tmp_target_safe "$target"; then
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"tmp_target_unsafe\",\"backend\":\"$backend\",\"rc\":3}"
    return 3
  fi
  rm -f -- "$target" 2>/dev/null
  if ! ( umask 077; set -C; : > "$target" ) 2>/dev/null; then
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"tmp_target_create\",\"backend\":\"$backend\",\"rc\":3}"
    return 3
  fi
  return 0
}

# Read the native-Windows supervisor PID without trusting a pathname between
# validation and read. The descriptor and the current directory entry must
# still name the same single-link regular file; the payload is one positive
# decimal PID and nothing else.
_uberdev_dispatch_read_secure_pid_file() {
  _uberdev_dispatch_python -I -B - "$1" <<'PY'
import os, stat, sys
p = sys.argv[1]
fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(fd)
    current = os.lstat(p)
    if (not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(current.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
        raise SystemExit(1)
    payload = os.read(fd, 64)
    if os.read(fd, 1):
        raise SystemExit(1)
finally:
    os.close(fd)
try:
    text = payload.decode("ascii")
except UnicodeDecodeError:
    raise SystemExit(1)
if not text.isdecimal() or int(text) <= 0:
    raise SystemExit(1)
print(text, end="")
PY
}

# POSIX keeps the historical shell $! bridge. Native Windows instead waits
# for the Python supervisor to publish os.getpid(), because Git Bash's $! is a
# shell compatibility PID and is not the native PID used by Python liveness.
_uberdev_dispatch_capture_supervisor_pid() {
  local launch_pid="$1" pid_file="$2" attempts=0 captured=""
  if [ "$(_uberdev_dispatch_os_class)" != windows-native ]; then
    printf '%s' "$launch_pid" > "$pid_file" || return 1
    _uberdev_dispatch_tmp_target_safe "$pid_file" || return 1
    captured="$(cat "$pid_file" 2>/dev/null || true)"
  else
    while [ "$attempts" -lt 200 ]; do
      if _uberdev_dispatch_tmp_target_safe "$pid_file"; then
        captured="$(_uberdev_dispatch_read_secure_pid_file "$pid_file" 2>/dev/null || true)"
      fi
      [ -n "$captured" ] && break
      sleep 0.025
      attempts=$((attempts + 1))
    done
  fi
  case "$captured" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s' "$captured"
}

# _uberdev_dispatch_path_lookup NAME
#
# Print what a PATH SEARCH would run for NAME, and nothing else.
#
# This is deliberately NOT `command -v`. `command -v` answers "what would THIS
# SHELL run", and that includes shell functions, aliases and builtins: with a
# `bash() { … }` function defined anywhere up the call chain — a debug wrapper,
# a test fixture, an interactive rc file — `command -v bash` prints the bare
# word `bash`, and every `-x` test on that answer is a test of `./bash`.
#
# The child never sees any of that. The background arm reaches its interpreter
# through `os.execvp("bash", …)` (and `shutil.which("bash")` on the Windows
# branch), and the wezterm arm through `wezterm cli spawn -- bash -c`; all
# three are PATH searches performed outside any shell. So the probe has to ask
# the same question, or it refuses dispatches the child would have run fine and
# passes ones it would not.
#
# The execvp semantics reproduced here, deliberately and in order:
#   - a NAME containing a slash is not searched for at all;
#   - an EMPTY PATH element means the current directory;
#   - PATH unset (not merely empty) falls back to `os.defpath`, ":/bin:/usr/bin";
#   - the FIRST executable regular file wins.
# The loop peels elements with parameter expansion rather than word-splitting
# `$PATH`, because `for d in $PATH` under `IFS=:` does not split in zsh and this
# file is sourced by zsh-backed callers.
#
# rc 0 with the path on stdout; rc 1 when nothing on PATH would run.
_uberdev_dispatch_path_lookup() {
  local name="$1" search rest dir candidate
  case "$name" in
    */*)
      # execvp treats this as a path, not a name. No search.
      [ -f "$name" ] && [ -x "$name" ] || return 1
      printf '%s' "$name"
      return 0
      ;;
  esac
  if [ -n "${PATH+set}" ]; then search="$PATH"; else search=":/bin:/usr/bin"; fi
  # The appended separator makes the LAST element visible to the peel loop,
  # including a trailing empty one ("/usr/bin:" also searches the cwd). Braced
  # because `"$search:"` is a modifier expansion in zsh.
  rest="${search}:"
  while :; do
    case "$rest" in
      *:*) dir="${rest%%:*}"; rest="${rest#*:}" ;;
      *) break ;;
    esac
    if [ -n "$dir" ]; then candidate="${dir}/${name}"; else candidate="./${name}"; fi
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# _uberdev_dispatch_preflight_report LOG_FILE MESSAGE
#
# A refusal that reaches only the dispatcher's stderr is invisible where it
# matters. lib/solve-launcher.sh reports every failed dispatch as
# `tail -3 "${DISPATCH_LOG:-/dev/null}"`, so in a /turbo fanout a
# stderr-only refusal prints "(no output captured; check <path>)" and points
# the operator at an EMPTY file — in precisely the scenario this preflight
# exists to make legible. The message goes to BOTH sinks.
#
# The log path is already guarded and 0600-created by
# _uberdev_dispatch_prepare_tmp_target at both call sites, so this only ever
# appends to a target that has passed the #155 TOCTOU checks.
_uberdev_dispatch_preflight_report() {
  local log="$1" message="$2"
  printf '%s\n' "$message" >&2
  [ -n "$log" ] || return 0
  printf '%s\n' "$message" >>"$log" 2>/dev/null || {
    # Not swallowed: the operator has to know the log they are about to read
    # is missing the reason, otherwise an empty tail reads as "no diagnosis".
    printf 'dispatch: warning: the refusal above could not be appended to %s\n' "$log" >&2
  }
  return 0
}

# Wall-clock budget for the child-library probe below, in whole seconds.
#
# Moving the failure earlier also moved a subprocess ACROSS a supervision
# boundary: the same `. "$DISPATCH_LIB"` used to run only in a child the
# dispatcher never waits on, and now runs in the dispatcher's own foreground —
# inside the serial loop `lib/solve-launcher.sh` drives one issue at a time. A
# library that BLOCKS at source time rather than failing to parse (a stalled
# network mount holding the file, a mid-edit save leaving a blocking top-level
# statement) therefore wedges the whole /turbo fanout, not one child. 30 s is
# ~1000x a local read of this file; raise it only for a filesystem that is
# legitimately that slow.
_UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT_DEFAULT=30

# Grace between the deadline's SIGTERM and the SIGKILL that follows it.
#
# timeout(1) signals and then WAITS. A probe that ignores SIGTERM — a library
# whose top level installs `trap '' TERM` mid-edit, or an interpreter wedged in
# a handler — is therefore never cut off at all without `--kill-after`, and the
# budget above degrades from a bound into a suggestion. The grace is short and
# fixed rather than proportional to the budget: it is not "how slow may this
# host be" (that is the budget) but "how long may a process that has already
# been told to die take to die", and the answer does not scale with filesystem
# speed. It deliberately does NOT close the D-state case documented on the
# probe: no signal reaches an uninterruptible syscall.
_UBERDEV_DISPATCH_PREFLIGHT_KILL_GRACE=5

# _uberdev_dispatch_preflight_timeout -> the probe budget, in whole seconds.
# A malformed override is reported and ignored rather than silently taken as
# "no bound" — that is the failure this budget exists to prevent.
_uberdev_dispatch_preflight_timeout() {
  local requested="${UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT:-}"
  case "$requested" in
    '') ;;
    *[!0-9]*|0)
      printf 'dispatch: warning: UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT=%s is not a positive whole number of seconds; using %s\n' \
        "$requested" "$_UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT_DEFAULT" >&2
      ;;
    *) printf '%s' "$requested"; return 0 ;;
  esac
  printf '%s' "$_UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT_DEFAULT"
}

# _uberdev_dispatch_preflight_timeout_bin -> a timeout(1) to bound the probe.
#
# `$TIMEOUT_BIN` is the answer whenever `uberdev_dispatch_resolve_env` has run,
# and in every production path it has: `uberdev_dispatch_preflight_backend`
# resolves it for `background` and `wezterm` and REFUSES the workflow outright
# on a host with neither timeout(1) nor gtimeout(1), so a real dispatch never
# reaches this probe without one, and it is tried FIRST here. The remaining
# candidates are NOT a second copy of that policy — they are a fallback for
# callers that drive an arm directly without the resolver (the dispatch test
# harnesses do exactly that), so the bound holds there too instead of depending
# on a variable somebody else was supposed to set.
#
# Every candidate — `$TIMEOUT_BIN` included — is put through
# `_uberdev_dispatch_path_lookup` rather than used as written. The resolver
# sets `TIMEOUT_BIN=timeout` (a BARE NAME) on the `command -v` branch, and a
# bare name in command position is answered by the shell's function table
# first: a `timeout` function anywhere up the call chain would then stand in
# for the bound itself. That is T15's fault in a second costume, so it gets
# T15's remedy — resolve to a path, exactly as the child's exec would.
#
# rc 0 with the binary on stdout; rc 1 when this host has no timeout(1) at all.
_uberdev_dispatch_preflight_timeout_bin() {
  local candidate resolved
  # `/usr/bin/timeout` before the PATH names for the RFC 0004 §3.8 reason the
  # resolver gives: on Windows the MSYS coreutils build lives there and is not
  # necessarily on PATH.
  for candidate in "${TIMEOUT_BIN:-}" /usr/bin/timeout timeout gtimeout; do
    [ -n "$candidate" ] || continue
    if resolved="$(_uberdev_dispatch_path_lookup "$candidate")"; then
      printf '%s' "$resolved"
      return 0
    fi
  done
  return 1
}

# _uberdev_dispatch_preflight_child_lib ISSUE_NUM BACKEND [LOG_FILE]
#
# #384 — the one window no teardown covers. A child wrapper's first safe
# instruction is `. "$DISPATCH_LIB"`; by the time it runs, the worktree and its
# branch already exist, and `_uberdev_dispatch_cleanup_child_worktree` plus
# every preservation guard it depends on still live only in the file that just
# failed to load. A guardless inline `git worktree remove` there would invert
# the very safety property those guards exist to hold, so the failure is moved
# EARLIER instead: refuse before `git worktree add` runs, while there is still
# nothing on disk to strand.
#
# The probe runs in a FRESH `bash -c`, never in this shell, for two reasons:
#   - re-sourcing here proves nothing — the guard at the top of this file
#     short-circuits on `_UBERDEV_DISPATCH_LOADED=1` and returns immediately,
#     and every function the child needs is already defined in this process; and
#   - `bash` IS the child's interpreter. The background arm reaches it through
#     `os.execvp("bash", ...)` inside a nohup'd python that inherited this
#     process's PATH, environment and cwd, so the probe resolves the same
#     binary and starts from the same state the wrapper will.
# That last point is a CONTRACT between two sites that no compiler compares:
# the interpreter resolved HERE and the one each wrapper actually spawns. It is
# resolved by _uberdev_dispatch_path_lookup — an execvp-shaped PATH search —
# and NOT by `command -v`, which answers for THIS shell (functions and aliases
# included) about a process that has neither.
# It is NOT expressed as a `# CONTRACT:` marker: that mechanism compares closed
# VOCABULARIES and rejects anything under tests/contract_markers.py's
# MIN_MEMBERS=2, and this contract's vocabulary is the single token `bash`.
# The binding is enforced behaviourally instead, by
# tests/dispatch-child-worktree-teardown.test.sh T16: it records which
# interpreter sourced the library at the probe and at the wrapper during one
# real dispatch, and reds when the two diverge. T15/T15b hold the resolver
# itself.
# It also asserts the teardown entry point is REACHABLE after the source rather
# than just that the source returned 0 — a truncated or partially checked-out
# library does the latter and still leaves the child with no teardown. Those two
# outcomes are DIFFERENT faults with different remedies, so they get different
# refusals: probe rc 4 is "loaded, symbol absent" (an incomplete file), anything
# else non-zero is "did not load" (unreadable, absent, a syntax error). Only the
# probe body produces 4, and an ambiguous rc falls to the conservative
# did-not-load wording rather than asserting a shape it cannot see.
#
# HONEST LIMIT — this NARROWS the window; it does not close it:
#   - the library can still be made unloadable BETWEEN this probe and the
#     child's own source (a mid-edit save). That residual is why both wrappers
#     keep naming the worktree on stderr before `exit 126` — the backstop is
#     still load-bearing, not vestigial.
#   - for the wezterm arm the pane's `bash` is resolved by the long-lived
#     wezterm mux server's environment, not by ours, and the pane's cwd is the
#     worktree rather than our cwd; there this is a close proxy, not an exact
#     rehearsal.
#   - the wrapper's three python/argv validations sit in the same pre-source
#     window and are NOT covered here — this proves the LIBRARY is loadable,
#     not that the argv survived the trip. They are no longer silent: each one
#     now names the worktree it strands before `exit 126`, and
#     tests/dispatch-child-worktree-teardown.test.sh T18 holds that for both
#     arms.
#   - the wall-clock bound rests on timeout(1) delivering SIGTERM and then, if
#     that is ignored, SIGKILL. A probe wedged in an uninterruptible syscall
#     (the classic D-state NFS stall) outlives BOTH, and no signal would help;
#     the bound turns "the dispatcher hangs forever" into "the dispatcher hangs
#     as long as the kernel does", which is as far as a userspace probe reaches.
#     It also needs a timeout(1) to exist. A host with none runs this probe
#     unbounded — but that host has already been refused by
#     `uberdev_dispatch_preflight_backend` for both arms that call this, so the
#     uncovered case is a caller that skipped the resolver, not a dispatch.
#     Signalling alone is NOT the whole bound: the dispatcher must also not be
#     waiting on something timeout(1) does not supervise. That is why the probe
#     transcript goes to a file rather than through `$(...)` — a command
#     substitution waits for EOF on the capture pipe, which an orphan spawned
#     at source time keeps open long after the interpreter and the timeout have
#     both exited. Both escapes are held by T22.
#
# rc 0  the child can load the library and reach the teardown.
# rc 1  it cannot, and nothing has been created, so nothing has leaked.

_uberdev_dispatch_preflight_child_lib() {
  local issue="$1" backend="$2" log="${3:-}"
  local lib="$_UBERDEV_DISPATCH_FILE" child_bash probe_out probe_rc=0
  local timeout_bin probe_budget probe_out_file
  local probe_cmd=()
  child_bash="$(_uberdev_dispatch_path_lookup bash)" || child_bash=''
  if [ -z "$child_bash" ]; then
    # The PATH value is deliberately NOT interpolated: this message is read
    # through `tail -3` of a log, where a 4KB line buries the other two, and
    # `echo $PATH` is the operator's obvious next command anyway.
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: refusing to create a child worktree for issue %s — the child wrapper is a `bash -c` body and a PATH search found no executable `bash`. Nothing was created.' \
      "$backend" "$issue")"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"dispatch_lib_preflight\",\"backend\":\"$backend\",\"rc\":1}"
    return 1
  fi
  probe_budget="$(_uberdev_dispatch_preflight_timeout)"
  timeout_bin="$(_uberdev_dispatch_preflight_timeout_bin)" || timeout_bin=''
  # Built as an ARRAY, never as an unquoted `${TIMEOUT_BIN:+$TIMEOUT_BIN 30}`:
  # zsh does not word-split unquoted parameter expansions, so that idiom would
  # try to exec one file literally named `timeout 30` here. Bash+zsh array.
  # `-k` is what makes the deadline a BOUND rather than a request. It adds no
  # portability assumption this probe did not already make: the 124 branch
  # below only reads as "I killed it" on a timeout(1) that reports 124 for a
  # deadline, and every implementation that does (GNU coreutils, busybox) also
  # takes --kill-after. The resolver above is what pins that build on Windows.
  [ -z "$timeout_bin" ] || probe_cmd=( "$timeout_bin" -k "$_UBERDEV_DISPATCH_PREFLIGHT_KILL_GRACE" "$probe_budget" )
  # 3 = the source itself failed; 4 = it loaded and the teardown is absent.
  # `</dev/null` because a library that reads at source time would otherwise eat
  # the DISPATCHER's stdin on a probe that then reported success. The child
  # never has that stdin either — the background arm is nohup'd and the wezterm
  # arm runs in a pane — so closing it is also the more faithful rehearsal.
  probe_cmd+=( "$child_bash" -c '
    . "$1" || exit 3
    command -v _uberdev_dispatch_cleanup_child_worktree >/dev/null 2>&1 || exit 4
  ' _ "$lib" )
  # The transcript goes to a FILE, not through `$(...)`. A command substitution
  # waits for EOF on the capture pipe rather than for timeout(1)'s child, and a
  # library that BACKGROUNDS anything at source time hands that write end to an
  # orphan: the interpreter exits 0 at once, timeout never fires, and the
  # dispatcher then blocks on the orphan for as long as it lives — past the
  # budget, with no refusal and nothing in the log. Reading a regular file
  # after the wait cannot block on a writer that is still holding it open.
  probe_out_file="${UBERDEV_TMPDIR:-/tmp}/dispatch-lib-preflight-$backend-$issue.out"
  if ! _uberdev_dispatch_prepare_tmp_target "$probe_out_file" "$issue" "$backend"; then
    # Fail CLOSED. Running the probe with its transcript redirected somewhere
    # unguarded, or with no transcript at all, is exactly the unbounded
    # foreground subprocess this budget exists to prevent.
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: refusing to create a child worktree for issue %s — the dispatch-library probe could not create its transcript at %s (see the error above). Nothing was created.' \
      "$backend" "$issue" "$probe_out_file")"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"dispatch_lib_preflight\",\"backend\":\"$backend\",\"rc\":1}"
    return 1
  fi
  "${probe_cmd[@]}" </dev/null >"$probe_out_file" 2>&1 || probe_rc=$?
  if ! probe_out="$(cat "$probe_out_file" 2>/dev/null)"; then
    # Not swallowed: an unreadable transcript is otherwise indistinguishable
    # from an empty one, and the operator would read "no diagnosis" as "the
    # probe said nothing".
    probe_out="(the probe transcript at $probe_out_file could not be read)"
  fi
  rm -f -- "$probe_out_file" 2>/dev/null
  # 124 is timeout(1)'s "I killed it"; 137 is 128+SIGKILL, which is what the
  # `-k` escalation above exits with when the first SIGTERM was ignored. Both
  # are the same fault with the same remedy, so both get the stall wording —
  # folding 137 into "cannot load" would send the operator hunting a syntax
  # error in a file that never got the chance to have one. Guarded on the
  # wrapper actually being in front, so a library that itself `exit 124`s at
  # source time is still read as a load failure rather than as a stall that
  # never happened.
  if [ -n "$timeout_bin" ] && { [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; }; then
    # Its OWN wording, not folded into "cannot load": that refusal sends the
    # operator hunting a syntax error in a file that may be perfectly valid.
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: refusing to create a child worktree for issue %s — the child interpreter %s did not finish loading the dispatch library %s within %ss, so the probe was killed (rc %s; 137 means it ignored the deadline SIGTERM and was SIGKILLed %ss later). The file is not failing, it is BLOCKING (a stalled mount, or a save caught mid-write); the child would block on it the same way, and the dispatcher cannot wait on that with the rest of the fanout behind it. Nothing was created. Raise UBERDEV_DISPATCH_PREFLIGHT_TIMEOUT if this host is legitimately that slow.' \
      "$backend" "$issue" "$child_bash" "$lib" "$probe_budget" "$probe_rc" "$_UBERDEV_DISPATCH_PREFLIGHT_KILL_GRACE")"
  elif [ "$probe_rc" -eq 4 ]; then
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: refusing to create a child worktree for issue %s — the child interpreter %s LOADED the dispatch library %s cleanly, but it does not define `_uberdev_dispatch_cleanup_child_worktree`. The file is readable and valid; it is INCOMPLETE (a truncated write or a partial checkout), so the child would have no teardown. Nothing was created.' \
      "$backend" "$issue" "$child_bash" "$lib")"
  elif [ "$probe_rc" -ne 0 ]; then
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: refusing to create a child worktree for issue %s — the child interpreter %s cannot load the dispatch library %s (probe rc %s). The child teardown lives in that library, so a worktree created now could not be taken back down. Nothing was created.' \
      "$backend" "$issue" "$child_bash" "$lib" "$probe_rc")"
  else
    return 0
  fi
  if [ -n "$probe_out" ]; then
    _uberdev_dispatch_preflight_report "$log" "$(printf '%s dispatch: dispatch library probe reported: %s' "$backend" "$probe_out")"
  fi
  _uberdev_dispatch_audit dispatch_setup_failed \
    "{\"issue\":$issue,\"phase\":\"dispatch_lib_preflight\",\"backend\":\"$backend\",\"rc\":1}"
  return 1
}

# _uberdev_dispatch_background ISSUE_NUM TIER PROMPT_FILE
# Dependency-free fallback: explicit `git worktree add` + detached headless
# `claude -p`. Sets DISPATCH_RC and DISPATCH_ID (the detached pid).
_uberdev_dispatch_background() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local WORKTREE_RELATIVE=".claude/worktrees/solve-issue-$ISSUE_NUM"
  local WORKTREE_BRANCH="worktree-solve-issue-$ISSUE_NUM"
  local LOG_FILE="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  local STATUS_FILE="${UBERDEV_AGENT_STATUS_FILE:-${UBERDEV_TMPDIR:-/tmp}/solve-bg-status-$ISSUE_NUM.json}"
  local RESULT_FILE="${UBERDEV_AGENT_RESULT_FILE:-${UBERDEV_TMPDIR:-/tmp}/solve-bg-result-$ISSUE_NUM.md}"
  local REPOSITORY_ROOT WORKTREE_DIR
  # #381 RULING 4: a routed child (agent_id set -> CHILD_OWNED=1) owns its
  # isolated worktree for the length of one bounded task, so the dispatcher —
  # not the operator — must take it back down. A top-level /solve dispatch
  # (CHILD_OWNED=0) keeps its worktree: that one IS the deliverable workspace.
  local CHILD_OWNED="${UBERDEV_AGENT_CHILD_OWNED:-0}"
  local CLEANUP_START_HEAD=''
  REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"repository\",\"backend\":\"background\",\"rc\":1}"
    return 1
  }
  REPOSITORY_ROOT="$(cd "$REPOSITORY_ROOT" 2>/dev/null && pwd -P)" || { DISPATCH_RC=1; return 1; }
  WORKTREE_DIR="$REPOSITORY_ROOT/$WORKTREE_RELATIVE"
  # Captured BEFORE any mutation: without a pinned start commit the teardown
  # cannot tell "nothing happened here" from "the child committed", so it would
  # have to choose between leaking and destroying. Fail closed here instead —
  # no worktree exists yet, so there is nothing to leak.
  if [ "$CHILD_OWNED" = "1" ]; then
    CLEANUP_START_HEAD="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD 2>/dev/null)" || {
      DISPATCH_RC=1
      _uberdev_dispatch_audit dispatch_setup_failed \
        "{\"issue\":$ISSUE_NUM,\"phase\":\"start_head\",\"backend\":\"background\",\"rc\":1}"
      return 1
    }
  fi
  # TOCTOU hardening (#155): guard + 0600-create the predictable log + pid
  # paths before any redirect writes to them (world-writable $UBERDEV_TMPDIR).
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE.pid" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$RESULT_FILE" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  # #384: the last statement before anything exists to leak. Deliberately NOT
  # scoped by CHILD_OWNED — the teardown boundary is, but this is a
  # precondition: a child that cannot load this library never does any work for
  # anybody, so creating a worktree for it is pure cost either way.
  # $LOG_FILE is passed, not just recorded in DISPATCH_LOG: the /turbo fanout
  # report tails that file, so a refusal that never lands in it is reported as
  # "(no output captured)".
  if ! _uberdev_dispatch_preflight_child_lib "$ISSUE_NUM" background "$LOG_FILE"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    return 1
  fi
  # Explicit dispatcher-controlled worktree — sidesteps the Windows
  # worktree-isolation bug #40164 in the --bg backend's own --worktree path
  # handling. MSYS_NO_PATHCONV stops Git Bash rewriting the POSIX path.
  if ! _uberdev_dispatch_git_worktree_add \
      "$REPOSITORY_ROOT" "$WORKTREE_DIR" "$WORKTREE_BRANCH" "$LOG_FILE" "$CLEANUP_START_HEAD"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"worktree\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  local PROMPT_BODY
  # B5 fix (prompt-read): an unreadable $PROMPT_FILE would otherwise leave
  # PROMPT_BODY="" and dispatch `claude -p ""` (garbage agent), with the
  # audit event happily reporting success. Guard the cat read and surface
  # the failure as a dispatch_setup_failed audit + rc=1.
  if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$LOG_FILE")"; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" background prompt_read 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  # BG_TURBO_ENV: UBERDEV_TURBO + SKIP_PERMISSIONS propagation across the env(1)
  # boundary, per RFC 0005 §2.3 (scoped-relaxation contract).
  local BG_TURBO_ENV=()
  [[ "${AUTO_MODE:-0}" == "1" ]] && BG_TURBO_ENV=( UBERDEV_TURBO=1 )
  [[ "${SKIP_PERMISSIONS:-0}" == "1" ]] && BG_TURBO_ENV+=( SKIP_PERMISSIONS=1 )
  # Detached wrapper preserves the exact provider argv while atomically
  # maintaining the canonical running/terminal status consumed by lifecycle
  # reconciliation. DISPATCH_ID is the wrapper PID, so kill -0 and status
  # describe the same lifetime.
  local PROVIDER_CMD=( env )
  [ "${#BG_TURBO_ENV[@]}" -eq 0 ] || PROVIDER_CMD+=( "${BG_TURBO_ENV[@]}" )
  PROVIDER_CMD+=( claude -p "$PROMPT_BODY" --model "$MODEL" )
  [ "${#PERM_FLAG[@]}" -eq 0 ] || PROVIDER_CMD+=( "${PERM_FLAG[@]}" )
  [ "${#EFFORT_FLAG[@]}" -eq 0 ] || PROVIDER_CMD+=( "${EFFORT_FLAG[@]}" )
  if ! _uberdev_dispatch_resolve_python; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" background python_launcher 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  local PYTHON_LAUNCH=( "$_UBERDEV_PYTHON_EXE" )
  [ -z "$_UBERDEV_PYTHON_PREFIX" ] || PYTHON_LAUNCH+=( "$_UBERDEV_PYTHON_PREFIX" )
  UBERDEV_SUPERVISOR_PID_FILE="$STATUS_FILE.pid" nohup "${PYTHON_LAUNCH[@]}" -I -c 'import os,shutil,stat,subprocess,sys,traceback
argv=["bash","-c",*sys.argv[1:]]
if os.name=="nt":
 pid_path=os.environ["UBERDEV_SUPERVISOR_PID_FILE"]
 fd=os.open(pid_path,os.O_WRONLY|getattr(os,"O_NOFOLLOW",0))
 try:
  opened=os.fstat(fd); current=os.lstat(pid_path)
  if not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(current.st_mode) or opened.st_nlink!=1 or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino): raise RuntimeError("unsafe supervisor pid file")
  payload=str(os.getpid()).encode("ascii")
  if os.write(fd,payload)!=len(payload): raise RuntimeError("short supervisor pid write")
  os.ftruncate(fd,len(payload)); os.fsync(fd)
 finally: os.close(fd)
 os.environ["UBERDEV_WRAPPER_PID"]=str(os.getpid())
 flags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
 diagnostic=os.environ.get("UBERDEV_DETACH_DIAGNOSTICS")=="1"
 bash_path=shutil.which("bash")
 launch_argv=[bash_path]
 if diagnostic: launch_argv.append("-x")
 launch_argv.extend(["-c",*sys.argv[1:]])
 if diagnostic: print(f"detach diagnostic: bash={bash_path!r} cwd={os.getcwd()!r} flags={flags} argv={launch_argv!r}",file=sys.stderr,flush=True)
 try: child=subprocess.Popen(launch_argv,stdout=sys.stdout,stderr=sys.stderr,creationflags=flags)
 except BaseException:
  if diagnostic: traceback.print_exc(file=sys.stderr)
  raise
 if diagnostic: print(f"detach diagnostic: child_pid={child.pid}",file=sys.stderr,flush=True)
 rc=child.wait()
 if diagnostic: print(f"detach diagnostic: child_rc={rc}",file=sys.stderr,flush=True)
 raise SystemExit(rc)
os.setsid()
os.execvp("bash",argv)' '
    PYTHON_EXE="$1"; PYTHON_PREFIX="$2"; DISPATCH_LIB="$3"; shift 3
    WORKTREE_DIR="$1"; STATUS_FILE="$2"; RESULT_FILE="$3"; ISSUE_NUM="$4"; TIER="$5"
    REPOSITORY_ROOT="$6"; WORKTREE_RELATIVE="$7"; WORKTREE_BRANCH="$8"
    CLEANUP_START_HEAD="$9"; CHILD_OWNED="${10}"; shift 10
    # The worktree argv is unpacked FIRST so the validations below can name what
    # they are about to strand. #384: these three sit in the same pre-source
    # window as the `. "$DISPATCH_LIB"` failure — the worktree and branch exist,
    # the teardown does not — and every one of them used to `exit 126` in total
    # silence, leaking both with no trace anywhere. They are not covered by the
    # dispatcher preflight either: it proves the LIBRARY is loadable, not that
    # this argv survived the trip. Same ruling as the source failure: report by
    # name, never force-remove without the guards that live in $DISPATCH_LIB.
    report_presource_leak() {
      [ "$CHILD_OWNED" != "1" ] || printf "background dispatch: %s; child worktree %s (%s) is left in place and needs manual removal\n" \
        "$1" "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
    }
    case "$PYTHON_PREFIX" in ""|-3) ;; *) report_presource_leak "refusing an unrecognised python launcher prefix '\''$PYTHON_PREFIX'\''"; exit 126 ;; esac
    [ -n "$PYTHON_EXE" ] && [ -x "$PYTHON_EXE" ] || { report_presource_leak "python launcher '\''$PYTHON_EXE'\'' is missing or not executable"; exit 126; }
    _UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"
    run_python() {
      if [ -n "$PYTHON_PREFIX" ]; then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi
    }
    python3() { run_python "$@"; }
    export -n -f run_python python3 2>/dev/null || { report_presource_leak "this interpreter cannot scope the python3 shim (export -f unsupported)"; exit 126; }
    # The window no teardown can cover: the teardown transaction and every
    # preservation guard it depends on live in $DISPATCH_LIB, so before this
    # line there is nothing safe to call. A guardless inline `git worktree
    # remove` here would be the exact destructive shortcut those guards exist
    # to forbid. So this leak is REPORTED and left for the operator, not
    # silently absorbed and not force-removed.
    #
    # #384 NARROWED this window; it did not close it. Before creating the
    # worktree the dispatcher now runs this same source, under this same
    # interpreter, in a fresh process (_uberdev_dispatch_preflight_child_lib)
    # and refuses outright if it fails. What survives is the interval between
    # that probe and this line — a mid-edit save, a checkout landing under us.
    # This report is the backstop for that remainder, not dead code.
    . "$DISPATCH_LIB" || {
      [ "$CHILD_OWNED" != "1" ] || printf "background dispatch: cannot source %s; child worktree %s (%s) is left in place and needs manual removal\n" \
        "$DISPATCH_LIB" "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
      exit 126
    }
    WRAPPER_PID="${UBERDEV_WRAPPER_PID:-$$}"
    EMPTY_VALUE=
    WORKTREE_CLEANUP_DONE=0
    write_status() {
      _uberdev_agent_publish_status_record "$STATUS_FILE" provider background "$1" "$2" "$WRAPPER_PID" \
        "$EMPTY_VALUE" "$EMPTY_VALUE" "$ISSUE_NUM" "$TIER" \
        "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" 0
    }
    # #381 RULING 4: the dispatcher created this worktree, so this wrapper — the
    # process that owns the child lifetime — takes it back down. Runs from
    # REPOSITORY_ROOT in a subshell because our own cwd IS the worktree being
    # removed. Failure is surfaced on stderr and folded into the child rc; it is
    # never swallowed into a "completed".
    cleanup_child_worktree() {
      [ "$WORKTREE_CLEANUP_DONE" -eq 0 ] || return 0
      if [ "$CHILD_OWNED" != "1" ]; then WORKTREE_CLEANUP_DONE=1; return 0; fi
      if (
        cd "$REPOSITORY_ROOT" || exit 2
        . "$DISPATCH_LIB" || exit 2
        _uberdev_dispatch_cleanup_child_worktree "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" \
          "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$1"
      ); then
        WORKTREE_CLEANUP_DONE=1
        return 0
      fi
      printf "background dispatch: failed to clean child worktree %s (%s)\n" \
        "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
      return 2
    }
    # Armed BEFORE the cd: a failed `cd` into the worktree, or a signal landing
    # between here and the full finalizer below, is still a terminal child and
    # must not strand the worktree.
    trap '\''cleanup_child_worktree cancelled || true'\'' EXIT
    write_status running null || exit 126
    cd "$WORKTREE_DIR" || { write_status failed 127; exit 127; }
    TMP_RESULT="${RESULT_FILE}.partial.${WRAPPER_PID}"
    TMP_RESULT_ID="$(run_python -I -c '\''import os,sys; p=sys.argv[1]; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600); os.fchmod(fd,0o600) if os.name!="nt" else None; e=os.fstat(fd); os.close(fd); print(f"{e.st_dev}:{e.st_ino}",end="")'\'' "$TMP_RESULT")" \
      || { write_status failed 126; exit 126; }
    cleanup_partial() {
      run_python -I -c '\''import os,stat,sys; p,identity=sys.argv[1:]; parent,name=os.path.dirname(p),os.path.basename(p)
if os.name=="nt":
 try:
  e=os.lstat(p)
  if stat.S_ISREG(e.st_mode) and not stat.S_ISLNK(e.st_mode) and e.st_nlink==1 and f"{e.st_dev}:{e.st_ino}"==identity: os.unlink(p)
 except FileNotFoundError: pass
 raise SystemExit(0)
d=os.open(parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); f=None
try:
 f=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=d); e=os.fstat(f); c=os.stat(name,dir_fd=d,follow_symlinks=False)
 if stat.S_ISREG(e.st_mode) and e.st_uid==os.geteuid() and e.st_nlink==1 and stat.S_IMODE(e.st_mode)==0o600 and f"{e.st_dev}:{e.st_ino}"==identity and (e.st_dev,e.st_ino)==(c.st_dev,c.st_ino): os.unlink(name,dir_fd=d)
except FileNotFoundError: pass
finally:
 os.close(f) if f is not None else None; os.close(d)'\'' "$TMP_RESULT" "$TMP_RESULT_ID" >/dev/null 2>&1 || true
    }
    finalize_on_exit() {
      cleanup_partial
      # An abnormal exit (signal, unexpected `exit`) is still a terminal state
      # for the child, so the worktree still has to go.
      cleanup_child_worktree cancelled || true
    }
    trap finalize_on_exit EXIT
    trap '\''exit 143'\'' HUP INT TERM
    "$@" > "$TMP_RESULT"
    PROVIDER_RC=$?
    cat "$TMP_RESULT"
    if [ "$PROVIDER_RC" -eq 0 ]; then STATE=completed; else STATE=failed; fi
    if [ "$PROVIDER_RC" -eq 0 ] && [ ! -s "$TMP_RESULT" ]; then
      printf "%s\n" "error: background provider completed without a result" >&2
      PROVIDER_RC=65; STATE=failed
    fi
    if [ "$PROVIDER_RC" -eq 0 ]; then
      run_python -I -c '\''import os,sys; os.replace(sys.argv[1],sys.argv[2])'\'' "$TMP_RESULT" "$RESULT_FILE" \
        || { rm -f -- "$TMP_RESULT"; write_status failed 126; exit 126; }
    else
      rm -f -- "$TMP_RESULT"
    fi
    if ! cleanup_child_worktree "$STATE"; then
      PROVIDER_RC=74; STATE=failed
    fi
    trap - EXIT HUP INT TERM
    write_status "$STATE" "$PROVIDER_RC" || exit 126
    exit "$PROVIDER_RC"
  ' _ "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE" "$WORKTREE_DIR" "$STATUS_FILE" "$RESULT_FILE" "$ISSUE_NUM" "$TIER" \
    "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED" "${PROVIDER_CMD[@]}" \
    >"$LOG_FILE" 2>&1 &
  DISPATCH_RC=$?
  local LAUNCH_PID="$!"
  disown "$LAUNCH_PID" 2>/dev/null || true
  if ! DISPATCH_ID="$(_uberdev_dispatch_capture_supervisor_pid "$LAUNCH_PID" "$STATUS_FILE.pid")"; then
    kill -TERM "$LAUNCH_PID" 2>/dev/null || true
    DISPATCH_LOG="$LOG_FILE"
    # The SIGTERM above races the wrapper's own EXIT trap, which is armed only
    # once it has sourced this library — so the wrapper may die before it can
    # ever tear the worktree down. Tear it down from here too. Both teardowns
    # take the same mutex, and the loser observes absent:absent and returns 0,
    # so the double call is safe rather than merely tolerated.
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" background pid_target_unsafe 3 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    rm -f "$STATUS_FILE.pid" 2>/dev/null || true
    return "$DISPATCH_RC"
  fi
  # S10 cleanup: $STATUS_FILE.pid is a one-shot inter-subshell side file
  # whose only purpose is bridging the pid back from the subshell above.
  # Delete it now so a subsequent rerun for the same issue cannot read a
  # stale pid (the canonical record lives in $STATUS_FILE below).
  rm -f "$STATUS_FILE.pid" 2>/dev/null || true
  # The wrapper may already be terminal before the parent observes its owned
  # session. Preserve its exact launch handle only when the canonical status
  # and result/exit evidence prove that immediate terminal race.
  if [[ -n "$DISPATCH_ID" ]] && ! _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"; then
    if ! _uberdev_dispatch_accept_immediate_terminal background "$DISPATCH_ID" "$STATUS_FILE" "$RESULT_FILE" >/dev/null; then
      DISPATCH_ID=""
    fi
  fi
  if [[ "$DISPATCH_RC" -eq 0 && -n "$DISPATCH_ID" ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"background\",\"pid\":\"$DISPATCH_ID\",\"log\":\"$LOG_FILE\"}"
  else
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    # Deliberately NOT a `_uberdev_dispatch_fail_after_worktree` site. Reaching
    # here means the wrapper launched and its pid was captured — only the owned
    # SESSION could not be observed — so a child may be running in that
    # worktree right now, and it owns the teardown through its own EXIT trap.
    # Every arm above this point aborts before any child can be running, which
    # is exactly the line the dispatcher-side teardown is drawn on.
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"background\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
}

# _uberdev_dispatch_wezterm_config
# Idempotently merge the uberdev managed block into ~/.wezterm.lua. The block
# is fenced by BEGIN/END markers; on a re-run the old block is stripped and
# re-appended. The user's own config outside the markers is never touched.
_uberdev_dispatch_wezterm_config() {
  local cfg="${HOME}/.wezterm.lua"
  local begin='-- BEGIN uberdev managed block (RFC 0004) -- do not edit'
  local end='-- END uberdev managed block'
  local tmp="${UBERDEV_TMPDIR:-/tmp}/.wezterm.uberdev.$$"
  # KNOWN LIMITATION (RFC 0004 §3.6 — follow-up amendment): this helper appends a
  # Lua `return { … }` block. If the user's existing `.wezterm.lua` already
  # contains its own `return config`, Lua's first-return-wins semantics mean the
  # managed block's `unix_domains` / `exit_behavior` are unreachable and the
  # `wezterm` backend cannot reach the `uberdev` mux domain. Robust on fresh
  # configs; users with an existing config must integrate the managed values by
  # hand for now. Tracked as a follow-up RFC amendment.
  # Strip any prior managed block, preserving the user's surrounding config.
  if [ -f "$cfg" ]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1} skip && $0==e {skip=0; next} !skip {print}
    ' "$cfg" > "$tmp" || return 1
  else
    : > "$tmp" || return 1
  fi
  # Append a fresh managed block. exit_behavior=Hold keeps a finished or
  # crashed agent pane (and its transcript) visible — the default "Close"
  # makes the pane vanish on exit.
  cat >> "$tmp" <<'LUA' || return 1
-- BEGIN uberdev managed block (RFC 0004) -- do not edit
return {
  unix_domains = { { name = 'uberdev' } },
  exit_behavior = 'Hold',
}
-- END uberdev managed block
LUA
  mv "$tmp" "$cfg" || return 1
}

# _uberdev_dispatch_wezterm ISSUE_NUM TIER PROMPT_FILE
# Spawns each agent as a foreground headless `claude -p` in a visible WezTerm
# pane. Sets DISPATCH_RC and DISPATCH_ID (the spawned pane id).
#
# Intentional asymmetry vs. the background backend: this backend does
# NOT env(1)-wrap the spawn with BG_TURBO_ENV (no UBERDEV_TURBO / SKIP_PERMISSIONS
# propagation). Per design Q4 (see `docs/uberdev/specs/...-goal-skip-permissions-propagation-design.md` §Q4 / Non-goals), wezterm is the attended-mode backend — visible panes,
# operator can approve permission prompts manually — so the cmux PermissionRequest
# stall does not apply. PERM_FLAG argv-threading to the directly-dispatched
# claude -p (line 673) carries `--dangerously-skip-permissions` to the
# first-level child for callers that opt in via SKIP_PERMISSIONS; that is the
# scope wezterm supports today. Nested /turbo→/orchestrator→SDD bypass under
# wezterm is filed as an open question (design doc §Open questions item 2).
_uberdev_dispatch_wezterm() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  if ! _uberdev_dispatch_wezterm_config; then
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"config","backend":"wezterm","rc":1}'
    return 1
  fi
  # RFC §3.6: every `wezterm cli` call in this file passes
  # `--domain-name uberdev` (the probe in _uberdev_dispatch_wezterm_available
  # and the spawn below). That flag — not any env-var pin — is the actual
  # mechanism that keeps fan-out on one mux. No socket-env-var export is
  # used or needed; the domain flag fully determines the target mux.
  local WORKTREE_RELATIVE=".claude/worktrees/solve-issue-$ISSUE_NUM"
  local WORKTREE_BRANCH="worktree-solve-issue-$ISSUE_NUM"
  local LOG_FILE="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  local STATUS_FILE="${UBERDEV_AGENT_STATUS_FILE:-${UBERDEV_TMPDIR:-/tmp}/solve-bg-status-$ISSUE_NUM.json}"
  local REPOSITORY_ROOT WORKTREE_DIR
  # #381 RULING 4 — identical teardown boundary to the background arm: a routed
  # child (CHILD_OWNED=1) gets its isolated worktree removed when it
  # terminalizes; a top-level attended pane keeps its workspace.
  local CHILD_OWNED="${UBERDEV_AGENT_CHILD_OWNED:-0}"
  local CLEANUP_START_HEAD=''
  REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"repository","backend":"wezterm","rc":1}'
    return 1
  }
  REPOSITORY_ROOT="$(cd "$REPOSITORY_ROOT" 2>/dev/null && pwd -P)" || { DISPATCH_RC=1; return 1; }
  WORKTREE_DIR="$REPOSITORY_ROOT/$WORKTREE_RELATIVE"
  if [ "$CHILD_OWNED" = "1" ]; then
    CLEANUP_START_HEAD="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD 2>/dev/null)" || {
      DISPATCH_RC=1
      _uberdev_dispatch_audit dispatch_setup_failed \
        '{"issue":'"$ISSUE_NUM"',"phase":"start_head","backend":"wezterm","rc":1}'
      return 1
    }
  fi
  # TOCTOU hardening (#155): guard + 0600-create the predictable log path
  # before the worktree-add redirect below — the wezterm backend writes the
  # SAME world-writable path the background backend hardens, so it
  # must fail-CLOSED on a symlink/foreign-owned target too.
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "wezterm"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE" "$ISSUE_NUM" "wezterm"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  # #384, same placement and same rationale as the background arm: refuse while
  # there is still nothing on disk. A pane whose spawn SUCCEEDS and whose body
  # then dies at `. "$DISPATCH_LIB"` is the worst shape of this bug — the
  # dispatcher sees a pane id, so no dispatcher-side teardown ever runs.
  if ! _uberdev_dispatch_preflight_child_lib "$ISSUE_NUM" wezterm "$LOG_FILE"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    return 1
  fi
  # The backend runs its own worktree add — a pane's `claude -p` does not get
  # native --worktree. Absolute path, quoted (repo path may contain spaces).
  # MSYS_NO_PATHCONV stops Git Bash rewriting the path.
  if ! _uberdev_dispatch_git_worktree_add \
      "$REPOSITORY_ROOT" "$WORKTREE_DIR" "$WORKTREE_BRANCH" "$LOG_FILE" "$CLEANUP_START_HEAD"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"worktree","backend":"wezterm","rc":1}'
    return 1
  fi
  local WORKTREE_ABS WORKTREE_NATIVE STATUS_FILE_NATIVE
  if ! WORKTREE_ABS="$(cd "$WORKTREE_DIR" && pwd -P)"; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" wezterm worktree_path 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  if ! WORKTREE_NATIVE="$(_uberdev_dispatch_native_cli_path "$WORKTREE_ABS")" \
      || ! STATUS_FILE_NATIVE="$(_uberdev_dispatch_native_cli_path "$STATUS_FILE")"; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" wezterm native_path 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  local PROMPT_BODY
  # B5 fix (prompt-read), mirrored from the `background` backend: an
  # unreadable $PROMPT_FILE would otherwise leave PROMPT_BODY="" and spawn
  # `claude -p ""` into the pane (garbage agent), with the audit event
  # happily reporting success. Guard the cat read and surface the failure
  # as a dispatch_setup_failed audit + rc=1.
  if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$LOG_FILE")"; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" wezterm prompt_read 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  if ! _uberdev_dispatch_resolve_python; then
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" wezterm python_launcher 1 \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
    return "$DISPATCH_RC"
  fi
  # wezterm cli spawn into the pinned uberdev domain. Foreground claude -p
  # (headless print mode streaming into the pane) — detaching would empty the
  # pane. MSYS2_ARG_CONV_EXCL prevents blanket rewriting of child Bash argv;
  # only the native wezterm cwd and native-Python status path were normalized
  # explicitly above.
  #
  # B4 fix: capture the spawn rc IMMEDIATELY after the `$(...)` close. Before
  # this change the only gate was `[ -z "$DISPATCH_ID" ]`, which missed the
  # case where `wezterm cli spawn` exits non-zero AND prints a partial token
  # to stdout — the partial string was then treated as a valid pane id. AND-
  # gating SPAWN_RC=0 with the non-empty check covers both failure shapes.
  local SPAWN_RC
  local PROVIDER_CMD=( claude -p "$PROMPT_BODY" --model "$MODEL" )
  [ "${#PERM_FLAG[@]}" -eq 0 ] || PROVIDER_CMD+=( "${PERM_FLAG[@]}" )
  [ "${#EFFORT_FLAG[@]}" -eq 0 ] || PROVIDER_CMD+=( "${EFFORT_FLAG[@]}" )
  DISPATCH_ID="$(MSYS2_ARG_CONV_EXCL='*' wezterm cli spawn \
    --domain-name uberdev --cwd "$WORKTREE_NATIVE" -- \
    bash -c '
      PYTHON_EXE="$1"; PYTHON_PREFIX="$2"; DISPATCH_LIB="$3"; shift 3
      STATUS_FILE="$1"; ISSUE_NUM="$2"; TIER="$3"
      REPOSITORY_ROOT="$4"; WORKTREE_RELATIVE="$5"; WORKTREE_BRANCH="$6"
      CLEANUP_START_HEAD="$7"; CHILD_OWNED="$8"; WORKTREE_DIR="$9"; shift 9
      # Same ruling and same reordering as the background arm: the worktree argv
      # is unpacked first so these three pre-source validations can name what
      # they would strand instead of exiting 126 in silence. The pane is the
      # only process that could ever remove this worktree, so a silent death
      # here leaks it with the dispatcher believing the spawn succeeded.
      report_presource_leak() {
        [ "$CHILD_OWNED" != "1" ] || printf "wezterm dispatch: %s; child worktree %s (%s) is left in place and needs manual removal\n" \
          "$1" "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
      }
      case "$PYTHON_PREFIX" in ""|-3) ;; *) report_presource_leak "refusing an unrecognised python launcher prefix '\''$PYTHON_PREFIX'\''"; exit 126 ;; esac
      [ -n "$PYTHON_EXE" ] && [ -x "$PYTHON_EXE" ] || { report_presource_leak "python launcher '\''$PYTHON_EXE'\'' is missing or not executable"; exit 126; }
      _UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"
      run_python() {
        if [ -n "$PYTHON_PREFIX" ]; then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi
      }
      python3() { run_python "$@"; }
      export -n -f run_python python3 2>/dev/null || { report_presource_leak "this interpreter cannot scope the python3 shim (export -f unsupported)"; exit 126; }
      # Same pre-source window as the background wrapper, same ruling: report
      # the worktree by name rather than force-remove it without the guards
      # that live in $DISPATCH_LIB. Also narrowed by the #384 preflight, and
      # narrowed LESS here: the bash that runs this body is resolved by the
      # wezterm mux server, not by the process that ran the probe.
      . "$DISPATCH_LIB" || {
        [ "$CHILD_OWNED" != "1" ] || printf "wezterm dispatch: cannot source %s; child worktree %s (%s) is left in place and needs manual removal\n" \
          "$DISPATCH_LIB" "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
        exit 126
      }
      WRAPPER_PID="$$"
      EMPTY_VALUE=
      WORKTREE_CLEANUP_DONE=0
      write_status() {
        _uberdev_agent_publish_status_record "$STATUS_FILE" provider wezterm "$1" "$2" \
          "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$ISSUE_NUM" "$TIER" \
          "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" 0
      }
      # #381 RULING 4 — same teardown contract as the background arm. The pane
      # cwd IS the worktree, so the transaction runs from REPOSITORY_ROOT in a
      # subshell. A failure is printed into the pane and folded into the rc.
      cleanup_child_worktree() {
        [ "$WORKTREE_CLEANUP_DONE" -eq 0 ] || return 0
        if [ "$CHILD_OWNED" != "1" ]; then WORKTREE_CLEANUP_DONE=1; return 0; fi
        if (
          cd "$REPOSITORY_ROOT" || exit 2
          . "$DISPATCH_LIB" || exit 2
          _uberdev_dispatch_cleanup_child_worktree "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" \
            "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$1"
        ); then
          WORKTREE_CLEANUP_DONE=1
          return 0
        fi
        printf "wezterm dispatch: failed to clean child worktree %s (%s)\n" \
          "$WORKTREE_DIR" "$WORKTREE_BRANCH" >&2
        return 2
      }
      # Armed BEFORE `write_status running`, mirroring the background wrapper:
      # that call can `exit 126`, and every other `exit` between here and the
      # finalizer below is likewise a terminal pane with a worktree already on
      # disk. Signal-only traps left all of those leaking silently, because a
      # plain `exit` is not a signal. cleanup_child_worktree is idempotent via
      # WORKTREE_CLEANUP_DONE, so the signal arm firing first costs nothing.
      trap '\''cleanup_child_worktree cancelled || true'\'' EXIT
      trap '\''cleanup_child_worktree cancelled || true; exit 143'\'' HUP INT TERM
      write_status running null || exit 126
      "$@"
      PROVIDER_RC=$?
      if [ "$PROVIDER_RC" -eq 0 ]; then STATE=completed; else STATE=failed; fi
      if ! cleanup_child_worktree "$STATE"; then
        PROVIDER_RC=74; STATE=failed
      fi
      trap - EXIT HUP INT TERM
      write_status "$STATE" "$PROVIDER_RC" || exit 126
      exit "$PROVIDER_RC"
    ' _ "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE" "$STATUS_FILE_NATIVE" "$ISSUE_NUM" "$TIER" \
    "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED" "$WORKTREE_ABS" "${PROVIDER_CMD[@]}" \
    2> >(tee -a "$LOG_FILE" >&2))"
  SPAWN_RC=$?
  if [[ "$SPAWN_RC" -ne 0 || -z "$DISPATCH_ID" ]]; then
    DISPATCH_RC=1
    # Stamp DISPATCH_ID empty so the success arm below cannot fire on a
    # partial-stdout token from a failed spawn.
    DISPATCH_ID=""
  fi
  if [[ "$DISPATCH_RC" -eq 0 ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      '{"issue":'"$ISSUE_NUM"',"tier":"'"$TIER"'","backend":"wezterm","pane_id":"'"$DISPATCH_ID"'"}'
  else
    DISPATCH_LOG="$LOG_FILE"
    # Unlike the background arm's `dispatch` phase, a failed `wezterm cli spawn`
    # leaves NO reapable handle: there is no pane id to monitor and no status
    # file the operator will ever be pointed at, so nothing downstream will
    # take this worktree back down. A mux that is not up is routine, which is
    # what makes this the most-travelled leak of the set. If a pane did come up
    # despite the failure, its own wrapper tears down idempotently under the
    # same mutex, and a pane that dirtied the tree is refused, not destroyed.
    _uberdev_dispatch_fail_after_worktree "$ISSUE_NUM" wezterm dispatch "$DISPATCH_RC" \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$CLEANUP_START_HEAD" "$CHILD_OWNED"
    DISPATCH_RC=$?
  fi
  return "$DISPATCH_RC"
}
