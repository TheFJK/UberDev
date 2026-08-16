#!/usr/bin/env bash
# Shape-check for the `wezterm` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_wezterm). Verifies `wezterm cli spawn` with
# --domain-name, the mux-preflight list-clients poll (ALSO pinned to the
# `uberdev` domain — B1 fix), the .wezterm.lua managed-block with
# exit_behavior Hold, and the ABSENCE of `claude --bg` from the wezterm
# arm. RFC 0004 §3.6 / §4.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# bash 3.2 (the only bash on macos-latest) exits ZERO from a `set -u` abort in a
# script carrying an EXIT trap, so this fixture could die partway and still let
# the job's && chain go green. The floor is a completion flag no abort path can
# forge — see convention 9 in plugins/uberdev/docs/testing.md (#551).
. "$REPO_ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }
trap '_floor_rc=$?; uberdev_test_exit_floor dispatch-wezterm "$_floor_rc"' EXIT
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

echo "== Positive: wezterm cli spawn mechanism =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_wezterm\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_wezterm function"
assert_grep "$DISPATCH_LIB" \
  'wezterm cli spawn' \
  "wezterm backend spawns each agent via wezterm cli spawn"
assert_grep "$DISPATCH_LIB" \
  '\-\-domain-name uberdev' \
  "wezterm spawn pins the named uberdev domain"
assert_grep "$DISPATCH_LIB" \
  '\-\-cwd ' \
  "wezterm spawn --cwd's the pane into the worktree"
assert_grep "$DISPATCH_LIB" \
  'claude -p' \
  "wezterm backend runs foreground headless claude -p in the pane"
# B1 fix: the mux-pinning mechanism is `--domain-name uberdev` on every
# `wezterm cli` call (the probe arm + the retry list-clients call inside
# _uberdev_dispatch_wezterm_available + the wezterm cli spawn). Require
# >= 3 `--domain-name uberdev` occurrences to lock in all three call sites;
# a regression that drops the flag from any one of them would re-introduce
# the scatter-across-stray-WezTerm bug. Counting bare `--domain-name uberdev`
# (rather than `wezterm cli --domain-name uberdev`) is robust to the spawn
# call's multi-line backslash continuation that puts the flag on its own line.
DOMAIN_NAME_COUNT="$(grep -cE -- '--domain-name uberdev' "$DISPATCH_LIB" 2>/dev/null || echo "0")"
if [[ "$DOMAIN_NAME_COUNT" -ge 3 ]]; then
  echo "  PASS  every wezterm cli call pins --domain-name uberdev (count=$DOMAIN_NAME_COUNT, expected >= 3)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  expected >= 3 \`--domain-name uberdev\` occurrences (probe + retry list-clients + spawn); count=$DOMAIN_NAME_COUNT"
  FAIL=$((FAIL + 1))
fi
# Tombstone: the v0.29.0 no-op `export WEZTERM_UNIX_SOCKET=…` form must NOT
# reappear. The mux pin is `--domain-name uberdev`; the export was a
# tautology (`${WEZTERM_UNIX_SOCKET:-}` → its current value or empty) that
# misled readers into thinking the socket env var was load-bearing.
assert_grep_not "$DISPATCH_LIB" \
  'export WEZTERM_UNIX_SOCKET' \
  "no tautological export WEZTERM_UNIX_SOCKET=… (B1 regression guard — real pin is --domain-name uberdev)"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_git_worktree_add' \
  "wezterm backend serializes its own worktree add (no native --worktree)"
WT_WORKTREE_BODY="$(awk '/^_uberdev_dispatch_wezterm\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s\n' "$WT_WORKTREE_BODY" | grep -Fq 'MSYS_NO_PATHCONV=1 git worktree add'; then
  echo "  FAIL  wezterm backend bypasses the repository Git metadata mutex"; FAIL=$((FAIL + 1))
else
  echo "  PASS  wezterm backend has no direct worktree-add bypass"; PASS=$((PASS + 1))
fi

echo "== Repository-root worktree placement from a subdirectory =="
WEZ_ROOT_TMP="$(mktemp -d)"
git init -q "$WEZ_ROOT_TMP/repo"
mkdir -p "$WEZ_ROOT_TMP/repo/nested/deep" "$WEZ_ROOT_TMP/runtime" \
  "$WEZ_ROOT_TMP/home" "$WEZ_ROOT_TMP/outside"
printf 'root placement\n' >"$WEZ_ROOT_TMP/prompt.txt"
(
  cd "$WEZ_ROOT_TMP/repo/nested/deep" || exit 1
  HOME="$WEZ_ROOT_TMP/home" UBERDEV_TMPDIR="$WEZ_ROOT_TMP/runtime" CAPTURE="$WEZ_ROOT_TMP/capture" \
    /bin/bash -c '
      . "$1"
      _uberdev_dispatch_wezterm_config() { return 0; }
      _uberdev_dispatch_git_worktree_add() {
        printf "repo=%s\ntarget=%s\n" "$1" "$2" >"$CAPTURE"
        return 77
      }
      _uberdev_dispatch_wezterm 335 medium "$2" >/dev/null 2>&1
      [ "$?" -eq 1 ]
    ' _ "$DISPATCH_LIB" "$WEZ_ROOT_TMP/prompt.txt"
)
WEZ_EXPECTED_ROOT="$(cd "$WEZ_ROOT_TMP/repo" && pwd -P)"
if grep -Fqx "repo=$WEZ_EXPECTED_ROOT" "$WEZ_ROOT_TMP/capture" 2>/dev/null \
    && grep -Fqx "target=$WEZ_EXPECTED_ROOT/.claude/worktrees/solve-issue-335" \
      "$WEZ_ROOT_TMP/capture"; then
  echo "  PASS  WezTerm resolves repository root and passes an absolute worktree target"
  PASS=$((PASS + 1))
else
  echo "  FAIL  WezTerm subdirectory placement: $(tr '\n' ' ' <"$WEZ_ROOT_TMP/capture" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
(
  cd "$WEZ_ROOT_TMP/outside" || exit 1
  HOME="$WEZ_ROOT_TMP/home" UBERDEV_TMPDIR="$WEZ_ROOT_TMP/runtime" \
    CAPTURE="$WEZ_ROOT_TMP/outside-called" /bin/bash -c '
      . "$1"
      _uberdev_dispatch_wezterm_config() { return 0; }
      _uberdev_dispatch_git_worktree_add() { : >"$CAPTURE"; return 0; }
      _uberdev_dispatch_wezterm 336 medium "$2" >/dev/null 2>&1
      [ "$?" -eq 1 ] && [ ! -e "$CAPTURE" ]
    ' _ "$DISPATCH_LIB" "$WEZ_ROOT_TMP/prompt.txt"
)
if [ "$?" -eq 0 ]; then
  echo "  PASS  WezTerm fails closed outside a Git worktree before mutation"
  PASS=$((PASS + 1))
else
  echo "  FAIL  WezTerm attempted worktree mutation outside a Git repository"
  FAIL=$((FAIL + 1))
fi
rm -rf "$WEZ_ROOT_TMP"

echo "== Positive: mux preflight + .wezterm.lua managed block =="
assert_grep "$DISPATCH_LIB" \
  'wezterm-mux-server' \
  "wezterm preflight starts wezterm-mux-server before the first spawn"
assert_grep "$DISPATCH_LIB" \
  'list-clients' \
  "wezterm preflight polls wezterm cli list-clients (cold-start race guard)"
assert_grep "$DISPATCH_LIB" \
  '\.wezterm\.lua' \
  "wezterm backend manages a .wezterm.lua config"
assert_grep "$DISPATCH_LIB" \
  'exit_behavior.*Hold' \
  ".wezterm.lua managed block sets exit_behavior = Hold (pane stays visible)"
assert_grep "$DISPATCH_LIB" \
  'unix_domains' \
  ".wezterm.lua managed block defines the uberdev unix_domains entry"
assert_grep "$DISPATCH_LIB" \
  'managed|BEGIN uberdev|END uberdev' \
  ".wezterm.lua block is a fenced managed region (merge, never overwrite)"
assert_grep "$DISPATCH_LIB" \
  '"backend":"wezterm"' \
  "agent_dispatched payload carries backend=wezterm"
assert_grep "$DISPATCH_LIB" \
  '"pane_id":' \
  "agent_dispatched payload carries the spawned pane_id"

echo "== #246 D-perm/D-skip: wezterm backend inherits paired PERM_FLAG from shared resolver =="
# The PR body and CHANGELOG claim "all three dispatch backends inherit the change
# because they all expand \"\${PERM_FLAG[@]}\" from the same resolver." That is
# structurally true, but the only functional coverage used to live in the
# now-retired detached-session fixture. A future regression where
# someone hand-edits `_uberdev_dispatch_wezterm` to strip / hard-code PERM_FLAG
# would have red-CI'd only that one file. The D-perm / D-skip subshell cases
# are mirrored here to lock the "wezterm backend inherits" claim against that
# regression class. The assertion shape is IDENTICAL across backends because
# PERM_FLAG is set by the SHARED `uberdev_dispatch_resolve_env` (not by per-backend
# code); this test verifies that resolver is reachable from the wezterm backend's
# code path.
TALLY_FILE="$(mktemp)"

echo
echo "== #246 D-perm: AUTO_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions (wezterm backend inherits from shared resolver) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG SKIP_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; AUTO_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-perm (wezterm) AUTO_PERMISSIONS=1 -> PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-perm (wezterm) PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #246 D-skip: SKIP_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions (wezterm backend inherits from shared resolver) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG AUTO_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; SKIP_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-skip (wezterm) SKIP_PERMISSIONS=1 -> PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-skip (wezterm) PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

rm -f "$TALLY_FILE"

echo
echo "== Process-separated WezTerm pane retains portable Python after PATH narrowing =="
# WHICH "PATH narrowing" THE TITLE MEANS. It is the IN-PANE `PATH=../bin`
# python-resolution step inside the two `bash -c` bodies below — the pane is
# handed a relative, one-entry PATH and must still resolve a portable Python.
# It is NOT the WEZ_RUNTIME_PATH binding, which deliberately keeps the host
# $PATH behind the stub bin so the dispatch resolves the same `timeout` a real
# run would. Do not "restore" that binding to a stub-dir-plus-pinned-system-dirs
# literal on the strength of this header: dropping the host $PATH is the #548
# defect, and the row above the teardown below reds when it comes back.
WEZ_RUNTIME_TMP="$(mktemp -d)"
mkdir -p "$WEZ_RUNTIME_TMP/bin" "$WEZ_RUNTIME_TMP/repo/.git" "$WEZ_RUNTIME_TMP/tmp" "$WEZ_RUNTIME_TMP/home"
if REAL_PYTHON_EXE="$(command -v python3 2>/dev/null)" && [ -n "$REAL_PYTHON_EXE" ]; then
  REAL_PYTHON_PREFIX=''
elif REAL_PYTHON_EXE="$(command -v python 2>/dev/null)" && [ -n "$REAL_PYTHON_EXE" ]; then
  REAL_PYTHON_PREFIX=''
elif REAL_PYTHON_EXE="$(command -v py 2>/dev/null)" && [ -n "$REAL_PYTHON_EXE" ]; then
  REAL_PYTHON_PREFIX='-3'
else
  echo "error: Python 3 is required for dispatch-wezterm fixtures" >&2
  exit 1
fi
REAL_CYGPATH_EXE="$(command -v cygpath 2>/dev/null || true)"
cat > "$WEZ_RUNTIME_TMP/bin/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
if [ -n "$REAL_PYTHON_PREFIX" ]; then
  exec "$REAL_PYTHON_EXE" "$REAL_PYTHON_PREFIX" "\$@"
else
  exec "$REAL_PYTHON_EXE" "\$@"
fi
SH
cat > "$WEZ_RUNTIME_TMP/bin/cygpath" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 2 ] || exit 97
case "$1" in
  -m) printf '%s\n' "${2##*/}" >> "$WEZ_CYGPATH_CAPTURE" ;;
  -u) ;;
  *) exit 97 ;;
esac
if [ -n "${WEZ_REAL_CYGPATH:-}" ]; then exec "$WEZ_REAL_CYGPATH" "$@"; fi
printf '%s\n' "$2"
SH
cat > "$WEZ_RUNTIME_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then pwd -P; exit 0; fi
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --git-common-dir ]; then printf '.git\n'; exit 0; fi
if [ "$1" = worktree ] && [ "$2" = add ]; then mkdir -p "$3"; exit 0; fi
exit 1
SH
cat > "$WEZ_RUNTIME_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${MSYS2_ARG_CONV_EXCL+x}" = x ]; then
  printf 'leaked-msys-argv-conversion-control\n' > "$WEZ_PROVIDER_CAPTURE"
  exit 100
fi
if /usr/bin/env | /usr/bin/grep -Eq '^BASH_FUNC_(python3|run_python)%%='; then
  printf 'exported-python-bridge\n' > "$WEZ_PROVIDER_CAPTURE"
  exit 98
fi
printf 'pane-cwd-observed\n' > .wezterm-pane-cwd-observed
i=0
while [ "$i" -lt 200 ]; do
  if /usr/bin/grep -Fq '"state":"running"' "$WEZ_STATUS_FILE" 2>/dev/null; then
    printf 'running-observed-no-export\n' > "$WEZ_PROVIDER_CAPTURE"
    exit 0
  fi
  sleep 0.01
  i=$((i + 1))
done
printf 'running-not-observed\n' > "$WEZ_PROVIDER_CAPTURE"
exit 99
SH
cat > "$WEZ_RUNTIME_TMP/bin/wezterm" <<'SH'
#!/usr/bin/env bash
[ "$1" = cli ] && [ "$2" = spawn ] || exit 95
[ "${MSYS2_ARG_CONV_EXCL:-}" = '*' ] || exit 94
pane_cwd=''
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  if [ "$1" = --cwd ]; then pane_cwd="$2"; shift 2; else shift; fi
done
[ "${1:-}" = -- ] || exit 96
shift
# `MSYS2_ARG_CONV_EXCL=*` is a caller-side control for the native wezterm CLI,
# not pane state. A real mux process does not leak that transient assignment
# into its pane; mirror that boundary before the Git Bash pane invokes native
# Python so POSIX path argv is translated normally on Windows.
( unset MSYS2_ARG_CONV_EXCL; cd "$pane_cwd" && "$@" ) || exit $?
printf '731\n'
exit 0
SH
chmod +x "$WEZ_RUNTIME_TMP/bin/py" "$WEZ_RUNTIME_TMP/bin/cygpath" "$WEZ_RUNTIME_TMP/bin/git" "$WEZ_RUNTIME_TMP/bin/claude" "$WEZ_RUNTIME_TMP/bin/wezterm"
WEZ_CYGPATH_U_PROBE="$(WEZ_REAL_CYGPATH='' "$WEZ_RUNTIME_TMP/bin/cygpath" -u 'C:/fixture/path')"
for runtime_command in env cat sleep rm uname grep stat id awk mv tee mkdir basename dirname; do
  ln -s "$(command -v "$runtime_command")" "$WEZ_RUNTIME_TMP/bin/$runtime_command"
done
# The stub bin stays FIRST so the fixture py/cygpath/git/claude/wezterm and the
# symlinked coreutils above still win, and the host $PATH sits behind it so the
# dispatches below resolve the same `timeout` a real run would (#548). The
# trailing /usr/bin:/bin is kept as the MSYS fallback for Git Bash, where the
# host $PATH may carry those directories in Windows form only — the value is a
# strict superset of the old one, so it cannot regress any runner.
WEZ_RUNTIME_PATH="$WEZ_RUNTIME_TMP/bin:$PATH:/usr/bin:/bin"
printf 'wezterm portable python prompt\n' > "$WEZ_RUNTIME_TMP/prompt.txt"
WEZ_STATUS_FILE="$WEZ_RUNTIME_TMP/tmp/wezterm-clean-status.json"
WEZ_PROVIDER_CAPTURE="$WEZ_RUNTIME_TMP/clean-provider-capture.txt"
WEZ_CYGPATH_CAPTURE="$WEZ_RUNTIME_TMP/cygpath-capture.txt"
: > "$WEZ_CYGPATH_CAPTURE"
WEZ_RUNTIME_OUT="$(
  cd "$WEZ_RUNTIME_TMP/repo" && \
  PATH="$WEZ_RUNTIME_PATH" HOME="$WEZ_RUNTIME_TMP/home" MSYSTEM=MINGW64 \
  UBERDEV_TMPDIR="$WEZ_RUNTIME_TMP/tmp" WEZ_CYGPATH_CAPTURE="$WEZ_CYGPATH_CAPTURE" WEZ_REAL_CYGPATH="$REAL_CYGPATH_EXE" \
  UBERDEV_AGENT_STATUS_FILE="$WEZ_STATUS_FILE" WEZ_STATUS_FILE="$WEZ_STATUS_FILE" \
  WEZ_PROVIDER_CAPTURE="$WEZ_PROVIDER_CAPTURE" \
  /bin/bash -c '
    . "$1"
    PATH=../bin
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 1
    resolved_python="$_UBERDEV_PYTHON_EXE"
    PATH="$3"; export PATH
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=()
    _uberdev_dispatch_wezterm 92 small "$2"
    printf "rc=%s\npane=%s\nresolved=%s\nstatus=%s\nprovider=%s\n" "$?" "${DISPATCH_ID:-}" "$resolved_python" \
      "$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)" "$(cat "$WEZ_PROVIDER_CAPTURE" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$WEZ_RUNTIME_TMP/prompt.txt" "$WEZ_RUNTIME_PATH"
)"
WEZ_HOSTILE_STATUS_FILE="$WEZ_RUNTIME_TMP/tmp/wezterm-hostile-status.json"
WEZ_HOSTILE_PROVIDER_CAPTURE="$WEZ_RUNTIME_TMP/hostile-provider-capture.txt"
WEZ_HOSTILE_OUT="$(
  cd "$WEZ_RUNTIME_TMP/repo" && \
  PATH="$WEZ_RUNTIME_PATH" HOME="$WEZ_RUNTIME_TMP/home" MSYSTEM=MINGW64 \
  UBERDEV_TMPDIR="$WEZ_RUNTIME_TMP/tmp" WEZ_CYGPATH_CAPTURE="$WEZ_CYGPATH_CAPTURE" WEZ_REAL_CYGPATH="$REAL_CYGPATH_EXE" \
  UBERDEV_AGENT_STATUS_FILE="$WEZ_HOSTILE_STATUS_FILE" WEZ_STATUS_FILE="$WEZ_HOSTILE_STATUS_FILE" \
  WEZ_PROVIDER_CAPTURE="$WEZ_HOSTILE_PROVIDER_CAPTURE" \
  /bin/bash -c '
    . "$1"
    PATH=../bin
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 1
    resolved_python="$_UBERDEV_PYTHON_EXE"
    PATH="$3"; export PATH
    run_python() {
      if [ -n "$_UBERDEV_PYTHON_PREFIX" ]; then
        command "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$@"
      else
        command "$_UBERDEV_PYTHON_EXE" "$@"
      fi
    }
    python3() { run_python "$@"; }
    export -f run_python python3
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=()
    _uberdev_dispatch_wezterm 93 small "$2"
    printf "rc=%s\npane=%s\nresolved=%s\nstatus=%s\nprovider=%s\n" "$?" "${DISPATCH_ID:-}" "$resolved_python" \
      "$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)" "$(cat "$WEZ_PROVIDER_CAPTURE" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$WEZ_RUNTIME_TMP/prompt.txt" "$WEZ_RUNTIME_PATH"
)"
WT_RUNTIME_BODY="$(awk '/^_uberdev_dispatch_wezterm\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
WEZ_PYTHON_EXPECTED="$(cd "$WEZ_RUNTIME_TMP/bin" && pwd -P)/py"
WEZ_CLEAN_RESOLVED="$(printf '%s\n' "$WEZ_RUNTIME_OUT" | sed -n 's/^resolved=//p')"
WEZ_HOSTILE_RESOLVED="$(printf '%s\n' "$WEZ_HOSTILE_OUT" | sed -n 's/^resolved=//p')"
WEZ_CLEAN_PANE_MARKER="$WEZ_RUNTIME_TMP/repo/.claude/worktrees/solve-issue-92/.wezterm-pane-cwd-observed"
WEZ_HOSTILE_PANE_MARKER="$WEZ_RUNTIME_TMP/repo/.claude/worktrees/solve-issue-93/.wezterm-pane-cwd-observed"
WEZ_VERIFY_PYTHON=( "$REAL_PYTHON_EXE" )
if [ -n "$REAL_PYTHON_PREFIX" ]; then WEZ_VERIFY_PYTHON+=( "$REAL_PYTHON_PREFIX" ); fi
WEZ_VERIFY_OUT=''
if WEZ_VERIFY_OUT="$("${WEZ_VERIFY_PYTHON[@]}" -I -B - \
    "$WEZ_CLEAN_RESOLVED" "$WEZ_HOSTILE_RESOLVED" "$WEZ_PYTHON_EXPECTED" \
    "$WEZ_STATUS_FILE" "$WEZ_HOSTILE_STATUS_FILE" \
    "$WEZ_PROVIDER_CAPTURE" "$WEZ_HOSTILE_PROVIDER_CAPTURE" \
    "$WEZ_CLEAN_PANE_MARKER" "$WEZ_HOSTILE_PANE_MARKER" "$WEZ_CYGPATH_CAPTURE" 2>&1 <<'PY'
import json,os,pathlib,sys
(clean_resolved,hostile_resolved,expected_python,clean_status_path,hostile_status_path,
 clean_provider_path,hostile_provider_path,clean_marker_path,hostile_marker_path,
 cygpath_capture)=sys.argv[1:]
for resolved in (clean_resolved,hostile_resolved):
    assert os.path.samefile(resolved,expected_python),(resolved,expected_python)
for issue,status_path in ((92,clean_status_path),(93,hostile_status_path)):
    assert json.loads(pathlib.Path(status_path).read_text())=={
        'backend':'wezterm','exit_code':0,'issue':issue,'state':'completed','tier':'small',
    }
for provider_path in (clean_provider_path,hostile_provider_path):
    assert pathlib.Path(provider_path).read_text()=='running-observed-no-export\n'
for marker_path in (clean_marker_path,hostile_marker_path):
    assert pathlib.Path(marker_path).read_text()=='pane-cwd-observed\n'
assert pathlib.Path(cygpath_capture).read_text().splitlines()==[
    'solve-issue-92','solve-issue-92','wezterm-clean-status.json',
    'solve-issue-93','solve-issue-93','wezterm-hostile-status.json',
]
PY
)"; then
  WEZ_VERIFY_RC=0
else
  WEZ_VERIFY_RC=$?
fi
if printf '%s\n' "$WEZ_RUNTIME_OUT" | grep -Fq 'rc=0' \
    && printf '%s\n' "$WEZ_RUNTIME_OUT" | grep -Fq 'pane=731' \
    && printf '%s\n' "$WEZ_HOSTILE_OUT" | grep -Fq 'rc=0' \
    && printf '%s\n' "$WEZ_HOSTILE_OUT" | grep -Fq 'pane=731' \
    && [ "$WEZ_CYGPATH_U_PROBE" = 'C:/fixture/path' ] \
    && [ "$WEZ_VERIFY_RC" -eq 0 ] \
    && printf '%s\n' "$WT_RUNTIME_BODY" | grep -Fq '_uberdev_dispatch_resolve_python'; then
  echo "  PASS  clean and hostile WezTerm py -3 panes retain launchers, cwd, status, and non-exported bridges"; PASS=$((PASS + 1))
else
  echo "  FAIL  clean and hostile WezTerm py -3 panes retain launchers, cwd, status, and non-exported bridges"
  echo "        clean=$WEZ_RUNTIME_OUT hostile=$WEZ_HOSTILE_OUT cygpath_u=$WEZ_CYGPATH_U_PROBE verifier=$WEZ_VERIFY_OUT"
  FAIL=$((FAIL + 1))
fi
# #548 — the binding above is a fixture INPUT, not a constant. Narrowing it back
# silently moves the dispatch onto the UNBOUNDED preflight arm on any host that
# ships no /usr/bin/timeout, and every existing verdict in this file is
# byte-identical on both arms. This row is what makes the widening enforced
# rather than merely present, and it reds on ubuntu, Windows and macOS alike.
# One row covers both dispatches above — they share the one binding.
#
# The haystack is padded with a trailing ':' so the host $PATH counts whether it
# is followed by a segment (the form below) or is LAST (the #521 donor form at
# child-dispatch.test.sh:1043). An unpadded *":$PATH:"* would red that shape for
# no reason.
# BOUNDARY: a degenerate host whose entire $PATH is one of the pinned segments
# is not distinguished here; the arm row below covers the real property there.
WEZ_RUNTIME_PATH_STUB_OK=0
WEZ_RUNTIME_PATH_TAIL_OK=0
case "$WEZ_RUNTIME_PATH" in "$WEZ_RUNTIME_TMP/bin:"*) WEZ_RUNTIME_PATH_STUB_OK=1 ;; esac
case "$WEZ_RUNTIME_PATH:" in *":$PATH:"*)             WEZ_RUNTIME_PATH_TAIL_OK=1 ;; esac
if [ "$WEZ_RUNTIME_PATH_STUB_OK" -eq 1 ] && [ "$WEZ_RUNTIME_PATH_TAIL_OK" -eq 1 ]; then
  echo "  PASS  wezterm runtime PATH keeps the stub bin first and the host PATH behind it"
  PASS=$((PASS + 1))
else
  echo "  FAIL  wezterm runtime PATH keeps the stub bin first and the host PATH behind it: $WEZ_RUNTIME_PATH"
  FAIL=$((FAIL + 1))
fi
# #548 — assert WHICH preflight arm the two dispatches above took, not merely
# that one was taken. `_uberdev_dispatch_preflight_timeout_bin` returns 0
# SILENTLY on the happy path and emits no audit record naming the bound, so the
# resolved binary is the only observable — every verdict above is byte-identical
# on the bounded and the unbounded arm, which is why the narrow literal survived
# here. The row above proves the PATH is wide; this one proves the width reaches
# production code. One row covers the clean and the hostile dispatch: they share
# the one binding.
#
# Driven as a unit under the SAME variable the dispatches ran with, so the row
# cannot drift onto a PATH nobody used — that drift IS this issue's defect
# class. Precedent: child-dispatch.test.sh:1074-1092 (#521) and T15 in
# dispatch-child-worktree-teardown.test.sh, which drives this same resolver.
#
# TIMEOUT_BIN is neither set NOR unset here. lib/dispatch.sh tries
# "${TIMEOUT_BIN:-}" ahead of every PATH name, and the dispatches above inherit
# that variable from the ambient environment; the `unset TIMEOUT_BIN` lines in
# this file belong to the #246 D-perm/D-skip subshells and do not reach here.
# Touching it either way would assert about an environment they never had.
#
# No pipe, by construction: command substitution and `case` only, so this file's
# epipe-guard.test.sh exposure is unchanged and it still needs no `pipefail`.
# The verdict goes through the PASS/FAIL counters because the file is `set -u`
# only — a bare `[ … ]` or `*) false ;;` here would be a no-op.
WEZ_RUNTIME_PATH_TIMEOUT_BIN="$(
  PATH="$WEZ_RUNTIME_PATH" \
    /bin/bash -c 'set -u; . "$1"; _uberdev_dispatch_preflight_timeout_bin' _ "$DISPATCH_LIB"
)"
echo "        wezterm preflight resolved timeout bin = ${WEZ_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
# Absolute, never a bare name: a bare name in command position is answered by
# the shell's function table first (T15's finding). The drive-letter alternation
# is mandatory — Git Bash is in the CI matrix. Absoluteness subsumes
# non-emptiness: the empty string matches neither branch.
WEZ_RUNTIME_PATH_ARM_OK=0
case "$WEZ_RUNTIME_PATH_TIMEOUT_BIN" in
  /*|[A-Za-z]:/*) [ -x "$WEZ_RUNTIME_PATH_TIMEOUT_BIN" ] && WEZ_RUNTIME_PATH_ARM_OK=1 ;;
esac
if [ "$WEZ_RUNTIME_PATH_ARM_OK" -eq 1 ]; then
  echo "  PASS  wezterm dispatch took the BOUNDED preflight arm (absolute, executable timeout bin)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  wezterm dispatch took the UNBOUNDED preflight arm — resolved timeout bin: ${WEZ_RUNTIME_PATH_TIMEOUT_BIN:-<none>}"
  FAIL=$((FAIL + 1))
fi
rm -rf "$WEZ_RUNTIME_TMP"

echo
echo "== Anti-pattern: wezterm backend never uses claude --bg =="
# Scope the check to the _uberdev_dispatch_wezterm function body — sibling
# backends in the same file legitimately use `claude --bg`.
WT_FN_BODY="$(awk '/^_uberdev_dispatch_wezterm\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s' "$WT_FN_BODY" | grep -qE 'claude --bg'; then
  echo "  FAIL  _uberdev_dispatch_wezterm uses claude --bg (pane needs foreground claude -p)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  _uberdev_dispatch_wezterm does not use claude --bg"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

uberdev_test_exit_floor_reached
[[ $FAIL -eq 0 ]]
