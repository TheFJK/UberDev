#!/usr/bin/env bash
# Shape + mechanism checks for cross-platform shell/runtime portability:
#
#   1. plugins/uberdev/hooks/run-hook.cmd — the Windows cmd.exe arm must forward
#      args via a SHIFT-based loop (mirroring the Unix `exec bash … "$@"`),
#      NOT the bare `%2 %3 … %9` form that capped at 8 args and re-split spaced
#      ones. We assert the broken form is gone, the SHIFT-loop is present, the
#      Unix arm still uses "$@", AND we model the cmd SHIFT-loop to prove it
#      forwards 11 args (incl. a spaced one) intact.
#
#   2. tests/manual/probe-prompt-file-slash-expansion.sh — the ANSI-strip must
#      remove ESC bytes portably (`tr -d '\033'`), NOT via GNU sed's `\x1B`
#      escape, which BSD/macOS sed historically treats as the literal chars
#      `x1B`, leaving the escapes in place → empty SESSION_ID → spurious
#      INDETERMINATE/exit-3 on the macOS operator. We assert the GNU-only form
#      is gone, the portable `tr` strip is present, prove the live pipeline
#      extracts a non-empty id, and prove (deterministically, on any platform)
#      that a literal-\x strip mis-extracts while the tr-based strip succeeds.
#
#   3. plugins/uberdev/lib/run_manifest.py — Windows reconciliation must use
#      the native process-record probe; os.kill(pid, 0) terminates the target
#      under CPython on Windows instead of performing a POSIX liveness check.
#
# Portable grep-and-assert + runtime model — runs green on ubuntu (GNU sed),
# windows-latest Git Bash (GNU sed), and macOS (BSD sed) alike.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_HOOK_CMD="$REPO_ROOT/plugins/uberdev/hooks/run-hook.cmd"
PROBE="$REPO_ROOT/tests/manual/probe-prompt-file-slash-expansion.sh"

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
    echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local got="$1" want="$2" desc="$3"
  if [ "$got" = "$want" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (got '$got', want '$want')"
    FAIL=$((FAIL + 1))
  fi
}

assert_nonempty() {
  local got="$1" desc="$2"
  if [ -n "$got" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (got empty)"
    FAIL=$((FAIL + 1))
  fi
}

echo "== run-hook.cmd: Windows arg-forwarding mirrors the Unix \"\$@\" contract =="

# The broken bare-arg form must be gone from EVERY bash-invocation arm.
assert_grep_not "$RUN_HOOK_CMD" \
  '%2 %3 %4 %5 %6 %7 %8 %9' \
  "broken bare '%2 %3 … %9' arg-forwarding form is removed (no 8-arg cap, no re-split)"

# A SHIFT-based accumulation loop must be present.
assert_grep "$RUN_HOOK_CMD" \
  '^shift$' \
  "cmd arm SHIFTs past the script name (%1) before accumulating the rest"
assert_grep "$RUN_HOOK_CMD" \
  '^:collect_hook_args$' \
  "cmd arm has a goto-loop label to accumulate remaining args"
assert_grep "$RUN_HOOK_CMD" \
  'set HOOK_ARGS=%HOOK_ARGS% "%~1"' \
  "each forwarded arg is de-quoted then re-quoted (survives spaces as one token)"
assert_grep "$RUN_HOOK_CMD" \
  'bash.exe" "%HOOK_DIR%%HOOK_SCRIPT%"%HOOK_ARGS%' \
  "Git-for-Windows arm forwards the accumulated %HOOK_ARGS%"
assert_grep "$RUN_HOOK_CMD" \
  '^    bash "%HOOK_DIR%%HOOK_SCRIPT%"%HOOK_ARGS%$' \
  "PATH-bash arm forwards the accumulated %HOOK_ARGS%"

# The Unix arm must still use the symmetric "$@" contract (regression guard).
assert_grep "$RUN_HOOK_CMD" \
  'exec bash "\$\{SCRIPT_DIR\}/\$\{SCRIPT_NAME\}" "\$@"' \
  "Unix arm still forwards all args via \"\$@\""

# The polyglot heredoc must stay balanced and parse as a valid shell script
# under both bash and zsh (hooks are invoked through this wrapper at runtime).
if bash -n "$RUN_HOOK_CMD" 2>/dev/null; then
  echo "  PASS  run-hook.cmd parses under bash -n (heredoc balanced)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  run-hook.cmd fails bash -n (heredoc unbalanced / Unix arm broken)"
  FAIL=$((FAIL + 1))
fi
if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$RUN_HOOK_CMD" 2>/dev/null; then
    echo "  PASS  run-hook.cmd parses under zsh -n"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  run-hook.cmd fails zsh -n"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP  zsh -n (zsh not on PATH)"
fi

echo
echo "== run-hook.cmd: model the cmd SHIFT-loop, prove N-arg + spaced forwarding =="
# Faithful POSIX model of the run-hook.cmd loop semantics:
#   set HOOK_SCRIPT=%~1 ; shift ; while %~1 nonempty: HOOK_ARGS+= " "%~1"" ; shift
# cmd `%~1` strips one layer of surrounding quotes; we pass already-bare argv and
# re-quote each token exactly as the .cmd does. The forwarded command line must
# match what the Unix `"$@"` arm would produce.
model_cmd_forward() {
  local script="$1"; shift
  local hook_args=""
  while [ "$#" -gt 0 ]; do
    hook_args="$hook_args \"$1\""
    shift
  done
  printf '%s' "bash \"DIR/$script\"$hook_args"
}

assert_eq "$(model_cmd_forward session-start)" \
          'bash "DIR/session-start"' \
          "0 extra args -> no trailing args (today's real single-token hook usage)"
assert_eq "$(model_cmd_forward myhook a1 a2 a3 a4 a5 a6 a7 a8)" \
          'bash "DIR/myhook" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8"' \
          "8 extra args all forwarded (old %9-cap boundary)"
assert_eq "$(model_cmd_forward myhook a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11)" \
          'bash "DIR/myhook" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9" "a10" "a11"' \
          "11 extra args forwarded (old bare form would silently DROP a10/a11)"
assert_eq "$(model_cmd_forward myhook one "two words" three)" \
          'bash "DIR/myhook" "one" "two words" "three"' \
          "spaced arg survives as ONE token (old bare %N would re-split it)"

echo
echo "== probe: ANSI-strip is portable (tr -d '\\033'), not the GNU-only sed \\x1B =="

# The GNU-only `\x1B` sed escape must be gone from the probe's STRIP PIPELINE.
# Match only active pipeline-continuation lines (leading-whitespace `| …`), so a
# `\x1B` mention inside the explanatory comment cannot mask a real regression.
assert_grep_not "$PROBE" \
  "^[[:space:]]*\| sed -E 's/.x1B" \
  "GNU-only 'sed -E s/\\x1B…' ANSI-strip pipeline stage is removed"
# The portable ESC-byte strip must be present as a pipeline stage. The source
# text is `tr -d '\033'` — backslash (one char) then literal 033.
assert_grep "$PROBE" \
  "^[[:space:]]*\| tr -d '.033'" \
  "portable 'tr -d \\033' ESC-byte strip pipeline stage is present"
# The residual CSI body is stripped by a POSIX sed matching only a literal '['.
assert_grep "$PROBE" \
  "^[[:space:]]*\| sed -E 's/.\[\[0-9;\]\*\[a-zA-Z\]//g'" \
  "residual CSI body stripped by POSIX sed pipeline stage (literal '[' only, no \\xHH escape)"

echo
echo "== probe: live + deterministic mechanism proof =="

# Build a realistic ANSI-decorated `claude --bg` launch banner. \xc2\xb7 is the
# UTF-8 middle dot '·'; \033[36m / \033[39m are SGR colour codes around the id.
probe_out="$(printf 'Launching agent...\nbackgrounded \xc2\xb7 \033[36ma1b2c3d4\033[39m\n')"

# (1) The FIXED pipeline (exactly as in the probe) extracts a non-empty id on
#     the live platform's sed, BSD or GNU.
sid_fixed="$(printf '%s\n' "$probe_out" \
  | tr -d '\033' \
  | sed -E 's/\[[0-9;]*[a-zA-Z]//g' \
  | awk '/backgrounded · [0-9a-f]{8}/ { print $3; exit }')"
assert_nonempty "$sid_fixed" "fixed tr-based pipeline yields non-empty SESSION_ID on live sed"
assert_eq "$sid_fixed" "a1b2c3d4" "fixed tr-based pipeline extracts the correct 8-hex id"

# (2) Deterministic, platform-independent regression kernel: when the ANSI strip
#     treats `\x` as a LITERAL backslash-x (old BSD-sed semantics), the ESC
#     bytes survive and the awk $3 mis-extracts. We force that semantics on ANY
#     sed by DOUBLING the backslash (`\\x1B`) so even a \xHH-aware sed sees the
#     literal token — reproducing the pre-fix failure mode deterministically.
sid_literal_x="$(printf '%s\n' "$probe_out" \
  | sed -E 's/\\x1B\[[0-9;]*[a-zA-Z]//g' \
  | awk '/backgrounded · [0-9a-f]{8}/ { print $3; exit }')"
if [ "$sid_literal_x" != "a1b2c3d4" ]; then
  echo "  PASS  literal-\\x strip mis-extracts (got '${sid_literal_x:-<empty>}') — the pre-fix bug, now avoided"
  PASS=$((PASS + 1))
else
  echo "  FAIL  literal-\\x strip unexpectedly succeeded — regression kernel is not exercising the bug"
  FAIL=$((FAIL + 1))
fi

# (3) `tr -d '\033'` removes ESC bytes unconditionally (the portability anchor):
#     ESC-byte count must drop to zero regardless of sed.
esc_before="$(printf '%s' "$probe_out" | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')"
esc_after="$(printf '%s' "$probe_out" | tr -d '\033' | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')"
assert_eq "$esc_before" "2" "fixture carries 2 ESC bytes pre-strip"
assert_eq "$esc_after" "0" "tr -d '\\033' removes all ESC bytes (platform-independent)"

echo
echo "== run manifest: Windows reconciliation uses a non-signaling native probe =="

if python3 -I -B -c 'import os; raise SystemExit(0 if os.name=="nt" else 1)'; then
  WINDOWS_PROBE_TMP="$(mktemp -d)"
  WINDOWS_BRIDGE_ROOT="$(cygpath -m "$WINDOWS_PROBE_TMP")"
  if (
    . "$REPO_ROOT/plugins/uberdev/lib/child-dispatch.sh"
    mkdir -p "$WINDOWS_BRIDGE_ROOT/state"
    native_record="$(_uberdev_agent_capture_owner_process_record "$WINDOWS_BRIDGE_ROOT")"
    native_pid="${native_record%%$'\t'*}"
    native_identity="${native_record#*$'\t'}"
    lease_record=''
    UBERDEV_SEMAPHORE_OWNER_PID="$native_pid" uberdev_semaphore_acquire \
      "$WINDOWS_BRIDGE_ROOT/state" windows-native-repo codex 1 windows-native-owner 30 \
      exact-identity lease_record
    lease="${lease_record%%$'\t'*}"
    _UBERDEV_AGENT_OWNER_PID="$native_pid"
    _UBERDEV_AGENT_OWNER_IDENTITY="$native_identity"
    request='{"run_id":"windows-native-owner","backend":"codex","timeout_s":30}'
    decision='{"routing_mode":"inherit","effective_policy":"inherit"}'
    event="$(_uberdev_agent_event_json agent_started "$request" "$decision" '' "$WINDOWS_BRIDGE_ROOT/status.json")"
    generation=1234567890abcdef1234567890abcdef
    printf '{"backend":"codex","state":"running","exit_code":null,"pid":"321","lease_generation":"%s"}\n' \
      "$generation" >"$WINDOWS_BRIDGE_ROOT/status.json"
    snapshot="$(shasum -a 256 "$WINDOWS_BRIDGE_ROOT/status.json" | awk '{print $1}')"
    _uberdev_child_timeout_intent_write "$WINDOWS_BRIDGE_ROOT/status.json" 321 "$generation" "$snapshot"
    python3 -I -B - "$native_pid" "$native_identity" "$lease" "$event" \
      "$WINDOWS_BRIDGE_ROOT/status.json.timeout-intent-v1" \
      "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" <<'PY'
import json,pathlib,subprocess,sys
pid,identity,lease_path,event_raw,intent_path,tool=sys.argv[1:]
lease=dict(line.split('=',1) for line in pathlib.Path(lease_path).read_text().splitlines())
event=json.loads(event_raw); intent=json.loads(pathlib.Path(intent_path).read_text())
assert lease['owner_pid']==pid and lease['owner_identity']==identity
assert str(event['owner_pid'])==pid and event['owner_process_identity']==identity
assert str(intent['waiter_pid'])==pid and intent['waiter_process_identity']==identity
probe=subprocess.run([sys.executable,'-I','-B',tool,'process-identity','--pid',pid],capture_output=True,text=True)
assert probe.returncode==0 and probe.stdout==identity
PY
    uberdev_semaphore_release "$lease"
  ); then
    echo "  PASS  native Windows owner bridge binds lease, manifest, and timeout waiter without signaling"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  native Windows owner bridge did not preserve one live native identity"
    FAIL=$((FAIL + 1))
  fi
  if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" "$WINDOWS_PROBE_TMP" <<'PY'
import importlib.util,pathlib,subprocess,sys,time
tool,tmp=sys.argv[1:]
spec=importlib.util.spec_from_file_location('run_manifest_windows_runtime',tool)
module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
assert spec.loader is not None; spec.loader.exec_module(module)
child=subprocess.Popen([sys.executable,'-I','-B','-c','import time; time.sleep(30)'])
try:
 status,identity=module._process_identity(child.pid)
 assert status=='captured' and identity
 manifest=str(pathlib.Path(tmp)/'events.jsonl')
 module.append_event(manifest,{'schema_version':2,'event':'route_decided','timestamp':'2026-07-10T00:00:00Z','run_id':'windows-native-probe','backend':'codex'})
 module.append_event(manifest,{'schema_version':2,'event':'agent_started','timestamp':'2026-07-10T00:00:01Z','run_id':'windows-native-probe','backend':'codex','owner_pid':child.pid,'owner_process_identity':identity,'backend_handle':child.pid})
 result=module.reconcile_manifest(manifest)
 assert result=={'abandoned':0,'open':1,'status':'ok'},result
 assert child.poll() is None,'liveness reconciliation terminated the process'
finally:
 if child.poll() is None: child.terminate()
 child.wait(timeout=10)
PY
  then
    echo "  PASS  native Windows reconciliation leaves its live owner process untouched"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  native Windows reconciliation signaled or abandoned a live owner"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$WINDOWS_PROBE_TMP"
else
  echo "  SKIP  native Windows reconciliation runtime (non-Windows host)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
