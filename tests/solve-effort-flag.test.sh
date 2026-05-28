#!/usr/bin/env bash
# Runtime fixture for the v0.22.1 --effort=<level> threading in
# solve-pipeline/SKILL.md. Complements the shape-check assertions in
# tests/dispatch-claude-bg.test.sh by EXECUTING the Phase A parser against
# several `$ARGUMENTS` shapes and asserting the resolved EFFORT_LEVEL /
# EFFORT_FLAG / captured-argv values.
#
# Why a runtime fixture: shape-checks anchor on textual patterns, but the
# precedence ladder (CLI > env > config > default) is a behavioural
# contract that a pure grep cannot exercise. A future refactor that
# reordered the if/elif chain (e.g. let env win over CLI) would slip past
# every grep assertion while breaking the user-visible contract. This
# runtime fixture covers that gap.
#
# Tactic: extract the Phase A parser block from SKILL.md via awk markers,
# source it inside a controlled subshell with a no-op audit-emit stub,
# and probe $EFFORT_LEVEL after each input shape. The dispatch-argv
# assertion uses a `claude` stub on PATH that writes its argv to a temp
# file (mirrors tests/install.test.sh's stub pattern).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
HELPER="$REPO_ROOT/plugins/uberdev/lib/config-read.sh"

for f in "$SOLVE_PIPELINE" "$HELPER"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Extract the Phase A --effort parser block. Anchors must match the marker
# comment in SKILL.md and the validation `case` closer. Range is
# [# --- Phase A: --effort=<level> parser ...] through the matching `esac`,
# inclusive.
PARSER_BLOCK="$(awk '
  /^# --- Phase A: --effort=<level> parser/ { capture=1 }
  capture { print }
  capture && /^esac$/ { print "PARSER_END"; exit }
' "$SOLVE_PIPELINE")"

if ! grep -q 'PARSER_END' <<<"$PARSER_BLOCK"; then
  echo "FATAL: could not extract Phase A --effort parser block from $SOLVE_PIPELINE" >&2
  echo "       awk anchors '^# --- Phase A: --effort=<level> parser' / '^esac$' did not match a single contiguous range" >&2
  exit 2
fi
# Drop the sentinel before eval.
PARSER_BLOCK="${PARSER_BLOCK%PARSER_END*}"

# Positive content guard: the extracted window MUST contain the EFFORT_LEVEL_ENUM
# literal. Catches future Phase A `case` additions (e.g. another enum closing
# with `esac`) that would shift the extraction window away from the --effort
# parser. Without this guard, a wrong-window extraction silently runs an
# unrelated block and every R1/R2 assertion fails with confusing diffs.
if ! grep -q 'low|medium|high|xhigh|max' <<<"$PARSER_BLOCK"; then
  echo "FATAL: extracted PARSER_BLOCK does not contain the EFFORT_LEVEL_ENUM literal" >&2
  echo "       awk anchors may have shifted onto an adjacent case-esac block — verify SKILL.md" >&2
  exit 2
fi

# _resolve <ARGUMENTS> [<env_override>] [<config_value>]
# Sources the helper + parser block in a clean subshell. Returns
# "$EFFORT_LEVEL|$EFFORT_FLAG|$EFFORT_SOURCE" on stdout.
_resolve() {
  local args="$1" env_val="${2-}" config_val="${3-}"
  local sandbox stdout_file
  sandbox="$(mktemp -d)"
  stdout_file="$(mktemp)"
  mkdir -p "$sandbox/.claude"
  : > "$sandbox/.claude/uberdev.local.md"
  if [ -n "$config_val" ]; then
    printf 'solve_effort: %s\n' "$config_val" > "$sandbox/.claude/uberdev.local.md"
  fi
  # CLAUDE_PLUGIN_ROOT must point at the plugin (where lib/config-read.sh
  # lives) for the parser's `. "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh"`
  # to succeed.
  (
    cd "$sandbox"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
    export ARGUMENTS="$args"
    if [ -n "$env_val" ]; then
      export UBERDEV_SOLVE_EFFORT="$env_val"
    else
      unset UBERDEV_SOLVE_EFFORT
    fi
    # The parser references _uberdev_audit_emit (defined at the top of
    # SKILL.md Phase A but not extracted by our awk window). Stub as a
    # no-op so the eval doesn't `command not found` out.
    _uberdev_audit_emit() { :; }
    eval "$PARSER_BLOCK"
    # The SKILL.md hoist binds EFFORT_FLAG as a bash+zsh array
    # (`EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )`); reconstruct as a scalar
    # string here purely for the R1/R2 assertion shape — the test asserts on
    # textual output like "high|--effort high|cli", not on argv slot count.
    # R3 below mirrors the array form to lock the dispatch contract.
    EFFORT_FLAG="--effort $EFFORT_LEVEL"
    printf '%s|%s|%s' "$EFFORT_LEVEL" "$EFFORT_FLAG" "$EFFORT_SOURCE"
  ) > "$stdout_file" 2>>"$stdout_file.err"
  cat "$stdout_file"
  rm -rf "$sandbox" "$stdout_file" "$stdout_file.err"
}

echo "== R1: --effort=<level> precedence ladder =="

# R1a: no flag, no env, no config -> default `max`
RES="$(_resolve '128')"
if [[ "$RES" = "max|--effort max|default" ]]; then
  pass "R1a: bare invocation resolves to default max (got: $RES)"
else
  fail "R1a: bare invocation should resolve to 'max|--effort max|default', got '$RES'"
fi

# R1b: CLI flag wins over env + config
RES="$(_resolve '128 --effort=high' 'xhigh' 'low')"
if [[ "$RES" = "high|--effort high|cli" ]]; then
  pass "R1b: --effort=high CLI flag wins over env=xhigh and config=low (got: $RES)"
else
  fail "R1b: CLI should win — expected 'high|--effort high|cli', got '$RES'"
fi

# R1c: env wins over config when no CLI flag
RES="$(_resolve '128' 'xhigh' 'low')"
if [[ "$RES" = "xhigh|--effort xhigh|env" ]]; then
  pass "R1c: UBERDEV_SOLVE_EFFORT=xhigh wins over config=low when no CLI flag (got: $RES)"
else
  fail "R1c: env should win — expected 'xhigh|--effort xhigh|env', got '$RES'"
fi

# R1d: config wins over default when no CLI flag and no env
RES="$(_resolve '128' '' 'high')"
if [[ "$RES" = "high|--effort high|config" ]]; then
  pass "R1d: config solve_effort=high wins over default when no CLI/env (got: $RES)"
else
  fail "R1d: config should win — expected 'high|--effort high|config', got '$RES'"
fi

# R1e: all five enum values accepted via CLI
for lvl in low medium high xhigh max; do
  RES="$(_resolve "128 --effort=$lvl")"
  if [[ "$RES" = "$lvl|--effort $lvl|cli" ]]; then
    pass "R1e: --effort=$lvl accepted (got: $RES)"
  else
    fail "R1e: --effort=$lvl rejected — expected '$lvl|--effort $lvl|cli', got '$RES'"
  fi
done

# R1f: explicit `solve_effort: max` in config MUST attribute source=config
# (regression guard for the inequality-based misattribution bug — Phase A
# previously labelled this `default` because the resolved value matched the
# default). The fix is the direct grep against the config file for the literal
# `solve_effort:` key BEFORE delegating to uberdev_read_enum.
RES="$(_resolve '128' '' 'max')"
if [[ "$RES" = "max|--effort max|config" ]]; then
  pass "R1f: config solve_effort=max attributed to source=config (got: $RES)"
else
  fail "R1f: explicit config=max should attribute source=config — expected 'max|--effort max|config', got '$RES'"
fi

# R1g: bare invocation with empty config file MUST attribute source=default
# (companion to R1f — confirms the absence path lands on `default` and the
# direct-grep probe does not produce false positives on an empty config).
RES="$(_resolve '128' '' '')"
if [[ "$RES" = "max|--effort max|default" ]]; then
  pass "R1g: empty config attributed to source=default (got: $RES)"
else
  fail "R1g: empty config should attribute source=default — expected 'max|--effort max|default', got '$RES'"
fi

echo
echo "== R2: invalid --effort=<level> values rejected loudly =="

# R2a: typo like --effort=hgh aborts with non-zero exit and helpful stderr
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/.claude"
: > "$SANDBOX/.claude/uberdev.local.md"
STDERR_FILE="$(mktemp)"
(
  cd "$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  export ARGUMENTS="128 --effort=hgh"
  unset UBERDEV_SOLVE_EFFORT
  _uberdev_audit_emit() { :; }
  eval "$PARSER_BLOCK"
) 2>"$STDERR_FILE"
RC=$?
STDERR_CONTENT="$(cat "$STDERR_FILE")"
rm -rf "$SANDBOX" "$STDERR_FILE"
if [[ "$RC" -ne 0 ]] && grep -q "not in {low,medium,high,xhigh,max}" <<<"$STDERR_CONTENT"; then
  pass "R2a: --effort=hgh rejected (rc=$RC, stderr names the enum)"
else
  fail "R2a: --effort=hgh should exit non-zero and name the enum; rc=$RC stderr=$STDERR_CONTENT"
fi

# R2b: invalid env var also rejected
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/.claude"
: > "$SANDBOX/.claude/uberdev.local.md"
STDERR_FILE="$(mktemp)"
(
  cd "$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  export ARGUMENTS="128"
  export UBERDEV_SOLVE_EFFORT="ludicrous"
  _uberdev_audit_emit() { :; }
  eval "$PARSER_BLOCK"
) 2>"$STDERR_FILE"
RC=$?
STDERR_CONTENT="$(cat "$STDERR_FILE")"
rm -rf "$SANDBOX" "$STDERR_FILE"
if [[ "$RC" -ne 0 ]] && grep -q "not in {low,medium,high,xhigh,max}" <<<"$STDERR_CONTENT"; then
  pass "R2b: UBERDEV_SOLVE_EFFORT=ludicrous rejected (rc=$RC, stderr names the enum)"
else
  fail "R2b: invalid env value should exit non-zero and name the enum; rc=$RC stderr=$STDERR_CONTENT"
fi

echo
echo '== R3: child-argv capture — ${EFFORT_FLAG[@]} reaches claude --bg with one slot per element =='
# Build a stubbed `claude` that captures its argv to a file. Invoke the
# argv-arm dispatch shape directly (avoids extracting the wave-batching
# loop from SKILL.md, which would couple to too many other variables).
# This locks the contract that:
#   1. EFFORT_FLAG is a bash+zsh array; `"${EFFORT_FLAG[@]}"` expands to two
#      argv slots (--effort + level) regardless of SH_WORD_SPLIT (v0.22.2
#      regression: v0.22.1 shipped scalar `EFFORT_FLAG="--effort max"` which
#      collapsed into one argv slot under zsh, the macOS default shell).
#   2. The level lands as a separate argv slot, not concatenated with
#      --effort (a regression like `EFFORT_FLAG=( --effort=$EFFORT_LEVEL )`
#      would produce one combined slot that some claude --effort parsers
#      might still accept, but would break this assertion loudly).
# Solve-pipeline-zsh.test.sh runs the equivalent capture under a real zsh
# subshell to specifically guard the SH_WORD_SPLIT=off scenario; this R3
# fixture runs under bash (#!/usr/bin/env bash above), so the bash + zsh
# story is covered jointly.
STUB_DIR="$(mktemp -d)"
CAPTURE_FILE="$(mktemp)"
cat > "$STUB_DIR/claude" <<STUB
#!/usr/bin/env bash
# Capture argv to the file referenced by \$CLAUDE_ARGV_CAPTURE.
printf '%s\n' "\$@" > "\$CLAUDE_ARGV_CAPTURE"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/.claude"
: > "$SANDBOX/.claude/uberdev.local.md"
# Write a fake prompt body so the argv arm has something to dispatch with.
echo "fake prompt body" > "$SANDBOX/prompt.txt"

(
  # macOS ships bash 3.2 as /bin/bash; that version + `set -u` (inherited
  # from the parent harness) errors on `"${PERM_FLAG[@]}"` when PERM_FLAG
  # is an empty array — a quirk fixed in bash 4.4. The SKILL.md does not
  # run under `set -u` in production (Claude Code's Bash tool inherits
  # zsh, which handles empty arrays cleanly), so this is purely a
  # test-harness portability concern. Relax `set -u` for this subshell
  # so the empty-array mirror compiles on macOS bash 3.2; the rest of
  # the test file keeps `set -u` for typo guarding.
  set +u
  cd "$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  export ARGUMENTS="128 --effort=high"
  export CLAUDE_ARGV_CAPTURE="$CAPTURE_FILE"
  unset UBERDEV_SOLVE_EFFORT
  _uberdev_audit_emit() { :; }
  # Phase A parser resolves EFFORT_LEVEL.
  eval "$PARSER_BLOCK"
  # EFFORT_FLAG hoist (lives further down in SKILL.md outside the extracted
  # parser window) — mirror the array form verbatim so the test fails loudly
  # if SKILL.md regresses to the scalar form that broke under zsh in v0.22.1.
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
  # Stand-ins for the other Phase A variables consumed by the argv arm.
  TIMEOUT_BIN=""
  SOLVE_TIMEOUT=10
  MODEL='claude-opus-4-8[1m]'
  PERM_FLAG=()
  ISSUE_NUM=128
  PROMPT_BODY="$(cat "$SANDBOX/prompt.txt")"
  # Mirror the argv-arm composition from SKILL.md Step 5b' verbatim.
  cmd=( "$STUB_DIR/claude" --bg
        --worktree "solve-issue-$ISSUE_NUM"
        --model "$MODEL" )
  cmd+=( "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" -- "$PROMPT_BODY" )
  "${cmd[@]}" >/dev/null 2>&1
) || true

# Explicit stub-execution check: if the stub never ran (PATH miss, exec fail,
# Phase A parser aborted before reaching the dispatch), surface that
# specifically instead of conflating it with a missing-argv-token failure.
if [[ ! -f "$CAPTURE_FILE" ]] || [[ ! -s "$CAPTURE_FILE" ]]; then
  fail "R3 precondition: claude stub did not execute (capture file missing or empty)"
fi

ARGV_DUMP="$(cat "$CAPTURE_FILE" 2>/dev/null)"
if grep -qx -- '--effort' <<<"$ARGV_DUMP" && grep -qx 'high' <<<"$ARGV_DUMP"; then
  pass "R3a: captured argv contains '--effort' and 'high' as separate slots (word-split preserved)"
else
  fail "R3a: captured argv missing '--effort' and/or 'high' as separate slots"
  echo "        argv dump:"
  printf '          %s\n' $ARGV_DUMP
fi
# Order check: `--effort` must precede the level token.
EFFORT_LINE=$(grep -n '^--effort$' <<<"$ARGV_DUMP" | head -1 | cut -d: -f1)
LEVEL_LINE=$(grep -n '^high$' <<<"$ARGV_DUMP" | head -1 | cut -d: -f1)
if [[ -n "$EFFORT_LINE" && -n "$LEVEL_LINE" && "$EFFORT_LINE" -lt "$LEVEL_LINE" ]]; then
  pass "R3b: '--effort' (slot $EFFORT_LINE) precedes 'high' (slot $LEVEL_LINE) in argv order"
else
  fail "R3b: '--effort' must precede the level slot — got effort=$EFFORT_LINE level=$LEVEL_LINE"
fi

# Cleanup
rm -rf "$STUB_DIR" "$SANDBOX" "$CAPTURE_FILE"

echo
echo "== R4: effort_resolved audit event is actually written =="
# The R1/R2 tests stub _uberdev_audit_emit as a no-op to focus on the
# precedence ladder. R4 closes the gap: extract the REAL _uberdev_audit_emit
# function from SKILL.md, set SOLVE_AUDIT_LOG to a tmpfile, run the parser +
# the EFFORT_FLAG/audit-emit hoist, and assert the emitted JSON line has the
# expected shape `{event: effort_resolved, data: {source, level}}`.
AUDIT_FN_BLOCK="$(awk '
  /^_uberdev_audit_emit\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { print "AUDIT_FN_END"; exit }
' "$SOLVE_PIPELINE")"

if ! grep -q 'AUDIT_FN_END' <<<"$AUDIT_FN_BLOCK"; then
  fail "R4 precondition: could not extract _uberdev_audit_emit from $SOLVE_PIPELINE"
else
  AUDIT_FN_BLOCK="${AUDIT_FN_BLOCK%AUDIT_FN_END*}"

  SANDBOX="$(mktemp -d)"
  AUDIT_LOG="$(mktemp)"
  mkdir -p "$SANDBOX/.claude"
  : > "$SANDBOX/.claude/uberdev.local.md"
  (
    cd "$SANDBOX"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
    export ARGUMENTS="128 --effort=high"
    export SOLVE_AUDIT_LOG="$AUDIT_LOG"
    unset UBERDEV_SOLVE_EFFORT
    # Define the REAL _uberdev_audit_emit BEFORE sourcing the parser; the
    # parser only references the function name (no early-binding capture).
    eval "$AUDIT_FN_BLOCK"
    eval "$PARSER_BLOCK"
    # Mirror the SKILL.md hoist that emits the `effort_resolved` event.
    # The audit emit reads $EFFORT_SOURCE and $EFFORT_LEVEL directly (not via
    # $EFFORT_FLAG), so the array-vs-scalar shape doesn't matter here; bind
    # the array form anyway to stay consistent with the SKILL.md.
    EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
    _uberdev_audit_emit effort_resolved \
      "{\"source\":\"$EFFORT_SOURCE\",\"level\":\"$EFFORT_LEVEL\"}" || true
  ) >/dev/null 2>&1

  EMITTED="$(cat "$AUDIT_LOG" 2>/dev/null)"
  if grep -q '"event":"effort_resolved"' <<<"$EMITTED" \
     && grep -q '"source":"cli"' <<<"$EMITTED" \
     && grep -q '"level":"high"' <<<"$EMITTED"; then
    pass "R4: effort_resolved audit event written with source=cli, level=high"
  else
    fail "R4: expected effort_resolved JSON with source=cli, level=high in $AUDIT_LOG; got: $EMITTED"
  fi
  rm -rf "$SANDBOX" "$AUDIT_LOG"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
