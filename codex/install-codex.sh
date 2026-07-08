#!/usr/bin/env bash
# install-codex.sh — install UberDev into OpenAI Codex CLI.
#
# Codex counterpart to ./install.sh (the Claude Code installer). Codex has no
# single "enable plugin" key, so this installer wires UberDev across Codex's
# three config surfaces:
#
#   1. ~/.agents/skills/<name>/   ← Codex-ported skills + command-skills
#   2. ~/.codex/agents/*.toml     ← agents   (Codex personal-subagent dir)
#   3. ~/.codex/AGENTS.md         ← primer   (Codex global instructions)
#
# Codex reads skills from ~/.agents/skills/ natively (open-skills format).
# This installer copies the path-fixed Codex skill tree from
# codex/uberdev-codex/skills, not the raw Claude skill source. Agents live in
# ~/.codex/agents/ as standalone TOML. The primer is appended to the active
# Codex global instruction file (`~/.codex/AGENTS.override.md` when present,
# otherwise `~/.codex/AGENTS.md`).
#
# The Codex-native plugin (codex/uberdev-codex/) is the *alternative* install
# path — `codex plugin marketplace add TheFJK/UberDev` then `/plugins`. Use
# whichever you prefer. This script is the "one-liner, no app interaction"
# path; the plugin is the "browse and toggle" path. See codex/README.md.
#
# Why two paths: the documented Codex plugin manifest has no `agents` field,
# so the plugin can ship skills but NOT the 42 agents. This installer carries
# the agents. Users who want agents + dispatch MUST run this installer (the
# plugin alone leaves /solve, /turbo, /review-pr without their subagents).
#
# Idempotent: re-running is safe. Skills/agents are rsynced (mirror); the
# primer is merged behind a stable sentinel so re-runs don't duplicate it.
# Existing ~/.codex/AGENTS.md content outside the sentinel block is preserved.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/TheFJK/UberDev/main/codex/install-codex.sh | bash
#   ./codex/install-codex.sh                          # from a clone
#   ./codex/install-codex.sh --uninstall              # remove UberDev from Codex
#   CODEX_HOME=/custom/dir ./codex/install-codex.sh   # non-default CODEX_HOME
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
# Resolve the script's own dir so it works from a clone regardless of CWD. When
# run via `curl ... | bash`, $0 is just "bash"; in that case this initially
# points at CWD and bootstrap_source_tree downloads a temporary repo snapshot.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [ -f "${SCRIPT_SOURCE}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi
# The repo root holds plugins/uberdev/ (source) and codex/ (this script + tools).
# codex/ lives at $REPO_ROOT/codex, so climb one level.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
AGENTS_DIR="${CODEX_HOME}/agents"
SKILLS_USER_DIR="${HOME}/.agents/skills"
RUNTIME_DIR="${CODEX_HOME}/plugins/uberdev-codex"
AGENTS_MD_DEFAULT="${CODEX_HOME}/AGENTS.md"
AGENTS_MD_OVERRIDE="${CODEX_HOME}/AGENTS.override.md"
AGENTS_MD="${AGENTS_MD_DEFAULT}"
[ -f "${AGENTS_MD_OVERRIDE}" ] && AGENTS_MD="${AGENTS_MD_OVERRIDE}"
UBERDEV_REF="${UBERDEV_REF:-main}"
UBERDEV_REPO_URL="${UBERDEV_REPO_URL:-https://github.com/TheFJK/UberDev.git}"
UBERDEV_ARCHIVE_URL="${UBERDEV_ARCHIVE_URL:-https://github.com/TheFJK/UberDev/archive/refs/heads/${UBERDEV_REF}.tar.gz}"
BOOTSTRAP_PARENT=""

# Stable sentinels wrap the injected primer block so re-runs replace cleanly
# instead of appending duplicate copies. The marker text never appears in real
# user prose, so false matches are effectively impossible.
SENTINEL_BEGIN="<!-- BEGIN uberdev-codex-primer (managed by install-codex.sh) -->"
SENTINEL_END="<!-- END uberdev-codex-primer -->"

# Subdirectories inside the repo. These can be overridden for testing.
UBERDEV_SRC_INPUT="${UBERDEV_SRC:-}"
SKILLS_SRC_INPUT="${SKILLS_SRC:-}"
AGENTS_MD_SRC_INPUT="${AGENTS_MD_SRC:-}"
CONVERTER_INPUT="${CONVERTER:-}"
MANAGED_MARKER=".uberdev-codex-managed"

set_source_paths() {
  UBERDEV_SRC="${UBERDEV_SRC_INPUT:-${REPO_ROOT}/plugins/uberdev}"
  SKILLS_SRC="${SKILLS_SRC_INPUT:-${REPO_ROOT}/codex/uberdev-codex/skills}"
  AGENTS_MD_SRC="${AGENTS_MD_SRC_INPUT:-${SCRIPT_DIR}/AGENTS.md}"
  CONVERTER="${CONVERTER_INPUT:-${SCRIPT_DIR}/tools/convert-agents.py}"
}
set_source_paths

# ── Helpers ──────────────────────────────────────────────────────────────────
err()  { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "'$1' is required but not found in PATH."
    [ -n "${2:-}" ] && printf '       %s\n' "$2" >&2
    exit 1
  fi
}

source_tree_ready() {
  [ -d "${UBERDEV_SRC}/agents" ] \
    && [ -d "${SKILLS_SRC}" ] \
    && [ -f "${AGENTS_MD_SRC}" ] \
    && [ -f "${CONVERTER}" ]
}

cleanup_bootstrap() {
  if [ -n "${BOOTSTRAP_PARENT}" ] && [ -d "${BOOTSTRAP_PARENT}" ]; then
    rm -rf "${BOOTSTRAP_PARENT}"
  fi
}

extract_bootstrap_archive() {
  require_cmd tar "Needed to unpack the UberDev source snapshot."
  if [ -n "${UBERDEV_BOOTSTRAP_TARBALL:-}" ]; then
    tar -xzf "${UBERDEV_BOOTSTRAP_TARBALL}" -C "${BOOTSTRAP_PARENT}"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "${UBERDEV_ARCHIVE_URL}" | tar -xzf - -C "${BOOTSTRAP_PARENT}"; then
      return 0
    fi
    warn "archive download failed; trying git clone fallback."
  fi
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "${UBERDEV_REF}" "${UBERDEV_REPO_URL}" "${BOOTSTRAP_PARENT}/repo"
    return 0
  fi
  err "repo sources are missing and neither curl nor git is available to fetch them."
  exit 1
}

bootstrap_source_tree() {
  if ! source_tree_ready \
    && [ -d "$(pwd)/plugins/uberdev/agents" ] \
    && [ -d "$(pwd)/codex/uberdev-codex/skills" ] \
    && [ -f "$(pwd)/codex/AGENTS.md" ] \
    && [ -f "$(pwd)/codex/tools/convert-agents.py" ]; then
    REPO_ROOT="$(pwd)"
    SCRIPT_DIR="${REPO_ROOT}/codex"
    set_source_paths
  fi

  if source_tree_ready; then
    return 0
  fi

  BOOTSTRAP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/uberdev-codex.XXXXXX")"
  trap cleanup_bootstrap EXIT
  warn "local UberDev repo sources not found beside the installer; downloading ${UBERDEV_REF} snapshot."
  extract_bootstrap_archive

  local extracted
  if [ -d "${BOOTSTRAP_PARENT}/repo/plugins/uberdev" ]; then
    extracted="${BOOTSTRAP_PARENT}/repo"
  else
    extracted="$(find "${BOOTSTRAP_PARENT}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  fi
  if [ -z "${extracted}" ] || [ ! -d "${extracted}" ]; then
    err "downloaded UberDev archive did not contain a repo directory."
    exit 1
  fi

  REPO_ROOT="${extracted}"
  SCRIPT_DIR="${REPO_ROOT}/codex"
  set_source_paths
  if ! source_tree_ready; then
    err "downloaded UberDev snapshot is missing Codex install sources."
    printf '       checked UBERDEV_SRC=%s\n' "${UBERDEV_SRC}" >&2
    printf '       checked SKILLS_SRC=%s\n' "${SKILLS_SRC}" >&2
    printf '       checked AGENTS_MD_SRC=%s\n' "${AGENTS_MD_SRC}" >&2
    printf '       checked CONVERTER=%s\n' "${CONVERTER}" >&2
    exit 1
  fi
}

# ── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
  echo "Removing UberDev from Codex (skills, agents, primer)…"
  local failed=0
  # Skills: remove every dir carrying our managed marker, including stale
  # skills from older releases that no longer exist in the current source tree.
  if [ -d "${SKILLS_USER_DIR}" ]; then
    for skill_dir in "${SKILLS_USER_DIR}"/*; do
      [ -d "$skill_dir" ] || continue
      [ -f "${skill_dir}/${MANAGED_MARKER}" ] || continue
      name="$(basename "$skill_dir")"
      if rm -rf "${skill_dir}"; then
        echo "  removed skill: ${name}"
      else
        err "failed to remove managed skill: ${skill_dir}"
        failed=1
      fi
    done
  fi
  # Agents: remove namespaced uberdev-*.toml only.
  if [ -d "${AGENTS_DIR}" ]; then
    local agent_file removed_agents=0
    for agent_file in "${AGENTS_DIR}"/uberdev-*.toml; do
      [ -e "$agent_file" ] || continue
      if rm -f "$agent_file"; then
        removed_agents=1
      else
        err "failed to remove agent: ${agent_file}"
        failed=1
      fi
    done
    [ "$removed_agents" -eq 1 ] && echo "  removed agents: uberdev-*.toml"
  fi
  if [ -d "${RUNTIME_DIR}" ]; then
    if rm -rf "${RUNTIME_DIR}"; then
      echo "  removed runtime: ${RUNTIME_DIR}"
    else
      err "failed to remove runtime: ${RUNTIME_DIR}"
      failed=1
    fi
  fi
  # Primer: strip both possible global instruction files. Codex ignores
  # AGENTS.md when AGENTS.override.md exists, but a user may create/remove the
  # override between install and uninstall.
  local _agents_target _agents_saved
  _agents_saved="${AGENTS_MD}"
  for _agents_target in "${AGENTS_MD_DEFAULT}" "${AGENTS_MD_OVERRIDE}"; do
    AGENTS_MD="${_agents_target}"
    strip_primer || failed=1
  done
  AGENTS_MD="${_agents_saved}"
  if [ "$failed" -ne 0 ]; then
    err "UberDev uninstall incomplete; see failures above."
    exit 1
  fi
  ok "UberDev removed from Codex."
  echo "  (Codex itself, ~/.codex/config.toml, and other plugins were not touched.)"
}

strip_primer() {
  [ -f "${AGENTS_MD}" ] || return 0
  if ! grep -qF "${SENTINEL_BEGIN}" "${AGENTS_MD}" 2>/dev/null; then
    return 0  # nothing to strip
  fi
  local begin_count end_count tmp
  begin_count="$(grep -cF "${SENTINEL_BEGIN}" "${AGENTS_MD}" 2>/dev/null || true)"
  end_count="$(grep -cF "${SENTINEL_END}" "${AGENTS_MD}" 2>/dev/null || true)"
  if [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    err "malformed UberDev primer block in ${AGENTS_MD}; expected exactly one begin and one end sentinel. No changes made."
    return 1
  fi
  tmp="$(mktemp)"
  # Delete from BEGIN to END sentinel inclusive. awk avoids sed NFA edge cases
  # with arbitrary primer content (backslashes, slashes, &).
  if ! awk -v b="${SENTINEL_BEGIN}" -v e="${SENTINEL_END}" '
    $0 == b { if (seen_begin) exit 2; seen_begin=1; skip=1; next }
    $0 == e { if (!skip) exit 2; seen_end=1; skip=0; next }
    !skip { print }
    END { if (!seen_begin || !seen_end || skip) exit 2 }
  ' "${AGENTS_MD}" > "${tmp}"; then
    rm -f "${tmp}"
    err "malformed UberDev primer block in ${AGENTS_MD}; no changes made."
    return 1
  fi
  if [ -s "${tmp}" ]; then
    mv "${tmp}" "${AGENTS_MD}"
  else
    # Primer was the only content — leave the file empty-but-present.
    : > "${AGENTS_MD}"
    rm -f "${tmp}"
  fi
}

ensure_skills_user_dir_regular() {
  [ -L "${SKILLS_USER_DIR}" ] || return 0

  local link_target backup
  link_target="$(readlink "${SKILLS_USER_DIR}" 2>/dev/null || true)"
  backup="${SKILLS_USER_DIR}.symlink-$(date -u +%Y%m%d%H%M%S).bak"
  mv "${SKILLS_USER_DIR}" "${backup}"
  mkdir -p "${SKILLS_USER_DIR}"
  warn "converted ${SKILLS_USER_DIR} from symlink to regular Codex skills directory (old symlink backed up at ${backup}; target was ${link_target:-unknown})."
}

ensure_agents_md_regular_file() {
  [ -L "${AGENTS_MD}" ] || return 0

  local link_target backup tmp
  link_target="$(readlink "${AGENTS_MD}" 2>/dev/null || true)"
  backup="${AGENTS_MD}.symlink-$(date -u +%Y%m%d%H%M%S).bak"
  tmp="$(mktemp "${CODEX_HOME}/.agents-md-from-symlink.XXXXXX")"

  if ! cp -P "${AGENTS_MD}" "${backup}"; then
    rm -f "${tmp}"
    err "failed to back up ${AGENTS_MD} symlink before converting it to a regular file."
    exit 1
  fi
  if ! cat "${AGENTS_MD}" > "${tmp}"; then
    rm -f "${tmp}"
    err "failed to read ${AGENTS_MD} symlink target before converting it to a regular file."
    exit 1
  fi
  rm -f "${AGENTS_MD}"
  mv "${tmp}" "${AGENTS_MD}"
  warn "converted ${AGENTS_MD} from symlink to regular Codex guidance file (old symlink backed up at ${backup}; target was ${link_target:-unknown})."
}

# Ensure a run that would fail on a user-authored skill collision fails before
# touching runtime, agents, or primer.
preflight_skill_collisions() {
  if [ ! -d "${SKILLS_SRC}" ]; then
    err "skills source not found: ${SKILLS_SRC}"
    exit 1
  fi
  local skill_dir name
  for skill_dir in "${SKILLS_SRC}"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    [ "$name" = "_shared" ] && continue
    if [ -e "${SKILLS_USER_DIR}/${name}" ] && [ ! -f "${SKILLS_USER_DIR}/${name}/${MANAGED_MARKER}" ]; then
      err "skill collision: ${SKILLS_USER_DIR}/${name} already exists and is not managed by UberDev."
      printf '       Move or remove that skill, then rerun the installer. No files were overwritten.\n' >&2
      exit 1
    fi
  done
}

cleanup_stale_managed_skills() {
  [ -d "${SKILLS_USER_DIR}" ] || return 0
  local installed name stale
  for installed in "${SKILLS_USER_DIR}"/*; do
    [ -d "$installed" ] || continue
    [ -f "${installed}/${MANAGED_MARKER}" ] || continue
    name="$(basename "$installed")"
    [ -d "${SKILLS_SRC}/${name}" ] && continue
    stale=1
    if rm -rf "$installed"; then
      echo "  removed stale managed skill: ${name}"
    else
      err "failed to remove stale managed skill: ${installed}"
      exit 1
    fi
  done
  return 0
}

# ── Install ──────────────────────────────────────────────────────────────────
install_skills() {
  echo "→ Installing skills → ${SKILLS_USER_DIR}/"
  if [ ! -d "${SKILLS_SRC}" ]; then
    err "skills source not found: ${SKILLS_SRC}"
    exit 1
  fi
  ensure_skills_user_dir_regular
  mkdir -p "${SKILLS_USER_DIR}"
  cleanup_stale_managed_skills
  # Mirror each skill dir individually. --delete only within each skill's own
  # dir (not the whole SKILLS_USER_DIR) so we never touch unrelated user skills.
  for skill_dir in "${SKILLS_SRC}"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    # _shared holds cross-skill templates (document-reviewer), not a skill.
    [ "$name" = "_shared" ] && continue
    mkdir -p "${SKILLS_USER_DIR}/${name}"
    rsync -a --delete \
      --exclude '__pycache__/' --exclude '*.pyc' \
      --exclude '*.bak' --exclude '*.bak2' --exclude '*.fix' \
      --exclude '.DS_Store' \
      "$skill_dir" "${SKILLS_USER_DIR}/${name}/"
    printf 'managed-by=uberdev-codex\n' > "${SKILLS_USER_DIR}/${name}/${MANAGED_MARKER}"
  done
  local count
  count="$(find "${SKILLS_SRC}" -maxdepth 1 -mindepth 1 -type d ! -name '_shared' | wc -l | tr -d ' ')"
  ok "${count} skills installed to ${SKILLS_USER_DIR}/"
}

install_runtime() {
  echo "→ Installing runtime → ${RUNTIME_DIR}/"
  if [ ! -d "${REPO_ROOT}/codex/uberdev-codex" ]; then
    err "Codex runtime source not found: ${REPO_ROOT}/codex/uberdev-codex"
    exit 1
  fi
  mkdir -p "${RUNTIME_DIR}"
  rsync -a --delete \
    --exclude '__pycache__/' --exclude '*.pyc' \
    --exclude '*.bak' --exclude '*.bak2' --exclude '*.fix' \
    --exclude '.DS_Store' \
    "${REPO_ROOT}/codex/uberdev-codex/" "${RUNTIME_DIR}/"
  ok "runtime installed to ${RUNTIME_DIR}/"
}

install_agents() {
  echo "→ Installing agents → ${AGENTS_DIR}/"
  if [ ! -f "${CONVERTER}" ]; then
    err "agent converter not found: ${CONVERTER}"
    exit 1
  fi
  mkdir -p "${AGENTS_DIR}"
  local tmp_agents agent_file converted_count
  tmp_agents="$(mktemp -d "${CODEX_HOME}/.uberdev-agents.XXXXXX")"
  # Convert fresh into a temp dir, then replace the managed namespace. This
  # removes agents that existed in an older UberDev release but no longer ship.
  if ! python3 "${CONVERTER}" "${UBERDEV_SRC}/agents" "${tmp_agents}" >/dev/null; then
    rm -rf "${tmp_agents}"
    err "agent conversion failed (see messages above)."
    exit 1
  fi
  converted_count="$(find "${tmp_agents}" -maxdepth 1 -name 'uberdev-*.toml' | wc -l | tr -d ' ')"
  if [ "${converted_count}" -eq 0 ]; then
    rm -rf "${tmp_agents}"
    err "agent conversion produced zero agents; refusing to replace existing uberdev agents."
    exit 1
  fi
  for agent_file in "${AGENTS_DIR}"/uberdev-*.toml; do
    [ -e "$agent_file" ] || continue
    rm -f "$agent_file"
  done
  for agent_file in "${tmp_agents}"/uberdev-*.toml; do
    [ -e "$agent_file" ] || continue
    cp "$agent_file" "${AGENTS_DIR}/"
  done
  rm -rf "${tmp_agents}"
  local count
  count="$(find "${AGENTS_DIR}" -maxdepth 1 -name 'uberdev-*.toml' | wc -l | tr -d ' ')"
  ok "${count} agents installed to ${AGENTS_DIR}/ (as uberdev-*.toml)"
}

install_primer() {
  echo "→ Installing primer → ${AGENTS_MD}"
  if [ ! -f "${AGENTS_MD_SRC}" ]; then
    err "primer source not found: ${AGENTS_MD_SRC}"
    exit 1
  fi
  mkdir -p "${CODEX_HOME}"
  ensure_agents_md_regular_file
  # Atomic write: bootstrap empty file if absent; refuse to clobber malformed.
  if [ ! -f "${AGENTS_MD}" ]; then
    printf '# Codex global instructions\n' > "${AGENTS_MD}"
  fi
  if ! jq_err="$(jq -e . "${AGENTS_MD}" 2>&1 >/dev/null)"; then
    : # AGENTS.md is markdown, not JSON — jq "failure" here is expected and fine.
  fi
  # Replace any prior managed block, then append the fresh one.
  strip_primer
  TMP="$(mktemp "${CODEX_HOME}/.agents-md.XXXXXX")"
  trap 'rm -f "$TMP"' RETURN
  {
    cat "${AGENTS_MD}"
    # Ensure exactly one blank line between existing content and the block.
    [ -s "${AGENTS_MD}" ] && [ "$(tail -c1 "${AGENTS_MD}" 2>/dev/null)" != "" ] && printf '\n'
    printf '\n%s\n\n' "${SENTINEL_BEGIN}"
    cat "${AGENTS_MD_SRC}"
    printf '\n%s\n' "${SENTINEL_END}"
  } > "${TMP}"
  mv "${TMP}" "${AGENTS_MD}"
  ok "primer merged into ${AGENTS_MD}"
}

print_next_steps() {
  cat <<EOF

✓ UberDev installed for Codex.

Next steps:

  1. Restart Codex (or start a fresh session) so skills and agents load.

  2. Verify:
       ls ~/.agents/skills/      # ~39 UberDev skills incl. command-skills
       ls ~/.codex/agents/       # ~42 uberdev-*.toml subagents
       grep uberdev-codex-primer ~/.codex/AGENTS*.md   # primer block present

Uninstall:  ./codex/install-codex.sh --uninstall
Docs:       codex/README.md
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    --uninstall|-u) do_uninstall; exit 0 ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    "") : ;;  # default = install
    *) err "unknown argument: $1"; echo "Usage: $0 [--uninstall|--help]" >&2; exit 1 ;;
  esac

  bootstrap_source_tree

  echo "Installing UberDev for Codex (CODEX_HOME=${CODEX_HOME})…"
  echo "  source: ${UBERDEV_SRC}"
  echo ""

  # jq is NOT required for this installer (it is for the Claude installer,
  # which patches settings.json). We need python3 (agent conversion) and
  # rsync (mirroring). git is recommended (skills dispatch via git) but not
  # load-bearing for the install itself.
  require_cmd python3 "macOS ships it; elsewhere see https://python.org"
  require_cmd rsync "macOS: brew install rsync; Debian: sudo apt install rsync"

  # Warn (don't fail) if codex itself isn't on PATH — user may be installing
  # on a box before installing Codex, or have it under a different name.
  if ! command -v codex >/dev/null 2>&1; then
    warn "'codex' CLI not found on PATH. Install it from https://developers.openai.com/codex — the files are still placed correctly for when it is."
  fi

  preflight_skill_collisions
  install_runtime
  install_skills
  install_agents
  install_primer
  print_next_steps
}

main "$@"
