#!/usr/bin/env bash
# tests/workflow-args.test.sh — contract tests for uberdev_emit_workflow_args
# (RFC 0012 §4.3, infra-R7): the config → Workflow-args plumbing every
# migrated thin preflight relies on (DR-2 verbatim relay).
#
# Contract under test:
#   W1  — envelope emitted between exact WORKFLOW_ARGS_BEGIN/END marker lines;
#         the payload between them is one valid compact-JSON object.
#   W2  — versioned envelope keys: v==1, run_id, now_epoch (int), now_iso,
#         plugin_root, repo_root, cwd, pipeline, config{}.
#   W3  — KEY=VALUE config folding with auto-typing (int → number,
#         true/false → boolean, everything else → string; leading-zero
#         values stay strings) and dotted keys as literal JSON keys.
#   W4  — reserved top-level overrides (run_id / plugin_root / repo_root /
#         cwd) land top-level, never under .config; locked keys
#         (v / now_epoch / now_iso / pipeline / config) are REJECTED rc=2.
#   W5  — composition with the existing read helpers: values resolved via
#         uberdev_read_* (env > uberdev.local.md > default) flow into the
#         envelope; the emitter itself NEVER warns, never touches the
#         warn-once sentinels, never writes audit rows.
#   W6  — injection discipline: caller-supplied VALUEs travel as data
#         (jq --arg), never expanded as code — `$(...)`, backticks and
#         quotes survive as literal JSON string bytes and execute nothing.
#   W7  — never-eval-a-caller-supplied-NAME discipline (structural): the
#         emitter's function body contains zero `eval`; the four legacy
#         constant-name `eval "printf` sites in the read helpers are intact.
#   W8  — error paths exit 2 with a one-line stderr diagnostic (missing
#         pipeline, bad pipeline charset, non-KEY=VALUE arg, bad KEY).
#   W9  — the frozen-time contract (RFC 0012 DR-7) is documented in the
#         helper and now_epoch/now_iso are emitter-minted (not overridable).
#
# Runs under bash on ubuntu AND windows Git Bash (jq + git ship on both CI
# images). Mirrors the _isolate sandbox convention of config-override.test.sh
# (same lib, fresh PWD + empty config per snippet, sentinels reset by
# sub-shelling) without touching that file — it is owned by the
# solve-launcher PR series.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_HELPER="$REPO_ROOT/plugins/uberdev/lib/config-read.sh"
HELPER="$SOURCE_HELPER"

for f in "$SOURCE_HELPER"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || {
  echo "FATAL: jq is required for the workflow-args contract tests (preinstalled on both CI images)" >&2
  exit 2
}

# MSYS2/Git-for-Windows arg mangling: on the windows runner, bash rewrites
# absolute-POSIX-looking argv values (e.g. /pr) into Windows paths
# (C:/Program Files/Git/pr) at the exec boundary when invoking NATIVE
# binaries (jq.exe) — BEFORE jq ever sees them. That breaks byte-exact
# envelope asserts (W4.1) while proving nothing about the emitter, whose
# data-not-code contract is what this file tests. Disable the conversion for
# this test process via the documented Git-for-Windows controls; inert on
# POSIX hosts. (Production note: conversion of REAL host paths to C:/-style
# in live Windows preflights is desirable for node-side consumption — the
# emitter correctly leaves that to the platform.)
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# _isolate BODY — run a snippet in a throwaway PWD with an empty config file,
# sourcing the helper fresh in a sub-shell (sentinel exports die with it).
# Captures stdout in _LAST_STDOUT, stderr in _LAST_STDERR, rc in _LAST_RC.
_LAST_STDOUT=""
_LAST_STDERR=""
_LAST_RC=0
_isolate() {
  local body="$1"
  local sandbox out err
  sandbox="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  mkdir -p "$sandbox/.claude"
  : > "$sandbox/.claude/uberdev.local.md"
  (
    cd "$sandbox"
    # shellcheck source=/dev/null
    . "$HELPER"
    eval "$body"
  ) >"$out" 2>"$err"
  _LAST_RC=$?
  _LAST_STDOUT="$(cat "$out")"
  _LAST_STDERR="$(cat "$err")"
  rm -rf "$sandbox" "$out" "$err"
}

# Extract the JSON payload between the markers from _LAST_STDOUT.
_payload() {
  printf '%s\n' "$_LAST_STDOUT" | sed -n '/^WORKFLOW_ARGS_BEGIN$/,/^WORKFLOW_ARGS_END$/p' | sed '1d;$d'
}

# LEGACY SURFACE, retained deliberately (#381). ${CODEX_HOME}/plugins/uberdev-codex
# is a path only a stale pre-#381 install can produce -- the distribution that
# wrote it is deleted and the CHANGELOG uninstall recipe removes it. This case
# pins that the arm still RESOLVES for such a host; it does not assert that the
# path is a supported install target. See lib/config-read.sh's comment at the arm.
_assert_codex_home_plugin_root() {
  local helper_path="$1" label="$2" payload expected_codex_root
  HELPER="$helper_path"
  _isolate '
    unset CLAUDE_PLUGIN_ROOT PLUGIN_ROOT
    export CODEX_HOME="$PWD/codex-home"
    mkdir -p "$CODEX_HOME/plugins/uberdev-codex"
    uberdev_emit_workflow_args scan-fleet
  '
  payload="$(_payload)"
  if printf '%s' "$payload" | jq -e '.plugin_root | endswith("/codex-home/plugins/uberdev-codex")' >/dev/null 2>&1; then
    pass "W2.6 ${label} CODEX_HOME-only runtime emits plugin_root from CODEX_HOME/plugins/uberdev-codex"
  else
    expected_codex_root="$(printf '%s' "$payload" | jq -r '.plugin_root // "<missing>"' 2>/dev/null || printf '%s' "$payload")"
    fail "W2.6 ${label} CODEX_HOME-only runtime emits plugin_root fallback (got: ${expected_codex_root:-$payload})"
  fi
}

echo "## workflow-args contract (RFC 0012 §4.3 — uberdev_emit_workflow_args)"

# ---------------------------------------------------------------------------
echo "== W1: marker framing + valid JSON =="
_isolate 'uberdev_emit_workflow_args review-pr'
if [ "$_LAST_RC" -eq 0 ]; then
  pass "W1.1 bare invocation exits 0"
else
  fail "W1.1 bare invocation exits 0 (got rc=$_LAST_RC, stderr: $_LAST_STDERR)"
fi
first_line="$(printf '%s\n' "$_LAST_STDOUT" | sed -n '1p')"
last_line="$(printf '%s\n' "$_LAST_STDOUT" | sed -n '$p')"
[ "$first_line" = "WORKFLOW_ARGS_BEGIN" ] \
  && pass "W1.2 first output line is the literal WORKFLOW_ARGS_BEGIN marker" \
  || fail "W1.2 first output line is the literal WORKFLOW_ARGS_BEGIN marker (got: $first_line)"
[ "$last_line" = "WORKFLOW_ARGS_END" ] \
  && pass "W1.3 last output line is the literal WORKFLOW_ARGS_END marker" \
  || fail "W1.3 last output line is the literal WORKFLOW_ARGS_END marker (got: $last_line)"
payload="$(_payload)"
if printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "W1.4 payload between the markers parses as one JSON object"
else
  fail "W1.4 payload between the markers parses as one JSON object (got: $payload)"
fi
[ "$(printf '%s\n' "$payload" | wc -l | tr -d '[:space:]')" = "1" ] \
  && pass "W1.5 payload is compact single-line JSON (verbatim-relay friendly)" \
  || fail "W1.5 payload is compact single-line JSON"

# ---------------------------------------------------------------------------
echo "== W2: versioned envelope keys =="
if printf '%s' "$payload" | jq -e '
    .v == 1
    and (.run_id | type == "string")
    and (.now_epoch | type == "number")
    and (.now_iso | type == "string")
    and (.plugin_root | type == "string")
    and (.repo_root | type == "string")
    and (.cwd | type == "string")
    and .pipeline == "review-pr"
    and (.config | type == "object")
  ' >/dev/null 2>&1; then
  pass "W2.1 envelope carries v=1, run_id, now_epoch:int, now_iso, plugin_root, repo_root, cwd, pipeline, config{}"
else
  fail "W2.1 envelope keys/types drifted from the §4.3 v1 contract (got: $payload)"
fi
if grep -qE '^[0-9]{8}-[0-9]{6}-[a-f0-9]+$' <<<"$(jq -r '.run_id' <<<"$payload")"; then
  pass "W2.2 minted run_id matches the established RUN_ID shape ^[0-9]{8}-[0-9]{6}-[a-f0-9]+\$"
else
  fail "W2.2 minted run_id matches the established RUN_ID shape (got: $(printf '%s' "$payload" | jq -r '.run_id'))"
fi
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$(jq -r '.now_iso' <<<"$payload")"; then
  pass "W2.3 now_iso is UTC ISO-8601 (YYYY-MM-DDTHH:MM:SSZ)"
else
  fail "W2.3 now_iso is UTC ISO-8601 (got: $(printf '%s' "$payload" | jq -r '.now_iso'))"
fi
# now_epoch sanity: a real recent epoch (> 2020-01-01), not 0 / garbage.
if printf '%s' "$payload" | jq -e '.now_epoch > 1577836800' >/dev/null 2>&1; then
  pass "W2.4 now_epoch is a live epoch (frozen at emission, not a placeholder)"
else
  fail "W2.4 now_epoch is a live epoch (got: $(printf '%s' "$payload" | jq -r '.now_epoch'))"
fi
[ -z "$_LAST_STDERR" ] \
  && pass "W2.5 happy path emits nothing on stderr" \
  || fail "W2.5 happy path emits nothing on stderr (got: $_LAST_STDERR)"
_assert_codex_home_plugin_root "$SOURCE_HELPER" "source helper"
HELPER="$SOURCE_HELPER"

# ---------------------------------------------------------------------------
echo "== W3: config folding + auto-typing =="
_isolate 'uberdev_emit_workflow_args uberscan areas=8 deep=true neg=-3 zerolead=007 label="hello world" fanout_concurrency.solve_bg=6'
payload="$(_payload)"
if printf '%s' "$payload" | jq -e '
    .config.areas == 8 and (.config.areas | type == "number")
    and .config.deep == true
    and .config.neg == -3
    and .config.zerolead == "007"
    and .config.label == "hello world"
    and .config["fanout_concurrency.solve_bg"] == 6
  ' >/dev/null 2>&1; then
  pass "W3.1 int → number, true → boolean, -3 → number, 007 → string, free text → string, dotted KEY is a literal JSON key"
else
  fail "W3.1 config auto-typing/folding drifted (got: $payload)"
fi
if printf '%s' "$payload" | jq -e '.config | keys | length == 6' >/dev/null 2>&1; then
  pass "W3.2 exactly the six supplied keys land under .config"
else
  fail "W3.2 exactly the six supplied keys land under .config (got: $payload)"
fi

# ---------------------------------------------------------------------------
echo "== W4: reserved overrides + locked keys =="
_isolate 'uberdev_emit_workflow_args goal run_id=20260612-010203-abc123 plugin_root=/pr repo_root=/rr cwd=/cw extra=1'
payload="$(_payload)"
if printf '%s' "$payload" | jq -e '
    .run_id == "20260612-010203-abc123"
    and .plugin_root == "/pr" and .repo_root == "/rr" and .cwd == "/cw"
    and .config == {extra: 1}
  ' >/dev/null 2>&1; then
  pass "W4.1 run_id/plugin_root/repo_root/cwd override top-level and stay OUT of .config"
else
  fail "W4.1 reserved-override routing drifted (got: $payload)"
fi
for locked in v now_epoch now_iso pipeline config; do
  _isolate "uberdev_emit_workflow_args goal $locked=x"
  if [ "$_LAST_RC" -eq 2 ] && grep -q "locked" <<<"$_LAST_STDERR"; then
    pass "W4.2 locked key '$locked' is rejected rc=2"
  else
    fail "W4.2 locked key '$locked' is rejected rc=2 (rc=$_LAST_RC, stderr: $_LAST_STDERR)"
  fi
done

# ---------------------------------------------------------------------------
echo "== W5: composition with uberdev_read_* (precedence + sentinel silence) =="
_isolate '
  export UBERDEV_TEST_FANOUT=7
  resolved="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_TEST_FANOUT 1 50 6)"
  uberdev_emit_workflow_args scan fanout="$resolved"
'
payload="$(_payload)"
if printf '%s' "$payload" | jq -e '.config.fanout == 7' >/dev/null 2>&1; then
  pass "W5.1 env-resolved value (env tier beats default) flows into .config as a number"
else
  fail "W5.1 env-resolved value flows into .config (got: $payload)"
fi
_isolate '
  printf "fanout_concurrency:\n  research: 9\n" > .claude/uberdev.local.md
  resolved="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_TEST_UNSET_VAR 1 50 6)"
  uberdev_emit_workflow_args scan fanout="$resolved"
'
payload="$(_payload)"
if printf '%s' "$payload" | jq -e '.config.fanout == 9' >/dev/null 2>&1; then
  pass "W5.2 uberdev.local.md-resolved value (file tier) flows into .config"
else
  fail "W5.2 uberdev.local.md-resolved value flows into .config (got: $payload)"
fi
_isolate '
  export UBERDEV_TEST_FANOUT=999
  resolved="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_TEST_FANOUT 1 50 6)"
  uberdev_emit_workflow_args scan fanout="$resolved"
  uberdev_emit_workflow_args scan fanout="$resolved" >/dev/null
'
payload="$(_payload)"
warn_count="$(printf '%s\n' "$_LAST_STDERR" | grep -cE "fanout_concurrency.research = .999. is invalid" || true)"
if printf '%s' "$payload" | jq -e '.config.fanout == 6' >/dev/null 2>&1 && [ "$warn_count" = "1" ]; then
  pass "W5.3 invalid value falls back via the READ helper (one D7 warn) and the emitter adds no warning of its own"
else
  fail "W5.3 read-helper warn-once + emitter silence (payload: $payload; warn_count=$warn_count)"
fi
if grep -q 'uberdev_emit_workflow_args' <<<"$_LAST_STDERR"; then
  fail "W5.4 emitter stays silent on stderr when inputs are valid (got: $_LAST_STDERR)"
else
  pass "W5.4 emitter stays silent on stderr when inputs are valid"
fi

# ---------------------------------------------------------------------------
echo "== W6: injection discipline (values are data, never code) =="
CANARY="$(mktemp -d)/canary"
_isolate "uberdev_emit_workflow_args scan sneaky='\$(touch $CANARY)' tick='\`touch $CANARY\`' quotes='\";]} bad'"
payload="$(_payload)"
if [ ! -e "$CANARY" ]; then
  pass "W6.1 command-substitution/backtick payloads in VALUEs execute nothing"
else
  fail "W6.1 command-substitution/backtick payloads in VALUEs execute nothing (canary file appeared)"
fi
if printf '%s' "$payload" | jq -e '.config.sneaky | startswith("$(touch ")' >/dev/null 2>&1 \
   && printf '%s' "$payload" | jq -e '.config.quotes == "\";]} bad"' >/dev/null 2>&1; then
  pass "W6.2 hostile bytes survive as literal JSON string content (jq --arg quoting)"
else
  fail "W6.2 hostile bytes survive as literal JSON string content (got: $payload)"
fi
if printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "W6.3 envelope stays valid JSON under hostile values"
else
  fail "W6.3 envelope stays valid JSON under hostile values"
fi
rm -rf "$(dirname "$CANARY")"

# ---------------------------------------------------------------------------
echo "== W7: never-eval discipline (structural) =="
# Function body scoped: from the function's opening line to its closing `}`.
emit_body="$(awk '/^uberdev_emit_workflow_args\(\)/{inb=1} inb{print} inb&&/^\}/{exit}' "$HELPER")"
if [ -n "$emit_body" ]; then
  pass "W7.1 uberdev_emit_workflow_args function body found in lib/config-read.sh"
else
  fail "W7.1 uberdev_emit_workflow_args function body found in lib/config-read.sh"
fi
if grep -qwE 'eval' <<<"$emit_body"; then
  fail "W7.2 emitter body must contain ZERO eval — caller-supplied KEY/VALUE may never be expanded as code"
else
  pass "W7.2 emitter body contains zero eval (KEY/VALUE travel via jq --arg only)"
fi
legacy_eval_count="$(grep -c 'eval "printf' "$HELPER" || true)"
if [ "$legacy_eval_count" = "4" ]; then
  pass "W7.3 the four legacy constant-name 'eval \"printf' sites in the read helpers are intact (no more, no fewer)"
else
  fail "W7.3 expected exactly 4 constant-name 'eval \"printf' sites in config-read.sh, found $legacy_eval_count"
fi

# ---------------------------------------------------------------------------
echo "== W8: error paths =="
_isolate 'uberdev_emit_workflow_args'
[ "$_LAST_RC" -eq 2 ] && grep -q 'missing PIPELINE' <<<"$_LAST_STDERR" \
  && pass "W8.1 missing PIPELINE → rc=2 + diagnostic" \
  || fail "W8.1 missing PIPELINE → rc=2 + diagnostic (rc=$_LAST_RC, stderr: $_LAST_STDERR)"
_isolate 'uberdev_emit_workflow_args "bad name"'
[ "$_LAST_RC" -eq 2 ] && grep -q 'invalid PIPELINE' <<<"$_LAST_STDERR" \
  && pass "W8.2 PIPELINE with disallowed chars → rc=2" \
  || fail "W8.2 PIPELINE with disallowed chars → rc=2 (rc=$_LAST_RC)"
_isolate 'uberdev_emit_workflow_args scan notakeyvalue'
[ "$_LAST_RC" -eq 2 ] && grep -q 'not KEY=VALUE' <<<"$_LAST_STDERR" \
  && pass "W8.3 non-KEY=VALUE argument → rc=2" \
  || fail "W8.3 non-KEY=VALUE argument → rc=2 (rc=$_LAST_RC)"
_isolate 'uberdev_emit_workflow_args scan "ba d=1"'
[ "$_LAST_RC" -eq 2 ] && grep -q 'invalid KEY' <<<"$_LAST_STDERR" \
  && pass "W8.4 KEY with disallowed chars → rc=2" \
  || fail "W8.4 KEY with disallowed chars → rc=2 (rc=$_LAST_RC)"
_isolate 'uberdev_emit_workflow_args scan =1'
[ "$_LAST_RC" -eq 2 ] && grep -q 'empty KEY' <<<"$_LAST_STDERR" \
  && pass "W8.5 empty KEY → rc=2" \
  || fail "W8.5 empty KEY → rc=2 (rc=$_LAST_RC)"
_isolate 'uberdev_emit_workflow_args scan 2>/dev/null || echo "MARKER_ABSENT_RC=$?"'
if grep -q 'WORKFLOW_ARGS_BEGIN' <<<"$_LAST_STDOUT"; then
  pass "W8.6 happy path still frames with markers after the error-path battery (no sticky state)"
else
  fail "W8.6 happy path still frames with markers after the error-path battery"
fi

# ---------------------------------------------------------------------------
echo "== W9: frozen-time contract is documented + enforced =="
if grep -qE 'FROZEN-TIME CONTRACT \(RFC 0012 DR-7\)' "$HELPER"; then
  pass "W9.1 helper documents the frozen-time contract (DR-7) in a comment"
else
  fail "W9.1 helper documents the frozen-time contract (DR-7) in a comment"
fi
if grep -qE 'agent-side .date.' "$HELPER"; then
  pass "W9.2 helper names agent-side date as the ONLY mid-run wall-clock source"
else
  fail "W9.2 helper names agent-side date as the ONLY mid-run wall-clock source"
fi
_isolate 'uberdev_emit_workflow_args scan now_epoch=12345'
[ "$_LAST_RC" -eq 2 ] \
  && pass "W9.3 now_epoch cannot be overridden (frozen at emission)" \
  || fail "W9.3 now_epoch cannot be overridden (rc=$_LAST_RC)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
