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

## Implementation note

The ALIASES table and forwarder template are defined in
`plugins/uberdev/lib/aliases-sync.sh` (the single source of truth, also
used by `hooks/session-start` for auto-install). `tests/aliases.test.sh`
section A6 enforces drift between the helper's ALIASES rows and each
canonical command's `allowed-tools` frontmatter.

## Run

```bash
set -e

FORCE=0
DRY_RUN=0
[[ " $ARGUMENTS " == *" --force "* ]] && FORCE=1
[[ " $ARGUMENTS " == *" --dry-run "* ]] && DRY_RUN=1

# Plugin-root resolution: same fallback chain as lib/aliases-sync.sh
# (PLUGIN_ROOT > CLAUDE_PLUGIN_ROOT > CURSOR_PLUGIN_ROOT) so this command
# works in Cursor environments too — not just Claude Code.
PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT/commands" ]; then
  echo "❌ Plugin root not set or invalid (checked PLUGIN_ROOT, CLAUDE_PLUGIN_ROOT, CURSOR_PLUGIN_ROOT); cannot resolve canonical commands." >&2
  echo "   This command must be run from within Claude Code or Cursor with the uberdev plugin enabled." >&2
  exit 1
fi

# Source the shared helper (single source of truth for ALIASES + write logic).
# shellcheck source=lib/aliases-sync.sh
. "$PLUGIN_ROOT/lib/aliases-sync.sh"

DEST_DIR="$HOME/.claude/commands"
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$DEST_DIR" || {
    echo "❌ Failed to create $DEST_DIR (permissions? disk full?)" >&2
    exit 1
  }
fi

echo "Installing uberdev short-form aliases…"
echo "  source: $PLUGIN_ROOT/commands"
echo "  dest:   $DEST_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode:   dry-run (no files written)"
[ "$FORCE" = "1" ] && echo "  mode:   --force (refresh managed forwarders)"
echo

INSTALLED=0
SKIPPED=0

while IFS='|' read -r SHORT CANON TOOLS; do
  [ -n "$SHORT" ] || continue
  TARGET="$DEST_DIR/${SHORT}.md"
  CANON_FILE="$PLUGIN_ROOT/commands/${CANON}.md"

  if [ ! -f "$CANON_FILE" ]; then
    echo "  SKIP  /$SHORT — canonical not found at $CANON_FILE"
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  case " $BUILTINS " in
    *" $SHORT "*)
      echo "  SKIP  /$SHORT — collides with a Claude Code built-in; use /uberdev:$CANON"
      SKIPPED=$((SKIPPED + 1)); continue ;;
  esac

  # Collision check via the shared marker test.
  if _aliases_check_marker "$TARGET"; then
    if [ "$FORCE" != "1" ]; then
      echo "  KEEP  /$SHORT — already installed (use --force to refresh)"
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    echo "  REPL  /$SHORT — refreshing existing managed forwarder"
  elif [ -e "$TARGET" ]; then
    echo "  SKIP  /$SHORT — $TARGET exists and is not managed by uberdev (won't overwrite)"
    SKIPPED=$((SKIPPED + 1)); continue
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "  PLAN  /$SHORT → /uberdev:$CANON  (would write $TARGET)"
    continue
  fi

  if _aliases_write_forwarder "$SHORT" "$CANON" "$TOOLS" "$PLUGIN_ROOT" "$TARGET"; then
    echo "  OK    /$SHORT → /uberdev:$CANON"
    INSTALLED=$((INSTALLED + 1))
  else
    echo "  FAIL  /$SHORT → write failed"
    SKIPPED=$((SKIPPED + 1))
  fi
done <<< "$ALIASES"

echo
echo "Summary: $INSTALLED installed, $SKIPPED skipped"
[ "$DRY_RUN" = "1" ] && echo "(dry-run — no files actually written)"
echo
echo "Test with:  /issue some test description"
echo "Remove with: /uberdev:uninstall-aliases"
```

After running the script, briefly relay the per-alias outcome to the user.
