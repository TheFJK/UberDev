#!/usr/bin/env bash
# Shape-check for the `background` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_background). Verifies explicit `git worktree add`,
# detached headless `claude -p`, nohup/disown backgrounding, per-issue
# status-file writes, and the ABSENCE of `claude --bg`. RFC 0004 §3.7 / §4.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        pattern: $pattern (must not appear)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== Positive: background backend mechanism =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_background\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_background function"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_git_worktree_add' \
  "background backend serializes explicit worktree add (sidesteps #40164)"
BG_WORKTREE_BODY="$(awk '/^_uberdev_dispatch_background\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s\n' "$BG_WORKTREE_BODY" | grep -Fq 'MSYS_NO_PATHCONV=1 git worktree add'; then
  echo "  FAIL  background backend bypasses the repository Git metadata mutex"; FAIL=$((FAIL + 1))
else
  echo "  PASS  background backend has no direct worktree-add bypass"; PASS=$((PASS + 1))
fi
assert_grep "$DISPATCH_LIB" \
  'claude -p' \
  "background backend launches headless claude -p (print mode)"
assert_grep "$DISPATCH_LIB" \
  'nohup' \
  "background backend detaches the process via nohup"
assert_grep "$DISPATCH_LIB" \
  'disown' \
  "background backend disowns the detached process"
assert_grep "$DISPATCH_LIB" \
  '"\$\{EFFORT_FLAG\[@\]\}"' \
  "background backend threads \"\${EFFORT_FLAG[@]}\" into claude -p"
assert_grep "$DISPATCH_LIB" \
  '"\$\{PERM_FLAG\[@\]\}"' \
  "background backend threads \"\${PERM_FLAG[@]}\" into claude -p"
assert_grep "$DISPATCH_LIB" \
  'BG_TURBO_ENV\+=\( SKIP_PERMISSIONS=1 \)' \
  "BG_TURBO_ENV propagates SKIP_PERMISSIONS to background dispatch arm (#241)"

echo "== Repository-root worktree placement from a subdirectory =="
BG_ROOT_TMP="$(mktemp -d)"
git init -q "$BG_ROOT_TMP/repo"
mkdir -p "$BG_ROOT_TMP/repo/nested/deep" "$BG_ROOT_TMP/runtime" "$BG_ROOT_TMP/outside"
printf 'root placement\n' >"$BG_ROOT_TMP/prompt.txt"
(
  cd "$BG_ROOT_TMP/repo/nested/deep" || exit 1
  UBERDEV_TMPDIR="$BG_ROOT_TMP/runtime" CAPTURE="$BG_ROOT_TMP/capture" \
    /bin/bash -c '
      . "$1"
      _uberdev_dispatch_git_worktree_add() {
        printf "repo=%s\ntarget=%s\n" "$1" "$2" >"$CAPTURE"
        return 77
      }
      _uberdev_dispatch_background 335 medium "$2" >/dev/null 2>&1
      [ "$?" -eq 1 ]
    ' _ "$DISPATCH_LIB" "$BG_ROOT_TMP/prompt.txt"
)
BG_EXPECTED_ROOT="$(cd "$BG_ROOT_TMP/repo" && pwd -P)"
if grep -Fqx "repo=$BG_EXPECTED_ROOT" "$BG_ROOT_TMP/capture" 2>/dev/null \
    && grep -Fqx "target=$BG_EXPECTED_ROOT/.claude/worktrees/solve-issue-335" \
      "$BG_ROOT_TMP/capture"; then
  echo "  PASS  background resolves repository root and passes an absolute worktree target"
  PASS=$((PASS + 1))
else
  echo "  FAIL  background subdirectory placement: $(tr '\n' ' ' <"$BG_ROOT_TMP/capture" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
(
  cd "$BG_ROOT_TMP/outside" || exit 1
  UBERDEV_TMPDIR="$BG_ROOT_TMP/runtime" CAPTURE="$BG_ROOT_TMP/outside-called" \
    /bin/bash -c '
      . "$1"
      _uberdev_dispatch_git_worktree_add() { : >"$CAPTURE"; return 0; }
      _uberdev_dispatch_background 336 medium "$2" >/dev/null 2>&1
      [ "$?" -eq 1 ] && [ ! -e "$CAPTURE" ]
    ' _ "$DISPATCH_LIB" "$BG_ROOT_TMP/prompt.txt"
)
if [ "$?" -eq 0 ]; then
  echo "  PASS  background fails closed outside a Git worktree before mutation"
  PASS=$((PASS + 1))
else
  echo "  FAIL  background attempted worktree mutation outside a Git repository"
  FAIL=$((FAIL + 1))
fi
rm -rf "$BG_ROOT_TMP"

echo "== Empty optional argv is nounset-safe in the actual background provider =="
BG_NOUNSET_TMP="$(mktemp -d)"
mkdir -p "$BG_NOUNSET_TMP/bin" "$BG_NOUNSET_TMP/runtime"
printf 'background nounset\n' >"$BG_NOUNSET_TMP/prompt.txt"
cat >"$BG_NOUNSET_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$BG_NOUNSET_PROVIDER_LOG"
printf 'background nounset result\n'
SH
chmod +x "$BG_NOUNSET_TMP/bin/claude"
BG_NOUNSET_SEEN=''
BG_NOUNSET_INDEX=0
for BG_TEST_BASH in /bin/bash "$(command -v bash)"; do
  case " $BG_NOUNSET_SEEN " in *" $BG_TEST_BASH "*) continue ;; esac
  BG_NOUNSET_SEEN="$BG_NOUNSET_SEEN $BG_TEST_BASH"
  BG_NOUNSET_INDEX=$((BG_NOUNSET_INDEX + 1))
  BG_NOUNSET_REPO="$BG_NOUNSET_TMP/repo-$BG_NOUNSET_INDEX"
  BG_NOUNSET_RUNTIME="$BG_NOUNSET_TMP/runtime-$BG_NOUNSET_INDEX"
  BG_NOUNSET_PROVIDER_LOG="$BG_NOUNSET_TMP/provider-$BG_NOUNSET_INDEX.log"
  mkdir -p "$BG_NOUNSET_RUNTIME"
  git init -q "$BG_NOUNSET_REPO"
  BG_NOUNSET_OUT="$({
    cd "$BG_NOUNSET_REPO" || exit 1
    PATH="$BG_NOUNSET_TMP/bin:$PATH" BG_NOUNSET_PROVIDER_LOG="$BG_NOUNSET_PROVIDER_LOG" \
      "$BG_TEST_BASH" -c '
        set -u
        . "$1"
        _uberdev_dispatch_git_worktree_add() { mkdir -p "$2"; return 0; }
        _uberdev_dispatch_wait_owned_session() { return 0; }
        MODEL=sonnet
        AUTO_MODE=0
        SKIP_PERMISSIONS=0
        PERM_FLAG=()
        EFFORT_FLAG=()
        UBERDEV_TMPDIR="$2"
        UBERDEV_AGENT_STATUS_FILE="$2/status.json"
        UBERDEV_AGENT_RESULT_FILE="$2/result.md"
        DISPATCH_RC=0
        DISPATCH_ID=""
        DISPATCH_LOG=""
        _uberdev_dispatch_background 346 medium "$3"
        rc=$?
        printf "rc=%s id=%s\n" "$rc" "$DISPATCH_ID"
        [ "$rc" -eq 0 ] && [ -n "$DISPATCH_ID" ]
      ' _ "$DISPATCH_LIB" "$BG_NOUNSET_RUNTIME" "$BG_NOUNSET_TMP/prompt.txt"
  } 2>&1)"
  BG_NOUNSET_RC=$?
  BG_NOUNSET_TRIES=0
  while ! grep -Fq '"state":"completed"' "$BG_NOUNSET_RUNTIME/status.json" 2>/dev/null \
      && [ "$BG_NOUNSET_TRIES" -lt 200 ]; do
    BG_NOUNSET_TRIES=$((BG_NOUNSET_TRIES + 1))
    sleep 0.025
  done
  BG_NOUNSET_VERSION="$($BG_TEST_BASH --version | head -1)"
  if [ "$BG_NOUNSET_RC" -eq 0 ] \
      && grep -Fq '"state":"completed"' "$BG_NOUNSET_RUNTIME/status.json" \
      && grep -Fq 'background nounset result' "$BG_NOUNSET_RUNTIME/result.md" \
      && [ "$(wc -l <"$BG_NOUNSET_PROVIDER_LOG" | tr -d ' ')" -eq 1 ]; then
    echo "  PASS  background accepts empty optional argv under set -u on $BG_NOUNSET_VERSION"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  background nounset provider contract on $BG_NOUNSET_VERSION: rc=$BG_NOUNSET_RC out=$BG_NOUNSET_OUT"
    FAIL=$((FAIL + 1))
  fi
done
rm -rf "$BG_NOUNSET_TMP"

echo "== Positive: status-file writes + audit payload =="
assert_grep "$DISPATCH_LIB" \
  'DISPATCH_RC' \
  "background backend sets the DISPATCH_RC per-issue result var"
if python3 -I -B - "$DISPATCH_LIB" <<'PY'
import json,re,sys
source=open(sys.argv[1],encoding='utf-8').read()
body=source.split('_uberdev_dispatch_background() {',1)[1].split('\n}',1)[0]
match=re.search(r'_uberdev_dispatch_audit agent_dispatched\s+\\\n\s+"((?:\\.|[^"\\])*)"',body)
assert match
template=bytes(match.group(1),'utf-8').decode('unicode_escape')
for token,value in {
    '$ISSUE_NUM':'90','$TIER':'small','$DISPATCH_ID':'12345','$LOG_FILE':'dispatch.log'
}.items(): template=template.replace(token,value)
payload=json.loads(template)
assert payload['backend']=='background'
assert payload['pid']=='12345'
PY
then
  echo "  PASS  agent_dispatched payload carries backend=background"; PASS=$((PASS + 1))
  echo "  PASS  agent_dispatched payload carries the detached pid"; PASS=$((PASS + 1))
else
  echo "  FAIL  agent_dispatched payload is not valid semantic background/PID JSON"; FAIL=$((FAIL + 2))
fi
assert_grep "$DISPATCH_LIB" \
  'solve-bg-status-|status' \
  "background backend writes a per-issue status file"

echo "== #246 D-perm/D-skip: background backend inherits paired PERM_FLAG from shared resolver =="
# The PR body and CHANGELOG claim "all three dispatch backends inherit the change
# because they all expand \"\${PERM_FLAG[@]}\" from the same resolver." That is
# structurally true, but the only functional coverage lives in
# tests/dispatch-claude-bg.test.sh (lines 633-674). A future regression where
# someone hand-edits `_uberdev_dispatch_background` to strip / hard-code
# PERM_FLAG would only red-CI the claude-bg test file. Mirror the claude-bg
# D-perm / D-skip subshell cases here to lock the "background backend inherits"
# claim against that regression class. The assertion shape is IDENTICAL across
# backends because PERM_FLAG is set by the SHARED `uberdev_dispatch_resolve_env`
# (not by per-backend code); this test verifies that resolver is reachable from
# the background backend's code path.
TALLY_FILE="$(mktemp)"

echo
echo "== #246 D-perm: AUTO_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions (background backend inherits from shared resolver) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG SKIP_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; AUTO_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-perm (background) AUTO_PERMISSIONS=1 -> PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-perm (background) PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #246 D-skip: SKIP_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions (background backend inherits from shared resolver) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG AUTO_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; SKIP_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-skip (background) SKIP_PERMISSIONS=1 -> PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-skip (background) PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

rm -f "$TALLY_FILE"

echo
echo "== Portable Python command resolution =="
PYTHON_RESOLVER_TMP="$(mktemp -d)"
REAL_PYTHON="$(command -v python3)"
cat > "$PYTHON_RESOLVER_TMP/python" <<SH
#!/bin/sh
exec "$REAL_PYTHON" "\$@"
SH
cat > "$PYTHON_RESOLVER_TMP/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
exec "$REAL_PYTHON" "\$@"
SH
chmod +x "$PYTHON_RESOLVER_TMP/python" "$PYTHON_RESOLVER_TMP/py"
if PYTHON_ONLY_OUT="$(/bin/bash -c '. "$1"; PATH="$2"; _uberdev_dispatch_python -c "print(\"python-only\")"' _ "$DISPATCH_LIB" "$PYTHON_RESOLVER_TMP" 2>&1)" \
    && [ "$PYTHON_ONLY_OUT" = python-only ]; then
  echo "  PASS  dispatch resolves Windows python when python3 is absent"; PASS=$((PASS + 1))
else
  echo "  FAIL  dispatch resolves Windows python when python3 is absent: $PYTHON_ONLY_OUT"; FAIL=$((FAIL + 1))
fi
rm -f "$PYTHON_RESOLVER_TMP/python"
if PY_LAUNCHER_OUT="$(/bin/bash -c '. "$1"; PATH="$2"; _uberdev_dispatch_python -c "print(\"py-launcher\")"' _ "$DISPATCH_LIB" "$PYTHON_RESOLVER_TMP" 2>&1)" \
    && [ "$PY_LAUNCHER_OUT" = py-launcher ]; then
  echo "  PASS  dispatch resolves Windows py -3 launcher as final fallback"; PASS=$((PASS + 1))
else
  echo "  FAIL  dispatch resolves Windows py -3 launcher as final fallback: $PY_LAUNCHER_OUT"; FAIL=$((FAIL + 1))
fi
if CACHED_PYTHON_OUT="$(/bin/bash -c '. "$1"; _uberdev_dispatch_resolve_python; PATH="$2"; _uberdev_dispatch_python -c "print(\"cached-python\")"' _ "$DISPATCH_LIB" "$PYTHON_RESOLVER_TMP/empty" 2>&1)" \
    && [ "$CACHED_PYTHON_OUT" = cached-python ]; then
  echo "  PASS  resolved absolute Python argv survives later PATH narrowing"; PASS=$((PASS + 1))
else
  echo "  FAIL  resolved absolute Python argv survives later PATH narrowing: $CACHED_PYTHON_OUT"; FAIL=$((FAIL + 1))
fi
RELATIVE_RESOLVER_TMP="$(mktemp -d)"
mkdir -p "$RELATIVE_RESOLVER_TMP/repo/relative-bin"
cat > "$RELATIVE_RESOLVER_TMP/repo/relative-bin/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
exec "$REAL_PYTHON" "\$@"
SH
chmod +x "$RELATIVE_RESOLVER_TMP/repo/relative-bin/py"
RELATIVE_EXPECTED="$(cd "$RELATIVE_RESOLVER_TMP/repo/relative-bin" && pwd -P)/py"
RELATIVE_RESOLVER_OUT="$(/bin/bash -c '
  . "$1"
  cd "$2" || exit 1
  PATH=relative-bin
  unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
  _uberdev_dispatch_resolve_python || exit 1
  cached="$_UBERDEV_PYTHON_EXE"
  cd / || exit 1
  value="$(_uberdev_dispatch_python -c "print(\"relative-cache\")")" || exit 1
  printf "cached=%s\nvalue=%s\n" "$cached" "$value"
' _ "$DISPATCH_LIB" "$RELATIVE_RESOLVER_TMP/repo" 2>&1)"
if printf '%s\n' "$RELATIVE_RESOLVER_OUT" | grep -Fq "cached=$RELATIVE_EXPECTED" \
    && printf '%s\n' "$RELATIVE_RESOLVER_OUT" | grep -Fq 'value=relative-cache'; then
  echo "  PASS  relative PATH launcher is cached as a cwd-independent absolute executable"; PASS=$((PASS + 1))
else
  echo "  FAIL  relative PATH launcher is cached as a cwd-independent absolute executable: $RELATIVE_RESOLVER_OUT"; FAIL=$((FAIL + 1))
fi
rm -rf "$RELATIVE_RESOLVER_TMP"
rm -rf "$PYTHON_RESOLVER_TMP"
if grep -Eq '(^|[[:space:]|(&])python3[[:space:]]+-' "$DISPATCH_LIB"; then
  echo "  FAIL  dispatch.sh retains a literal python3 invocation"; FAIL=$((FAIL + 1))
else
  echo "  PASS  all dispatch Python calls use the portable resolver"; PASS=$((PASS + 1))
fi
detached_resolver_count="$(grep -Fc 'nohup "${PYTHON_LAUNCH[@]}"' "$DISPATCH_LIB")"
nested_bridge_count="$(grep -Fc 'python3() { run_python "$@"; }' "$DISPATCH_LIB")"
nested_command_count="$(grep -Fc 'then command "$PYTHON_EXE" "$PYTHON_PREFIX" "$@"; else command "$PYTHON_EXE" "$@"; fi' "$DISPATCH_LIB")"
nested_cache_count="$(grep -Fc '_UBERDEV_PYTHON_EXE="$PYTHON_EXE"; _UBERDEV_PYTHON_PREFIX="$PYTHON_PREFIX"' "$DISPATCH_LIB")"
nested_prefix_guard_count="$(grep -Fc 'case "$PYTHON_PREFIX" in ""|-3) ;; *) exit 126 ;; esac' "$DISPATCH_LIB")"
nested_argv_count="$(grep -Fc '"$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE"' "$DISPATCH_LIB")"
nested_unexport_count="$(grep -Fc 'export -n -f run_python python3 2>/dev/null || exit 126' "$DISPATCH_LIB")"
if [ "$detached_resolver_count" -eq 2 ] \
    && [ "$nested_bridge_count" -eq 3 ] \
    && [ "$nested_command_count" -eq 3 ] \
    && [ "$nested_cache_count" -eq 3 ] \
    && [ "$nested_prefix_guard_count" -eq 3 ] \
    && [ "$nested_argv_count" -eq 3 ] \
    && [ "$nested_unexport_count" -eq 3 ]; then
  echo "  PASS  all three process-separated wrappers preserve validated Python executable/prefix argv and install recursion-safe local bridges"; PASS=$((PASS + 1))
else
  echo "  FAIL  all three process-separated wrappers preserve validated Python executable/prefix argv and install recursion-safe local bridges"
  echo "        detached=$detached_resolver_count bridge=$nested_bridge_count command=$nested_command_count cache=$nested_cache_count prefix_guard=$nested_prefix_guard_count argv=$nested_argv_count unexport=$nested_unexport_count"
  FAIL=$((FAIL + 1))
fi
if grep -Eq 'export[[:space:]]+-f[[:space:]]+python3|eval[[:space:]].*PYTHON|BASH_FUNC_python3' "$DISPATCH_LIB"; then
  echo "  FAIL  portable Python bridge is exported, eval-based, or environment-injected"; FAIL=$((FAIL + 1))
else
  echo "  PASS  portable Python bridge remains local and avoids eval/function export"; PASS=$((PASS + 1))
fi

echo
echo "== Git metadata mutex candidate binds the outer holder across its owner bridge =="
MUTEX_OWNER_TMP="$(mktemp -d)"
MUTEX_OWNER_BASH="$(command -v bash)"
if MUTEX_OWNER_OUT="$("$MUTEX_OWNER_BASH" -c '
  . "$1"
  holder_pid="$BASHPID"
  scope="$(_uberdev_semaphore_prepare_scope "$2/state" bridge-repository git-worktree-metadata)" || exit 1
  _uberdev_semaphore_write_process_identity() {
    mode="$1"; destination="$2"
    # Native Windows Python crosses an MSYS launcher and a command-substitution
    # bridge. The parent-depth mode must run in that bridge so it resolves back
    # to the still-live mutex holder, never the short-lived bridge process.
    [ "$mode" = parent ] && [ "$BASHPID" != "$holder_pid" ] || return 91
    printf "%s\n%s|%s|%s|%064d\n" \
      "$holder_pid" "$holder_pid" "$holder_pid" "$holder_pid" 0 >"$destination"
  }
  _uberdev_semaphore_mutex_acquire "$scope" || exit $?
  recorded_pid="$(sed -n "1p" "$scope/.mutex/owner_pid")"
  kill -0 "$recorded_pid" 2>/dev/null || exit 92
  _uberdev_semaphore_mutex_release "$scope" || exit $?
  printf "holder=%s recorded=%s\n" "$holder_pid" "$recorded_pid"
' _ "$DISPATCH_LIB" "$MUTEX_OWNER_TMP" 2>&1)" \
    && printf '%s\n' "$MUTEX_OWNER_OUT" | grep -Eq '^holder=([1-9][0-9]*) recorded=\1$'; then
  echo "  PASS  metadata mutex candidate records its live outer holder through the parent-depth bridge"
  PASS=$((PASS + 1))
else
  echo "  FAIL  metadata mutex candidate records a direct or short-lived owner: $MUTEX_OWNER_OUT"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MUTEX_OWNER_TMP"

echo
echo "== Git metadata mutex rejects polluted candidate token output before publication =="
MUTEX_POLLUTION_TMP="$(mktemp -d)"
if MUTEX_POLLUTION_OUT="$("$MUTEX_OWNER_BASH" -c '
  . "$1"
  scope="$(_uberdev_semaphore_prepare_scope "$2/state" polluted-repository git-worktree-metadata)" || exit 1
  _uberdev_semaphore_write_process_identity() {
    mode="$1"; destination="$2"
    [ "$mode" = parent ] || return 91
    printf "%s\n%s|%s|%s|%064d\n" \
      "$BASHPID" "$BASHPID" "$BASHPID" "$BASHPID" 0 >"$destination" || return 92
    printf "noise\n"
  }
  _uberdev_semaphore_mutex_acquire "$scope"
  acquire_rc=$?
  remaining=""
  for path in "$scope/.mutex" "$scope"/.mutex-candidate.*; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      remaining="$remaining ${path##*/}"
    fi
  done
  printf "rc=%s\nremaining=%s\n" "$acquire_rc" "$remaining"
' _ "$DISPATCH_LIB" "$MUTEX_POLLUTION_TMP" 2>&1)" \
    && printf '%s\n' "$MUTEX_POLLUTION_OUT" | grep -Fxq 'uberdev semaphore: mutex owner candidate returned malformed token' \
    && printf '%s\n' "$MUTEX_POLLUTION_OUT" | grep -Fxq 'rc=2' \
    && printf '%s\n' "$MUTEX_POLLUTION_OUT" | grep -Fxq 'remaining='; then
  echo "  PASS  polluted candidate output fails closed without publishing mutex state"
  PASS=$((PASS + 1))
else
  echo "  FAIL  polluted candidate output was trusted or left partial mutex state: $MUTEX_POLLUTION_OUT"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MUTEX_POLLUTION_TMP"

windows_detach_count="$(grep -Fc 'subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS' "$DISPATCH_LIB")"
posix_setsid_count="$(grep -Fc 'os.setsid()' "$DISPATCH_LIB")"
wrapper_pid_bridge_count="$(grep -Fc 'os.environ["UBERDEV_WRAPPER_PID"]=str(os.getpid())' "$DISPATCH_LIB")"
supervisor_pid_file_count="$(grep -Fc 'UBERDEV_SUPERVISOR_PID_FILE="$STATUS_FILE.pid" nohup' "$DISPATCH_LIB")"
secure_pid_writer_count="$(grep -Fc 'pid_path=os.environ["UBERDEV_SUPERVISOR_PID_FILE"]' "$DISPATCH_LIB")"
absolute_bash_launcher_count="$(grep -Fc 'launch_argv=[bash_path]' "$DISPATCH_LIB")"
if [ "$windows_detach_count" -eq 2 ] \
    && [ "$posix_setsid_count" -eq 2 ] \
    && [ "$wrapper_pid_bridge_count" -eq 2 ] \
    && [ "$supervisor_pid_file_count" -eq 2 ] \
    && [ "$secure_pid_writer_count" -eq 2 ] \
    && [ "$absolute_bash_launcher_count" -eq 2 ] \
    && grep -Fq '_uberdev_dispatch_read_secure_pid_file' "$DISPATCH_LIB" \
    && ! grep -Fq 'os.setsid(); os.execvp' "$DISPATCH_LIB"; then
  echo "  PASS  detached launchers securely bridge native Windows supervisor PIDs and preserve POSIX setsid"; PASS=$((PASS + 1))
else
  echo "  FAIL  detached launchers securely bridge native Windows supervisor PIDs and preserve POSIX setsid"; FAIL=$((FAIL + 1))
fi

echo
echo "== Immediate terminal background wrapper keeps its exact handle =="
FIXTURE_WAIT_BODY="$(awk '/^    _uberdev_dispatch_wait_owned_session\(\)/{f=1} f{print} f&&/^    }/{exit}' "$0")"
if printf '%s\n' "$FIXTURE_WAIT_BODY" | grep -Eq 'state.*completed' \
    && printf '%s\n' "$FIXTURE_WAIT_BODY" | grep -Fq 'attempts' \
    && ! printf '%s\n' "$FIXTURE_WAIT_BODY" | grep -Fq 'ps -o'; then
  echo "  PASS  immediate fixture waits on bounded canonical terminal evidence"; PASS=$((PASS + 1))
else
  echo "  FAIL  immediate fixture waits on bounded canonical terminal evidence"; FAIL=$((FAIL + 1))
fi
IMMEDIATE_TMP="$(mktemp -d)"
mkdir -p "$IMMEDIATE_TMP/bin" "$IMMEDIATE_TMP/repo/.git" "$IMMEDIATE_TMP/tmp"
cat > "$IMMEDIATE_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then pwd -P; exit 0; fi
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --git-common-dir ]; then printf '.git\n'; exit 0; fi
if [ "$1" = worktree ] && [ "$2" = add ]; then mkdir -p "$3"; exit 0; fi
exit 1
SH
cat > "$IMMEDIATE_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if /usr/bin/env | /usr/bin/grep -Eq '^BASH_FUNC_(python3|run_python)%%='; then exit 98; fi
body="$2"
sleep 0.05
printf 'immediate %s result\n' "$body"
case "$body" in *failed*) exit 29 ;; *) exit 0 ;; esac
SH
chmod +x "$IMMEDIATE_TMP/bin/git" "$IMMEDIATE_TMP/bin/claude"
for runtime_command in env nohup cat sleep rm uname grep stat id ps find basename dirname mkdir; do
  ln -s "$(command -v "$runtime_command")" "$IMMEDIATE_TMP/bin/$runtime_command"
done
IMMEDIATE_RUNTIME_PATH="$IMMEDIATE_TMP/bin:/usr/bin:/bin"
NATIVE_BASH_PROBE="$(PATH="$IMMEDIATE_RUNTIME_PATH" "$REAL_PYTHON" -I -B -c \
  'import shutil; print(shutil.which("bash") or "", end="")')"
case "$NATIVE_BASH_PROBE" in
  ''|"$IMMEDIATE_TMP/bin/"*)
    echo "  FAIL  detached native Python resolves a real Git Bash executable outside the synthetic fixture bin: $NATIVE_BASH_PROBE"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  PASS  detached native Python resolves a real Git Bash executable outside the synthetic fixture bin"
    PASS=$((PASS + 1))
    ;;
esac
IMMEDIATE_OUT="$(
  cd "$IMMEDIATE_TMP/repo" &&
  PATH="$IMMEDIATE_RUNTIME_PATH" UBERDEV_TMPDIR="$IMMEDIATE_TMP/tmp" \
  _UBERDEV_PYTHON_EXE="$REAL_PYTHON" _UBERDEV_PYTHON_PREFIX='' \
  /bin/bash -c '
    . "$1"
    UBERDEV_DETACH_DIAGNOSTICS=1; export UBERDEV_DETACH_DIAGNOSTICS
    fixture_pids=(); fixture_running_count=0
    _uberdev_dispatch_wait_owned_session() {
      local status attempts=0 terminal_seen=0 running_seen=0
      fixture_pids+=("$1")
      while [ "$attempts" -lt 200 ]; do
        status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
        if [[ "$status" == *\"state\":\"running\"* && "$running_seen" -eq 0 ]]; then
          running_seen=1; fixture_running_count=$((fixture_running_count + 1))
        fi
        if [[ "$status" == *\"state\":\"completed\"* \
            && "$status" == *\"exit_code\":0* \
            && -s "$UBERDEV_AGENT_RESULT_FILE" ]]; then
          terminal_seen=1; break
        fi
        if [[ "$status" == *\"state\":\"failed\"* \
            && "$status" =~ \"exit_code\":-?[1-9][0-9]* ]]; then
          terminal_seen=1; break
        fi
        sleep 0.025; attempts=$((attempts + 1))
      done
      [ "$terminal_seen" -eq 1 ] || return 0
      # Give the detached supervisor a bounded window to exit after publishing
      # its canonical terminal snapshot. Returning 1 selects the exact-handle
      # immediate-terminal validation path in the dispatcher.
      attempts=0
      while kill -0 "$1" 2>/dev/null && [ "$attempts" -lt 200 ]; do
        sleep 0.025; attempts=$((attempts + 1))
      done
      kill -0 "$1" 2>/dev/null && return 0
      return 1
    }
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=(); failures=0; issue=70
    record_failure() {
      failures=$((failures + 1))
      printf "mismatch issue=%s outcome=%s check=%s rc=%s dispatch_id=%q status=%q result=%q mode=%q partials=%q child_log=%q\n" \
        "$issue" "$outcome" "$1" "$rc" "${DISPATCH_ID:-}" "$status" "$result" "$mode" "$partials" "$child_log"
    }
    status_contract_matches() {
      _uberdev_dispatch_python -I -B -c '\''import json,sys
s=json.loads(sys.argv[1]); issue=int(sys.argv[2]); outcome=sys.argv[3]
expected={"issue":issue,"tier":"small","backend":"background","state":outcome,"exit_code":0 if outcome=="completed" else 29,"pid":sys.argv[4]}
raise SystemExit(0 if s==expected else 1)'\'' "$status" "$issue" "$outcome" "$DISPATCH_ID"
    }
    status_pid_matches() {
      _uberdev_dispatch_python -I -B -c '\''import json,sys; raise SystemExit(0 if json.loads(sys.argv[1]).get("pid")==sys.argv[2] else 1)'\'' \
        "$status" "$DISPATCH_ID"
    }
    probe_mode() {
      local candidate
      candidate="$(stat -c %a "$1" 2>/dev/null)"
      if [ -n "$candidate" ]; then
        case "$candidate" in *[!0-7]*) ;; *) printf "%s" "$candidate"; return 0 ;; esac
      fi
      candidate="$(stat -f %Lp "$1" 2>/dev/null)"
      [ -n "$candidate" ] || return 1
      case "$candidate" in *[!0-7]*) return 1 ;; *) printf "%s" "$candidate" ;; esac
    }
    for outcome in completed failed completed failed completed failed; do
      issue=$((issue + 1))
      printf "%s\n" "$outcome" > "$UBERDEV_TMPDIR/prompt-$issue.txt"
      UBERDEV_AGENT_STATUS_FILE="$UBERDEV_TMPDIR/status-$issue.json"
      UBERDEV_AGENT_RESULT_FILE="$UBERDEV_TMPDIR/result-$issue.md"
      export UBERDEV_AGENT_STATUS_FILE UBERDEV_AGENT_RESULT_FILE
      _uberdev_dispatch_background "$issue" small "$UBERDEV_TMPDIR/prompt-$issue.txt"
      rc=$?; status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
      result="$(cat "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null)"
      mode="$(probe_mode "$UBERDEV_AGENT_RESULT_FILE")"
      partials="$(find "$UBERDEV_TMPDIR" -maxdepth 1 \( -name "result-$issue.md.partial.*" -o -name "result-$issue.md.tmp.*" \) -print)"
      child_log="$(cat "$UBERDEV_TMPDIR/solve-bg-stdout-$issue.log" 2>/dev/null)"
      if [ "$rc" -eq 0 ] && [ -n "${DISPATCH_ID:-}" ] && status_contract_matches; then
        case "$outcome" in
        completed)
          [ "$result" = "immediate completed result" ] || record_failure completed_result
          # Git Bash reports synthesized POSIX bits over native Windows ACLs;
          # require a validated octal probe there, and exact 0600 on POSIX.
          case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) [ -n "$mode" ] || record_failure completed_result_mode ;;
            *) [ "$mode" = 600 ] || record_failure completed_result_mode ;;
          esac
          ;;
        failed)
          [ ! -s "$UBERDEV_AGENT_RESULT_FILE" ] || record_failure failed_result_empty
          ;;
        esac
      else
        record_failure terminal_contract
      fi
      [ -z "$partials" ] || record_failure partial_cleanup
      [ -n "${DISPATCH_ID:-}" ] || record_failure dispatch_id
      status_pid_matches || record_failure terminal_pid_identity
    done
    for fixture_pid in "${fixture_pids[@]}"; do
      wait "$fixture_pid" 2>/dev/null || true
    done
    [ "$fixture_running_count" -eq 6 ] || { failures=$((failures + 1)); printf "mismatch check=running_status count=%s\n" "$fixture_running_count"; }
    printf "failures=%s\n" "$failures"
  ' _ "$DISPATCH_LIB"
)"
if [[ "$IMMEDIATE_OUT" == *'failures=0'* ]]; then
  echo "  PASS  background captures provider stdout into a private canonical result and preserves exact immediate terminal handles"; PASS=$((PASS + 1))
else
  echo "  FAIL  background captures provider stdout into a private canonical result and preserves exact immediate terminal handles"
  echo "        $IMMEDIATE_OUT"; FAIL=$((FAIL + 1))
fi
rm -rf "$IMMEDIATE_TMP"

echo
echo "== Delayed background wrapper registers one PID through running and terminal state =="
DELAYED_TMP="$(mktemp -d)"
mkdir -p "$DELAYED_TMP/bin" "$DELAYED_TMP/repo/.git" "$DELAYED_TMP/tmp"
cat > "$DELAYED_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then pwd -P; exit 0; fi
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --git-common-dir ]; then printf '.git\n'; exit 0; fi
if [ "$1" = worktree ] && [ "$2" = add ]; then mkdir -p "$3"; exit 0; fi
exit 1
SH
cat > "$DELAYED_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if /usr/bin/env | /usr/bin/grep -Eq '^BASH_FUNC_(python3|run_python)%%='; then exit 98; fi
sleep 1
printf 'delayed background result\n'
SH
chmod +x "$DELAYED_TMP/bin/git" "$DELAYED_TMP/bin/claude"
cat > "$DELAYED_TMP/bin/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
exec "$REAL_PYTHON" "\$@"
SH
chmod +x "$DELAYED_TMP/bin/py"
for runtime_command in env nohup cat sleep rm uname grep stat id ps basename dirname mkdir; do
  ln -s "$(command -v "$runtime_command")" "$DELAYED_TMP/bin/$runtime_command"
done
DELAYED_RUNTIME_PATH="$DELAYED_TMP/bin:/usr/bin:/bin"
printf 'delayed' > "$DELAYED_TMP/prompt.txt"
DELAYED_OUT="$(
  cd "$DELAYED_TMP/repo" &&
  PATH="$DELAYED_RUNTIME_PATH" UBERDEV_TMPDIR="$DELAYED_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    PATH=../bin
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 1
    resolved_python="$_UBERDEV_PYTHON_EXE"
    PATH="$3"; export PATH
    run_python() { command "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$@"; }
    python3() { run_python "$@"; }
    export -f run_python python3
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=()
    _uberdev_dispatch_background 90 small "$2"
    rc=$?; pid="${DISPATCH_ID:-}"; status_file="$UBERDEV_TMPDIR/solve-bg-status-90.json"
    attempts=0; running=""
    while [ "$attempts" -lt 200 ]; do
      running="$(cat "$status_file" 2>/dev/null)"
      [[ "$running" == *\"state\":\"running\"* ]] && break
      sleep 0.025; attempts=$((attempts + 1))
    done
    attempts=0; terminal="$running"
    while [ "$attempts" -lt 200 ]; do
      terminal="$(cat "$status_file" 2>/dev/null)"
      [[ "$terminal" == *\"state\":\"completed\"* ]] && break
      sleep 0.025; attempts=$((attempts + 1))
    done
    printf "rc=%s\npid=%s\nresolved=%s\nrunning=%s\nterminal=%s\nresult=%s\n" \
      "$rc" "$pid" "$resolved_python" "$running" "$terminal" "$(cat "$UBERDEV_TMPDIR/solve-bg-result-90.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$DELAYED_TMP/prompt.txt" "$DELAYED_RUNTIME_PATH"
)"
delayed_pid="$(printf '%s\n' "$DELAYED_OUT" | sed -n 's/^pid=//p')"
delayed_python_resolved="$(printf '%s\n' "$DELAYED_OUT" | sed -n 's/^resolved=//p')"
delayed_python_expected="$(cd "$DELAYED_TMP/bin" && pwd -P)/py"
if grep -Fq "assert lines['resolved']""==sys.argv[3]" "$0"; then
  echo "  FAIL  delayed fixture compares its POSIX launcher path before native-Python argv conversion"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  delayed fixture compares its POSIX launcher path before native-Python argv conversion"
  PASS=$((PASS + 1))
fi
if [ -n "$delayed_pid" ] \
    && [ "$delayed_python_resolved" = "$delayed_python_expected" ] \
    && python3 -I -B - "$DELAYED_OUT" "$delayed_pid" <<'PY'
import json,sys
lines=dict(line.split('=',1) for line in sys.argv[1].splitlines())
pid=sys.argv[2]
assert lines['rc']=='0' and lines['pid']==pid
assert json.loads(lines['running'])=={
    'issue':90,'tier':'small','backend':'background','state':'running','exit_code':None,'pid':pid,
}
assert json.loads(lines['terminal'])=={
    'issue':90,'tier':'small','backend':'background','state':'completed','exit_code':0,'pid':pid,
}
assert lines['result']=='delayed background result'
PY
then
  echo "  PASS  delayed background running and terminal receipts retain the dispatch PID"; PASS=$((PASS + 1))
else
  echo "  FAIL  delayed background running and terminal receipts retain the dispatch PID: $DELAYED_OUT"; FAIL=$((FAIL + 1))
fi
rm -rf "$DELAYED_TMP"

echo
echo "== Anti-pattern: background backend never uses claude --bg =="
# Extract just the _uberdev_dispatch_background function body and assert
# `claude --bg` does not appear inside it (sibling backends in the same
# file legitimately use it — scope the check to this function).
BG_FN_BODY="$(awk '/^_uberdev_dispatch_background\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s' "$BG_FN_BODY" | grep -qE 'claude --bg'; then
  echo "  FAIL  _uberdev_dispatch_background uses claude --bg (must use claude -p)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  _uberdev_dispatch_background does not use claude --bg"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
