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
  'backgrounded · \[0-9a-f\]\{8\}' \
  "claude-bg backend extracts the backgrounded · <id> bg session id"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_claude_bg\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_claude_bg function"

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

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
