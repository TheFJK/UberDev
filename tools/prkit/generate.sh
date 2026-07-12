#!/usr/bin/env bash
# tools/prkit/generate.sh — generate the standalone prkit plugin from UberDev SSOT.
#   generate.sh --target <dir> [--version X.Y.Z] [--force]
# Stages: preflight -> clean -> copy -> rewrite -> scaffold -> codex -> verify -> summary.
# Idempotent: same SSOT + version => byte-identical output.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$REPO_ROOT/plugins/uberdev"
MANIFEST="$HERE/manifest.txt"
TEMPLATES="$HERE/templates"
. "$HERE/rewrite.sh"

TARGET=""; VERSION="0.1.0"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2;;
    --version) VERSION="${2:-}"; shift 2;;
    --force) FORCE=1; shift;;
    *) echo "generate: unknown arg '$1'" >&2; exit 2;;
  esac
done
[ -n "$TARGET" ] || { echo "generate: --target <dir> required" >&2; exit 2; }
# Guard mkdir/cd: an unchecked failure here would collapse TARGET to "" and make
# the later rm -rf "$P" / scaffold writes hit the filesystem root.
mkdir -p "$TARGET" || { echo "generate: cannot create target dir: $TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)" || { echo "generate: cannot resolve target dir: $TARGET" >&2; exit 1; }
[ -n "$TARGET" ] || { echo "generate: target resolved to empty path — refusing to write to filesystem root" >&2; exit 1; }

# Deterministic DATE input (no wall-clock in output beyond the version's date):
# use PRKIT_RELEASE_DATE if provided, else a fixed placeholder the release ritual
# overrides. The determinism test pins this.
DATE="${PRKIT_RELEASE_DATE:-2026-07-12}"

# --- 1. Preflight ---
[ -d "$SRC" ] || { echo "generate: SSOT missing: $SRC" >&2; exit 1; }
[ -r "$MANIFEST" ] || { echo "generate: manifest missing: $MANIFEST" >&2; exit 1; }
if [ -d "$TARGET/.git" ] && [ "$FORCE" -eq 0 ]; then
  if [ -n "$(git -C "$TARGET" status --porcelain 2>/dev/null)" ]; then
    echo "generate: target working tree is dirty (use --force to override)" >&2; exit 1
  fi
fi

P="$TARGET/plugins/prkit"

# --- 2. Clean previously generated plugin tree (leave the rest of the repo) ---
rm -rf "$P"
mkdir -p "$P"

# --- 3. Copy per manifest. A failed cp (e.g. a manifest source went missing in
# the SSOT) MUST abort — otherwise a broken tree ships and the "copied N" summary
# lies. copied is asserted to equal the manifest entry count. ---
copied=0; expected=0
while IFS= read -r rel; do
  rel="${rel%$'\r'}"   # strip CR (Windows Git-Bash autocrlf checkout)
  case "$rel" in ''|\#*) continue;; esac
  expected=$((expected+1))
  dst="$P/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$SRC/$rel" "$dst" || { echo "generate: copy failed (manifest source missing?): $rel" >&2; exit 1; }
  copied=$((copied+1))
done < "$MANIFEST"
[ "$copied" -eq "$expected" ] || { echo "generate: copied $copied of $expected manifest files" >&2; exit 1; }

# --- 4. Rewrite every copied file. The one JSON data file (model-routing-v1.json)
# has no uberdev token, so perl -0pi is a byte-preserving no-op on it; every copied
# file is text, so nothing is skipped. rw_rc surfaces a perl failure. ---
rw_rc=0
while IFS= read -r -d '' f; do
  prkit_neutralize "$f" || { echo "generate: neutralize failed: $f" >&2; rw_rc=1; }
  prkit_apply_rewrites "$f" || { echo "generate: rewrite failed: $f" >&2; rw_rc=1; }
done < <(find "$P" -type f -print0)
[ "$rw_rc" -eq 0 ] || { echo "generate: rewrite pass had failures" >&2; exit 1; }

# --- 5. Scaffold standalone-only files from templates ---
# render fails loudly: a missing template or a sed error must not silently ship a
# zero-byte scaffold (a bare `> out` redirect truncates out before sed runs, and
# the root-level scaffolds are outside verify's plugins/prkit + codex scan roots).
render(){
  local tmpl="$1" out="$2" tmp
  [ -r "$tmpl" ] || { echo "generate: template missing: $tmpl" >&2; exit 1; }
  tmp="$(mktemp)"
  { sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{DATE}}/$DATE/g" "$tmpl" > "$tmp" && [ -s "$tmp" ]; } \
    || { echo "generate: render produced empty/failed output: $tmpl" >&2; rm -f "$tmp"; exit 1; }
  mv "$tmp" "$out"
}
mkdir -p "$P/.claude-plugin" "$TARGET/.claude-plugin" "$TARGET/.github/workflows"
render "$TEMPLATES/plugin.json.tmpl"       "$P/.claude-plugin/plugin.json"
render "$TEMPLATES/marketplace.json.tmpl"  "$TARGET/.claude-plugin/marketplace.json"
render "$TEMPLATES/README.md.tmpl"         "$TARGET/README.md"
render "$TEMPLATES/LICENSE.tmpl"           "$TARGET/LICENSE"
render "$TEMPLATES/NOTICE.tmpl"            "$TARGET/NOTICE"
render "$TEMPLATES/CHANGELOG.md.tmpl"      "$TARGET/CHANGELOG.md"
render "$TEMPLATES/gitignore.tmpl"        "$TARGET/.gitignore"
render "$TEMPLATES/ci.yml.tmpl"           "$TARGET/.github/workflows/ci.yml"

# --- 5b. Codex port (present only when the codex/ SSOT + its manifest exist) ---
MANIFEST_CODEX="$HERE/manifest-codex.txt"
cx_copied=0; cx_scaffolded=0
if [ -r "$MANIFEST_CODEX" ] && [ -d "$REPO_ROOT/codex" ]; then
  # The prkit repo's entire codex/ tree is generated — clean it for an idempotent
  # regenerate (no stale files if the manifest shrinks).
  rm -rf "$TARGET/codex"
  # Copy each codex source to a dest path with uberdev->prkit applied
  # (codex/uberdev-codex -> codex/prkit-codex, uberdev-cmd- -> prkit-cmd-,
  #  codex/agents/uberdev-<a>.toml -> codex/agents/prkit-<a>.toml).
  cx_expected=0
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"   # strip CR (Windows Git-Bash autocrlf checkout)
    case "$rel" in ''|\#*) continue;; esac
    cx_expected=$((cx_expected+1))
    drel="$(printf '%s' "$rel" | sed 's/uberdev/prkit/g')"
    dst="$TARGET/$drel"
    mkdir -p "$(dirname "$dst")"
    cp "$REPO_ROOT/$rel" "$dst" || { echo "generate: codex copy failed (source missing?): $rel" >&2; exit 1; }
    cx_copied=$((cx_copied+1))
  done < "$MANIFEST_CODEX"
  [ "$cx_copied" -eq "$cx_expected" ] || { echo "generate: codex copied $cx_copied of $cx_expected files" >&2; exit 1; }
  # Rewrite content of every copied codex file (neutralize out-of-set, then blanket).
  while IFS= read -r -d '' f; do
    prkit_neutralize "$f" || { echo "generate: codex neutralize failed: $f" >&2; rw_rc=1; }
    prkit_apply_rewrites "$f" || { echo "generate: codex rewrite failed: $f" >&2; rw_rc=1; }
  done < <(find "$TARGET/codex" -type f -print0)
  [ "$rw_rc" -eq 0 ] || { echo "generate: codex rewrite pass had failures" >&2; exit 1; }
  # Scaffold codex-specific files from prkit-correct templates (authored, not
  # rewritten — so they don't inherit UberDev's stale counts). AFTER the rewrite
  # loop so they stay pristine.
  mkdir -p "$TARGET/codex/prkit-codex/.codex-plugin"
  render "$TEMPLATES/codex-plugin.json.tmpl" "$TARGET/codex/prkit-codex/.codex-plugin/plugin.json"
  render "$TEMPLATES/codex-README.md.tmpl"   "$TARGET/codex/README.md"
  render "$TEMPLATES/codex-AGENTS.md.tmpl"    "$TARGET/codex/AGENTS.md"
  cx_scaffolded=3
  # Restore exec bits on the entry scripts (cp preserves mode, but be explicit).
  [ -f "$TARGET/codex/install-codex.sh" ] && chmod +x "$TARGET/codex/install-codex.sh"
  [ -f "$TARGET/codex/prkit-codex/hooks/session-start" ] && chmod +x "$TARGET/codex/prkit-codex/hooks/session-start"
fi

# --- 6. Verify (fail the whole run on any violation; covers both trees) ---
if ! bash "$HERE/verify.sh" "$TARGET"; then
  echo "generate: VERIFY FAILED — output left in $TARGET for inspection" >&2
  exit 1
fi

# --- 7. Summary ---
echo "generate: OK — copied $copied claude + $cx_copied codex files, scaffolded $((8 + cx_scaffolded)), verified."
echo "generate: next -> git -C '$TARGET' add -A && git -C '$TARGET' commit -m 'chore: regenerate prkit $VERSION'"
