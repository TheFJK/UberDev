---
description: "Remove short-form aliases (/issue, /solve, /turbo, /turbox, /fix, /simplify, /review-pr, /merge, /premerge, /dev, /testers, /ubergoal, /uberscan, /ubersimplify, /uberthink, /ubercluster) installed by /uberdev:install-aliases"
argument-hint: "[--dry-run]"
allowed-tools: ["Bash"]
---

# Uninstall short-form aliases

User flags: `$ARGUMENTS` (`--dry-run` to preview without removing)

Removes the user-level forwarder files written by `/uberdev:install-aliases`
AND the auto-install version-marker (`~/.claude/.uberdev-aliases-version`).
Marker-scoped: only files carrying `managed-by: uberdev-aliases` are
removed, so a hand-authored `~/.claude/commands/issue.md` (or any other
short name) is preserved untouched. Removing the version-marker ensures
the next session-start hook will treat the system as freshly installed.

## Run

```bash
set -e

DRY_RUN=0
[[ " $ARGUMENTS " == *" --dry-run "* ]] && DRY_RUN=1

DEST_DIR="$HOME/.claude/commands"
# NEWLINE-delimited, and read through a here-doc rather than walked with
# `for SHORT in $SHORTS`. This fence runs under the Bash tool's /bin/zsh, where
# an unquoted scalar does NOT word-split: the `for` form iterates exactly once
# over the whole string, every `[ -e "$DEST_DIR/${SHORT}.md" ]` misses, and the
# command reports "not installed" for all of them while removing nothing. Same
# shape as the `done <<< "$ALIASES"` reader in lib/aliases-sync.sh.
SHORTS='issue
solve
turbo
turbox
fix
simplify
review-pr
merge
premerge
dev
testers
ubergoal
uberscan
ubersimplify
uberthink
ubercluster'

REMOVED=0
KEPT=0

echo "Removing uberdev-managed short-form aliases…"
echo "  scan:  $DEST_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode:  dry-run (no files removed)"
echo

while IFS= read -r SHORT; do
  [ -n "$SHORT" ] || continue
  TARGET="$DEST_DIR/${SHORT}.md"

  if [ ! -e "$TARGET" ]; then
    echo "  ----  /$SHORT — not installed"
    continue
  fi

  # Marker check is the safety contract. Without it, this command could
  # delete a user's hand-authored alias file that just happens to share
  # one of the short names. grep -q is the smallest possible check that
  # answers "did install-aliases write this?".
  if ! grep -q 'managed-by: uberdev-aliases' "$TARGET" 2>/dev/null; then
    echo "  KEEP  /$SHORT — $TARGET exists but is not managed by uberdev"
    KEPT=$((KEPT + 1))
    continue
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "  PLAN  /$SHORT — would remove $TARGET"
    continue
  fi

  rm -f "$TARGET"
  echo "  GONE  /$SHORT — removed"
  REMOVED=$((REMOVED + 1))
done <<EOF
$SHORTS
EOF

echo
echo "Summary: $REMOVED removed, $KEPT kept"
[ "$DRY_RUN" = "1" ] && echo "(dry-run — nothing actually removed)"

# Remove version-marker file (issue #21).
# Without this, the next session-start hook's idempotency check would
# see installed_version == plugin_version and skip the install — making
# the uninstall silently incomplete.
MARKER="$HOME/.claude/.uberdev-aliases-version"
if [ -f "$MARKER" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "  PLAN  version-marker — would remove $MARKER"
  else
    if rm -f "$MARKER" 2>/dev/null && [ ! -e "$MARKER" ]; then
      echo "  GONE  version-marker — removed $MARKER"
    else
      echo "  FAIL  version-marker — could not remove $MARKER (check permissions)" >&2
    fi
  fi
fi

echo
echo "Reinstall with: /uberdev:install-aliases"
```

After running, briefly relay the per-alias outcome to the user.
