---
description: "Install short-form aliases (/issue, /solve, /turbo, /simplify, /review-pr) as one-way forwarders to /uberdev:<command>"
argument-hint: "[--force] [--dry-run]"
allowed-tools: ["Bash", "Read"]
---

# Install short-form aliases

User flags: `$ARGUMENTS` (`--force` to refresh existing managed forwarders, `--dry-run` to preview without writing)

Plugin commands are addressed as `/uberdev:<command>` because Claude Code's
plugin manifest enforces the `<plugin-name>:` prefix. The manifest has no
field for top-level aliases, so the only mechanism is shipping forwarder
files into the user's standalone `~/.claude/commands/` directory (where
filename = command name, no plugin prefix). See issue #16.

This command writes five such forwarders. Each is **one-way** — it points
at the canonical `/uberdev:<command>` rather than duplicating its body.
Existing `/uberdev:<command>` invocations are unaffected; this is purely
additive ergonomics.

## What gets installed

| Short form | Canonical |
|---|---|
| `/issue`     | `/uberdev:issue` |
| `/solve`     | `/uberdev:solve` |
| `/turbo`     | `/uberdev:turbo` |
| `/simplify`  | `/uberdev:simplify` |
| `/review-pr` | `/uberdev:review-pr` |

Note `/review-pr` rather than `/review`: `/review` is a built-in
Claude Code command, and the issue's collision rule is "plugin namespacing
always wins over short alias" — but built-ins ship with Claude Code itself,
so we sidestep the collision by using a slightly different short name.

## Run

```bash
set -e

FORCE=0
DRY_RUN=0
[[ " $ARGUMENTS " == *" --force "* ]] && FORCE=1
[[ " $ARGUMENTS " == *" --dry-run "* ]] && DRY_RUN=1

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT/commands" ]; then
  echo "❌ CLAUDE_PLUGIN_ROOT not set or invalid; cannot resolve canonical commands." >&2
  echo "   This command must be run from within Claude Code with the uberdev plugin enabled." >&2
  exit 1
fi

DEST_DIR="$HOME/.claude/commands"
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$DEST_DIR" || {
    echo "❌ Failed to create $DEST_DIR (permissions? disk full?)" >&2
    exit 1
  }
fi

# Per-alias config: short-name|canonical-name|JSON-array-of-allowed-tools.
#
# allowed-tools is HARDCODED here, not auto-extracted from each canonical's
# frontmatter. It must be kept byte-identical to the canonical's
# `allowed-tools` line so the forwarder grants the same tool surface — no
# more, no less. If a canonical is updated to need a new tool, this table
# must be updated to match.
#
# `tests/aliases.test.sh` section A6 enforces this drift-detection contract:
# the suite reads each canonical's `allowed-tools` line and asserts the
# matching ALIASES row contains the same value. So forgetting to update
# this list will fail CI rather than silently shipping under-privileged
# forwarders.
ALIASES='issue|issue|["Bash", "Glob", "Grep", "Read", "Task"]
solve|solve|["Bash", "Read", "Task"]
turbo|turbo|["Bash", "Read", "Task"]
simplify|simplify|["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
review-pr|review-pr|["Bash(git*)", "Bash(gh*)", "Glob", "Grep", "Read", "Task"]'

# Built-in Claude Code commands; never overwrite these even with --force.
# /review is the load-bearing entry here (we already use /review-pr to dodge
# it, but if someone adds another canonical short-named like a built-in, the
# guard catches it).
BUILTINS='init review security-review statusline-setup help clear plugin'

echo "Installing uberdev short-form aliases…"
echo "  source: $PLUGIN_ROOT/commands"
echo "  dest:   $DEST_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode:   dry-run (no files written)"
[ "$FORCE" = "1" ] && echo "  mode:   --force (refresh managed forwarders)"
echo

INSTALLED=0
SKIPPED=0

while IFS='|' read -r SHORT CANON TOOLS; do
  TARGET="$DEST_DIR/${SHORT}.md"
  CANON_FILE="$PLUGIN_ROOT/commands/${CANON}.md"

  if [ ! -f "$CANON_FILE" ]; then
    echo "  SKIP  /$SHORT — canonical not found at $CANON_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Built-in collision — refuse even with --force, since clobbering a
  # built-in would brick the user's environment.
  if [[ " $BUILTINS " == *" $SHORT "* ]]; then
    echo "  SKIP  /$SHORT — collides with a Claude Code built-in; use /uberdev:$CANON"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Collision check: a single grep against TARGET answers both "does it
  # exist?" and "is it ours?" — grep with 2>/dev/null returns non-zero
  # silently if the file is missing, so we don't need a separate -e stat.
  if grep -q 'managed-by: uberdev-aliases' "$TARGET" 2>/dev/null; then
    if [ "$FORCE" != "1" ]; then
      echo "  KEEP  /$SHORT — already installed (use --force to refresh)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    echo "  REPL  /$SHORT — refreshing existing managed forwarder"
  elif [ -e "$TARGET" ]; then
    echo "  SKIP  /$SHORT — $TARGET exists and is not managed by uberdev (won't overwrite)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "  PLAN  /$SHORT → /uberdev:$CANON  (would write $TARGET)"
    continue
  fi

  # Write the forwarder. Heredoc is unquoted so $SHORT/$CANON/$TOOLS/
  # $PLUGIN_ROOT/$CANON_FILE expand HERE — those values are baked into
  # the forwarder once at install time. $ARGUMENTS and ${CLAUDE_PLUGIN_ROOT}
  # are escaped with a leading backslash so they remain LITERAL in the
  # written file; Claude Code's harness substitutes them later, when the
  # user actually invokes the alias (so each invocation gets the user's
  # then-current args, not the empty $ARGUMENTS at install time).
  cat > "$TARGET" <<EOF
---
description: "Alias for /uberdev:$CANON"
argument-hint: "<args>  # forwarded to /uberdev:$CANON"
allowed-tools: $TOOLS
---

<!-- managed-by: uberdev-aliases -->
<!-- Generated by /uberdev:install-aliases. Remove via /uberdev:uninstall-aliases. -->
<!-- Do not edit by hand — re-run /uberdev:install-aliases --force to regenerate. -->

# /$SHORT — alias for /uberdev:$CANON

This is a top-level shorthand for the canonical \`/uberdev:$CANON\`.
Treat this invocation exactly as if the user had typed
\`/uberdev:$CANON \$ARGUMENTS\`. There is no logic here — the canonical
command file lives in the uberdev plugin install.

- **canonical command**: \`$CANON_FILE\`
- **\${CLAUDE_PLUGIN_ROOT}** (resolved at install time): \`$PLUGIN_ROOT\`
- **user arguments**: \`\$ARGUMENTS\`

**Action:** Read the canonical command file with the \`Read\` tool, then
follow its instructions exactly. Wherever the canonical references
\`\${CLAUDE_PLUGIN_ROOT}\`, substitute the resolved path above. Pass
\`\$ARGUMENTS\` through unchanged.

If the canonical path is stale (e.g. you reinstalled the plugin to a
different location), re-run \`/uberdev:install-aliases --force\` to
regenerate this file.
EOF
  echo "  OK    /$SHORT → /uberdev:$CANON"
  INSTALLED=$((INSTALLED + 1))
done <<< "$ALIASES"

echo
echo "Summary: $INSTALLED installed, $SKIPPED skipped"
[ "$DRY_RUN" = "1" ] && echo "(dry-run — no files actually written)"
echo
echo "Test with:  /issue some test description"
echo "Remove with: /uberdev:uninstall-aliases"
```

After running the script, briefly relay the per-alias outcome to the user.
