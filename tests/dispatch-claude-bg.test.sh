#!/usr/bin/env bash
# Shape-check for the v0.22.0 `claude --bg` dispatch in lib/solve-launcher.sh
# (#304 / RFC 0012 §3.4: the executable Phase A + Step 4.5 + Phase B pipeline
# was hoisted out of solve-pipeline/SKILL.md into the lib file).
#
# Verifies the three-arm BG_PROMPT_MODE case-switch, the Phase A probes,
# the wave-batching outer loop, the --terminal= deprecation shim, and the
# absence of the security anti-pattern shapes (eval, naive interpolation).
#
# Companion test: tests/ghostty-dispatch-no-instance-leak.test.sh asserts
# the retired surface is ABSENT. This test asserts the new surface is PRESENT.

set -u
unset UBERDEV_AGENT_INSTANCE_ID

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
SOLVE_SKILL="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
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

# Mirror of the extraction pipeline in plugins/uberdev/lib/dispatch.sh
# (the success arm of _uberdev_dispatch_claude_bg, post-#143 fix).
# Reads $1 as the path to a fixture file simulating $BG_STDOUT_LOG and
# echoes the post-scrub $DISPATCH_ID (either empty or exactly 8 hex).
# This helper now structurally mirrors the _uberdev_dispatch_claude_bg
# id-extraction block (ID_CLEAN/ID_RAW, post-#143 fix): ANSI-strip via sed,
# `printf '%s\n' | grep -m1 -aoE` the marker, `${raw##* }` for the word, then
# hex-scrub + the {8} length sentinel. Keeping the same five steps (rather than
# an awk|head shortcut) means no part of the pipeline escapes the shape-check
# assertions above — the regexes here MUST stay in lockstep with production.
_extract_id() {
  local fixture="$1"
  local clean raw id
  clean="$(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' "$fixture")"
  raw="$(printf '%s\n' "$clean" | grep -m1 -aoE '^backgrounded · [0-9a-f]{8}$')"
  id="${raw##* }"
  id="${id//[^0-9a-f]/}"
  [[ ${#id} -eq 8 ]] || id=""
  printf '%s' "$id"
}

# tmp fixture cleanup (per-test scope). Also reaps TALLY_FILE (created in the
# functional-subshell section below)
# so an abnormal exit between its mktemp and the manual rm doesn't leak it;
# guarded by -n because it's bound later. The manual rm stays (rm -f is idempotent).
_TMPFIX=""
TALLY_FILE=""
_cleanup_tmpfix() {
  if [ -n "$_TMPFIX" ]; then
    rm -f "$_TMPFIX"
  fi
  if [ -n "$TALLY_FILE" ]; then
    rm -f "$TALLY_FILE"
  fi
}
trap _cleanup_tmpfix EXIT

echo "== Positive: claude --bg three-arm dispatch case-switch (lib/dispatch.sh) =="
assert_grep "$DISPATCH_LIB" \
  'case "\$BG_PROMPT_MODE" in' \
  "_uberdev_dispatch_claude_bg contains BG_PROMPT_MODE case-switch"
assert_grep "$DISPATCH_LIB" \
  'cmd\+?=\( claude --bg \)' \
  "_uberdev_dispatch_claude_bg builds the shared claude --bg invocation"
assert_grep "$DISPATCH_LIB" \
  '\-\-prompt-file "\$PROMPT_FILE"' \
  "claude-bg file arm reads \$PROMPT_FILE via --prompt-file"
assert_grep "$DISPATCH_LIB" \
  '< "\$PROMPT_FILE"' \
  "claude-bg stdin arm streams \$PROMPT_FILE on FD 0"
assert_grep "$DISPATCH_LIB" \
  'cmd=\( "\$TIMEOUT_BIN"' \
  "claude-bg argv arm uses bash array (no eval)"
assert_grep "$DISPATCH_LIB" \
  '"\$\{cmd\[@\]\}"' \
  "claude-bg argv arm expands the array via \"\${cmd[@]}\""
assert_grep "$DISPATCH_LIB" \
  '\-\-worktree "solve-issue-\$ISSUE_NUM\$INSTANCE_SUFFIX"' \
  "claude-bg arm scopes each isolated worktree to the routed child instance"
CLAUDE_BG_BODY="$(awk '/^_uberdev_dispatch_claude_bg\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s\n' "$CLAUDE_BG_BODY" | grep -Fq '_uberdev_dispatch_with_git_metadata_mutex' \
    && printf '%s\n' "$CLAUDE_BG_BODY" | grep -Fq '[ "$BG_WORKSPACE_MODE" = isolated ]'; then
  echo "  PASS  isolated Claude bootstrap is mutex-scoped while caller mode remains provider-direct"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude --bg --worktree bootstrap bypasses or overextends the Git metadata mutex"
  FAIL=$((FAIL + 1))
fi
if python3 -I -B - "$DISPATCH_LIB" <<'PY'
import sys
source=open(sys.argv[1],encoding="utf-8").read()
body=source.split("_uberdev_dispatch_claude_bg() {",1)[1].split("\n}",1)[0]
case=body.split('case "$BG_PROMPT_MODE" in',1)[1]
launch=case.rsplit('if [[ "$DISPATCH_RC" -eq 0 ]]',1)[0]
assert launch.count("_uberdev_dispatch_with_git_metadata_mutex")==1,launch
assert launch.index("_uberdev_dispatch_with_git_metadata_mutex") > launch.index("esac")
PY
then
  echo "  PASS  all three Claude prompt modes converge on one bounded bootstrap mutex"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude prompt modes do not converge on one bounded bootstrap mutex"
  FAIL=$((FAIL + 1))
fi

echo "== Positive: --effort=<level> threaded into claude --bg (v0.22.1) =="
# Regression: prior to v0.22.1, /turbo and /solve dispatched `claude --bg`
# without any --effort flag — `claude --bg` 2.1.139 does NOT inherit the
# parent session's effort, so every bg spawn fell back to the supervised
# daemon's default (silent quality downgrade for /turbo). The Phase A
# parser + EFFORT_FLAG hoist + threaded case arms close that gap; the
# assertions below lock the contract in.
assert_grep "$SOLVE_SKILL" \
  '^\| `EFFORT_LEVEL_DEFAULT` \| `max`' \
  "Constants table declares EFFORT_LEVEL_DEFAULT = max (autopilot default)"
assert_grep "$SOLVE_SKILL" \
  '^\| `EFFORT_LEVEL_ENUM` \| `low \\\| medium \\\| high \\\| xhigh \\\| max \\\| ultra`' \
  "Public effort enum includes Codex-only ultra; Claude legacy effort remains five values"
assert_grep "$SOLVE_PIPELINE" \
  'effort_resolved' \
  "SOLVE_AUDIT_EVENT_ENUM contains effort_resolved (Phase A telemetry)"
assert_grep "$SOLVE_PIPELINE" \
  "EFFORT_FLAG_VALUE=.*grep -oE .\\\\-\\\\-effort=\\[a-z\\]\\+" \
  "Phase A parses --effort=<level> from \$ARGUMENTS"
assert_grep "$SOLVE_PIPELINE" \
  'UBERDEV_SOLVE_EFFORT' \
  "Phase A honours UBERDEV_SOLVE_EFFORT env override"
assert_grep "$SOLVE_PIPELINE" \
  'uberdev_read_enum solve_effort UBERDEV_SOLVE_EFFORT' \
  "Phase A reads solve_effort from .claude/uberdev.local.md via uberdev_read_enum"
assert_grep "$DISPATCH_LIB" \
  '^[[:space:]]*EFFORT_FLAG=\( --effort "\$EFFORT_LEVEL" \)$' \
  "uberdev_dispatch_resolve_env binds EFFORT_FLAG as a bash+zsh array — scalar form regresses to a one-slot \`--effort max\` argv element under zsh SH_WORD_SPLIT=off (v0.22.2 fix)"
assert_grep "$DISPATCH_LIB" \
  '^[[:space:]]*PERM_FLAG=\(\)$' \
  "uberdev_dispatch_resolve_env binds PERM_FLAG as an empty bash+zsh array — same zsh-word-split rationale as EFFORT_FLAG (v0.22.2 fix)"
# Structural floor for the PERM_FLAG resolver: the count==2 assertion below is the
# canonical "both opt-in tiers populate the bypass-pair literal" check. Pair it with
# the negative regression guard ("--permission-mode auto MUST NOT appear at runtime")
# to catch both regression directions.
# Count: 2 occurrences expected — the SKIP branch (line ~196) and the AUTO branch
# (line ~198) of uberdev_dispatch_resolve_env. Asserts that AUTO did not regress
# back to --permission-mode auto and that the if/elif structure is preserved for
# audit-log observability.
# #246 (post-#243 follow-up): --dangerously-skip-permissions bypasses permission *checks*
# but does NOT set --permission-mode; without an explicit --permission-mode the bg session
# UI cycle defaults to `auto`, which silently breaks Search and other agent tools. Pair the
# two flags so the cycle-ring lands on bypassPermissions AND the checks are short-circuited.
perm_flag_count=$(grep -c 'PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )' "$DISPATCH_LIB")
if [ "$perm_flag_count" -eq 2 ]; then
  echo "  PASS  dispatch.sh has 2 PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions ) sites (SKIP + AUTO branches, both pair the danger-skip + bypass-mode)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  dispatch.sh has $perm_flag_count PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions ) sites (expected exactly 2 — SKIP + AUTO branches; #246 fix)"
  FAIL=$((FAIL + 1))
fi
# Regression guard #246: the bare `--dangerously-skip-permissions` form (without the
# `--permission-mode bypassPermissions` companion) must NOT appear as a PERM_FLAG
# assignment at runtime. The bg-session UI cycle defaults to `auto` when no
# --permission-mode is set, which silently breaks Search/etc. — see issue #246.
bare_skip_count=$(grep -cE '^[[:space:]]*PERM_FLAG=\( --dangerously-skip-permissions \)[[:space:]]*$' "$DISPATCH_LIB")
if [ "$bare_skip_count" -eq 0 ]; then
  echo "  PASS  dispatch.sh has no bare PERM_FLAG=( --dangerously-skip-permissions ) assignments — #246 pair-with-bypass regression guard intact"
  PASS=$((PASS + 1))
else
  echo "  FAIL  dispatch.sh has $bare_skip_count bare PERM_FLAG=( --dangerously-skip-permissions ) assignments — must be paired with --permission-mode bypassPermissions (#246)"
  FAIL=$((FAIL + 1))
fi
# Regression guard: --permission-mode auto MUST NOT appear in the runtime resolver
# (doc comments mentioning the historical mapping are fine; the executable PERM_FLAG=
# assignment regressed in the past and the test catches a re-introduction).
if grep -qE '^[[:space:]]*PERM_FLAG=\( --permission-mode auto \)' "$DISPATCH_LIB"; then
  echo "  FAIL  dispatch.sh re-introduced PERM_FLAG=( --permission-mode auto ) — auto-mode is dead in practice (post-#241 follow-up); both branches must yield --dangerously-skip-permissions --permission-mode bypassPermissions"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  dispatch.sh does NOT assign PERM_FLAG=( --permission-mode auto ) at runtime (auto-mode-collapse regression guard intact)"
  PASS=$((PASS + 1))
fi
assert_grep "$DISPATCH_LIB" \
  'BG_TURBO_ENV\+=\( SKIP_PERMISSIONS=1 \)' \
  "BG_TURBO_ENV propagates SKIP_PERMISSIONS to nested child dispatches (#241)"
# #304 / RFC 0012 §3.4: the #241 hygiene unset moved INSIDE the launcher
# process (the shell profile re-injects SKIP_PERMISSIONS into every fresh
# fence, so a command-file fence unset protected nothing).
assert_grep "$SOLVE_PIPELINE" 'unset SKIP_PERMISSIONS' \
  "T-no-skip (#241 pollution defence — launcher unsets SKIP_PERMISSIONS in-process; stale /goal export cannot elevate /solve or bare /turbo)"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_audit_emit effort_resolved' \
  "Phase A emits effort_resolved audit event with {source, level}"
assert_grep "$SOLVE_PIPELINE" \
  'low\|medium\|high\|xhigh\|max\|ultra' \
  "Phase A validates the six-value provider-neutral public enum"
assert_grep "$SOLVE_PIPELINE" \
  'ultra is Codex-only' \
  "Claude-backed resolution rejects public ultra before claims"
WINDOWS_PATH_TMP="$(mktemp -d)"
mkdir "$WINDOWS_PATH_TMP/bin"
cat >"$WINDOWS_PATH_TMP/bin/cygpath" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CYGPATH_LOG"
[ "$1" = -m ] || exit 2
printf 'C:/native-temp\n'
SH
chmod +x "$WINDOWS_PATH_TMP/bin/cygpath"
WINDOWS_TMP_BLOCK="$(awk '/^_UBERDEV_TMP_BASE=/{capture=1} capture&&/^if ! UBERDEV_TMPDIR=/{exit} capture{print}' "$SOLVE_PIPELINE")"
WINDOWS_NORMALIZED="$(MSYSTEM=MINGW64 CYGPATH_LOG="$WINDOWS_PATH_TMP/cygpath.log" PATH="$WINDOWS_PATH_TMP/bin:$PATH" TMPDIR=/tmp/posix-temp \
  bash -c "$WINDOWS_TMP_BLOCK
printf '%s' \"\$_UBERDEV_TMP_BASE\"")"
if [ "$WINDOWS_NORMALIZED" = 'C:/native-temp' ] \
   && grep -q '^-m /tmp/posix-temp$' "$WINDOWS_PATH_TMP/cygpath.log"; then
  echo "  PASS  Git Bash temp base is normalized for native Windows Python"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Git Bash temp base was not normalized for native Windows Python"
  FAIL=$((FAIL + 1))
fi
rm -rf "$WINDOWS_PATH_TMP"
WINDOWS_STAGING_TMP="$(mktemp -d)"
WINDOWS_STAGING_BASE="$WINDOWS_STAGING_TMP"
case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
  MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
    WINDOWS_STAGING_BASE="$(cygpath -m "$WINDOWS_STAGING_TMP")"
    ;;
esac
if python3 -I -B - "$SOLVE_PIPELINE" "$WINDOWS_STAGING_BASE" <<'PY'
import contextlib
import io
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
base = pathlib.Path(sys.argv[2]).resolve()
base.chmod(0o700)
prefix = "if ! UBERDEV_TMPDIR=\"$(python3 -I -B -c '\n"
suffix = "\n' \"$_UBERDEV_TMP_BASE\")\"; then"
start = source.index(prefix) + len(prefix)
end = source.index(suffix, start)
snippet = source[start:end]
if hasattr(os, "geteuid"):
    del os.geteuid
sys.argv = ["embedded-staging", str(base)]
stdout = io.StringIO()
with contextlib.redirect_stdout(stdout):
    exec(compile(snippet, "solve-launcher-staging", "exec"), {})
created = pathlib.Path(stdout.getvalue())
assert created.parent == base
assert created.name.startswith("uberdev-solve-windows-")
if os.name != "nt":
    assert stat.S_IMODE(created.stat().st_mode) == 0o700
created.rmdir()
PY
then
  echo "  PASS  solve staging works when Python has no os.geteuid (native Windows)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  solve staging requires unavailable os.geteuid on native Windows"
  FAIL=$((FAIL + 1))
fi
rm -rf "$WINDOWS_STAGING_TMP"
ULTRA_TMP="$(mktemp -d)"; mkdir "$ULTRA_TMP/bin"
cat >"$ULTRA_TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$ULTRA_GH_LOG"
case "$1 $2" in
  "repo view") echo owner/repo ;;
  "issue view") echo '{"number":91,"title":"README typo","state":"OPEN","body":"Fix typo in README.md.","labels":[{"name":"docs"}],"assignees":[],"comments":[]}' ;;
  *) exit 3 ;;
esac
SH
cat >"$ULTRA_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$ULTRA_CLAUDE_LOG"
exit 99
SH
chmod +x "$ULTRA_TMP/bin/gh" "$ULTRA_TMP/bin/claude"
if PATH="$ULTRA_TMP/bin:$PATH" ULTRA_GH_LOG="$ULTRA_TMP/gh.log" ULTRA_CLAUDE_LOG="$ULTRA_TMP/claude.log" \
  TMPDIR="$ULTRA_TMP" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$SOLVE_PIPELINE" --auto-mode=0 -- 91 --backend=claude-bg --effort=ultra >"$ULTRA_TMP/out" 2>&1; then
  ULTRA_RC=0
else
  ULTRA_RC=$?
fi
if [ "$ULTRA_RC" -ne 0 ] && grep -q 'ultra is Codex-only' "$ULTRA_TMP/out" \
    && ! grep -q '^label create' "$ULTRA_TMP/gh.log" && [ ! -e "$ULTRA_TMP/claude.log" ]; then
  echo "  PASS  Claude Ultra fails behaviorally before claim or dispatch mutation"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude Ultra must fail before claims (rc=$ULTRA_RC output=$(cat "$ULTRA_TMP/out"))"
  FAIL=$((FAIL + 1))
fi
rm -rf "$ULTRA_TMP"
# All three prompt modes converge after `esac`, where the optional permission
# and effort arrays are appended with explicit length guards. This both keeps
# every mode on one flag path and avoids Bash 3.2 `set -u` aborts when an array
# is empty. The array-quoted form (not the prior unquoted scalar form) remains
# mandatory under zsh.
if python3 -I -B - "$DISPATCH_LIB" <<'PY'
import sys
source=open(sys.argv[1],encoding="utf-8").read()
body=source.split("_uberdev_dispatch_claude_bg() {",1)[1].split("\n}",1)[0]
case=body.split('case "$BG_PROMPT_MODE" in',1)[1]
after=case.split("esac",1)[1]
perm='[ "${#PERM_FLAG[@]}" -eq 0 ] || cmd+=( "${PERM_FLAG[@]}" )'
effort='[ "${#EFFORT_FLAG[@]}" -eq 0 ] || cmd+=( "${EFFORT_FLAG[@]}" )'
assert body.count(perm)==1,body
assert body.count(effort)==1,body
assert after.index(perm) < after.index(effort),after
PY
then
  echo "  PASS  all three dispatch arms converge on nounset-safe permission and effort argv"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude prompt arms do not converge on nounset-safe permission and effort argv"
  FAIL=$((FAIL + 1))
fi
# Tombstone: the v0.22.1 scalar form `$PERM_FLAG $EFFORT_FLAG` (no braces,
# no quotes) must NOT reappear. A regression to that form would re-trigger
# the v0.22.1 zsh dispatch failure that v0.22.2 fixed.
# `grep -c` prints a single number (0 when no matches, N otherwise) and
# exits rc=0 on matches, rc=1 on zero matches, rc>=2 on regex/IO error.
# We capture rc explicitly so that rc>=2 (regex error or unreadable file)
# loudly fails the test instead of silently coercing to "0" and producing
# a false PASS. The previous form `$(... 2>/dev/null; true)` masked ALL
# non-zero exits including rc=2, defeating the regression-guard purpose.
# Load-bearing regex suffix: `[^[]` at the end requires a non-`[` character
# after `EFFORT_FLAG`, which prevents false-matching the new array form
# `${EFFORT_FLAG[@]}` (literal `$EFFORT_FLAG` followed by `[`). Removing
# this suffix in a "simplification" pass would make the tombstone fire on
# the correct array form and turn every run into a false FAIL — do not
# delete without re-deriving an equivalent anchor.
SCALAR_RELAPSE_COUNT="$(grep -cE '\$PERM_FLAG \$EFFORT_FLAG[^[]' "$DISPATCH_LIB" 2>/dev/null)" || GREP_RC=$?
GREP_RC="${GREP_RC:-0}"
if [[ "$GREP_RC" -ge 2 ]]; then
  echo "  FAIL  grep exited rc=$GREP_RC on $SOLVE_PIPELINE — test harness broken (regex error or file unreadable)"
  FAIL=$((FAIL + 1))
elif [[ "${SCALAR_RELAPSE_COUNT:-0}" -eq 0 ]]; then
  echo "  PASS  no scalar-form \`\$PERM_FLAG \$EFFORT_FLAG\` relapse (v0.22.2 regression guard)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  found $SCALAR_RELAPSE_COUNT scalar-form \`\$PERM_FLAG \$EFFORT_FLAG\` instances — these break under zsh (v0.22.2 fixed this)"
  FAIL=$((FAIL + 1))
fi
unset GREP_RC
assert_grep "$DISPATCH_LIB" \
  "sed -E \\\$'s/" \
  "claude-bg backend pre-strips ANSI CSI escapes from \$BG_STDOUT_LOG (#143 fix)"
assert_grep "$DISPATCH_LIB" \
  '\^backgrounded · \[0-9a-f\]\{8\}\$' \
  "claude-bg backend uses line-anchored marker grep (#143 OSC/DCS defense-in-depth)"
assert_grep "$DISPATCH_LIB" \
  'DISPATCH_ID="\$\{DISPATCH_ID//\[\^0-9a-f\]/\}"' \
  "claude-bg backend hex-only scrub locks \$DISPATCH_ID to /^[0-9a-f]{8}\$/ contract"
assert_grep "$DISPATCH_LIB" \
  '\[ "\$\{#DISPATCH_ID\}" -eq 8 \]' \
  "claude-bg backend length check enforces exactly-8-hex id post-scrub"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_claude_bg\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_claude_bg function"

echo
echo "== #175: uberdev_dispatch_resolve_env SSOT helper (structural) =="
assert_grep "$DISPATCH_LIB" \
  '^uberdev_dispatch_resolve_env\(\)' \
  "#175 — uberdev_dispatch_resolve_env function is defined in lib/dispatch.sh"
assert_grep "$DISPATCH_LIB" \
  "MODEL='claude-opus-4-8\[1m\]'" \
  "#175 — helper sets MODEL single-quoted (blocks zsh [1m] glob)"
assert_grep "$DISPATCH_LIB" \
  'if \[\[ -n "\$TIMEOUT_BIN" \]\]; then' \
  "#175 — helper carries the verbatim fail-loud TIMEOUT_BIN guard (config-override I2f shape)"
assert_grep "$DISPATCH_LIB" \
  'brew install coreutils' \
  "#175 — helper carries the brew install coreutils remediation pointer"
# AC3: the env resolver must never read or write the backend var (that is preflight's).
RESOLVE_BODY="$(awk '/^uberdev_dispatch_resolve_env\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s' "$RESOLVE_BODY" | grep -q 'UBERDEV_RESOLVED_BACKEND'; then
  echo "  FAIL  #175 — resolve_env must NOT reference UBERDEV_RESOLVED_BACKEND (D15)"; FAIL=$((FAIL + 1))
else
  echo "  PASS  #175 — resolve_env does not reference UBERDEV_RESOLVED_BACKEND (D15)"; PASS=$((PASS + 1))
fi

echo "== Functional: id_extract rc capture + subphase discriminator (#154) =="
# These cases SOURCE lib/dispatch.sh and drive _uberdev_dispatch_claude_bg with
# stubs, asserting on the captured dispatch_setup_failed / agent_dispatched
# audit payloads. Distinct from the assert_grep shape-checks above; both styles
# coexist. Each case runs in a SUBSHELL so stub funcs and the _UBERDEV_DISPATCH_LOADED
# source-guard never leak between cases.
TALLY_FILE="$(mktemp)"   # subshell PASS/FAIL hand-off (see read-back idiom per case)

assert_contains() {
  # assert_contains "<haystack>" "<needle>" "<desc>"
  local hay="$1" needle="$2" desc="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        wanted substring: $needle"; echo "        in: $hay"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  # assert_not_contains "<haystack>" "<needle>" "<desc>"
  local hay="$1" needle="$2" desc="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        must NOT contain: $needle"; echo "        in: $hay"
    FAIL=$((FAIL + 1))
  fi
}

(
  set +u   # bash 3.2 (macOS system bash) treats empty-array expansions as unbound under set -u
  UBERDEV_TMPDIR="$(mktemp -d)"
  # Fixture-seed: the function computes BG_STDOUT_LOG="${UBERDEV_TMPDIR}/solve-bg-stdout-<issue>.log"
  # internally (dispatch.sh:187), so we pre-seed exactly that path. No production change.
  printf 'Agent starting...\nbackgrounded · abc12345\n' > "$UBERDEV_TMPDIR/solve-bg-stdout-7.log"
  declare -a AUDIT_EVENTS=()
  _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }   # "<event> <json>"
  timeout() { shift; "$@"; }          # drop the duration arg, exec the rest
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }  # strip VAR=val prefixes
  claude() { printf 'backgrounded · abc12345\n'; return 0; }
  TIMEOUT_BIN="timeout"; SOLVE_TIMEOUT=1; MODEL="sonnet"
  PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE="file"
  PROMPT_FILE="$UBERDEV_TMPDIR/prompt.txt"; printf 'do the thing\n' > "$PROMPT_FILE"
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  _uberdev_dispatch_claude_bg 7 medium "$PROMPT_FILE"
  rc=$?
  joined="${AUDIT_EVENTS[*]}"
  [[ "$rc" -eq 0 ]] && echo "  PASS  happy path returns 0" && PASS=$((PASS + 1)) || { echo "  FAIL  happy path returns 0 (got $rc)"; FAIL=$((FAIL + 1)); }
  [[ "$DISPATCH_ID" == "abc12345" ]] && echo "  PASS  happy path extracts DISPATCH_ID=abc12345" && PASS=$((PASS + 1)) || { echo "  FAIL  happy path DISPATCH_ID (got '$DISPATCH_ID')"; FAIL=$((FAIL + 1)); }
  assert_contains "$joined" "agent_dispatched" "happy path emits agent_dispatched"
  assert_not_contains "$joined" "dispatch_setup_failed" "happy path does NOT emit dispatch_setup_failed"
  assert_contains "$joined" '"tier":"medium"' "happy path agent_dispatched carries tier=medium"
  assert_contains "$joined" '"backend":"claude-bg"' "happy path agent_dispatched carries backend=claude-bg"
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo "== Empty optional argv is nounset-safe in actual Claude providers =="
CLAUDE_NOUNSET_TMP="$(mktemp -d)"
mkdir -p "$CLAUDE_NOUNSET_TMP/caller"
printf 'nounset provider prompt\n' >"$CLAUDE_NOUNSET_TMP/prompt.txt"
CLAUDE_NOUNSET_SHELLS=( /bin/bash "$(command -v bash)" )
CLAUDE_NOUNSET_SEEN=''
CLAUDE_NOUNSET_INDEX=0
for CLAUDE_NOUNSET_SHELL in "${CLAUDE_NOUNSET_SHELLS[@]}"; do
  [ -x "$CLAUDE_NOUNSET_SHELL" ] || continue
  CLAUDE_NOUNSET_REAL="$(cd "$(dirname "$CLAUDE_NOUNSET_SHELL")" && pwd -P)/$(basename "$CLAUDE_NOUNSET_SHELL")"
  case " $CLAUDE_NOUNSET_SEEN " in *" $CLAUDE_NOUNSET_REAL "*) continue ;; esac
  CLAUDE_NOUNSET_SEEN="$CLAUDE_NOUNSET_SEEN $CLAUDE_NOUNSET_REAL"
  CLAUDE_NOUNSET_INDEX=$((CLAUDE_NOUNSET_INDEX + 1))
  CLAUDE_NOUNSET_VERSION="$($CLAUDE_NOUNSET_SHELL --version | head -1)"
  for CLAUDE_NOUNSET_MODE in file stdin argv; do
    case "$CLAUDE_NOUNSET_MODE" in file) CLAUDE_NOUNSET_ISSUE=343 ;; stdin) CLAUDE_NOUNSET_ISSUE=344 ;; *) CLAUDE_NOUNSET_ISSUE=345 ;; esac
    CLAUDE_NOUNSET_CASE="$CLAUDE_NOUNSET_TMP/$CLAUDE_NOUNSET_INDEX-$CLAUDE_NOUNSET_MODE"
    mkdir -p "$CLAUDE_NOUNSET_CASE/runtime"
    : >"$CLAUDE_NOUNSET_CASE/provider.log"
    set +e
    CLAUDE_NOUNSET_OUT="$($CLAUDE_NOUNSET_SHELL -c '
      set -u
      timeout() { shift; "$@"; }
      env() { while [[ "${1:-}" == *=* ]]; do shift; done; "$@"; }
      claude() {
        printf "%s\n" "$*" >>"$PROVIDER_LOG"
        printf "backgrounded · a11ce335\n"
      }
      . "$1"
      TIMEOUT_BIN=timeout
      SOLVE_TIMEOUT=9
      MODEL=sonnet
      AUTO_MODE=0
      SKIP_PERMISSIONS=0
      AUTO_PERMISSIONS=0
      PERM_FLAG=()
      EFFORT_FLAG=()
      BG_PROMPT_MODE="$2"
      UBERDEV_AGENT_WORKSPACE_MODE=caller
      UBERDEV_AGENT_WORKSPACE_DIR="$3"
      UBERDEV_TMPDIR="$4"
      PROVIDER_LOG="$5"
      DISPATCH_RC=0
      DISPATCH_ID=""
      DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg "$6" medium "$7"
      rc=$?
      [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = a11ce335 ] \
        && [ "$(wc -l <"$PROVIDER_LOG" | tr -d " ")" -eq 1 ]
    ' _ "$DISPATCH_LIB" "$CLAUDE_NOUNSET_MODE" "$CLAUDE_NOUNSET_TMP/caller" \
      "$CLAUDE_NOUNSET_CASE/runtime" "$CLAUDE_NOUNSET_CASE/provider.log" \
      "$CLAUDE_NOUNSET_ISSUE" "$CLAUDE_NOUNSET_TMP/prompt.txt" 2>&1)"
    CLAUDE_NOUNSET_RC=$?
    set +e
    if [ "$CLAUDE_NOUNSET_RC" -eq 0 ]; then
      echo "  PASS  Claude $CLAUDE_NOUNSET_MODE mode accepts empty optional argv under set -u on $CLAUDE_NOUNSET_VERSION"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  Claude $CLAUDE_NOUNSET_MODE nounset contract on $CLAUDE_NOUNSET_VERSION: $CLAUDE_NOUNSET_OUT"
      FAIL=$((FAIL + 1))
    fi
  done
done
rm -rf "$CLAUDE_NOUNSET_TMP"

echo "== Claude stdin fail-closed contract on Bash 3.2 and Bash 5 =="
CLAUDE_STDIN_TMP="$(mktemp -d)"
CLAUDE_SHELLS=( /bin/bash "$(command -v bash)" )
CLAUDE_SEEN_SHELLS=''
CLAUDE_SHELL_INDEX=0
for CLAUDE_SHELL in "${CLAUDE_SHELLS[@]}"; do
  [ -x "$CLAUDE_SHELL" ] || continue
  CLAUDE_SHELL_REAL="$(cd "$(dirname "$CLAUDE_SHELL")" && pwd -P)/$(basename "$CLAUDE_SHELL")"
  case " $CLAUDE_SEEN_SHELLS " in *" $CLAUDE_SHELL_REAL "*) continue ;; esac
  CLAUDE_SEEN_SHELLS="$CLAUDE_SEEN_SHELLS $CLAUDE_SHELL_REAL"
  CLAUDE_SHELL_INDEX=$((CLAUDE_SHELL_INDEX + 1))
  CLAUDE_SHELL_LABEL="$($CLAUDE_SHELL --version | head -1)"
  for CLAUDE_STDIN_CASE in missing redirection-failure; do
    CASE_DIR="$CLAUDE_STDIN_TMP/${CLAUDE_STDIN_CASE}-$CLAUDE_SHELL_INDEX"
    mkdir -p "$CASE_DIR/runtime"
    : >"$CASE_DIR/provider.log"
    PROMPT_CASE="$CASE_DIR/prompt.txt"
    if [ "$CLAUDE_STDIN_CASE" = redirection-failure ]; then
      # chmod 000 is advisory on Git Bash/Windows, and Cygwin can reopen a
      # write-only descriptor through /dev/fd with read access. A closed FD
      # has no backing handle to reopen, so this is a deterministic shell-level
      # redirection-open failure on Bash 3.2, Bash 5, and Git Bash.
      PROMPT_CASE=/dev/fd/9
      if "$CLAUDE_SHELL" -c 'exec < /dev/fd/9' 9>&- >/dev/null 2>&1; then
        echo "  FAIL  redirection-failure fixture unexpectedly opened a closed FD on $CLAUDE_SHELL_LABEL"
        FAIL=$((FAIL + 1))
        continue
      fi
    fi
    set +e
    CLAUDE_STDIN_RESULT="$($CLAUDE_SHELL -c '
      set +u
      UBERDEV_TMPDIR="$2/runtime"
      PROVIDER_LOG="$2/provider.log"
      MUTEX_SENTINEL="$2/mutex-held"
      timeout() { shift; "$@"; }
      env() { while [[ "${1:-}" == *=* ]]; do shift; done; "$@"; }
      claude() { printf "provider-launched\n" >>"$PROVIDER_LOG"; printf "backgrounded · bad00001\n"; }
      TIMEOUT_BIN=timeout; SOLVE_TIMEOUT=9; MODEL=sonnet
      PERM_FLAG=( --permission-mode default ); EFFORT_FLAG=( --effort medium )
      BG_PROMPT_MODE=stdin; DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      . "$1"
      _uberdev_dispatch_with_git_metadata_mutex() {
        shift
        [ "${1:-}" = claude-bootstrap ] && shift
        : >"$MUTEX_SENTINEL"
        "$@"; mutex_command_rc=$?
        rm -f "$MUTEX_SENTINEL"
        return "$mutex_command_rc"
      }
      _uberdev_dispatch_claude_bg 337 medium "$3"
      rc=$?
      printf "rc=%s provider=%s mutex=%s\n" "$rc" \
        "$(wc -l <"$PROVIDER_LOG" 2>/dev/null || printf 0)" \
        "$([ -e "$MUTEX_SENTINEL" ] && printf held || printf clear)"
      [ "$rc" -ne 0 ] && [ ! -s "$PROVIDER_LOG" ] && [ ! -e "$MUTEX_SENTINEL" ]
    ' _ "$DISPATCH_LIB" "$CASE_DIR" "$PROMPT_CASE" 9>&- 2>&1)"
    CLAUDE_STDIN_RC=$?
    set +e
    if [ "$CLAUDE_STDIN_RC" -eq 0 ]; then
      echo "  PASS  $CLAUDE_STDIN_CASE stdin is terminal before provider/mutex leak on $CLAUDE_SHELL_LABEL"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $CLAUDE_STDIN_CASE stdin contract on $CLAUDE_SHELL_LABEL: $CLAUDE_STDIN_RESULT"
      FAIL=$((FAIL + 1))
    fi
  done
done
rm -rf "$CLAUDE_STDIN_TMP"

echo "== Claude bootstrap timeout and release-failure handle preservation =="
CLAUDE_TIMEOUT_CONTRACT="$(bash -c '
  . "$1"
  unset UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT
  printf "default=%s capped=%s " \
    "$(_uberdev_dispatch_claude_bootstrap_timeout 120)" \
    "$(_uberdev_dispatch_claude_bootstrap_timeout 20)"
  UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=7
  printf "configured=%s" "$(_uberdev_dispatch_claude_bootstrap_timeout 120)"
' _ "$DISPATCH_LIB")"
if [ "$CLAUDE_TIMEOUT_CONTRACT" = 'default=60 capped=20 configured=7' ]; then
  echo "  PASS  Claude bootstrap timeout defaults to 60s, caps to solve timeout, and accepts a shorter override"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude bootstrap timeout resolution: $CLAUDE_TIMEOUT_CONTRACT"
  FAIL=$((FAIL + 1))
fi
CLAUDE_TIMEOUT_VALIDATION_ERRORS=''
for CLAUDE_TIMEOUT_SHELL in /bin/bash "$(command -v bash)"; do
  [ -x "$CLAUDE_TIMEOUT_SHELL" ] || continue
  CLAUDE_TIMEOUT_MATRIX="$($CLAUDE_TIMEOUT_SHELL -c '
    set -u
    . "$1"
    huge=999999999999999999999999999999999999999999999999999999999999
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT="$huge"
    huge_config="$(_uberdev_dispatch_claude_bootstrap_timeout 86400)" || exit 10
    unset UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT
    huge_solve="$(_uberdev_dispatch_claude_bootstrap_timeout "$huge")" || exit 11
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=0
    _uberdev_dispatch_claude_bootstrap_timeout 100 >/dev/null 2>&1; zero_rc=$?
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=not-a-number
    _uberdev_dispatch_claude_bootstrap_timeout 100 >/dev/null 2>&1; invalid_rc=$?
    printf "huge_config=%s huge_solve=%s zero=%s invalid=%s" \
      "$huge_config" "$huge_solve" "$zero_rc" "$invalid_rc"
  ' _ "$DISPATCH_LIB" 2>&1)"
  [ "$CLAUDE_TIMEOUT_MATRIX" = 'huge_config=300 huge_solve=60 zero=2 invalid=2' ] \
    || CLAUDE_TIMEOUT_VALIDATION_ERRORS="$CLAUDE_TIMEOUT_VALIDATION_ERRORS [$CLAUDE_TIMEOUT_SHELL:$CLAUDE_TIMEOUT_MATRIX]"
done
if [ -z "$CLAUDE_TIMEOUT_VALIDATION_ERRORS" ]; then
  echo "  PASS  bootstrap timeout rejects invalid/zero and safely caps huge decimals on Bash 3.2 and Bash 5"
  PASS=$((PASS + 1))
else
  echo "  FAIL  bootstrap timeout overflow contract:$CLAUDE_TIMEOUT_VALIDATION_ERRORS"
  FAIL=$((FAIL + 1))
fi
CLAUDE_QUARANTINE_FAILURES="$(/bin/bash -c '
  set -u
  . "$1"
  _uberdev_semaphore_quarantine_mutex() { return 37; }
  root="$(mktemp -d)"

  ownerless="$root/ownerless"; mkdir -p "$ownerless/.mutex"; chmod 700 "$ownerless/.mutex"
  _uberdev_semaphore_mutex_reclaim_dead "$ownerless" 1; ownerless_rc=$?

  invalid="$root/invalid"; mkdir -p "$invalid/.mutex"; chmod 700 "$invalid/.mutex"
  printf "invalid\n\nnot-a-token\n" >"$invalid/.mutex/owner_pid"; chmod 600 "$invalid/.mutex/owner_pid"
  _uberdev_semaphore_mutex_reclaim_dead "$invalid" 1; invalid_rc=$?

  published="$root/published"; mkdir -p "$published/.mutex"; chmod 700 "$published/.mutex"
  printf "99999999\n\ndead-token\n" >"$published/.mutex/owner_pid"; chmod 600 "$published/.mutex/owner_pid"
  _uberdev_semaphore_mutex_reclaim_dead "$published" published; published_rc=$?
  printf "ownerless=%s invalid=%s published=%s" "$ownerless_rc" "$invalid_rc" "$published_rc"
' _ "$DISPATCH_LIB")"
if [ "$CLAUDE_QUARANTINE_FAILURES" = 'ownerless=37 invalid=37 published=37' ]; then
  echo "  PASS  ownerless, invalid-owner, and published-dead reclaim preserve quarantine failure rc"
  PASS=$((PASS + 1))
else
  echo "  FAIL  quarantine failure rc preservation: $CLAUDE_QUARANTINE_FAILURES"
  FAIL=$((FAIL + 1))
fi
CLAUDE_OWNERLESS_TURNOVER="$(/bin/bash -c '
  set -u
  . "$1"
  root="$(mktemp -d)"
  vanished="$root/vanished"
  mkdir -p "$vanished/.mutex"
  chmod 700 "$vanished/.mutex"
  _uberdev_semaphore_path_identity() {
    rmdir "$1" || return 2
    return 2
  }
  _uberdev_semaphore_mutex_reclaim_ownerless_generation "$vanished" "1:1"
  vanished_rc=$?
  if [ ! -e "$vanished/.mutex" ] && [ ! -L "$vanished/.mutex" ]; then absent=1; else absent=0; fi

  present="$root/present"
  mkdir -p "$present/.mutex"
  chmod 700 "$present/.mutex"
  _uberdev_semaphore_path_identity() { return 2; }
  _uberdev_semaphore_mutex_reclaim_ownerless_generation "$present" "1:1"
  present_rc=$?
  if [ -d "$present/.mutex" ] && [ ! -L "$present/.mutex" ]; then retained=1; else retained=0; fi
  printf "vanished=%s absent=%s present=%s retained=%s" \
    "$vanished_rc" "$absent" "$present_rc" "$retained"
' _ "$DISPATCH_LIB")"
if [ "$CLAUDE_OWNERLESS_TURNOVER" = 'vanished=1 absent=1 present=2 retained=1' ]; then
  echo "  PASS  ownerless exact-generation reclaim distinguishes benign turnover from an unstatable live path"
  PASS=$((PASS + 1))
else
  echo "  FAIL  ownerless vanish-before-identity turnover: $CLAUDE_OWNERLESS_TURNOVER"
  FAIL=$((FAIL + 1))
fi
CLAUDE_OWNERLESS_PROBE_CHURN="$(/bin/bash -c '
  set -u
  . "$1"
  root="$(mktemp -d)"
  mkdir -p "$root/.mutex"
  chmod 700 "$root/.mutex"
  identity_writes=0
  _uberdev_semaphore_write_process_identity() {
    identity_writes=$((identity_writes + 1))
    return 2
  }
  UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 UBERDEV_SEMAPHORE_MUTEX_QUIET_BUSY=1 \
    UBERDEV_SEMAPHORE_MUTEX_PROBE_ONLY=1 \
    _uberdev_semaphore_mutex_acquire "$root"
  rc=$?
  printf "rc=%s writes=%s state=%s" "$rc" "$identity_writes" \
    "${_UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE:-unknown}"
' _ "$DISPATCH_LIB")"
if [ "$CLAUDE_OWNERLESS_PROBE_CHURN" = 'rc=75 writes=0 state=ownerless' ]; then
  echo "  PASS  busy Claude probe observes ownerless state without preparing a contender identity"
  PASS=$((PASS + 1))
else
  echo "  FAIL  busy Claude probe performed contender churn: $CLAUDE_OWNERLESS_PROBE_CHURN"
  FAIL=$((FAIL + 1))
fi
CLAUDE_SLOW_PROBE_TMP="$(mktemp -d)"
CLAUDE_SLOW_PROBE_START="$(python3 -I -B -c 'import time; print(time.monotonic())')"
set +e
CLAUDE_SLOW_PROBE_OUT="$(/bin/bash -c '
  set -u
  . "$1"
  POST_IMPL_REVIEW_CAP=1; REVIEW_EXPECTED_COUNT=1
  SLOW_ROOT="$2"
  _UBERDEV_GIT_METADATA_MUTEX_PUBLICATION_GRACE_S=0
  _UBERDEV_GIT_METADATA_MUTEX_WALL_PROBE_ALLOWANCE_S=0
  _uberdev_semaphore_mutex_acquire() {
    calls="$(cat "$SLOW_ROOT/calls" 2>/dev/null || printf 0)"
    calls=$((calls + 1)); printf "%s\n" "$calls" >"$SLOW_ROOT/calls"
    command sleep 0.25
    _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE=published-live
    _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_IDENTITY=fixture
    return 75
  }
  sleep() { return 0; }
  _uberdev_dispatch_git_metadata_mutex_acquire "$2/scope" claude-bootstrap 1
' _ "$DISPATCH_LIB" "$CLAUDE_SLOW_PROBE_TMP" 2>&1)"
CLAUDE_SLOW_PROBE_RC=$?
set +e
CLAUDE_SLOW_PROBE_END="$(python3 -I -B -c 'import time; print(time.monotonic())')"
CLAUDE_SLOW_PROBE_CALLS="$(cat "$CLAUDE_SLOW_PROBE_TMP/calls" 2>/dev/null || printf 0)"
if [ "$CLAUDE_SLOW_PROBE_RC" -eq 75 ] && [ "$CLAUDE_SLOW_PROBE_CALLS" -le 10 ] \
    && [[ "$CLAUDE_SLOW_PROBE_OUT" == *'acquisition timed out for claude-bootstrap'* ]] \
    && python3 -I -B - "$CLAUDE_SLOW_PROBE_START" "$CLAUDE_SLOW_PROBE_END" <<'PY'
import sys
elapsed=float(sys.argv[2])-float(sys.argv[1])
assert 1.0 <= elapsed < 3.2, elapsed
PY
then
  echo "  PASS  slow probe overhead is bounded independently of scheduled publication-grace ticks"
  PASS=$((PASS + 1))
else
  echo "  FAIL  slow-probe wall bound (rc=$CLAUDE_SLOW_PROBE_RC calls=$CLAUDE_SLOW_PROBE_CALLS elapsed=$(python3 -I -B -c "print(float('$CLAUDE_SLOW_PROBE_END')-float('$CLAUDE_SLOW_PROBE_START'))") out=$CLAUDE_SLOW_PROBE_OUT)"
  FAIL=$((FAIL + 1))
fi
rm -rf "$CLAUDE_SLOW_PROBE_TMP"
CLAUDE_BOOT_TMP="$(mktemp -d)"
git init -q "$CLAUDE_BOOT_TMP/repo"
mkdir -p "$CLAUDE_BOOT_TMP/bin" "$CLAUDE_BOOT_TMP/runtime-bound" "$CLAUDE_BOOT_TMP/runtime-release" \
  "$CLAUDE_BOOT_TMP/runtime-serial-first" "$CLAUDE_BOOT_TMP/runtime-serial-second" \
  "$CLAUDE_BOOT_TMP/runtime-publish-waiter" "$CLAUDE_BOOT_TMP/runtime-abandoned"
cat >"$CLAUDE_BOOT_TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >>"$CLAUDE_PROVIDER_LOG"
case "${CLAUDE_PROVIDER_MODE:-hang}" in
  marker) printf 'backgrounded · c0de335a\n' ;;
  serial)
    if ! mkdir "$CLAUDE_SERIAL_SENTINEL" 2>/dev/null; then
      printf 'split-owner %s\n' "$UBERDEV_AGENT_INSTANCE_ID" >>"$CLAUDE_SERIAL_LOG"
      exit 91
    fi
    trap 'rmdir "$CLAUDE_SERIAL_SENTINEL"' EXIT
    printf 'enter %s\n' "$UBERDEV_AGENT_INSTANCE_ID" >>"$CLAUDE_SERIAL_LOG"
    sleep 0.35
    printf 'exit %s\n' "$UBERDEV_AGENT_INSTANCE_ID" >>"$CLAUDE_SERIAL_LOG"
    case "$UBERDEV_AGENT_INSTANCE_ID" in
      serial-first) printf 'backgrounded · 11111111\n' ;;
      serial-second) printf 'backgrounded · 22222222\n' ;;
      *) exit 92 ;;
    esac
    ;;
  *) sleep 30 ;;
esac
SH
chmod +x "$CLAUDE_BOOT_TMP/bin/claude"
CLAUDE_TIMEOUT_BIN="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null)"
printf 'bootstrap bound\n' >"$CLAUDE_BOOT_TMP/prompt.txt"
# Exit 124 proves the dedicated provider timeout fired. Keep elapsed time as a
# whole-call hang watchdog only: native Windows may spend additional time
# tearing down the timed-out Cygwin process tree after the one-second deadline.
CLAUDE_BOUND_WATCHDOG_S=7
CLAUDE_BOUND_START="$(python3 -I -B -c 'import time; print(time.monotonic())')"
set +e
(
  cd "$CLAUDE_BOOT_TMP/repo" || exit 1
  PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_LOG="$CLAUDE_BOOT_TMP/bound-provider.log" \
    UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-bound" UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=1 \
    bash -c '
      set +u
      . "$1"
      TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
      PERM_FLAG=( --permission-mode default ); EFFORT_FLAG=( --effort medium )
      BG_PROMPT_MODE=file; DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg 338 medium "$3"
    ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
)
CLAUDE_BOUND_RC=$?
set +e
CLAUDE_BOUND_END="$(python3 -I -B -c 'import time; print(time.monotonic())')"
CLAUDE_BOUND_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLAUDE_BOOT_TMP/repo")"
if python3 -I -B - "$CLAUDE_BOUND_START" "$CLAUDE_BOUND_END" "$CLAUDE_BOUND_WATCHDOG_S" <<'PY'
import sys
assert float(sys.argv[2])-float(sys.argv[1]) < float(sys.argv[3])
PY
then
  CLAUDE_BOUND_ELAPSED_OK=1
else
  CLAUDE_BOUND_ELAPSED_OK=0
fi
if [ "$CLAUDE_BOUND_RC" -eq 124 ] && [ "$CLAUDE_BOUND_ELAPSED_OK" -eq 1 ] \
    && [ -s "$CLAUDE_BOOT_TMP/bound-provider.log" ] \
    && [ ! -e "$CLAUDE_BOUND_SCOPE/.mutex" ]; then
  echo "  PASS  hung Claude bootstrap is bounded by its dedicated timeout and releases the mutex"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude bootstrap bound (rc=$CLAUDE_BOUND_RC watchdog=$CLAUDE_BOUND_WATCHDOG_S elapsed=$(python3 -I -B -c "print(float('$CLAUDE_BOUND_END')-float('$CLAUDE_BOUND_START'))"))"
  FAIL=$((FAIL + 1))
fi

# Reproduce the production starvation shape without a five-second fixture:
# shorten the generic mutex policy to one ownership-safe attempt, then hold the first
# real Claude provider bootstrap for 350ms. The Claude-specific policy must use
# the actual enforced two-child wave size, wait outside the provider critical
# section, and let the second dispatch acquire the same mutex generation only
# after the first releases it.
CLAUDE_SERIAL_LOG="$CLAUDE_BOOT_TMP/serial.log"
CLAUDE_SERIAL_SENTINEL="$CLAUDE_BOOT_TMP/serial-owner"
CLAUDE_SERIAL_READY_DEADLINE_S=5
: >"$CLAUDE_SERIAL_LOG"
(
  cd "$CLAUDE_BOOT_TMP/repo" || exit 1
  PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_MODE=serial \
    CLAUDE_SERIAL_LOG="$CLAUDE_SERIAL_LOG" CLAUDE_SERIAL_SENTINEL="$CLAUDE_SERIAL_SENTINEL" \
    UBERDEV_AGENT_INSTANCE_ID=serial-first UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-serial-first" \
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=2 UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 \
    POST_IMPL_REVIEW_CAP=2 REVIEW_EXPECTED_COUNT=2 \
    /bin/bash -c '
      set -u
      . "$1"
      TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
      PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE=file
      DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg 347 medium "$3"
      rc=$?
      [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = 11111111 ]
    ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
) >"$CLAUDE_BOOT_TMP/serial-first.out" 2>&1 &
CLAUDE_SERIAL_FIRST_PID=$!
CLAUDE_SERIAL_READY=0
CLAUDE_SERIAL_READY_REASON=deadline
CLAUDE_SERIAL_READY_STARTED="$SECONDS"
while [ ! -d "$CLAUDE_SERIAL_SENTINEL" ] \
    && [ $((SECONDS - CLAUDE_SERIAL_READY_STARTED)) -lt "$CLAUDE_SERIAL_READY_DEADLINE_S" ]; do
  if ! kill -0 "$CLAUDE_SERIAL_FIRST_PID" 2>/dev/null; then
    CLAUDE_SERIAL_READY_REASON=first-exited
    break
  fi
  sleep 0.01
done
if [ -d "$CLAUDE_SERIAL_SENTINEL" ] && kill -0 "$CLAUDE_SERIAL_FIRST_PID" 2>/dev/null; then
  CLAUDE_SERIAL_READY=1
  CLAUDE_SERIAL_READY_REASON=ready
  (
    cd "$CLAUDE_BOOT_TMP/repo" || exit 1
    PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_MODE=serial \
      CLAUDE_SERIAL_LOG="$CLAUDE_SERIAL_LOG" CLAUDE_SERIAL_SENTINEL="$CLAUDE_SERIAL_SENTINEL" \
      UBERDEV_AGENT_INSTANCE_ID=serial-second UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-serial-second" \
      UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=2 UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 \
      POST_IMPL_REVIEW_CAP=2 REVIEW_EXPECTED_COUNT=2 \
      /bin/bash -c '
        set -u
        . "$1"
        TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
        PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE=file
        DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
        _uberdev_dispatch_claude_bg 348 medium "$3"
        rc=$?
        [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = 22222222 ]
      ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
  ) >"$CLAUDE_BOOT_TMP/serial-second.out" 2>&1 &
  CLAUDE_SERIAL_SECOND_PID=$!
fi
CLAUDE_SERIAL_READY_ELAPSED_S=$((SECONDS - CLAUDE_SERIAL_READY_STARTED))
wait "$CLAUDE_SERIAL_FIRST_PID"; CLAUDE_SERIAL_FIRST_RC=$?
if [ "$CLAUDE_SERIAL_READY" -eq 1 ]; then
  wait "$CLAUDE_SERIAL_SECOND_PID"; CLAUDE_SERIAL_SECOND_RC=$?
else
  CLAUDE_SERIAL_SECOND_RC=not-launched
fi
CLAUDE_SERIAL_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLAUDE_BOOT_TMP/repo")"
CLAUDE_SERIAL_SCOPE_DEBRIS=0
for CLAUDE_SERIAL_DEBRIS_PATH in \
    "$CLAUDE_SERIAL_SCOPE"/.mutex-candidate.* "$CLAUDE_SERIAL_SCOPE"/.mutex.quarantine.*; do
  if [ -e "$CLAUDE_SERIAL_DEBRIS_PATH" ] || [ -L "$CLAUDE_SERIAL_DEBRIS_PATH" ]; then
    CLAUDE_SERIAL_SCOPE_DEBRIS=1
  fi
done
if [ "$CLAUDE_SERIAL_READY" -ne 1 ]; then
  echo "  FAIL  concurrent Claude fixture readiness (reason=$CLAUDE_SERIAL_READY_REASON deadline=${CLAUDE_SERIAL_READY_DEADLINE_S}s waited=${CLAUDE_SERIAL_READY_ELAPSED_S}s first=$CLAUDE_SERIAL_FIRST_RC second=$CLAUDE_SERIAL_SECOND_RC)"
  FAIL=$((FAIL + 1))
elif [ "$CLAUDE_SERIAL_FIRST_RC" -eq 0 ] && [ "$CLAUDE_SERIAL_SECOND_RC" -eq 0 ] \
    && [ "$(cat "$CLAUDE_SERIAL_LOG")" = $'enter serial-first\nexit serial-first\nenter serial-second\nexit serial-second' ] \
    && [ ! -e "$CLAUDE_SERIAL_SCOPE/.mutex" ] \
    && [ ! -e "$CLAUDE_SERIAL_SENTINEL" ] \
    && [ "$CLAUDE_SERIAL_SCOPE_DEBRIS" -eq 0 ]
then
  echo "  PASS  concurrent slow Claude bootstraps wait within the enforced wave budget without split ownership"
  PASS=$((PASS + 1))
else
  echo "  FAIL  concurrent Claude bootstrap serialization (first=$CLAUDE_SERIAL_FIRST_RC second=$CLAUDE_SERIAL_SECOND_RC sentinel=$(test -e "$CLAUDE_SERIAL_SENTINEL" && printf present || printf absent) debris=$CLAUDE_SERIAL_SCOPE_DEBRIS log=$(tr '\n' '|' <"$CLAUDE_SERIAL_LOG"))"
  FAIL=$((FAIL + 1))
fi

# Deterministic publication-race regression. The original owner pauses after
# creating `.mutex` but before atomically linking `owner_pid`. A Claude waiter
# must observe that exact unpublished generation without quarantining it or
# launching the provider. Once publication/release completes, the same waiter
# proceeds normally.
CLAUDE_PUBLISH_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLAUDE_BOOT_TMP/repo")"
CLAUDE_PUBLISH_PAUSED="$CLAUDE_BOOT_TMP/publish-paused"
CLAUDE_PUBLISH_CONTINUE="$CLAUDE_BOOT_TMP/publish-continue"
CLAUDE_PUBLISH_ACQUIRED="$CLAUDE_BOOT_TMP/publish-acquired"
CLAUDE_PUBLISH_PROVIDER_LOG="$CLAUDE_BOOT_TMP/publish-provider.log"
UBERDEV_SEMAPHORE_TESTING=1 \
  UBERDEV_SEMAPHORE_TEST_PAUSE_AFTER_MKDIR="$CLAUDE_PUBLISH_PAUSED" \
  UBERDEV_SEMAPHORE_TEST_CONTINUE_FILE="$CLAUDE_PUBLISH_CONTINUE" \
  /bin/bash -c '
    set -u
    . "$1"
    _uberdev_semaphore_mutex_acquire "$2" || exit $?
    printf "acquired\n" >"$3"
    sleep 0.20
    _uberdev_semaphore_mutex_release "$2"
  ' _ "$DISPATCH_LIB" "$CLAUDE_PUBLISH_SCOPE" "$CLAUDE_PUBLISH_ACQUIRED" \
  >"$CLAUDE_BOOT_TMP/publish-holder.out" 2>&1 &
CLAUDE_PUBLISH_HOLDER_PID=$!
CLAUDE_PUBLISH_READY_TRIES=0
while [ ! -s "$CLAUDE_PUBLISH_PAUSED" ] && [ "$CLAUDE_PUBLISH_READY_TRIES" -lt 200 ]; do
  CLAUDE_PUBLISH_READY_TRIES=$((CLAUDE_PUBLISH_READY_TRIES + 1))
  sleep 0.01
done
CLAUDE_PUBLISH_IDENTITY_BEFORE="$(bash -c '. "$1"; _uberdev_semaphore_path_identity "$2/.mutex"' \
  _ "$DISPATCH_LIB" "$CLAUDE_PUBLISH_SCOPE" 2>/dev/null || true)"
(
  cd "$CLAUDE_BOOT_TMP/repo" || exit 1
  PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_LOG="$CLAUDE_PUBLISH_PROVIDER_LOG" \
    CLAUDE_PROVIDER_MODE=marker UBERDEV_AGENT_INSTANCE_ID=publish-waiter \
    UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-publish-waiter" \
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT=2 UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 \
    POST_IMPL_REVIEW_CAP=1 REVIEW_EXPECTED_COUNT=1 \
    /bin/bash -c '
      set -u
      . "$1"
      TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
      PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE=file
      DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg 349 medium "$3"
      rc=$?
      [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = c0de335a ]
    ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
) >"$CLAUDE_BOOT_TMP/publish-waiter.out" 2>&1 &
CLAUDE_PUBLISH_WAITER_PID=$!
sleep 0.30
CLAUDE_PUBLISH_IDENTITY_DURING="$(bash -c '. "$1"; _uberdev_semaphore_path_identity "$2/.mutex"' \
  _ "$DISPATCH_LIB" "$CLAUDE_PUBLISH_SCOPE" 2>/dev/null || true)"
CLAUDE_PUBLISH_NOT_STOLEN=0
if [ -n "$CLAUDE_PUBLISH_IDENTITY_BEFORE" ] \
    && [ "$CLAUDE_PUBLISH_IDENTITY_DURING" = "$CLAUDE_PUBLISH_IDENTITY_BEFORE" ] \
    && [ ! -s "$CLAUDE_PUBLISH_PROVIDER_LOG" ] \
    && kill -0 "$CLAUDE_PUBLISH_WAITER_PID" 2>/dev/null; then
  CLAUDE_PUBLISH_NOT_STOLEN=1
fi
: >"$CLAUDE_PUBLISH_CONTINUE"
wait "$CLAUDE_PUBLISH_HOLDER_PID"; CLAUDE_PUBLISH_HOLDER_RC=$?
wait "$CLAUDE_PUBLISH_WAITER_PID"; CLAUDE_PUBLISH_WAITER_RC=$?
if [ "$CLAUDE_PUBLISH_NOT_STOLEN" -eq 1 ] \
    && [ "$CLAUDE_PUBLISH_HOLDER_RC" -eq 0 ] && [ "$CLAUDE_PUBLISH_WAITER_RC" -eq 0 ] \
    && [ -s "$CLAUDE_PUBLISH_ACQUIRED" ] \
    && [ "$(wc -l <"$CLAUDE_PUBLISH_PROVIDER_LOG" | tr -d ' ')" -eq 1 ] \
    && [ ! -e "$CLAUDE_PUBLISH_SCOPE/.mutex" ]; then
  echo "  PASS  Claude waiter preserves an in-flight unpublished mutex generation then proceeds after release"
  PASS=$((PASS + 1))
else
  CLAUDE_PUBLISH_INTERNAL_LOG="$(find "$CLAUDE_BOOT_TMP/runtime-publish-waiter" -name 'solve-bg-stdout-349-*.log' -type f -print | head -1)"
  echo "  FAIL  Claude waiter stole or stalled the publish window (safe=$CLAUDE_PUBLISH_NOT_STOLEN holder=$CLAUDE_PUBLISH_HOLDER_RC waiter=$CLAUDE_PUBLISH_WAITER_RC before=$CLAUDE_PUBLISH_IDENTITY_BEFORE during=$CLAUDE_PUBLISH_IDENTITY_DURING waiter_out=$(tr '\n' '|' <"$CLAUDE_BOOT_TMP/publish-waiter.out") provider=$(test ! -e "$CLAUDE_PUBLISH_PROVIDER_LOG" || tr '\n' '|' <"$CLAUDE_PUBLISH_PROVIDER_LOG") internal=$(test -z "$CLAUDE_PUBLISH_INTERNAL_LOG" || tr '\n' '|' <"$CLAUDE_PUBLISH_INTERNAL_LOG"))"
  FAIL=$((FAIL + 1))
fi

# An ownerless generation can also be genuinely abandoned. Require the exact
# same generation to remain stable through the publication grace window before
# reclaiming it; this prevents permanent deadlock without weakening the race
# protection above.
CLAUDE_ABANDONED_OPERATION_TIMEOUT_S=1
CLAUDE_ABANDONED_QUEUE_SLOTS=1
CLAUDE_ABANDONED_PUBLICATION_GRACE_S=1
CLAUDE_ABANDONED_WALL_PROBE_ALLOWANCE_S=2
# The runtime's acquisition wall budget ends before candidate preparation and
# provider bootstrap. Allow those phases, the deliberate identity-write delay,
# and Windows scheduler variance three additional seconds in this whole-call
# watchdog; cadence instrumentation below proves the grace policy itself.
CLAUDE_ABANDONED_WHOLE_CALL_MARGIN_S=3
CLAUDE_ABANDONED_ACQUISITION_WALL_BUDGET_S=$((
  CLAUDE_ABANDONED_OPERATION_TIMEOUT_S * CLAUDE_ABANDONED_QUEUE_SLOTS
  + CLAUDE_ABANDONED_PUBLICATION_GRACE_S
  + CLAUDE_ABANDONED_WALL_PROBE_ALLOWANCE_S
))
CLAUDE_ABANDONED_WATCHDOG_S=$((
  CLAUDE_ABANDONED_ACQUISITION_WALL_BUDGET_S + CLAUDE_ABANDONED_WHOLE_CALL_MARGIN_S
))
CLAUDE_ABANDONED_CADENCE_LOG="$CLAUDE_BOOT_TMP/abandoned-cadence.log"
mkdir "$CLAUDE_PUBLISH_SCOPE/.mutex"
chmod 700 "$CLAUDE_PUBLISH_SCOPE/.mutex"
CLAUDE_ABANDONED_START="$(python3 -I -B -c 'import time; print(time.monotonic())')"
set +e
(
  cd "$CLAUDE_BOOT_TMP/repo" || exit 1
  PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_LOG="$CLAUDE_BOOT_TMP/abandoned-provider.log" \
    CLAUDE_ABANDONED_CADENCE_LOG="$CLAUDE_ABANDONED_CADENCE_LOG" \
    CLAUDE_PROVIDER_MODE=marker UBERDEV_AGENT_INSTANCE_ID=abandoned-waiter \
    UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-abandoned" \
    UBERDEV_CLAUDE_BOOTSTRAP_TIMEOUT="$CLAUDE_ABANDONED_OPERATION_TIMEOUT_S" \
    UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 POST_IMPL_REVIEW_CAP="$CLAUDE_ABANDONED_QUEUE_SLOTS" \
    REVIEW_EXPECTED_COUNT="$CLAUDE_ABANDONED_QUEUE_SLOTS" \
    /bin/bash -c '
      set -u
      . "$1"
      eval "$(declare -f _uberdev_semaphore_write_process_identity \
        | sed "1s/_uberdev_semaphore_write_process_identity/_uberdev_semaphore_write_process_identity_without_delay/")"
      _uberdev_semaphore_write_process_identity() {
        command sleep 0.25
        _uberdev_semaphore_write_process_identity_without_delay "$@"
      }
      sleep() {
        printf "%s\n" "$1" >>"$CLAUDE_ABANDONED_CADENCE_LOG" || return 2
        command sleep "$@"
      }
      TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
      PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE=file
      DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg 350 medium "$3"
      rc=$?
      [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = c0de335a ]
    ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
)
CLAUDE_ABANDONED_RC=$?
set +e
CLAUDE_ABANDONED_END="$(python3 -I -B -c 'import time; print(time.monotonic())')"
CLAUDE_ABANDONED_POLICY_OK=0
if python3 -I -B - "$CLAUDE_ABANDONED_START" "$CLAUDE_ABANDONED_END" \
    "$CLAUDE_ABANDONED_WATCHDOG_S" "$CLAUDE_ABANDONED_CADENCE_LOG" <<'PY'
import sys

(started, ended, watchdog, path) = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    observed = stream.read().splitlines()
# Eight 50ms/one-tick waits plus six 100ms/two-tick waits reach the configured
# 20-tick publication grace without relying on scheduler wall time.
assert observed == ["0.05"] * 8 + ["0.10"] * 6, observed
assert 8 * 1 + 6 * 2 == 1 * 20
elapsed=float(ended)-float(started)
assert elapsed < float(watchdog), elapsed
PY
then
  CLAUDE_ABANDONED_POLICY_OK=1
fi
CLAUDE_ABANDONED_SCOPE_DEBRIS=0
for CLAUDE_ABANDONED_DEBRIS_PATH in \
    "$CLAUDE_PUBLISH_SCOPE"/.mutex-candidate.* "$CLAUDE_PUBLISH_SCOPE"/.mutex.quarantine.*; do
  if [ -e "$CLAUDE_ABANDONED_DEBRIS_PATH" ] || [ -L "$CLAUDE_ABANDONED_DEBRIS_PATH" ]; then
    CLAUDE_ABANDONED_SCOPE_DEBRIS=1
  fi
done
if [ "$CLAUDE_ABANDONED_RC" -eq 0 ] && [ ! -e "$CLAUDE_PUBLISH_SCOPE/.mutex" ] \
    && [ "$CLAUDE_ABANDONED_SCOPE_DEBRIS" -eq 0 ] \
    && [ "$(wc -l <"$CLAUDE_BOOT_TMP/abandoned-provider.log" | tr -d ' ')" -eq 1 ] \
    && [ "$CLAUDE_ABANDONED_POLICY_OK" -eq 1 ]
then
  echo "  PASS  stable abandoned ownerless mutex is reclaimed only after publication grace"
  PASS=$((PASS + 1))
else
  echo "  FAIL  abandoned ownerless mutex recovery (rc=$CLAUDE_ABANDONED_RC policy=$CLAUDE_ABANDONED_POLICY_OK debris=$CLAUDE_ABANDONED_SCOPE_DEBRIS watchdog=$CLAUDE_ABANDONED_WATCHDOG_S elapsed=$(python3 -I -B -c "print(float('$CLAUDE_ABANDONED_END')-float('$CLAUDE_ABANDONED_START'))"))"
  FAIL=$((FAIL + 1))
fi

set +e
CLAUDE_RELEASE_RESULT="$({
  cd "$CLAUDE_BOOT_TMP/repo" || exit 1
  PATH="$CLAUDE_BOOT_TMP/bin:$PATH" CLAUDE_PROVIDER_LOG="$CLAUDE_BOOT_TMP/release-provider.log" \
    CLAUDE_PROVIDER_MODE=marker UBERDEV_TMPDIR="$CLAUDE_BOOT_TMP/runtime-release" \
    bash -c '
      set +u
      . "$1"
      _uberdev_semaphore_mutex_release() { return 31; }
      TIMEOUT_BIN="$2"; SOLVE_TIMEOUT=4; MODEL=sonnet
      PERM_FLAG=( --permission-mode default ); EFFORT_FLAG=( --effort medium )
      BG_PROMPT_MODE=file; DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
      _uberdev_dispatch_claude_bg 339 medium "$3"
      printf "rc=%s id=%s\n" "$?" "$DISPATCH_ID"
    ' _ "$DISPATCH_LIB" "$CLAUDE_TIMEOUT_BIN" "$CLAUDE_BOOT_TMP/prompt.txt"
} 2>&1)"
CLAUDE_RELEASE_COMMAND_RC=$?
set +e
CLAUDE_RELEASE_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLAUDE_BOOT_TMP/repo")"
set +e
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 bash -c \
  '. "$1"; POST_IMPL_REVIEW_CAP=1; REVIEW_EXPECTED_COUNT=1; _uberdev_dispatch_git_metadata_mutex_acquire "$2" claude-bootstrap 1 && _uberdev_semaphore_mutex_release "$2"' \
  _ "$DISPATCH_LIB" "$CLAUDE_RELEASE_SCOPE"
CLAUDE_RELEASE_RECLAIM_RC=$?
set +e
if [ "$CLAUDE_RELEASE_COMMAND_RC" -eq 0 ] \
    && [[ "$CLAUDE_RELEASE_RESULT" == *'rc=0 id=c0de335a'* ]] \
    && grep -Fq 'release failed after claude-bootstrap (rc=31)' \
      "$CLAUDE_BOOT_TMP/runtime-release/solve-bg-stdout-339.log" \
    && [ "$(wc -l <"$CLAUDE_BOOT_TMP/release-provider.log" | tr -d ' ')" -eq 1 ] \
    && [ "$CLAUDE_RELEASE_RECLAIM_RC" -eq 0 ] \
    && [ ! -e "$CLAUDE_RELEASE_SCOPE/.mutex" ]; then
  echo "  PASS  Claude release failure preserves the strict marker handle and dead-owner reclaim"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude release-failure handle contract: result=$CLAUDE_RELEASE_RESULT reclaim=$CLAUDE_RELEASE_RECLAIM_RC"
  FAIL=$((FAIL + 1))
fi
rm -rf "$CLAUDE_BOOT_TMP"

(
  set +u
  UBERDEV_TMPDIR="$(mktemp -d)"
  CALLER_DIR="$UBERDEV_TMPDIR/caller"
  CALL_LOG="$UBERDEV_TMPDIR/claude-calls.log"
  MUTEX_LOG="$UBERDEV_TMPDIR/mutex-calls.log"
  mkdir -p "$CALLER_DIR"
  : > "$CALL_LOG"
  : > "$MUTEX_LOG"
  declare -a AUDIT_EVENTS=()
  _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  timeout() { shift; "$@"; }
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }
  claude() {
    printf '%s\n' "$*" >> "$CALL_LOG"
    printf 'backgrounded · c011ab1e\n'
    return 0
  }
  TIMEOUT_BIN="timeout"; SOLVE_TIMEOUT=1; MODEL="sonnet"
  PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE="file"
  PROMPT_FILE="$UBERDEV_TMPDIR/prompt.txt"; printf 'use caller workspace\n' > "$PROMPT_FILE"
  UBERDEV_AGENT_WORKSPACE_MODE=caller
  UBERDEV_AGENT_WORKSPACE_DIR="$CALLER_DIR"
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  _uberdev_dispatch_with_git_metadata_mutex() {
    printf 'unexpected\n' >> "$MUTEX_LOG"
    return 99
  }
  _uberdev_dispatch_claude_bg 335 medium "$PROMPT_FILE"
  rc=$?
  calls="$(cat "$CALL_LOG")"
  if [ "$rc" -eq 0 ] && [ "$DISPATCH_ID" = c011ab1e ] \
      && [ ! -s "$MUTEX_LOG" ] \
      && [[ "$calls" != *--worktree* ]]; then
    echo "  PASS  caller-mode Claude dispatch bypasses metadata mutex and provider worktree creation"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  caller-mode Claude dispatch contract (rc=$rc id=$DISPATCH_ID calls=$calls)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

(
  set +u
  UBERDEV_TMPDIR="$(mktemp -d)"
  CALL_LOG="$UBERDEV_TMPDIR/claude-calls.log"
  : > "$CALL_LOG"
  declare -a AUDIT_EVENTS=()
  _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  timeout() { shift; "$@"; }
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }
  claude() {
    printf '%s|%s\n' "$UBERDEV_AGENT_INSTANCE_ID" "$*" >> "$CALL_LOG"
    printf 'backgrounded · %08x\n' "$CLAUDE_CHILD_INDEX"
  }
  TIMEOUT_BIN="timeout"; SOLVE_TIMEOUT=1; MODEL="sonnet"
  PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE="file"
  PROMPT_FILE="$UBERDEV_TMPDIR/prompt.txt"; printf 'review the change\n' > "$PROMPT_FILE"
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  fanout_errors=""
  for CLAUDE_CHILD_INDEX in 1 2 3 4 5 6; do
    UBERDEV_AGENT_INSTANCE_ID="post-review-six-child-r${CLAUDE_CHILD_INDEX}-iter1-attempt01"
    export UBERDEV_AGENT_INSTANCE_ID CLAUDE_CHILD_INDEX
    child_slug="$(_uberdev_dispatch_instance_slug)"
    if ! _uberdev_dispatch_claude_bg 336 medium "$PROMPT_FILE"; then
      fanout_errors="$fanout_errors dispatch-$CLAUDE_CHILD_INDEX"
      continue
    fi
    expected_handle="$(printf '%08x' "$CLAUDE_CHILD_INDEX")"
    expected_log="$UBERDEV_TMPDIR/solve-bg-stdout-336-$child_slug.log"
    [ "$DISPATCH_ID" = "$expected_handle" ] || fanout_errors="$fanout_errors handle-$CLAUDE_CHILD_INDEX"
    [ -s "$expected_log" ] || fanout_errors="$fanout_errors log-$CLAUDE_CHILD_INDEX"
    grep -Fq -- "--worktree solve-issue-336-$child_slug" "$CALL_LOG" \
      || fanout_errors="$fanout_errors worktree-$CLAUDE_CHILD_INDEX"
  done
  [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 6 ] || fanout_errors="$fanout_errors call-count"
  [ "$(find "$UBERDEV_TMPDIR" -name 'solve-bg-stdout-336-*.log' | wc -l | tr -d ' ')" -eq 6 ] \
    || fanout_errors="$fanout_errors log-count"
  if uberdev_dispatch_preflight_backend background review-pr >/dev/null 2>&1 \
      || uberdev_dispatch_preflight_backend wezterm review-pr >/dev/null 2>&1; then
    fanout_errors="$fanout_errors unsupported-review-backend"
  fi
  if [ -z "$fanout_errors" ]; then
    echo "  PASS  six Claude reviewers receive unique worktrees and stdout logs before fanout"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  six Claude reviewer isolation:$fanout_errors"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

(
  set +u   # bash 3.2 (macOS system bash) treats empty-array expansions as unbound under set -u
  UBERDEV_TMPDIR="$(mktemp -d)"
  printf 'Agent starting...\nrunning...\n' > "$UBERDEV_TMPDIR/solve-bg-stdout-8.log"
  declare -a AUDIT_EVENTS=()
  _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  timeout() { shift; "$@"; }
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }
  claude() { printf 'Agent starting...\nrunning...\n'; return 0; }   # no marker
  TIMEOUT_BIN="timeout"; SOLVE_TIMEOUT=1; MODEL="sonnet"
  PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE="file"
  PROMPT_FILE="$UBERDEV_TMPDIR/prompt.txt"; printf 'x\n' > "$PROMPT_FILE"
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  _uberdev_dispatch_claude_bg 8 medium "$PROMPT_FILE"
  rc=$?
  joined="${AUDIT_EVENTS[*]}"
  [[ "$rc" -eq 2 ]] && echo "  PASS  marker_absent returns 2" && PASS=$((PASS + 1)) || { echo "  FAIL  marker_absent returns 2 (got $rc)"; FAIL=$((FAIL + 1)); }
  [[ -z "$DISPATCH_ID" ]] && echo "  PASS  marker_absent stamps DISPATCH_ID empty" && PASS=$((PASS + 1)) || { echo "  FAIL  marker_absent DISPATCH_ID not empty (got '$DISPATCH_ID')"; FAIL=$((FAIL + 1)); }
  assert_contains "$joined" "dispatch_setup_failed" "marker_absent emits dispatch_setup_failed"
  assert_contains "$joined" '"phase":"id_extract"' "marker_absent keeps phase=id_extract"
  assert_contains "$joined" '"subphase":"marker_absent"' "marker_absent payload carries subphase=marker_absent"
  assert_contains "$joined" '"rc":2' "marker_absent keeps rc:2 contract"
  assert_contains "$joined" '"mode":"file"' "marker_absent payload carries mode=file"
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

(
  set +u   # bash 3.2 (macOS system bash) treats empty-array expansions as unbound under set -u
  UBERDEV_TMPDIR="$(mktemp -d)"
  SEED_LOG="$UBERDEV_TMPDIR/solve-bg-stdout-9.log"
  printf 'backgrounded · dead0000\n' > "$SEED_LOG"   # content present but read must fail
  chmod 000 "$SEED_LOG" 2>/dev/null || true
  declare -a AUDIT_EVENTS=()
  _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  timeout() { shift; "$@"; }
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }
  claude() { return 0; }   # spawn succeeds; the LOG read is what fails
  TIMEOUT_BIN="timeout"; SOLVE_TIMEOUT=1; MODEL="sonnet"
  PERM_FLAG=(); EFFORT_FLAG=(); BG_PROMPT_MODE="file"
  PROMPT_FILE="$UBERDEV_TMPDIR/prompt.txt"; printf 'x\n' > "$PROMPT_FILE"
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # Root-safe fallback: if chmod 000 won't block the read (root / odd FS),
  # shadow grep to return 2 so the pipeline_error branch is still exercised.
  # On macOS (non-root), chmod 000 blocks both read AND write, so the file-arm
  # redirect to the pre-seeded log fails before grep is even called — the
  # dispatch path is "phase:dispatch rc:1" not "phase:id_extract". We restore
  # the log to 644 so the redirect can succeed, then use grep-shadow to
  # inject rc=2 at grep time, exercising the id_extract/pipeline_error path.
  chmod 644 "$SEED_LOG" 2>/dev/null || true
  grep() { return 2; }
  echo "  NOTE  pipeline_error: using grep-shadow to simulate rc>=2 (chmod-000 blocks redirect on macOS; restored to 644 + grep stub)"
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  _uberdev_dispatch_claude_bg 9 medium "$PROMPT_FILE"
  rc=$?
  joined="${AUDIT_EVENTS[*]}"
  [[ "$rc" -eq 2 ]] && echo "  PASS  pipeline_error returns 2" && PASS=$((PASS + 1)) || { echo "  FAIL  pipeline_error returns 2 (got $rc)"; FAIL=$((FAIL + 1)); }
  [[ -z "$DISPATCH_ID" ]] && echo "  PASS  pipeline_error stamps DISPATCH_ID empty" && PASS=$((PASS + 1)) || { echo "  FAIL  pipeline_error DISPATCH_ID not empty (got '$DISPATCH_ID')"; FAIL=$((FAIL + 1)); }
  assert_contains "$joined" "dispatch_setup_failed" "pipeline_error emits dispatch_setup_failed"
  assert_contains "$joined" '"phase":"id_extract"' "pipeline_error keeps phase=id_extract"
  assert_contains "$joined" '"subphase":"pipeline_error"' "pipeline_error payload carries subphase=pipeline_error"
  assert_contains "$joined" '"rc":2' "pipeline_error keeps rc:2 contract"
  assert_contains "$joined" '"mode":"file"' "pipeline_error payload carries mode=file"
  assert_not_contains "$joined" '"subphase":"marker_absent"' "pipeline_error must NOT mislabel as marker_absent (discriminator differs)"
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

rm -f "$TALLY_FILE"

echo "== Positive: Phase A constants + hardcoded BG_PROMPT_MODE =="
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_require_claude_version "2.1.152"' \
  "Phase A enforces claude --version >= 2.1.152 (hard gate; bumped from 2.1.139 for #246 — --permission-mode bypassPermissions requires 2.1.152+)"
assert_grep "$SOLVE_PIPELINE" \
  'npm i -g @anthropic-ai/claude-code' \
  "version-gate error includes actionable npm install pointer"
assert_grep "$DISPATCH_LIB" \
  '^[[:space:]]*BG_PROMPT_MODE=argv' \
  "uberdev_dispatch_resolve_env hardcodes BG_PROMPT_MODE=argv (probe completed 2026-05-28 against claude-code 2.1.153 via tests/manual/probe-prompt-file-slash-expansion.sh — INDETERMINATE; argv stays canonical per #240 won't-fix)"
assert_grep "$SOLVE_PIPELINE" \
  'TERMINAL_FLAG_DEPRECATED_NOTE' \
  "Constants table defines TERMINAL_FLAG_DEPRECATED_NOTE"
assert_grep "$SOLVE_PIPELINE" \
  '^TERMINAL_FLAG_DEPRECATED_NOTE=' \
  "Phase A binds TERMINAL_FLAG_DEPRECATED_NOTE as a bash variable (B1 regression guard)"
assert_grep "$SOLVE_PIPELINE" \
  'echo "\$TERMINAL_FLAG_DEPRECATED_NOTE" >&2' \
  "deprecation note emitted to stderr on first encounter"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_audit_emit deprecated_flag_used' \
  "deprecated_flag_used audit event recorded"

echo "== Positive: fanout_concurrency.solve_bg + wave-batching =="
assert_grep "$SOLVE_PIPELINE" \
  'uberdev_read_int_in_range fanout_concurrency.solve_bg UBERDEV_FANOUT_SOLVE_BG 1 50 6' \
  "Phase A reads fanout_concurrency.solve_bg with bounds [1,50] default 6"
assert_grep "$SOLVE_PIPELINE" \
  'MAX_PARALLEL_BG_AGENTS' \
  "Phase A binds MAX_PARALLEL_BG_AGENTS shell var"
assert_grep "$SOLVE_PIPELINE" \
  'WAVE_COUNT=\$\(\( \(TOTAL_ISSUES \+ MAX_PARALLEL_BG_AGENTS - 1\) / MAX_PARALLEL_BG_AGENTS \)\)' \
  "Phase B wave-batching computes ceil(N / cap)"
assert_grep "$SOLVE_PIPELINE" \
  'solve_bg_fanout_wave_started' \
  "Phase B emits solve_bg_fanout_wave_started audit event per wave"

echo "== Anti-pattern: no eval / no naive interpolation =="
NONCOMMENT=$(grep -vE '^[[:space:]]*#' "$SOLVE_PIPELINE")
if grep -qE 'claude --bg "\$PROMPT"' <<<"$NONCOMMENT"; then
  echo "  FAIL  claude --bg \"\$PROMPT\" naive interpolation present (security regression)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  no claude --bg \"\$PROMPT\" naive interpolation (claude-bg-arg-injection guard)"
  PASS=$((PASS + 1))
fi
if grep -qE '^[[:space:]]*eval "claude --bg' <<<"$NONCOMMENT"; then
  echo "  FAIL  eval \"claude --bg …\" form present (spec-reviewer finding 1 violated)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  no eval \"claude --bg …\" form (bash array form preserved)"
  PASS=$((PASS + 1))
fi

echo "== Tombstone: Step 3 terminal detection retired =="
assert_grep_not "$SOLVE_PIPELINE" \
  'CMUX_SOCKET_PATH' \
  "CMUX_SOCKET_PATH detection retired (Step 3 deletion)"
assert_grep_not "$SOLVE_PIPELINE" \
  'TERM_PROGRAM.*ghostty|TERM_PROGRAM.*iTerm|TERM_PROGRAM.*Apple_Terminal' \
  "TERM_PROGRAM cascade retired (Step 3 deletion)"
assert_grep_not "$SOLVE_PIPELINE" \
  'REAL_CLAUDE=\$\(' \
  "REAL_CLAUDE PATH walk retired (Step 3 deletion)"

# Fail-loud mktemp wrapper — without this, an mktemp failure leaves _TMPFIX
# empty and the subsequent `printf > ""` silently errors to stderr while
# the test reports a misleading FAIL or false-positive PASS. (#143 review.)
_new_fixture() {
  _TMPFIX="$(mktemp "${TMPDIR:-/tmp}/uberdev-143-XXXXXX")" || {
    echo "  FAIL  mktemp failed (env / disk?) — aborting test" >&2
    FAIL=$((FAIL+1))
    exit 1
  }
}

# Helpers: collapse the 10 runtime fixture blocks into a single-line call.
# Each helper owns the full per-call lifecycle: _new_fixture → write fixture
# bytes → _extract_id → assert → PASS/FAIL bookkeeping → cleanup. The first
# argument is the raw byte sequence passed to `printf '%b'`; the third is
# the human-readable `desc` echoed alongside PASS/FAIL.
_assert_extract_eq() {
  local bytes="$1" expected="$2" desc="$3"
  local got
  _new_fixture
  printf '%b' "$bytes" > "$_TMPFIX"
  got="$(_extract_id "$_TMPFIX")"
  if [[ "$got" == "$expected" ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (got '$got', expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$_TMPFIX"; _TMPFIX=""
}

_assert_extract_empty() {
  local bytes="$1" desc="$2"
  local got
  _new_fixture
  printf '%b' "$bytes" > "$_TMPFIX"
  got="$(_extract_id "$_TMPFIX")"
  if [[ -z "$got" ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (got '$got', expected empty)"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$_TMPFIX"; _TMPFIX=""
}

echo "== Runtime: ANSI-positive extraction (#143) =="
_assert_extract_eq 'backgrounded \xc2\xb7 \x1b[36mb88389ff\x1b[39m\n' \
                   'b88389ff' \
                   'ANSI-decorated marker (\x1B[36m<id>\x1B[39m) extracts to bare 8-hex'
_assert_extract_eq 'backgrounded \xc2\xb7 \x1b[1;36mb88389ff\x1b[0m\n' \
                   'b88389ff' \
                   'compound CSI (\x1B[1;36m<id>\x1B[0m) extracts to bare 8-hex (multi-param strip)'
_assert_extract_eq 'backgrounded \xc2\xb7 b88389ff\n' \
                   'b88389ff' \
                   'bare marker (back-compat with Claude Code 2.1.139) extracts to 8-hex'
_assert_extract_eq 'some preamble\nbackgrounded \xc2\xb7 \x1b[36mb88389ff\x1b[39m\ntrailing noise\n' \
                   'b88389ff' \
                   'mixed-line stdout extracts the first matching marker'
_assert_extract_eq 'backgrounded \xc2\xb7 aaaaaaaa\nbackgrounded \xc2\xb7 bbbbbbbb\n' \
                   'aaaaaaaa' \
                   'multiple markers → head -1 takes the first id'
_assert_extract_empty '\x1b]8;;http://x\x07backgrounded \xc2\xb7 b88389ff\x1b]8;;\x07\n' \
                      'OSC-decorated marker is rejected (line-anchor + CSI-only strip)'
_assert_extract_empty 'backgrounded \xc2\xb7 b8838\n' \
                      'truncated-id (5 hex) yields empty (matches B3 fail-CLOSED path)'
_assert_extract_empty 'backgrounded \xc2\xb7 b88389ffaabbcc\n' \
                      'over-length-id (14 hex) yields empty (locks {8} format contract)'
_assert_extract_empty 'backgrounded \xc2\xb7 B88389FF\n' \
                      'uppercase-hex id yields empty (lowercase-only [0-9a-f] class)'
_assert_extract_empty '' \
                      'empty stdout yields empty (B3 fail-CLOSED path triggers)'

echo "== Runtime: B3 fail-CLOSED guard regression (#143 / RFC 0004 §3.5) =="
_assert_extract_empty 'some unrelated noise\nbackground started but not the marker\nspawn attempted\n' \
                      'missing-marker stdout yields empty (B3 fail-CLOSED guard fires via the empty -z "$DISPATCH_ID" arm; grep rc=1 here, not >=2)'

echo
echo "== #155: TOCTOU symlink-swap / pre-creation hardening (structural) =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_tmp_target_safe\(\) \{' \
  "#155 — _uberdev_dispatch_tmp_target_safe guard helper defined"
assert_grep "$DISPATCH_LIB" \
  'if \[ -L "\$target" \]; then' \
  "#155 — guard rejects a symlink at the predicted path"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_prepare_tmp_target "\$BG_STDOUT_LOG" "\$ISSUE_NUM" "claude-bg"' \
  "#155 — claude-bg backend guards BG_STDOUT_LOG before the redirect sites"
assert_grep "$DISPATCH_LIB" \
  'umask 077; set -C; : > "\$target"' \
  "#155 — prepare creates target 0600 under noclobber (closes the guard->create race)"
assert_grep "$DISPATCH_LIB" \
  'pid_target_unsafe' \
  "#155 — background backend re-verifies \$STATUS_FILE.pid ownership before parsing"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_prepare_tmp_target "\$LOG_FILE" "\$ISSUE_NUM" "wezterm"' \
  "#155 (review) — wezterm backend also guards its identical predictable LOG_FILE path"
assert_grep "$DISPATCH_LIB" \
  'if \[ -z "\$owner_uid" \]; then' \
  "#155 (review) — guard fails CLOSED when ownership is undeterminable (empty owner_uid, e.g. minimal stat)"

echo
echo "== #155: fail-CLOSED behaviour (runtime regression fixture) =="
# Spec-acceptance fixture: pre-creating a symlink at the predicted path MUST
# cause the guard to fail-CLOSED (non-zero) rather than write through it; a
# clean path passes; prepare creates 0600 and fail-closes (rc=3) on a symlink.
# `set +eu`: CI runs test scripts under `bash -e -o pipefail`, so a bare
# command returning non-zero (the prepare-on-symlink call legitimately returns
# 3) would otherwise abort the subshell before we can assert on it. The
# symlink + perm sub-checks are gated on real-symlink support so the fixture
# stays robust on platforms where `ln -s` is a copy (Windows Git Bash without
# developer mode) — the structural assertions above still lock the guard code.
(
  set +eu
  . "$DISPATCH_LIB" >/dev/null 2>&1
  _t="$(mktemp -d)" || exit 20
  _uberdev_dispatch_tmp_target_safe "$_t/clean.log" || exit 12                  # clean path MUST pass (all platforms)
  _uberdev_dispatch_prepare_tmp_target "$_t/p.log" 99 claude-bg >/dev/null 2>&1 || exit 13
  [ -f "$_t/p.log" ] || exit 14                                                 # prepare created the file (all platforms)
  ln -s /etc/passwd "$_t/evil.log" 2>/dev/null
  if [ -L "$_t/evil.log" ]; then                                               # real-symlink platform (Linux/macOS)
    _uberdev_dispatch_tmp_target_safe "$_t/evil.log" >/dev/null 2>&1; [ "$?" -ne 0 ] || exit 11   # symlink MUST be rejected
    ln -s /etc/passwd "$_t/p2.log" 2>/dev/null
    _uberdev_dispatch_prepare_tmp_target "$_t/p2.log" 99 claude-bg >/dev/null 2>&1; [ "$?" -eq 3 ] || exit 15  # prepare on symlink -> rc 3
    _perm="$(stat -c '%a' "$_t/p.log" 2>/dev/null || stat -f '%Lp' "$_t/p.log" 2>/dev/null)"
    [ "$_perm" = "600" ] || exit 16                                            # created 0600 (perms meaningful on this platform)
  fi
  rm -rf "$_t"
  exit 0
)
_rc155=$?
if [ "$_rc155" -eq 0 ]; then
  echo "  PASS  #155 runtime — symlink fail-CLOSED, clean pass, 0600 create, prepare-symlink rc=3"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #155 runtime — guard behaviour (subshell exit $_rc155)"
  FAIL=$((FAIL + 1))
fi

TALLY_FILE="$(mktemp)"   # subshell PASS/FAIL hand-off for #175 cases

echo
echo "== #175 D-iso: uberdev_dispatch_resolve_env populates env from a clean shell =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG AUTO_PERMISSIONS SKIP_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env; rc=$?
  [[ "$rc" -eq 0 ]] && { echo "  PASS  D-iso resolve_env returns 0"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso resolve_env rc=$rc"; FAIL=$((FAIL + 1)); }
  [[ -n "$TIMEOUT_BIN" ]] && { echo "  PASS  D-iso TIMEOUT_BIN non-empty"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso TIMEOUT_BIN empty"; FAIL=$((FAIL + 1)); }
  if [ -x "$TIMEOUT_BIN" ] || command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then echo "  PASS  D-iso TIMEOUT_BIN executable/resolvable"; PASS=$((PASS + 1)); else echo "  FAIL  D-iso TIMEOUT_BIN not executable ($TIMEOUT_BIN)"; FAIL=$((FAIL + 1)); fi
  [[ "$MODEL" == 'claude-opus-4-8[1m]' ]] && { echo "  PASS  D-iso MODEL correct"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso MODEL='$MODEL'"; FAIL=$((FAIL + 1)); }
  case "$SOLVE_TIMEOUT" in (''|*[!0-9]*) echo "  FAIL  D-iso SOLVE_TIMEOUT not numeric ('$SOLVE_TIMEOUT')"; FAIL=$((FAIL + 1));; (*) echo "  PASS  D-iso SOLVE_TIMEOUT numeric"; PASS=$((PASS + 1));; esac
  [[ "$BG_PROMPT_MODE" == "argv" ]] && { echo "  PASS  D-iso BG_PROMPT_MODE=argv"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso BG_PROMPT_MODE='$BG_PROMPT_MODE'"; FAIL=$((FAIL + 1)); }
  [[ "${EFFORT_FLAG[*]}" == "--effort max" ]] && { echo "  PASS  D-iso EFFORT_FLAG=( --effort max )"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso EFFORT_FLAG=( ${EFFORT_FLAG[*]} )"; FAIL=$((FAIL + 1)); }
  [[ "${#PERM_FLAG[@]}" -eq 0 ]] && { echo "  PASS  D-iso PERM_FLAG empty (default AUTO_PERMISSIONS=0)"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-iso PERM_FLAG=( ${PERM_FLAG[*]} )"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #246 D-perm: AUTO_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions (#243 + #246 pairing — bypass-mode pins the bg UI cycle ring; danger-skip short-circuits the checks) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; AUTO_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] && { echo "  PASS  D-perm AUTO_PERMISSIONS=1 -> PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-perm PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #246 D-skip: SKIP_PERMISSIONS=1 yields --dangerously-skip-permissions --permission-mode bypassPermissions =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG AUTO_PERMISSIONS EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; SKIP_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-skip PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-skip PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #246 D-precedence: SKIP_PERMISSIONS=1 + AUTO_PERMISSIONS=1 -> both yield --dangerously-skip-permissions --permission-mode bypassPermissions (collapsed tier; precedence ordering preserved for observability only) =="
(
  set +u
  unset TIMEOUT_BIN SOLVE_TIMEOUT MODEL BG_PROMPT_MODE PERM_FLAG EFFORT_FLAG EFFORT_LEVEL
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"; SKIP_PERMISSIONS=1; AUTO_PERMISSIONS=1
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  uberdev_dispatch_resolve_env
  [[ "${PERM_FLAG[*]}" == "--dangerously-skip-permissions --permission-mode bypassPermissions" ]] \
    && { echo "  PASS  D-precedence both tiers yield --dangerously-skip-permissions --permission-mode bypassPermissions"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL  D-precedence PERM_FLAG=( ${PERM_FLAG[*]} ) — expected --dangerously-skip-permissions --permission-mode bypassPermissions (#246)"; FAIL=$((FAIL + 1)); }
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #175 D-regression: goal-pipeline preflight->resolve_env->dispatch is NOT rc=126 =="
if python3 -I -B - "$0" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
marker=source.index('\necho "== #175 D-regression:')
start=source.index('\n(\n  set +u\n  UBERDEV_TMPDIR="$(mktemp -d)"',marker)
end=source.index('\n) ; read -r dP dF < "$TALLY_FILE"',start)
block=source[start:end]
assert 'claude() {' not in block
assert 'cat >"$UBERDEV_TMPDIR/bin/claude"' in block
assert 'PATH="$UBERDEV_TMPDIR/bin:$PATH"' in block
assert 'TIMEOUT_BIN="timeout"' not in block
PY
then
  echo "  PASS  D-regression crosses the real timeout/env exec boundary with an executable Claude stub"
  PASS=$((PASS + 1))
else
  echo "  FAIL  D-regression still depends on shell-only timeout/env/Claude mocks"
  FAIL=$((FAIL + 1))
fi
(
  set +u
  UBERDEV_TMPDIR="$(mktemp -d)"
  mkdir -p "$UBERDEV_TMPDIR/bin"
  cat >"$UBERDEV_TMPDIR/bin/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '2.1.152\n' ;;
  --bg) printf 'backgrounded · def67890\n' ;;
  agents) printf '[{"sessionId":"def67890-full","state":"completed"}]\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$UBERDEV_TMPDIR/bin/claude"
  PATH="$UBERDEV_TMPDIR/bin:$PATH"
  export PATH
  printf 'Agent starting...\nbackgrounded · def67890\n' > "$UBERDEV_TMPDIR/solve-bg-stdout-42.log"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  declare -a AUDIT_EVENTS=(); _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  # First call exercises auto backend-resolution; second forces claude-bg so the
  # dispatch stub below routes deterministically on any host.
  uberdev_dispatch_preflight
  UBERDEV_DISPATCH_BACKEND_REQUESTED=claude-bg uberdev_dispatch_preflight
  uberdev_dispatch_resolve_env
  # Prove the #175 root cause (empty TIMEOUT_BIN) is fixed HERE too, not only in
  # D-iso: resolve_env must select the real timeout binary used below.
  [[ -n "$TIMEOUT_BIN" ]] && { echo "  PASS  D-regression resolve_env selected a real timeout binary"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression resolve_env left TIMEOUT_BIN empty"; FAIL=$((FAIL + 1)); }
  # Fixture: synthetic dispatch-plumbing input. The executable Claude stub
  # crosses the real timeout -> env -> exec boundary; the prompt body never
  # reaches a real agent. Pre-#235 bare-slash shape is preserved intentionally
  # because this fixture exercises TIMEOUT_BIN, not canonical prompt shape.
  PROMPT_FILE="$UBERDEV_TMPDIR/solve-prompt-42.txt"; printf '/uberdev:orchestrator --turbo solve GH issue #42\n' > "$PROMPT_FILE"
  uberdev_dispatch_one 42 small "$PROMPT_FILE"; rc=$?
  [[ "$rc" -ne 126 ]] && { echo "  PASS  D-regression dispatch rc != 126 (got $rc) — #175 fixed"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression dispatch rc=126 — #175 NOT fixed"; FAIL=$((FAIL + 1)); }
  [[ "$rc" -eq 0 ]] && { echo "  PASS  D-regression happy-path rc=0"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression happy-path rc=$rc"; FAIL=$((FAIL + 1)); }
  D_REGRESSION_STATUS="$UBERDEV_TMPDIR/solve-bg-status-42.json"
  D_REGRESSION_STATE="$UBERDEV_TMPDIR/.agent-state-$(id -u)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    grep -q '"state":"completed"' "$D_REGRESSION_STATUS" 2>/dev/null \
      && ! grep -R -q 'run_id=solve-claude-bg-42-' "$D_REGRESSION_STATE/semaphore-v1" 2>/dev/null \
      && break
    command sleep 0.1
  done
  if grep -q '"state":"completed"' "$D_REGRESSION_STATUS" 2>/dev/null \
      && [ ! -e "$D_REGRESSION_STATUS.watcher-error.json" ] \
      && ! grep -R -q 'run_id=solve-claude-bg-42-' "$D_REGRESSION_STATE/semaphore-v1" 2>/dev/null; then
    echo "  PASS  D-regression adapter supervision terminalizes and releases its exact lease"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  D-regression adapter supervision retained status error or lease state"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UBERDEV_TMPDIR"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

echo
echo "== #175 D-failloud: no timeout/gtimeout on PATH -> return 1 + brew pointer =="
# Unlike the other #175 cases, this block captures via $(...) rather than the
# subshell+TALLY_FILE idiom: it must run the PATH-sandboxed probe inline and grab
# stderr+rc together, which the subshell-then-tally hand-off pattern can't express.
_ff_out="$(
  set +eu
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB" >/dev/null 2>&1
  _sandbox="$(mktemp -d)"
  PATH="$_sandbox" uberdev_dispatch_resolve_env 2>&1
  echo "RC=$?"
  rm -rf "$_sandbox"
)"
if [ -x /usr/bin/timeout ]; then
  case "$_ff_out" in (*RC=0*) echo "  PASS  D-failloud (/usr/bin/timeout present) resolve_env rc=0"; PASS=$((PASS + 1));; (*) echo "  FAIL  D-failloud expected rc=0 with /usr/bin/timeout present: $_ff_out"; FAIL=$((FAIL + 1));; esac
else
  case "$_ff_out" in
    (*"brew install coreutils"*RC=1*|*RC=1*"brew install coreutils"*) echo "  PASS  D-failloud rc=1 + brew pointer"; PASS=$((PASS + 1));;
    (*) echo "  FAIL  D-failloud expected rc=1 + brew pointer: $_ff_out"; FAIL=$((FAIL + 1));;
  esac
fi

echo
echo "== #335 Claude cancellation is exact and bounded =="
(
  set +u
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  CANCEL_TMP="$(mktemp -d)"
  CANCEL_LOG="$CANCEL_TMP/claude.log"
  CANCEL_STATE="$CANCEL_TMP/state"
  printf 'live\n' > "$CANCEL_STATE"
  claude() {
    printf '%s\n' "$*" >> "$CANCEL_LOG"
    if [ "${1:-}" = stop ]; then
      printf 'cancelled\n' > "$CANCEL_STATE"
      return 0
    fi
    if [ "${1:-}" = agents ] && [ "${2:-}" = --all ] && [ "${3:-}" = --json ]; then
      if [ "$(cat "$CANCEL_STATE")" = cancelled ]; then
        printf '[{"sessionId":"abc12345-full","state":"cancelled"}]\n'
      else
        printf '[{"sessionId":"abc12345-full","state":"running"}]\n'
      fi
      return 0
    fi
    return 2
  }
  . "$DISPATCH_LIB"
  _uberdev_dispatch_cancel_backend claude-bg abc12345 ''
  valid_rc=$?
  _uberdev_dispatch_cancel_claude_bg 'abc12345;touch-pwned' >/dev/null 2>&1
  invalid_rc=$?
  calls="$(cat "$CANCEL_LOG" 2>/dev/null)"
  if [ "$valid_rc" -eq 0 ] && [ "$invalid_rc" -eq 2 ] \
      && [ "$(grep -c '^stop abc12345-full$' "$CANCEL_LOG")" -eq 1 ] \
      && [[ "$calls" != *touch-pwned* ]]; then
    echo "  PASS  cancellation runs only exact claude stop <8hex> and confirms terminal state"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  exact Claude cancellation contract (valid=$valid_rc invalid=$invalid_rc calls=$calls)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$CANCEL_TMP"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TALLY_FILE"
) ; read -r dP dF < "$TALLY_FILE"; PASS="$dP"; FAIL="$dF"

rm -f "$TALLY_FILE"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
