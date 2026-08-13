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

# ---------------------------------------------------------------------------
# ONE corpus enumeration and ONE file predicate, shared by the THREE zsh
# runtime-class guards below (parameter modifiers, tied parameters, and
# `trap … RETURN`). Extracted when the second consumer arrived (#401): a
# hand-rolled second copy would be the "one contract, N uncompared copies" drift
# (#370/#371) that this file's own header is about, in the file that is about it.
#
# The third consumer arrived in #413, and it arrived because a DECLARED boundary
# is still a second copy. #401 wrote one here in prose — "the zsh-MODIFIER guard
# keeps its own, narrower `find`" — and that guard's own corpus was
# `plugins/**` with `-name '*.md' -o -name '*.sh'`, so it read neither `tests/`
# nor `tools/` nor a single extension-less shipped hook: the two gaps the tied
# guard had already had to close, twice, each time finding live hits. Pointing
# it at this pair found six more mangled shapes in `tests/`, exactly as the
# distribution argument predicted — four refspec assertions in
# tests/review-pr.test.sh (the same pins the modifier block's own prose already
# named as having pinned the broken literal, still unbraced long after the
# production side was fixed) and two `doc:name` pairing loops in
# tests/review-child-handoff.test.sh, where `:r` quietly strips the `.md` off
# the doc path and `:s` is a hard `bad substitution`. There is now no fourth
# copy to declare a boundary against.
#
# The enumeration was widened five times (plugins/lib → +commands/skills/agents/
# hooks → +tests/tools); each widening found live hits, so it is deliberately
# `-type f` over whole directories with the shape decision made by the predicate.
_xshell_corpus() {
  find "$REPO_ROOT/plugins/uberdev/commands" "$REPO_ROOT/plugins/uberdev/skills" \
       "$REPO_ROOT/plugins/uberdev/lib" "$REPO_ROOT/plugins/uberdev/agents" \
       "$REPO_ROOT/plugins/uberdev/hooks" \
       "$REPO_ROOT/tests" "$REPO_ROOT/tools" \
       -type f 2>/dev/null | sort
}

# THE FILE PREDICATE, and the fifth widening it encodes. It used to be
# `-name '*.sh' -o -name '*.md'`, and NONE of the shipped hooks carry an
# extension — `session-start`, `session-end`, `pre-compact`,
# `inject-brainstorm-answers`, plus `lib/rl-curl` — so all of them were listed
# as scanned and none of them ever were. Behind that gap sat
# `is_safe_path() { local root="$1" path="$2"; ... }` in
# inject-brainstorm-answers, the hook's symlink/traversal check.
#
# Both shipped wirings reach that hook through bash (hooks.json goes via
# `run-hook.cmd`, whose Unix arm is `exec bash`; hooks-cursor.json execs the file
# so its `#!/usr/bin/env bash` shebang governs), so it was NOT broken in
# production. What made it worth calling out is the direction of the failure:
# `canonicalize` shells out to python3/realpath, so with `$PATH` emptied by the
# tied `path` the check cannot resolve anything and refuses EVERY path,
# including legitimate ones (verified live: the pre-rename body accepts under
# bash and refuses under zsh). A security check that fails closed is the good
# direction; a security check that has silently never been scanned is not.
#
# So the predicate is "names it like a shell file, OR says it is one" — matched
# on the BASENAME, because the repo's own worktree paths contain dots
# (`.claude/worktrees/...`) and a full-path `*.*` test would skip nearly
# everything.
_xshell_is_shell_surface() {
  case "${1##*/}" in
    *.sh|*.md|*.tmpl) return 0 ;;
    *.*)       return 1 ;;
    *) head -n 1 "$1" 2>/dev/null \
         | grep -qE '^#!.*[/ ](ba|z|k|a|da)?sh([[:space:]]|$)' ;;
  esac
}

echo
echo "== zsh parameter modifiers: an unbraced \$var:<letter> silently eats the colon =="

# THE CLASS. Every `bash` fence in a command/skill markdown is executed by the
# harness through /bin/zsh on macOS, and zsh applies HISTORY-STYLE MODIFIERS to
# a brace-less parameter expansion: `"$sha:refs/heads/x"` expands as
# `${sha:r}` + `efs/heads/x`, i.e. `<sha>efs/heads/x`. The colon is gone, the
# refspec is garbage, and `git push` dies with "src refspec ... does not match
# any" — a failure whose message names neither zsh nor the modifier. bash
# expands the identical string correctly, so a bash-only local run never sees
# it. Found live on the trust-anchor publish in commands/review-pr.md, which had
# shipped this shape and whose test pinned the broken literal.
# `P` (realpath) is in the list because zsh has it and omitting it made the
# guard blind to `"$dir:Pxyz"` — proven live: `zsh -c 'V=/tmp/x; print -r --
# "$V:Prefs"'` prints `/private/tmp/xrefs`, the colon and the `P` both eaten.
#
# THE LETTER CLASS IS A CLAIM ABOUT ZSH, and it used to be wrong in the
# permissive direction: `p`, `U`, `W`, `x` and `X` were listed as modifiers and
# zsh applies none of them to a parameter expansion (`zsh -c 'V=/tmp/a.txt;
# print -r -- "$V:Urest"'` prints `/tmp/a.txt:Urest`, colon intact — `p` is a
# history-expansion-only modifier, and `W`/`x`/`X` need forms this shape never
# reaches). Harmless while the corpus was five plugin directories and empty of
# them; the moment #413 pointed the guard at `tests/` it started punishing
# PowerShell, because `"-Path $env:UBERDEV_JUNCTION_PATH"` in
# tests/review-child-handoff.test.sh is a namespace reference that no shell ever
# expands and that zsh leaves alone. A guard that reds on a line zsh does not
# mangle cannot be fixed by bracing anything, so it is not a guard. The class is
# now exactly the set zsh really applies, pinned in BOTH directions by the live
# rows at the end of this block: no letter in it is decoration, and no letter
# outside it is a blind spot.
ZSH_MODIFIER_LETTERS='aAcefFghlPqQrstuw'
# The name class admits DIGITS and the punctuation parameters, because a
# positional parameter is mangled exactly like a named one and the old
# `\$[A-Za-z_]` anchor could never match it: `zsh -c 'f(){ print -r --
# "$1:refs/heads/x"; }; f abc123'` prints `abc123efs/heads/x`. A helper doing
# `git push origin "$1:refs/heads/$b"` was invisible to this guard.
ZSH_MODIFIER_NAME_HEAD='A-Za-z_0-9@*#?-'
# ONE detector, four consumers: the corpus scan, the dead-marker row, the
# anti-vacuity row and the anti-false-positive row. A second copy of this regex
# is exactly the "one contract, N uncompared copies" drift this file's own header
# is about — every row below must fire on the same regex the scan uses, or it is
# proving something about a detector that is not the one shipping.
ZSH_MODIFIER_DETECT="\\\$[$ZSH_MODIFIER_NAME_HEAD][A-Za-z0-9_]*:[$ZSH_MODIFIER_LETTERS]"
# Comment-stripped, because the two braced call sites NAME the broken shape in
# order to explain why the braces are load-bearing — and a guard that punished
# its own explanation would be unfixable (the S13.11d/S21.9 precedent).
#
# THE ALLOW MARKER, same mechanism and same reason as the tied guard's below:
# the #413 widening sweeps in the rows that MUST keep the broken shape — this
# block's own anti-vacuity heredoc and its three live `zsh -c` probes, which
# prove the mangle by performing it. Excluding this FILE would go blind to real
# drift across a thousand lines, so the exemption is keyed on a marker that has
# to sit in a TRAILING COMMENT on the offending line, and the two rows after the
# scan keep it honest: every marker must sit on a line the detector really would
# have caught, and the marked-line inventory is pinned per file. Marker and
# matcher are separate variables on purpose — the matcher needs a literal `#`,
# so interpolating the marker keeps these two definitions from registering as
# markers themselves.
ZSH_MODIFIER_MARKER='zsh-modifier-fixture'
ZSH_MODIFIER_ALLOW="#[^#]*$ZSH_MODIFIER_MARKER"
ZSH_MODIFIER_HITS=""
ZSH_MODIFIER_MARKED=""
while IFS= read -r zsh_scan_file; do
  _xshell_is_shell_surface "$zsh_scan_file" || continue
  zsh_scan_rel="${zsh_scan_file#"$REPO_ROOT"/}"
  # Numbered BEFORE either filter, so a reported number is the line's real one.
  # The pre-#413 form stripped whole-line comments first and reported post-strip
  # offsets; that was survivable across five plugin directories and is not
  # across two hundred test files, where the reader has to find the hit by hand.
  zsh_scan_hit="$(grep -nE "$ZSH_MODIFIER_DETECT" "$zsh_scan_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE "$ZSH_MODIFIER_ALLOW" \
    || true)"
  # EVERY line carries the path, not just the first — the rows below parse these
  # entries back apart on `:`.
  while IFS= read -r zsh_scan_line; do
    [ -n "$zsh_scan_line" ] || continue
    ZSH_MODIFIER_HITS="$ZSH_MODIFIER_HITS${ZSH_MODIFIER_HITS:+
}$zsh_scan_rel:$zsh_scan_line"
  done <<EOF_ZSH_SCAN_HIT
$zsh_scan_hit
EOF_ZSH_SCAN_HIT
  zsh_scan_mark="$(grep -nE "$ZSH_MODIFIER_ALLOW" "$zsh_scan_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    || true)"
  while IFS= read -r zsh_scan_line; do
    [ -n "$zsh_scan_line" ] || continue
    ZSH_MODIFIER_MARKED="$ZSH_MODIFIER_MARKED${ZSH_MODIFIER_MARKED:+
}$zsh_scan_rel:$zsh_scan_line"
  done <<EOF_ZSH_SCAN_MARK
$zsh_scan_mark
EOF_ZSH_SCAN_MARK
done <<EOF_ZSH_SCAN
$(_xshell_corpus)
EOF_ZSH_SCAN
if [ -z "$ZSH_MODIFIER_HITS" ]; then
  echo "  PASS  no plugin, test or tool shell surface has an unbraced \$var:<modifier-letter>"
  PASS=$((PASS + 1))
else
  echo "  FAIL  an unbraced \$var:<modifier-letter> would be mangled by zsh — brace it as \${var}:"
  printf '        %s\n' "$ZSH_MODIFIER_HITS"
  FAIL=$((FAIL + 1))
fi

# The allow-list must not be able to hide anything. A marker on a line the
# detector would NOT have caught is either decoration or a fishing attempt to
# neutralise a whole region, and either way it makes the exemption unreviewable.
ZSH_MODIFIER_DEAD_MARKERS=""
while IFS= read -r zsh_modifier_entry; do
  [ -n "$zsh_modifier_entry" ] || continue
  # `rel:NNN:content` — two shortest-prefix strips leave the content, and the
  # content is what the detector has to agree is a real mangled expansion.
  zsh_modifier_body="${zsh_modifier_entry#*:}"
  zsh_modifier_body="${zsh_modifier_body#*:}"
  printf '%s\n' "$zsh_modifier_body" | grep -qE "$ZSH_MODIFIER_DETECT" && continue
  ZSH_MODIFIER_DEAD_MARKERS="$ZSH_MODIFIER_DEAD_MARKERS${ZSH_MODIFIER_DEAD_MARKERS:+
}$zsh_modifier_entry"
done <<EOF_ZSH_MODIFIER_DEAD
$ZSH_MODIFIER_MARKED
EOF_ZSH_MODIFIER_DEAD
if [ -z "$ZSH_MODIFIER_DEAD_MARKERS" ]; then
  echo "  PASS  every $ZSH_MODIFIER_MARKER marker sits on an expansion the detector really catches"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a $ZSH_MODIFIER_MARKER marker exempts a line the detector would not have flagged"
  printf '        %s\n' "$ZSH_MODIFIER_DEAD_MARKERS"
  FAIL=$((FAIL + 1))
fi

# ...and it must not grow silently. The inventory is pinned per file, so ADDING
# an exemption is a diff a reviewer has to approve rather than a line that
# quietly stops being scanned. Both directions matter: a count that DROPS means
# a deliberately-broken fixture got "consistency-fixed" and the rows below
# stopped proving anything.
ZSH_MODIFIER_INVENTORY="$(printf '%s\n' "$ZSH_MODIFIER_MARKED" \
  | grep -v '^$' \
  | sed 's/:[0-9][0-9]*:.*$//' \
  | sort | uniq -c \
  | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*\(.*\)$/\2 \1/')"
ZSH_MODIFIER_INVENTORY_EXPECTED='tests/crossplatform-shell-wrappers.test.sh 6'
if [ "$ZSH_MODIFIER_INVENTORY" = "$ZSH_MODIFIER_INVENTORY_EXPECTED" ]; then
  echo "  PASS  the modifier allow-list is exactly the pinned fixture inventory"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the modifier allow-list drifted from its pinned inventory"
  printf '        expected: %s\n' "$ZSH_MODIFIER_INVENTORY_EXPECTED"
  printf '        actual:   %s\n' "$ZSH_MODIFIER_INVENTORY"
  FAIL=$((FAIL + 1))
fi

# Anti-vacuity: the grep above must actually fire on the shape, and zsh must
# actually mangle it. Both proven here so a future edit cannot quietly relax
# either half into a check that can never red.
#
# All three rows carry the allow marker because the corpus scan above now reads
# THIS file too, and they have to keep the broken shape or the row proves
# nothing. The marker is load-bearing in both directions: the scan skips them,
# and the dead-marker row re-checks that each one still matches the detector —
# the same assertion this row makes, from the other side.
ZSH_MODIFIER_DETECTOR_GAPS=""
while IFS= read -r zsh_modifier_shape; do
  [ -n "$zsh_modifier_shape" ] || continue
  printf '%s\n' "$zsh_modifier_shape" \
    | grep -qE "$ZSH_MODIFIER_DETECT" \
    || ZSH_MODIFIER_DETECTOR_GAPS="$ZSH_MODIFIER_DETECTOR_GAPS${ZSH_MODIFIER_DETECTOR_GAPS:+
}$zsh_modifier_shape"
done <<'EOF_ZSH_MODIFIER_SHAPES'
git push origin "$publish_sha:refs/heads/$live_branch"  # zsh-modifier-fixture: anti-vacuity row
git push origin "$1:refs/heads/$live_branch"  # zsh-modifier-fixture: anti-vacuity row
printf '%s\n' "$dir:Pxyz"  # zsh-modifier-fixture: anti-vacuity row
EOF_ZSH_MODIFIER_SHAPES
if [ -z "$ZSH_MODIFIER_DETECTOR_GAPS" ]; then
  echo "  PASS  the detector reds on every mangled shape, named and positional"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector does not match shapes it exists to find (vacuous)"
  printf '        %s\n' "$ZSH_MODIFIER_DETECTOR_GAPS"
  FAIL=$((FAIL + 1))
fi

# ...and it must NOT punish anything zsh leaves alone, or the corpus could never
# go green. The braced fix, a `$var:` followed by a letter that is NOT a
# modifier, the PowerShell namespace reference that the pre-#413 letter class
# reddened for no reason, and a colon that is not preceded by an expansion at
# all: every one of these survives zsh byte-for-byte and must survive the guard.
ZSH_MODIFIER_FALSE_POSITIVES=""
while IFS= read -r zsh_modifier_clean; do
  [ -n "$zsh_modifier_clean" ] || continue
  ! printf '%s\n' "$zsh_modifier_clean" | grep -qE "$ZSH_MODIFIER_DETECT" \
    || ZSH_MODIFIER_FALSE_POSITIVES="$ZSH_MODIFIER_FALSE_POSITIVES${ZSH_MODIFIER_FALSE_POSITIVES:+
}$zsh_modifier_clean"
done <<'EOF_ZSH_MODIFIER_CLEAN'
git push origin "${publish_sha}:refs/heads/${live_branch}"
git push origin "${1}:refs/heads/$live_branch"
"-Path $env:UBERDEV_JUNCTION_PATH "
"-Target $env:UBERDEV_JUNCTION_TARGET | Out-Null",
new-item -path $env:X -target $env:Y
printf '%s\n' "${dir}:Pxyz"
case "$line" in *:done) ;; esac
EOF_ZSH_MODIFIER_CLEAN
if [ -z "$ZSH_MODIFIER_FALSE_POSITIVES" ]; then
  echo "  PASS  the detector ignores the braced fix and every colon zsh leaves alone"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector reds on a line zsh does not mangle — the corpus could never go green"
  printf '        %s\n' "$ZSH_MODIFIER_FALSE_POSITIVES"
  FAIL=$((FAIL + 1))
fi
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP  live zsh mangling proof (zsh not on PATH)"
else
  ZSH_UNBRACED="$(zsh -c 'V=abc123; print -r -- "$V:refs/heads/x"' 2>/dev/null)"  # zsh-modifier-fixture: live proof
  ZSH_BRACED="$(zsh -c 'V=abc123; print -r -- "${V}:refs/heads/x"' 2>/dev/null)"
  # The two shapes the shipped detector could not see, proven mangled for real
  # so neither half of the widening can be relaxed back into a vacuous check.
  ZSH_POSITIONAL="$(zsh -c 'f(){ print -r -- "$1:refs/heads/x"; }; f abc123' 2>/dev/null)"  # zsh-modifier-fixture: live proof
  ZSH_REALPATH="$(zsh -c 'V=abc123; print -r -- "$V:Prefs"' 2>/dev/null)"  # zsh-modifier-fixture: live proof
  if [ "$ZSH_UNBRACED" = 'abc123efs/heads/x' ] && [ "$ZSH_BRACED" = 'abc123:refs/heads/x' ] \
     && [ "$ZSH_POSITIONAL" = 'abc123efs/heads/x' ] && [ "$ZSH_REALPATH" != 'abc123:Prefs' ]; then
    echo "  PASS  live zsh: unbraced loses the colon ('$ZSH_UNBRACED'), positional and :P too, braced survives"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh modifier behaviour drifted: unbraced='$ZSH_UNBRACED' braced='$ZSH_BRACED' positional='$ZSH_POSITIONAL' realpath='$ZSH_REALPATH'"
    FAIL=$((FAIL + 1))
  fi

  # THE LETTER CLASS AGAINST REALITY, both directions, one letter at a time.
  # A hand-maintained list of modifier letters is a claim, and the pre-#413 list
  # was wrong in the direction that makes a guard unfixable: five letters that
  # zsh does not apply were in it, so correct lines reddened. The inverse error
  # is the blind spot the `P` widening had to fix by hand. Neither can recur
  # silently while these two rows drive every ASCII letter through the real
  # shell and compare the answer to the class the detector ships.
  #
  # The probe string is BUILT, never written literally, so the scan above finds
  # no unbraced shape here to flag — the `$` arrives through printf.
  ZSH_MODIFIER_ALPHABET='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
  ZSH_MODIFIER_DECORATION=""
  ZSH_MODIFIER_BLIND=""
  zsh_modifier_i=0
  while [ "$zsh_modifier_i" -lt "${#ZSH_MODIFIER_ALPHABET}" ]; do
    zsh_modifier_letter="${ZSH_MODIFIER_ALPHABET:$zsh_modifier_i:1}"
    zsh_modifier_i=$((zsh_modifier_i + 1))
    zsh_modifier_src="$(printf 'V=/tmp/abc.txt; print -r -- "%sV:%srest"' '$' "$zsh_modifier_letter")"
    zsh_modifier_out="$(zsh -c "$zsh_modifier_src" 2>&1)"
    zsh_modifier_rc=$?
    # "zsh mangled it" is colon-based on purpose: `:a`/`:A`/`:P` resolve against
    # the real filesystem, so their OUTPUT differs between macOS and ubuntu while
    # the thing under test — the eaten colon — does not. A non-zero rc counts too
    # (`:s` is a hard `bad substitution`, which kills the fence outright).
    if [ "$zsh_modifier_rc" = 0 ] && [ "$zsh_modifier_out" = "/tmp/abc.txt:${zsh_modifier_letter}rest" ]; then
      zsh_modifier_real=0
    else
      zsh_modifier_real=1
    fi
    case "$ZSH_MODIFIER_LETTERS" in
      *"$zsh_modifier_letter"*) zsh_modifier_listed=1 ;;
      *)                        zsh_modifier_listed=0 ;;
    esac
    if [ "$zsh_modifier_listed" = 1 ] && [ "$zsh_modifier_real" = 0 ]; then
      ZSH_MODIFIER_DECORATION="$ZSH_MODIFIER_DECORATION${ZSH_MODIFIER_DECORATION:+ }$zsh_modifier_letter"
    fi
    if [ "$zsh_modifier_listed" = 0 ] && [ "$zsh_modifier_real" = 1 ]; then
      ZSH_MODIFIER_BLIND="$ZSH_MODIFIER_BLIND${ZSH_MODIFIER_BLIND:+ }$zsh_modifier_letter"
    fi
  done
  if [ -z "$ZSH_MODIFIER_DECORATION" ]; then
    echo "  PASS  live zsh: every letter in the detector's class is a modifier zsh really applies"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  the detector reds on letters zsh leaves alone — drop them: $ZSH_MODIFIER_DECORATION"
    FAIL=$((FAIL + 1))
  fi
  if [ -z "$ZSH_MODIFIER_BLIND" ]; then
    echo "  PASS  live zsh: every modifier zsh really applies is in the detector's class"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh mangles letters the detector cannot see — add them: $ZSH_MODIFIER_BLIND"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== shell-surface predicate: every shell-bearing file shape is in scope =="

# THE SIXTH WIDENING, and the one that shipped downstream. `tools/prkit/` is in
# the corpus, but every file under `tools/prkit/templates/` ends `.tmpl`, so the
# `*.*` arm skipped ALL EIGHT of them — including `ci.yml.tmpl`, the one
# template that emits shell (`run: |` blocks) into the generated prkit repo, and
# `README.md.tmpl` / `CHANGELOG.md.tmpl`, whose basenames end `.tmpl` and so
# never reached the `*.md` arm either. A `trap … RETURN` or a tied `local path`
# authored into the generator's own OUTPUT was invisible to both guards below.
#
# Green on arrival: both consumers (ZSH_TRAP_RETURN_DETECT, ZSH_TIED_DECL) were
# replayed against all eight templates before the widening landed — zero hits.
# It is insurance for the surface that publishes a second repository (#410),
# not a live-bug fix.
#
# The negative half keeps it a PREDICATE and not "everything": data files
# (`.json`) and non-shell code (`.py`) must stay out, or the two detectors below
# would start reading bytes they cannot reason about.
XSHELL_PREDICATE_GAPS=""
for xs_yes in "tools/prkit/templates/ci.yml.tmpl" \
              "tools/prkit/templates/gitignore.tmpl" \
              "tools/prkit/templates/README.md.tmpl" \
              "plugins/uberdev/hooks/session-start" \
              "tests/crossplatform-shell-wrappers.test.sh"; do
  if [ ! -e "$REPO_ROOT/$xs_yes" ]; then
    XSHELL_PREDICATE_GAPS="$XSHELL_PREDICATE_GAPS missing:$xs_yes"
  elif ! _xshell_is_shell_surface "$REPO_ROOT/$xs_yes"; then
    XSHELL_PREDICATE_GAPS="$XSHELL_PREDICATE_GAPS not-scanned:$xs_yes"
  fi
done
for xs_no in "plugins/uberdev/policy/model-routing-v1.json" \
             "plugins/uberdev/lib/model_routing.py"; do
  if [ -e "$REPO_ROOT/$xs_no" ] && _xshell_is_shell_surface "$REPO_ROOT/$xs_no"; then
    XSHELL_PREDICATE_GAPS="$XSHELL_PREDICATE_GAPS wrongly-scanned:$xs_no"
  fi
done
if [ -z "$XSHELL_PREDICATE_GAPS" ]; then
  echo "  PASS  the predicate admits every shell-bearing shape and no data file"
  PASS=$((PASS + 1))
else
  echo "  FAIL  shell-surface predicate scope drift:$XSHELL_PREDICATE_GAPS"
  FAIL=$((FAIL + 1))
fi

echo
echo "== zsh tied parameters: a \`local path\`/\`local … status\` breaks the fence =="

# THE CLASS, and the #370/#371 shape: one contract, enforced in ONE copy.
# lib/status.sh:78-84 documents this rule in full and tests/status.test.sh S1.17
# enforces it — for lib/status.sh alone. Every other library was unguarded, and
# lib/review-fleet-args.sh promptly shipped four `local path="$1"` writers whose
# `jq` calls die `command not found` under zsh. That matters because the
# harness executes command/skill `bash` fences through /bin/zsh on macOS, while
# CI runs `bash tests/...` on ubuntu and windows only — so the whole suite is
# blind to it by construction unless a row drives zsh on purpose.
#
# The tied/special names are zsh's, not a style preference: `path` IS `$PATH`,
# `cdpath` IS `$CDPATH`, and `status`/`argv` are reserved.
#
# THE CORPUS IS THE POINT, and it was wrong on arrival: this guard scanned
# `plugins/uberdev/lib/**/*.sh` only — libraries — while its own header says the
# class matters because "the harness executes command/skill `bash` fences
# through /bin/zsh on macOS". The predicate was disjoint from the drift it must
# find, the #370/#371 shape a third time. `commands/review-pr.md` was carrying
# four live hits at the time (three `local status=`, one `local … path=`) and
# `skills/post-impl-review/SKILL.md` three more; one of them,
# `review_apply_ci_classification_status`, sat on the mandatory Phase 3 routing
# path. `local status=` is the more severe half of the family: `local path=`
# degrades the next command to `command not found`, while `local status=` is a
# HARD script kill (`read-only variable: status`) that takes the whole fence
# with it. The corpus below is now the same one the zsh-modifier guard above
# scans — commands, skills, lib, agents, hooks.
#
# THE SHAPE WAS ALSO WRONG, and it let the more severe half through: the
# terminator was `=`, so the guard only saw a declaration that ASSIGNS at the
# point of declaration. A BARE declaration in a multi-name list —
# `local index status result cleanup_rc=0` — is accepted by zsh and then kills
# the script at the FIRST LATER ASSIGNMENT, which is the shape the dispatch
# helpers actually use:
#   zsh -c 'f(){ local a status; status=hi; echo "$status"; }; f'
#   -> f: read-only variable: status   (rc=1, the whole fence dies)
# Sixteen such bare `status` declarations were live across commands/simplify.md
# and the brainstorm / orchestrator / subagent-driven-dev skills — every one on
# a child dispatch/wait/unwind path — plus a bare `local path` in
# merge-pipeline/lib/release-anchor.sh. The terminator is therefore
# `([=[:space:]]|$)`: assigned, followed by another name, or last on the line.
#
# `[^#]*`, not `.*`, for the pre-name span. Only WHOLE-LINE comments are
# stripped above, so with `.*` a trailing comment would manufacture a false
# positive out of prose — `local dir  # returns status` would match on the bare
# arm. Bounding the span to non-`#` bytes means a tied name is only ever read
# from the code half of the line. The cost is a declaration that reaches a tied
# name only by crossing a literal `#` (inside a quoted default, say) — no such
# line exists in the corpus, and the trailing-comment false positive is the
# larger hazard now that a bare name is enough to red.
#
# THE CORPUS WAS STILL NARROWER THAN THE CLASS, a fourth time: it stopped at
# `plugins/`, so `tests/` and `tools/` were unguarded, and the widened detector
# found twenty more live declarations there — including two `trap`-installed
# cleanup handlers in `tools/prkit/{generate,verify}.sh`, one of which captures
# `local status=$?` as its first act and would take the generation-lock release
# with it. None of them run under zsh TODAY (CI drives only the four
# `*-zsh.test.sh` files that way, and those are clean), so this half is cheap
# insurance rather than a live-bug fix: the shapes break the moment a helper is
# moved into a zsh-driven fence or a `*-zsh.test.sh` file, which is exactly how
# the plugin-side hits got there.
ZSH_TIED_NAMES='path|cdpath|fpath|manpath|mailpath|module_path|psvar|watch|status|argv'
# ONE detector, five consumers: the corpus scan, the two anti-vacuity rows
# (assignment arm, bare arm), the negative row, and the dead-marker row. A
# second copy of this regex is exactly the "one contract, N uncompared copies"
# drift this file's own header is about — every row below must fire on the same
# regex the scan uses, or it is proving something about a detector that is not
# the one shipping.
ZSH_TIED_DECL="^[[:space:]]*(local|typeset|declare)[[:space:]]+([^#]*[^_[:alnum:]])?($ZSH_TIED_NAMES)([=[:space:]]|\$)"
# THE EXCLUSION, and why it is a per-line marker and not a path. Widening the
# corpus sweeps in the rows that MUST keep the broken shape: this file's own
# anti-vacuity fixtures below, and the `fixture_bash_bad` heredoc in
# tests/skill-renderer-awk-collision.test.sh, whose comment says in so many
# words "Do NOT `consistency-fix` this to `topic_status`; that would weaken the
# inverse proof". Excluding those FILES would go blind to real drift in the
# same files — skill-renderer-awk-collision.test.sh is four hundred lines of
# live helper code wrapped around that one fixture, and this file is a thousand.
# So the exclusion is keyed on a marker that must sit in a TRAILING COMMENT on
# the declaration itself, and the two rows after the scan keep it honest: every
# marker must sit on a line the detector really would have caught (no
# decoration), and the marked-line inventory is pinned per file (no silent
# growth). Marker and matcher are separate variables on purpose — the matcher
# needs a literal `#`, so interpolating the marker keeps these two definitions
# from registering as markers themselves.
ZSH_TIED_MARKER='zsh-tied-fixture'
ZSH_TIED_ALLOW="#[^#]*$ZSH_TIED_MARKER"
ZSH_TIED_HITS=""
ZSH_TIED_MARKED=""
while IFS= read -r zsh_tied_file; do
  # THE FILE FILTER WAS ALSO NARROWER THAN THE CLASS, a fifth time, and it hid a
  # PRODUCTION file rather than a test helper — see `_xshell_is_shell_surface`
  # above, which now owns that predicate for this guard and for the
  # `trap … RETURN` guard below it.
  _xshell_is_shell_surface "$zsh_tied_file" || continue
  zsh_tied_rel="${zsh_tied_file#"$REPO_ROOT"/}"
  # Numbered BEFORE either filter, so a reported number is the line's real one.
  # The pre-widening form stripped comments first and reported post-strip
  # offsets; that was survivable across five plugin directories and is not
  # across two hundred test files, where the reader has to find the hit by hand.
  # The comment filter is kept (rather than dropped as redundant) because it is
  # only redundant while the detector stays anchored at the declaration keyword:
  # the surviving call sites NAME the broken shape to explain why `target` is
  # load-bearing, and a guard that punished its own explanation would be
  # unfixable (the S13.11d/S21.9 precedent).
  zsh_tied_hit="$(grep -nE "$ZSH_TIED_DECL" "$zsh_tied_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE "$ZSH_TIED_ALLOW" \
    || true)"
  # EVERY line gets the path, not just the first. `grep -n` emits one line per
  # hit, so prefixing the block once left later hits reading as a bare `255:`
  # with no file — cosmetic in the failure report, fatal for the marked list,
  # which the two rows below actually PARSE back apart on `:`.
  while IFS= read -r zsh_tied_line; do
    [ -n "$zsh_tied_line" ] || continue
    ZSH_TIED_HITS="$ZSH_TIED_HITS${ZSH_TIED_HITS:+
}$zsh_tied_rel:$zsh_tied_line"
  done <<EOF_ZSH_TIED_HIT
$zsh_tied_hit
EOF_ZSH_TIED_HIT
  # Every marked line, for the two allow-list honesty rows below.
  zsh_tied_mark="$(grep -nE "$ZSH_TIED_ALLOW" "$zsh_tied_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    || true)"
  while IFS= read -r zsh_tied_line; do
    [ -n "$zsh_tied_line" ] || continue
    ZSH_TIED_MARKED="$ZSH_TIED_MARKED${ZSH_TIED_MARKED:+
}$zsh_tied_rel:$zsh_tied_line"
  done <<EOF_ZSH_TIED_MARK
$zsh_tied_mark
EOF_ZSH_TIED_MARK
done <<EOF_ZSH_TIED
$(_xshell_corpus)
EOF_ZSH_TIED
if [ -z "$ZSH_TIED_HITS" ]; then
  echo "  PASS  no plugin, test or tool shell surface declares a local named after a zsh tied/special parameter"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a local shadows a zsh tied parameter — rename it (target/file/dir/root)"
  printf '        %s\n' "$ZSH_TIED_HITS"
  FAIL=$((FAIL + 1))
fi

# The allow-list must not be able to hide anything. A marker on a line the
# detector would NOT have caught is either decoration or a fishing attempt to
# neutralise a whole region, and either way it makes the exemption unreviewable.
ZSH_TIED_DEAD_MARKERS=""
while IFS= read -r zsh_tied_entry; do
  [ -n "$zsh_tied_entry" ] || continue
  # `rel:NNN:content` — two shortest-prefix strips leave the content, and the
  # content is what the detector has to agree is a real tied declaration.
  zsh_tied_body="${zsh_tied_entry#*:}"
  zsh_tied_body="${zsh_tied_body#*:}"
  printf '%s\n' "$zsh_tied_body" | grep -qE "$ZSH_TIED_DECL" && continue
  ZSH_TIED_DEAD_MARKERS="$ZSH_TIED_DEAD_MARKERS${ZSH_TIED_DEAD_MARKERS:+
}$zsh_tied_entry"
done <<EOF_ZSH_TIED_DEAD
$ZSH_TIED_MARKED
EOF_ZSH_TIED_DEAD
if [ -z "$ZSH_TIED_DEAD_MARKERS" ]; then
  echo "  PASS  every $ZSH_TIED_MARKER marker sits on a declaration the detector really catches"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a $ZSH_TIED_MARKER marker exempts a line the detector would not have flagged"
  printf '        %s\n' "$ZSH_TIED_DEAD_MARKERS"
  FAIL=$((FAIL + 1))
fi

# ...and it must not grow silently. The inventory is pinned per file, so ADDING
# an exemption is a diff a reviewer has to approve rather than a line that
# quietly stops being scanned. Both directions matter: a count that DROPS means
# a deliberately-broken fixture got "consistency-fixed", which is the failure
# the skill-renderer file warns about in its own comment.
ZSH_TIED_INVENTORY="$(printf '%s\n' "$ZSH_TIED_MARKED" \
  | grep -v '^$' \
  | sed 's/:[0-9][0-9]*:.*$//' \
  | sort | uniq -c \
  | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*\(.*\)$/\2 \1/')"
ZSH_TIED_INVENTORY_EXPECTED='tests/crossplatform-shell-wrappers.test.sh 5
tests/skill-renderer-awk-collision.test.sh 1'
if [ "$ZSH_TIED_INVENTORY" = "$ZSH_TIED_INVENTORY_EXPECTED" ]; then
  echo "  PASS  the tied-parameter allow-list is exactly the pinned fixture inventory"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the tied-parameter allow-list drifted from its pinned inventory"
  printf '        expected: %s\n' "$ZSH_TIED_INVENTORY_EXPECTED"
  printf '        actual:   %s\n' "$ZSH_TIED_INVENTORY"
  FAIL=$((FAIL + 1))
fi

# Anti-vacuity: the detector must fire on the exact shape that shipped.
if printf '%s\n' '  local path="$1" ci_iter="$2" payload' \
   | grep -qE "$ZSH_TIED_DECL"; then
  echo "  PASS  the detector reds on the exact shape that shipped"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector does not match the shape it exists to find (vacuous)"
  FAIL=$((FAIL + 1))
fi

# Anti-vacuity for the BARE arm, which is the half the `=` terminator missed.
# Every one of these is a real declaration that shipped: mid-list, last-on-line,
# and a `typeset` flag form. All die under zsh at the first later assignment.
#
# These five rows carry the allow marker because the corpus scan above now
# reads THIS file too, and they have to keep the broken shape or the row proves
# nothing. The marker is load-bearing in both directions: the scan skips them,
# and the dead-marker row re-checks that each one still matches the detector —
# which is the same assertion this row makes, from the other side. Note the
# marker also makes each row a trailing-comment case, so together with the
# negative row below they pin both halves of the `[^#]*` span rule: a tied name
# BEFORE the `#` still reds, one after it does not.
ZSH_TIED_BARE_GAPS=""
while IFS= read -r zsh_tied_bare; do
  [ -n "$zsh_tied_bare" ] || continue
  printf '%s\n' "$zsh_tied_bare" | grep -qE "$ZSH_TIED_DECL" \
    || ZSH_TIED_BARE_GAPS="$ZSH_TIED_BARE_GAPS${ZSH_TIED_BARE_GAPS:+
}$zsh_tied_bare"
done <<'EOF_ZSH_TIED_BARE'
  local index status result cleanup_rc=0  # zsh-tied-fixture: anti-vacuity row
  local records="$1" descriptors="$2" row edge result status receipt index  # zsh-tied-fixture: anti-vacuity row
  local path removed added chg_added bad  # zsh-tied-fixture: anti-vacuity row
  local index status  # zsh-tied-fixture: anti-vacuity row
  typeset -g status  # zsh-tied-fixture: anti-vacuity row
EOF_ZSH_TIED_BARE
if [ -z "$ZSH_TIED_BARE_GAPS" ]; then
  echo "  PASS  the detector reds on the BARE declaration too, mid-list and last-on-line"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector misses a bare tied declaration (the severe half is vacuous)"
  printf '        %s\n' "$ZSH_TIED_BARE_GAPS"
  FAIL=$((FAIL + 1))
fi

# ...and it must NOT punish the fix, or the corpus can never go green: a widened
# terminator that also fires on `child_status` / `record_path` / a trailing
# comment would make every rename futile and the guard unfixable.
ZSH_TIED_FALSE_POSITIVES=""
while IFS= read -r zsh_tied_clean; do
  [ -n "$zsh_tied_clean" ] || continue
  ! printf '%s\n' "$zsh_tied_clean" | grep -qE "$ZSH_TIED_DECL" \
    || ZSH_TIED_FALSE_POSITIVES="$ZSH_TIED_FALSE_POSITIVES${ZSH_TIED_FALSE_POSITIVES:+
}$zsh_tied_clean"
done <<'EOF_ZSH_TIED_CLEAN'
  local index child_status result cleanup_rc=0
  local edge="$1" record_path="$2" ledger_path="$3"
  local changed_path removed added chg_added bad
  local status_file="$1" mystatus="$2" pathological=1
  local dir  # the caller reads status from here
EOF_ZSH_TIED_CLEAN
if [ -z "$ZSH_TIED_FALSE_POSITIVES" ]; then
  echo "  PASS  the detector ignores the renamed forms and a trailing-comment mention"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector reds on a CORRECT declaration — the corpus could never go green"
  printf '        %s\n' "$ZSH_TIED_FALSE_POSITIVES"
  FAIL=$((FAIL + 1))
fi

# ...and the MECHANISM, live, plus the shipped writers driven under zsh. A
# structural grep alone would go green the day someone reintroduces the shape
# with a name the regex missed.
if ! command -v zsh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  live zsh tied-parameter proof (zsh or jq not on PATH)"
else
  ZSH_TIED_PROBE="$(zsh -c 'f() { local path=/tmp/x.json; command -v jq >/dev/null 2>&1 && print -r -- found || print -r -- lost; }; f' 2>/dev/null)"
  if [ "$ZSH_TIED_PROBE" = lost ]; then
    echo "  PASS  live zsh: a \`local path=\` really does lose every external command"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh tied-parameter behaviour drifted: probe said '$ZSH_TIED_PROBE'"
    FAIL=$((FAIL + 1))
  fi
  # The BARE arm's mechanism, live: the DECLARATION is accepted, so nothing looks
  # wrong at that line — the function dies at the first later assignment, and the
  # rc is the function's, not a warning. This is why the `=`-only terminator read
  # as "no hits" while sixteen live declarations were one assignment from death.
  ZSH_BARE_OUT="$(zsh -c 'f() { local a status; status=hi; print -r -- "$status"; }; f' 2>/dev/null)"
  ZSH_BARE_RC=$?
  ZSH_BARE_FIXED="$(zsh -c 'f() { local a child_status; child_status=hi; print -r -- "$child_status"; }; f' 2>/dev/null)"
  ZSH_BARE_FIXED_RC=$?
  if [ "$ZSH_BARE_RC" -ne 0 ] && [ -z "$ZSH_BARE_OUT" ] \
     && [ "$ZSH_BARE_FIXED_RC" -eq 0 ] && [ "$ZSH_BARE_FIXED" = hi ]; then
    echo "  PASS  live zsh: a bare \`local … status\` dies on its first assignment, the rename does not"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh bare tied-declaration behaviour drifted: rc=$ZSH_BARE_RC out='$ZSH_BARE_OUT' fixed_rc=$ZSH_BARE_FIXED_RC fixed='$ZSH_BARE_FIXED'"
    FAIL=$((FAIL + 1))
  fi
  # The three review-fleet writers that ship on the Phase 3 push path. Driven
  # under ZSH, not bash: every existing row for them uses an explicit `bash -c`,
  # which is precisely why the class was invisible. review_fleet_write_ci_push
  # is the sharpest — it runs IMMEDIATELY AFTER a successful force-push, so an
  # rc=2 there lands the remote mutation and then aborts before the audit event.
  ZSH_ARGS_LIB="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
  ZSH_ARGS_TMP="$(mktemp -d)"
  ZSH_SHA40="$(printf 'a%.0s' $(seq 40))"
  ZSH_WRITER_RESULT="$(zsh -c '
    set -u
    . "$1" || exit 90
    review_fleet_write_ci_state "$2/state.json" 2 1 "[]" "[]" || exit 91
    review_fleet_write_ci_push "$2/push.json" "$3" ci-rebase-handler || exit 92
    review_fleet_write_sidecar "$2/sidecar.json" bind "$2" inst || exit 93
    review_fleet_write_conflict_paths "$2/paths.zlist" "src/a b.py" || exit 94
    review_fleet_write_ci_pointer "$2/ptr.txt" "$2/sidecar.json" || exit 95
    [ -s "$2/state.json" ] && [ -s "$2/push.json" ] && [ -s "$2/sidecar.json" ] \
      && [ -s "$2/paths.zlist" ] && [ -s "$2/ptr.txt" ] || exit 96
    # review_fleet_ci_green_outcome (#400) reads the ledger under its CANONICAL
    # name, so write that too and drive the reader in the same zsh frame. Its
    # `local target` is the tied-parameter rule again: spelled `path` it would
    # blow away $PATH for the whole frame and the jq below would be
    # command-not-found — the failure would land on a green CI run, upgrading
    # nothing and reporting no error.
    review_fleet_write_ci_state "$2/ci-loop-state.json" 2 1 \
      "[{\"sha\":\"$3\",\"by_agent\":\"ci-code-fixer\"}]" "[\"code_bug\"]" || exit 97
    ZSH_GREEN_OUTCOME="$(review_fleet_ci_green_outcome "$2" 1)" || exit 98
    [ "$ZSH_GREEN_OUTCOME" = green_after_fix ] || exit 99
    # The three #418 carriers, written AND read in the same zsh frame. They are
    # the newest members of this family and they run on the same Phase 3 path:
    # the probe verdict decides `--no-ci-fix` OUTCOME, the classification decides
    # which fixer (if any) mutates code, and the check name is filed into a
    # CRITICAL issue. `local check_name` / `local verdict` are safe names, but a
    # future edit reaching for `local path` or `local status` here would die
    # exactly like the writers above -- which is why they are driven under zsh
    # rather than trusted to the bash rows in review-pr-phase3-ci.test.sh.
    review_fleet_write_ci_probe_verdict "$2/ci-probe-verdict.txt" green || exit 100
    review_fleet_write_ci_check_name "$2/ci-check-name.txt" "shape-checks (pull_request)" || exit 101
    review_fleet_write_ci_classification "$2/ci-classification.json" code_bug "tests/foo.test.sh:12" || exit 102
    [ "$(review_fleet_read_ci_probe_verdict "$2/ci-probe-verdict.txt")" = green ] || exit 103
    [ "$(review_fleet_read_ci_check_name "$2/ci-check-name.txt")" = "shape-checks (pull_request)" ] || exit 104
    [ "$(review_fleet_read_ci_classification "$2/ci-classification.json" failure_class)" = code_bug ] || exit 105
    [ "$(review_fleet_read_ci_classification "$2/ci-classification.json" signal_anchor)" = "tests/foo.test.sh:12" ] || exit 106
    print -r -- "$(review_fleet_read_ci_pointer "$2/ptr.txt")"
  ' _ "$ZSH_ARGS_LIB" "$ZSH_ARGS_TMP" "$ZSH_SHA40" 2>&1)"
  ZSH_WRITER_RC=$?
  if [ "$ZSH_WRITER_RC" = 0 ] && [ "$ZSH_WRITER_RESULT" = "$ZSH_ARGS_TMP/sidecar.json" ]; then
    echo "  PASS  every review-fleet cross-fence primitive runs under zsh and lands its file"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  a review-fleet primitive failed under zsh (rc=$ZSH_WRITER_RC): $ZSH_WRITER_RESULT"
    FAIL=$((FAIL + 1))
  fi

  # Z2 — NEGATIVE CONTROL, the #398 bashism's mechanism, live and first.
  # `mapfile` is a bash builtin with no zsh equivalent, and the Step-4 conflict
  # re-bind in commands/review-pr.md used it inside a markdown `bash` fence —
  # which the harness executes under /bin/zsh. Nothing consumed its rc, so the
  # array it was supposed to fill stayed EMPTY and the very next statement
  # (`[ "${#conflicted_files[@]}" -gt 0 ]`) read a missing builtin as "no
  # conflicts to resolve". Fed from a HERESTRING, never a pipe:
  # tests/epipe-guard.test.sh refuses a pipe into an early-exiting reader.
  # `slurp_rc=$?` on its own line, not `"rc=$?:count=…"` inline: zsh reads the
  # `:c` in `$?:count` as a history-style `:c` modifier and swallows it, so the
  # inline spelling renders `rc=127ount=0`.
  ZSH_SLURP="$(zsh -f -c '
    mapfile -t zsh_slurp_probe <<< "one" 2>/dev/null
    slurp_rc=$?
    print -r -- "rc=${slurp_rc}:count=${#zsh_slurp_probe[@]}"' 2>/dev/null)"
  if [ "$ZSH_SLURP" = "rc=127:count=0" ]; then
    echo "  PASS  live zsh: bash's array-slurp builtin is absent and leaves an EMPTY array behind"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh array-slurp behaviour drifted: probe said '$ZSH_SLURP' (want rc=127:count=0)"
    FAIL=$((FAIL + 1))
  fi

  # Z1 — and the replacement really works in that same shell. The enumerator is
  # driven under `zsh -c` against a real add/add rebase conflict (the shape the
  # retired `^UU` filter could not see), and its payload must be byte-identical
  # to what bash produces for the same repository. SKIPs rather than FAILs
  # without git/python3: this suite also runs on the windows job.
  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  live zsh conflict-enumerator proof (git or python3 not on PATH)"
  else
    ZSH_AA_REPO="$ZSH_ARGS_TMP/aa/repo"
    mkdir -p "$ZSH_ARGS_TMP/aa"
    (
      set -e
      cd "$ZSH_ARGS_TMP/aa"
      git init -q -b main repo
      cd repo
      git config user.email fixture@example.invalid
      git config user.name Fixture
      mkdir src
      printf 'KEEP = 1\n' >src/keep.py
      git add -- src/keep.py
      git commit -qm 'test: base'
      printf "COLLIDE = 'main'\n" >src/collide.py
      git add -- src/collide.py
      git commit -qm 'test: main adds the colliding path'
      git checkout -qb fix/398-collide HEAD~1
      printf "COLLIDE = 'branch'\n" >src/collide.py
      git add -- src/collide.py
      git commit -qm 'test: the branch adds it too'
      git rebase main
    ) >/dev/null 2>&1 || true    # the fixture rebase MUST conflict
    ZSH_AA_PORCELAIN="$(git -C "$ZSH_AA_REPO" status --porcelain 2>/dev/null)"
    case "$ZSH_AA_PORCELAIN" in
      *'AA '*) ZSH_AA_GATE=ok ;;
      *) ZSH_AA_GATE=no-aa ;;
    esac
    case "$ZSH_AA_PORCELAIN" in
      *'UU '*) ZSH_AA_GATE=stray-uu ;;
    esac
    if [ "$ZSH_AA_GATE" != ok ]; then
      echo "  FAIL  the add/add fixture did not conflict as AA ($ZSH_AA_GATE); the row below would be vacuous"
      FAIL=$((FAIL + 1))
    else
      ZSH_CONTRACT="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"
      ZSH_ENUM_RC=0
      zsh -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
        _ "$ZSH_ARGS_LIB" "$ZSH_AA_REPO" "$ZSH_CONTRACT" "$ZSH_ARGS_TMP/zsh.zlist" \
        >/dev/null 2>&1 || ZSH_ENUM_RC=$?
      ZSH_ENUM_BASH_RC=0
      bash -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
        _ "$ZSH_ARGS_LIB" "$ZSH_AA_REPO" "$ZSH_CONTRACT" "$ZSH_ARGS_TMP/bash.zlist" \
        >/dev/null 2>&1 || ZSH_ENUM_BASH_RC=$?
      if [ "$ZSH_ENUM_RC" = 0 ] && [ "$ZSH_ENUM_BASH_RC" = 0 ] \
         && [ -s "$ZSH_ARGS_TMP/zsh.zlist" ] \
         && cmp -s "$ZSH_ARGS_TMP/zsh.zlist" "$ZSH_ARGS_TMP/bash.zlist"; then
        echo "  PASS  live zsh: review_fleet_unmerged_paths enumerates the AA conflict identically to bash"
        PASS=$((PASS + 1))
      else
        echo "  FAIL  conflict enumerator under zsh rc=$ZSH_ENUM_RC (bash rc=$ZSH_ENUM_BASH_RC) — payloads differ or empty"
        FAIL=$((FAIL + 1))
      fi
    fi
  fi
  rm -rf "$ZSH_ARGS_TMP"
fi

echo
echo "== zsh trap RETURN: a function-scoped cleanup trap never installs (#401) =="

# THE CLASS, same family as the tied parameters above and the same reason it was
# invisible: `RETURN` is not a signal zsh accepts. `trap "rm -f \"$f\"" RETURN`
# is a hard `undefined signal: RETURN` error under zsh, so the trap NEVER
# INSTALLS — and under bash it is a perfectly ordinary, correct idiom. A file
# whose cleanup depends on it is clean in every bash-run test and leaks on every
# call in the shell the harness actually executes command/skill `bash` fences in.
#
# It shipped for real. lib/rate-limit-curl.sh documents the hazard three separate
# times and releases its mutex explicitly at every return — while
# merge-pipeline/lib/discover.sh, in the same plugin, guarded all three of its
# public functions with the dead trap. Every `/merge` run printed three
# `undefined signal: RETURN` lines and leaked three temp files, and under
# errexit the trap line aborted discovery outright. Four files carried the rule
# in PROSE and none of them could enforce it; that is what this block is.
#
# `docs/` stays out of the corpus on purpose: this is a code-surface class, and
# an RFC may legitimately name the construct while explaining it.
#
# ONE detector, five consumers — the corpus scan, the dead-marker row, the
# anti-vacuity row, the anti-false-positive row, and the live proof — so no row
# can end up proving something about a detector that is not the one shipping.
#
# STATEMENT-ANCHORED (`^[[:space:]]*trap[[:space:]]`) is what makes it land
# green on a repo that talks about the construct constantly: it skips the
# `assert_grep "$LIB" 'trap…RETURN'` shape, the `echo "… (trap RETURN
# regression)"` message in testers-rate-limit-wrapper.test.sh, and every prose
# mention that is not a trap STATEMENT.
#
# `[^#]*`, not `.*`, for the span before RETURN — only WHOLE-LINE comments are
# stripped below, so an unbounded span would manufacture a false positive out of
# a trailing comment (`trap "rm -f \"$t\"" EXIT  # not RETURN` must stay clean).
# Same reasoning, same shape, as ZSH_TIED_DECL above.
ZSH_TRAP_RETURN_DETECT='^[[:space:]]*trap[[:space:]][^#]*[[:space:]]RETURN([[:space:]]|;|\)|$)'
# Marker and matcher are separate variables for the same reason as the tied
# guard's: the matcher needs a literal `#`, so interpolating the marker keeps
# these two definitions from registering as markers themselves.
ZSH_TRAP_RETURN_MARKER='zsh-trap-return-fixture'
ZSH_TRAP_RETURN_ALLOW="#[^#]*$ZSH_TRAP_RETURN_MARKER"
ZSH_TRAP_RETURN_HITS=""
ZSH_TRAP_RETURN_MARKED=""
while IFS= read -r ztr_file; do
  _xshell_is_shell_surface "$ztr_file" || continue
  ztr_rel="${ztr_file#"$REPO_ROOT"/}"
  ztr_hit="$(grep -nE "$ZSH_TRAP_RETURN_DETECT" "$ztr_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE "$ZSH_TRAP_RETURN_ALLOW" \
    || true)"
  # EVERY line carries the path, not just the first — the two rows below parse
  # these entries back apart on `:`.
  while IFS= read -r ztr_line; do
    [ -n "$ztr_line" ] || continue
    ZSH_TRAP_RETURN_HITS="$ZSH_TRAP_RETURN_HITS${ZSH_TRAP_RETURN_HITS:+
}$ztr_rel:$ztr_line"
  done <<EOF_ZTR_HIT
$ztr_hit
EOF_ZTR_HIT
  ztr_mark="$(grep -nE "$ZSH_TRAP_RETURN_ALLOW" "$ztr_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    || true)"
  while IFS= read -r ztr_line; do
    [ -n "$ztr_line" ] || continue
    ZSH_TRAP_RETURN_MARKED="$ZSH_TRAP_RETURN_MARKED${ZSH_TRAP_RETURN_MARKED:+
}$ztr_rel:$ztr_line"
  done <<EOF_ZTR_MARK
$ztr_mark
EOF_ZTR_MARK
done <<EOF_ZTR
$(_xshell_corpus)
EOF_ZTR
if [ -z "$ZSH_TRAP_RETURN_HITS" ]; then
  echo "  PASS  no plugin, test or tool shell surface installs a \`trap … RETURN\`"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a \`trap … RETURN\` never installs under zsh — release explicitly on every return path"
  printf '        %s\n' "$ZSH_TRAP_RETURN_HITS"
  FAIL=$((FAIL + 1))
fi

# The allow-list must not be able to hide anything: a marker on a line the
# detector would NOT have caught is decoration or a fishing attempt, and either
# way it makes the exemption unreviewable.
ZSH_TRAP_RETURN_DEAD_MARKERS=""
while IFS= read -r ztr_entry; do
  [ -n "$ztr_entry" ] || continue
  ztr_body="${ztr_entry#*:}"
  ztr_body="${ztr_body#*:}"
  printf '%s\n' "$ztr_body" | grep -qE "$ZSH_TRAP_RETURN_DETECT" && continue
  ZSH_TRAP_RETURN_DEAD_MARKERS="$ZSH_TRAP_RETURN_DEAD_MARKERS${ZSH_TRAP_RETURN_DEAD_MARKERS:+
}$ztr_entry"
done <<EOF_ZTR_DEAD
$ZSH_TRAP_RETURN_MARKED
EOF_ZTR_DEAD
if [ -z "$ZSH_TRAP_RETURN_DEAD_MARKERS" ]; then
  echo "  PASS  every $ZSH_TRAP_RETURN_MARKER marker sits on a trap statement the detector really catches"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a $ZSH_TRAP_RETURN_MARKER marker exempts a line the detector would not have flagged"
  printf '        %s\n' "$ZSH_TRAP_RETURN_DEAD_MARKERS"
  FAIL=$((FAIL + 1))
fi

# ...and it must not grow silently. Both directions red: growth means a new
# exemption slipped in unreviewed, shrinkage means a deliberately-broken fixture
# got "consistency-fixed" and the anti-vacuity row stopped proving anything.
ZSH_TRAP_RETURN_INVENTORY="$(printf '%s\n' "$ZSH_TRAP_RETURN_MARKED" \
  | grep -v '^$' \
  | sed 's/:[0-9][0-9]*:.*$//' \
  | sort | uniq -c \
  | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*\(.*\)$/\2 \1/')"
ZSH_TRAP_RETURN_INVENTORY_EXPECTED='tests/crossplatform-shell-wrappers.test.sh 2'
if [ "$ZSH_TRAP_RETURN_INVENTORY" = "$ZSH_TRAP_RETURN_INVENTORY_EXPECTED" ]; then
  echo "  PASS  the trap-RETURN allow-list is exactly the pinned fixture inventory"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the trap-RETURN allow-list drifted from its pinned inventory"
  printf '        expected: %s\n' "$ZSH_TRAP_RETURN_INVENTORY_EXPECTED"
  printf '        actual:   %s\n' "$ZSH_TRAP_RETURN_INVENTORY"
  FAIL=$((FAIL + 1))
fi

# Anti-vacuity. The first line is the exact byte sequence that shipped in
# lib/discover.sh; the second is the unquoted form, because a detector that only
# knew the quoted one would miss the next author. Both carry the marker — the
# corpus scan above reads THIS file — which is what pins the inventory at 2, and
# the dead-marker row re-checks each of them from the other side.
ZSH_TRAP_RETURN_GAPS=""
while IFS= read -r ztr_bad; do
  [ -n "$ztr_bad" ] || continue
  printf '%s\n' "$ztr_bad" | grep -qE "$ZSH_TRAP_RETURN_DETECT" \
    || ZSH_TRAP_RETURN_GAPS="$ZSH_TRAP_RETURN_GAPS${ZSH_TRAP_RETURN_GAPS:+
}$ztr_bad"
done <<'EOF_ZTR_BAD'
  trap "rm -f \"$gh_err\"" RETURN  # zsh-trap-return-fixture: anti-vacuity row
  trap cleanup RETURN  # zsh-trap-return-fixture: anti-vacuity row
EOF_ZTR_BAD
if [ -z "$ZSH_TRAP_RETURN_GAPS" ]; then
  echo "  PASS  the detector reds on the exact shape that shipped, quoted and unquoted"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector does not match the shape it exists to find (vacuous)"
  printf '        %s\n' "$ZSH_TRAP_RETURN_GAPS"
  FAIL=$((FAIL + 1))
fi

# ...and it must NOT punish anything legitimate, or the corpus could never go
# green. Traps of real signals, trap RESET, multi-signal traps, a trailing
# comment that merely says RETURN, and the two shapes this repo uses to TALK
# about the bug — a grep assertion and an error message — all stay clean.
ZSH_TRAP_RETURN_FALSE_POSITIVES=""
while IFS= read -r ztr_clean; do
  [ -n "$ztr_clean" ] || continue
  ! printf '%s\n' "$ztr_clean" | grep -qE "$ZSH_TRAP_RETURN_DETECT" \
    || ZSH_TRAP_RETURN_FALSE_POSITIVES="$ZSH_TRAP_RETURN_FALSE_POSITIVES${ZSH_TRAP_RETURN_FALSE_POSITIVES:+
}$ztr_clean"
done <<'EOF_ZTR_CLEAN'
trap '_goal_phase3_on_exit "$?"' EXIT
  trap - EXIT
  trap 'x' INT TERM
  trap 'rm -f "$x"' EXIT INT TERM
  trap "rm -f \"$t\"" EXIT  # not RETURN
  [ ! -d "$D/.lock" ] || { echo "mutex leaked under zsh (trap RETURN regression)"; exit 1; }
assert_grep "$LIB" 'trap[[:space:]]+.*RETURN' \
EOF_ZTR_CLEAN
if [ -z "$ZSH_TRAP_RETURN_FALSE_POSITIVES" ]; then
  echo "  PASS  the detector ignores real-signal traps and every prose mention of the bug"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the detector reds on a legitimate line — the corpus could never go green"
  printf '        %s\n' "$ZSH_TRAP_RETURN_FALSE_POSITIVES"
  FAIL=$((FAIL + 1))
fi

# ...and the MECHANISM, live, in BOTH shells. The bash twin is not decoration:
# it is the demonstration of why every bash-run test in this repo was blind to
# the class. Written as single-line `zsh -c`/`bash -c` probes so the embedded
# `trap` is never line-initial and therefore never trips the scan above.
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP  live trap-RETURN mechanism proof (zsh not on PATH — the Windows shape-check job)"
else
  ZTR_TMP="$(mktemp -d)"
  ZTR_ZSH_DEAD="$(ZTR_TMP="$ZTR_TMP" zsh -c 'f() { : > "$ZTR_TMP/z"; trap "rm -f \"$ZTR_TMP/z\"" RETURN; }; f; [ -e "$ZTR_TMP/z" ] && print -r -- LEAKED || print -r -- CLEAN' 2>&1)"
  ZTR_ZSH_FIXED="$(ZTR_TMP="$ZTR_TMP" zsh -c 'f() { : > "$ZTR_TMP/zf"; rm -f "$ZTR_TMP/zf"; }; f; [ -e "$ZTR_TMP/zf" ] && print -r -- LEAKED || print -r -- CLEAN' 2>&1)"
  ZTR_BASH_DEAD="$(ZTR_TMP="$ZTR_TMP" bash -c 'f() { : > "$ZTR_TMP/b"; trap "rm -f \"$ZTR_TMP/b\"" RETURN; }; f; [ -e "$ZTR_TMP/b" ] && echo LEAKED || echo CLEAN' 2>&1)"
  rm -rf "$ZTR_TMP"
  case "$ZTR_ZSH_DEAD" in
    *"undefined signal"*LEAKED*) ztr_zsh_dead_ok=1 ;;
    *) ztr_zsh_dead_ok=0 ;;
  esac
  if [ "$ztr_zsh_dead_ok" = 1 ] && [ "$ZTR_ZSH_FIXED" = CLEAN ] && [ "$ZTR_BASH_DEAD" = CLEAN ]; then
    echo "  PASS  live: zsh rejects RETURN and leaks the file, the explicit release does not — and bash cleans up either way"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  trap-RETURN behaviour drifted: zsh-dead='$ZTR_ZSH_DEAD' zsh-fixed='$ZTR_ZSH_FIXED' bash-dead='$ZTR_BASH_DEAD'"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== which green: review_fleet_ci_green_outcome, driven portably (#400) =="
# The zsh row above proves the tied-parameter rule; THIS one is the portable
# behavioural signal. Both review-pr-phase3-ci.test.sh and
# review-pr-workflow.test.sh are on the windows-latest skip list, so without
# these two rows the whole `green` vs `green_after_fix` derivation would ship
# with zero coverage on the Git Bash job — and the zsh block above skips there
# too, because windows-latest carries no zsh.
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  review_fleet_ci_green_outcome rows (jq not on PATH)"
else
  GREEN_LIB="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
  GREEN_TMP="$(mktemp -d)"
  GREEN_SHA40="$(printf 'b%.0s' $(seq 40))"
  mkdir -p "$GREEN_TMP/clean" "$GREEN_TMP/fixed"

  bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 1 1 "[]" "[]"' \
    _ "$GREEN_LIB" "$GREEN_TMP/clean" >/dev/null 2>&1
  GREEN_CLEAN="$(bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
    _ "$GREEN_LIB" "$GREEN_TMP/clean" 2>/dev/null)"
  assert_eq "$GREEN_CLEAN" green \
    "a ledger with no recorded fix push resolves to green"

  bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 2 2 \
    "[{\"sha\":\"$3\",\"by_agent\":\"ci-code-fixer\"}]" "[\"code_bug\"]"' \
    _ "$GREEN_LIB" "$GREEN_TMP/fixed" "$GREEN_SHA40" >/dev/null 2>&1
  GREEN_FIXED="$(bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
    _ "$GREEN_LIB" "$GREEN_TMP/fixed" 2>/dev/null)"
  assert_eq "$GREEN_FIXED" green_after_fix \
    "a ledger with a recorded fix push resolves to green_after_fix"

  rm -rf "$GREEN_TMP"
fi

echo
echo "== run manifest: Windows reconciliation uses a non-signaling native probe =="

if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" \
    "$REPO_ROOT/plugins/uberdev/lib/live-semaphore.sh" \
    "$REPO_ROOT/plugins/uberdev/lib/agent-dispatch.sh" <<'PY'
import contextlib,hashlib,importlib.util,pathlib,shutil,sys,tempfile
from unittest import mock
@contextlib.contextmanager
def scratch_dir(prefix,parent=None):
 """Scratch tree whose TEARDOWN cannot decide this suite's verdict (#428).

 TemporaryDirectory.__exit__ re-raises every OSError but PermissionError and
 FileNotFoundError, so an unlink race reds a job whose diff never touched this
 file. Full rationale, tradeoff and the "no setup-python => no 3.10+
 ignore_cleanup_errors=" constraint: tests/code-fixer-contract.test.sh.
 """
 path=tempfile.mkdtemp(prefix=prefix,dir=parent)
 try:
  yield path
 finally:
  shutil.rmtree(path,ignore_errors=True)
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
 with scratch_dir("crossplatform-parent-identity-") as temporary:
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

if python3 -I -B - "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" <<'PY'
import contextlib,importlib.util,pathlib,shutil,sys,tempfile
from unittest import mock

@contextlib.contextmanager
def scratch_dir(prefix,parent=None):
 """Scratch tree whose TEARDOWN cannot decide this suite's verdict (#428).

 Full rationale, tradeoff and the "no setup-python => no 3.10+
 ignore_cleanup_errors=" constraint: tests/code-fixer-contract.test.sh.
 """
 path=tempfile.mkdtemp(prefix=prefix,dir=parent)
 try:
  yield path
 finally:
  shutil.rmtree(path,ignore_errors=True)

for index,module_path in enumerate(sys.argv[1:]):
 spec=importlib.util.spec_from_file_location(f'run_manifest_windows_filesystem_{index}',module_path)
 module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
 assert spec.loader is not None; spec.loader.exec_module(module)
 with scratch_dir("crossplatform-windows-fs-") as temporary:
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
import contextlib,importlib.util,ntpath,os,pathlib,shutil,stat,sys,tempfile,types
from unittest import mock
@contextlib.contextmanager
def scratch_dir(prefix,parent=None):
 """Scratch tree whose TEARDOWN cannot decide this suite's verdict (#428).

 Full rationale, tradeoff and the "no setup-python => no 3.10+
 ignore_cleanup_errors=" constraint: tests/code-fixer-contract.test.sh.
 """
 path=tempfile.mkdtemp(prefix=prefix,dir=parent)
 try:
  yield path
 finally:
  shutil.rmtree(path,ignore_errors=True)
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
with scratch_dir("crossplatform-lease-contract-") as temporary:
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
# #469: the subshell runs OUTSIDE the `if` condition and its captured status is
# tested, so the `set -e` it re-arms on line "set -e" below is live. A subshell
# used AS an if-condition has errexit suppressed for its whole body (POSIX: the
# -e setting is ignored for a command whose status is being tested), and bash
# keeps that suppression even across an explicit `set -e` inside the subshell —
# so every assertion above the last would be a no-op.
(
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
  [ "$closed_rc" -eq 1 ] || exit 61
  [ "$closed_output" = '{"error":"process_identity_parent_absent","status":"error"}' ] || exit 62
  [ "$extra_rc" -eq 1 ] || exit 63
  [ "$extra_output" = '{"error":"owner_process_identity_writer_failed","status":"error"}' ] || exit 64
  [ "$crlf_rc" -eq 2 ] || exit 65
  [ "$crlf_output" = '{"error":"owner_process_record_malformed","status":"error"}' ] || exit 66
  [ -z "$remaining_probe" ] || exit 67
)
OWNER_BRIDGE_CONTRACT_RC=$?
if [ "$OWNER_BRIDGE_CONTRACT_RC" -eq 0 ]; then
  echo "  PASS  owner bridge preserves safe writer failures and rejects CRLF or untrusted records"
  PASS=$((PASS + 1))
else
  echo "  FAIL  owner bridge leaked, rewrote status, or retained an unsafe probe (rc=$OWNER_BRIDGE_CONTRACT_RC; 61/63/65=closed|extra|crlf status, 62/64/66=closed|extra|crlf rendered record, 67=an unsafe probe file survived)"
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
    # #396-class: this wait is a HANG DETECTOR, not a budget, and an expired
    # wait must name ITSELF.
    #
    # The bound was ten 0.1s ticks — a hard 1.0s for a backgrounded CPython to
    # cold-start, CreateProcess/fork a SECOND CPython, and land the child pid on
    # disk. That is a fixed iteration count, not a condition: on expiry the loop
    # fell THROUGH instead of failing, `cat` yielded an empty pid, and the next
    # command died under `set -e`. The operator-visible verdict became "did not
    # preserve one live native identity" with stage=runtime-assertion and
    # raw=<unavailable> — accusing identity binding while the diagnostic printed
    # four IDENTICAL, correct identities (owner/lease/event/intent). The verdict
    # moved with machine speed, and the surviving evidence blamed a knob that was
    # provably working. Worse, this block is native-Windows-only, so the bound was
    # sized against a fork-based host (~135ms observed) but only ever ran where
    # each interpreter start is 150-400ms and process creation is CreateProcess.
    #
    # Three changes, none of which weakens the row:
    #   1. the deadline is 10s, matching the `child.wait(timeout=10)` the payload
    #      itself already trusts — generous enough that only a real hang reaches it;
    #   2. the poll condition is the state the rest of the block actually
    #      consumes — a positive-integer pid — instead of `-s`, which only proves
    #      the file is non-empty. It is strictly stronger: everything it admits,
    #      `-s` admitted too, while `0`, `0123`, ` 4321`, `43x` and a file holding
    #      just a newline (non-empty to `-s`, EMPTY after `$(cat)` strips it — the
    #      very fall-through that produced the empty pid) now keep it waiting;
    #   3. expiry routes into the existing windows_stage diagnostic, so a starved
    #      runner reds as `child_pid_file_never_written` under its own stage name
    #      instead of being laundered into another row's failure text.
    windows_child_pid=''
    windows_child_waits=0
    while [ "$windows_child_waits" -lt 100 ]; do
      windows_child_candidate="$(cat "$windows_child_pid_file" 2>/dev/null || true)"
      case "$windows_child_candidate" in
        ''|0|0*|*[!0-9]*) windows_child_candidate='' ;;
      esac
      if [ -n "$windows_child_candidate" ]; then
        windows_child_pid="$windows_child_candidate"
        break
      fi
      sleep 0.1
      windows_child_waits=$((windows_child_waits + 1))
    done
    if [ -z "$windows_child_pid" ]; then
      windows_stage=child-pid-timeout
      windows_stage_rc=1
      windows_stage_raw='{"error":"child_pid_file_never_written"}'
      false
    fi
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
    # #381: the `_uberdev_dispatch_codex_available() { return 0; }` stub that
    # sat here is gone with the function. It was inert, and it implied `codex`
    # was rejected below only because native Windows cannot supervise it —
    # `codex` is now rejected everywhere, by the enum, available binary or not.
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
echo "== hooks.json SessionStart: EXECUTE the declared command, assert the emitted contract (#461) =="
# WHY THIS SECTION EXISTS, and why it sits at the END of the file.
#
# Nothing in this repo ever RAN a hook declaration. tests/docs-accuracy.test.sh
# T8.1/T8.9 count strings inside hooks.json; the rows at the top of this file
# grep run-hook.cmd's bytes. Both are structurally blind to the failure #461 is
# about, which is silent by construction: the runtime picks an interpreter, the
# interpreter cannot parse the command, and the session starts with no context
# and no error. Upstream superpowers hit exactly that on Windows — PowerShell
# read the quoted hook path as an expression, cmd.exe truncated on a
# metacharacter, and the bootstrap simply never loaded. The only evidence that
# settles it is executing the literal the runtime executes and asserting the
# JSON contract the hook is supposed to emit.
#
# PLACEMENT. The `native Windows assertion block reports its own failing status`
# row above parses THIS FILE'S SOURCE, slicing it between the first occurrence of
# the `os.name=="nt"` gate literal and the `run_manifest.py` heredoc marker. A
# second gate placed earlier in the file would silently redefine that slice and
# make its assertions describe the wrong block. Everything below therefore lives
# downstream of both split points.
XH_HOOKS_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks.json"
XH_PLUGIN_DIR="$REPO_ROOT/plugins/uberdev"
XH_HOOKS_DIR="$XH_PLUGIN_DIR/hooks"

# ONE contract, ONE copy: the command string is READ OUT of the manifest, never
# retyped here. A retyped literal is the "one contract, N uncompared copies"
# drift (#370/#371) this file's own header is about — the test would keep
# passing over a string the runtime no longer runs. Read from STDIN, never as a
# path argument: windows-latest runs NATIVE Windows Python, which cannot resolve
# the MSYS `/…` paths Git Bash hands it.
# stderr is deliberately NOT silenced: if the manifest stops parsing, the
# traceback is the diagnosis and it belongs in the CI log next to the red row.
XH_CMD="$(python3 -I -B -c 'import json,sys; print(json.load(sys.stdin)["hooks"]["SessionStart"][0]["hooks"][0]["command"], end="")' < "$XH_HOOKS_JSON")"
# An empty extraction would make every row below vacuously green, so it fails
# loudly on its own rather than being inferred from a later PASS.
assert_nonempty "$XH_CMD" \
  "XH1a SessionStart command literal extracted from hooks.json (empty => every row below is vacuous)"
if grep -q 'run-hook\.cmd' <<<"$XH_CMD"; then
  echo "  PASS  XH1b the extracted literal is the run-hook.cmd polyglot invocation"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH1b the extracted literal does not route through run-hook.cmd"
  FAIL=$((FAIL + 1))
fi

if python3 -I -B -c 'import os; raise SystemExit(0 if os.name=="nt" else 1)'; then
  XH_NATIVE_WINDOWS=yes
else
  XH_NATIVE_WINDOWS=no
fi
if command -v jq >/dev/null 2>&1; then XH_JQ=present; else XH_JQ=absent; fi
# Non-fatal host row, printed on EVERY platform. Without it, the skip/run
# decision of the native-Windows arm below is inferable from the log but never
# stated, and "no XH5 line" reads the same as "XH5 quietly did nothing".
echo "  INFO  XH1c host uname=$(uname -s) native-windows-gate=${XH_NATIVE_WINDOWS} jq=${XH_JQ}"

# --- THE CR DETECTOR, and why it is not `grep` ------------------------------
# `grep` is DISQUALIFIED for this question on this repo's own Windows job.
# MSYS2's grep reads in TEXT mode and strips CR before matching, so
# `LC_ALL=C grep -q $'\r' <file>` reports "no CR" on a file that demonstrably
# has CRs. Measured on shape-checks-windows, not inferred: the CRLF fixture
# below reported `wc -c` = 2189 — exactly run-hook.cmd's 2126 LF bytes plus one
# CR for each of its 63 lines, so every CR byte was written — and the cr-grep on
# that same file returned rc=1. The same translation is visible from the other
# side, where a `$`-anchored grep matches a CRLF-checked-out file.
#
# That blindness silently inverted TWO rows before it was caught: XH2 below
# passed on windows-latest for the whole life of #494 while scanning with a
# detector that cannot see what it scans for, and XH2d called a CR-bearing
# checkout clean. A vacuous green is worse than a red.
#
# EVERY CR question in this file goes through this ONE helper. A second spelling
# of "does this file contain CR" is how the two answers drift apart.
#
# python3 with BINARY stdin, because byte-exactness on that host is already
# PROVEN by the very failure above: the producer read LF bytes through
# `sys.stdin.buffer` and wrote CRLF through `sys.stdout.buffer` and landed on
# 2189 exactly. CPython puts the standard streams in O_BINARY on Windows, so the
# buffer layer does no newline translation in either direction.
#
# Fed by REDIRECT, never as a path argument: windows-latest runs NATIVE Windows
# Python, which cannot resolve the MSYS `/…` paths Git Bash hands it — the same
# reason XH1a reads hooks.json from stdin.
#
# rc 0 = at least one CR byte, 1 = none, 2 = not a readable file, anything else
# = the detector itself failed. Callers MUST treat "neither 0 nor 1" as UNKNOWN
# and fail loudly; folding it into "clean" is exactly how a census goes vacuous.
xh_file_has_cr() {
  [ -f "$1" ] && [ -r "$1" ] || return 2
  python3 -I -B -c 'import sys
raise SystemExit(0 if b"\r" in sys.stdin.buffer.read() else 1)' < "$1"
}

# XH2a — THE DETECTOR'S OWN SELF-TEST, and the row this file was missing. Every
# CR claim below inherits this helper's correctness, so the helper is checked
# against two fixtures whose bytes are known by construction before anything
# uses it.
#
# THIS ROW FAILS ON windows-latest IF THE DETECTOR IS `grep`. That is the whole
# point: it turns a silent, platform-specific blindness into a red row on the
# host that has it, instead of letting it masquerade as a clean census. XH2
# alone could never catch this — a blind detector and a genuinely clean tree
# produce the identical "no CR found" answer, so the census agrees with its own
# blindness. Only a fixture with a KNOWN CR can tell those two apart.
XH_DET_TMP="$(mktemp -d)"
# The fixtures are written through the SAME python binary-stdout path that
# measurably produced a byte-perfect 2189-byte CRLF file on windows-latest — NOT
# through `printf`. Whether bash's builtin emits a raw CR to a redirected fd
# under MSYS is precisely the sort of unproven platform assumption that put the
# grep detector here to begin with, and a fixture this row cannot vouch for is a
# fixture that can red the job for the wrong reason.
#
# Sizes are then confirmed with `wc -c`, byte-exact on that host by the same
# measurement. A `dirty` file of exactly 2 bytes therefore HAS a CR as its second
# byte by construction, established without consulting the detector under test.
python3 -I -B -c 'import sys; sys.stdout.buffer.write(b"A\r")' > "$XH_DET_TMP/dirty"
python3 -I -B -c 'import sys; sys.stdout.buffer.write(b"A")'   > "$XH_DET_TMP/clean"
XH_DET_DIRTY_SIZE="$(wc -c < "$XH_DET_TMP/dirty" | tr -d '[:space:]')"
XH_DET_CLEAN_SIZE="$(wc -c < "$XH_DET_TMP/clean" | tr -d '[:space:]')"
xh_file_has_cr "$XH_DET_TMP/dirty"
XH_DET_DIRTY_RC=$?
xh_file_has_cr "$XH_DET_TMP/clean"
XH_DET_CLEAN_RC=$?
xh_file_has_cr "$XH_DET_TMP/does-not-exist"
XH_DET_MISSING_RC=$?
if [ "$XH_DET_DIRTY_SIZE" = 2 ] && [ "$XH_DET_CLEAN_SIZE" = 1 ] \
   && [ "$XH_DET_DIRTY_RC" -eq 0 ] && [ "$XH_DET_CLEAN_RC" -eq 1 ] \
   && [ "$XH_DET_MISSING_RC" -eq 2 ]; then
  echo "  PASS  XH2a the CR detector is byte-exact — it sees the CR in a 2-byte A+CR file, none in a 1-byte A file, and reports an unreadable path as unknown"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH2a the CR detector is not byte-exact on this host"
  echo "        fixtures: dirty=${XH_DET_DIRTY_SIZE} bytes (want 2), clean=${XH_DET_CLEAN_SIZE} bytes (want 1)"
  echo "        detector: dirty rc=${XH_DET_DIRTY_RC} (want 0), clean rc=${XH_DET_CLEAN_RC} (want 1), missing rc=${XH_DET_MISSING_RC} (want 2)"
  echo "        a wrong SIZE means the fixture writer is not byte-exact; a wrong RC means the detector is not."
  echo "        every CR claim below this row would be unsound — do NOT 'fix' those rows individually"
  FAIL=$((FAIL + 1))
fi
rm -rf "$XH_DET_TMP"

# --- XH2: the hook sources must be LF in the working tree -------------------
# The host this rule actually protects is a real user's Git-for-Windows clone,
# where `core.autocrlf=true` is the INSTALLER DEFAULT. Read with the byte-exact
# detector above: the previous `grep` form could not see a CR on windows-latest,
# so this census asserted nothing there. The row that proves the rule is
# load-bearing rather than decorative is XH2b below.
XH_CR_FILES=""
XH_CR_UNREADABLE=""
XH_CR_SCANNED=0
while IFS= read -r xh_hook_file; do
  [ -n "$xh_hook_file" ] || continue
  XH_CR_SCANNED=$((XH_CR_SCANNED + 1))
  xh_file_has_cr "$xh_hook_file"
  xh_cr_rc=$?
  # rc 0 = CR found, 1 = clean, anything else = the file's CR state is UNKNOWN.
  # Folding that third case into "clean" is how a census goes quietly vacuous.
  if [ "$xh_cr_rc" -eq 0 ]; then
    XH_CR_FILES="$XH_CR_FILES${XH_CR_FILES:+ }${xh_hook_file#"$REPO_ROOT"/}"
  elif [ "$xh_cr_rc" -ne 1 ]; then
    XH_CR_UNREADABLE="$XH_CR_UNREADABLE${XH_CR_UNREADABLE:+ }${xh_hook_file#"$REPO_ROOT"/}"
  fi
done <<EOF_XH_HOOK_FILES
$(find "$XH_HOOKS_DIR" -type f | sort)
EOF_XH_HOOK_FILES
if [ "$XH_CR_SCANNED" -lt 1 ]; then
  echo "  FAIL  XH2 scanned ZERO files under plugins/uberdev/hooks/ — the census is vacuous, not clean"
  FAIL=$((FAIL + 1))
elif [ -n "$XH_CR_UNREADABLE" ]; then
  echo "  FAIL  XH2 a hook source could not be read, so its CR state is unknown"
  printf '        %s\n' "$XH_CR_UNREADABLE"
  FAIL=$((FAIL + 1))
elif [ -z "$XH_CR_FILES" ]; then
  echo "  PASS  XH2 none of the ${XH_CR_SCANNED} files under plugins/uberdev/hooks/ carries a CR byte in the working tree"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH2 a hook source checked out with CR bytes — core.autocrlf rewrote it, and /.gitattributes should have pinned 'plugins/uberdev/hooks/** text eol=lf'"
  printf '        %s\n' "$XH_CR_FILES"
  FAIL=$((FAIL + 1))
fi

# --- XH2b/XH2c/XH2d: the CRLF mechanism proof -------------------------------
# CREATE the CRLF form and measure what the declared bash arm does with it. This
# is the opposite of stripping CR before executing, which would prove a
# counterfactual: here the defect is reproduced.
#
# `bash <file>` rather than executing the file, deliberately: `"shell": "bash"`
# is a claim about which interpreter parses run-hook.cmd, and forcing bash keeps
# the row about that claim (whether MSYS re-dispatches a `.cmd` through
# %COMSPEC% is a SEPARATE question, answered by XH6c below).
#
# WHY THE OUTCOME IS MEASURED AND NOT HARDCODED. The death this row used to
# assert unconditionally is a property of STOCK GNU bash, not of bash-on-Windows.
# The bash Git for Windows ships (C:\Program Files\Git\bin\bash.exe; `uname -s` =
# MINGW64_NT-…, see XH1c) is built from MSYS2's bash package, which applies
# MSYS2-packages/bash/0005-bash-4.3-msys2-fix-lineendings.patch. That patch adds
#
#     #ifdef __MSYS__
#           if (c == '\r')
#             continue;
#     #endif
#
# to shell_getc() in y.tab.c — the shell's own input reader — so every CR byte is
# discarded before the lexer ever sees it. That is a COMPILE-TIME property of the
# interpreter: not Cygwin's opt-in `set -o igncr`, not a text-mode mount, and
# nothing in the environment turns it off. On that host a CRLF run-hook.cmd
# parses byte-for-byte like the LF one and runs to completion — windows-latest
# measured rc=0 with EMPTY stderr, which is exactly what redded the hardcoded
# form of this row.
#
# So the interpreter's CR handling is MEASURED first (XH2b1) and the asserted
# outcome is the one that FOLLOWS from the measurement. Neither arm is a skip:
# the CR-blind arm asserts the CRLF copy is byte-for-byte indistinguishable from
# an LF control run through the same harness, which reds if the MSYS2 patch is
# ever dropped or the fixture stops being built.
#
# The pair XH2b + XH2d is what makes the rule load-bearing, and each half is
# needed. XH2b measures the HARM, and can only measure it on a CR-preserving
# bash — i.e. on ubuntu and macOS here, and on every POSIX interpreter that can
# still read a Git-for-Windows clone (WSL, a Linux container over the same
# checkout, this repo's own CI). XH2d measures whether the rule is EFFECTIVE at
# stopping CR from reaching the checkout at all, and does that identically on
# every host. Neither row claims the pin benefits every Windows consumer: XH6a
# and XH6c record that an EXECUTED run-hook.cmd is re-dispatched to cmd.exe on
# Windows, and cmd.exe is the CR-*preferring* side of the polyglot. That
# adjudication belongs to the evidence rows, not to an assertion here.
XH_CRLF_DIR="$(mktemp -d)"
cp "$XH_HOOKS_DIR/run-hook.cmd" "$XH_CRLF_DIR/run-hook.lf.cmd"
cp "$XH_HOOKS_DIR/session-start" "$XH_CRLF_DIR/session-start"
python3 -I -B -c 'import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))' \
  < "$XH_CRLF_DIR/run-hook.lf.cmd" > "$XH_CRLF_DIR/run-hook.cmd"
chmod 755 "$XH_CRLF_DIR/run-hook.cmd" "$XH_CRLF_DIR/run-hook.lf.cmd" "$XH_CRLF_DIR/session-start"

# XH2b0 — FIXTURE INTEGRITY. Both silent-vacuity modes are asserted rather than
# assumed: an empty or CR-less "CRLF" copy runs clean under ANY bash and `bash -n`
# returns 0 on it, so XH2b and XH2c would both go green over a fixture that never
# reproduced anything.
XH_CRLF_SIZE="$(wc -c < "$XH_CRLF_DIR/run-hook.cmd" | tr -d '[:space:]')"
xh_file_has_cr "$XH_CRLF_DIR/run-hook.cmd"
XH_CRLF_HAS_CR=$?
xh_file_has_cr "$XH_CRLF_DIR/run-hook.lf.cmd"
XH_LF_HAS_CR=$?
if [ "${XH_CRLF_SIZE:-0}" -gt 0 ] && [ "$XH_CRLF_HAS_CR" -eq 0 ] && [ "$XH_LF_HAS_CR" -eq 1 ]; then
  echo "  PASS  XH2b0 the fixture pair is real — the ${XH_CRLF_SIZE}-byte CRLF copy carries CR bytes, the LF control does not"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH2b0 the CRLF fixture pair was not produced (crlf bytes=${XH_CRLF_SIZE}, crlf cr-detect rc=${XH_CRLF_HAS_CR} want 0, lf cr-detect rc=${XH_LF_HAS_CR} want 1) — XH2b/XH2c would be vacuous"
  FAIL=$((FAIL + 1))
fi

# XH2b1 — MEASURE this bash's CR handling, on a fixture whose answer is a byte
# count rather than a platform guess. `printf X<CR>` is ONE word: a CR-blind bash
# parses it as `X` and writes 1 byte; a CR-preserving bash keeps the CR inside
# the word and writes 2, the second being the CR. Both halves are checked — a
# 2-byte write whose second byte is NOT a CR is a broken probe, not a
# classification — and an unclassifiable probe is a FAIL, never a default.
#
# `wc -c` plus the byte-exact detector above, never `grep`: on windows-latest a
# CR-blind grep would have answered "no CR" for BOTH outcomes, which happens to
# agree with the 1-byte case and so would have hidden a mis-measurement behind a
# correct-looking classification.
printf 'printf X\r\n' > "$XH_CRLF_DIR/cr-probe"
bash "$XH_CRLF_DIR/cr-probe" >"$XH_CRLF_DIR/cr-probe.out" 2>"$XH_CRLF_DIR/cr-probe.err"
XH_CR_PROBE_SIZE="$(wc -c < "$XH_CRLF_DIR/cr-probe.out" | tr -d '[:space:]')"
xh_file_has_cr "$XH_CRLF_DIR/cr-probe.out"
XH_CR_PROBE_HAS_CR=$?
if [ "${XH_CR_PROBE_SIZE:-0}" -eq 1 ] && [ "$XH_CR_PROBE_HAS_CR" -eq 1 ]; then
  XH_BASH_CR_BLIND=yes
elif [ "${XH_CR_PROBE_SIZE:-0}" -eq 2 ] && [ "$XH_CR_PROBE_HAS_CR" -eq 0 ]; then
  XH_BASH_CR_BLIND=no
else
  XH_BASH_CR_BLIND=unknown
fi
if [ "$XH_BASH_CR_BLIND" = unknown ]; then
  echo "  FAIL  XH2b1 this bash's CR handling could not be classified (probe wrote ${XH_CR_PROBE_SIZE} bytes, cr-detect rc=${XH_CR_PROBE_HAS_CR}; want 1+rc1 = CR-blind, 2+rc0 = CR-preserving)"
  printf '        stderr[0]: %s\n' "$(head -n 1 "$XH_CRLF_DIR/cr-probe.err")"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  XH2b1 this bash's CR handling measured: cr-blind=${XH_BASH_CR_BLIND} (probe wrote ${XH_CR_PROBE_SIZE} bytes, cr-detect rc=${XH_CR_PROBE_HAS_CR})"
  PASS=$((PASS + 1))
fi

# ONE runner for both halves of the comparison. Two hand-rolled copies of the
# hermetic env would be the same uncompared-copies drift the manifest extraction
# above avoids, and the CRLF half is precisely the copy nobody can eyeball on a
# CR-blind host. Each run gets its own throwaway HOME so neither can influence
# the other's output. $1 = wrapper to run, $2 = stdout sink, $3 = stderr sink.
xh_run_crlf_fixture() {
  local xh_fixture_home
  xh_fixture_home="$(mktemp -d)"
  # LC_ALL=C so bash's diagnostic is the C-locale English this row matches on.
  env -u COPILOT_CLI -u CODEX_HOME -u CURSOR_PLUGIN_ROOT LC_ALL=C \
      HOME="$xh_fixture_home" UBERDEV_NO_AUTO_ALIAS=1 CLAUDE_PLUGIN_ROOT="$XH_PLUGIN_DIR" \
      bash "$1" session-start >"$2" 2>"$3" </dev/null
  XH_CRLF_RUN_RC=$?
  rm -rf "$xh_fixture_home"
}
xh_run_crlf_fixture "$XH_CRLF_DIR/run-hook.lf.cmd" "$XH_CRLF_DIR/lf.stdout" "$XH_CRLF_DIR/lf.stderr"
XH_LF_RC=$XH_CRLF_RUN_RC
xh_run_crlf_fixture "$XH_CRLF_DIR/run-hook.cmd" "$XH_CRLF_DIR/stdout" "$XH_CRLF_DIR/stderr"
XH_CRLF_RC=$XH_CRLF_RUN_RC
XH_CRLF_ERR_HEAD="$(head -n 1 "$XH_CRLF_DIR/stderr" 2>/dev/null)"

# XH2b2 — the LF CONTROL, asserted on every platform. Without it the CR-blind arm
# would be comparing two outputs that could both be empty, and the fixture dir (a
# copy of the wrapper next to a copy of session-start) would itself be an
# unverified harness.
if [ "$XH_LF_RC" -eq 0 ] && grep -q 'SessionStart' "$XH_CRLF_DIR/lf.stdout"; then
  echo "  PASS  XH2b2 the LF control in the same fixture dir emits the SessionStart contract (rc=${XH_LF_RC})"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH2b2 the LF control emitted no SessionStart contract (rc=${XH_LF_RC}) — the fixture harness is broken, so XH2b proves nothing"
  printf '        stderr[0]: %s\n' "$(head -n 1 "$XH_CRLF_DIR/lf.stderr")"
  FAIL=$((FAIL + 1))
fi

case "$XH_BASH_CR_BLIND" in
  no)
    if [ "$XH_CRLF_RC" -ne 0 ] \
       && grep -q 'command not found' "$XH_CRLF_DIR/stderr" \
       && ! grep -q 'SessionStart' "$XH_CRLF_DIR/stdout"; then
      echo "  PASS  XH2b under this CR-preserving bash a CRLF run-hook.cmd dies (rc=${XH_CRLF_RC}) and emits no SessionStart contract"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  XH2b a CR-preserving bash did NOT kill the CRLF run-hook.cmd (rc=${XH_CRLF_RC})"
      printf '        stderr[0]: %s\n' "$XH_CRLF_ERR_HEAD"
      FAIL=$((FAIL + 1))
    fi
    ;;
  yes)
    if [ "$XH_CRLF_RC" -eq "$XH_LF_RC" ] && cmp -s "$XH_CRLF_DIR/stdout" "$XH_CRLF_DIR/lf.stdout"; then
      echo "  PASS  XH2b this bash is CR-BLIND (MSYS2 shell_getc drops \\r), so the CRLF copy is indistinguishable from the LF control (rc=${XH_CRLF_RC}, stdout byte-identical) — the harm channel is NOT reproducible on this host by any means, and XH2d proves the rule's effect here instead"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  XH2b this bash measured CR-BLIND but the CRLF copy did not match the LF control (crlf rc=${XH_CRLF_RC} vs lf rc=${XH_LF_RC}; stdout differs)"
      printf '        stderr[0]: %s\n' "$XH_CRLF_ERR_HEAD"
      FAIL=$((FAIL + 1))
    fi
    ;;
  *)
    echo "  FAIL  XH2b not asserted — XH2b1 could not classify this bash, and a row that asserts nothing must never read as a pass (crlf rc=${XH_CRLF_RC})"
    FAIL=$((FAIL + 1))
    ;;
esac

bash -n "$XH_CRLF_DIR/run-hook.cmd" 2>/dev/null
XH_CRLF_SYNTAX_RC=$?
# The `run-hook.cmd parses under bash -n` guard at the top of this file returns
# 0 on the very copy that dies at runtime under a CR-preserving bash. Pinning
# that here is what stops a future reader from deleting XH2b as redundant with a
# syntax check.
if [ "$XH_CRLF_SYNTAX_RC" -eq 0 ]; then
  echo "  PASS  XH2c bash -n returns 0 on that same CRLF copy — the syntax guard is structurally blind to this class"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH2c bash -n rejected the CRLF copy (rc=${XH_CRLF_SYNTAX_RC}); re-check whether XH2b still proves anything the syntax guard misses"
  FAIL=$((FAIL + 1))
fi
rm -rf "$XH_CRLF_DIR"

# --- XH2d: the /.gitattributes rule, proved against git itself --------------
# XH2b proves the HARM of a CR byte, and can only do so on a bash that preserves
# CR. This row proves the rule is EFFECTIVE, which is a different claim and one
# layer earlier: stop `core.autocrlf=true` — the Git-for-Windows INSTALLER
# DEFAULT — from ever writing a CR into the checkout. That job belongs to git,
# not to the host: `core.autocrlf` is config, not platform behaviour, so `true`
# rewrites LF→CRLF on checkout on ubuntu and macOS exactly as it does on
# Windows. The row therefore runs identically on every host in the matrix,
# including the CR-blind one where XH2b's harm channel is unreproducible.
#
# BOTH directions are measured in the same scratch repo, because only the pair
# is evidence: an unprotected checkout must come back WITH CR (else autocrlf is
# not a live threat here and the row proves nothing), and the same checkout under
# the rule must come back WITHOUT.
#
# The rule text is READ OUT of the real /.gitattributes and never retyped — a
# retyped literal is the "one contract, N uncompared copies" drift this file's
# header is about, and it would hold this row green over a rule the repo has
# since narrowed, widened or deleted.
# "Active line" is defined exactly as tests/docs-accuracy.test.sh T8.10 defines
# it — drop comments and blanks first, then select the hooks-scoped rules — so
# the two guards cannot disagree about what counts as a rule.
XH_GA_RULES="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/.gitattributes" 2>/dev/null | grep -E 'plugins/uberdev/hooks')"
if [ -z "$XH_GA_RULES" ]; then
  echo "  FAIL  XH2d /.gitattributes carries no active rule scoped to plugins/uberdev/hooks — nothing pins the hook sources to LF on a core.autocrlf=true clone"
  FAIL=$((FAIL + 1))
else
  XH_GA_TMP="$(mktemp -d)"
  mkdir -p "$XH_GA_TMP/home" "$XH_GA_TMP/repo/plugins/uberdev/hooks"
  cp "$XH_HOOKS_DIR/run-hook.cmd" "$XH_GA_TMP/repo/plugins/uberdev/hooks/run-hook.cmd"
  # HOME/XDG redirected and system config off: the invoking user's ~/.gitconfig
  # (or a global core.attributesFile) must not decide this row's answer.
  xh_git() {
    env HOME="$XH_GA_TMP/home" XDG_CONFIG_HOME="$XH_GA_TMP/home/.config" \
        GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        git -C "$XH_GA_TMP/repo" \
            -c init.defaultBranch=main -c core.autocrlf=true \
            -c user.name=uberdev-xh2d -c user.email=xh2d@example.invalid \
            -c commit.gpgsign=false "$@"
  }
  # Deletes the worktree copy and restores it through git's checkout filters, so
  # the CR (or its absence) is written by the same code path a clone uses.
  # Returns the detector's rc: 0 = CR present, 1 = clean, else unknown.
  xh_ga_checkout_has_cr() {
    rm -f "$XH_GA_TMP/repo/plugins/uberdev/hooks/run-hook.cmd"
    xh_git checkout -q -- plugins/uberdev/hooks/run-hook.cmd >/dev/null 2>&1
    xh_file_has_cr "$XH_GA_TMP/repo/plugins/uberdev/hooks/run-hook.cmd"
  }
  XH_GA_SETUP_RC=0
  xh_git init -q >/dev/null 2>&1 || XH_GA_SETUP_RC=1
  xh_git add plugins/uberdev/hooks/run-hook.cmd >/dev/null 2>&1 || XH_GA_SETUP_RC=1
  xh_git commit -q -m 'seed hook source (LF)' >/dev/null 2>&1 || XH_GA_SETUP_RC=1
  xh_ga_checkout_has_cr
  XH_GA_UNPROTECTED=$?
  printf '%s\n' "$XH_GA_RULES" > "$XH_GA_TMP/repo/.gitattributes"
  xh_git add .gitattributes >/dev/null 2>&1 || XH_GA_SETUP_RC=1
  xh_git commit -q -m 'add the repo hooks rule' >/dev/null 2>&1 || XH_GA_SETUP_RC=1
  xh_ga_checkout_has_cr
  XH_GA_PROTECTED=$?
  if [ "$XH_GA_SETUP_RC" -ne 0 ]; then
    echo "  FAIL  XH2d the scratch git repo could not be built, so the rule was never exercised"
    FAIL=$((FAIL + 1))
  elif [ "$XH_GA_UNPROTECTED" -ne 0 ]; then
    echo "  FAIL  XH2d core.autocrlf=true left an UNPROTECTED checkout free of CR (cr-detect rc=${XH_GA_UNPROTECTED}) — with no threat reproduced, this row cannot show the rule matters"
    FAIL=$((FAIL + 1))
  elif [ "$XH_GA_PROTECTED" -eq 1 ]; then
    echo "  PASS  XH2d the /.gitattributes hooks rule beats core.autocrlf=true — the unprotected checkout comes back with CR, the same checkout under the rule comes back LF"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  XH2d the /.gitattributes hooks rule did not keep the checkout LF under core.autocrlf=true (cr-detect rc=${XH_GA_PROTECTED}; 0=CR present, 2=unknown)"
    printf '        rule(s) exercised: %s\n' "$XH_GA_RULES"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$XH_GA_TMP"
fi

# --- XH3/XH4: the executed positive oracle, and its hermeticity -------------
# CLAUDE_PLUGIN_ROOT goes in the ENVIRONMENT and the shell expands it, exactly
# as the runtime's spawn(command, [], {shell}) does — string-substituting it
# here would test a literal the runtime never sees.
#
# THE ORACLE IS THE EMITTED JSON FIELD, NEVER THE EXIT CODE: a hook that never
# loaded also exits 0 on several paths (run-hook.cmd's no-bash arm is a
# deliberate `exit /b 0`), which is the whole shape of the silent failure. The
# oracle also holds on a jq-less host — session-start's degraded arm emits the
# same hookSpecificOutput.hookEventName.
#
# ONE runner and ONE parser, shared by the POSIX row and the native-Windows row
# below. Two hand-rolled copies of the hermetic env would be the same
# uncompared-copies drift the extraction above avoids, and the Windows copy is
# precisely the one nobody can run locally to notice the divergence.
#
# $1 = CLAUDE_PLUGIN_ROOT to run under, $2 = stdout sink, $3 = stderr sink.
# Sets XH_RUN_RC and XH_RUN_HOME_ENTRIES; the throwaway HOME is always removed.
xh_run_declared_command() {
  XH_RUN_HOME="$(mktemp -d)"
  env -u COPILOT_CLI -u CODEX_HOME -u CURSOR_PLUGIN_ROOT \
      HOME="$XH_RUN_HOME" UBERDEV_NO_AUTO_ALIAS=1 CLAUDE_PLUGIN_ROOT="$1" \
      bash -c "$XH_CMD" >"$2" 2>"$3" </dev/null
  XH_RUN_RC=$?
  XH_RUN_HOME_ENTRIES="$(find "$XH_RUN_HOME" -mindepth 1 | wc -l | tr -d '[:space:]')"
  rm -rf "$XH_RUN_HOME"
}
# Prints the EVENT NAME only. The real body is ~16 KB of injected context and
# has no place in a CI log.
xh_event_name() {
  python3 -I -B -c 'import json,sys
try:
    doc = json.load(sys.stdin)
except (ValueError, UnicodeDecodeError):
    doc = {}
out = doc.get("hookSpecificOutput", {}) if isinstance(doc, dict) else {}
print(out.get("hookEventName", "") if isinstance(out, dict) else "", end="")' < "$1"
}

XH_OUT_FILE="$(mktemp)"
XH_ERR_FILE="$(mktemp)"
xh_run_declared_command "$XH_PLUGIN_DIR" "$XH_OUT_FILE" "$XH_ERR_FILE"
XH_EVENT="$(xh_event_name "$XH_OUT_FILE")"
if [ "$XH_EVENT" = "SessionStart" ]; then
  echo "  PASS  XH3 the declared SessionStart command runs and emits hookSpecificOutput.hookEventName (rc=${XH_RUN_RC})"
  PASS=$((PASS + 1))
else
  echo "  FAIL  XH3 the declared SessionStart command emitted no SessionStart contract (rc=${XH_RUN_RC}, event='${XH_EVENT}')"
  printf '        stderr[0]: %s\n' "$(head -n 1 "$XH_ERR_FILE")"
  FAIL=$((FAIL + 1))
fi
# A hook that writes into the invoking user's home during a test is a test that
# mutates the runner. The alias forwarders are the concrete risk here, hence
# UBERDEV_NO_AUTO_ALIAS=1 in the runner and this row to prove it held.
assert_eq "$XH_RUN_HOME_ENTRIES" "0" \
  "XH4 the oracle is hermetic — it wrote nothing into its throwaway HOME"
rm -f "$XH_OUT_FILE" "$XH_ERR_FILE"

# --- XH5/XH6/XH7: the native-Windows arm ------------------------------------
# This is the issue's actual question and the RFC 0019 §7 verification
# obligation: a green macOS or ubuntu run leaves every branch below UNEXECUTED
# and is not evidence for any of it.
if [ "$XH_NATIVE_WINDOWS" = yes ]; then
  XH_WIN_ROOT="$(cygpath -m "$XH_PLUGIN_DIR")"
  assert_nonempty "$XH_WIN_ROOT" \
    "XH5a cygpath -m normalised the plugin root for the native-Windows arm"
  XH_WIN_OUT="$(mktemp)"
  XH_WIN_ERR="$(mktemp)"
  xh_run_declared_command "$XH_WIN_ROOT" "$XH_WIN_OUT" "$XH_WIN_ERR"
  XH_WIN_EVENT="$(xh_event_name "$XH_WIN_OUT")"
  if [ "$XH_WIN_EVENT" = "SessionStart" ]; then
    echo "  PASS  XH5 the declared SessionStart command runs on NATIVE Windows with a cygpath-normalised plugin root (rc=${XH_RUN_RC})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  XH5 the declared SessionStart command emitted no SessionStart contract on NATIVE Windows (rc=${XH_RUN_RC}, event='${XH_WIN_EVENT}')"
    printf '        stderr[0]: %s\n' "$(head -n 1 "$XH_WIN_ERR")"
    FAIL=$((FAIL + 1))
  fi
  assert_eq "$XH_RUN_HOME_ENTRIES" "0" \
    "XH5b the native-Windows oracle is hermetic — it wrote nothing into its throwaway HOME"
  rm -f "$XH_WIN_OUT" "$XH_WIN_ERR"

  # XH6a/XH6b are RECORDED, not asserted. Ossifying an assumption about someone
  # else's parser is how the stale claims this issue also had to repair got
  # written; what the log needs is the observed rc from each interpreter.
  XH_CMD_CMDEXE="${XH_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/%CLAUDE_PLUGIN_ROOT%}"
  XH_PROBE_OUT="$(CLAUDE_PLUGIN_ROOT="$XH_WIN_ROOT" cmd.exe //c "$XH_CMD_CMDEXE" 2>&1 </dev/null)"
  XH_PROBE_RC=$?
  echo "  INFO  XH6a cmd.exe rc=${XH_PROBE_RC} first-line=$(printf '%s' "$XH_PROBE_OUT" | head -n 1)"
  XH_CMD_PWSH="${XH_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/\$\{env:CLAUDE_PLUGIN_ROOT\}}"
  XH_PROBE_OUT="$(CLAUDE_PLUGIN_ROOT="$XH_WIN_ROOT" powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$XH_CMD_PWSH" 2>&1 </dev/null)"
  XH_PROBE_RC=$?
  echo "  INFO  XH6b powershell.exe rc=${XH_PROBE_RC} first-line=$(printf '%s' "$XH_PROBE_OUT" | head -n 1)"
else
  # A skip must never read as a pass, so each suppressed row is named with its
  # reason rather than simply not printed (same discipline as the `zsh -n` skip
  # near the top of this file).
  echo "  SKIP  XH5a/XH5 declared-command execution on native Windows (not a native Windows host)"
  echo "  SKIP  XH5b native-Windows hermeticity (not a native Windows host)"
  echo "  SKIP  XH6a cmd.exe interpreter evidence (not a native Windows host)"
  echo "  SKIP  XH6b powershell.exe interpreter evidence (not a native Windows host)"
fi

# XH6c — INTERPRETER IDENTITY, printed on every platform because POSIX is the
# control. run-hook.cmd is invoked through the shell with NO argument, which
# makes each arm name itself:
#   * `missing script name` + rc=1  => cmd.exe ran it (MSYS re-dispatched the
#     `.cmd` through %COMSPEC%), so the batch arm is NOT vestigial under a
#     declared bash shell and `eol=lf` needs re-examining against its goto loop;
#   * anything else (measured on POSIX: rc=126, `…/hooks/: Is a directory`)
#     => bash ran it, which is what `"shell": "bash"` assumes.
# The assertion half is POSIX-only, because POSIX is where the expected answer
# was measured; on Windows the row is evidence for the adjudication, not a gate.
XH_ID_HOME="$(mktemp -d)"
XH_ID_OUT="$(env -u COPILOT_CLI -u CODEX_HOME -u CURSOR_PLUGIN_ROOT LC_ALL=C \
    HOME="$XH_ID_HOME" UBERDEV_NO_AUTO_ALIAS=1 CLAUDE_PLUGIN_ROOT="$XH_PLUGIN_DIR" \
    bash -c "\"$XH_HOOKS_DIR/run-hook.cmd\"" 2>&1 </dev/null)"
XH_ID_RC=$?
rm -rf "$XH_ID_HOME"
echo "  INFO  XH6c run-hook.cmd with no argument: rc=${XH_ID_RC} first-line=$(printf '%s' "$XH_ID_OUT" | head -n 1)"
if [ "$XH_NATIVE_WINDOWS" = yes ]; then
  echo "  SKIP  XH6c assertion (native Windows — the rc above is evidence for adjudication, not a gate)"
elif grep -q 'missing script name' <<<"$XH_ID_OUT"; then
  echo "  FAIL  XH6c the cmd.exe arm answered on a POSIX host — run-hook.cmd is not being parsed by bash"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  XH6c the bash arm answers on POSIX, as \"shell\": \"bash\" assumes"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
