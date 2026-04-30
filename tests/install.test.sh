#!/usr/bin/env bash
# Tests for issue #22 — install.sh bootstrap script enables the plugin in
# ~/.claude/settings.json (working around Claude Code's enabledPlugins bug,
# refs anthropics/claude-code#20661).
#
# /plugin install populates the cache + installed_plugins.json but does NOT
# write enabledPlugins. Loader reads only the latter, so commands silently
# 404 until enabledPlugins["uberdev@uberdev"] = true is added by hand. The
# install.sh bootstrap closes that gap on a curl|bash one-liner.
#
# These are sandbox tests: each section runs install.sh under a temp $HOME
# with a no-op `claude` stub on PATH, so we exercise the jq-patch behavior
# without touching the user's real ~/.claude or hitting the Claude API.
#
# Sections:
#   I1 — install.sh exists at repo root, has shebang, is executable
#   I2 — fresh install: settings.json created with enabledPlugins entry
#   I3 — preserves unrelated keys (theme/model/etc.) on existing settings.json
#   I4 — preserves other enabledPlugins entries (doesn't clobber sibling plugins)
#   I5 — idempotent: re-run produces byte-identical settings.json
#   I6 — refuses to clobber malformed settings.json (exits non-zero, file untouched)
#   I7 — README documents the install.sh / curl|bash one-liner
#   I8 — script does not contain destructive shapes (rm -rf $HOME, etc.)
#   I9 — re-run flips a manually-disabled (false) entry back to true

# `set -e` is intentionally NOT enabled: a failed assertion must NOT abort the
# rest of the suite. We track PASS/FAIL counters explicitly and exit non-zero
# at the end if any failed. `set -u` and `pipefail` stay on for the usual
# safety reasons (catch typos, propagate failures through pipes).
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

INSTALL_SH="$REPO_ROOT/install.sh"
README="$REPO_ROOT/README.md"

# Pre-flight: refuse to run if asserted-against files are missing. Without
# this, every assertion fails with a confusing "pattern not found" instead
# of the real cause (mirrors aliases.test.sh and audit-fixups.test.sh).
for f in "$INSTALL_SH" "$README"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

# jq is required by install.sh AND by these tests' assertions. Catch the
# missing-tool case here with a clear message rather than letting jq's own
# "command not found" leak through every assertion.
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required to run these tests (and to run install.sh)." >&2
  exit 2
fi

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

# Stubbed `claude` shared across all sandboxes. install.sh invokes claude for
# marketplace-add + install (best-effort); a silent no-op stub is enough for
# these tests, which target the jq-patch contract — not the slash-command
# layer. Hoisted to one shared dir to avoid rewriting the stub per sandbox.
STUB_BIN_DIR="$(mktemp -d)"
cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN_DIR/claude"

# Build a sandbox $HOME for one install.sh invocation. The sandbox is
# isolated per section so each test starts from a known settings.json
# state without coupling between sections.
make_sandbox() {
  mktemp -d
}

# Seed a sandbox with a starting settings.json. Used by I3/I4/I6 to set up
# the various preconditions (unrelated keys / sibling enabledPlugins /
# malformed JSON) we want install.sh to handle correctly.
seed_settings() {
  local home="$1" content="$2"
  mkdir -p "$home/.claude"
  printf '%s' "$content" > "$home/.claude/settings.json"
}

# Run install.sh under a sandbox HOME. PATH is prefixed with the shared stub
# dir so our claude wins; the rest of PATH is preserved so jq and coreutils
# still resolve.
run_install() {
  local home="$1"
  HOME="$home" PATH="$STUB_BIN_DIR:$PATH" bash "$INSTALL_SH" >"$home/install.out" 2>&1
  return $?
}

echo "== I1: install.sh exists, has shebang, is executable =="
assert_grep "$INSTALL_SH" '^#!/' "install.sh has a shebang"
if [ -x "$INSTALL_SH" ]; then
  echo "  PASS  install.sh is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL  install.sh is not executable (chmod +x install.sh)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I2: fresh install creates settings.json with enabledPlugins entry =="
SANDBOX="$(make_sandbox)"
if run_install "$SANDBOX"; then
  SETTINGS="$SANDBOX/.claude/settings.json"
  if [ ! -f "$SETTINGS" ]; then
    echo "  FAIL  settings.json was not created at $SETTINGS"
    FAIL=$((FAIL + 1))
  elif jq -e '.enabledPlugins["uberdev@uberdev"] == true' "$SETTINGS" >/dev/null 2>&1; then
    echo "  PASS  enabledPlugins[\"uberdev@uberdev\"] = true on fresh install"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  enabledPlugins entry not set"
    echo "        settings.json: $(cat "$SETTINGS" 2>&1)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  install.sh exited non-zero on fresh install"
  echo "        output: $(cat "$SANDBOX/install.out" 2>&1)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I3: existing unrelated settings keys are preserved =="
SANDBOX="$(make_sandbox)"
seed_settings "$SANDBOX" \
  '{"theme":"dark","model":"claude-opus-4-7","permissions":{"allow":["Bash"]}}'
if run_install "$SANDBOX"; then
  if jq -e '
      .theme == "dark"
      and .model == "claude-opus-4-7"
      and .permissions.allow == ["Bash"]
      and .enabledPlugins["uberdev@uberdev"] == true
    ' "$SANDBOX/.claude/settings.json" >/dev/null 2>&1; then
    echo "  PASS  unrelated keys (theme/model/permissions) preserved"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  unrelated keys clobbered or enabledPlugins missing"
    echo "        settings.json: $(cat "$SANDBOX/.claude/settings.json")"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  install.sh exited non-zero with existing settings.json"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I4: other enabledPlugins entries are preserved =="
SANDBOX="$(make_sandbox)"
seed_settings "$SANDBOX" \
  '{"enabledPlugins":{"other-plugin@market":true,"third@market":false}}'
if run_install "$SANDBOX"; then
  if jq -e '
      .enabledPlugins["other-plugin@market"] == true
      and .enabledPlugins["third@market"] == false
      and .enabledPlugins["uberdev@uberdev"] == true
    ' "$SANDBOX/.claude/settings.json" >/dev/null 2>&1; then
    echo "  PASS  other plugin entries preserved alongside ours"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  other plugin entries clobbered"
    echo "        settings.json: $(cat "$SANDBOX/.claude/settings.json")"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  install.sh exited non-zero with pre-existing enabledPlugins"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I5: re-running install.sh is idempotent =="
SANDBOX="$(make_sandbox)"
run_install "$SANDBOX" >/dev/null
FIRST="$(cat "$SANDBOX/.claude/settings.json")"
run_install "$SANDBOX" >/dev/null
SECOND="$(cat "$SANDBOX/.claude/settings.json")"
if [ "$FIRST" = "$SECOND" ]; then
  echo "  PASS  re-run produces byte-identical settings.json (no duplicates, no churn)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  re-run mutated settings.json"
  echo "        first:  $FIRST"
  echo "        second: $SECOND"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I6: malformed settings.json is refused, not clobbered =="
SANDBOX="$(make_sandbox)"
BAD='this is { not valid json'
seed_settings "$SANDBOX" "$BAD"
if run_install "$SANDBOX"; then
  echo "  FAIL  install.sh succeeded on malformed settings.json (should refuse)"
  FAIL=$((FAIL + 1))
else
  CURRENT="$(cat "$SANDBOX/.claude/settings.json")"
  if [ "$CURRENT" = "$BAD" ]; then
    echo "  PASS  install.sh refused malformed settings.json and left it untouched"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  install.sh exited non-zero but mutated the malformed file anyway"
    echo "        before: $BAD"
    echo "        after:  $CURRENT"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== I7: README documents the install.sh / curl|bash one-liner =="
assert_grep "$README" \
  'install\.sh|curl[[:space:]]+-fsSL.*UberDev' \
  "README references install.sh or curl|bash install path"
assert_grep "$README" \
  'enabledPlugins|claude-code/issues/20661' \
  "README mentions the upstream enabledPlugins bug context"

echo
echo "== I8: install.sh contains no destructive shell shapes =="
# Mirror the safety guard in aliases.test.sh A2: forbid the unambiguous
# footguns rather than the literal flag --force (which is a legitimate
# user-facing flag name in our other scripts). rm -rf $HOME or cp -f over
# user files would be a bug regardless of context.
assert_grep_not "$INSTALL_SH" \
  'rm[[:space:]]+-rf[[:space:]]+"?\$HOME[/"]' \
  "install.sh does NOT contain rm -rf \$HOME patterns"
assert_grep_not "$INSTALL_SH" \
  'rm[[:space:]]+-rf[[:space:]]+"?\$\{?HOME\}?/\.claude[/"]?[[:space:]]*$' \
  "install.sh does NOT rm -rf the user's ~/.claude directory"

echo
echo "== I9: re-run flips a manually-disabled entry back to true =="
# A user (or a future /uberdev:doctor command) may have set the entry to
# false to temporarily disable the plugin. Re-running install.sh must flip
# it back to true — otherwise the bug-workaround silently no-ops on the
# very state it's meant to fix. Guards against a future refactor that
# guards the assignment behind an `if .enabledPlugins[$key] then ...`
# check, which would preserve the false value instead of overwriting it.
SANDBOX="$(make_sandbox)"
seed_settings "$SANDBOX" '{"enabledPlugins":{"uberdev@uberdev":false}}'
if run_install "$SANDBOX"; then
  if jq -e '.enabledPlugins["uberdev@uberdev"] == true' \
       "$SANDBOX/.claude/settings.json" >/dev/null 2>&1; then
    echo "  PASS  pre-existing false entry flipped back to true"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  pre-existing false entry was not flipped to true"
    echo "        settings.json: $(cat "$SANDBOX/.claude/settings.json")"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  install.sh exited non-zero with pre-existing false entry"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
