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
echo "== live semaphore: MSYS shell PID maps to its validated native WINPID =="

if native_pid_out="$(/bin/bash -c '
  . "$1"
  ps() {
    exit 97
  }
  UBERDEV_SEMAPHORE_TESTING=1
  listing="PID PPID PGID WINPID TTY UID STIME COMMAND
41 7 41 610 pty0 1000 12:00:00 /usr/bin/bash"
  _uberdev_semaphore_windows_native_pid 41 "$listing"
' _ "$REPO_ROOT/plugins/uberdev/lib/live-semaphore.sh")" \
    && [ "$native_pid_out" = 610 ]; then
  echo "  PASS  native owner mapping selects WINPID only from the exact shell PID row"
  PASS=$((PASS + 1))
else
  echo "  FAIL  native owner mapping did not select the exact shell WINPID: $native_pid_out"
  FAIL=$((FAIL + 1))
fi

echo
echo "== live semaphore: zsh mutex owner capture does not depend on BASH or PATH bash =="

if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP  zsh mutex owner capture (zsh not on PATH)"
else
  zsh_mutex_tmp="$(mktemp -d)"
  zsh_mutex_tmp="$(cd "$zsh_mutex_tmp" && pwd -P)"
  mkdir -p "$zsh_mutex_tmp/shadow-bin"
  cat >"$zsh_mutex_tmp/shadow-bin/bash" <<'EOF_ZSH_SHADOW_BASH'
#!/bin/sh
exit 97
EOF_ZSH_SHADOW_BASH
  chmod +x "$zsh_mutex_tmp/shadow-bin/bash"
  cat >"$zsh_mutex_tmp/bash-env" <<'EOF_ZSH_BASH_ENV'
exit 96
EOF_ZSH_BASH_ENV
  if zsh_mutex_output="$(zsh -c '
      unset BASH
      . "$1"
      PATH="$2/shadow-bin:$PATH"
      BASH_ENV="$2/bash-env"
      export PATH
      export BASH_ENV
      holder_pid="$$"
      scope="$(_uberdev_semaphore_prepare_scope "$2/state" zsh-owner-probe codex)" || exit 11
      _uberdev_semaphore_mutex_acquire "$scope" || exit 12
      owner_pid="$(sed -n "1p" "$scope/.mutex/owner_pid")"
      owner_identity="$(sed -n "2p" "$scope/.mutex/owner_pid")"
      [ "$owner_pid" = "$holder_pid" ] || exit 13
      _uberdev_semaphore_process_identity_matches "$owner_pid" "$owner_identity" || exit 14
      _uberdev_semaphore_mutex_release "$scope" || exit 15
      [ ! -e "$scope/.mutex" ] && [ ! -L "$scope/.mutex" ] || exit 16
      printf "owner=%s live=yes residue=no\n" "$owner_pid"
    ' _ "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" "$zsh_mutex_tmp" 2>"$zsh_mutex_tmp/stderr")" \
      && case "$zsh_mutex_output" in
      owner=[0-9]*' live=yes residue=no') true ;;
      *) false ;;
      esac; then
    echo "  PASS  real zsh holder publishes its live identity and releases without residue"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  real zsh holder could not publish/release its live identity: ${zsh_mutex_output:-<empty>}"
    sed -n '1,8p' "$zsh_mutex_tmp/stderr" 2>/dev/null | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$zsh_mutex_tmp"
fi

echo
echo "== run manifest: Windows reconciliation uses a non-signaling native probe =="

if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" \
    "$REPO_ROOT/plugins/uberdev/lib/live-semaphore.sh" \
    "$REPO_ROOT/plugins/uberdev/lib/agent-dispatch.sh" <<'PY'
import hashlib,importlib.util,pathlib,sys,tempfile
from unittest import mock
tool,semaphore,agent=sys.argv[1:]
source=pathlib.Path(tool).read_text(encoding='utf-8')
semaphore_source=pathlib.Path(semaphore).read_text(encoding='utf-8')
agent_source=pathlib.Path(agent).read_text(encoding='utf-8')
assert 'owner_depth = {"direct": 0, "parent": 1}.get(mode)' in source
assert 'stat.S_ISFIFO(os.fstat(1).st_mode)' not in source
candidate_helper=semaphore_source.split('_uberdev_semaphore_mutex_prepare_candidate() {',1)[1].split('\n}',1)[0]
mutex_acquire=semaphore_source.split('_uberdev_semaphore_mutex_acquire() {',1)[1].split('\n}',1)[0]
mutex_owner=semaphore_source.split('_uberdev_semaphore_capture_mutex_owner() {',1)[1].split('\n}',1)[0]
native_pid=semaphore_source.split('_uberdev_semaphore_windows_native_pid() {',1)[1].split('\n}',1)[0]
assert '_uberdev_semaphore_write_process_identity' not in candidate_helper
assert '_uberdev_semaphore_process_identity "$owner"' in mutex_owner
assert 'helper_shell="$(_uberdev_semaphore_bash_executable)"' in mutex_owner
assert "BASH_ENV='' ENV='' \"$helper_shell\" --noprofile --norc -p" in mutex_owner
assert 'command -v bash' not in semaphore_source
assert '/usr/bin/ps.exe /usr/bin/ps /bin/ps' in native_pid
assert 'listing="$(ps ' not in native_pid
assert 'mutex_owner_process_identity_unavailable' in mutex_owner
assert 'token="$(_uberdev_semaphore_mutex_prepare_candidate "$candidate")"' in mutex_acquire
assert '[ "${#token}" -eq 32 ] || return 2' in candidate_helper
assert 'case "$token" in *[!0-9a-f]*) return 2 ;; esac' in candidate_helper
assert 'candidate_rc=$?' in mutex_acquire and 'return "$candidate_rc"' in mutex_acquire
caller_length_guard='if [ "${#token}" -ne 32 ]; then'
caller_hex_guard='*[!0-9a-f]*)'
publication='if mkdir "$mutex" 2>/dev/null; then'
assert caller_length_guard in mutex_acquire and caller_hex_guard in mutex_acquire
assert 'mutex owner candidate returned malformed token' in mutex_acquire
assert mutex_acquire.index('_uberdev_semaphore_capture_mutex_owner "$candidate"') \
    < mutex_acquire.index('token="$(_uberdev_semaphore_mutex_prepare_candidate "$candidate")"') \
    < mutex_acquire.index(caller_length_guard) \
    < mutex_acquire.index(caller_hex_guard) \
    < mutex_acquire.index(publication)
assert '_uberdev_semaphore_write_process_identity "$owner_mode" "$probe"' in semaphore_source
assert 'if [ -n "$output_variable" ]; then owner_mode=direct; else owner_mode=parent; fi' in semaphore_source
assert '_uberdev_semaphore_write_process_identity parent "$probe"' in agent_source
assert '_secure_open_regular(destination, os.O_WRONLY, 0o600)' in source
assert 'open(destination, "w", encoding="ascii", newline="\\n")' not in source
assert 'owner_pid = _native_parent_pid(owner_pid)' in source
assert '_windows_guarded_parent_record(' in source
assert 'if os.name == "nt":\n        owner_depth += 1' in source
spec=importlib.util.spec_from_file_location('run_manifest_owner_depth_model',tool)
module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
assert spec.loader is not None; spec.loader.exec_module(module)
original_os_name=module.os.name
original_getppid=module.os.getppid
original_platform_probe=module._process_identity_platform
original_parent_pid=module._native_parent_pid
original_guarded_parent=module._windows_guarded_parent_record
original_process_identity=module._process_identity
try:
 with tempfile.TemporaryDirectory() as temporary:
  root=pathlib.Path(temporary)
  for name in ('posix-direct','posix-parent','windows-direct','windows-parent'):
   (root/name).touch(mode=0o600)
  module._process_identity=lambda pid: ('captured',f'{pid}|{pid}|{pid}|'+('a'*64))
  module.os.name='posix'
  module._process_identity_platform=lambda: 'linux'
  module.os.getppid=lambda: 41
  module._native_parent_pid=lambda pid: {41:73,73:1}[pid]
  module._write_process_identity('direct',str(root/'posix-direct'))
  module._write_process_identity('parent',str(root/'posix-parent'))

  windows_parent_calls=[]
  def windows_guarded_parent(pid,expected_creation_ticks=None):
   windows_parent_calls.append((pid,expected_creation_ticks))
   return {
    51:(61,6100),
    61:(71,7100),
   }[pid]
  module.os.name='nt'
  module._process_identity_platform=lambda: 'windows'
  module.os.getppid=lambda: 51
  module._native_parent_pid=lambda _pid: (_ for _ in ()).throw(
   AssertionError('Windows owner traversal used the obsolete unbound parent probe')
  )
  module._windows_guarded_parent_record=windows_guarded_parent
  module._write_process_identity('direct',str(root/'windows-direct'))
  module._write_process_identity('parent',str(root/'windows-parent'))
  assert windows_parent_calls==[(51,None),(51,None),(61,6100)]

  expected_records=(
   ('posix-direct',41,None),
   ('posix-parent',73,None),
   ('windows-direct',61,6100),
   ('windows-parent',71,7100),
  )
  for name,pid,creation_ticks in expected_records:
   digest=('a'*64) if creation_ticks is None else hashlib.sha256(
    f'windows:{creation_ticks}'.encode()
   ).hexdigest()
   expected=f'{pid}\n{pid}|{pid}|{pid}|{digest}\n'
   payload=(root/name).read_bytes()
   assert payload==expected.encode('ascii') and b'\r' not in payload

  module.os.name='posix'
  module._process_identity_platform=lambda: 'linux'
  module.os.getppid=lambda: 41
  module._native_parent_pid=lambda pid: {41:73,73:1}[pid]
  candidate=root/'secure-open-contract'
  candidate.touch(mode=0o600)
  with mock.patch.object(module,'_secure_open_regular',wraps=module._secure_open_regular) as opened:
   module._write_process_identity('direct',str(candidate))
  opened.assert_called_once_with(str(candidate),module.os.O_WRONLY,0o600)

  module.os.name='nt'
  module._process_identity_platform=lambda: 'windows'
  module.os.getppid=lambda: 51
  module._native_parent_pid=lambda _pid: (_ for _ in ()).throw(
   AssertionError('Windows error mapping used the obsolete unbound parent probe')
  )
  module._windows_guarded_parent_record=lambda _pid,_expected=None: (
   (_ for _ in ()).throw(ProcessLookupError())
  )
  try: module._write_process_identity('parent',str(root/'absent-parent'))
  except module.ManifestRuntimeError as error: assert str(error)=='process_identity_parent_absent'
  else: raise AssertionError('absent parent did not fail closed')
  module._windows_guarded_parent_record=lambda _pid,_expected=None: (
   (_ for _ in ()).throw(OSError())
  )
  try: module._write_process_identity('parent',str(root/'unavailable-parent'))
  except module.ManifestRuntimeError as error: assert str(error)=='process_identity_parent_unavailable'
  else: raise AssertionError('unavailable parent did not fail closed')
finally:
 module.os.name=original_os_name
 module.os.getppid=original_getppid
 module._process_identity_platform=original_platform_probe
 module._native_parent_pid=original_parent_pid
 module._windows_guarded_parent_record=original_guarded_parent
 module._process_identity=original_process_identity
PY
then
  echo "  PASS  owner mode and mutex candidate bridge select the live native parent identity"
  PASS=$((PASS + 1))
else
  echo "  FAIL  owner mode or mutex candidate bridge can select a transient process identity"
  FAIL=$((FAIL + 1))
fi

echo
echo "== run manifest: native Windows filesystem routing ignores mutable owner-depth models =="

if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" \
    "$REPO_ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import importlib.util,pathlib,sys,tempfile
from unittest import mock

for index,module_path in enumerate(sys.argv[1:]):
 spec=importlib.util.spec_from_file_location(f'run_manifest_windows_filesystem_{index}',module_path)
 module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
 assert spec.loader is not None; spec.loader.exec_module(module)
 with tempfile.TemporaryDirectory() as temporary:
  candidate=pathlib.Path(temporary).resolve()/'owner-candidate'
  candidate.touch(mode=0o600)
  original_platform=module.sys.platform
  original_os_name=module.os.name
  original_platform_probe=module._process_identity_platform
  original_getppid=module.os.getppid
  original_process_identity=module._process_identity
  try:
   module.sys.platform='win32'
   module.os.name='posix'
   module._process_identity_platform=lambda: None
   module.os.getppid=lambda: 41
   module._process_identity=lambda pid: (
    'captured',f'{pid}|{pid}|{pid}|'+('a'*64)
   )
   with mock.patch.object(
    module,'_open_directory_fd',
    side_effect=AssertionError('native Windows entered the POSIX dir_fd walk')
   ), mock.patch.object(
    module.os,'fchmod',
    side_effect=AssertionError('native Windows attempted POSIX fchmod'),
    create=True
   ):
    module._write_process_identity('direct',str(candidate))
  finally:
   module.sys.platform=original_platform
   module.os.name=original_os_name
   module._process_identity_platform=original_platform_probe
   module.os.getppid=original_getppid
   module._process_identity=original_process_identity
  expected='41\n41|41|41|'+('a'*64)+'\n'
  assert candidate.read_bytes()==expected.encode('ascii')
 print('native-windows-filesystem-bound')
PY
then
  echo "  PASS  native Windows filesystem routing cannot enter POSIX dir_fd operations"
  PASS=$((PASS + 1))
else
  echo "  FAIL  native Windows filesystem routing followed a mutable owner-depth model"
  FAIL=$((FAIL + 1))
fi

echo
echo "== run manifest: lease capabilities use one native-Python identity namespace =="

if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" \
    "$REPO_ROOT/plugins/uberdev/lib/live-semaphore.sh" \
    "$REPO_ROOT/plugins/uberdev/lib/agent-dispatch.sh" <<'PY'
import importlib.util,ntpath,os,pathlib,stat,sys,tempfile,types
from unittest import mock
tool,semaphore,agent=sys.argv[1:]
semaphore_source=pathlib.Path(semaphore).read_text(encoding='utf-8')
agent_source=pathlib.Path(agent).read_text(encoding='utf-8')
assert '_uberdev_semaphore_path_identity "$lease"' not in semaphore_source
assert semaphore_source.count('_uberdev_semaphore_lease_identity "$lease"')>=3
assert 'secure-remove-lease --lease-path "$lease"' in semaphore_source
assert '--generation "$generation" --identity "$identity"' in semaphore_source
release=agent_source.split('_uberdev_agent_release_exact_lease() {',1)[1].split('\n}',1)[0]
assert '_uberdev_semaphore_remove_lease "$lease" "$generation" "$native_identity"' in release
assert 'os.O_DIRECTORY' not in release and 'dir_fd=' not in release and 'rm -f' not in release
spec=importlib.util.spec_from_file_location('run_manifest_lease_identity_contract',tool)
module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
assert spec.loader is not None; spec.loader.exec_module(module)
generation='a'*32
lease_name=generation+'b'*32+'.lease'
mixed_windows_path='C:/Users/test/AppData/Local/uberdev/'+lease_name
canonical_windows_path=ntpath.abspath(mixed_windows_path)
fallback_uid=4242
assert getattr(types.SimpleNamespace(),'geteuid',lambda:fallback_uid)()==fallback_uid
fixture_uid=getattr(os,'geteuid',lambda:fallback_uid)()
fake_parent=types.SimpleNamespace(st_mode=stat.S_IFDIR|0o700,st_uid=fixture_uid)
with mock.patch.object(module.os,'path',ntpath), \
     mock.patch.object(module,'_reject_symlinked_ancestors'), \
     mock.patch.object(module.os,'lstat',return_value=fake_parent):
 canonical,name=module._validated_lease_capability_path(mixed_windows_path,generation)
 assert canonical==canonical_windows_path and name==lease_name
 for unsafe in (
  'C:/Users/test/../'+lease_name,
  'C:\\Users\\test\\..\\'+lease_name,
  'C:/Users/test/./'+lease_name,
  'C:\\Users\\test\\.\\'+lease_name,
 ):
  try:
   module._validated_lease_capability_path(unsafe,generation)
  except module.ManifestRejected as error:
   assert str(error)=='lease_path_traversal_rejected'
  else:
   raise AssertionError('lease traversal component was accepted')
with tempfile.TemporaryDirectory() as temporary:
 root=pathlib.Path(temporary)
 lease=root/(generation+'b'*32+'.lease')
 payload=f'generation={generation}\nrun_id=windows-contract\n'.encode('ascii')
 original_os_name=module.os.name
 try:
  module.os.name='nt'
  published=module.secure_write_lease(str(lease),payload)
  observed=module.secure_lease_identity(str(lease),generation)
  assert observed==published
  identity=f'{published[0]}:{published[1]}'
  try:
   module.secure_remove_lease(str(lease),generation,f'{published[0]}:{published[1]+1}')
  except module.ManifestRejected as error:
   assert str(error)=='lease_identity_mismatch'
  else:
   raise AssertionError('mismatched lease identity did not fail closed')
  assert lease.read_bytes()==payload
  module.secure_remove_lease(str(lease),generation,identity)
  assert not lease.exists()
  victim=root/'victim.txt'; victim.write_text('keep',encoding='ascii')
  try:
   module.secure_remove_lease(str(victim),generation,identity)
  except module.ManifestRejected:
   pass
  else:
   raise AssertionError('unsafe lease filename was accepted')
  assert victim.read_text(encoding='ascii')=='keep'
  try:
   module.secure_lease_identity(lease.name,generation)
  except module.ManifestRejected as error:
   assert str(error)=='lease_path_must_be_absolute'
  else:
   raise AssertionError('relative lease identity path was accepted')
 finally:
  module.os.name=original_os_name
 args=module._build_parser().parse_args([
  'secure-lease-identity','--lease-path',str(lease),'--generation',generation,
 ])
 assert vars(args)=={
  'command':'secure-lease-identity','lease_path':str(lease),'generation':generation,
 }
 remove_args=module._build_parser().parse_args([
  'secure-remove-lease','--lease-path',str(lease),'--generation',generation,
  '--identity','1:2',
 ])
 assert vars(remove_args)=={
  'command':'secure-remove-lease','lease_path':str(lease),'generation':generation,
  'identity':'1:2',
 }
PY
then
  echo "  PASS  native Python publishes, identifies, and removes one exact lease capability"
  PASS=$((PASS + 1))
else
  echo "  FAIL  native Python lease identity/removal contract is incomplete"
  FAIL=$((FAIL + 1))
fi

windows_bridge_safe_error() {
  python3 -I -B - "$1" <<'PY'
import json,re,sys
raw=sys.argv[1]
pattern=re.compile(r'[a-z][a-z0-9_.:-]{0,127}')
try:
 if len(raw)>4096: raise ValueError()
 value=json.loads(raw)
 if not isinstance(value,dict) or 'error' not in value or set(value)-{'error','reason','status'}: raise ValueError()
 if any(not isinstance(item,str) for item in value.values()): raise ValueError()
 if not pattern.fullmatch(value['error']): raise ValueError()
 if 'reason' in value and not pattern.fullmatch(value['reason']): raise ValueError()
 if 'status' in value and value['status'] not in {'error','rejected'}: raise ValueError()
 print(json.dumps(value,sort_keys=True,separators=(',',':')),end='')
except (TypeError,ValueError,json.JSONDecodeError):
 print('<unavailable>',end='')
PY
}

manifest_error='{"status":"error","error":"process_identity_unavailable"}'
manifest_error_rendered="$(windows_bridge_safe_error "$manifest_error")"
manifest_rejected_rendered="$(windows_bridge_safe_error '{"error":"invalid_process_identity_mode","status":"rejected"}')"
extra_error_rendered="$(windows_bridge_safe_error '{"error":"process_identity_unavailable","status":"error","detail":"sensitive"}')"
nonstr_error_rendered="$(windows_bridge_safe_error '{"error":7,"status":"error"}')"
invalid_status_rendered="$(windows_bridge_safe_error '{"error":"process_identity_unavailable","status":"warning"}')"
oversize_error="$(python3 -I -B -c 'import json;print(json.dumps({"error":"a"*4097,"status":"error"}),end="")')"
oversize_error_rendered="$(windows_bridge_safe_error "$oversize_error")"
if [ "$manifest_error_rendered" = '{"error":"process_identity_unavailable","status":"error"}' ] \
    && [ "$manifest_rejected_rendered" = '{"error":"invalid_process_identity_mode","status":"rejected"}' ] \
    && [ "$extra_error_rendered" = '<unavailable>' ] \
    && [ "$nonstr_error_rendered" = '<unavailable>' ] \
    && [ "$invalid_status_rendered" = '<unavailable>' ] \
    && [ "$oversize_error_rendered" = '<unavailable>' ]; then
  echo "  PASS  diagnostic sanitizer retains closed manifest errors and rejects untrusted fields"
  PASS=$((PASS + 1))
else
  echo "  FAIL  diagnostic sanitizer accepted malformed or discarded valid manifest evidence"
  FAIL=$((FAIL + 1))
fi

owner_bridge_contract_tmp="$(mktemp -d)"
if (
  trap 'rm -rf "$owner_bridge_contract_tmp"' EXIT
  . "$REPO_ROOT/plugins/uberdev/lib/child-dispatch.sh"
  bridge_writer_case=closed
  _uberdev_semaphore_write_process_identity() {
    case "$bridge_writer_case" in
      closed) printf '%s\n' '{"status":"error","error":"process_identity_parent_absent"}'; return 1 ;;
      extra) printf '%s\n' '{"status":"error","error":"process_identity_parent_absent","detail":"unsafe"}'; return 1 ;;
      crlf) printf '41\r\n41|41|41|%064d\r\n' 0 >"$2"; return 0 ;;
      *) return 2 ;;
    esac
  }
  set +e
  closed_output="$(_uberdev_agent_capture_owner_process_record "$owner_bridge_contract_tmp")"
  closed_rc=$?
  bridge_writer_case=extra
  extra_output="$(_uberdev_agent_capture_owner_process_record "$owner_bridge_contract_tmp")"
  extra_rc=$?
  bridge_writer_case=crlf
  crlf_output="$(_uberdev_agent_capture_owner_process_record "$owner_bridge_contract_tmp")"
  crlf_rc=$?
  set -e
  remaining_probe=''
  for candidate in "$owner_bridge_contract_tmp"/.owner-process.* \
      "$owner_bridge_contract_tmp"/.owner-process-output.*; do
    [ ! -e "$candidate" ] || remaining_probe="$candidate"
  done
  [ "$closed_rc" -eq 1 ] \
    && [ "$closed_output" = '{"error":"process_identity_parent_absent","status":"error"}' ] \
    && [ "$extra_rc" -eq 1 ] \
    && [ "$extra_output" = '{"error":"owner_process_identity_writer_failed","status":"error"}' ] \
    && [ "$crlf_rc" -eq 2 ] \
    && [ "$crlf_output" = '{"error":"owner_process_record_malformed","status":"error"}' ] \
    && [ -z "$remaining_probe" ]
); then
  echo "  PASS  owner bridge preserves safe writer failures and rejects CRLF or untrusted records"
  PASS=$((PASS + 1))
else
  echo "  FAIL  owner bridge leaked, rewrote status, or retained an unsafe probe"
  FAIL=$((FAIL + 1))
  rm -rf "$owner_bridge_contract_tmp"
fi

if python3 -I -B - "$0" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
block=source.split("if python3 -I -B -c 'import os; raise SystemExit(0 if os.name==\"nt\" else 1)'; then",1)[1]
block=block.split("if python3 -I -B - \"$REPO_ROOT/plugins/uberdev/lib/run_manifest.py\"",1)[0]
assert '\n  (\n' in block
assert '\n  WINDOWS_RUNTIME_RC=$?\n' in block
assert 'if (\n' not in block
assert 'if [ "$WINDOWS_RUNTIME_RC" -eq 0 ]; then' in block
assert 'shasum -a 256 "$WINDOWS_BRIDGE_ROOT/status.json"' not in block
assert 'hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()' in block
assert '$(_uberdev_child_timeout_intent_write' not in block
assert 'if _uberdev_child_timeout_intent_write "$WINDOWS_BRIDGE_ROOT/status.json" 321 "$generation" "$snapshot" 2>/dev/null; then' in block
PY
then
  echo "  PASS  native Windows assertion block reports its own failing status"
  PASS=$((PASS + 1))
else
  echo "  FAIL  native Windows assertion block can hide a failed assertion"
  FAIL=$((FAIL + 1))
fi

snapshot_contract_file="$(mktemp)"
printf 'abc' >"$snapshot_contract_file"
snapshot_contract_hash="$(python3 -I -B -c 'import hashlib,pathlib,sys;print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest(),end="")' "$snapshot_contract_file")"
rm -f "$snapshot_contract_file"
if [ "$snapshot_contract_hash" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]; then
  echo "  PASS  snapshot hashing uses portable Python hashlib with exact file bytes"
  PASS=$((PASS + 1))
else
  echo "  FAIL  portable snapshot hashing produced the wrong digest"
  FAIL=$((FAIL + 1))
fi

if python3 -I -B -c 'import os; raise SystemExit(0 if os.name=="nt" else 1)'; then
  WINDOWS_PROBE_TMP="$(mktemp -d)"
  WINDOWS_BRIDGE_ROOT="$(cygpath -m "$WINDOWS_PROBE_TMP")"
  WINDOWS_BRIDGE_DIAGNOSTIC="$WINDOWS_BRIDGE_ROOT/owner-bridge-diagnostic"
  (
    . "$REPO_ROOT/plugins/uberdev/lib/child-dispatch.sh"
    set -e
    windows_child_controller=''
    windows_child_stop="$WINDOWS_BRIDGE_ROOT/child-stop"
    windows_intent_path="$WINDOWS_BRIDGE_ROOT/status.json.timeout-intent-v1"
    native_pid=''
    native_identity=''
    direct_pid=''
    direct_identity=''
    direct_raw=''
    lease=''
    event=''
    probe_output=''
    probe_rc=''
    windows_stage=owner
    windows_stage_rc=0
    windows_stage_raw=''
    cleanup_windows_child() {
      if [ -n "$windows_child_controller" ]; then
        : >"$windows_child_stop"
        wait "$windows_child_controller" 2>/dev/null || true
      fi
    }
    windows_bridge_exit() {
      windows_bridge_rc=$?
      trap - EXIT
      set +e
      if [ "$windows_bridge_rc" -ne 0 ]; then
        [ "$windows_stage_rc" -ne 0 ] || windows_stage_rc=$windows_bridge_rc
        windows_stage_safe_raw="$(windows_bridge_safe_error "$windows_stage_raw" 2>/dev/null)" \
          || windows_stage_safe_raw='<unavailable>'
        python3 -I -B - "$windows_stage" "$windows_stage_rc" "$windows_stage_safe_raw" \
          "$native_pid" "$native_identity" "$lease" "$event" "$windows_intent_path" \
          "$probe_rc" "$probe_output" >>"$WINDOWS_BRIDGE_DIAGNOSTIC" <<'PY'
import json,pathlib,re,sys
stage,stage_rc,stage_safe_raw,owner_pid,owner_identity,lease_path,event_raw,intent_path,probe_rc,probe_output=sys.argv[1:]
identity_pattern=re.compile(r'[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}')
stage_pattern=re.compile(r'[a-z][a-z0-9-]{0,31}')
def safe_pid(value):
 value=str(value)
 return value if value.isdigit() and int(value)>0 else '<unavailable>'
def safe_identity(value):
 value=str(value)
 return value if identity_pattern.fullmatch(value) else '<unavailable>'
def read_pairs(path):
 try:
  entry=pathlib.Path(path)
  if not entry.is_file() or entry.stat().st_size>16384: return {}
  return dict(line.split('=',1) for line in entry.read_text(encoding='utf-8').splitlines() if '=' in line)
 except (OSError,UnicodeError,ValueError): return {}
def read_json(raw='',path=''):
 try:
  if path:
   entry=pathlib.Path(path)
   if not entry.is_file() or entry.stat().st_size>16384: return {}
   return json.loads(entry.read_text(encoding='utf-8'))
  if len(raw)>16384: return {}
  return json.loads(raw)
 except (OSError,UnicodeError,ValueError,TypeError,json.JSONDecodeError): return {}
lease=read_pairs(lease_path)
event=read_json(raw=event_raw)
intent=read_json(path=intent_path)
print(f'stage={stage if stage_pattern.fullmatch(stage) else "<unavailable>"}')
print(f'rc={stage_rc if stage_rc.isdigit() else "<unavailable>"}')
print(f'raw={stage_safe_raw}')
print(f'owner pid={safe_pid(owner_pid)} identity={safe_identity(owner_identity)}')
print(f'lease pid={safe_pid(lease.get("owner_pid",""))} identity={safe_identity(lease.get("owner_identity",""))}')
print(f'event pid={safe_pid(event.get("owner_pid",""))} identity={safe_identity(event.get("owner_process_identity",""))}')
print(f'intent pid={safe_pid(intent.get("waiter_pid",""))} identity={safe_identity(intent.get("waiter_process_identity",""))}')
print(f'process-identity probe rc={probe_rc if probe_rc.isdigit() else "<unavailable>"} identity={safe_identity(probe_output)}')
PY
      fi
      cleanup_windows_child
      exit "$windows_bridge_rc"
    }
    trap windows_bridge_exit EXIT
    mkdir -p "$WINDOWS_BRIDGE_ROOT/state"
    if native_record="$(_uberdev_agent_capture_owner_process_record "$WINDOWS_BRIDGE_ROOT" 2>/dev/null)"; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw="$native_record"
      false
    fi
    native_pid="${native_record%%$'\t'*}"
    native_identity="${native_record#*$'\t'}"
    case "$native_pid:$native_identity" in
      *[!0-9\|a-f:]*) windows_stage_rc=2; windows_stage_raw='{"error":"owner_record_malformed"}'; false ;;
    esac
    windows_stage=owner-direct
    direct_probe="$WINDOWS_BRIDGE_ROOT/direct-owner-record"
    direct_output="$WINDOWS_BRIDGE_ROOT/direct-owner-output"
    (umask 077; : >"$direct_probe")
    if _uberdev_semaphore_write_process_identity direct "$direct_probe" \
        >"$direct_output" 2>/dev/null; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      if direct_raw="$(python3 -I -B -c 'import pathlib,sys;path=pathlib.Path(sys.argv[1]);print(path.read_text(encoding="utf-8") if path.is_file() and path.stat().st_size<=4096 else "",end="")' "$direct_output" 2>/dev/null)"; then :; else direct_raw=''; fi
      windows_stage_raw="$direct_raw"
      false
    fi
    read -r direct_pid <"$direct_probe" || direct_pid=''
    direct_identity="$(sed -n '2p' "$direct_probe" 2>/dev/null || true)"
    if [ "$direct_pid" != "$native_pid" ] || [ "$direct_identity" != "$native_identity" ]; then
      windows_stage_rc=1
      windows_stage_raw='{"error":"owner_bridge_identity_mismatch"}'
      false
    fi
    windows_stage=probe
    if probe_output="$(python3 -I -B "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" process-identity --pid "$native_pid" 2>/dev/null)"; then
      probe_rc=0
    else
      probe_rc=$?
      windows_stage_rc=$probe_rc
      windows_stage_raw="$probe_output"
      false
    fi
    if [ "$probe_output" != "$native_identity" ]; then
      windows_stage_rc=1
      windows_stage_raw='{"error":"process_identity_mismatch"}'
      false
    fi
    lease_record=''
    windows_stage=lease
    if UBERDEV_SEMAPHORE_OWNER_PID="$native_pid" uberdev_semaphore_acquire \
        "$WINDOWS_BRIDGE_ROOT/state" windows-native-repo codex 1 windows-native-owner 30 \
        exact-identity lease_record 2>/dev/null; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw="{\"error\":\"${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-lease_acquire_failed}\"}"
      false
    fi
    lease="${lease_record%%$'\t'*}"
    lease_capability="${lease_record#*$'\t'}"
    lease_generation="${lease_capability##*:}"
    lease_expected_identity="${lease_capability%:*}"
    windows_stage=lease-identity
    if lease_observed_identity="$(_uberdev_semaphore_lease_identity "$lease" "$lease_generation" 2>/dev/null)"; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw='{"error":"lease_identity_probe_failed"}'
      false
    fi
    if [ "$lease_observed_identity" != "$lease_expected_identity" ]; then
      windows_stage_rc=1
      windows_stage_raw='{"error":"lease_identity_mismatch"}'
      false
    fi
    _UBERDEV_AGENT_OWNER_PID="$native_pid"
    _UBERDEV_AGENT_OWNER_IDENTITY="$native_identity"
    request='{"run_id":"windows-native-owner","backend":"codex","timeout_s":30}'
    decision='{"routing_mode":"inherit","effective_policy":"inherit"}'
    windows_stage=event
    if event="$(_uberdev_agent_event_json agent_started "$request" "$decision" '' "$WINDOWS_BRIDGE_ROOT/status.json" 2>/dev/null)"; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw="$event"
      false
    fi
    generation=1234567890abcdef1234567890abcdef
    printf '{"backend":"codex","state":"running","exit_code":null,"pid":"321","lease_generation":"%s"}\n' \
      "$generation" >"$WINDOWS_BRIDGE_ROOT/status.json"
    snapshot="$(python3 -I -B -c 'import hashlib,pathlib,sys;print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest(),end="")' "$WINDOWS_BRIDGE_ROOT/status.json")"
    windows_stage=intent
    if _uberdev_child_timeout_intent_write "$WINDOWS_BRIDGE_ROOT/status.json" 321 "$generation" "$snapshot" 2>/dev/null; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw='{"error":"timeout_intent_write_failed"}'
      false
    fi
    windows_stage=intent-probe
    intent_probe_output=''
    if intent_probe_output="$(_uberdev_agent_timeout_intent_probe "$WINDOWS_BRIDGE_ROOT/status.json" 321 "$generation" 2>/dev/null)"; then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
    fi
    if [ "$windows_stage_rc" -ne 0 ] || [ "$intent_probe_output" != valid ]; then
      [ "$windows_stage_rc" -ne 0 ] || windows_stage_rc=1
      windows_stage_raw='{"error":"timeout_intent_probe_failed"}'
      false
    fi
    windows_stage=owner-evidence
    if python3 -I -B - "$native_pid" "$native_identity" "$lease" "$event" <<'PY'
import json,pathlib,sys
pid,identity,lease_path,event_raw=sys.argv[1:]
lease=dict(line.split('=',1) for line in pathlib.Path(lease_path).read_text().splitlines())
event=json.loads(event_raw)
assert lease['owner_pid']==pid and lease['owner_identity']==identity
assert str(event['owner_pid'])==pid and event['owner_process_identity']==identity
PY
    then
      windows_stage_rc=0
    else
      windows_stage_rc=$?
      windows_stage_raw='{"error":"identity_evidence_mismatch"}'
      false
    fi
    windows_stage=runtime-assertion
    windows_child_pid_file="$WINDOWS_BRIDGE_ROOT/child-pid"
    python3 -I -B - "$windows_child_pid_file" "$windows_child_stop" <<'PY' &
import pathlib,subprocess,sys,time
pid_path,stop_path=map(pathlib.Path,sys.argv[1:])
child=subprocess.Popen([sys.executable,'-I','-B','-c','import time; time.sleep(30)'])
try:
 pid_path.write_text(str(child.pid),encoding='ascii')
 while not stop_path.exists() and child.poll() is None: time.sleep(0.05)
finally:
 if child.poll() is None: child.terminate()
 child.wait(timeout=10)
PY
    windows_child_controller=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ ! -s "$windows_child_pid_file" ] || break
      sleep 0.1
    done
    windows_child_pid="$(cat "$windows_child_pid_file")"
    windows_child_identity="$(python3 -I -B \
      "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" process-identity --pid "$windows_child_pid")"
    cancel_calls="$WINDOWS_BRIDGE_ROOT/cancel-calls"
    _uberdev_dispatch_owned_group_state() { printf 'owned-group\n' >>"$cancel_calls"; return 1; }
    _uberdev_dispatch_group_owned_session() { printf 'group-session\n' >>"$cancel_calls"; return 1; }
    kill() { printf 'signal\n' >>"$cancel_calls"; return 0; }
    set +e
    _uberdev_dispatch_cancel_backend background "$windows_child_pid" "$windows_child_identity"
    cancel_rc=$?
    set -e
    [ "$cancel_rc" -eq 2 ]
    [ "$_UBERDEV_DISPATCH_CANCEL_REASON" = provider_cancel_unconfirmed ]
    [ ! -e "$cancel_calls" ]
    ! _uberdev_dispatch_numeric_supervision_supported codex
    ! _uberdev_dispatch_numeric_supervision_supported background
    _uberdev_dispatch_numeric_supervision_supported wezterm
    _uberdev_dispatch_numeric_supervision_supported wezterm
    # RFC 0015: `workflow` spawns no OS process, so the numeric-supervision gate
    # does not apply to it — this is what makes native Windows a first-class
    # host without WezTerm.
    _uberdev_dispatch_numeric_supervision_supported workflow
    _uberdev_dispatch_codex_available() { return 0; }
    for rejected_backend in codex background; do
      unset UBERDEV_RESOLVED_BACKEND
      UBERDEV_DISPATCH_BACKEND_REQUESTED="$rejected_backend"
      export UBERDEV_DISPATCH_BACKEND_REQUESTED
      ! uberdev_dispatch_preflight solve >/dev/null 2>&1
      [ -z "${UBERDEV_RESOLVED_BACKEND+x}" ]
    done
    # RFC 0015 changed this arm: `auto` on native Windows used to HARD-ERROR
    # when WezTerm was unavailable, because every candidate backend needed a
    # supervisable process tree. It now resolves to `workflow`, which has no
    # process tree at all. This block is native-Windows-only — there is no
    # macOS CI job and Linux never enters it — so it is the sole guard against
    # the auto matrix regressing on Windows.
    unset CODEX_HOME UBERDEV_RESOLVED_BACKEND
    UBERDEV_DISPATCH_BACKEND_REQUESTED=auto
    export UBERDEV_DISPATCH_BACKEND_REQUESTED
    _uberdev_dispatch_wezterm_available() { return 1; }
    claude() { return 0; }
    uberdev_dispatch_preflight solve >/dev/null 2>&1
    [ "${UBERDEV_RESOLVED_BACKEND:-}" = workflow ]
    windows_stage=lease-release-wrong-identity
    release_identity="$(_uberdev_agent_lease_identity "$lease")"
    release_native_identity="${release_identity%:*}"
    release_device="${release_native_identity%%:*}"
    release_inode="${release_native_identity#*:}"
    if [ "$release_inode" = 0 ]; then wrong_release_inode=1; else wrong_release_inode=0; fi
    ! _uberdev_agent_release_exact_lease "$lease" \
      "$release_device:$wrong_release_inode:$lease_generation" >/dev/null 2>&1
    [ -f "$lease" ] && [ ! -L "$lease" ]
    windows_stage=lease-release-wrong-generation
    wrong_release_generation=00000000000000000000000000000000
    [ "$wrong_release_generation" != "$lease_generation" ] \
      || wrong_release_generation=11111111111111111111111111111111
    ! _uberdev_agent_release_exact_lease "$lease" \
      "$release_native_identity:$wrong_release_generation" >/dev/null 2>&1
    [ -f "$lease" ] && [ ! -L "$lease" ]
    windows_stage=lease-release-replacement
    replacement_lease="$(dirname "$lease")/${lease_generation}eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.lease"
    [ "$replacement_lease" != "$lease" ] \
      || replacement_lease="$(dirname "$lease")/${lease_generation}ffffffffffffffffffffffffffffffff.lease"
    _uberdev_semaphore_publish_lease "$(dirname "$lease")" "$replacement_lease" \
      windows-native-replacement "$native_pid" "$native_identity" '' '' \
      "$(date +%s)" 30 "$WINDOWS_BRIDGE_ROOT/status.json"
    python3 -I -B -c 'import os,sys;os.replace(sys.argv[1],sys.argv[2])' \
      "$replacement_lease" "$lease"
    replacement_identity="$(_uberdev_agent_lease_identity "$lease")"
    [ "$replacement_identity" != "$release_identity" ]
    ! _uberdev_agent_release_exact_lease "$lease" "$release_identity" >/dev/null 2>&1
    [ -f "$lease" ] && [ ! -L "$lease" ]
    windows_stage=lease-release-exact
    _uberdev_agent_release_exact_lease "$lease" "$replacement_identity"
    [ ! -e "$lease" ] && [ ! -L "$lease" ]
    cleanup_windows_child
    windows_child_controller=''
    trap - EXIT
  )
  WINDOWS_RUNTIME_RC=$?
  if [ "$WINDOWS_RUNTIME_RC" -eq 0 ]; then
    echo "  PASS  native Windows owner bridge binds identity and rejects unverifiable numeric cancellation"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  native Windows owner bridge did not preserve one live native identity"
    if [ -f "$WINDOWS_BRIDGE_DIAGNOSTIC" ]; then
      windows_diagnostic_lines=0
      while IFS= read -r windows_diagnostic_line \
          && [ "$windows_diagnostic_lines" -lt 8 ]; do
        printf '        %s\n' "$windows_diagnostic_line"
        windows_diagnostic_lines=$((windows_diagnostic_lines + 1))
      done <"$WINDOWS_BRIDGE_DIAGNOSTIC"
    fi
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
