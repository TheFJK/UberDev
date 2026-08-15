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
BG_NOUNSET_TERMINAL_EVIDENCE_BUDGET_S=30
_dispatch_test_wait_background_terminal() {
  local runtime_dir="$1" provider_log_file="$2" budget_s="$3"
  local status_file="$runtime_dir/status.json" result_file="$runtime_dir/result.md"
  local child_log_file="$runtime_dir/solve-bg-stdout-346.log"
  local started=$SECONDS child_status='' result provider_log child_log reason=timeout
  while [ $((SECONDS - started)) -lt "$budget_s" ]; do
    child_status="$(cat "$status_file" 2>/dev/null)"
    case "$child_status" in
      *\"state\":\"completed\"*) return 0 ;;
      *\"state\":\"failed\"*) reason=unexpected_terminal; break ;;
    esac
    sleep 0.025
  done
  result="$(cat "$result_file" 2>/dev/null)"
  provider_log="$(tail -n 20 "$provider_log_file" 2>/dev/null | tr '\n' ';')"
  child_log="$(tail -n 20 "$child_log_file" 2>/dev/null | tr '\n' ';')"
  printf 'background terminal evidence failure: reason=%s budget_s=%s status_file=%s status=%s result_file=%s result=%s provider_log_file=%s provider_log=%s child_log_file=%s child_log=%s\n' \
    "$reason" "$budget_s" "$status_file" "${child_status:-missing}" "$result_file" "${result:-missing}" \
    "$provider_log_file" "${provider_log:-empty}" "$child_log_file" "${child_log:-empty}" >&2
  return 1
}
if BG_NOUNSET_TIMEOUT_DIAGNOSTIC="$(_dispatch_test_wait_background_terminal \
    "$BG_NOUNSET_TMP/missing-runtime" "$BG_NOUNSET_TMP/missing-provider.log" 0 2>&1)"; then
  echo "  FAIL  background terminal observer fails closed with bounded evidence diagnostics"
  FAIL=$((FAIL + 1))
else
  case "$BG_NOUNSET_TIMEOUT_DIAGNOSTIC" in
    *"reason=timeout"*"budget_s=0"*"status=missing"*"result=missing"*"provider_log=empty"*"child_log=empty"*)
      echo "  PASS  background terminal observer fails closed with bounded evidence diagnostics"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  background terminal observer timeout diagnostic: $BG_NOUNSET_TIMEOUT_DIAGNOSTIC"
      FAIL=$((FAIL + 1))
      ;;
  esac
fi
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
  BG_NOUNSET_TERMINAL_DIAGNOSTIC=''
  if BG_NOUNSET_TERMINAL_DIAGNOSTIC="$(_dispatch_test_wait_background_terminal \
      "$BG_NOUNSET_RUNTIME" "$BG_NOUNSET_PROVIDER_LOG" \
      "$BG_NOUNSET_TERMINAL_EVIDENCE_BUDGET_S" 2>&1)"; then
    BG_NOUNSET_TERMINAL_RC=0
  else
    BG_NOUNSET_TERMINAL_RC=1
  fi
  BG_NOUNSET_VERSION="$($BG_TEST_BASH --version | head -1)"
  if [ "$BG_NOUNSET_RC" -eq 0 ] \
      && [ "$BG_NOUNSET_TERMINAL_RC" -eq 0 ] \
      && grep -Fq '"state":"completed"' "$BG_NOUNSET_RUNTIME/status.json" \
      && grep -Fq 'background nounset result' "$BG_NOUNSET_RUNTIME/result.md" \
      && [ "$(wc -l <"$BG_NOUNSET_PROVIDER_LOG" | tr -d ' ')" -eq 1 ]; then
    echo "  PASS  background accepts empty optional argv under set -u on $BG_NOUNSET_VERSION"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  background nounset provider contract on $BG_NOUNSET_VERSION: rc=$BG_NOUNSET_RC out=$BG_NOUNSET_OUT terminal=$BG_NOUNSET_TERMINAL_DIAGNOSTIC"
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
# structurally true, but the only functional coverage used to live in the
# now-retired detached-session fixture. A future regression where
# someone hand-edits `_uberdev_dispatch_background` to strip / hard-code
# PERM_FLAG would have red-CI'd only that one file. The D-perm / D-skip
# subshell cases are mirrored here to lock the "background backend inherits"
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

_dispatch_test_resolve_tool() {
  local tool_name="$1" candidate
  candidate="$(command -v "$tool_name" 2>/dev/null)" || return 1
  case "$candidate" in
    /*|[A-Za-z]:[\\/]*) ;;
    *) return 1 ;;
  esac
  [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

_dispatch_test_install_tool() {
  local destination="$1" tool_name="$2" tool_path="$3" escaped_path
  [ ! -e "$destination/$tool_name" ] || return 0
  escaped_path="$(printf '%q' "$tool_path")" || return 1
  printf '#!/bin/bash\nexec %s "$@"\n' "$escaped_path" >"$destination/$tool_name" \
    || return 1
  chmod +x "$destination/$tool_name"
}

_dispatch_test_populate_mutex_tools() {
  local destination="$1" runtime_command tool_path hash_tool hash_tool_path os_name
  for runtime_command in basename cat chmod cut dirname grep ln mkdir mktemp mv ps rm rmdir sed sleep stat tr uname; do
    tool_path="$(_dispatch_test_resolve_tool "$runtime_command")" || return 1
    _dispatch_test_install_tool "$destination" "$runtime_command" "$tool_path" || return 1
  done
  if hash_tool_path="$(_dispatch_test_resolve_tool shasum 2>/dev/null)"; then
    hash_tool=shasum
  elif hash_tool_path="$(_dispatch_test_resolve_tool sha256sum 2>/dev/null)"; then
    hash_tool=sha256sum
  else
    return 1
  fi
  _dispatch_test_install_tool "$destination" "$hash_tool" "$hash_tool_path" || return 1
  os_name="$(uname -s 2>/dev/null)" || return 1
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*)
      tool_path="$(_dispatch_test_resolve_tool cygpath)" || return 1
      _dispatch_test_install_tool "$destination" cygpath "$tool_path" || return 1
      ;;
  esac
}

_dispatch_test_verify_mutex_tools() {
  local destination="$1" sanitized raw digest os_name windows_path
  (
    PATH="$destination"
    sanitized="$(printf 'fixture-text' | tr -d '\r\n')" || exit 11
    [ "$sanitized" = fixture-text ] || exit 12
    if command -v shasum >/dev/null 2>&1; then
      raw="$(printf 'fixture-hash' | shasum -a 256)" || exit 13
    elif command -v sha256sum >/dev/null 2>&1; then
      raw="$(printf 'fixture-hash' | sha256sum)" || exit 13
    else
      exit 14
    fi
    digest="${raw%%[[:space:]]*}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 15
    os_name="$(uname -s 2>/dev/null)" || exit 16
    case "$os_name" in
      MINGW*|MSYS*|CYGWIN*)
        windows_path="$(cygpath -u 'C:/Windows' 2>/dev/null)" || exit 17
        case "$windows_path" in /*) ;; *) exit 18 ;; esac
        ;;
    esac
  )
}

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
# #384 re-pointed these two anchors. Both guards still exist in both wrappers
# and still `exit 126`; what changed is that they now NAME the worktree they
# are about to strand first (`report_presource_leak`), because they sit in the
# post-worktree/pre-source window and used to exit in total silence. The
# patterns became EREs rather than fixed strings only so the message argument
# — which contains embedded single quotes — can be skipped over; both ends of
# each statement are still pinned, so a dropped guard or a dropped exit fails
# here exactly as before.
nested_prefix_guard_count="$(grep -Ec 'case "\$PYTHON_PREFIX" in ""\|-3\) ;; \*\) report_presource_leak .*; exit 126 ;; esac' "$DISPATCH_LIB")"
nested_argv_count="$(grep -Fc '"$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$_UBERDEV_DISPATCH_FILE"' "$DISPATCH_LIB")"
nested_unexport_count="$(grep -Ec 'export -n -f run_python python3 2>/dev/null \|\| \{ report_presource_leak .*; exit 126; \}' "$DISPATCH_LIB")"
# POPULATION COUNT-LOCK. #381 deleted the codex arm of
# _uberdev_agent_dispatch_backend, and with it the third process-separated
# wrapper, so every count below dropped by exactly one. The two survivors are
# _uberdev_dispatch_background (lib/dispatch.sh:1504) and
# _uberdev_dispatch_wezterm (lib/dispatch.sh:1837); only background is
# nohup-detached, which is why detached_resolver_count is 1 and the rest are 2.
# The INVARIANT is unchanged and these stay `-eq`, not `-ge`: a dropped bridge
# and a newly-added wrapper that forgets one must both still fail here.
if [ "$detached_resolver_count" -eq 1 ] \
    && [ "$nested_bridge_count" -eq 2 ] \
    && [ "$nested_command_count" -eq 2 ] \
    && [ "$nested_cache_count" -eq 2 ] \
    && [ "$nested_prefix_guard_count" -eq 2 ] \
    && [ "$nested_argv_count" -eq 2 ] \
    && [ "$nested_unexport_count" -eq 2 ]; then
  echo "  PASS  both process-separated wrappers preserve validated Python executable/prefix argv and install recursion-safe local bridges"; PASS=$((PASS + 1))
else
  echo "  FAIL  both process-separated wrappers preserve validated Python executable/prefix argv and install recursion-safe local bridges"
  echo "        detached=$detached_resolver_count bridge=$nested_bridge_count command=$nested_command_count cache=$nested_cache_count prefix_guard=$nested_prefix_guard_count argv=$nested_argv_count unexport=$nested_unexport_count"
  FAIL=$((FAIL + 1))
fi
if grep -Eq 'export[[:space:]]+-f[[:space:]]+python3|eval[[:space:]].*PYTHON|BASH_FUNC_python3' "$DISPATCH_LIB"; then
  echo "  FAIL  portable Python bridge is exported, eval-based, or environment-injected"; FAIL=$((FAIL + 1))
else
  echo "  PASS  portable Python bridge remains local and avoids eval/function export"; PASS=$((PASS + 1))
fi

echo
echo "== Git metadata mutex uses the validated Python argv and records its live holder =="
MUTEX_OWNER_TMP="$(mktemp -d)"
MUTEX_OWNER_BASH="$(command -v bash)"
mkdir -p "$MUTEX_OWNER_TMP/tools"
_dispatch_test_populate_mutex_tools "$MUTEX_OWNER_TMP/tools" || {
  echo "  FAIL  portable mutex fixture tools are unavailable"
  exit 1
}
if _dispatch_test_verify_mutex_tools "$MUTEX_OWNER_TMP/tools"; then
  :
else
  fixture_tools_rc=$?
  echo "  FAIL  portable mutex fixture dependency probe failed (rc=$fixture_tools_rc)"
  exit 1
fi
mutex_resolver_failures=''
for resolver in python3 python py; do
  resolver_dir="$MUTEX_OWNER_TMP/$resolver"
  mkdir -p "$resolver_dir"
  if [ "$resolver" = py ]; then
    cat >"$resolver_dir/$resolver" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
exec "$REAL_PYTHON" "\$@"
SH
  else
    cat >"$resolver_dir/$resolver" <<SH
#!/bin/sh
exec "$REAL_PYTHON" "\$@"
SH
  fi
  chmod +x "$resolver_dir/$resolver"
  if MUTEX_OWNER_OUT="$("$MUTEX_OWNER_BASH" -c '
    . "$1"
    PATH="$2:$3"
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 90
    holder_pid="$BASHPID"
    expected_pid="$holder_pid"
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*|CYGWIN*)
        expected_pid="$(_uberdev_semaphore_windows_native_pid "$holder_pid")" || exit 95
        ;;
    esac
    scope="$(_uberdev_semaphore_prepare_scope "$4/state" resolver-repository git-worktree-metadata)" || exit 91
    _uberdev_semaphore_mutex_acquire "$scope" || exit $?
    recorded_pid="$(sed -n "1p" "$scope/.mutex/owner_pid")"
    recorded_identity="$(sed -n "2p" "$scope/.mutex/owner_pid")"
    [ "$recorded_pid" = "$expected_pid" ] || exit 92
    _uberdev_semaphore_process_identity_matches "$recorded_pid" "$recorded_identity" || exit 93
    _uberdev_semaphore_mutex_release "$scope" || exit $?
    remaining=""
    for path in "$scope/.mutex" "$scope"/.mutex-candidate.*; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || remaining="$remaining ${path##*/}"
    done
    [ -z "$remaining" ] || exit 94
    printf "holder=%s expected=%s recorded=%s match=yes\n" "$holder_pid" "$expected_pid" "$recorded_pid"
  ' _ "$DISPATCH_LIB" "$resolver_dir" "$MUTEX_OWNER_TMP/tools" "$resolver_dir" 2>&1)" \
      && printf '%s\n' "$MUTEX_OWNER_OUT" | grep -Eq '^holder=[1-9][0-9]* expected=[1-9][0-9]* recorded=[1-9][0-9]* match=yes$'; then
    :
  else
    mutex_resolver_failures="$mutex_resolver_failures $resolver=[$MUTEX_OWNER_OUT]"
  fi
done
if [ -z "$mutex_resolver_failures" ]; then
  echo "  PASS  python3, python, and py -3 acquire with narrowed PATH and record the live holder"
  PASS=$((PASS + 1))
else
  echo "  FAIL  portable resolver mutex acquisition: $mutex_resolver_failures"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MUTEX_OWNER_TMP"

echo
echo "== Concurrent worktree additions serialize through one portable metadata mutex =="
MUTEX_CONCURRENT_TMP="$(mktemp -d)"
mkdir -p "$MUTEX_CONCURRENT_TMP/bin" "$MUTEX_CONCURRENT_TMP/repo/.git" "$MUTEX_CONCURRENT_TMP/state"
cat >"$MUTEX_CONCURRENT_TMP/bin/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
exec "$REAL_PYTHON" "\$@"
SH
cat >"$MUTEX_CONCURRENT_TMP/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --git-common-dir ]; then
  printf '.git\n'
  exit 0
fi
if [ "$1" = worktree ] && [ "$2" = add ]; then
  if ! mkdir "$MUTEX_TEST_GUARD" 2>/dev/null; then
    printf 'overlap\n' >"$MUTEX_TEST_OVERLAP"
    exit 96
  fi
  sleep 0.15
  mkdir -p "$3"
  rmdir "$MUTEX_TEST_GUARD"
  exit 0
fi
exit 95
SH
chmod +x "$MUTEX_CONCURRENT_TMP/bin/py" "$MUTEX_CONCURRENT_TMP/bin/git"
_dispatch_test_populate_mutex_tools "$MUTEX_CONCURRENT_TMP/bin" || {
  echo "  FAIL  portable concurrent mutex fixture tools are unavailable"
  exit 1
}
if _dispatch_test_verify_mutex_tools "$MUTEX_CONCURRENT_TMP/bin"; then
  :
else
  fixture_tools_rc=$?
  echo "  FAIL  portable concurrent mutex fixture dependency probe failed (rc=$fixture_tools_rc)"
  exit 1
fi
for contender in one two; do
  MUTEX_TEST_GUARD="$MUTEX_CONCURRENT_TMP/state/critical" \
  MUTEX_TEST_OVERLAP="$MUTEX_CONCURRENT_TMP/state/overlap" \
  "$MUTEX_OWNER_BASH" -c '
    . "$1"
    PATH="$2"
    export PATH MUTEX_TEST_GUARD MUTEX_TEST_OVERLAP
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 90
    _uberdev_dispatch_git_worktree_add "$3" "$4" "$5" "$6"
  ' _ "$DISPATCH_LIB" "$MUTEX_CONCURRENT_TMP/bin" "$MUTEX_CONCURRENT_TMP/repo" \
    "$MUTEX_CONCURRENT_TMP/worktree-$contender" "branch-$contender" \
    "$MUTEX_CONCURRENT_TMP/$contender.log" &
  case "$contender" in
    one) mutex_concurrent_one_pid=$! ;;
    two) mutex_concurrent_two_pid=$! ;;
  esac
done
wait "$mutex_concurrent_one_pid"; mutex_concurrent_one_rc=$?
wait "$mutex_concurrent_two_pid"; mutex_concurrent_two_rc=$?
mutex_concurrent_residue=''
for residue in "$MUTEX_CONCURRENT_TMP/repo/.git/.uberdev-worktree-metadata-locks"/semaphore-v1/*.scope/.mutex \
    "$MUTEX_CONCURRENT_TMP/repo/.git/.uberdev-worktree-metadata-locks"/semaphore-v1/*.scope/.mutex-candidate.*; do
  [ ! -e "$residue" ] && [ ! -L "$residue" ] || mutex_concurrent_residue="$mutex_concurrent_residue ${residue##*/}"
done
if [ "$mutex_concurrent_one_rc" -eq 0 ] && [ "$mutex_concurrent_two_rc" -eq 0 ] \
    && [ -d "$MUTEX_CONCURRENT_TMP/worktree-one" ] \
    && [ -d "$MUTEX_CONCURRENT_TMP/worktree-two" ] \
    && [ ! -e "$MUTEX_CONCURRENT_TMP/state/overlap" ] \
    && [ -z "$mutex_concurrent_residue" ]; then
  echo "  PASS  two worktree additions serialize and leave no mutex candidate residue"
  PASS=$((PASS + 1))
else
  echo "  FAIL  concurrent metadata critical sections overlapped or leaked state"
  echo "        one=$mutex_concurrent_one_rc two=$mutex_concurrent_two_rc overlap=$(test -e "$MUTEX_CONCURRENT_TMP/state/overlap" && printf yes || printf no) residue=$mutex_concurrent_residue"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MUTEX_CONCURRENT_TMP"

echo
echo "== Git metadata mutex rejects polluted candidate token output before publication =="
MUTEX_POLLUTION_TMP="$(mktemp -d)"
if MUTEX_POLLUTION_OUT="$("$MUTEX_OWNER_BASH" -c '
  . "$1"
  scope="$(_uberdev_semaphore_prepare_scope "$2/state" polluted-repository git-worktree-metadata)" || exit 1
  _uberdev_semaphore_mutex_prepare_candidate() {
    candidate="$1"
    printf "%032d\nnoise\n" 0
    printf "%032d\n" 0 >>"$candidate"
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

echo
echo "== Git metadata mutex preserves a bounded owner-capture diagnostic before cleanup =="
MUTEX_DIAGNOSTIC_TMP="$(mktemp -d)"
MUTEX_DIAGNOSTIC_OUT="$("$MUTEX_OWNER_BASH" -c '
  . "$1"
  scope="$(_uberdev_semaphore_prepare_scope "$2/state" diagnostic-repository git-worktree-metadata)" || exit 1
  _uberdev_semaphore_bash_executable() { return 2; }
  _uberdev_semaphore_mutex_acquire "$scope"
  acquire_rc=$?
  remaining=""
  for path in "$scope/.mutex" "$scope"/.mutex-candidate.*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || remaining="$remaining ${path##*/}"
  done
  printf "rc=%s\nremaining=%s\n" "$acquire_rc" "$remaining"
' _ "$DISPATCH_LIB" "$MUTEX_DIAGNOSTIC_TMP" 2>&1)"
if printf '%s\n' "$MUTEX_DIAGNOSTIC_OUT" \
      | grep -Fxq '{"error":"mutex_owner_shell_pid_unavailable","status":"error"}' \
    && printf '%s\n' "$MUTEX_DIAGNOSTIC_OUT" | grep -Fxq 'uberdev semaphore: cannot record mutex owner' \
    && printf '%s\n' "$MUTEX_DIAGNOSTIC_OUT" | grep -Fxq 'rc=2' \
    && printf '%s\n' "$MUTEX_DIAGNOSTIC_OUT" | grep -Fxq 'remaining=' \
    && ! printf '%s\n' "$MUTEX_DIAGNOSTIC_OUT" | grep -Fq 'Traceback'; then
  echo "  PASS  owner-capture failure preserves bounded JSON evidence and cleans its candidate"
  PASS=$((PASS + 1))
else
  echo "  FAIL  owner-capture failure lost diagnostics, leaked state, or exposed a traceback: $MUTEX_DIAGNOSTIC_OUT"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MUTEX_DIAGNOSTIC_TMP"

windows_detach_count="$(grep -Fc 'subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS' "$DISPATCH_LIB")"
posix_setsid_count="$(grep -Fc 'os.setsid()' "$DISPATCH_LIB")"
wrapper_pid_bridge_count="$(grep -Fc 'os.environ["UBERDEV_WRAPPER_PID"]=str(os.getpid())' "$DISPATCH_LIB")"
supervisor_pid_file_count="$(grep -Fc 'UBERDEV_SUPERVISOR_PID_FILE="$STATUS_FILE.pid" nohup' "$DISPATCH_LIB")"
secure_pid_writer_count="$(grep -Fc 'pid_path=os.environ["UBERDEV_SUPERVISOR_PID_FILE"]' "$DISPATCH_LIB")"
absolute_bash_launcher_count="$(grep -Fc 'launch_argv=[bash_path]' "$DISPATCH_LIB")"
# POPULATION COUNT-LOCK, same cause as above: `background` is the only detached
# launcher left since #381 removed the codex one, so all six markers went 2->1
# together. A marker that fails to move with the others means one launcher lost
# its Windows supervisor-PID bridge or its POSIX setsid, which is the whole
# point of locking them as a group.
if [ "$windows_detach_count" -eq 1 ] \
    && [ "$posix_setsid_count" -eq 1 ] \
    && [ "$wrapper_pid_bridge_count" -eq 1 ] \
    && [ "$supervisor_pid_file_count" -eq 1 ] \
    && [ "$secure_pid_writer_count" -eq 1 ] \
    && [ "$absolute_bash_launcher_count" -eq 1 ] \
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
# RENDEZVOUS, NOT A CLOCK. The dispatcher-side observer creates
# $FIXTURE_RUNNING_ACK the instant it has recorded this dispatch's canonical
# "running" snapshot, and only then may this provider finish -- so the window
# in which "running" is observable lasts as long as the observer needs instead
# of one fixed provider sleep. The bound below is a 30s hang guard, not a
# budget: reaching it means no running record ever appeared, which the
# per-dispatch running_status check then reports against the failing issue. It
# is deliberately longer than the 20s observer deadline, so the observer
# verdict decides the row instead of a coin-flip between two deadlines.
[ -n "${FIXTURE_RUNNING_ACK:-}" ] || { printf 'fixture provider: FIXTURE_RUNNING_ACK unset\n' >&2; exit 97; }
ack_waits=0
while [ ! -e "$FIXTURE_RUNNING_ACK" ] && [ "$ack_waits" -lt 1200 ]; do
  sleep 0.025; ack_waits=$((ack_waits + 1))
done
printf 'immediate %s result\n' "$body"
case "$body" in *failed*) exit 29 ;; *) exit 0 ;; esac
SH
chmod +x "$IMMEDIATE_TMP/bin/git" "$IMMEDIATE_TMP/bin/claude"
for runtime_command in env nohup cat sleep rm uname grep stat id ps find basename dirname mkdir; do
  ln -s "$(command -v "$runtime_command")" "$IMMEDIATE_TMP/bin/$runtime_command"
done
# The stub bin stays FIRST so the fixture git/claude and the symlinked
# coreutils above still win, and the host $PATH sits behind it so the dispatch
# below resolves the same `timeout` a real run would (#548). The trailing
# /usr/bin:/bin is kept as the MSYS fallback for Git Bash, where the host $PATH
# may carry those directories in Windows form only — the value is a strict
# superset of the old one, so it cannot regress any runner.
IMMEDIATE_RUNTIME_PATH="$IMMEDIATE_TMP/bin:$PATH:/usr/bin:/bin"
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
    fixture_pids=(); fixture_running_seen=0
    _uberdev_dispatch_wait_owned_session() {
      local observed_status attempts=0 terminal_seen=0
      fixture_pids+=("$1")
      # 800 x 0.025s is a 20s hang detector, not an oracle: the provider is
      # held at the rendezvous below until this loop has seen "running", so the
      # observable window never depends on how fast this process is scheduled.
      while [ "$attempts" -lt 800 ]; do
        observed_status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
        if [[ "$observed_status" == *\"state\":\"running\"* && "$fixture_running_seen" -eq 0 ]]; then
          # Releasing the provider is what makes the running observation a
          # rendezvous instead of a race against a fixed provider sleep.
          fixture_running_seen=1; : > "$FIXTURE_RUNNING_ACK"
        fi
        if [[ "$observed_status" == *\"state\":\"completed\"* \
            && "$observed_status" == *\"exit_code\":0* \
            && -s "$UBERDEV_AGENT_RESULT_FILE" ]]; then
          terminal_seen=1; break
        fi
        if [[ "$observed_status" == *\"state\":\"failed\"* \
            && "$observed_status" =~ \"exit_code\":-?[1-9][0-9]* ]]; then
          terminal_seen=1; break
        fi
        sleep 0.025; attempts=$((attempts + 1))
      done
      if [ "$terminal_seen" -ne 1 ]; then
        failures=$((failures + 1))
        printf "mismatch check=terminal_snapshot_deadline pid=%s\n" "$1"
        return 0
      fi
      # Wait for the detached supervisor to exit after publishing its canonical
      # terminal snapshot. Returning 1 is what SELECTS the exact-handle
      # immediate-terminal validation path in the dispatcher, so quietly
      # returning 0 on expiry would swap the branch under test instead of
      # failing. 800 x 0.025s is a 20s hang detector; expiry is reported by
      # name and still returns 1, so the row reds loudly rather than diverging.
      attempts=0
      while kill -0 "$1" 2>/dev/null && [ "$attempts" -lt 800 ]; do
        sleep 0.025; attempts=$((attempts + 1))
      done
      if kill -0 "$1" 2>/dev/null; then
        failures=$((failures + 1))
        printf "mismatch check=supervisor_exit_deadline pid=%s\n" "$1"
      fi
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
      # Per-dispatch rendezvous handle: the provider for THIS issue blocks
      # until the observer above has recorded the running snapshot of THIS
      # issue. (No apostrophes here: the whole block is a single-quoted script.)
      FIXTURE_RUNNING_ACK="$UBERDEV_TMPDIR/running-ack-$issue"
      export FIXTURE_RUNNING_ACK
      rm -f "$FIXTURE_RUNNING_ACK"
      fixture_running_seen=0
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
      # PER-DISPATCH, not a tail count: the diagnostic names the issue whose
      # running snapshot never appeared, and it is printed before the next
      # dispatch can bury it. The provider is held at the rendezvous until this
      # flips, so a 0 here means the canonical running record was never
      # published -- never that the observer was scheduled too late.
      [ "$fixture_running_seen" -eq 1 ] || record_failure running_status
    done
    for fixture_pid in "${fixture_pids[@]}"; do
      wait "$fixture_pid" 2>/dev/null || true
    done
    printf "failures=%s\n" "$failures"
  ' _ "$DISPATCH_LIB"
)"
if [[ "$IMMEDIATE_OUT" == *'failures=0'* ]]; then
  echo "  PASS  background captures provider stdout into a private canonical result and preserves exact immediate terminal handles"; PASS=$((PASS + 1))
else
  echo "  FAIL  background captures provider stdout into a private canonical result and preserves exact immediate terminal handles"
  echo "        $IMMEDIATE_OUT"; FAIL=$((FAIL + 1))
fi
# #548 — the binding above is a fixture INPUT, not a constant. Narrowing it back
# silently moves the dispatch onto the UNBOUNDED preflight arm on any host that
# ships no /usr/bin/timeout, and every existing verdict in this file is
# byte-identical on both arms. This row is what makes the widening enforced
# rather than merely present, and it reds on ubuntu, Windows and macOS alike.
#
# The haystack is padded with a trailing ':' so the host $PATH counts whether it
# is followed by a segment (the form below) or is LAST (the #521 donor form at
# child-dispatch.test.sh:1043, and :179 in this file). An unpadded *":$PATH:"*
# would red that shape for no reason.
# BOUNDARY: a degenerate host whose entire $PATH is one of the pinned segments
# is not distinguished here; the arm row below covers the real property there.
IMMEDIATE_RUNTIME_PATH_STUB_OK=0
IMMEDIATE_RUNTIME_PATH_TAIL_OK=0
case "$IMMEDIATE_RUNTIME_PATH" in "$IMMEDIATE_TMP/bin:"*) IMMEDIATE_RUNTIME_PATH_STUB_OK=1 ;; esac
case "$IMMEDIATE_RUNTIME_PATH:" in *":$PATH:"*)           IMMEDIATE_RUNTIME_PATH_TAIL_OK=1 ;; esac
if [ "$IMMEDIATE_RUNTIME_PATH_STUB_OK" -eq 1 ] && [ "$IMMEDIATE_RUNTIME_PATH_TAIL_OK" -eq 1 ]; then
  echo "  PASS  immediate runtime PATH keeps the stub bin first and the host PATH behind it"
  PASS=$((PASS + 1))
else
  echo "  FAIL  immediate runtime PATH keeps the stub bin first and the host PATH behind it: $IMMEDIATE_RUNTIME_PATH"
  FAIL=$((FAIL + 1))
fi
# #548 — assert WHICH preflight arm the dispatch above took, not merely that one
# was taken. `_uberdev_dispatch_preflight_timeout_bin` returns 0 SILENTLY on the
# happy path and emits no audit record naming the bound, so the resolved binary
# is the only observable — every verdict above is byte-identical on the bounded
# and the unbounded arm, which is exactly why the narrow literal survived here
# for so long. The row above proves the PATH is wide; this one proves the width
# reaches production code.
#
# Driven as a unit under the SAME variable the dispatch ran with, so the row
# cannot drift onto a PATH nobody used — that drift IS this issue's defect
# class, and committing it inside the fix would be the worst outcome available.
# Precedent: child-dispatch.test.sh:1074-1092 (#521) and T15 in
# dispatch-child-worktree-teardown.test.sh, which drives this same resolver.
#
# TIMEOUT_BIN is neither set NOR unset here. lib/dispatch.sh tries
# "${TIMEOUT_BIN:-}" ahead of every PATH name, and the dispatch above inherits
# that variable from the ambient environment; the `unset TIMEOUT_BIN` lines in
# this file belong to the #246 D-perm/D-skip subshells and do not reach here.
# Touching it either way would assert about an environment the dispatch never
# had.
#
# No pipe, by construction: command substitution and `case` only, so this file's
# epipe-guard.test.sh exposure is unchanged and it still needs no `pipefail`.
# The verdict goes through the PASS/FAIL counters because the file is `set -u`
# only — a bare `[ … ]` or `*) false ;;` here would be a no-op.
IMMEDIATE_RUNTIME_PATH_TIMEOUT_BIN="$(
  PATH="$IMMEDIATE_RUNTIME_PATH" \
    /bin/bash -c 'set -u; . "$1"; _uberdev_dispatch_preflight_timeout_bin' _ "$DISPATCH_LIB"
)"
echo "        immediate preflight resolved timeout bin = ${IMMEDIATE_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
# Absolute, never a bare name: a bare name in command position is answered by
# the shell's function table first (T15's finding). The drive-letter alternation
# is mandatory — Git Bash is in the CI matrix. Absoluteness subsumes
# non-emptiness: the empty string matches neither branch.
IMMEDIATE_RUNTIME_PATH_ARM_OK=0
case "$IMMEDIATE_RUNTIME_PATH_TIMEOUT_BIN" in
  /*|[A-Za-z]:/*) [ -x "$IMMEDIATE_RUNTIME_PATH_TIMEOUT_BIN" ] && IMMEDIATE_RUNTIME_PATH_ARM_OK=1 ;;
esac
if [ "$IMMEDIATE_RUNTIME_PATH_ARM_OK" -eq 1 ]; then
  echo "  PASS  immediate dispatch took the BOUNDED preflight arm (absolute, executable timeout bin)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  immediate dispatch took the UNBOUNDED preflight arm — resolved timeout bin: ${IMMEDIATE_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
  FAIL=$((FAIL + 1))
fi
rm -rf "$IMMEDIATE_TMP"

echo
echo "== Owned-session probe is decided by session identity, not by elapsed time =="
# WHY THIS ROW EXISTS. The delayed row below has to accept the dispatcher
# fail-closed refusal, because _uberdev_dispatch_wait_owned_session polls a
# FIXED 40 attempts for the detached supervisor to reach setsid() and a starved
# runner can exhaust that window with the child perfectly healthy. Accepting
# the refusal there would be vacuous if nothing pinned the acceptance arm, so
# this row drives the probe directly against two children whose session
# identity the TEST controls. Neither verdict can move with machine speed: the
# leader has ALREADY called setsid() before we look (attempt 1 decides it), and
# a child that never calls setsid() can never become a session leader no matter
# how long the probe runs.
OWNED_TMP="$(mktemp -d)"
cat > "$OWNED_TMP/session-child.py" <<'PY'
import os, sys, time
target, mode = sys.argv[1], sys.argv[2]
# setsid is POSIX-only. On Windows run_manifest deliberately reports
# pid|pid|pid for every live process (there are no sessions there), which is
# what the platform-split expectation below accounts for.
if mode == "leader" and hasattr(os, "setsid"):
    os.setsid()
# Published atomically, and it is the NATIVE pid on purpose: under Git Bash the
# shell $! is an MSYS pid the identity probe cannot resolve, which is the same
# reason the production wrapper bridges its supervisor pid through a file.
with open(target + ".tmp", "w") as handle:
    handle.write(str(os.getpid()))
os.replace(target + ".tmp", target)
time.sleep(60)
PY
OWNED_OUT="$(
  /bin/bash -c '
    . "$1" || { printf "probe=source-failed\n"; exit 0; }
    _uberdev_dispatch_resolve_python || { printf "probe=no-python\n"; exit 0; }
    launcher=( "$_UBERDEV_PYTHON_EXE" )
    [ -z "$_UBERDEV_PYTHON_PREFIX" ] || launcher+=( "$_UBERDEV_PYTHON_PREFIX" )
    leader_file="$2/leader.pid"; stray_file="$2/stray.pid"
    "${launcher[@]}" -I -B "$3" "$leader_file" leader & leader_job=$!
    "${launcher[@]}" -I -B "$3" "$stray_file" stray & stray_job=$!
    # 800 x 0.025s is a 20s hang detector on the handshake, not a budget: the
    # children publish and then sleep, so the files do not expire.
    waits=0
    while { [ ! -s "$leader_file" ] || [ ! -s "$stray_file" ]; } && [ "$waits" -lt 800 ]; do
      sleep 0.025; waits=$((waits + 1))
    done
    leader_pid="$(cat "$leader_file" 2>/dev/null)"
    stray_pid="$(cat "$stray_file" 2>/dev/null)"
    if [ -z "$leader_pid" ] || [ -z "$stray_pid" ]; then
      kill "$leader_job" "$stray_job" 2>/dev/null || true
      printf "probe=children-never-published\nleader_pid=%s\nstray_pid=%s\n" "$leader_pid" "$stray_pid"
      exit 0
    fi
    _uberdev_dispatch_wait_owned_session "$leader_pid"; leader_rc=$?
    _uberdev_dispatch_wait_owned_session "$stray_pid"; stray_rc=$?
    kill "$leader_job" "$stray_job" 2>/dev/null || true
    wait "$leader_job" 2>/dev/null || true
    wait "$stray_job" 2>/dev/null || true
    printf "probe=ran\nleader_rc=%s\nstray_rc=%s\n" "$leader_rc" "$stray_rc"
  ' _ "$DISPATCH_LIB" "$OWNED_TMP" "$OWNED_TMP/session-child.py"
)"
owned_probe="$(printf '%s\n' "$OWNED_OUT" | sed -n 's/^probe=//p')"
owned_leader_rc="$(printf '%s\n' "$OWNED_OUT" | sed -n 's/^leader_rc=//p')"
owned_stray_rc="$(printf '%s\n' "$OWNED_OUT" | sed -n 's/^stray_rc=//p')"
case "$(uname -s)" in
  # Windows has no POSIX sessions, so the documented contract there is that a
  # live pid IS its own session and must be accepted; the refusal arm is a
  # POSIX statement and is asserted as such.
  MINGW*|MSYS*|CYGWIN*) owned_stray_expected=0 ;;
  *) owned_stray_expected=1 ;;
esac
if [ "$owned_probe" = ran ] \
    && [ "$owned_leader_rc" = 0 ] \
    && [ "$owned_stray_rc" = "$owned_stray_expected" ]; then
  echo "  PASS  owned-session probe accepts an established session leader and applies the platform session contract to a child that never became one"
  PASS=$((PASS + 1))
else
  echo "  FAIL  owned-session probe accepts an established session leader and applies the platform session contract to a child that never became one"
  echo "        expected probe=ran leader_rc=0 stray_rc=$owned_stray_expected; got: $OWNED_OUT"
  FAIL=$((FAIL + 1))
fi
rm -rf "$OWNED_TMP"

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
# RENDEZVOUS, NOT A CLOCK. What makes this dispatch "delayed" is that the
# provider is still running while the parent reads the canonical running
# snapshot -- so the parent, not a fixed sleep, decides when this exits. The
# bound is a 30s hang guard deliberately longer than the parent poll deadline,
# so a missing running record surfaces as the parent verdict, not as a
# coin-flip between the two deadlines.
[ -n "${FIXTURE_RUNNING_ACK:-}" ] || { printf 'fixture provider: FIXTURE_RUNNING_ACK unset\n' >&2; exit 97; }
ack_waits=0
while [ ! -e "$FIXTURE_RUNNING_ACK" ] && [ "$ack_waits" -lt 1200 ]; do
  sleep 0.025; ack_waits=$((ack_waits + 1))
done
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
# Stub bin first, host $PATH behind it, /usr/bin:/bin kept as the Git Bash MSYS
# fallback — see the IMMEDIATE_RUNTIME_PATH binding above (#548).
DELAYED_RUNTIME_PATH="$DELAYED_TMP/bin:$PATH:/usr/bin:/bin"
printf 'delayed' > "$DELAYED_TMP/prompt.txt"
# The receipt verifier lives in its own file so the dispatch fixture and the
# contract checks each stay readable. It prints exactly one verdict word —
# `ok`, `race`, or `bad:<reason>` — and its exit status is folded into the
# caller below, so a verifier that crashes reds the row rather than passing it.
cat > "$DELAYED_TMP/verify-receipts.py" <<'PY'
import json,sys
raw,issue=sys.argv[1],int(sys.argv[2])
def bad(reason):
    print("bad:"+reason); raise SystemExit(0)
try: lines=dict(line.split('=',1) for line in raw.splitlines())
except ValueError: bad("unparsable receipt block %r"%(raw,))
try: terminal=json.loads(lines.get('terminal',''))
except Exception: bad("terminal receipt is not JSON: %r"%(lines.get('terminal'),))
supervisor=terminal.get('pid') if isinstance(terminal,dict) else None
if not (isinstance(supervisor,str) and supervisor.isdigit()):
    bad("terminal receipt names no supervisor pid: %r"%(lines.get('terminal'),))
if terminal!={'issue':issue,'tier':'small','backend':'background','state':'completed','exit_code':0,'pid':supervisor}:
    bad("terminal receipt off contract: %r"%(lines.get('terminal'),))
try: running=json.loads(lines.get('running',''))
except Exception: bad("running receipt is not JSON: %r"%(lines.get('running'),))
if running!={'issue':issue,'tier':'small','backend':'background','state':'running','exit_code':None,'pid':supervisor}:
    bad("running receipt off contract or names a second pid: %r"%(lines.get('running'),))
if lines.get('result')!='delayed background result':
    bad("result payload: %r"%(lines.get('result'),))
rc,handle=lines.get('rc'),lines.get('pid')
if rc=='0':
    if handle!=supervisor:
        bad("dispatch returned 0 with handle %r while both receipts name %r"%(handle,supervisor))
    print("ok"); raise SystemExit(0)
if rc=='1' and handle=='':
    print("race"); raise SystemExit(0)
bad("dispatch rc=%r handle=%r is neither the owned-session success nor the fail-closed refusal"%(rc,handle))
PY
run_delayed_dispatch() {
  (
    cd "$DELAYED_TMP/repo" || exit 1
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
      issue="$4"
      # Rendezvous handle: the provider is held until this shell has recorded
      # the canonical running snapshot, so the running window lasts as long as
      # this shell needs instead of one fixed provider sleep.
      FIXTURE_RUNNING_ACK="$UBERDEV_TMPDIR/running-ack-$issue"
      export FIXTURE_RUNNING_ACK
      rm -f "$FIXTURE_RUNNING_ACK"
      _uberdev_dispatch_background "$issue" small "$2"
      rc=$?; pid="${DISPATCH_ID:-}"; status_file="$UBERDEV_TMPDIR/solve-bg-status-$issue.json"
      # 800 x 0.025s is a 20s hang detector, not a budget.
      attempts=0; running=""
      while [ "$attempts" -lt 800 ]; do
        running="$(cat "$status_file" 2>/dev/null)"
        [[ "$running" == *\"state\":\"running\"* ]] && break
        sleep 0.025; attempts=$((attempts + 1))
      done
      # Released unconditionally: on expiry the provider must still finish so
      # the receipts below report what really happened instead of hanging.
      : > "$FIXTURE_RUNNING_ACK"
      attempts=0; terminal="$running"
      while [ "$attempts" -lt 800 ]; do
        terminal="$(cat "$status_file" 2>/dev/null)"
        [[ "$terminal" == *\"state\":\"completed\"* ]] && break
        sleep 0.025; attempts=$((attempts + 1))
      done
      printf "rc=%s\npid=%s\nresolved=%s\nrunning=%s\nterminal=%s\nresult=%s\n" \
        "$rc" "$pid" "$resolved_python" "$running" "$terminal" "$(cat "$UBERDEV_TMPDIR/solve-bg-result-$issue.md" 2>/dev/null)"
    ' _ "$DISPATCH_LIB" "$DELAYED_TMP/prompt.txt" "$DELAYED_RUNTIME_PATH" "$1"
  )
}
delayed_python_expected="$(cd "$DELAYED_TMP/bin" && pwd -P)/py"
if grep -Fq "assert lines['resolved']""==sys.argv[3]" "$0"; then
  echo "  FAIL  delayed fixture compares its POSIX launcher path before native-Python argv conversion"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  delayed fixture compares its POSIX launcher path before native-Python argv conversion"
  PASS=$((PASS + 1))
fi
# WHAT THIS ROW MAY NOT ASSERT, AND WHY. The dispatcher refuses to hand back a
# handle whose session it could not prove it owns:
# _uberdev_dispatch_wait_owned_session polls a FIXED 40 attempts for the
# detached supervisor to reach os.setsid(), and on expiry
# _uberdev_dispatch_accept_immediate_terminal rejects the still-live wrapper,
# clears DISPATCH_ID and returns 1 — with the child running on perfectly. That
# refusal is correct fail-closed behaviour reached by machine speed alone, so a
# flat "rc must be 0" here is an assertion about the runner, not about the code
# (measured budget on a warm host: ~5s; a 5s startup handicap flips it every
# time). The invariant that is NOT speed-dependent is the one this row is named
# for: whatever handle the dispatcher hands back must agree with the receipts
# the child published. So exactly two shapes are legal — the owned-session
# success (rc=0 with the handle equal to the pid in BOTH receipts) and the
# fail-closed refusal (rc=1 with no handle at all) — and everything else, a
# wrong pid, a second pid across the two receipts, an off-contract snapshot, a
# wrong payload, or any other rc/handle pair, reds on the spot. The acceptance
# arm is NOT left unpinned: the owned-session probe row above drives it
# directly and deterministically. The refusal is retried once so the strong
# arm decides the row whenever the runner lets it, and is announced when taken.
DELAYED_MAX_ATTEMPTS=2
delayed_verdict=""
delayed_report=""
delayed_try=0
while [ "$delayed_try" -lt "$DELAYED_MAX_ATTEMPTS" ]; do
  delayed_issue=$((90 + delayed_try))
  delayed_try=$((delayed_try + 1))
  delayed_report="$(run_delayed_dispatch "$delayed_issue")"
  delayed_python_resolved="$(printf '%s\n' "$delayed_report" | sed -n 's/^resolved=//p')"
  if [ "$delayed_python_resolved" != "$delayed_python_expected" ]; then
    delayed_verdict="bad:python launcher resolved=$delayed_python_resolved expected=$delayed_python_expected"
  elif ! delayed_verdict="$(python3 -I -B "$DELAYED_TMP/verify-receipts.py" "$delayed_report" "$delayed_issue")"; then
    delayed_verdict="bad:receipt verifier crashed"
  fi
  [ "$delayed_verdict" = race ] || break
  printf '        note: issue %s hit the fail-closed owned-session refusal with intact child receipts\n' "$delayed_issue"
done
if [ "$delayed_verdict" = ok ] || [ "$delayed_verdict" = race ]; then
  echo "  PASS  delayed background running and terminal receipts agree with the dispatch handle [$delayed_verdict]"
  PASS=$((PASS + 1))
else
  echo "  FAIL  delayed background running and terminal receipts agree with the dispatch handle after $delayed_try attempt(s): $delayed_verdict"
  echo "        $delayed_report"; FAIL=$((FAIL + 1))
fi
# #548 — the binding above is a fixture INPUT, not a constant. Narrowing it back
# silently moves the dispatch onto the UNBOUNDED preflight arm on any host that
# ships no /usr/bin/timeout, and every existing verdict in this file is
# byte-identical on both arms. This row is what makes the widening enforced
# rather than merely present, and it reds on ubuntu, Windows and macOS alike.
#
# The haystack is padded with a trailing ':' so the host $PATH counts whether it
# is followed by a segment (the form below) or is LAST (the #521 donor form at
# child-dispatch.test.sh:1043, and :179 in this file). An unpadded *":$PATH:"*
# would red that shape for no reason.
# BOUNDARY: a degenerate host whose entire $PATH is one of the pinned segments
# is not distinguished here; the arm row below covers the real property there.
DELAYED_RUNTIME_PATH_STUB_OK=0
DELAYED_RUNTIME_PATH_TAIL_OK=0
case "$DELAYED_RUNTIME_PATH" in "$DELAYED_TMP/bin:"*) DELAYED_RUNTIME_PATH_STUB_OK=1 ;; esac
case "$DELAYED_RUNTIME_PATH:" in *":$PATH:"*)         DELAYED_RUNTIME_PATH_TAIL_OK=1 ;; esac
if [ "$DELAYED_RUNTIME_PATH_STUB_OK" -eq 1 ] && [ "$DELAYED_RUNTIME_PATH_TAIL_OK" -eq 1 ]; then
  echo "  PASS  delayed runtime PATH keeps the stub bin first and the host PATH behind it"
  PASS=$((PASS + 1))
else
  echo "  FAIL  delayed runtime PATH keeps the stub bin first and the host PATH behind it: $DELAYED_RUNTIME_PATH"
  FAIL=$((FAIL + 1))
fi
# #548 — assert WHICH preflight arm the dispatch above took, not merely that one
# was taken; same reasoning as the immediate site's arm row, and the same
# constraints (unit-driven under the one shared variable, TIMEOUT_BIN untouched,
# no pipe, counter-scored verdict). See that row's comment for the full record.
DELAYED_RUNTIME_PATH_TIMEOUT_BIN="$(
  PATH="$DELAYED_RUNTIME_PATH" \
    /bin/bash -c 'set -u; . "$1"; _uberdev_dispatch_preflight_timeout_bin' _ "$DISPATCH_LIB"
)"
echo "        delayed preflight resolved timeout bin = ${DELAYED_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
# Absolute, never a bare name: a bare name in command position is answered by
# the shell's function table first (T15's finding). The drive-letter alternation
# is mandatory — Git Bash is in the CI matrix. Absoluteness subsumes
# non-emptiness: the empty string matches neither branch.
DELAYED_RUNTIME_PATH_ARM_OK=0
case "$DELAYED_RUNTIME_PATH_TIMEOUT_BIN" in
  /*|[A-Za-z]:/*) [ -x "$DELAYED_RUNTIME_PATH_TIMEOUT_BIN" ] && DELAYED_RUNTIME_PATH_ARM_OK=1 ;;
esac
if [ "$DELAYED_RUNTIME_PATH_ARM_OK" -eq 1 ]; then
  echo "  PASS  delayed dispatch took the BOUNDED preflight arm (absolute, executable timeout bin)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  delayed dispatch took the UNBOUNDED preflight arm — resolved timeout bin: ${DELAYED_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
  FAIL=$((FAIL + 1))
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
