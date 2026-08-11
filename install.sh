#!/usr/bin/env bash
# UberDev bootstrap installer.
#
# Works around an upstream Claude Code bug where `/plugin install` populates
# the cache + installed_plugins.json but does NOT write enabledPlugins in
# ~/.claude/settings.json — so commands silently 404 until that key is
# patched in by hand.
#
# Upstream state, re-checked 2026-08-10:
#   LIVE  anthropics/claude-code#14815 — open; the bug this script works around.
#   DEAD  anthropics/claude-code#20661 — closed 2026-01-29, duplicate (folded into #17832).
#   DEAD  anthropics/claude-code#17832 — closed 2026-03-30, not_planned (declined upstream).
#   DEAD  anthropics/claude-code#15524 — closed 2025-12-31, duplicate.
# The bug is unfixed, so this script is still load-bearing. Do not read the
# closed issues above as evidence it was fixed — they were folded or declined,
# never resolved.
#
# What this script does:
#   1. Best-effort runs the marketplace-add + install slash commands via
#      `claude --print` (no-op if claude isn't on PATH or doesn't accept
#      slash commands in print mode — the jq-patch below is the real fix).
#   2. jq-patches ~/.claude/settings.json to set
#      enabledPlugins["uberdev@uberdev"] = true. Idempotent: re-running is
#      a no-op, and unrelated keys / sibling enabledPlugins entries are
#      preserved.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/TheFJK/UberDev/main/install.sh | bash
# or, after cloning:
#   ./install.sh

set -euo pipefail

PLUGIN_KEY="uberdev@uberdev"
MARKETPLACE_REPO="${UBERDEV_MARKETPLACE:-TheFJK/UberDev}"
SETTINGS_DIR="${HOME}/.claude"
SETTINGS="${SETTINGS_DIR}/settings.json"

# ── Pre-flight ────────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required but not found in PATH." >&2
  echo "       macOS:   brew install jq" >&2
  echo "       Debian:  sudo apt install jq" >&2
  echo "       Other:   https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

# ── Step 1: marketplace-add + install (best-effort, non-interactive) ──────────
# Best-effort because the user-visible workaround is the jq-patch below — it's
# what unblocks /uberdev:* commands. `|| true` swallows failures so a stale
# claude binary or a CC version that doesn't run slash commands in --print
# mode doesn't break the install.
#
# run_bounded: cap each claude invocation at 30s (RFC 0012 §3.13). `claude
# --print` can hang indefinitely (auth prompt, network stall), wedging the
# curl|bash one-liner before the jq-patch ever runs. GNU/BSD `timeout` is
# probed first, then Homebrew coreutils' `gtimeout` (macOS ships no system
# timeout); if neither exists, run unbounded — fail-open keeps the best-effort
# step alive on minimal hosts, and the jq-patch below remains the real fix.
run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 "$@"
  else
    "$@"
  fi
}

if command -v claude >/dev/null 2>&1; then
  echo "→ Adding marketplace ${MARKETPLACE_REPO} and installing ${PLUGIN_KEY}…"
  run_bounded claude --print "/plugin marketplace add ${MARKETPLACE_REPO}" >/dev/null 2>&1 || true
  run_bounded claude --print "/plugin install ${PLUGIN_KEY}" >/dev/null 2>&1 || true
else
  echo "⚠️  'claude' CLI not found on PATH." >&2
  echo "   Run these inside Claude Code, then re-run this installer to enable:" >&2
  echo "     /plugin marketplace add ${MARKETPLACE_REPO}" >&2
  echo "     /plugin install ${PLUGIN_KEY}" >&2
fi

# BEGIN settings-mutation — the ONLY region of this script that writes
# ~/.claude/settings.json. Everything outside these two markers is preflight,
# best-effort slash commands, or error output. README.md's "What the script
# does to ~/.claude/settings.json" section quotes the one-line sed command
# that prints exactly this region, so a reader can audit the dangerous part
# without reading the whole file. The marker strings are deliberately not
# repeated anywhere else in this script — a second copy would truncate that
# sed range. tests/install.test.sh I12 pins the pair and ratchets against a
# future settings write escaping the fence.
#
# ── Step 2: jq-patch enabledPlugins (the actual bug workaround) ───────────────
mkdir -p "${SETTINGS_DIR}" || {
  echo "ERROR: failed to create ${SETTINGS_DIR}." >&2
  echo "       Check permissions on ${HOME}, then re-run." >&2
  exit 1
}

# Bootstrap an empty settings.json if it doesn't exist yet. We only do this
# when the file is missing — we do NOT overwrite an existing file even if
# it's empty/malformed (see the jq -e guard below).
if [ ! -f "${SETTINGS}" ]; then
  echo '{}' > "${SETTINGS}"
fi

# Refuse to clobber a malformed settings.json. If a user has hand-edited their
# settings into invalid JSON, silently rewriting it would destroy their work;
# surface jq's actual parse error so the user knows where to fix it.
if ! jq_err="$(jq -e . "${SETTINGS}" 2>&1 >/dev/null)"; then
  echo "ERROR: ${SETTINGS} is not valid JSON; refusing to patch." >&2
  # jq prefixes its output with 'jq: ' already; pass through as-is, indented.
  echo "${jq_err}" | sed 's/^/       /' >&2
  echo "       Fix the file manually, then re-run." >&2
  exit 1
fi

# Atomic patch via temp-file + mv: the original is only replaced after jq
# writes a valid JSON document, so a mid-write crash leaves settings.json
# intact. The trap always runs (any exit path); on the success path it's a
# no-op because mv has already renamed $TMP out from under it.
#
# TMP lives in $SETTINGS_DIR (not $TMPDIR) so it shares a filesystem with
# $SETTINGS — that makes the mv a true rename(2) syscall (atomic) instead of
# a copy-then-unlink fallback that crosses filesystems non-atomically. The
# leading `.` makes it a hidden file in case the move is interrupted.
TMP="$(mktemp "${SETTINGS_DIR}/.settings.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# `.enabledPlugins // {}` defaults the key to an empty object when absent,
# so users without any prior plugin config get a well-formed entry. Setting
# `[$key] = true` is idempotent: a re-run on already-enabled state is a
# byte-level no-op. Sibling enabledPlugins entries (other plugins) are
# preserved verbatim because we mutate a single key, not the whole object.
jq --arg key "${PLUGIN_KEY}" \
  '.enabledPlugins = (.enabledPlugins // {}) | .enabledPlugins[$key] = true' \
  "${SETTINGS}" > "${TMP}"

if ! mv "${TMP}" "${SETTINGS}"; then
  echo "ERROR: failed to write ${SETTINGS}." >&2
  echo "       Check permissions on ${SETTINGS_DIR}, then re-run." >&2
  exit 1
fi
# END settings-mutation

echo "✓ uberdev installed and enabled in ${SETTINGS}."
echo "  Restart Claude Code (or run /reload-plugins) to load the plugin."
