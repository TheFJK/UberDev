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
#   _uberdev_dispatch_claude_bg / _uberdev_dispatch_wezterm /
#   _uberdev_dispatch_background / _uberdev_dispatch_codex
#
# Sourced by:
#   - skills/solve-pipeline/SKILL.md Step 5b
#   - skills/goal-pipeline/SKILL.md Phase 0
#   - commands/review-pr.md executable setup and routed child adapter
#   - tests/dispatch-claude-bg.test.sh, dispatch-fallback.test.sh,
#     dispatch-background.test.sh, dispatch-wezterm.test.sh
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
# shellcheck source=/dev/null
. "$_UBERDEV_DISPATCH_LIB_DIR/agent-dispatch.sh" || return 1
# shellcheck source=/dev/null
. "$_UBERDEV_DISPATCH_LIB_DIR/config-read.sh" || return 1
_UBERDEV_DISPATCH_LOADED=1

# A provider-managed worktree may finish its final git worktree unlock at the
# same time as the Codex supervisor starts cleanup. Retry only transient Git
# metadata/probe failures (rc2); preservation decisions (rc3) are terminal.
_UBERDEV_CODEX_CLEANUP_MAX_ATTEMPTS=3
_UBERDEV_CODEX_CLEANUP_RETRY_DELAY_1_S=0.05
_UBERDEV_CODEX_CLEANUP_RETRY_DELAY_2_S=0.10
_UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT_DEFAULT_S=60
_UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT_MAX_S=300
_UBERDEV_GIT_METADATA_MUTEX_FAST_POLLS=8
_UBERDEV_GIT_METADATA_MUTEX_MEDIUM_POLLS=8
_UBERDEV_GIT_METADATA_MUTEX_STEADY_POLLS_PER_SECOND=4
_UBERDEV_GIT_METADATA_MUTEX_FAST_DELAY_S=0.05
_UBERDEV_GIT_METADATA_MUTEX_MEDIUM_DELAY_S=0.10
_UBERDEV_GIT_METADATA_MUTEX_STEADY_DELAY_S=0.25
_UBERDEV_GIT_METADATA_MUTEX_WAIT_TICKS_PER_SECOND=20
_UBERDEV_GIT_METADATA_MUTEX_FAST_DELAY_TICKS=1
_UBERDEV_GIT_METADATA_MUTEX_MEDIUM_DELAY_TICKS=2
_UBERDEV_GIT_METADATA_MUTEX_STEADY_DELAY_TICKS=5
_UBERDEV_GIT_METADATA_MUTEX_PUBLICATION_GRACE_S=1
_UBERDEV_GIT_METADATA_MUTEX_WALL_PROBE_ALLOWANCE_S=2
_UBERDEV_GIT_METADATA_MUTEX_OWNERLESS_CONFIRMATIONS=3

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
  local path="$1"
  case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
    MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
      if ! command -v cygpath >/dev/null 2>&1; then
        echo 'error: cygpath is required to normalize a native-Windows dispatch path' >&2
        return 127
      fi
      cygpath -m "$path"
      ;;
    *) printf '%s' "$path" ;;
  esac
}

# Return a validated runtime root. The default lives below the platform temp
# root; POSIX creates or validates an EUID-owned, non-symlink directory locked
# to 0700. Native Windows relies on the current-user ACL only when this helper
# creates the default directory; a pre-existing default or caller override is
# checked for directory and ordinary-link safety but is not asserted private
# here. The reparse-aware boundaries are child-receipts.py:is_link_or_reparse
# and run_manifest.py:_secure_open_regular; the worktree receipt helpers below
# check ordinary links plus stable file identity, not Windows reparse flags.
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

_uberdev_dispatch_claude_bootstrap_queue_slots() {
  local slots expected
  if [ -n "${POST_IMPL_REVIEW_CAP:-}" ]; then
    slots="$POST_IMPL_REVIEW_CAP"
    expected="${REVIEW_EXPECTED_COUNT:-}"
  elif [ -n "${MAX_PARALLEL_BG_AGENTS:-}" ]; then
    slots="$MAX_PARALLEL_BG_AGENTS"
    expected="${TOTAL_ISSUES:-}"
  else
    slots=1
    expected=''
  fi
  case "$slots" in [1-9]|[1-4][0-9]|50) ;; *) return 2 ;; esac
  if [ -n "$expected" ]; then
    case "$expected" in [1-9]|[1-4][0-9]|50) ;; *) return 2 ;; esac
    [ "$expected" -ge "$slots" ] || slots="$expected"
  fi
  printf '%s\n' "$slots"
}

# Claude's synchronous `--bg --worktree` bootstrap may legitimately own the
# repository mutex for its full provider timeout. Poll it at a low frequency
# with backoff, one ownership-safe acquisition attempt per poll. The wait
# budget is derived from the actual enforced fanout wave, so ordinary Git
# add/cleanup callers retain the semaphore's short default policy.
_uberdev_dispatch_git_metadata_mutex_acquire() {
  local scope="$1" phase="$2" operation_timeout="${3:-}" queue_slots provider_wait_seconds
  local scheduled_wait_seconds wall_wait_seconds
  local wait_tick_limit grace_ticks max_polls polls=0 waited_ticks=0 delay delay_ticks acquire_rc
  local wall_started wall_elapsed
  local observed_state observed_identity ownerless_identity='' ownerless_first_tick=0 ownerless_confirmations=0
  local stable_ticks reclaim_rc
  if [ "$phase" != claude-bootstrap ] || [ -z "$operation_timeout" ]; then
    _uberdev_semaphore_mutex_acquire "$scope"
    return $?
  fi
  case "$operation_timeout" in
    [1-9]|[1-9][0-9]|[12][0-9][0-9]|300) ;;
    *) return 2 ;;
  esac
  queue_slots="$(_uberdev_dispatch_claude_bootstrap_queue_slots)" || return 2
  provider_wait_seconds=$((operation_timeout * queue_slots))
  scheduled_wait_seconds=$((provider_wait_seconds + _UBERDEV_GIT_METADATA_MUTEX_PUBLICATION_GRACE_S))
  wall_wait_seconds=$((scheduled_wait_seconds + _UBERDEV_GIT_METADATA_MUTEX_WALL_PROBE_ALLOWANCE_S))
  wait_tick_limit=$((scheduled_wait_seconds * _UBERDEV_GIT_METADATA_MUTEX_WAIT_TICKS_PER_SECOND))
  grace_ticks=$((_UBERDEV_GIT_METADATA_MUTEX_PUBLICATION_GRACE_S * _UBERDEV_GIT_METADATA_MUTEX_WAIT_TICKS_PER_SECOND))
  max_polls=$((wait_tick_limit \
    + _UBERDEV_GIT_METADATA_MUTEX_FAST_POLLS + _UBERDEV_GIT_METADATA_MUTEX_MEDIUM_POLLS))
  wall_started="$SECONDS"
  while [ "$polls" -lt "$max_polls" ]; do
    wall_elapsed=$((SECONDS - wall_started))
    if [ "$wall_elapsed" -gt "$wall_wait_seconds" ]; then
      printf 'uberdev git metadata mutex: acquisition timed out for %s after %ss (queue_slots=%s)\n' \
        "$phase" "$wall_wait_seconds" "$queue_slots" >&2
      return 75
    fi
    if UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 UBERDEV_SEMAPHORE_MUTEX_QUIET_BUSY=1 \
        UBERDEV_SEMAPHORE_MUTEX_PROBE_ONLY=1 \
        _uberdev_semaphore_mutex_acquire "$scope"; then
      return 0
    else
      acquire_rc=$?
    fi
    [ "$acquire_rc" -eq 75 ] || {
      printf 'uberdev git metadata mutex: acquisition failed for %s (rc=%s)\n' \
        "$phase" "$acquire_rc" >&2
      return "$acquire_rc"
    }
    polls=$((polls + 1))
    wall_elapsed=$((SECONDS - wall_started))
    if [ "$wall_elapsed" -gt "$wall_wait_seconds" ]; then
      printf 'uberdev git metadata mutex: acquisition timed out for %s after %ss (queue_slots=%s)\n' \
        "$phase" "$wall_wait_seconds" "$queue_slots" >&2
      return 75
    fi
    observed_state="${_UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE:-unknown}"
    observed_identity="${_UBERDEV_SEMAPHORE_MUTEX_OBSERVED_IDENTITY:-}"
    case "$observed_state" in
      ownerless)
        [ -n "$observed_identity" ] || return 2
        if [ "$observed_identity" = "$ownerless_identity" ]; then
          ownerless_confirmations=$((ownerless_confirmations + 1))
        else
          ownerless_identity="$observed_identity"
          ownerless_first_tick="$waited_ticks"
          ownerless_confirmations=1
        fi
        stable_ticks=$((waited_ticks - ownerless_first_tick))
        if [ "$stable_ticks" -ge "$grace_ticks" ] \
            && [ "$ownerless_confirmations" -ge "$_UBERDEV_GIT_METADATA_MUTEX_OWNERLESS_CONFIRMATIONS" ]; then
          if _uberdev_semaphore_mutex_reclaim_ownerless_generation "$scope" "$ownerless_identity"; then
            ownerless_identity=''; ownerless_confirmations=0; ownerless_first_tick="$waited_ticks"
            continue
          else
            reclaim_rc=$?
          fi
          if [ "$reclaim_rc" -eq 1 ]; then
            ownerless_identity=''; ownerless_confirmations=0; ownerless_first_tick="$waited_ticks"
          else
            printf 'uberdev git metadata mutex: ownerless reclaim failed for %s (rc=%s)\n' \
              "$phase" "$reclaim_rc" >&2
            return "$reclaim_rc"
          fi
        fi
        ;;
      published-live|published-dead|absent)
        ownerless_identity=''; ownerless_confirmations=0; ownerless_first_tick="$waited_ticks"
        ;;
      *)
        printf 'uberdev git metadata mutex: unsafe probe state for %s (%s)\n' \
          "$phase" "$observed_state" >&2
        return 2
        ;;
    esac
    if [ "$waited_ticks" -ge "$wait_tick_limit" ] || [ "$polls" -ge "$max_polls" ]; then
      printf 'uberdev git metadata mutex: acquisition timed out for %s after %ss (queue_slots=%s)\n' \
        "$phase" "$scheduled_wait_seconds" "$queue_slots" >&2
      return 75
    fi
    if [ "$polls" -le "$_UBERDEV_GIT_METADATA_MUTEX_FAST_POLLS" ]; then
      delay="$_UBERDEV_GIT_METADATA_MUTEX_FAST_DELAY_S"
      delay_ticks="$_UBERDEV_GIT_METADATA_MUTEX_FAST_DELAY_TICKS"
    elif [ "$polls" -le $((_UBERDEV_GIT_METADATA_MUTEX_FAST_POLLS + _UBERDEV_GIT_METADATA_MUTEX_MEDIUM_POLLS)) ]; then
      delay="$_UBERDEV_GIT_METADATA_MUTEX_MEDIUM_DELAY_S"
      delay_ticks="$_UBERDEV_GIT_METADATA_MUTEX_MEDIUM_DELAY_TICKS"
    else
      delay="$_UBERDEV_GIT_METADATA_MUTEX_STEADY_DELAY_S"
      delay_ticks="$_UBERDEV_GIT_METADATA_MUTEX_STEADY_DELAY_TICKS"
    fi
    sleep "$delay" || {
      printf 'uberdev git metadata mutex: acquisition wait interrupted for %s\n' "$phase" >&2
      return 2
    }
    waited_ticks=$((waited_ticks + delay_ticks))
  done
  return 75
}

_uberdev_dispatch_with_git_metadata_mutex() {
  local repo_root="$1" phase="$2" scope rc release_rc
  local operation_timeout="${_UBERDEV_GIT_METADATA_MUTEX_OPERATION_TIMEOUT:-}"
  shift 2
  [ "$#" -gt 0 ] || return 2
  case "$phase" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  scope="$(_uberdev_dispatch_git_metadata_mutex_scope "$repo_root")" || return 2
  (
    _uberdev_dispatch_git_metadata_mutex_acquire "$scope" "$phase" "$operation_timeout" || exit $?
    trap '_uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true' EXIT
    "$@"
    rc=$?
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1
    release_rc=$?
    [ "$release_rc" -eq 0 ] || printf \
      'uberdev git metadata mutex: release failed after %s (rc=%s); command rc=%s remains authoritative\n' \
      "$phase" "$release_rc" "$rc" >&2
    [ "$release_rc" -ne 0 ] || trap - EXIT
    exit "$rc"
  )
}

_uberdev_dispatch_git_worktree_add_locked() {
  local repo_root="$1" target="$2" branch="$3" log_file="$4" native_target
  native_target="$(_uberdev_dispatch_native_cli_path "$target")" || return $?
  cd "$repo_root" || return 2
  MSYS_NO_PATHCONV=1 git worktree add "$native_target" -b "$branch" >"$log_file" 2>&1
}

_uberdev_dispatch_git_worktree_add() {
  local repo_root="$1"
  _uberdev_dispatch_with_git_metadata_mutex "$repo_root" worktree-add \
    _uberdev_dispatch_git_worktree_add_locked "$@"
}

_uberdev_dispatch_claude_bootstrap_timeout() {
  local solve_timeout="$1" configured="${UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT:-$_UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT_DEFAULT_S}"
  _uberdev_dispatch_python -I -B - "$solve_timeout" "$configured" \
    "$_UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT_MAX_S" <<'PY'
import sys

solve_raw, configured_raw, maximum = sys.argv[1:]

def bounded_decimal(raw):
    if not raw or not raw.isascii() or not raw.isdecimal():
        raise SystemExit(2)
    value = raw.lstrip("0")
    if not value:
        raise SystemExit(2)
    if len(value) > len(maximum) or (len(value) == len(maximum) and value > maximum):
        return maximum
    return value

solve = bounded_decimal(solve_raw)
configured = bounded_decimal(configured_raw)
if len(configured) < len(solve) or (len(configured) == len(solve) and configured < solve):
    print(configured)
else:
    print(solve)
PY
}

# Create a private ownership receipt before `git worktree add`. Cleanup accepts
# only the exact repo/path/branch/token tuple recorded here, preventing a stale
# or substituted path from being removed as if it belonged to this child.
_uberdev_dispatch_create_codex_worktree_receipt() {
  local start_head
  start_head="$(git -C "$1" rev-parse HEAD 2>/dev/null)" || return 2
  _uberdev_dispatch_python -I -B - "$1" "$2" "$3" "$4" "$start_head" <<'PY'
import json,os,posixpath,re,secrets,stat,subprocess,sys
repo_arg,relative,branch,receipt,start_head=sys.argv[1:]
repo=os.path.realpath(repo_arg)
if not os.path.isabs(repo_arg) or not os.path.isdir(repo) or os.path.isabs(relative): raise SystemExit(2)
if not re.fullmatch(r'[0-9a-f]{40}',start_head): raise SystemExit(2)
normalized=posixpath.normpath(relative)
basename=posixpath.basename(normalized)
if (normalized!=relative or not normalized.startswith(".claude/worktrees/solve-issue-")
    or branch!="worktree-"+basename): raise SystemExit(2)
root=os.path.join(repo,".claude","worktrees")
target=os.path.abspath(os.path.join(repo,*normalized.split('/')))
if os.path.commonpath((root,target))!=root: raise SystemExit(2)
if os.path.lexists(target): raise SystemExit(2)
branch_probe=subprocess.run(['git','-C',repo,'show-ref','--verify','--quiet','refs/heads/'+branch])
if branch_probe.returncode!=1: raise SystemExit(2)
receipt=os.path.abspath(receipt); parent=os.path.dirname(receipt)
parent_entry=os.lstat(parent); uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
if stat.S_ISLNK(parent_entry.st_mode) or not stat.S_ISDIR(parent_entry.st_mode) or (uid is not None and parent_entry.st_uid!=uid): raise SystemExit(2)
token=secrets.token_hex(16)+":"+start_head
payload={"schema_version":1,"repo":repo,"relative":normalized,"worktree":target,"branch":branch,"start_head":start_head,"token":token,"path_absent_at_receipt":True,"branch_absent_at_receipt":True}
flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0)
descriptor=os.open(receipt,flags,0o600)
try:
 if os.name!="nt": os.fchmod(descriptor,0o600)
 raw=(json.dumps(payload,sort_keys=True,separators=(",",":"))+"\n").encode()
 if os.write(descriptor,raw)!=len(raw): raise OSError("short receipt write")
 os.fsync(descriptor)
finally: os.close(descriptor)
print(token,end="")
PY
}

_uberdev_dispatch_discard_codex_worktree_receipt() {
  _uberdev_dispatch_python -I -B - "$1" "$2" <<'PY'
import json,os,stat,sys
path,token=sys.argv[1:]; parent,name=os.path.dirname(path),os.path.basename(path)
if os.name=="nt":
 before=os.lstat(path)
 if os.path.islink(path) or not stat.S_ISREG(before.st_mode) or before.st_nlink!=1: raise SystemExit(2)
 descriptor=os.open(path,os.O_RDONLY|getattr(os,"O_BINARY",0)|getattr(os,"O_NOINHERIT",0))
 try:
  opened=os.fstat(descriptor); current=os.lstat(path)
  if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink!=1
      or (opened.st_dev,opened.st_ino)!=(before.st_dev,before.st_ino)
      or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise SystemExit(2)
  raw=os.read(descriptor,65537)
  if len(raw)>65536 or json.loads(raw).get("token")!=token: raise SystemExit(2)
  current=os.lstat(path)
  if os.path.islink(path) or (current.st_dev,current.st_ino)!=(opened.st_dev,opened.st_ino): raise SystemExit(2)
 finally: os.close(descriptor)
 os.unlink(path)
 raise SystemExit(0)
parent_fd=os.open(parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); descriptor=None
try:
 descriptor=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent_fd)
 opened=os.fstat(descriptor); current=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
 uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
 if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink!=1 or (uid is not None and opened.st_uid!=uid)
     or (os.name!="nt" and stat.S_IMODE(opened.st_mode)!=0o600)
     or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise SystemExit(2)
 raw=os.read(descriptor,65537)
 if len(raw)>65536 or json.loads(raw).get("token")!=token: raise SystemExit(2)
 current=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
 if (current.st_dev,current.st_ino)!=(opened.st_dev,opened.st_ino): raise SystemExit(2)
 os.unlink(name,dir_fd=parent_fd)
finally:
 if descriptor is not None: os.close(descriptor)
 os.close(parent_fd)
PY
}

_uberdev_dispatch_cleanup_codex_worktree_locked() {
  local repo_root="$1" relative="$2" branch="$3" receipt="$4" token="$5" terminal="$6"
  local target_record target start_head
  case "$terminal" in completed|failed|timed_out|cancelled|setup_failed) ;; *) return 2 ;; esac
  target_record="$(_uberdev_dispatch_python -I -B - "$repo_root" "$relative" "$branch" "$receipt" "$token" <<'PY'
import json,os,re,stat,sys
repo_arg,relative,branch,path,token=sys.argv[1:]
repo=os.path.realpath(repo_arg); parent,name=os.path.dirname(path),os.path.basename(path)
try: token_start=token.rsplit(':',1)[1]
except (AttributeError,IndexError): raise SystemExit(2)
if not re.fullmatch(r'[0-9a-f]{40}',token_start): raise SystemExit(2)
if os.name=="nt":
 before=os.lstat(path)
 if os.path.islink(path) or not stat.S_ISREG(before.st_mode) or before.st_nlink!=1: raise SystemExit(2)
 descriptor=os.open(path,os.O_RDONLY|getattr(os,"O_BINARY",0)|getattr(os,"O_NOINHERIT",0))
 try:
  opened=os.fstat(descriptor); current=os.lstat(path)
  if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink!=1
      or (opened.st_dev,opened.st_ino)!=(before.st_dev,before.st_ino)
      or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise SystemExit(2)
  raw=os.read(descriptor,65537)
  if len(raw)>65536: raise SystemExit(2)
  value=json.loads(raw)
 finally: os.close(descriptor)
 expected={"schema_version":1,"repo":repo,"relative":relative,"worktree":os.path.abspath(os.path.join(repo,*relative.split('/'))),"branch":branch,"start_head":token_start,"token":token,"path_absent_at_receipt":True,"branch_absent_at_receipt":True}
 if value!=expected: raise SystemExit(2)
 target=value["worktree"]; root=os.path.join(repo,".claude","worktrees")
 if os.path.commonpath((root,target))!=root or branch!="worktree-"+relative.rsplit('/',1)[-1]: raise SystemExit(2)
 if os.path.lexists(target):
  entry=os.lstat(target)
  if os.path.islink(target) or not stat.S_ISDIR(entry.st_mode): raise SystemExit(2)
 print(target+'\t'+token_start,end="")
 raise SystemExit(0)
parent_fd=os.open(parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); descriptor=None
try:
 descriptor=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent_fd)
 opened=os.fstat(descriptor); current=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
 uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
 if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink!=1 or (uid is not None and opened.st_uid!=uid)
     or (os.name!="nt" and stat.S_IMODE(opened.st_mode)!=0o600)
     or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino)): raise SystemExit(2)
 raw=os.read(descriptor,65537)
 if len(raw)>65536: raise SystemExit(2)
 value=json.loads(raw)
 expected={"schema_version":1,"repo":repo,"relative":relative,"worktree":os.path.abspath(os.path.join(repo,relative)),"branch":branch,"start_head":token_start,"token":token,"path_absent_at_receipt":True,"branch_absent_at_receipt":True}
 if value!=expected: raise SystemExit(2)
 target=value["worktree"]; root=os.path.join(repo,".claude","worktrees")
 if os.path.commonpath((root,target))!=root or branch!="worktree-"+os.path.basename(relative): raise SystemExit(2)
 if os.path.lexists(target):
  entry=os.lstat(target)
  if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode) or (uid is not None and entry.st_uid!=uid): raise SystemExit(2)
 print(target+'\t'+token_start,end="")
finally:
 if descriptor is not None: os.close(descriptor)
 os.close(parent_fd)
PY
)" || return 2
  target="${target_record%%$'\t'*}"
  start_head="${target_record#*$'\t'}"
  [ -n "$target" ] && [ -n "$start_head" ] && [ "$target" != "$start_head" ] || return 2
  (
    cd "$repo_root" || exit 2
    branch_exists=0
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      branch_exists=1
    else
      show_ref_rc=$?
      [ "$show_ref_rc" -eq 1 ] || exit 2
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
      local_status="$(git -C "$target" status --porcelain --untracked-files=all)" || exit 2
      [ -z "$local_status" ] || exit 3
      target_head="$(git -C "$target" rev-parse HEAD)" || exit 2
      [ "$target_head" = "$start_head" ] || exit 3
      git worktree remove --force "$target" || exit 2
      [ ! -e "$target" ] && [ ! -L "$target" ] || exit 2
    fi
    if [ "$branch_exists" -eq 1 ]; then
      branch_head="$(git rev-parse "refs/heads/$branch")" || exit 2
      [ "$branch_head" = "$start_head" ] || exit 3
      worktree_list="$(git worktree list --porcelain)" || exit 2
      if printf '%s\n' "$worktree_list" | grep -Fqx "branch refs/heads/$branch"; then exit 2; fi
      git branch -D "$branch" >/dev/null || exit 2
    fi
  )
  return $?
}

_uberdev_dispatch_cleanup_codex_worktree() {
  local repo_root="$1" receipt="$4" token="$5" scope rc release_rc attempt=1 retry_delay
  scope="$(_uberdev_dispatch_git_metadata_mutex_scope "$repo_root")" || return 2
  (
    _uberdev_semaphore_mutex_acquire "$scope" || exit $?
    trap '_uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true' EXIT
    while :; do
      if _uberdev_dispatch_cleanup_codex_worktree_locked "$@"; then rc=0; else rc=$?; fi
      if [ "$rc" -ne 2 ] || [ "$attempt" -ge "$_UBERDEV_CODEX_CLEANUP_MAX_ATTEMPTS" ]; then
        break
      fi
      case "$attempt" in
        1) retry_delay="$_UBERDEV_CODEX_CLEANUP_RETRY_DELAY_1_S" ;;
        2) retry_delay="$_UBERDEV_CODEX_CLEANUP_RETRY_DELAY_2_S" ;;
        *) rc=2; break ;;
      esac
      printf 'uberdev codex cleanup: transient attempt %s/%s; retrying in %ss\n' \
        "$attempt" "$_UBERDEV_CODEX_CLEANUP_MAX_ATTEMPTS" "$retry_delay" >&2
      sleep "$retry_delay" || { rc=2; break; }
      attempt=$((attempt + 1))
    done
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1
    release_rc=$?
    [ "$release_rc" -eq 0 ] \
      || printf 'uberdev codex cleanup: mutex release failed after cleanup transaction\n' >&2 \
      || true
    [ "$release_rc" -eq 0 ] || [ "$rc" -ne 0 ] || rc=2
    [ "$release_rc" -ne 0 ] || trap - EXIT
    [ "$rc" -eq 0 ] || exit "$rc"
    _uberdev_dispatch_discard_codex_worktree_receipt "$receipt" "$token" || {
      printf 'uberdev codex cleanup: ownership receipt discard failed after cleanup transaction\n' >&2 \
        || true
      exit 2
    }
  )
}

# The dispatch_backend enum — identical to the --backend= flag's accepted set.
# `codex` is the OpenAI Codex CLI backend (RFC 0012 §3.4 codex-port): execs
# `codex exec` headless + nohup-detached, PID-tracked like `background`.
_UBERDEV_DISPATCH_BACKEND_ENUM='auto|claude-bg|wezterm|background|codex'

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
    codex|background) [ "$(_uberdev_dispatch_os_class)" != windows-native ] ;;
    claude-bg|wezterm) return 0 ;;
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

# _uberdev_dispatch_codex_available -> exit 0 if the codex CLI is usable, 1 otherwise.
# Usable = the `codex` binary is on PATH. No mux/domain probe needed (unlike
# wezterm): `codex exec` is a self-contained headless invocation with no shared
# server state to warm up. Kept as a named probe for symmetry with the wezterm
# arm and so the preflight + dispatch_one switch call the same gate.
_uberdev_dispatch_codex_available() {
  command -v codex >/dev/null 2>&1
}

# uberdev_dispatch_preflight [WORKFLOW]
# Resolves UBERDEV_DISPATCH_BACKEND_REQUESTED (auto|claude-bg|wezterm|background|codex)
# to a concrete UBERDEV_RESOLVED_BACKEND, ONCE per invocation, committed for
# the whole batch (no mid-fanout switch). Hard-errors (return 1) when an
# explicit backend is unusable on this host. Auto selection is workflow-aware
# for review-pr and simplify because their governed children require an atomic
# result artifact and caller-workspace repair support. Emits
# dispatch_backend_resolved.
uberdev_dispatch_preflight() {
  local requested="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-auto}"
  local workflow="${1:-}" os_class reason resolved
  os_class="$(_uberdev_dispatch_os_class)"
  case "$requested" in
    claude-bg|background)
      # claude-bg / background depend only on git + claude + shell — usable
      # on every OS class. No capability gate.
      resolved="$requested"; reason="explicit" ;;
    codex)
      # codex backend needs the `codex` CLI on PATH. No OS constraint (codex
      # exec is cross-platform); single capability gate is the binary itself.
      if ! _uberdev_dispatch_codex_available; then
        echo "error: --backend=codex requested but the 'codex' CLI is unavailable" >&2
        echo "       (binary missing on PATH). Install Codex or use another backend." >&2
        return 1
      fi
      resolved="codex"; reason="explicit" ;;
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
      if [ "$os_class" = windows-native ]; then
        if _uberdev_dispatch_wezterm_available; then
          resolved="wezterm"; reason="auto-windows-wezterm"
        else
          echo "error: native Windows requires WezTerm for verifiable child supervision" >&2
          echo "       install/start WezTerm, or run from WSL2 or another POSIX host" >&2
          return 1
        fi
      elif [ "$workflow" = review-pr ] || [ "$workflow" = simplify ]; then
        if _uberdev_dispatch_codex_available; then
          resolved="codex"; reason="auto-${workflow}-result-artifact"
        else
          echo "error: $workflow requires the 'codex' CLI for supervised child result artifacts" >&2
          echo "       Install Codex or explicitly run this workflow from a supported Codex host." >&2
          return 1
        fi
      # If we're running inside Codex itself (CODEX_HOME set), or claude is
      # absent but codex is present, the codex backend is the natural default —
      # dispatching a claude --bg session from inside Codex would be wrong.
      # Checked before the per-OS matrix below so it wins in auto mode.
      elif [ -n "${CODEX_HOME:-}" ]; then
        if _uberdev_dispatch_codex_available; then
          resolved="codex"; reason="auto-codex-env"
        else
          echo "error: CODEX_HOME is set but the 'codex' CLI is unavailable on PATH" >&2
          echo "       Fix the Codex install/PATH, or explicitly choose a non-Codex backend with --backend=<name>." >&2
          return 1
        fi
      elif ! command -v claude >/dev/null 2>&1 && _uberdev_dispatch_codex_available; then
        resolved="codex"; reason="auto-no-claude"
      else
      case "$os_class" in
        macos)
          if _uberdev_dispatch_wezterm_available; then resolved="wezterm"; reason="auto-macos-wezterm"
          else resolved="claude-bg"; reason="auto-macos-fallback"; fi ;;
        wsl2)
          resolved="claude-bg"; reason="auto-wsl2" ;;
        *)
          resolved="claude-bg"; reason="auto-linux" ;;
      esac
      fi ;;
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

# ---------------------------------------------------------------------------
# uberdev_dispatch_resolve_env [BACKEND]
# Resolves the six deterministic dispatch-env vars consumed by every backend:
#   BG_PROMPT_MODE, MODEL, PERM_FLAG[], EFFORT_FLAG[], SOLVE_TIMEOUT, TIMEOUT_BIN.
# SSOT for both solve-pipeline (replaces its inline Phase A block) and
# goal-pipeline (Phase 0). Sourced, NEVER exec'd — PERM_FLAG/EFFORT_FLAG are
# bash arrays that cannot survive an env(1)/fork+exec boundary, so they must be
# set in the caller's shell scope. Idempotent: deterministic scalars, arrays
# rebuilt each call. Returns 1 (fail-loud) when no timeout(1)/gtimeout(1) is on
# PATH for Claude-backed backends. Does NOT read or write
# UBERDEV_RESOLVED_BACKEND (that is preflight's; RFC 0005 D15 constrains
# backend resolution only — env resolution is exempt). Codex callers pass
# BACKEND=codex explicitly so this helper can skip timeout(1) without reading
# preflight's global.
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
  # BG_PROMPT_MODE: hardcoded `argv`. Verified 2026-05-28 against claude-code
  # 2.1.153 via tests/manual/probe-prompt-file-slash-expansion.sh — probe verdict
  # was `INDETERMINATE`: --prompt-file is accepted as a flag (session backgrounds
  # successfully), but the file body is not promoted to the session-name surface
  # — the spawned session's name remained the short id rather than the opening
  # prompt body, unlike argv-mode where name = the opening message verbatim. The
  # session went idle within the probe's 30s window without the name field ever
  # diverging. Slash-expansion firing is therefore unobservable from outside the
  # session, but the name-surface divergence suggests the body is processed
  # through a different parser path (or not at all) — either way, the natural-
  # language wrapper at the 5 prompt-build callsites (issue #235 / PR #238)
  # remains canonical. The `file`/`stdin` arms in _uberdev_dispatch_claude_bg
  # remain pre-wired migration targets for a future CLI revision per RFC 0004
  # §3.4. Closes #240 (won't-fix).
  BG_PROMPT_MODE=argv

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

  # Codex does not wrap `codex exec` in timeout(1): the wrapper PID + status
  # JSON are the liveness contract. Do not require GNU coreutils on Codex-only
  # hosts just to resolve Claude-backed dispatch settings.
  if [ "$_dispatch_env_backend" = "codex" ]; then
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
# constructing children. Native Codex needs no Claude CLI model, permission, or
# timeout variables; every Claude-backed transport shares the resolver above.
uberdev_dispatch_preflight_backend() {
  local backend="${1:-}" workflow="${2:-}" backend_label
  case "$backend" in
    codex|claude-bg|background|wezterm)
      if ! _uberdev_dispatch_numeric_supervision_supported "$backend"; then
        backend_label="$backend"; [ "$backend" != codex ] || backend_label=Codex
        echo "error: $workflow cannot supervise native Windows $backend_label process trees" >&2
        echo "       use WezTerm, WSL2, or another POSIX host" >&2
        return 1
      fi
      ;;
  esac
  if [ "$workflow" = review-pr ] || [ "$workflow" = simplify ]; then
    case "$backend" in
      codex) ;;
      claude-bg)
        echo "error: $workflow cannot use claude-bg because it does not export a supervised result artifact" >&2
        return 1
        ;;
      wezterm|background)
        echo "error: $workflow requires a backend with result-artifact and caller-workspace repair support: $backend" >&2
        return 1
        ;;
    esac
  fi
  case "$backend" in
    codex)
      return 0
      ;;
    claude-bg)
      uberdev_dispatch_resolve_env "$backend" || return $?
      if [ -n "$workflow" ] && command -v _uberdev_agent_claude_permissions_preflight >/dev/null 2>&1; then
        _uberdev_agent_claude_permissions_preflight "$workflow" || return $?
      fi
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
    claude-bg)   _uberdev_dispatch_claude_bg "$issue_num" "$tier" "$prompt_file" ;;
    wezterm)     _uberdev_dispatch_wezterm "$issue_num" "$tier" "$prompt_file" ;;
    background)  _uberdev_dispatch_background "$issue_num" "$tier" "$prompt_file" ;;
    codex)       _uberdev_dispatch_codex "$issue_num" "$tier" "$prompt_file" ;;
    *) DISPATCH_RC=1; DISPATCH_ID=""; DISPATCH_LOG="unsupported backend: $backend"; return 1 ;;
  esac
}

_uberdev_dispatch_cancel_claude_bg() {
  local handle="${1:-}" resolved probe probe_rc attempts=0 absent_count=0 saw_valid=0
  _UBERDEV_DISPATCH_CANCEL_REASON=''
  [ "${#handle}" -eq 8 ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_session_resolution_failed; return 2; }
  printf '%s\n' "$handle" | LC_ALL=C grep -Eq '^[0-9a-f]{8}$' \
    || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_session_resolution_failed; return 2; }
  resolved="$(claude agents --all --json 2>/dev/null | _uberdev_dispatch_python -I -B -c '
import json,sys
prefix=sys.argv[1]
try: rows=json.load(sys.stdin)
except Exception: raise SystemExit(2)
matches=[row["sessionId"] for row in rows if isinstance(row,dict) and isinstance(row.get("sessionId"),str) and row["sessionId"].startswith(prefix)] if isinstance(rows,list) else []
if len(matches)!=1: raise SystemExit(2)
print(matches[0],end="")
' "$handle")" || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_session_resolution_failed; return 2; }
  [ -n "$resolved" ] || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_session_resolution_failed; return 2; }
  claude stop "$resolved" >/dev/null 2>&1 \
    || { _UBERDEV_DISPATCH_CANCEL_REASON=provider_stop_failed; return 2; }
  while [ "$attempts" -lt 20 ]; do
    if probe="$(_uberdev_agent_claude_probe "$resolved" exact 2>/dev/null)"; then
      probe_rc=0; saw_valid=1
    else
      probe_rc=$?
    fi
    if [ "$probe_rc" -eq 0 ]; then
      case "$probe" in
        completed|failed|timed_out|cancelled) return 0 ;;
        absent)
          absent_count=$((absent_count + 1))
          [ "$absent_count" -lt 3 ] || return 0
          ;;
        live|blocked:permission|blocked:provider) absent_count=0 ;;
        *) saw_valid=0 ;;
      esac
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ "$saw_valid" -eq 0 ]; then
    _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_probe_failed
    return 2
  fi
  _UBERDEV_DISPATCH_CANCEL_REASON=provider_cancel_unconfirmed
  return 1
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
    codex|background)
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
    claude-bg)
      _uberdev_dispatch_cancel_claude_bg "$handle"
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
  case "$UBERDEV_RESOLVED_BACKEND" in
    codex)
      result_file="$run_dir/solve-codex-result-$ISSUE_NUM.md"
      status_file="$run_dir/solve-codex-status-$ISSUE_NUM.json"
      ;;
    *)
      result_file="$run_dir/solve-bg-result-$ISSUE_NUM.md"
      status_file="$run_dir/solve-bg-status-$ISSUE_NUM.json"
      ;;
  esac
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

# _uberdev_dispatch_claude_bg ISSUE_NUM TIER PROMPT_FILE
# Launch the Claude background provider under the current routed lifecycle and
# capacity contract. Sets DISPATCH_RC and DISPATCH_ID for the caller.
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

_uberdev_dispatch_claude_bg() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local INSTANCE_SUFFIX='' INSTANCE_SLUG=''
  if [ -n "${UBERDEV_AGENT_INSTANCE_ID:-}" ]; then
    INSTANCE_SLUG="$(_uberdev_dispatch_instance_slug)" || return 3
    INSTANCE_SUFFIX="-$INSTANCE_SLUG"
  fi
  local BG_STDOUT_LOG="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM$INSTANCE_SUFFIX.log"
  # TOCTOU hardening (#155): guard + 0600-create the predictable bg-stdout path
  # before any case arm redirects to it (3 redirect sites below).
  if ! _uberdev_dispatch_prepare_tmp_target "$BG_STDOUT_LOG" "$ISSUE_NUM" "claude-bg"; then
    DISPATCH_RC=3
    DISPATCH_LOG="$BG_STDOUT_LOG"
    return 3
  fi
  # UBERDEV_TURBO=1 chain-wide signal for /turbo (AUTO_MODE=1) only; env(1)
  # mediates the inline-prefix because timeout(1) is argv[0]. Empty array
  # under AUTO_MODE=0 -> no-op passthrough. See commands/turbo.md + commands/
  # solve.md + RFC 0005 §2.3 (scoped-relaxation contract — propagation
  # rules for unattended-mode signals).
  # SKIP_PERMISSIONS=1 is /goal's autonomous-loop opt-in (#241); propagated
  # to the bg child so its own uberdev_dispatch_resolve_env call sees the
  # bypass tier. Gates on SKIP_PERMISSIONS directly, NOT on AUTO_MODE — the
  # defensive `unset` in commands/turbo.md + commands/solve.md (RFC 0005 §2.3
  # scoped-relaxation contract) is the pollution gate. `+=` (append)
  # preserves any UBERDEV_TURBO=1 set above.
  local BG_TURBO_ENV=()
  [[ "${AUTO_MODE:-0}" == "1" ]] && BG_TURBO_ENV=( UBERDEV_TURBO=1 )
  [[ "${SKIP_PERMISSIONS:-0}" == "1" ]] && BG_TURBO_ENV+=( SKIP_PERMISSIONS=1 )
  [[ "${AUTO_PERMISSIONS:-0}" == "1" ]] && BG_TURBO_ENV+=( AUTO_PERMISSIONS=1 )
  local BG_WORKSPACE_MODE="${UBERDEV_AGENT_WORKSPACE_MODE:-isolated}"
  local BG_EXECUTION_DIR BG_WORKTREE_ARGS=()
  case "$BG_WORKSPACE_MODE" in
    isolated)
      BG_EXECUTION_DIR="$(pwd -P)" || return 3
      BG_WORKTREE_ARGS=( --worktree "solve-issue-$ISSUE_NUM$INSTANCE_SUFFIX" )
      ;;
    caller)
      BG_EXECUTION_DIR="${UBERDEV_AGENT_WORKSPACE_DIR:-}"
      [ -n "$BG_EXECUTION_DIR" ] && [ -d "$BG_EXECUTION_DIR" ] || return 3
      BG_EXECUTION_DIR="$(cd "$BG_EXECUTION_DIR" 2>/dev/null && pwd -P)" || return 3
      ;;
    *) return 3 ;;
  esac
  local BG_PROMPT_MODE="${BG_PROMPT_MODE:-argv}" BG_STDIN_FILE='' PROMPT_BODY BG_BOOTSTRAP_TIMEOUT
  if ! BG_BOOTSTRAP_TIMEOUT="$(_uberdev_dispatch_claude_bootstrap_timeout "$SOLVE_TIMEOUT")"; then
    DISPATCH_RC=3
    DISPATCH_LOG="$BG_STDOUT_LOG"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"bootstrap_timeout\",\"backend\":\"claude-bg\",\"rc\":3}"
    return 3
  fi
  local cmd=( "$TIMEOUT_BIN" "$BG_BOOTSTRAP_TIMEOUT" env )
  [ "${#BG_TURBO_ENV[@]}" -eq 0 ] || cmd+=( "${BG_TURBO_ENV[@]}" )
  cmd+=( claude --bg )
  case "$BG_PROMPT_MODE" in
    file)
      # Trusted path arg; file contents never reach the shell as argv.
      cmd+=( --prompt-file "$PROMPT_FILE" )
      [ "${#BG_WORKTREE_ARGS[@]}" -eq 0 ] || cmd+=( "${BG_WORKTREE_ARGS[@]}" )
      cmd+=( --model "$MODEL" )
      ;;
    stdin)
      # File content streamed on FD 0; no argv quoting concern.
      [ "${#BG_WORKTREE_ARGS[@]}" -eq 0 ] || cmd+=( "${BG_WORKTREE_ARGS[@]}" )
      cmd+=( --model "$MODEL" )
      BG_STDIN_FILE="$PROMPT_FILE"
      ;;
    argv)
      # Bash array form (spec-reviewer finding 1) — single argv slot, no eval.
      # B5 fix (prompt-read), mirrored from the `background` backend: an
      # unreadable $PROMPT_FILE would otherwise leave PROMPT_BODY="" and
      # dispatch `claude --bg … -- ""` (garbage agent), with the audit event
      # happily reporting success. Guard the cat read and surface the failure
      # as a dispatch_setup_failed audit + rc=1.
      if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$BG_STDOUT_LOG")"; then
        DISPATCH_RC=1
        DISPATCH_LOG="$BG_STDOUT_LOG"
        _uberdev_dispatch_audit dispatch_setup_failed \
          "{\"issue\":$ISSUE_NUM,\"phase\":\"prompt_read\",\"backend\":\"claude-bg\",\"rc\":1}"
        return 1
      fi
      [ "${#BG_WORKTREE_ARGS[@]}" -eq 0 ] || cmd+=( "${BG_WORKTREE_ARGS[@]}" )
      cmd+=( --model "$MODEL" )
      ;;
    *)
      # Defensive default arm (silent-failure-hunter finding B2) — rc=127
      # instead of a silent no-op that would report DISPATCH_RC=0.
      echo "error: BG_PROMPT_MODE='$BG_PROMPT_MODE' is not one of {file, stdin, argv}" > "$BG_STDOUT_LOG"
      DISPATCH_RC=127
      ;;
  esac
  if [ "$DISPATCH_RC" -eq 0 ]; then
    [ "${#PERM_FLAG[@]}" -eq 0 ] || cmd+=( "${PERM_FLAG[@]}" )
    [ "${#EFFORT_FLAG[@]}" -eq 0 ] || cmd+=( "${EFFORT_FLAG[@]}" )
    [ "$BG_PROMPT_MODE" != argv ] || cmd+=( -- "$PROMPT_BODY" )
    # Claude owns its --worktree semantics (hooks, base ref, session cleanup).
    # Serialize only the synchronous bootstrap that creates and locks the
    # worktree. The mutex is released before handle parsing and detached work.
    (
      cd "$BG_EXECUTION_DIR" || exit 3
      if [ -n "$BG_STDIN_FILE" ]; then exec < "$BG_STDIN_FILE" || exit 1; fi
      if [ "$BG_WORKSPACE_MODE" = isolated ]; then
        _UBERDEV_GIT_METADATA_MUTEX_OPERATION_TIMEOUT="$BG_BOOTSTRAP_TIMEOUT" \
          _uberdev_dispatch_with_git_metadata_mutex "$BG_EXECUTION_DIR" claude-bootstrap "${cmd[@]}"
      else
        "${cmd[@]}"
      fi
    ) > "$BG_STDOUT_LOG" 2>&1
    DISPATCH_RC=$?
  fi
  if [[ "$DISPATCH_RC" -eq 0 ]]; then
    # Combined #143 (ANSI-strip + line-anchor + hex-validate) + #154 (capture
    # grep's OWN rc to tell a retryable pipeline error from non-retryable marker
    # drift). ANSI-strip first — `claude --bg` may wrap the `backgrounded · <id>`
    # marker in CSI color codes; the line-anchor `^...$` additionally rejects
    # OSC/DCS-wrapped markers (defense-in-depth). The cleaned stream is piped to
    # `grep -m1` so `$?` is grep's rc: grep is the LAST command in the
    # `printf|grep` pipeline, so the subshell exits with grep's rc and `$()`
    # propagates it as `$?`. (The subshell's PIPESTATUS is just not visible to
    # the outer scope — a scoping fact, not destruction.)
    # `${ID_RAW##* }` reproduces `awk '{print $NF}'`; the hex-validate sentinel
    # rejects any partial/garbage token. Mirrors the wezterm B4 SPAWN_RC=$? precedent.
    local ID_CLEAN ID_RAW ID_GREP_RC ID_SUBPHASE
    ID_CLEAN="$(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' "$BG_STDOUT_LOG")"
    ID_RAW="$(printf '%s\n' "$ID_CLEAN" | grep -m1 -aoE '^backgrounded · [0-9a-f]{8}$')"
    ID_GREP_RC=$?
    DISPATCH_ID="${ID_RAW##* }"
    DISPATCH_ID="${DISPATCH_ID//[^0-9a-f]/}"
    [[ "${#DISPATCH_ID}" -eq 8 ]] || DISPATCH_ID=""  # sentinel: empty == validation failed (B3 guard below)
    # B3 fix (preserved): `claude --bg` exited 0 but the marker was absent or
    # the extraction pipeline errored. Recording bg_session_id="" as a
    # "successful dispatch" would let /solve drop the claim-label while the user
    # has no way to `claude agents`-monitor or recover. Surface rc=2 with a
    # subphase discriminator so incident responders can tell drift
    # (marker_absent) from infra (pipeline_error).
    if [[ "$ID_GREP_RC" -ge 2 || -z "$DISPATCH_ID" ]]; then
      # subphase from a TWO-ELEMENT LITERAL SET only (D7 injection guard):
      # never derived from $ID_RAW or $BG_STDOUT_LOG content, which is
      # untrusted and would forge/break the unescaped audit JSONL.
      ID_SUBPHASE="marker_absent"
      [[ "$ID_GREP_RC" -ge 2 ]] && ID_SUBPHASE="pipeline_error"
      DISPATCH_RC=2
      DISPATCH_LOG="$BG_STDOUT_LOG"
      # Defense-in-depth (wezterm B4): stamp empty so the success arm can
      # never fire on a partial token from a failed extraction.
      DISPATCH_ID=""
      _uberdev_dispatch_audit dispatch_setup_failed \
        "{\"issue\":$ISSUE_NUM,\"phase\":\"id_extract\",\"subphase\":\"$ID_SUBPHASE\",\"backend\":\"claude-bg\",\"rc\":2,\"mode\":\"$BG_PROMPT_MODE\"}"
      return 2
    fi
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"claude-bg\",\"bg_session_id\":\"$DISPATCH_ID\",\"mode\":\"$BG_PROMPT_MODE\"}"
  else
    DISPATCH_LOG="$BG_STDOUT_LOG"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"claude-bg\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
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
  REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"repository\",\"backend\":\"background\",\"rc\":1}"
    return 1
  }
  REPOSITORY_ROOT="$(cd "$REPOSITORY_ROOT" 2>/dev/null && pwd -P)" || { DISPATCH_RC=1; return 1; }
  WORKTREE_DIR="$REPOSITORY_ROOT/$WORKTREE_RELATIVE"
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
  # Explicit dispatcher-controlled worktree — sidesteps the Windows
  # worktree-isolation bug #40164 in the --bg backend's own --worktree path
  # handling. MSYS_NO_PATHCONV stops Git Bash rewriting the POSIX path.
  if ! _uberdev_dispatch_git_worktree_add \
      "$REPOSITORY_ROOT" "$WORKTREE_DIR" "$WORKTREE_BRANCH" "$LOG_FILE"; then
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
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"prompt_read\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  # BG_TURBO_ENV: same propagation contract as the claude-bg arm — see lines ~359-369 for the rationale (UBERDEV_TURBO + SKIP_PERMISSIONS, RFC 0005 §2.3 scoped-relaxation contract).
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
  _uberdev_dispatch_resolve_python || { DISPATCH_RC=1; DISPATCH_LOG="$LOG_FILE"; return 1; }
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
    case "$PYTHON_PREFIX" in ""|-3) ;; *) exit 126 ;; esac
    [ -n "$PYTHON_EXE" ] && [ -x "$PYTHON_EXE" ] || exit 126
    _UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"
    run_python() {
      if [ -n "$PYTHON_PREFIX" ]; then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi
    }
    python3() { run_python "$@"; }
    export -n -f run_python python3 2>/dev/null || exit 126
    WORKTREE_DIR="$1"; STATUS_FILE="$2"; RESULT_FILE="$3"; ISSUE_NUM="$4"; TIER="$5"; shift 5
    . "$DISPATCH_LIB" || exit 126
    WRAPPER_PID="${UBERDEV_WRAPPER_PID:-$$}"
    EMPTY_VALUE=
    write_status() {
      _uberdev_agent_publish_status_record "$STATUS_FILE" provider background "$1" "$2" "$WRAPPER_PID" \
        "$EMPTY_VALUE" "$EMPTY_VALUE" "$ISSUE_NUM" "$TIER" \
        "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" 0
    }
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
    trap cleanup_partial EXIT
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
    trap - EXIT HUP INT TERM
    write_status "$STATE" "$PROVIDER_RC" || exit 126
    exit "$PROVIDER_RC"
  ' _ "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE" "$WORKTREE_DIR" "$STATUS_FILE" "$RESULT_FILE" "$ISSUE_NUM" "$TIER" "${PROVIDER_CMD[@]}" \
    >"$LOG_FILE" 2>&1 &
  DISPATCH_RC=$?
  local LAUNCH_PID="$!"
  disown "$LAUNCH_PID" 2>/dev/null || true
  if ! DISPATCH_ID="$(_uberdev_dispatch_capture_supervisor_pid "$LAUNCH_PID" "$STATUS_FILE.pid")"; then
    kill -TERM "$LAUNCH_PID" 2>/dev/null || true
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"pid_target_unsafe\",\"backend\":\"background\",\"rc\":3}"
    rm -f "$STATUS_FILE.pid" 2>/dev/null || true
    return 3
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
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"background\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
}

_uberdev_dispatch_report_codex_setup_cleanup_failure() {
  local issue_num="$1" phase="$2" repo_root="$3" worktree_relative="$4"
  local branch="$5" receipt="$6" token="$7" log_file="$8"
  if _uberdev_dispatch_cleanup_codex_worktree "$repo_root" "$worktree_relative" "$branch" \
      "$receipt" "$token" failed; then
    return 0
  fi
  printf 'codex dispatch: setup cleanup failed after %s; worktree=%s branch=%s receipt=%s\n' \
    "$phase" "$repo_root/$worktree_relative" "$branch" "$receipt" >>"$log_file"
  _uberdev_dispatch_audit dispatch_cleanup_failed \
    "{\"issue\":$issue_num,\"phase\":\"$phase\",\"backend\":\"codex\",\"rc\":74}"
  return 74
}

# _uberdev_dispatch_codex ISSUE_NUM TIER PROMPT_FILE
#
# Codex CLI backend (RFC 0012 §3.4 codex-port). Isolated children use a
# dispatcher-controlled worktree; caller-workspace children execute directly
# in the validated repository and intentionally create no worktree. Both modes
# read the prompt from $PROMPT_FILE, launch a detached headless process, capture
# its PID in DISPATCH_ID, and publish status JSON for liveness polling.
#
# What's different from `background`:
#   - execs `codex exec` instead of `claude -p` (Codex's headless non-interactive
#     mode). The wrapper `cd`s into the selected execution directory; --json
#     streams progress to the log and -o captures the final message.
#   - isolated mode creates a dispatcher-owned worktree and normally selects
#     workspace-write. Caller mode creates no worktree, runs in the validated
#     repository root, and uses the route-selected sandbox (reviewers may be
#     read-only while fixer routes use workspace-write).
#   - --skip-git-repo-check is NOT passed in either mode: both execution
#     directories are validated git checkouts, so Codex's repo guard remains a
#     useful safety net.
#   - MODEL/PERM_FLAG/EFFORT_FLAG from the claude arms don't apply: codex
#     selects model via -m / config.toml, and sandbox mode replaces the
#     permission-flag mechanism. BG_TURBO_ENV still propagates UBERDEV_TURBO
#     so the spawned agent knows it's in turbo mode.
#   - Liveness is PID-based (kill -0), same as background — there is no
#     `claude agents --json` equivalent to poll. The launcher's goal-state
#     polling reuses the background path's kill -0 contract unchanged.
_uberdev_dispatch_timeout_intent_matches() {
  local probe
  probe="$(_uberdev_agent_timeout_intent_probe "$1" "$2" 2>/dev/null)" || return 1
  [ "$probe" = valid ]
}

_uberdev_dispatch_codex() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local INSTANCE_SLUG
  INSTANCE_SLUG="$(_uberdev_dispatch_instance_slug)" || { DISPATCH_RC=1; return 1; }
  local STATUS_FILE="${UBERDEV_AGENT_STATUS_FILE:-${UBERDEV_TMPDIR:-/tmp}/solve-codex-status-$ISSUE_NUM.json}"
  local LOG_FILE="${STATUS_FILE}.log"
  local RESULT_FILE="${UBERDEV_AGENT_RESULT_FILE:-${UBERDEV_TMPDIR:-/tmp}/solve-codex-result-$ISSUE_NUM.md}"
  local WORKSPACE_MODE="${UBERDEV_AGENT_WORKSPACE_MODE:-isolated}"
  local WORKSPACE_DIR="${UBERDEV_AGENT_WORKSPACE_DIR:-}"
  local WORKTREE_RELATIVE=".claude/worktrees/solve-issue-$ISSUE_NUM-$INSTANCE_SLUG"
  local WORKTREE_DIR=''
  local WORKTREE_BRANCH="worktree-solve-issue-$ISSUE_NUM-$INSTANCE_SLUG"
  local EXECUTION_DIR=''
  local ROUTE_MODEL="${UBERDEV_AGENT_ROUTE_MODEL:-gpt-5.6-sol}"
  local ROUTE_EFFORT="${UBERDEV_AGENT_ROUTE_EFFORT:-medium}"
  local ROUTE_SERVICE_TIER="${UBERDEV_AGENT_SERVICE_TIER:-default}"
  local ROUTE_SANDBOX="${UBERDEV_AGENT_SANDBOX:-workspace-write}"
  local EFFECTIVE_POLICY="${UBERDEV_AGENT_EFFECTIVE_POLICY:-${UBERDEV_AGENT_ROUTING_MODE:-adaptive}}"
  local REPOSITORY_ROOT WORKTREE_RECEIPT WORKTREE_TOKEN='' ABORT_PID ABORT_CANDIDATE WORKTREE_ADD_RC=0
  local CHILD_OWNED="${UBERDEV_AGENT_CHILD_OWNED:-0}"
  REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" || { DISPATCH_RC=1; return 1; }
  WORKTREE_DIR="$REPOSITORY_ROOT/$WORKTREE_RELATIVE"
  EXECUTION_DIR="$WORKTREE_DIR"
  case "$WORKSPACE_MODE" in
    isolated) [ -z "$WORKSPACE_DIR" ] || { DISPATCH_RC=3; return 3; } ;;
    caller)
      [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ] || { DISPATCH_RC=3; return 3; }
      WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd -P)" || { DISPATCH_RC=3; return 3; }
      [ "$WORKSPACE_DIR" = "$REPOSITORY_ROOT" ] || { DISPATCH_RC=3; return 3; }
      EXECUTION_DIR="$WORKSPACE_DIR"
      WORKTREE_RELATIVE=''
      WORKTREE_DIR=''
      WORKTREE_BRANCH=''
      ;;
    *) DISPATCH_RC=3; return 3 ;;
  esac
  WORKTREE_RECEIPT="$STATUS_FILE.worktree-owner.json"
  if [ "$EFFECTIVE_POLICY" = inherit ]; then
    ROUTE_MODEL=""
    ROUTE_EFFORT=""
  fi
  # TOCTOU hardening (#155): guard + 0600-create the predictable paths before
  # any redirect writes to them (mirrors the background arm exactly).
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "codex"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE.pid" "$ISSUE_NUM" "codex"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE" "$ISSUE_NUM" "codex"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$RESULT_FILE" "$ISSUE_NUM" "codex"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if [ "$WORKSPACE_MODE" = isolated ] && [ "$CHILD_OWNED" = "1" ]; then
    WORKTREE_TOKEN="$(_uberdev_dispatch_create_codex_worktree_receipt \
      "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$WORKTREE_RECEIPT")" || {
        DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3;
      }
  fi
  # Explicit dispatcher-controlled worktree (same rationale as the background
  # arm — sidesteps backend-specific worktree handling; MSYS_NO_PATHCONV for
  # Git Bash on Windows).
  if [ "$WORKSPACE_MODE" = isolated ]; then
    _uberdev_dispatch_git_worktree_add "$REPOSITORY_ROOT" "$WORKTREE_DIR" "$WORKTREE_BRANCH" "$LOG_FILE" \
      || WORKTREE_ADD_RC=$?
  fi
  if [ "$WORKTREE_ADD_RC" -ne 0 ]; then
    if [ "$CHILD_OWNED" = "1" ] && ! _uberdev_dispatch_report_codex_setup_cleanup_failure "$ISSUE_NUM" setup_failed \
        "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$WORKTREE_RECEIPT" "$WORKTREE_TOKEN" "$LOG_FILE"; then
      DISPATCH_RC=74
      DISPATCH_LOG="$LOG_FILE"
      return 74
    fi
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"worktree\",\"backend\":\"codex\",\"rc\":1}"
    return 1
  fi
  # Validate readability without copying prompt content into argv. Codex exec
  # accepts positional `-` and reads the instruction from stdin.
  if [ ! -f "$PROMPT_FILE" ] || [ ! -r "$PROMPT_FILE" ]; then
    if [ "$WORKSPACE_MODE" = isolated ] && [ "$CHILD_OWNED" = "1" ] && \
        ! _uberdev_dispatch_report_codex_setup_cleanup_failure "$ISSUE_NUM" prompt_read \
          "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$WORKTREE_RECEIPT" "$WORKTREE_TOKEN" "$LOG_FILE"; then
      DISPATCH_RC=74
      DISPATCH_LOG="$LOG_FILE"
      return 74
    fi
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"prompt_read\",\"backend\":\"codex\",\"rc\":1}"
    return 1
  fi
  # BG_TURBO_ENV: same propagation contract as the other arms. UBERDEV_TURBO=1
  # so the spawned codex agent knows it's in turbo mode. SKIP_PERMISSIONS is a
  # claude-specific flag; codex autonomy comes from --sandbox workspace-write,
  # so it's intentionally NOT propagated here (would be a no-op env var).
  local BG_TURBO_ENV=()
  [[ "${AUTO_MODE:-0}" == "1" ]] && BG_TURBO_ENV=( UBERDEV_TURBO=1 )
  # Detached wrapper around headless codex exec. The wrapper owns both status
  # writes (running -> terminal) so a fast codex exit cannot race with the parent
  # and be overwritten back to "running". Track the wrapper PID, not the raw
  # codex child, so /goal can poll a process that owns the final status write.
  if ! _uberdev_dispatch_resolve_python; then
    if [ "$WORKSPACE_MODE" = isolated ] && [ "$CHILD_OWNED" = "1" ] && \
        ! _uberdev_dispatch_report_codex_setup_cleanup_failure "$ISSUE_NUM" python_launcher \
          "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$WORKTREE_RECEIPT" "$WORKTREE_TOKEN" "$LOG_FILE"; then
      DISPATCH_RC=74
      DISPATCH_LOG="$LOG_FILE"
      return 74
    fi
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"python_launcher\",\"backend\":\"codex\",\"rc\":1}"
    return 1
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
      case "$PYTHON_PREFIX" in ""|-3) ;; *) exit 126 ;; esac
      [ -n "$PYTHON_EXE" ] && [ -x "$PYTHON_EXE" ] || exit 126
      _UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"
      run_python() {
        if [ -n "$PYTHON_PREFIX" ]; then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi
      }
      python3() { run_python "$@"; }
      export -n -f run_python python3 2>/dev/null || exit 126
      ISSUE_NUM="$1"
      TIER="$2"
      STATUS_FILE="$3"
      RESULT_FILE="$4"
      LOG_FILE="$5"
      EXECUTION_DIR="$6"
      WORKTREE_RELATIVE="$7"
      WORKTREE_BRANCH="$8"
      PROMPT_FILE="$9"
      ROUTE_MODEL="${10}"
      ROUTE_EFFORT="${11}"
      ROUTE_SERVICE_TIER="${12}"
      ROUTE_SANDBOX="${13}"
      REPOSITORY_ROOT="${14}"
      WORKTREE_RECEIPT="${15}"
      WORKTREE_TOKEN="${16}"
      CHILD_OWNED="${17}"
      WORKSPACE_MODE="${18}"
      shift 18
      . "$DISPATCH_LIB" || exit 126
      WRAPPER_PID="${UBERDEV_WRAPPER_PID:-$$}"
      EMPTY_VALUE=
      CLEANUP_DONE=0
      FINAL_STATUS_WRITTEN=0
      TERMINAL_STATE=failed
      CLEANUP_PROVIDER_RC=null

      cleanup_worktree() {
        [ "$CLEANUP_DONE" -eq 0 ] || return 0
        if [ "$WORKSPACE_MODE" = caller ] || [ "$CHILD_OWNED" != "1" ]; then CLEANUP_DONE=1; return 0; fi
        if (
          cd "$REPOSITORY_ROOT" || exit 2
          . "$DISPATCH_LIB" || exit 2
          _uberdev_dispatch_cleanup_codex_worktree "$REPOSITORY_ROOT" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" \
            "$WORKTREE_RECEIPT" "$WORKTREE_TOKEN" "$TERMINAL_STATE"
        ); then
          CLEANUP_DONE=1
          return 0
        fi
        return 2
      }

      finalize_on_exit() {
        _exit_rc=$?
        [ "$FINAL_STATUS_WRITTEN" -eq 0 ] || return 0
        _exit_state="$TERMINAL_STATE"
        if ! cleanup_worktree; then
          printf "codex dispatch: failed to clean child worktree %s (%s)\n" "$EXECUTION_DIR" "$WORKTREE_BRANCH" >&2
          CLEANUP_PROVIDER_RC="$_exit_rc"
          _exit_rc=74
          _exit_state=failed
        elif [ "$_exit_state" = cancelled ]; then
          _exit_rc=143
          if _uberdev_dispatch_timeout_intent_matches "$STATUS_FILE" "$WRAPPER_PID"; then
            # The public waiter owns timeout classification after it has
            # published an exact cancellation intent. Preserve the running
            # snapshot so its compare-and-swap can write `timed_out`.
            return 0
          fi
        else
          _exit_state=failed
          [ "$_exit_rc" -ne 0 ] || _exit_rc=70
        fi
        write_status "$_exit_state" "$_exit_rc" || \
          printf "codex dispatch: failed to write terminal status file: %s\n" "$STATUS_FILE" >&2
      }

      trap finalize_on_exit EXIT
      trap "TERMINAL_STATE=cancelled; exit 143" HUP INT TERM

      write_status() {
        _uberdev_agent_publish_status_record "$STATUS_FILE" provider codex "$1" "$2" "$WRAPPER_PID" \
          "$EMPTY_VALUE" "$EMPTY_VALUE" "$ISSUE_NUM" "$TIER" "$CLEANUP_PROVIDER_RC" "$LOG_FILE" "$RESULT_FILE" \
          "$EXECUTION_DIR" "$WORKTREE_BRANCH" "$WORKSPACE_MODE" 1
      }

      if ! write_status running null; then
        printf "codex dispatch: failed to write running status file: %s\n" "$STATUS_FILE" >&2
        exit 126
      fi

      if cd "$EXECUTION_DIR"; then
        CODEX_ROUTE_ARGS=()
        [ -z "$ROUTE_MODEL" ] || CODEX_ROUTE_ARGS+=( -m "$ROUTE_MODEL" )
        [ -z "$ROUTE_EFFORT" ] || CODEX_ROUTE_ARGS+=( -c "model_reasoning_effort=\"$ROUTE_EFFORT\"" )
        env "$@" codex --ask-for-approval never exec \
        --sandbox "$ROUTE_SANDBOX" \
        "${CODEX_ROUTE_ARGS[@]}" \
        -c "service_tier=\"$ROUTE_SERVICE_TIER\"" \
        -c "features.multi_agent=false" \
        --json \
        -o "$RESULT_FILE" \
        - < "$PROMPT_FILE"
        CODEX_RC=$?
      else
        CODEX_RC=127
      fi
      CODEX_STATE=failed
      [ "$CODEX_RC" -eq 0 ] && CODEX_STATE=completed
      if [ "$CODEX_RC" -eq 0 ] && [ ! -s "$RESULT_FILE" ]; then
        printf "codex dispatch: completed without a result file: %s\n" "$RESULT_FILE" >&2
        CODEX_RC=65
        CODEX_STATE=failed
      fi
      TERMINAL_STATE="$CODEX_STATE"
      if ! cleanup_worktree; then
        printf "codex dispatch: failed to clean child worktree %s (%s)\n" "$EXECUTION_DIR" "$WORKTREE_BRANCH" >&2
        CLEANUP_PROVIDER_RC="$CODEX_RC"
        CODEX_RC=74
        CODEX_STATE=failed
        TERMINAL_STATE=failed
      else
        trap - EXIT
      fi
      if ! write_status "$CODEX_STATE" "$CODEX_RC"; then
        printf "codex dispatch: failed to write final status file: %s\n" "$STATUS_FILE" >&2
        exit 126
      fi
      FINAL_STATUS_WRITTEN=1
      exit "$CODEX_RC"
    ' _ "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE" "$ISSUE_NUM" "$TIER" "$STATUS_FILE" "$RESULT_FILE" "$LOG_FILE" "$EXECUTION_DIR" "$WORKTREE_RELATIVE" "$WORKTREE_BRANCH" "$PROMPT_FILE" \
    "$ROUTE_MODEL" "$ROUTE_EFFORT" "$ROUTE_SERVICE_TIER" "$ROUTE_SANDBOX" \
    "$REPOSITORY_ROOT" "$WORKTREE_RECEIPT" "$WORKTREE_TOKEN" "$CHILD_OWNED" "$WORKSPACE_MODE" \
    ${BG_TURBO_ENV[@]+"${BG_TURBO_ENV[@]}"} \
    >"$LOG_FILE" 2>&1 &
  DISPATCH_RC=$?
  local LAUNCH_PID="$!"
  disown 2>/dev/null || true
  if ! DISPATCH_ID="$(_uberdev_dispatch_capture_supervisor_pid "$LAUNCH_PID" "$STATUS_FILE.pid")"; then
    ABORT_PID="$LAUNCH_PID"
    if [ "$(_uberdev_dispatch_os_class)" = windows-native ]; then
      ABORT_CANDIDATE="$(_uberdev_dispatch_read_secure_pid_file "$STATUS_FILE.pid" 2>/dev/null || true)"
      [ -z "$ABORT_CANDIDATE" ] || ABORT_PID="$ABORT_CANDIDATE"
    fi
    case "$ABORT_PID" in ''|*[!0-9]*|0) kill -TERM "$LAUNCH_PID" 2>/dev/null || true ;; *) DISPATCH_ID="$ABORT_PID" ;; esac
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"pid_capture\",\"backend\":\"codex\",\"rc\":3}"
    rm -f "$STATUS_FILE.pid" 2>/dev/null || true
    return 3
  fi
  rm -f "$STATUS_FILE.pid" 2>/dev/null || true
  if [[ -n "$DISPATCH_ID" ]] && ! _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"; then
    if ! _uberdev_dispatch_accept_immediate_terminal codex "$DISPATCH_ID" "$STATUS_FILE" "$RESULT_FILE" >/dev/null; then
      DISPATCH_RC=1
      DISPATCH_ID=""
    fi
  fi
  # A fast `codex exec` failure is a terminal agent outcome, not a parent
  # dispatch setup failure. The wrapper records that in the final status JSON;
  # the parent succeeds once it has forked the wrapper and captured its PID.
  if [[ "$DISPATCH_RC" -eq 0 && -n "$DISPATCH_ID" ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"codex\",\"pid\":\"$DISPATCH_ID\",\"log\":\"$LOG_FILE\"}"
  else
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"codex\",\"rc\":$DISPATCH_RC}"
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
# Intentional asymmetry vs. claude-bg / background backends: this backend does
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
  REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"repository","backend":"wezterm","rc":1}'
    return 1
  }
  REPOSITORY_ROOT="$(cd "$REPOSITORY_ROOT" 2>/dev/null && pwd -P)" || { DISPATCH_RC=1; return 1; }
  WORKTREE_DIR="$REPOSITORY_ROOT/$WORKTREE_RELATIVE"
  # TOCTOU hardening (#155): guard + 0600-create the predictable log path
  # before the worktree-add redirect below — the wezterm backend writes the
  # SAME world-writable path the claude-bg / background backends harden, so it
  # must fail-CLOSED on a symlink/foreign-owned target too.
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "wezterm"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE" "$ISSUE_NUM" "wezterm"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  # The backend runs its own worktree add — a pane's `claude -p` does not get
  # native --worktree. Absolute path, quoted (repo path may contain spaces).
  # MSYS_NO_PATHCONV stops Git Bash rewriting the path.
  if ! _uberdev_dispatch_git_worktree_add \
      "$REPOSITORY_ROOT" "$WORKTREE_DIR" "$WORKTREE_BRANCH" "$LOG_FILE"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"worktree","backend":"wezterm","rc":1}'
    return 1
  fi
  local WORKTREE_ABS WORKTREE_NATIVE STATUS_FILE_NATIVE
  WORKTREE_ABS="$(cd "$WORKTREE_DIR" && pwd -P)" || { DISPATCH_RC=1; return 1; }
  if ! WORKTREE_NATIVE="$(_uberdev_dispatch_native_cli_path "$WORKTREE_ABS")" \
      || ! STATUS_FILE_NATIVE="$(_uberdev_dispatch_native_cli_path "$STATUS_FILE")"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"native_path","backend":"wezterm","rc":1}'
    return 1
  fi
  local PROMPT_BODY
  # B5 fix (prompt-read), mirrored from the `background` backend: an
  # unreadable $PROMPT_FILE would otherwise leave PROMPT_BODY="" and spawn
  # `claude -p ""` into the pane (garbage agent), with the audit event
  # happily reporting success. Guard the cat read and surface the failure
  # as a dispatch_setup_failed audit + rc=1.
  if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$LOG_FILE")"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"prompt_read","backend":"wezterm","rc":1}'
    return 1
  fi
  if ! _uberdev_dispatch_resolve_python; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"python_launcher","backend":"wezterm","rc":1}'
    return 1
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
      case "$PYTHON_PREFIX" in ""|-3) ;; *) exit 126 ;; esac
      [ -n "$PYTHON_EXE" ] && [ -x "$PYTHON_EXE" ] || exit 126
      _UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"
      run_python() {
        if [ -n "$PYTHON_PREFIX" ]; then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi
      }
      python3() { run_python "$@"; }
      export -n -f run_python python3 2>/dev/null || exit 126
      STATUS_FILE="$1"; ISSUE_NUM="$2"; TIER="$3"; shift 3
      . "$DISPATCH_LIB" || exit 126
      WRAPPER_PID="$$"
      EMPTY_VALUE=
      write_status() {
        _uberdev_agent_publish_status_record "$STATUS_FILE" provider wezterm "$1" "$2" \
          "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$ISSUE_NUM" "$TIER" \
          "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" "$EMPTY_VALUE" 0
      }
      write_status running null || exit 126
      "$@"
      PROVIDER_RC=$?
      if [ "$PROVIDER_RC" -eq 0 ]; then STATE=completed; else STATE=failed; fi
      write_status "$STATE" "$PROVIDER_RC" || exit 126
      exit "$PROVIDER_RC"
    ' _ "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE" "$STATUS_FILE_NATIVE" "$ISSUE_NUM" "$TIER" "${PROVIDER_CMD[@]}" \
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
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"dispatch","backend":"wezterm","rc":'"$DISPATCH_RC"'}'
  fi
  return "$DISPATCH_RC"
}
