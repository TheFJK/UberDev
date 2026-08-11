#!/usr/bin/env bash
# Tests for issue #22 — install.sh bootstrap script enables the plugin in
# ~/.claude/settings.json (working around Claude Code's enabledPlugins bug,
# refs anthropics/claude-code#14815 — open; #20661, the reference this file
# used to cite, was closed 2026-01-29 as a duplicate).
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
#   I7a–I7d — the upstream citation is live, dated, and dead refs are tombstoned
#   I8 — script does not contain destructive shapes (rm -rf $HOME, etc.)
#   I9 — re-run flips a manually-disabled (false) entry back to true
#   I10 — claude --print calls are wall-clock bounded
#   I11 — README documents a plain (non-curl|bash) install door, uncollapsed
#   I12 — install.sh's settings.json writes are fenced by auditable markers
#   I13 — README states what the script does to ~/.claude/settings.json

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

# Fixed-string variant. Needed for assertions whose needle is a shell command
# containing regex metacharacters (`/`, `.`, `*`) that must match literally —
# escaping those into an ERE by hand is how a pin silently stops matching.
assert_grep_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:   $file"
    echo "        needle: $needle"
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
  '{"theme":"dark","model":"claude-opus-4-8","permissions":{"allow":["Bash"]}}'
if run_install "$SANDBOX"; then
  if jq -e '
      .theme == "dark"
      and .model == "claude-opus-4-8"
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
echo "== I7: the upstream citation is live, dated, and dead refs are tombstoned =="
# The install path asks the reader to pipe a remote script into bash on the
# strength of one claim: "upstream is broken, here is the issue". #435 found
# that claim rotted — the cited anthropics/claude-code#20661 was closed
# 2026-01-29 as a duplicate, the canonical it folded into (#17832) was closed
# 2026-03-30 not_planned, and the still-open bug is #14815. A reader who
# followed our citation landed on a closed issue and could reasonably conclude
# the script was obsolete.
#
# The old assertion here was `enabledPlugins|claude-code/issues/20661`. That
# alternation is satisfied by three unrelated README lines (the one-liner
# comment, the manual jq snippet, the FAQ block), so it stayed green for the
# entire time the citation was wrong — it never tested the citation at all.
#
# The replacement is tiered like docs-accuracy.test.sh T10: name the live
# issue, require a same-line tombstone on every dead one, date the re-check,
# and guard the whole thing against vacuity.
assert_grep "$README" \
  'install\.sh|curl[[:space:]]+-fsSL.*UberDev' \
  "I7.0 README references install.sh or curl|bash install path"

# I7a — the LIVE upstream issue is named in BOTH copies of the claim.
assert_grep "$README" '14815' \
  "I7a README names the still-open upstream issue (#14815)"
assert_grep "$INSTALL_SH" '14815' \
  "I7a install.sh names the still-open upstream issue (#14815)"

# I7b — every DEAD issue number carries a same-line tombstone.
# Tiering and ordering copied from docs-accuracy.test.sh T10 (#381):
#   1. struck through (~~) -> retracted BY CONSTRUCTION, excused whatever it says;
#   2. otherwise a NEGATION ("still open", "not closed") -> ALWAYS a hit, even
#      alongside a tombstone word, because that is the shape where the
#      falsifying word is also the certifying word;
#   3. otherwise an ordinary tombstone word excuses the line.
# A number that appears zero times contributes zero lines and is not an error —
# this pins the numbers we DO cite, it does not mandate citing all of them.
DEAD_MARKER='closed|duplicate|not.?planned|superseded|dead|~~'
DEAD_NEGATION='not (closed|a duplicate|dead)|still open|reopened|remains open'
citation_hits=""
for citation_file in "$README" "$INSTALL_SH"; do
  for dead_num in 20661 17832 15524 13509; do
    while IFS= read -r citation_line; do
      [ -n "$citation_line" ] || continue
      # Herestring, not a pipe: this file sets pipefail and `grep -q` exits on
      # its first match, so a piped writer would take EPIPE
      # (tests/epipe-guard.test.sh).
      grep -qE -e '~~' <<<"$citation_line" && continue
      if ! grep -qE -e "$DEAD_NEGATION" <<<"$citation_line"; then
        grep -qE -e "$DEAD_MARKER" <<<"$citation_line" && continue
      fi
      citation_hits="${citation_hits}${citation_file}: ${citation_line}
"
    done <<EOF
$(grep -n -e "$dead_num" "$citation_file" 2>/dev/null || true)
EOF
  done
done
if [ -z "$citation_hits" ]; then
  echo "  PASS  I7b every dead upstream issue number carries a same-line tombstone"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I7b a closed upstream issue is cited with nothing marking it dead"
  printf '%s' "$citation_hits" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

# I7c — the re-check date is present, so the next reader can see how stale the
# upstream survey is. Shape, not a literal: this must not need a bump per release.
assert_grep "$README" '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' \
  "I7c README dates the upstream re-check"
assert_grep "$INSTALL_SH" '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' \
  "I7c install.sh dates the upstream re-check"

# I7d — anti-vacuity, per file. Without this, deleting the bug note outright
# would pass I7b with zero lines scanned (T9.0/T10.2 shape).
for citation_file in "$README" "$INSTALL_SH"; do
  dead_count="$(grep -cE -e '20661|17832|15524|13509' "$citation_file" || true)"
  live_count="$(grep -c -e '14815' "$citation_file" || true)"
  if [ "${dead_count:-0}" -ge 1 ] && [ "${live_count:-0}" -ge 1 ]; then
    echo "  PASS  I7d $citation_file still carries both a dead and a live upstream ref"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  I7d $citation_file has no upstream refs left — I7b may be vacuous"
    echo "        dead-number lines: ${dead_count:-0}; live-number lines: ${live_count:-0}"
    FAIL=$((FAIL + 1))
  fi
done

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
echo "== I10: claude --print calls are wall-clock bounded (RFC 0012 §3.13) =="
# `claude --print` can hang indefinitely (auth prompt, network stall) and
# would wedge the curl|bash one-liner before the jq-patch runs. Both
# invocations must go through the run_bounded wrapper, which probes
# timeout(1) then gtimeout (Homebrew coreutils on macOS) at 30s and
# fails-open when neither exists.
assert_grep "$INSTALL_SH" '^run_bounded\(\)' \
  "I10.1 run_bounded wrapper is defined"
assert_grep "$INSTALL_SH" 'timeout 30 "\$@"' \
  "I10.2 wrapper bounds at 30s via timeout(1)"
assert_grep "$INSTALL_SH" 'gtimeout 30 "\$@"' \
  "I10.3 wrapper falls back to gtimeout (macOS Homebrew coreutils)"
UNBOUNDED_CLAUDE="$(grep -nE '^[[:space:]]*claude --print' "$INSTALL_SH" || true)"
if [ -z "$UNBOUNDED_CLAUDE" ]; then
  echo "  PASS  I10.4 no unbounded claude --print invocation remains"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I10.4 unbounded claude --print invocation(s) found:"
  echo "$UNBOUNDED_CLAUDE" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi
BOUNDED_CLAUDE_COUNT="$(grep -cE '^[[:space:]]*run_bounded claude --print' "$INSTALL_SH" || true)"
if [ "$BOUNDED_CLAUDE_COUNT" -eq 2 ] 2>/dev/null; then
  echo "  PASS  I10.5 both claude --print invocations route through run_bounded"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I10.5 expected 2 run_bounded claude --print invocations, found ${BOUNDED_CLAUDE_COUNT}"
  FAIL=$((FAIL + 1))
fi

echo
echo "== I11: README offers a plain install door, not collapsed behind <details> =="
# `curl … | bash` is a hard sell to anyone who is not the author. It may be the
# convenient door; it must not be the only one a reader can find. The manual
# `/plugin marketplace add` flow was present but folded inside a <details>
# element, which reads as an afterthought and is invisible to anyone skimming.
#
# The slice is the `## Install` section only — asserting against the whole
# README would pass on a mention anywhere in a 400-line file.
INSTALL_SLICE="$(awk '/^## Install/{f=1;next} f && /^## /{exit} f' "$README")"
INSTALL_SLICE_LINES="$(printf '%s\n' "$INSTALL_SLICE" | grep -c '[^[:space:]]' || true)"

# Slice assertions share one helper so a renamed heading fails in ONE place
# (I11.1) instead of producing a confusing wall of "pattern not found".
assert_slice_grep() {
  local pattern="$1" desc="$2"
  # Herestring, not a pipe: pipefail + an early-exiting `grep -q` reader
  # (tests/epipe-guard.test.sh).
  if grep -qE -e "$pattern" <<<"$INSTALL_SLICE"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        section: README.md ## Install"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# I11.1 — the slice itself must be real. `## Install` is anchored by
# CONTRIBUTING.md's README.md#install link; if it is ever renamed the slice
# goes empty and every assertion below would pass vacuously on nothing.
if [ "${INSTALL_SLICE_LINES:-0}" -ge 20 ]; then
  echo "  PASS  I11.1 the ## Install slice is non-empty (${INSTALL_SLICE_LINES} non-blank lines)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I11.1 the ## Install slice has only ${INSTALL_SLICE_LINES:-0} non-blank lines — heading renamed? I11/I13 would be vacuous"
  FAIL=$((FAIL + 1))
fi

# I11.2 — the manual flow must be readable without expanding anything.
PLAIN_DOOR_AT_TOP_LEVEL="$(awk '
  /<details/                  { depth++ }
  /\/plugin marketplace add/  { if (depth == 0) print NR": "$0 }
  /<\/details>/               { if (depth > 0) depth-- }
' <<<"$INSTALL_SLICE")"
if [ -n "$PLAIN_DOOR_AT_TOP_LEVEL" ]; then
  echo "  PASS  I11.2 the plain '/plugin marketplace add' flow is outside any <details>"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I11.2 '/plugin marketplace add' is missing from ## Install, or only appears collapsed inside <details>"
  FAIL=$((FAIL + 1))
fi

# I11.3 — an honest statement of what breaks without the enabledPlugins patch.
# Nothing errors: the plugin installs into the cache and the commands simply do
# not load. A reader who skips the patch must be told that, or the manual door
# is a trap.
assert_slice_grep '404|do not load|silently' \
  "I11.3 ## Install states the silent-404 failure mode of skipping the patch"

echo
echo "== I12: settings.json writes are fenced by an auditable marker pair =="
# `curl -fsSL … | bash` asks a reader to run a remote script sight-unseen. The
# honest mitigation is not "trust us", it is "here is the only region that
# touches your settings file, audit that". These markers make that region
# addressable by one sed command (quoted verbatim in the README, I12.5), and
# the ratchet in I12.6 is what stops a future edit from writing settings.json
# outside the fence and quietly falsifying the README's promise.
#
# The markers are matched ANCHORED at column 0 so the strings can be quoted in
# prose (here, in the README, in a future doc) without changing the counts —
# and, critically, so the README's sed range still terminates on the real END
# marker rather than on a comment that merely names it.
BEGIN_MARKER_COUNT="$(grep -c -e '^# BEGIN settings-mutation' "$INSTALL_SH" || true)"
END_MARKER_COUNT="$(grep -c -e '^# END settings-mutation' "$INSTALL_SH" || true)"
if [ "${BEGIN_MARKER_COUNT:-0}" -eq 1 ]; then
  echo "  PASS  I12.1 install.sh opens the settings-mutation region exactly once"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I12.1 expected exactly 1 '# BEGIN settings-mutation' line, found ${BEGIN_MARKER_COUNT:-0}"
  FAIL=$((FAIL + 1))
fi
if [ "${END_MARKER_COUNT:-0}" -eq 1 ]; then
  echo "  PASS  I12.2 install.sh closes the settings-mutation region exactly once"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I12.2 expected exactly 1 '# END settings-mutation' line, found ${END_MARKER_COUNT:-0}"
  FAIL=$((FAIL + 1))
fi

# `grep -n | cut` is a pipe to a full-consumer, not to an early-exit reader —
# safe under pipefail (unlike `| head` or `| grep -q`).
BEGIN_MARKER_LINE="$(grep -n -e '^# BEGIN settings-mutation' "$INSTALL_SH" | cut -d: -f1 || true)"
END_MARKER_LINE="$(grep -n -e '^# END settings-mutation' "$INSTALL_SH" | cut -d: -f1 || true)"
if [ -n "$BEGIN_MARKER_LINE" ] && [ -n "$END_MARKER_LINE" ] \
   && [ "$BEGIN_MARKER_LINE" -lt "$END_MARKER_LINE" ]; then
  echo "  PASS  I12.3 the region opens before it closes (${BEGIN_MARKER_LINE} < ${END_MARKER_LINE})"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I12.3 marker order is wrong or a marker is missing (begin='${BEGIN_MARKER_LINE}' end='${END_MARKER_LINE}')"
  FAIL=$((FAIL + 1))
fi

# Non-vacuity: a marker pair wrapped around nothing would satisfy I12.1–I12.3
# while making the README's audit command print an empty region.
SETTINGS_REGION="$(awk '
  /^# BEGIN settings-mutation/ { inside = 1 }
  inside                       { print }
  /^# END settings-mutation/   { if (inside) exit }
' "$INSTALL_SH")"
REGION_LINES=0
if [ -n "$BEGIN_MARKER_LINE" ] && [ -n "$END_MARKER_LINE" ]; then
  REGION_LINES=$((END_MARKER_LINE - BEGIN_MARKER_LINE))
fi
if [ "$REGION_LINES" -ge 20 ] \
   && grep -qF -e 'jq --arg key' <<<"$SETTINGS_REGION" \
   && grep -qF -e 'mv "${TMP}" "${SETTINGS}"' <<<"$SETTINGS_REGION"; then
  echo "  PASS  I12.4 the fenced region really contains the jq patch and the atomic rename"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I12.4 the fenced region is empty, too small (${REGION_LINES} lines), or missing the jq patch / mv"
  FAIL=$((FAIL + 1))
fi

# Correspondence, both halves. The README must quote the audit command
# verbatim (this assertion), and the marker strings that command names must
# resolve in install.sh (I12.1/I12.2 above). Deleting either half breaks the
# promise; deleting one and keeping the other is exactly the silent-rot shape
# this pin exists to catch, so do not remove one without the other.
assert_grep_fixed "$README" \
  "sed -n '/# BEGIN settings-mutation/,/# END settings-mutation/p' install.sh" \
  "I12.5 README quotes the region-audit command verbatim"

# I12.6 — forward ratchet. Any write targeting $SETTINGS from OUTSIDE the
# fenced region is a hit: it would be a settings mutation the README's audit
# command never prints. Bracket expressions ([$] [{] [}]) rather than
# backslash escapes keep the ERE portable across gawk/mawk/BSD awk.
OUTSIDE_SETTINGS_WRITES="$(awk '
  /^# BEGIN settings-mutation/ { inside = 1 }
  !inside && /(>[[:space:]]*"?[$][{]?SETTINGS[}]?"?|mv[[:space:]].*"[$][{]?SETTINGS[}]?")/ { print NR": "$0 }
  /^# END settings-mutation/   { inside = 0 }
' "$INSTALL_SH")"
if [ -z "$OUTSIDE_SETTINGS_WRITES" ]; then
  echo "  PASS  I12.6 no write to settings.json escapes the fenced region"
  PASS=$((PASS + 1))
else
  echo "  FAIL  I12.6 settings.json is written outside the audited region:"
  printf '%s\n' "$OUTSIDE_SETTINGS_WRITES" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

echo
echo "== I13: README states what the script does to ~/.claude/settings.json =="
# The marker pair (I12) makes the dangerous region addressable; this makes its
# EFFECT legible without reading any shell at all. Every clause below is a
# behaviour I2–I6/I9 already test but nothing documented — an installer whose
# guarantees exist only in its test suite is asking for unearned trust.
assert_slice_grep 'enabledPlugins' \
  "I13.1 ## Install names the key the script writes"
assert_slice_grep 'idempotent|byte-identical|no-op' \
  "I13.2 ## Install states the re-run is a no-op (I5)"
assert_slice_grep 'preserve' \
  "I13.3 ## Install states unrelated keys / sibling entries survive (I3, I4)"
assert_slice_grep 'malformed|invalid JSON' \
  "I13.4 ## Install states a malformed settings.json is refused, not rewritten (I6)"
# Same-line, both halves: a bare `false` also matches the unrelated
# `auto_install_aliases: false` opt-out line a few paragraphs up, which would
# make this pin pass while documenting nothing.
assert_slice_grep 'false.*flipped back|flipped back.*false' \
  "I13.5 ## Install states a manually-disabled (false) entry is flipped back (I9)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
