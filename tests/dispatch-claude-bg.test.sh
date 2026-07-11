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
  'claude --bg \\?$|claude --bg --prompt-file' \
  "_uberdev_dispatch_claude_bg contains claude --bg invocation (file arm)"
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
  '\-\-worktree "solve-issue-\$ISSUE_NUM"' \
  "claude-bg arm passes --worktree solve-issue-N for isolation"

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
chmod +x "$ULTRA_TMP/bin/gh"
if PATH="$ULTRA_TMP/bin:$PATH" ULTRA_GH_LOG="$ULTRA_TMP/gh.log" TMPDIR="$ULTRA_TMP" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$SOLVE_PIPELINE" --auto-mode=0 -- 91 --backend=background --effort=ultra >"$ULTRA_TMP/out" 2>&1; then
  ULTRA_RC=0
else
  ULTRA_RC=$?
fi
if [ "$ULTRA_RC" -ne 0 ] && grep -q 'ultra is Codex-only' "$ULTRA_TMP/out" && ! grep -q '^label create' "$ULTRA_TMP/gh.log"; then
  echo "  PASS  Claude Ultra fails behaviorally before claim mutation"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Claude Ultra must fail before claims (rc=$ULTRA_RC output=$(cat "$ULTRA_TMP/out"))"
  FAIL=$((FAIL + 1))
fi
rm -rf "$ULTRA_TMP"
# Each of the three case-statement arms threads ${EFFORT_FLAG[@]} immediately
# after ${PERM_FLAG[@]}. The literal `"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`
# token-pair must appear at least three times (file arm, stdin arm, argv arm).
# A future edit that drops the flag from any one arm would regress to silent
# default-effort dispatch for that mode. The array-quoted form (not the prior
# unquoted `$PERM_FLAG $EFFORT_FLAG` scalar form) is mandatory under zsh —
# scalar word-split is OFF by default and would collapse `--effort max` into
# one argv slot, which `claude --bg` rejects loudly.
EFFORT_ARMS_COUNT=$(grep -cE '"\$\{PERM_FLAG\[@\]\}" "\$\{EFFORT_FLAG\[@\]\}"' "$DISPATCH_LIB" 2>/dev/null || echo "0")
if [[ "$EFFORT_ARMS_COUNT" -ge 3 ]]; then
  echo "  PASS  all three dispatch arms thread \"\${EFFORT_FLAG[@]}\" after \"\${PERM_FLAG[@]}\" (count=$EFFORT_ARMS_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  expected \"\${PERM_FLAG[@]}\" \"\${EFFORT_FLAG[@]}\" token-pair in all 3 case arms (file/stdin/argv); count=$EFFORT_ARMS_COUNT"
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
(
  set +u
  UBERDEV_TMPDIR="$(mktemp -d)"
  printf 'Agent starting...\nbackgrounded · def67890\n' > "$UBERDEV_TMPDIR/solve-bg-stdout-42.log"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  declare -a AUDIT_EVENTS=(); _uberdev_audit_emit() { AUDIT_EVENTS+=( "$1 $2" ); }
  timeout() { shift; "$@"; }
  env() { while [[ "$1" == *=* ]]; do shift; done; "$@"; }
  claude() { printf 'backgrounded · def67890\n'; return 0; }
  DISPATCH_RC=0; DISPATCH_ID=""; DISPATCH_LOG=""
  # shellcheck disable=SC1090
  . "$DISPATCH_LIB"
  # First call exercises auto backend-resolution; second forces claude-bg so the
  # dispatch stub below routes deterministically on any host.
  uberdev_dispatch_preflight
  UBERDEV_DISPATCH_BACKEND_REQUESTED=claude-bg uberdev_dispatch_preflight
  uberdev_dispatch_resolve_env
  # Prove the #175 root cause (empty TIMEOUT_BIN) is fixed HERE too, not only in
  # D-iso: resolve_env must populate TIMEOUT_BIN before any override below.
  [[ -n "$TIMEOUT_BIN" ]] && { echo "  PASS  D-regression resolve_env set TIMEOUT_BIN non-empty before override"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression resolve_env left TIMEOUT_BIN empty"; FAIL=$((FAIL + 1)); }
  # Override swaps in an equivalent valid binary for the bare-word `timeout()`
  # mock above; absolute /usr/bin/timeout (resolve_env's first choice on this
  # host) would bypass the function mock. The empty-TIMEOUT_BIN root cause of
  # #175 is asserted just above — this line is mock plumbing, not the guard.
  TIMEOUT_BIN="timeout"
  # Fixture: synthetic dispatch-plumbing input. claude() is mocked above; the prompt body never reaches a real agent. Pre-#235 bare-slash shape preserved here intentionally (this fixture exercises TIMEOUT_BIN, NOT the canonical prompt shape — see plugins/uberdev/lib/goal-state.sh and the goal-pipeline SKILL for the canonical post-#235 wrapper).
  PROMPT_FILE="$UBERDEV_TMPDIR/solve-prompt-42.txt"; printf '/uberdev:orchestrator --turbo solve GH issue #42\n' > "$PROMPT_FILE"
  uberdev_dispatch_one 42 small "$PROMPT_FILE"; rc=$?
  [[ "$rc" -ne 126 ]] && { echo "  PASS  D-regression dispatch rc != 126 (got $rc) — #175 fixed"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression dispatch rc=126 — #175 NOT fixed"; FAIL=$((FAIL + 1)); }
  [[ "$rc" -eq 0 ]] && { echo "  PASS  D-regression happy-path rc=0"; PASS=$((PASS + 1)); } || { echo "  FAIL  D-regression happy-path rc=$rc"; FAIL=$((FAIL + 1)); }
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

rm -f "$TALLY_FILE"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
