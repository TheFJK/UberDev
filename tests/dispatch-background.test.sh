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
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_wait_owned_session() {
      while state="$(ps -o stat= -p "$1" 2>/dev/null)" && [ -n "$state" ] && [ "${state#Z}" = "$state" ]; do :; done
      return 1
    }
    MODEL=sonnet; PERM_FLAG=(); EFFORT_FLAG=(); failures=0; issue=70
    for outcome in completed failed completed failed completed failed; do
      issue=$((issue + 1))
      printf "%s\n" "$outcome" > "$UBERDEV_TMPDIR/prompt-$issue.txt"
      UBERDEV_AGENT_STATUS_FILE="$UBERDEV_TMPDIR/status-$issue.json"
      UBERDEV_AGENT_RESULT_FILE="$UBERDEV_TMPDIR/result-$issue.md"
      export UBERDEV_AGENT_STATUS_FILE UBERDEV_AGENT_RESULT_FILE
      _uberdev_dispatch_background "$issue" small "$UBERDEV_TMPDIR/prompt-$issue.txt"
      rc=$?; status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
      case "$outcome:$rc:$DISPATCH_ID:$status" in
        completed:0:*:*\"state\":\"completed\"*\"exit_code\":0*)
          [ "$(cat "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null)" = "immediate completed result" ] || failures=$((failures + 1))
          [ "$(stat -f %Lp "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null || stat -c %a "$UBERDEV_AGENT_RESULT_FILE" 2>/dev/null)" = 600 ] || failures=$((failures + 1))
          ;;
        failed:0:*:*\"state\":\"failed\"*\"exit_code\":29*)
          [ ! -s "$UBERDEV_AGENT_RESULT_FILE" ] || failures=$((failures + 1))
          ;;
        *) failures=$((failures + 1)) ;;
      esac
      [ -n "${DISPATCH_ID:-}" ] || failures=$((failures + 1))
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
