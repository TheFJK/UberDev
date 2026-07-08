#!/usr/bin/env bash
# Shape-check for the `codex` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_codex). Verifies: codex is in the backend enum; the
# availability probe exists; preflight resolves codex (explicit + auto when
# CODEX_HOME set / claude absent); the dispatch_one switch routes codex;
# the backend execs `codex exec` (not claude) with --sandbox workspace-write,
# --json, -o, nohup-detached, PID-captured like the background arm; and the
# goal-state liveness poll is backend-aware (kill -0 for codex/background).
# RFC 0012 §3.4 codex-port.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
GOAL_LIB="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
PLUGIN_HOOKS="$REPO_ROOT/codex/uberdev-codex/hooks/hooks.json"
PLUGIN_ROOT="$REPO_ROOT/codex/uberdev-codex"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        pattern: $pattern"; FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        pattern: $pattern (must not appear)"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

pass_msg() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; FAIL=$((FAIL + 1)); }

echo "== Enum + probe =="
assert_grep "$DISPATCH_LIB" \
  'auto\|claude-bg\|wezterm\|background\|codex' \
  "backend enum includes codex"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_codex_available\(\)' \
  "codex availability probe is defined"
assert_grep "$DISPATCH_LIB" \
  'command -v codex' \
  "codex probe checks the codex binary on PATH"

echo "== Preflight resolves codex =="
assert_grep "$DISPATCH_LIB" \
  'resolved="codex"; reason="explicit"' \
  "preflight accepts explicit --backend=codex"
assert_grep "$DISPATCH_LIB" \
  'auto-codex-env' \
  "preflight auto-resolves codex when CODEX_HOME is set"
assert_grep "$DISPATCH_LIB" \
  'auto-no-claude' \
  "preflight auto-resolves codex when claude is absent but codex present"

CODEX_MISSING_OUT="$(mktemp)"
if CODEX_HOME=/tmp/codex-home PATH=/usr/bin:/bin UBERDEV_DISPATCH_BACKEND_REQUESTED=auto bash -c \
  '. "$1"; uberdev_dispatch_preflight' _ "$DISPATCH_LIB" >"$CODEX_MISSING_OUT" 2>&1; then
  fail_msg "auto preflight fails loudly when CODEX_HOME is set but codex is absent" "preflight returned success"
elif grep -q "CODEX_HOME" "$CODEX_MISSING_OUT" && grep -q "codex" "$CODEX_MISSING_OUT"; then
  pass_msg "auto preflight fails loudly when CODEX_HOME is set but codex is absent"
else
  fail_msg "auto preflight failure names CODEX_HOME and codex" "$(cat "$CODEX_MISSING_OUT")"
fi
rm -f "$CODEX_MISSING_OUT"

echo "== dispatch_one routes codex =="
assert_grep "$DISPATCH_LIB" \
  'codex\)[[:space:]]+_uberdev_dispatch_codex' \
  "dispatch_one switch routes codex to _uberdev_dispatch_codex"

echo "== _uberdev_dispatch_codex mechanism (mirrors background, execs codex) =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_codex\(\)' \
  "_uberdev_dispatch_codex function is defined"
assert_grep "$DISPATCH_LIB" \
  'git worktree add' \
  "codex backend runs explicit git worktree add (same as background)"
assert_grep "$DISPATCH_LIB" \
  'codex exec' \
  "codex backend launches headless codex exec (NOT claude -p)"
assert_grep "$DISPATCH_LIB" \
  '--sandbox workspace-write' \
  "codex backend passes --sandbox workspace-write for autonomous edits"
assert_grep "$DISPATCH_LIB" \
  '--ask-for-approval never' \
  "codex backend pins approval policy to never for detached execution"
assert_grep "$DISPATCH_LIB" \
  '--json' \
  "codex backend passes --json for progress streaming"
assert_grep "$DISPATCH_LIB" \
  'nohup' \
  "codex backend detaches via nohup (same as background)"
assert_grep "$DISPATCH_LIB" \
  'disown' \
  "codex backend disowns the detached process"
assert_grep "$DISPATCH_LIB" \
  'kill -0 "\$DISPATCH_ID"' \
  "codex backend PID-liveness-gates before reporting success"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_prepare_tmp_target "\$RESULT_FILE" "\$ISSUE_NUM" "codex"' \
  "codex backend guards the predictable result file before passing it to codex exec"
assert_grep "$DISPATCH_LIB" \
  'write_status running null' \
  "codex backend wrapper records running state before launching codex"
assert_grep "$DISPATCH_LIB" \
  'write_status "\$CODEX_STATE" "\$CODEX_RC"' \
  "codex wrapper records codex exec exit code in the status file"
assert_grep "$DISPATCH_LIB" \
  '"backend":"codex"' \
  "codex backend status-file + audit payload carries backend=codex"
assert_grep "$DISPATCH_LIB" \
  'WRAPPER_PID="\$\$"' \
  "codex wrapper uses its own numeric shell PID for status"

echo "== Codex backend does NOT thread claude-specific flags =="
CODEX_BODY="$(awk '
  /^_uberdev_dispatch_codex\(\) \{/ {in_body=1}
  in_body {print}
  in_body && /^}/ {exit}
' "$DISPATCH_LIB")"
if printf '%s\n' "$CODEX_BODY" | grep -qE '\<(PERM_FLAG|EFFORT_FLAG|claude -p)\>'; then
  fail_msg "codex backend body does not reference Claude-only flags or claude -p" \
    "$(printf '%s\n' "$CODEX_BODY" | grep -nE '\<(PERM_FLAG|EFFORT_FLAG|claude -p)\>')"
else
  pass_msg "codex backend body does not reference Claude-only flags or claude -p"
fi

echo "== goal-state backend-awareness =="
assert_grep "$GOAL_LIB" \
  'claude-bg\|wezterm\|background\|codex' \
  "goal-state UBERDEV_RESOLVED_BACKEND allowlist includes codex"
assert_grep "$GOAL_LIB" \
  'background\|codex' \
  "goal-state busy-for-issue liveness branches on background|codex (PID path)"

echo "== solve-launcher backend-conditional version gate =="
assert_grep "$LAUNCHER" \
  'UBERDEV_RESOLVED_BACKEND.*codex' \
  "solve-launcher gates on the resolved backend being codex"
assert_grep "$LAUNCHER" \
  'command -v codex' \
  "solve-launcher requires codex CLI when codex backend resolved"
assert_grep "$LAUNCHER" \
  'PLUGIN_ROOT' \
  "solve-launcher sources dispatch.sh via PLUGIN_ROOT (Codex) fallback"
assert_grep "$LAUNCHER" \
  'solve-codex-stdout-\$ISSUE_NUM\.log' \
  "solve-launcher prints codex log path in final summary"
assert_grep "$LAUNCHER" \
  'solve-codex-result-\$ISSUE_NUM\.md' \
  "solve-launcher prints codex result path in final summary"

echo "== Codex backend does not require timeout/gtimeout =="
NO_TIMEOUT_BIN="$(mktemp -d)"
cat > "$NO_TIMEOUT_BIN/codex" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$NO_TIMEOUT_BIN/codex"
if UBERDEV_RESOLVED_BACKEND=codex PATH="$NO_TIMEOUT_BIN" /bin/bash -c \
  '. "$1"; uberdev_dispatch_resolve_env codex' _ "$DISPATCH_LIB" >/tmp/codex-no-timeout-out 2>&1; then
  pass_msg "codex dispatch env resolution skips timeout/gtimeout requirement"
else
  fail_msg "codex dispatch env resolution skips timeout/gtimeout requirement" "$(cat /tmp/codex-no-timeout-out)"
fi
rm -rf "$NO_TIMEOUT_BIN"

echo "== Public launcher parser accepts codex =="
PARSER_OUT="$(mktemp)"
if bash "$LAUNCHER" --auto-mode=0 -- --backend=codex >"$PARSER_OUT" 2>&1; then
  echo "  FAIL  parser-only invocation should exit with usage when no issue is supplied"; FAIL=$((FAIL + 1))
elif grep -q "not in {auto,claude-bg,wezterm,background" "$PARSER_OUT"; then
  echo "  FAIL  public launcher rejected --backend=codex"; cat "$PARSER_OUT"; FAIL=$((FAIL + 1))
elif grep -q "Usage:" "$PARSER_OUT"; then
  echo "  PASS  public launcher parser accepts --backend=codex before usage check"; PASS=$((PASS + 1))
else
  echo "  FAIL  public launcher parser produced unexpected output"; cat "$PARSER_OUT"; FAIL=$((FAIL + 1))
fi
rm -f "$PARSER_OUT"

echo "== goal-state reads codex status files =="
TMPD="$(mktemp -d)"
printf '%s\n' '{"issue":42,"backend":"codex","pid":"999999"}' > "$TMPD/solve-codex-status-42.json"
PID_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
if [ "$PID_OUT" = "999999" ]; then
  echo "  PASS  goal-state PID helper reads solve-codex-status-N.json for codex backend"; PASS=$((PASS + 1))
else
  echo "  FAIL  goal-state PID helper did not read codex status file (got '$PID_OUT')"; FAIL=$((FAIL + 1))
fi

rm -f "$TMPD/solve-codex-status-42.json"
printf '%s\n' '{"issue":42,"backend":"background","pid":"111111"}' > "$TMPD/solve-bg-status-42.json"
PID_FALLBACK_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
if [ -z "$PID_FALLBACK_OUT" ]; then
  pass_msg "goal-state PID helper refuses cross-backend fallback status files"
else
  fail_msg "goal-state PID helper refuses cross-backend fallback status files" "got '$PID_FALLBACK_OUT'"
fi

printf '%s\n' '{"issue":42,"backend":"background","pid":"222222"}' > "$TMPD/solve-codex-status-42.json"
PID_BACKEND_MISMATCH_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
if [ -z "$PID_BACKEND_MISMATCH_OUT" ]; then
  pass_msg "goal-state PID helper validates backend field before trusting pid"
else
  fail_msg "goal-state PID helper validates backend field before trusting pid" "got '$PID_BACKEND_MISMATCH_OUT'"
fi
printf '%s\n' '{"issue":42,"backend":"codex","state":"failed","exit_code":17,"pid":"222222","log":"/tmp/log","result":"/tmp/result"}' > "$TMPD/solve-codex-status-42.json"
CODEX_STATUS_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; uberdev_goal_codex_status_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
case "$CODEX_STATUS_OUT" in
  failed$'\t'17$'\t'/tmp/log$'\t'/tmp/result)
    pass_msg "goal-state exposes terminal codex failed status with exit/log/result" ;;
  *)
    fail_msg "goal-state exposes terminal codex failed status with exit/log/result" "got '$CODEX_STATUS_OUT'" ;;
esac
rm -rf "$TMPD"

echo "== _uberdev_dispatch_codex behavior with stubbed git/codex =="
BEH_TMP="$(mktemp -d)"
mkdir -p "$BEH_TMP/bin" "$BEH_TMP/repo" "$BEH_TMP/tmp"
cat > "$BEH_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  mkdir -p "$3"
  exit 0
fi
echo "fake git: unsupported args: $*" >&2
exit 1
SH
cat > "$BEH_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
{
  printf 'argv:'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\nUBERDEV_TURBO=%s\n' "${UBERDEV_TURBO:-}"
} >> "$CODEX_CAPTURE"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sleep "${CODEX_STUB_SLEEP:-1}"
[ -n "$out" ] && printf 'codex final result\n' > "$out"
exit "${CODEX_STUB_RC:-0}"
SH
chmod +x "$BEH_TMP/bin/git" "$BEH_TMP/bin/codex"
printf 'prompt body for codex' > "$BEH_TMP/prompt.txt"
BEH_OUT="$(
  cd "$BEH_TMP/repo" && \
  PATH="$BEH_TMP/bin:/usr/bin:/bin" \
  UBERDEV_TMPDIR="$BEH_TMP/tmp" \
  AUTO_MODE=1 \
  CODEX_CAPTURE="$BEH_TMP/codex-capture.txt" \
  bash -c '
    . "$1"
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    i=0
    while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
      sleep 1
      i=$((i + 1))
    done
    printf "rc=%s\npid=%s\n" "$rc" "$pid"
    printf "status=%s\n" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)"
    printf "result=%s\n" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$BEH_TMP/prompt.txt"
)"
case "$BEH_OUT" in
  *'rc=0'*'"state":"completed"'*'"exit_code":0'*'result=codex final result'*)
    pass_msg "codex dispatch writes completed status with exit_code and result after stub exits" ;;
  *)
    fail_msg "codex dispatch writes completed status with exit_code and result after stub exits" "$BEH_OUT" ;;
esac
if grep -Fq -- '--sandbox] [workspace-write]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '--ask-for-approval] [never]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- 'UBERDEV_TURBO=1' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[prompt body for codex]' "$BEH_TMP/codex-capture.txt"; then
  pass_msg "codex dispatch passes sandbox, approval policy, turbo env, and prompt body to codex exec"
else
  fail_msg "codex dispatch passes sandbox, approval policy, turbo env, and prompt body to codex exec" \
    "$(cat "$BEH_TMP/codex-capture.txt" 2>/dev/null)"
fi
if printf '%s\n' "$BEH_OUT" | grep -Eq '"pid":"[0-9]+"'; then
  pass_msg "codex dispatch status pid is numeric"
else
  fail_msg "codex dispatch status pid is numeric" "$BEH_OUT"
fi
rm -rf "$BEH_TMP"

echo "== _uberdev_dispatch_codex failure and delayed-wrapper behavior =="
FAIL_TMP="$(mktemp -d)"
mkdir -p "$FAIL_TMP/bin" "$FAIL_TMP/repo" "$FAIL_TMP/tmp"
cp "$BEH_TMP/bin/git" "$FAIL_TMP/bin/git" 2>/dev/null || cat > "$FAIL_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  mkdir -p "$3"
  exit 0
fi
exit 1
SH
cat > "$FAIL_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'codex refused\n' > "$out"
exit 17
SH
chmod +x "$FAIL_TMP/bin/git" "$FAIL_TMP/bin/codex"
printf 'prompt body for failure' > "$FAIL_TMP/prompt.txt"
FAIL_OUT="$(
  cd "$FAIL_TMP/repo" && \
  PATH="$FAIL_TMP/bin:/usr/bin:/bin" \
  UBERDEV_TMPDIR="$FAIL_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    i=0
    while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
    printf "rc=%s\nstatus=%s\nresult=%s\n" "$rc" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$FAIL_TMP/prompt.txt"
)"
case "$FAIL_OUT" in
  *'rc=0'*'"state":"failed"'*'"exit_code":17'*'result=codex refused'*)
    pass_msg "codex dispatch records failed child status without treating dispatch as failed" ;;
  *)
    fail_msg "codex dispatch records failed child status without treating dispatch as failed" "$FAIL_OUT" ;;
esac
rm -rf "$FAIL_TMP"

RACE_TMP="$(mktemp -d)"
mkdir -p "$RACE_TMP/bin" "$RACE_TMP/repo" "$RACE_TMP/tmp"
cat > "$RACE_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  mkdir -p "$3"
  exit 0
fi
exit 1
SH
cat > "$RACE_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'fast failed codex result\n' > "$out"
exit 23
SH
cat > "$RACE_TMP/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -gt 0 ]; then
  exec /bin/cat "$@"
fi
tmp="$(mktemp)"
/bin/cat > "$tmp"
if grep -q '"state":"running"' "$tmp"; then
  sleep 1
fi
/bin/cat "$tmp"
rm -f "$tmp"
SH
chmod +x "$RACE_TMP/bin/git" "$RACE_TMP/bin/codex" "$RACE_TMP/bin/cat"
printf 'prompt body fast fail' > "$RACE_TMP/prompt.txt"
RACE_OUT="$(
  cd "$RACE_TMP/repo" && \
  PATH="$RACE_TMP/bin:/usr/bin:/bin" \
  UBERDEV_TMPDIR="$RACE_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    i=0
    while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
    printf "rc=%s\npid=%s\nstatus=%s\nresult=%s\n" "$rc" "$pid" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$RACE_TMP/prompt.txt"
)"
case "$RACE_OUT" in
  *'rc=0'*'"state":"failed"'*'"exit_code":23'*'result=fast failed codex result'*)
    pass_msg "codex dispatch never overwrites terminal child status with stale running status" ;;
  *)
    fail_msg "codex dispatch never overwrites terminal child status with stale running status" "$RACE_OUT" ;;
esac
rm -rf "$RACE_TMP"

echo "== Codex plugin package is self-contained =="
if [ -r "$PLUGIN_ROOT/lib/dispatch.sh" ] && [ -r "$PLUGIN_ROOT/lib/solve-launcher.sh" ] && [ -x "$PLUGIN_ROOT/hooks/session-start" ]; then
  echo "  PASS  Codex plugin bundles runtime lib and executable session-start hook"; PASS=$((PASS + 1))
else
  echo "  FAIL  Codex plugin missing runtime lib or executable session-start hook"; FAIL=$((FAIL + 1))
fi
if grep -q '\${PLUGIN_ROOT}/hooks/session-start' "$PLUGIN_HOOKS"; then
  echo "  PASS  Codex hook points at plugin-local session-start"; PASS=$((PASS + 1))
else
  echo "  FAIL  Codex hook does not point at plugin-local session-start"; FAIL=$((FAIL + 1))
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
