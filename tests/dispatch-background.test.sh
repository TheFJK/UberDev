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
  'git worktree add' \
  "background backend runs explicit git worktree add (sidesteps #40164)"
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

echo "== Positive: status-file writes + audit payload =="
assert_grep "$DISPATCH_LIB" \
  'DISPATCH_RC' \
  "background backend sets the DISPATCH_RC per-issue result var"
assert_grep "$DISPATCH_LIB" \
  '"backend":"background"' \
  "agent_dispatched payload carries backend=background"
assert_grep "$DISPATCH_LIB" \
  '"pid":' \
  "agent_dispatched payload carries the detached pid"
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
rm -rf "$PYTHON_RESOLVER_TMP"
if grep -Eq '(^|[[:space:]|(&])python3[[:space:]]+-' "$DISPATCH_LIB"; then
  echo "  FAIL  dispatch.sh retains a literal python3 invocation"; FAIL=$((FAIL + 1))
else
  echo "  PASS  all dispatch Python calls use the portable resolver"; PASS=$((PASS + 1))
fi
detached_resolver_count="$(grep -Fc 'nohup "${PYTHON_LAUNCH[@]}"' "$DISPATCH_LIB")"
if [ "$detached_resolver_count" -eq 2 ] \
    && grep -Fq 'PYTHON_EXE="$1"; PYTHON_PREFIX="$2"; shift 2' "$DISPATCH_LIB" \
    && grep -Fq '"$PYTHON_EXE" "$PYTHON_PREFIX" "$@"' "$DISPATCH_LIB"; then
  echo "  PASS  detached and nested dispatch preserve the py -3 argv prefix"; PASS=$((PASS + 1))
else
  echo "  FAIL  detached and nested dispatch preserve the py -3 argv prefix"; FAIL=$((FAIL + 1))
fi

echo
echo "== Immediate terminal background wrapper keeps its exact handle =="
IMMEDIATE_TMP="$(mktemp -d)"
mkdir -p "$IMMEDIATE_TMP/bin" "$IMMEDIATE_TMP/repo" "$IMMEDIATE_TMP/tmp"
cat > "$IMMEDIATE_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = worktree ] && [ "$2" = add ]; then mkdir -p "$3"; exit 0; fi
exit 1
SH
cat > "$IMMEDIATE_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
body="$2"
printf 'immediate %s result\n' "$body"
case "$body" in *failed*) exit 29 ;; *) exit 0 ;; esac
SH
chmod +x "$IMMEDIATE_TMP/bin/git" "$IMMEDIATE_TMP/bin/claude"
IMMEDIATE_OUT="$(
  cd "$IMMEDIATE_TMP/repo" &&
  PATH="$IMMEDIATE_TMP/bin:/usr/bin:/bin" UBERDEV_TMPDIR="$IMMEDIATE_TMP/tmp" \
  _UBERDEV_PYTHON_EXE="$REAL_PYTHON" _UBERDEV_PYTHON_PREFIX='' \
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_wait_owned_session() {
      while state="$(ps -o stat= -p "$1" 2>/dev/null)" && [ -n "$state" ] && [ "${state#Z}" = "$state" ]; do :; done
      return 1
    }
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=(); failures=0; issue=70
    record_failure() {
      failures=$((failures + 1))
      printf "mismatch issue=%s outcome=%s check=%s rc=%s dispatch_id=%q status=%q result=%q mode=%q partials=%q child_log=%q\n" \
        "$issue" "$outcome" "$1" "$rc" "${DISPATCH_ID:-}" "$status" "$result" "$mode" "$partials" "$child_log"
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
      mode="$(stat -f %Lp "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null || stat -c %a "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null)"
      partials="$(find "$UBERDEV_TMPDIR" -maxdepth 1 \( -name "result-$issue.md.partial.*" -o -name "result-$issue.md.tmp.*" \) -print)"
      child_log="$(cat "$UBERDEV_TMPDIR/solve-bg-stdout-$issue.log" 2>/dev/null)"
      case "$outcome:$rc:$DISPATCH_ID:$status" in
        completed:0:*:*\"state\":\"completed\"*\"exit_code\":0*)
          [ "$result" = "immediate completed result" ] || record_failure completed_result
          [ "$mode" = 600 ] || record_failure completed_result_mode
          ;;
        failed:0:*:*\"state\":\"failed\"*\"exit_code\":29*)
          [ ! -s "$UBERDEV_AGENT_RESULT_FILE" ] || record_failure failed_result_empty
          ;;
        *) record_failure terminal_contract ;;
      esac
      [ -z "$partials" ] || record_failure partial_cleanup
      [ -n "${DISPATCH_ID:-}" ] || record_failure dispatch_id
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
rm -rf "$IMMEDIATE_TMP"

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
