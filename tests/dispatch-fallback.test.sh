#!/usr/bin/env bash
# Shape-check for the platform-aware fallback resolver in lib/dispatch.sh
# (uberdev_dispatch_preflight). Verifies the per-OS preference order, the
# WSL2 same-OS guard, single-resolution (no mid-fanout switch), and the
# explicit --backend= hard-error path. RFC 0004 §3.3 / §4.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

echo "== Positive: auto resolution is Workflow-native (RFC 0015) =="
# The per-OS auto matrix (macos->wezterm/detached, wsl2/linux->detached,
# windows-native->wezterm-or-hard-error) existed ONLY to choose a detached
# process supervisor. The Workflow runtime needs no supervisor, so `auto` now
# resolves to `workflow` everywhere, Codex environments included (#381). These lock
# the new contract; the OS-class detector and the supervision gate are still
# exercised, because the EXPLICIT detached backends still depend on them.
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_os_class' \
  "preflight still calls the OS-class detector (explicit detached backends need it)"
assert_grep "$DISPATCH_LIB" \
  'resolved="workflow"; reason="auto-workflow"' \
  "auto resolves to the Workflow-native backend"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_numeric_supervision_supported' \
  "resolver still shares the native-Windows numeric supervision capability gate"
assert_grep_not "$DISPATCH_LIB" \
  'resolved="background"; reason="auto-windows-fallback"' \
  "auto never falls back to an unsupervisable numeric backend"
assert_grep_not "$DISPATCH_LIB" \
  'reason="auto-macos-wezterm"' \
  "the retired macos->wezterm auto arm is gone"
assert_grep_not "$DISPATCH_LIB" \
  'reason="auto-wsl2"' \
  "the retired wsl2 detached auto arm is gone"
assert_grep_not "$DISPATCH_LIB" \
  'reason="auto-linux"' \
  "the retired linux detached auto arm is gone"
assert_grep "$DISPATCH_LIB" \
  'UBERDEV_RESOLVED_BACKEND' \
  "preflight exports UBERDEV_RESOLVED_BACKEND"
assert_grep "$DISPATCH_LIB" \
  'dispatch_backend_resolved' \
  "preflight emits the dispatch_backend_resolved audit event"

echo "== Functional: auto never selects a detached backend on any OS =="
for OS_CLASS in macos linux wsl2 windows-native; do
  AUTO_BACKEND="$(/bin/bash -c '
    . "$1"
    # Capture the class BEFORE defining the override: inside a function body
    # $2 is the FUNCTION\047s second argument, not the shell\047s, so reading
    # it there would silently print empty and the per-OS assertion would pass
    # vacuously on every platform.
    _forced_os_class="$2"
    _uberdev_dispatch_os_class() { printf "%s" "$_forced_os_class"; }
    _uberdev_dispatch_wezterm_available() { return 0; }
    unset CODEX_HOME UBERDEV_RESOLVED_BACKEND
    UBERDEV_DISPATCH_BACKEND_REQUESTED=auto
    uberdev_dispatch_preflight solve >/dev/null 2>&1 || exit
    printf "%s" "$UBERDEV_RESOLVED_BACKEND"
  ' _ "$DISPATCH_LIB" "$OS_CLASS")"
  if [ "$AUTO_BACKEND" = workflow ]; then
    echo "  PASS  auto on $OS_CLASS resolves to workflow (WezTerm available and still not chosen)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  auto on $OS_CLASS resolved to '$AUTO_BACKEND', expected workflow"
    FAIL=$((FAIL + 1))
  fi
done

echo "== Functional: native Windows no longer hard-errors without WezTerm =="
# This was a hard refusal before RFC 0015 — the Workflow runtime needs no
# process tree, so native Windows is now a first-class host.
if WINDOWS_AUTO_BACKEND="$(/bin/bash -c '
  . "$1"
  _uberdev_dispatch_os_class() { printf windows-native; }
  _uberdev_dispatch_wezterm_available() { return 1; }
  unset CODEX_HOME UBERDEV_RESOLVED_BACKEND
  UBERDEV_DISPATCH_BACKEND_REQUESTED=auto
  uberdev_dispatch_preflight solve >/dev/null 2>&1 || exit
  printf "%s" "$UBERDEV_RESOLVED_BACKEND"
' _ "$DISPATCH_LIB")" && [ "$WINDOWS_AUTO_BACKEND" = workflow ]; then
  echo "  PASS  native Windows auto resolves to workflow with no WezTerm installed"
  PASS=$((PASS + 1))
else
  echo "  FAIL  native Windows auto did not resolve to workflow: $WINDOWS_AUTO_BACKEND"
  FAIL=$((FAIL + 1))
fi

# INVERTED, not deleted (#381). This block used to prove that a Codex
# environment WON `auto`: CODEX_HOME being set was one of two escapes that ran
# BEFORE the per-OS matrix and resolved the codex backend. Both escapes were
# removed with the transport (lib/dispatch.sh:635-637), so the property to lock
# is the opposite one -- an ambient CODEX_HOME must no longer steer resolution.
# The stub for _uberdev_dispatch_codex_available is gone too: the function no
# longer exists, so redefining it was an inert no-op that made this block look
# like it probed a capability when it probed nothing.
echo "== Functional: an ambient Codex environment no longer steers auto =="
if CODEX_AUTO_BACKEND="$(/bin/bash -c '
  . "$1"
  _uberdev_dispatch_os_class() { printf linux; }
  _uberdev_dispatch_wezterm_available() { return 1; }
  CODEX_HOME=/tmp/codex UBERDEV_DISPATCH_BACKEND_REQUESTED=auto
  unset UBERDEV_RESOLVED_BACKEND
  uberdev_dispatch_preflight solve >/dev/null 2>&1 || exit
  printf "%s" "$UBERDEV_RESOLVED_BACKEND"
' _ "$DISPATCH_LIB")" && [ "$CODEX_AUTO_BACKEND" = workflow ]; then
  echo "  PASS  auto with CODEX_HOME set still resolves to workflow (the escape is gone)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  CODEX_HOME still steers auto: resolved '$CODEX_AUTO_BACKEND', expected workflow"
  FAIL=$((FAIL + 1))
fi

# This block used to prove the OPPOSITE: that the deprecated detached backend
# still resolved, loudly. It is INVERTED, not deleted (RFC 0015 section 7 as
# amended) -- naming the retired backend must now be a hard enum error, and the
# error must list the accepted set so the operator is not left guessing.
echo "== Functional: the retired detached backend is refused by the enum, loudly =="
# preflight's own rc is captured INSIDE the subshell: the trailing printf would
# otherwise mask it and the assertion would read a refusal as a success.
BG_REFUSAL="$(/bin/bash -c '
  . "$1"
  _uberdev_dispatch_os_class() { printf linux; }
  unset CODEX_HOME UBERDEV_RESOLVED_BACKEND
  UBERDEV_DISPATCH_BACKEND_REQUESTED=claude-bg
  uberdev_dispatch_preflight solve >/dev/null
  printf "|rc=%s|resolved=%s" "$?" "${UBERDEV_RESOLVED_BACKEND-}"
' _ "$DISPATCH_LIB" 2>&1)"
if grep -Fq "|rc=1|resolved=" <<<"$BG_REFUSAL" \
    && grep -Fq "not in {auto|workflow|wezterm|background}" <<<"$BG_REFUSAL" \
    && ! grep -Fq "resolved=claude-bg" <<<"$BG_REFUSAL"; then
  echo "  PASS  the retired detached backend is refused by the enum, naming the accepted set"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the retired detached backend still resolves: $BG_REFUSAL"
  FAIL=$((FAIL + 1))
fi

echo "== Positive: WSL2 same-OS mux guard + single resolution =="
assert_grep "$DISPATCH_LIB" \
  'wezterm-mux-server|list-clients' \
  "preflight probes WezTerm mux availability (list-clients poll)"
assert_grep "$DISPATCH_LIB" \
  'same.OS|AF_UNIX|WSLg' \
  "preflight documents/enforces the WSL2 same-OS mux constraint"
assert_grep "$DISPATCH_LIB" \
  'commits|once per|whole batch|single' \
  "preflight resolves once and commits the whole batch (no mid-fanout switch)"

echo "== Positive: explicit --backend= hard-errors when unusable =="
assert_grep "$DISPATCH_LIB" \
  'UBERDEV_DISPATCH_BACKEND_REQUESTED|requested' \
  "preflight distinguishes an explicit request from auto"
assert_grep "$DISPATCH_LIB" \
  '^[[:space:]]*(exit|return) 1' \
  "preflight hard-errors (non-zero) when an explicit backend is unusable"

echo "== Anti-pattern: auto never escapes as a resolved backend =="
assert_grep_not "$DISPATCH_LIB" \
  'UBERDEV_RESOLVED_BACKEND=auto$|UBERDEV_RESOLVED_BACKEND="auto"' \
  "auto is resolved away — never assigned as the final backend"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
