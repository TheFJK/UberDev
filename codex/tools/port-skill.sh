#!/usr/bin/env bash
# port-skill.sh — copy UberDev skills into the Codex plugin with path fixes.
#
# Skills are ~80% platform-agnostic instruction content (the open-skills
# SKILL.md format is identical between Claude Code and Codex). What changes
# is the plugin-root env var, the config dir, and the instructions filename.
# Tool-name bridging (Task → spawn_agent, etc.) is runtime, via the shipped
# references/codex-tools.md — NOT a static text substitution, because skills
# reference tool names in prose that a blind s/// would corrupt.
#
# This script applies ONLY the safe, context-free path substitutions:
#   ${CLAUDE_PLUGIN_ROOT} / $CLAUDE_PLUGIN_ROOT  → ${PLUGIN_ROOT}
#   ${PLUGIN_ROOT}/... / $PLUGIN_ROOT/...        → ${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/...
#   ~/.claude/CLAUDE.md                          → ~/.codex/AGENTS.md
#   ~/.claude/                                   → ~/.codex/
#   ~/.claude  (bare, word-boundary)             → ~/.codex
# It leaves CLAUDE.md mentions mostly intact (CLAUDE.md is a real filename the
# agent must sometimes read) — the AGENTS.md primer tells Codex to treat
# AGENTS.md > CLAUDE.md, so no destructive rewrite is needed here.
#
# Idempotent: re-running produces byte-identical output (rsync --delete +
# deterministic sed). Source tree is never modified.
#
# Usage:
#   port-skill.sh <src_skills_dir> <dst_skills_dir>
#     e.g. port-skill.sh plugins/uberdev/skills codex/uberdev-codex/skills
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <src_skills_dir> <dst_skills_dir>" >&2
  exit 1
fi

SRC="$1"
DST="$2"

if [ ! -d "$SRC" ]; then
  echo "error: source skills dir not found: $SRC" >&2
  exit 1
fi

echo "Porting skills: $SRC → $DST"

# rsync mirror: copies new/changed, deletes stale, preserves structure.
# --exclude __pycache__ / .pyc / .bak / .fix: build artefacts that shouldn't
# ship in the plugin. -a (archive) preserves the SKILL.md + scripts/ + refs.
mkdir -p "$DST"
rsync -a --delete \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '*.bak' \
  --exclude '*.bak2' \
  --exclude '*.fix' \
  --exclude '.DS_Store' \
  "$SRC"/ "$DST"/

PKG_ROOT="$(dirname "$DST")"
SHARED_DST="$PKG_ROOT/shared"
if [ -d "$DST/_shared" ]; then
  rm -rf "$SHARED_DST"
  mv "$DST/_shared" "$SHARED_DST"
fi

# Apply path substitutions to every regular file under $DST.
# find -print0 / read -d '' for safety with spaces/odd chars in skill names.
count=0
find_roots=("$DST")
[ -d "$SHARED_DST" ] && find_roots+=("$SHARED_DST")
while IFS= read -r -d '' f; do
  # in-place edit via a temp file so a mid-write crash can't half-rewrite a
  # SKILL.md. macOS sed needs -i ''. GNU sed needs -i. The temp-file path is
  # portable across both.
  tmp="$(mktemp)"
  # 1. CLAUDE_PLUGIN_ROOT → PLUGIN_ROOT  (bare-word, any context)
  #    Codex provides PLUGIN_ROOT to bundled hooks/scripts; semantically the
  #    same plugin-root concept as Claude's CLAUDE_PLUGIN_ROOT. Replacing the
  #    bare token catches every form it appears in: ${CLAUDE_PLUGIN_ROOT},
  #    $CLAUDE_PLUGIN_ROOT, ${CLAUDE_PLUGIN_ROOT:-fallback}, `CLAUDE_PLUGIN_ROOT`,
  #    and bare CLAUDE_PLUGIN_ROOT=foo env assignments. CURSOR_PLUGIN_ROOT and
  #    the COPILOT_CLI branches are left intact (they're sibling-platform
  #    fallbacks that harmlessly no-op on Codex).
  # 2. PLUGIN_ROOT path references get a standalone-install fallback. Bundled
  #    Codex plugins set PLUGIN_ROOT; the standalone installer copies the
  #    runtime to ${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex.
  # 3. ~/.claude/CLAUDE.md → ~/.codex/AGENTS.md (Codex global instructions)
  # 4. ~/.claude/ → ~/.codex/   (Codex config home)
  # 5. ~/.claude  → ~/.codex     (bare, word-boundary — catches "~/.claude" at EOL)
  sed \
    -e 's|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT|g' \
    -e 's|\${PLUGIN_ROOT:-\${PLUGIN_ROOT:-\${CURSOR_PLUGIN_ROOT:-}}}|${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}|g' \
    -e 's|\${PLUGIN_ROOT}/|${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/|g' \
    -e 's|\$PLUGIN_ROOT/|${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/|g' \
    -e 's|\${HOME}/\.claude/plugins|${CODEX_HOME:-$HOME/.codex}/plugins|g' \
    -e 's|\${HOME}/\.cursor/plugins|${HOME}/.agents/skills|g' \
    -e 's|\.\./_shared/|../../shared/|g' \
    -e 's|~/\.claude/CLAUDE\.md|~/.codex/AGENTS.md|g' \
    -e 's|~/\.claude/|~/.codex/|g' \
    -e 's|~/\.claude\([^/[:alnum:]_]\)|~/.codex\1|g' \
    -e 's|~/\.claude$|~/.codex|g' \
    "$f" > "$tmp"
  if ! cmp -s "$f" "$tmp"; then
    mv "$tmp" "$f"
    count=$((count + 1))
  else
    rm -f "$tmp"
  fi
done < <(find "${find_roots[@]}" -type f -print0)

python3 - "$DST" "$SHARED_DST" <<'PY'
import json
import sys
from pathlib import Path

roots = [Path(arg) for arg in sys.argv[1:] if Path(arg).exists()]

def strip_trailing_ws(text: str) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        if line.endswith("\r\n"):
            out.append(line[:-2].rstrip(" \t") + "\r\n")
        elif line.endswith("\n"):
            out.append(line[:-1].rstrip(" \t") + "\n")
        else:
            out.append(line.rstrip(" \t"))
    return "".join(out)

for root in roots:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        trimmed = strip_trailing_ws(text)
        if trimmed != text:
            path.write_text(trimmed, encoding="utf-8")

for root in roots:
  for skill_md in root.glob("*/SKILL.md"):
    text = skill_md.read_text(encoding="utf-8")
    changed = False

    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            fm = text[4:end]
            lines = []
            for line in fm.splitlines(keepends=True):
                newline = "\n" if line.endswith("\n") else ""
                body = line[:-1] if newline else line
                if body.startswith("description: "):
                    value = body[len("description: "):].strip()
                    if ": " in value and not value.startswith(("'", '"')):
                        body = "description: " + json.dumps(value, ensure_ascii=False)
                        changed = True
                lines.append(body + newline)
            if changed:
                text = "---\n" + "".join(lines) + text[end:]

    # The Claude/Cursor fallback searches plugin directory layouts that do not
    # exist in Codex. Keep the plugin-root fast path, but make fallback cover
    # both Codex plugin and standalone installer layouts.
    replacement_a = (
        'PLUGIN_SCRIPTS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}'
        '/skills/brainstorm/scripts"'
    )
    old_a = (
        'PLUGIN_SCRIPTS="${PLUGIN_ROOT:-${PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}'
        '/skills/brainstorm/scripts"'
    )
    if old_a in text:
        text = text.replace(old_a, replacement_a)
        changed = True

    old_b = (
        'PLUGIN_SCRIPTS="$(find "${CODEX_HOME:-$HOME/.codex}/plugins" '
        '"${HOME}/.agents/skills" -type d -path '
        "'*/uberdev/skills/brainstorm/scripts' 2>/dev/null | head -1)\""
    )
    new_b = (
        'PLUGIN_SCRIPTS="$(find '
        '"${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex/skills/brainstorm/scripts" '
        '"${HOME}/.agents/skills/brainstorm/scripts" -maxdepth 0 -type d '
        '2>/dev/null | head -1)"'
    )
    if old_b in text:
        text = text.replace(old_b, new_b)
        changed = True

    if changed:
        skill_md.write_text(text, encoding="utf-8")
PY

echo "Done: $(find "$DST" -name SKILL.md | wc -l | tr -d ' ') skills, $count files path-fixed."
