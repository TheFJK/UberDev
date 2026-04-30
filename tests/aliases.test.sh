#!/usr/bin/env bash
# Tests for issue #16 — top-level aliases for the five most-used uberdev
# commands (/issue, /solve, /turbo, /simplify, /review-pr).
#
# Plugin commands are addressed as `/uberdev:<command>` because Claude Code's
# plugin manifest enforces the `<plugin-name>:` prefix on every plugin
# command. There is no manifest field for declaring a top-level alias, so
# the only viable mechanism is shipping forwarders into the user's
# standalone `~/.claude/commands/` directory, where filename = command name
# with no plugin prefix.
#
# This file asserts the contract for the install-aliases / uninstall-aliases
# plugin commands that do that work. It intentionally does NOT shell out to
# Claude Code itself — these are grep-based structural assertions in the
# style of tests/audit-fixups.test.sh and tests/turbo-flow.test.sh, runnable
# in CI before merge without an interactive harness.
#
# Sections:
#   A1 — install-aliases.md exists, references all 5 aliases, has marker
#   A2 — install-aliases.md performs collision detection (skip-if-exists)
#   A3 — install-aliases.md generates ONE-WAY forwarders, not duplicates
#   A4 — uninstall-aliases.md exists and only removes marker-tagged files
#   A5 — README documents the short forms and the install command

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

INSTALL_CMD="$REPO_ROOT/plugins/uberdev/commands/install-aliases.md"
UNINSTALL_CMD="$REPO_ROOT/plugins/uberdev/commands/uninstall-aliases.md"
README="$REPO_ROOT/README.md"

# Pre-flight: refuse to run if any asserted-against file is missing or
# unreadable. Without this, every assertion fails with a confusing "pattern
# not found" instead of the real cause (mirrors audit-fixups.test.sh).
for f in "$INSTALL_CMD" "$UNINSTALL_CMD" "$README"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc — pattern '$pattern' should not appear"
    echo "        file: $file"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== A1: install-aliases command exists and registers all 5 aliases =="
# Each canonical /uberdev:<name> must be wired up. We grep for the literal
# canonical command names since those are the targets the forwarders must
# point at; if any is missing, the user-visible alias for that command
# silently won't be installed.
for canonical in issue solve turbo simplify review-pr; do
  assert_grep "$INSTALL_CMD" \
    "uberdev:${canonical}\\b" \
    "install-aliases references canonical /uberdev:${canonical}"
done

# Marker is the safe-uninstall contract — uninstall-aliases keys off this
# string to know which user-level files belong to us. Without the marker,
# uninstall would either be unsafe (might delete user-authored files) or
# impossible (couldn't tell ours apart). Both files must agree on the literal.
MARKER='managed-by:[[:space:]]*uberdev-aliases'
assert_grep "$INSTALL_CMD" "$MARKER" \
  "install-aliases writes the 'managed-by: uberdev-aliases' marker into forwarders"
assert_grep "$UNINSTALL_CMD" "$MARKER" \
  "uninstall-aliases keys off the same 'managed-by: uberdev-aliases' marker"

echo
echo "== A2: install-aliases performs collision detection =="
# The issue's acceptance criterion: pre-flight detects collisions with
# existing user-level commands (built-in /review, other plugins claiming
# the short name, or hand-authored files) and degrades gracefully —
# warning + skip rather than overwrite. The phrasing has multiple valid
# expressions; accept any of them so the assertion doesn't ossify around
# a single wording.
assert_grep "$INSTALL_CMD" \
  'skip|already exists|collision|conflict|-e[[:space:]]+"\$' \
  "install-aliases skips on collision rather than overwriting"

# Negative: install must not contain blast-radius-y patterns that would
# bypass collision detection. We forbid the specifically-dangerous shapes
# (`cp -f`, `rm -rf $HOME...`) rather than the literal flag name `--force`,
# because `--force` is also the legitimate user-flag NAME the command
# accepts (gated behind the marker check, so safe). The dangerous shapes
# below are unambiguous: any of them in this file would be a footgun.
assert_grep_not "$INSTALL_CMD" \
  'cp[[:space:]]+-f[[:space:]]|rm[[:space:]]+-rf[[:space:]]+"?\$HOME[/"]' \
  "install-aliases does NOT contain cp -f or rm -rf \$HOME patterns"

echo
echo "== A3: forwarders are one-way pointers, not file duplication =="
# The issue is explicit: "The mapping must be one-way forwarding, not file
# duplication — maintaining two copies of issue.md is exactly the trap we'd
# be falling into."
#
# The forwarder template inside install-aliases must NOT inline the body of
# any canonical command. We pick a fingerprint from each canonical that
# would never appear in a thin forwarder: a Phase heading or a substantial
# bash block unique to that file. If install-aliases contains the
# fingerprint, it's duplicating instead of forwarding.
assert_grep_not "$INSTALL_CMD" \
  'Phase 0: Detect repo \+ parse flags' \
  "install-aliases does NOT inline issue.md's Phase 0 body"
assert_grep_not "$INSTALL_CMD" \
  'DUPLICATION NOTE — KEEP IN SYNC' \
  "install-aliases does NOT inline solve.md/turbo.md's duplication-note block"
assert_grep_not "$INSTALL_CMD" \
  'Phase 1: Identify Changes' \
  "install-aliases does NOT inline simplify.md's Phase 1 body"

# Positive: forwarder must reference the canonical's path so dispatch
# resolves at runtime. Any of `${CLAUDE_PLUGIN_ROOT}`, an `@`-include, or
# an absolute-path placeholder that's filled in at install time satisfies
# the one-way-pointer contract.
assert_grep "$INSTALL_CMD" \
  'CLAUDE_PLUGIN_ROOT|commands/(issue|solve|turbo|simplify|review-pr)\.md' \
  "install-aliases forwarder template points at canonical command files"

echo
echo "== A4: uninstall-aliases is marker-scoped =="
# Without marker scoping, uninstall could delete user-authored files that
# happen to share a short name. Assert that uninstall reads/checks the
# marker before removing.
assert_grep "$UNINSTALL_CMD" \
  'grep|-q|managed-by' \
  "uninstall-aliases checks for the marker before removing files"

# Belt-and-braces: uninstall must NOT do an unguarded rm of all 5 paths.
assert_grep_not "$UNINSTALL_CMD" \
  'rm[[:space:]]+-f[[:space:]]+"?\$HOME/\.claude/commands/(issue|solve|turbo|simplify|review-pr)\.md"?[[:space:]]*$' \
  "uninstall-aliases does NOT unconditionally rm forwarder paths"

echo
echo "== A5: README documents the short forms =="
# Discoverability acceptance criterion. README must mention at least one of
# the short forms AND the install command — otherwise the feature is
# invisible to new users.
assert_grep "$README" \
  '/issue.*alias|short.?form|/uberdev:install-aliases' \
  "README documents the short-form aliases or install command"

# All five short forms should appear somewhere in the README so users can
# search for them.
for short in /issue /solve /turbo /simplify /review-pr; do
  assert_grep "$README" \
    "${short}\\b" \
    "README mentions short form ${short}"
done

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
