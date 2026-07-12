#!/usr/bin/env bash
# tools/prkit/generate.sh — generate the standalone prkit plugin from UberDev SSOT.
#   generate.sh --target <dir> [--version X.Y.Z] [--force]
# Stages: preflight -> clean -> copy -> rewrite -> scaffold -> verify -> summary.
# Idempotent: same SSOT + version => byte-identical plugins/prkit output.
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
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

# Deterministic DATE input (no wall-clock in output beyond the version's date):
# use the version-tag date if provided via env, else a fixed placeholder the
# release ritual overrides. Determinism test pins this.
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

# --- 3. Copy per manifest ---
copied=0
while IFS= read -r rel; do
  case "$rel" in ''|\#*) continue;; esac
  dst="$P/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$SRC/$rel" "$dst"
  copied=$((copied+1))
done < "$MANIFEST"

# --- 4. Rewrite every copied text file (skip binary/json-data safely) ---
while IFS= read -r -d '' f; do
  case "$f" in
    *model-routing-v1.json) : ;;   # data file: has no uberdev token; still safe to run
  esac
  prkit_neutralize "$f"
  prkit_apply_rewrites "$f"
done < <(find "$P" -type f -print0)

# --- 5. Scaffold standalone-only files from templates ---
render(){ sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{DATE}}/$DATE/g" "$1"; }
mkdir -p "$P/.claude-plugin" "$TARGET/.claude-plugin" "$TARGET/.github/workflows"
render "$TEMPLATES/plugin.json.tmpl"       > "$P/.claude-plugin/plugin.json"
render "$TEMPLATES/marketplace.json.tmpl"  > "$TARGET/.claude-plugin/marketplace.json"
render "$TEMPLATES/README.md.tmpl"         > "$TARGET/README.md"
render "$TEMPLATES/LICENSE.tmpl"           > "$TARGET/LICENSE"
render "$TEMPLATES/NOTICE.tmpl"            > "$TARGET/NOTICE"
render "$TEMPLATES/CHANGELOG.md.tmpl"      > "$TARGET/CHANGELOG.md"
render "$TEMPLATES/gitignore.tmpl"        > "$TARGET/.gitignore"
render "$TEMPLATES/ci.yml.tmpl"           > "$TARGET/.github/workflows/ci.yml"

# --- 5b. Codex port (present only when the codex/ SSOT + its manifest exist) ---
MANIFEST_CODEX="$HERE/manifest-codex.txt"
cx_copied=0
if [ -r "$MANIFEST_CODEX" ] && [ -d "$REPO_ROOT/codex" ]; then
  # The prkit repo's entire codex/ tree is generated — clean it for an
  # idempotent regenerate (no stale files if the manifest shrinks).
  rm -rf "$TARGET/codex"
  # Copy each codex source to a dest path with uberdev->prkit applied
  # (codex/uberdev-codex -> codex/prkit-codex, uberdev-cmd- -> prkit-cmd-,
  #  codex/agents/uberdev-<a>.toml -> codex/agents/prkit-<a>.toml).
  while IFS= read -r rel; do
    case "$rel" in ''|\#*) continue;; esac
    drel="$(printf '%s' "$rel" | sed 's/uberdev/prkit/g')"
    dst="$TARGET/$drel"
    mkdir -p "$(dirname "$dst")"
    cp "$REPO_ROOT/$rel" "$dst"
    cx_copied=$((cx_copied+1))
  done < "$MANIFEST_CODEX"
  # Rewrite content of every copied codex file (neutralize goal/solve, then blanket).
  while IFS= read -r -d '' f; do
    prkit_neutralize "$f"
    prkit_apply_rewrites "$f"
  done < <(find "$TARGET/codex" -type f -print0)
  # Scaffold codex-specific files from prkit-correct templates (authored, not
  # rewritten — so they don't inherit UberDev's stale counts). AFTER the rewrite
  # loop so they stay pristine.
  mkdir -p "$TARGET/codex/prkit-codex/.codex-plugin"
  render "$TEMPLATES/codex-plugin.json.tmpl" > "$TARGET/codex/prkit-codex/.codex-plugin/plugin.json"
  render "$TEMPLATES/codex-README.md.tmpl"   > "$TARGET/codex/README.md"
  render "$TEMPLATES/codex-AGENTS.md.tmpl"    > "$TARGET/codex/AGENTS.md"
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
echo "generate: OK — copied $copied claude + $cx_copied codex files, scaffolded 8+3, verified."
echo "generate: next -> git -C '$TARGET' add -A && git -C '$TARGET' commit -m 'chore: regenerate prkit $VERSION'"
