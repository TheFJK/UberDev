#!/usr/bin/env bash
# Tests for issue #16 — top-level aliases for the seven most-used uberdev
# commands (/issue, /solve, /turbo, /simplify, /review-pr, /merge, /dev).
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
#   A1 — install-aliases.md exists, references all 7 aliases, has marker
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
CANON_DIR="$REPO_ROOT/plugins/uberdev/commands"

# Pre-flight: refuse to run if any asserted-against file is missing or
# unreadable. Without this, every assertion fails with a confusing "pattern
# not found" instead of the real cause (mirrors audit-fixups.test.sh).
# Section A6 also reads each canonical's frontmatter, so those files are
# pre-flighted too.
for f in "$INSTALL_CMD" "$UNINSTALL_CMD" "$README" \
         "$CANON_DIR/issue.md" "$CANON_DIR/solve.md" "$CANON_DIR/turbo.md" \
         "$CANON_DIR/simplify.md" "$CANON_DIR/review-pr.md" \
         "$CANON_DIR/merge.md" "$CANON_DIR/dev.md" \
         "$REPO_ROOT/.github/workflows/test.yml"; do
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

# Stub PLUGIN_ROOT to the worktree so the hook can read plugin.json
HOOK="$REPO_ROOT/plugins/uberdev/hooks/session-start"
PLUGIN_JSON="$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json"
PLUGIN_VERSION="$(jq -r .version "$PLUGIN_JSON")"

echo "== A1: install-aliases command exists and registers all 7 aliases =="
# Each canonical /uberdev:<name> must be wired up. We grep for the literal
# canonical command names since those are the targets the forwarders must
# point at; if any is missing, the user-visible alias for that command
# silently won't be installed.
for canonical in issue solve turbo simplify review-pr merge dev; do
  assert_grep "$INSTALL_CMD" \
    "uberdev:${canonical}\\b" \
    "install-aliases references canonical /uberdev:${canonical}"
done

# Marker is the safe-uninstall contract — uninstall-aliases keys off this
# string to know which user-level files belong to us. Without the marker,
# uninstall would either be unsafe (might delete user-authored files) or
# impossible (couldn't tell ours apart). Both files must agree on the literal.
MARKER='managed-by:[[:space:]]*uberdev-aliases'
assert_grep "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh" "$MARKER" \
  "lib/aliases-sync.sh writes the 'managed-by: uberdev-aliases' marker into forwarders"
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

# Belt-and-braces: uninstall must NOT do an unguarded rm of all 7 paths.
assert_grep_not "$UNINSTALL_CMD" \
  'rm[[:space:]]+-f[[:space:]]+"?\$HOME/\.claude/commands/(issue|solve|turbo|simplify|review-pr|merge|dev)\.md"?[[:space:]]*$' \
  "uninstall-aliases does NOT unconditionally rm forwarder paths"

echo
echo "== A5: README documents the short forms =="
# Discoverability acceptance criterion. README must mention at least one of
# the short forms AND the install command — otherwise the feature is
# invisible to new users.
assert_grep "$README" \
  '/issue.*alias|short.?form|/uberdev:install-aliases' \
  "README documents the short-form aliases or install command"

# All seven short forms should appear somewhere in the README so users can
# search for them.
for short in /issue /solve /turbo /simplify /review-pr /merge /dev; do
  assert_grep "$README" \
    "${short}\\b" \
    "README mentions short form ${short}"
done

echo
echo "== A6: alias forwarders mirror each canonical's allowed-tools =="
# Bind the drift contract to the actual write logic. A6 below verifies the
# ALIASES table matches each canonical's frontmatter, but doesn't catch a
# bug where the heredoc writes a different variable to the forwarder's
# `allowed-tools` line (e.g., `allowed-tools: $WRONGVAR`). This thin
# assertion closes that gap by requiring the write line to read exactly
# `allowed-tools: $TOOLS` — same variable name parsed from the ALIASES
# rows. Together, A6's two halves guarantee canonical → ALIASES → written
# forwarder share one source of truth.
assert_grep "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh" \
  '^allowed-tools: \$TOOLS$' \
  "lib/aliases-sync.sh heredoc writes the \$TOOLS variable from the ALIASES table"

# The ALIASES table in install-aliases.md hardcodes per-alias allowed-tools.
# That value MUST equal the canonical command's `allowed-tools:` line, byte
# for byte — otherwise the forwarder grants a different (usually narrower)
# tool surface than the canonical, and the alias silently breaks at the
# first tool the canonical needs but the forwarder can't use.
#
# We grep the canonical's allowed-tools line, normalize whitespace, and
# look for a matching ALIASES row in install-aliases.md that contains
# both the canonical name and the same JSON array. The check is
# fixed-string (-F) on the JSON tail, so trivial reformatting that
# preserves byte-equality stays green.
for canonical in issue solve turbo simplify review-pr merge dev; do
  canon_file="$CANON_DIR/${canonical}.md"
  # Strip the `allowed-tools: ` prefix, leaving just the JSON array.
  canon_tools=$(grep -E '^allowed-tools:[[:space:]]*' "$canon_file" \
                | head -1 | sed -E 's/^allowed-tools:[[:space:]]*//')
  if [ -z "$canon_tools" ]; then
    echo "  FAIL  /$canonical — could not extract allowed-tools from $canon_file"
    FAIL=$((FAIL + 1))
    continue
  fi
  if grep -F "${canonical}|${canonical}|${canon_tools}" "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh" > /dev/null; then
    echo "  PASS  /$canonical — ALIASES row matches canonical allowed-tools"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  /$canonical — ALIASES row drift detected"
    echo "        canonical allowed-tools: $canon_tools"
    echo "        expected ALIASES row:    ${canonical}|${canonical}|${canon_tools}"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== S1: fresh install — first session installs all 7 aliases =="
S1_HOME="$(mktemp -d)"
S1_STDERR="$(mktemp)"
HOME="$S1_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>"$S1_STDERR" || true

for short in issue solve turbo simplify review-pr merge dev; do
  if [ -f "$S1_HOME/.claude/commands/${short}.md" ] \
     && grep -q 'managed-by: uberdev-aliases' "$S1_HOME/.claude/commands/${short}.md"; then
    echo "  PASS  S1: /$short installed with marker"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S1: /$short missing or unmarkered"
    FAIL=$((FAIL + 1))
  fi
done
if [ "$(cat "$S1_HOME/.claude/.uberdev-aliases-version" 2>/dev/null || true)" = "$PLUGIN_VERSION" ]; then
  echo "  PASS  S1: version marker contains $PLUGIN_VERSION"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S1: version marker missing or wrong"
  FAIL=$((FAIL + 1))
fi
if grep -q "first run: installed 7 aliases" "$S1_STDERR"; then
  echo "  PASS  S1: first-run summary line on stderr"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S1: first-run summary line missing"
  FAIL=$((FAIL + 1))
fi
rm -rf "$S1_HOME" "$S1_STDERR"

echo
echo "== S2: second session is a no-op =="
S2_HOME="$(mktemp -d)"
S2_STDERR="$(mktemp)"
HOME="$S2_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null || true

# Precondition: first run must have produced the 7 forwarders. Without this
# guard, the mtime capture below silently picks up empty strings for absent
# files, the post-run lookup also returns "", and `[ "" = "" ]` makes the
# section spuriously PASS — masking the very TDD red signal we want.
S2_PREFLIGHT_OK=1
for short in issue solve turbo simplify review-pr merge dev; do
  [ -f "$S2_HOME/.claude/commands/${short}.md" ] || S2_PREFLIGHT_OK=0
done

if [ "$S2_PREFLIGHT_OK" != "1" ]; then
  echo "  FAIL  S2: precondition — first run did not produce forwarders"; FAIL=$((FAIL + 1))
else
  # Capture mtimes after first run. Bash 3.2 (the macOS /bin/bash) lacks
  # associative arrays, so write one mtime-per-line to a temp file keyed by
  # short name, and grep them back for comparison. The seven short names are
  # fixed; review-pr would be illegal as a bash variable name.
  S2_MT_FILE="$(mktemp)"
  for short in issue solve turbo simplify review-pr merge dev; do
    mt="$(stat -c %Y "$S2_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || stat -f %m "$S2_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || echo "")"
    printf '%s %s\n' "$short" "$mt" >> "$S2_MT_FILE"
  done
  sleep 1
  HOME="$S2_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash "$HOOK" >/dev/null 2>"$S2_STDERR" || true
  S2_OK=1
  for short in issue solve turbo simplify review-pr merge dev; do
    NEW="$(stat -c %Y "$S2_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || stat -f %m "$S2_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || echo "")"
    OLD="$(awk -v k="$short" '$1==k {print $2}' "$S2_MT_FILE")"
    if [ "$NEW" != "$OLD" ]; then S2_OK=0; break; fi
  done
  rm -f "$S2_MT_FILE"
  if [ "$S2_OK" = "1" ]; then
    echo "  PASS  S2: no mtime changes on second session"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S2: forwarder mtimes changed on second session"; FAIL=$((FAIL + 1))
  fi
  if ! grep -q "first run:" "$S2_STDERR"; then
    echo "  PASS  S2: stderr is silent on second session"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S2: first-run line printed on second session"; FAIL=$((FAIL + 1))
  fi
fi
rm -rf "$S2_HOME" "$S2_STDERR"

echo
echo "== S3: plugin upgrade refreshes forwarders =="
S3_HOME="$(mktemp -d)"
S3_STDERR="$(mktemp)"
HOME="$S3_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null || true

# Precondition: first run must have produced the 7 forwarders before we can
# meaningfully test that a stale-marker rewrite changes their mtimes. Same
# spurious-PASS trap as S2 if absent.
S3_PREFLIGHT_OK=1
for short in issue solve turbo simplify review-pr merge dev; do
  [ -f "$S3_HOME/.claude/commands/${short}.md" ] || S3_PREFLIGHT_OK=0
done

if [ "$S3_PREFLIGHT_OK" != "1" ]; then
  echo "  FAIL  S3: precondition — first run did not produce forwarders"; FAIL=$((FAIL + 1))
else
  # Rewrite version-marker to a stale value
  printf '0.10.0\n' > "$S3_HOME/.claude/.uberdev-aliases-version"
  # Capture pre-refresh mtimes via a flat temp file (bash 3.2 compat — see S2).
  S3_MT_FILE="$(mktemp)"
  for short in issue solve turbo simplify review-pr merge dev; do
    mt="$(stat -c %Y "$S3_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || stat -f %m "$S3_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || echo "")"
    printf '%s %s\n' "$short" "$mt" >> "$S3_MT_FILE"
  done
  sleep 1
  HOME="$S3_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash "$HOOK" >/dev/null 2>"$S3_STDERR" || true
  S3_OK=1
  for short in issue solve turbo simplify review-pr merge dev; do
    NEW="$(stat -c %Y "$S3_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || stat -f %m "$S3_HOME/.claude/commands/${short}.md" 2>/dev/null \
           || echo "")"
    OLD="$(awk -v k="$short" '$1==k {print $2}' "$S3_MT_FILE")"
    if [ "$NEW" = "$OLD" ]; then S3_OK=0; break; fi
  done
  rm -f "$S3_MT_FILE"
  if [ "$S3_OK" = "1" ]; then
    echo "  PASS  S3: forwarders rewritten on version mismatch"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S3: forwarders not refreshed on version mismatch"; FAIL=$((FAIL + 1))
  fi
  if [ "$(cat "$S3_HOME/.claude/.uberdev-aliases-version" 2>/dev/null || true)" = "$PLUGIN_VERSION" ]; then
    echo "  PASS  S3: version marker updated to $PLUGIN_VERSION"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S3: version marker not updated"; FAIL=$((FAIL + 1))
  fi
  if ! grep -q "first run:" "$S3_STDERR"; then
    echo "  PASS  S3: stderr silent on refresh (Q5)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S3: first-run line printed on refresh"; FAIL=$((FAIL + 1))
  fi
fi
rm -rf "$S3_HOME" "$S3_STDERR"

echo
echo "== S4: UBERDEV_NO_AUTO_ALIAS=1 short-circuits =="
# Variant a: env var
S4A_HOME="$(mktemp -d)"
HOME="$S4A_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  UBERDEV_NO_AUTO_ALIAS=1 bash "$HOOK" >/dev/null 2>/dev/null || true
if [ ! -e "$S4A_HOME/.claude/commands/issue.md" ] \
   && [ ! -e "$S4A_HOME/.claude/.uberdev-aliases-version" ]; then
  echo "  PASS  S4a: env var blocks all writes"; PASS=$((PASS + 1))
else
  echo "  FAIL  S4a: writes happened despite env var"; FAIL=$((FAIL + 1))
fi
rm -rf "$S4A_HOME"

# Variant b: uberdev.local.md
S4B_HOME="$(mktemp -d)"
S4B_PWD="$(mktemp -d)"
mkdir -p "$S4B_PWD/.claude"
cat > "$S4B_PWD/.claude/uberdev.local.md" <<'EOF'
---
auto_install_aliases: false
---
EOF
( cd "$S4B_PWD" && \
  HOME="$S4B_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash "$HOOK" >/dev/null 2>/dev/null || true )
if [ ! -e "$S4B_HOME/.claude/commands/issue.md" ]; then
  echo "  PASS  S4b: uberdev.local.md blocks writes"; PASS=$((PASS + 1))
else
  echo "  FAIL  S4b: writes happened despite uberdev.local.md opt-out"; FAIL=$((FAIL + 1))
fi
rm -rf "$S4B_HOME" "$S4B_PWD"

# Variant c: both → env var wins (no writes)
S4C_HOME="$(mktemp -d)"
HOME="$S4C_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  UBERDEV_NO_AUTO_ALIAS=1 bash "$HOOK" >/dev/null 2>/dev/null || true
if [ ! -e "$S4C_HOME/.claude/commands/issue.md" ]; then
  echo "  PASS  S4c: env+file → no writes"; PASS=$((PASS + 1))
else
  echo "  FAIL  S4c: writes happened with both opt-outs set"; FAIL=$((FAIL + 1))
fi
rm -rf "$S4C_HOME"

echo
echo "== S5: hand-authored file survives marker-scoped skip =="
S5_HOME="$(mktemp -d)"
mkdir -p "$S5_HOME/.claude/commands"
printf '# my custom solve\n' > "$S5_HOME/.claude/commands/solve.md"
S5_STDERR="$(mktemp)"
HOME="$S5_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>"$S5_STDERR" || true
if [ "$(cat "$S5_HOME/.claude/commands/solve.md")" = "# my custom solve" ]; then
  echo "  PASS  S5: hand-authored solve.md preserved byte-for-byte"; PASS=$((PASS + 1))
else
  echo "  FAIL  S5: hand-authored solve.md was overwritten"; FAIL=$((FAIL + 1))
fi
S5_INSTALLED=0
for short in issue turbo simplify review-pr merge dev; do
  if grep -q 'managed-by: uberdev-aliases' "$S5_HOME/.claude/commands/${short}.md" 2>/dev/null; then
    S5_INSTALLED=$((S5_INSTALLED + 1))
  fi
done
if [ "$S5_INSTALLED" = "6" ]; then
  echo "  PASS  S5: other 6 forwarders installed"; PASS=$((PASS + 1))
else
  echo "  FAIL  S5: only $S5_INSTALLED of 6 non-collision forwarders installed"; FAIL=$((FAIL + 1))
fi
if grep -q "installed 6 aliases, skipped 1 conflicts (solve)" "$S5_STDERR"; then
  echo "  PASS  S5: stderr summary reports skip"; PASS=$((PASS + 1))
else
  echo "  FAIL  S5: stderr did not report skip"; FAIL=$((FAIL + 1))
fi
rm -rf "$S5_HOME" "$S5_STDERR"

echo
echo "== S5b: symlinked ~/.claude/commands is refused =="
S5B_HOME="$(mktemp -d)"
S5B_DECOY="$(mktemp -d)"
mkdir -p "$S5B_HOME/.claude"
ln -s "$S5B_DECOY" "$S5B_HOME/.claude/commands"
# Precondition: on Git Bash (windows-latest CI) without admin / Developer
# Mode, `ln -s` does not create a POSIX symlink — it either fails silently
# or copies the target directory. `[ -L ]` then returns false and there is
# no symlink-shaped thing for the hook to refuse, so the refusal assertion
# below cannot be satisfied. Convert that into a SKIP rather than a FAIL:
# the test cannot meaningfully run when the platform's `ln -s` cannot
# produce a real symlink.
if [ ! -L "$S5B_HOME/.claude/commands" ]; then
  echo "  SKIP  S5b: ln -s did not produce a symlink on this platform (Git Bash without admin/Developer Mode?)"
else
  S5B_STDERR="$(mktemp)"
  HOME="$S5B_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash "$HOOK" >/dev/null 2>"$S5B_STDERR" || true
  if grep -q "refusing to sync" "$S5B_STDERR"; then
    echo "  PASS  S5b: symlinked commands dir refused"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S5b: symlink refusal stderr line missing"; FAIL=$((FAIL + 1))
  fi
  if [ -z "$(ls -A "$S5B_DECOY")" ]; then
    echo "  PASS  S5b: no writes into symlink target"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S5b: files written into symlinked dir"; FAIL=$((FAIL + 1))
  fi
  rm -f "$S5B_STDERR"
fi
rm -rf "$S5B_HOME" "$S5B_DECOY"

echo
echo "== S5b-guard: hook does not refuse a regular (non-symlinked) commands dir =="
# Complement to S5b — pins the false-positive direction: a regular pre-
# existing ~/.claude/commands directory must NOT trigger the symlink
# refusal. Catches regressions if the detection is ever tightened to
# also flag non-symlinks. This test runs on every platform; on Windows
# (where the precondition above SKIPs S5b) it doubles as live coverage
# for the directory-shape that `ln -s` produces when it cannot create
# a real symlink and silently copies / fails — the hook must accept
# that shape just as it accepts a fresh `mkdir -p`.
S5B_GUARD_HOME="$(mktemp -d)"
mkdir -p "$S5B_GUARD_HOME/.claude/commands"
S5B_GUARD_STDERR="$(mktemp)"
HOME="$S5B_GUARD_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>"$S5B_GUARD_STDERR" || true
if grep -q "refusing to sync" "$S5B_GUARD_STDERR"; then
  echo "  FAIL  S5b-guard: hook emitted refusal for a regular (non-symlink) dir"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S5b-guard: hook does not refuse a regular (non-symlink) commands dir"; PASS=$((PASS + 1))
fi
rm -rf "$S5B_GUARD_HOME" "$S5B_GUARD_STDERR"

echo
echo "== S6: uninstall-aliases removes version-marker =="
S6_HOME="$(mktemp -d)"
HOME="$S6_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null || true
# Static check: the uninstall-aliases command's bash body removes the marker.
if grep -qE 'rm[[:space:]]+-f[[:space:]]+"\$MARKER"|rm[[:space:]]+-f[[:space:]]+.*\.uberdev-aliases-version' \
   "$REPO_ROOT/plugins/uberdev/commands/uninstall-aliases.md"; then
  echo "  PASS  S6: uninstall-aliases.md contains version-marker rm"; PASS=$((PASS + 1))
else
  echo "  FAIL  S6: uninstall-aliases.md does not remove version-marker"; FAIL=$((FAIL + 1))
fi
rm -rf "$S6_HOME"

echo
echo "== S7: unreadable version-marker degrades to first-run =="
S7_HOME="$(mktemp -d)"
mkdir -p "$S7_HOME/.claude"
printf '0.10.0\n' > "$S7_HOME/.claude/.uberdev-aliases-version"
chmod 000 "$S7_HOME/.claude/.uberdev-aliases-version"
HOME="$S7_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null || true
chmod 644 "$S7_HOME/.claude/.uberdev-aliases-version" 2>/dev/null || true
if [ -f "$S7_HOME/.claude/commands/issue.md" ]; then
  echo "  PASS  S7: hook proceeded despite unreadable marker"; PASS=$((PASS + 1))
else
  echo "  FAIL  S7: hook crashed or skipped on unreadable marker"; FAIL=$((FAIL + 1))
fi
rm -rf "$S7_HOME"

echo
echo "== S8: two concurrent sessions converge byte-correctly =="
S8_HOME="$(mktemp -d)"
HOME="$S8_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null &
S8_P1=$!
HOME="$S8_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >/dev/null 2>/dev/null &
S8_P2=$!
wait "$S8_P1" "$S8_P2" || true
S8_OK=1
for short in issue solve turbo simplify review-pr merge dev; do
  f="$S8_HOME/.claude/commands/${short}.md"
  if [ ! -s "$f" ] || ! grep -q 'managed-by: uberdev-aliases' "$f"; then
    S8_OK=0; break
  fi
done
if [ "$S8_OK" = "1" ]; then
  echo "  PASS  S8: all 7 forwarders well-formed after race"; PASS=$((PASS + 1))
else
  echo "  FAIL  S8: race produced malformed/empty forwarder"; FAIL=$((FAIL + 1))
fi
if [ "$(cat "$S8_HOME/.claude/.uberdev-aliases-version" 2>/dev/null)" = "$PLUGIN_VERSION" ]; then
  echo "  PASS  S8: version-marker correct after race"; PASS=$((PASS + 1))
else
  echo "  FAIL  S8: version-marker corrupt after race"; FAIL=$((FAIL + 1))
fi
rm -rf "$S8_HOME"

echo
echo "== S9: aliases.test.sh is wired into CI =="
CI_YML="$REPO_ROOT/.github/workflows/test.yml"
if grep -qE 'aliases\.test\.sh' "$CI_YML"; then
  echo "  PASS  S9: aliases.test.sh referenced in test.yml"; PASS=$((PASS + 1))
else
  echo "  FAIL  S9: aliases.test.sh missing from test.yml"; FAIL=$((FAIL + 1))
fi

echo
echo "== S10: _aliases_read_version matches jq -r .version =="
# RFC 0004: the jq-free version reader must return the byte-identical string
# that `jq -r .version` returns on the plugin's own manifest. Sourcing the
# library in a command-substitution subshell keeps its functions scoped.
S10_GOT="$(
  . "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
  _aliases_read_version "$PLUGIN_JSON"
)"
if [ "$S10_GOT" = "$PLUGIN_VERSION" ]; then
  echo "  PASS  S10: _aliases_read_version → $S10_GOT"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10: got '$S10_GOT', expected '$PLUGIN_VERSION'"; FAIL=$((FAIL + 1))
fi

echo
echo "== S11: aliases_sync_main sets UBERDEV_ALIAS_NOTICE on first run =="
# RFC 0004: on a fresh install aliases_sync_main must compose a first-run
# notice into the UBERDEV_ALIAS_NOTICE global for the hook to inject.
S11_HOME="$(mktemp -d)"
S11_GOT="$(
  HOME="$S11_HOME"
  PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  . "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
  aliases_sync_main >/dev/null 2>&1
  printf '%s' "${UBERDEV_ALIAS_NOTICE:-}"
)"
case "$S11_GOT" in
  *"installed 7 short-form aliases"*)
    echo "  PASS  S11: first-run notice composed"; PASS=$((PASS + 1)) ;;
  *)
    echo "  FAIL  S11: UBERDEV_ALIAS_NOTICE='$S11_GOT'"; FAIL=$((FAIL + 1)) ;;
esac
rm -rf "$S11_HOME"

echo
echo "== S12: aliases install with jq absent (RFC 0004) =="
# Mask jq: build a bin dir holding symlinks to every tool the hook needs
# EXCEPT jq, then run the hook with PATH pointed only at it. With the
# RFC-0004 reorder, alias sync runs before the jq guard, so the seven
# forwarders must still install, and a fixed jq-missing notice must surface.
S12_BIN="$(mktemp -d)"
for t in bash grep sed head cat mkdir mktemp mv rm dirname; do
  src="$(command -v "$t" 2>/dev/null)" && ln -s "$src" "$S12_BIN/$t"
done
S12_HOME="$(mktemp -d)"
S12_STDOUT="$(mktemp)"
PATH="$S12_BIN" HOME="$S12_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >"$S12_STDOUT" 2>/dev/null || true
S12_OK=1
for short in issue solve turbo simplify review-pr merge dev; do
  if [ ! -f "$S12_HOME/.claude/commands/${short}.md" ] \
     || ! grep -q 'managed-by: uberdev-aliases' "$S12_HOME/.claude/commands/${short}.md"; then
    S12_OK=0; break
  fi
done
if [ "$S12_OK" = "1" ]; then
  echo "  PASS  S12: all 7 forwarders installed with jq masked"; PASS=$((PASS + 1))
else
  echo "  FAIL  S12: forwarders missing when jq absent"; FAIL=$((FAIL + 1))
fi
if grep -q 'jq not found' "$S12_STDOUT"; then
  echo "  PASS  S12: jq-missing notice surfaced in context"; PASS=$((PASS + 1))
else
  echo "  FAIL  S12: jq-missing notice not surfaced"; FAIL=$((FAIL + 1))
fi
rm -rf "$S12_BIN" "$S12_HOME" "$S12_STDOUT"

echo
echo "== S13: a collision is surfaced in the session context =="
# A hand-authored forwarder collides; the skipped alias must be named in the
# hook's stdout context injection, not just on stderr (RFC 0004).
S13_HOME="$(mktemp -d)"
mkdir -p "$S13_HOME/.claude/commands"
printf '# my custom turbo\n' > "$S13_HOME/.claude/commands/turbo.md"
S13_STDOUT="$(mktemp)"
HOME="$S13_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >"$S13_STDOUT" 2>/dev/null || true
if grep -q 'turbo' "$S13_STDOUT" && grep -qE 'not installed|already exists' "$S13_STDOUT"; then
  echo "  PASS  S13: collision notice present in context injection"; PASS=$((PASS + 1))
else
  echo "  FAIL  S13: collision notice missing from context"; FAIL=$((FAIL + 1))
fi
rm -rf "$S13_HOME" "$S13_STDOUT"

echo
echo "== S14: the first-run notice is surfaced in the session context =="
S14_HOME="$(mktemp -d)"
S14_STDOUT="$(mktemp)"
HOME="$S14_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >"$S14_STDOUT" 2>/dev/null || true
if grep -q 'installed 7 short-form aliases' "$S14_STDOUT"; then
  echo "  PASS  S14: first-run notice present in context injection"; PASS=$((PASS + 1))
else
  echo "  FAIL  S14: first-run notice missing from context"; FAIL=$((FAIL + 1))
fi
rm -rf "$S14_HOME" "$S14_STDOUT"

echo
echo "== S15: a write failure surfaces a failure notice (RFC 0004) =="
# Force _aliases_write_forwarder to fail by making ~/.claude/commands
# read-only after creating it; the per-alias loop then populates FAILED_LIST
# and the hook must inject the "failed to install alias(es)" notice.
S15_HOME="$(mktemp -d)"
mkdir -p "$S15_HOME/.claude/commands"
chmod 555 "$S15_HOME/.claude/commands"
S15_STDOUT="$(mktemp)"
HOME="$S15_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  bash "$HOOK" >"$S15_STDOUT" 2>/dev/null || true
chmod 755 "$S15_HOME/.claude/commands" 2>/dev/null || true
if grep -qE 'failed to install alias' "$S15_STDOUT"; then
  echo "  PASS  S15: write-failure notice surfaced in context"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15: write-failure notice missing from context"; FAIL=$((FAIL + 1))
fi
rm -rf "$S15_HOME" "$S15_STDOUT"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
