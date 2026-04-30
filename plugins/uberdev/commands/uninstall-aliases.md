---
description: "Remove short-form aliases (/issue, /solve, /turbo, /simplify, /review-pr) installed by /uberdev:install-aliases"
argument-hint: "[--dry-run]"
allowed-tools: ["Bash"]
---

# Uninstall short-form aliases

User flags: `$ARGUMENTS` (`--dry-run` to preview without removing)

Removes the user-level forwarder files written by `/uberdev:install-aliases`.
Marker-scoped: only files carrying `managed-by: uberdev-aliases` are
removed, so a hand-authored `~/.claude/commands/issue.md` (or any other
short name) is preserved untouched.

## Run

```bash
set -e

DRY_RUN=0
[[ " $ARGUMENTS " == *" --dry-run "* ]] && DRY_RUN=1

DEST_DIR="$HOME/.claude/commands"
SHORTS='issue solve turbo simplify review-pr'

REMOVED=0
KEPT=0

echo "Removing uberdev-managed short-form aliases…"
echo "  scan:  $DEST_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode:  dry-run (no files removed)"
echo

for SHORT in $SHORTS; do
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
done

echo
echo "Summary: $REMOVED removed, $KEPT kept"
[ "$DRY_RUN" = "1" ] && echo "(dry-run — nothing actually removed)"
echo
echo "Reinstall with: /uberdev:install-aliases"
```

After running, briefly relay the per-alias outcome to the user.
