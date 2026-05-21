#!/usr/bin/env bash
# Shape-check for the v0.22.0 `claude --bg` dispatch in solve-pipeline/SKILL.md.
#
# Verifies the three-arm BG_PROMPT_MODE case-switch, the Phase A probes,
# the wave-batching outer loop, the --terminal= deprecation shim, and the
# absence of the security anti-pattern shapes (eval, naive interpolation).
#
# Companion test: tests/ghostty-dispatch-no-instance-leak.test.sh asserts
# the retired surface is ABSENT. This test asserts the new surface is PRESENT.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
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
# Drift between this helper and dispatch.sh:241-243 (post-#143 fix) is
# caught by the shape-check assertions above — the regexes here MUST stay
# in lockstep.
_extract_id() {
  local fixture="$1"
  local id
  id="$(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' "$fixture" \
        | grep -aoE '^backgrounded · [0-9a-f]{8}$' \
        | awk '{print $NF}' \
        | head -1)"
  id="${id//[^0-9a-f]/}"
  [ "${#id}" -eq 8 ] || id=""
  printf '%s' "$id"
}

# tmp fixture cleanup (per-test scope)
_TMPFIX=""
_cleanup_tmpfix() { [ -n "$_TMPFIX" ] && rm -f "$_TMPFIX" || :; }
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
assert_grep "$SOLVE_PIPELINE" \
  '^\| `EFFORT_LEVEL_DEFAULT` \| `max`' \
  "Constants table declares EFFORT_LEVEL_DEFAULT = max (autopilot default)"
assert_grep "$SOLVE_PIPELINE" \
  '^\| `EFFORT_LEVEL_ENUM` \| `low \\\| medium \\\| high \\\| xhigh \\\| max`' \
  "Constants table declares EFFORT_LEVEL_ENUM = {low,medium,high,xhigh,max}"
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
assert_grep "$SOLVE_PIPELINE" \
  '^EFFORT_FLAG=\( --effort "\$EFFORT_LEVEL" \)$' \
  "Phase A hoist binds EFFORT_FLAG as a bash+zsh array — scalar form regresses to a one-slot \`--effort max\` argv element under zsh SH_WORD_SPLIT=off (v0.22.2 fix)"
assert_grep "$SOLVE_PIPELINE" \
  '^PERM_FLAG=\(\)$' \
  "Phase A hoist binds PERM_FLAG as an empty bash+zsh array — same zsh-word-split rationale as EFFORT_FLAG (v0.22.2 fix)"
assert_grep "$SOLVE_PIPELINE" \
  'PERM_FLAG=\( --permission-mode auto \)' \
  "Phase A AUTO_PERMISSIONS branch populates PERM_FLAG as an array, not a scalar"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_audit_emit effort_resolved' \
  "Phase A emits effort_resolved audit event with {source, level}"
assert_grep "$SOLVE_PIPELINE" \
  'low\|medium\|high\|xhigh\|max' \
  "Phase A validates resolved level against the {low,medium,high,xhigh,max} enum"
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

echo "== Positive: Phase A constants + hardcoded BG_PROMPT_MODE =="
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_require_claude_version "2.1.139"' \
  "Phase A enforces claude --version >= 2.1.139 (hard gate)"
assert_grep "$SOLVE_PIPELINE" \
  'npm i -g @anthropic-ai/claude-code' \
  "version-gate error includes actionable npm install pointer"
assert_grep "$SOLVE_PIPELINE" \
  '^BG_PROMPT_MODE=argv' \
  "Phase A hardcodes BG_PROMPT_MODE=argv (probe deferred per fix(solve) commit 0c17169 — claude --bg --help is not introspective in v2.1.139)"
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

echo "== Runtime: ANSI-positive extraction (#143) =="
_new_fixture
printf 'backgrounded \xc2\xb7 \x1b[36mb88389ff\x1b[39m\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ "$GOT" == "b88389ff" ]]; then
  echo "  PASS  ANSI-decorated marker (\\x1B[36m<id>\\x1B[39m) extracts to bare 8-hex"
  PASS=$((PASS + 1))
else
  echo "  FAIL  ANSI-decorated marker extracted as '$GOT' (expected 'b88389ff')"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

_new_fixture
printf 'backgrounded \xc2\xb7 b88389ff\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ "$GOT" == "b88389ff" ]]; then
  echo "  PASS  bare marker (back-compat with Claude Code 2.1.139) extracts to 8-hex"
  PASS=$((PASS + 1))
else
  echo "  FAIL  bare marker extracted as '$GOT' (expected 'b88389ff') — back-compat broken"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #5: noise + ANSI marker + noise → first match wins
_new_fixture
printf 'some preamble\nbackgrounded \xc2\xb7 \x1b[36mb88389ff\x1b[39m\ntrailing noise\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ "$GOT" == "b88389ff" ]]; then
  echo "  PASS  mixed-line stdout extracts the first matching marker"
  PASS=$((PASS + 1))
else
  echo "  FAIL  mixed-line stdout extracted as '$GOT' (expected 'b88389ff')"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #8: two valid markers → head -1 takes the first
_new_fixture
printf 'backgrounded \xc2\xb7 aaaaaaaa\nbackgrounded \xc2\xb7 bbbbbbbb\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ "$GOT" == "aaaaaaaa" ]]; then
  echo "  PASS  multiple markers → head -1 takes the first id"
  PASS=$((PASS + 1))
else
  echo "  FAIL  multiple markers extracted as '$GOT' (expected 'aaaaaaaa')"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #6: OSC-decorated marker (hyperlink wrap) — line-anchor rejects
_new_fixture
printf '\x1b]8;;http://x\x07backgrounded \xc2\xb7 b88389ff\x1b]8;;\x07\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  OSC-decorated marker is rejected (line-anchor + CSI-only strip)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  OSC-decorated marker extracted as '$GOT' (expected empty — line-anchor must reject)"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #9: truncated id (5 hex) → does not match {8}
_new_fixture
printf 'backgrounded \xc2\xb7 b8838\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  truncated-id (5 hex) yields empty (matches B3 fail-CLOSED path)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  truncated-id extracted as '$GOT' (expected empty)"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #10: over-length id (14 hex) → line-anchor $ requires exactly 8
_new_fixture
printf 'backgrounded \xc2\xb7 b88389ffaabbcc\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  over-length-id (14 hex) yields empty (locks {8} format contract)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  over-length-id extracted as '$GOT' (expected empty)"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #11: uppercase-hex id (8 upper) → [0-9a-f] is lowercase-only
_new_fixture
printf 'backgrounded \xc2\xb7 B88389FF\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  uppercase-hex id yields empty (lowercase-only [0-9a-f] class)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  uppercase-hex id extracted as '$GOT' (expected empty)"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

# Case #7: zero-byte stdout
_new_fixture
: > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  empty stdout yields empty (B3 fail-CLOSED path triggers)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  empty stdout extracted as '$GOT' (expected empty)"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

echo "== Runtime: B3 fail-CLOSED guard regression (#143 / RFC 0004 §3.5) =="
_new_fixture
printf 'some unrelated noise\nbackground started but not the marker\nspawn attempted\n' > "$_TMPFIX"
GOT="$(_extract_id "$_TMPFIX")"
if [[ -z "$GOT" ]]; then
  echo "  PASS  missing-marker stdout yields empty (B3 guard at dispatch.sh:250 still fires rc=2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  missing-marker stdout extracted as '$GOT' — B3 fail-CLOSED contract BROKEN"
  FAIL=$((FAIL + 1))
fi
rm -f "$_TMPFIX"; _TMPFIX=""

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
