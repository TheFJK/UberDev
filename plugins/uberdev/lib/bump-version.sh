#!/usr/bin/env bash
# plugins/uberdev/lib/bump-version.sh — one-command version-bump ritual
# (RFC 0012 §7.7, infra-R5; issue #309).
#
# Usage:
#   bash plugins/uberdev/lib/bump-version.sh <new-version> [--repo-root <path>]
#   bash plugins/uberdev/lib/bump-version.sh --help
#
# Propagates <new-version> (strict SemVer X.Y.Z) to EVERY CI-locked version
# surface in one shot:
#
#   Manifest surfaces (the drift pre-check refuses if these disagree):
#     1. plugins/uberdev/.claude-plugin/plugin.json   "version" (canonical SSOT — what /plugin reads)
#     2. .claude-plugin/marketplace.json              plugins[0].version (marketplace listing)
#     3. README.md                                    shields.io badge `version-X.Y.Z-blue`
#     4. CHANGELOG.md                                 new dated `## [X.Y.Z] — YYYY-MM-DD` section stub
#   CI release-ratchet test locks (red CI on a clean main if missed):
#     5. tests/goal.test.sh                           G20 `assert_version_bump` arg + the
#                                                     `version bump locked (X.Y.Z)` echo header
#     6. tests/solve-claim.test.sh                    `assert_version_bump` arg + the
#                                                     `Version bump A.B.C -> X.Y.Z propagated` echo header
#
#   The Codex plugin manifest (`codex/uberdev-codex/.codex-plugin/plugin.json`)
#   was surface 3 until the Codex distribution was retired (issue #381). It is
#   NOT a dropped check — the file it locked no longer exists, and keeping it
#   would make every bump exit 3 on a missing surface.
#
# Contract:
#   - Validates <new-version> is strict SemVer X.Y.Z (numeric, no leading
#     zeros, no `v` prefix, no pre-release/build suffix).
#   - Drift-grep PRE-check: refuses (exit 3) BEFORE editing anything if the
#     version surfaces disagree about the current version — a half-bumped
#     repo needs a human, not more sed. The manifest/badge/CHANGELOG surfaces
#     are the mandated refusal set (RFC 0012 §7.7); the 2 test-lock files are
#     pre-checked with the SAME line-scoped patterns the edits use, so a
#     replace can never silently no-op into a half-bump.
#   - Idempotent: <new-version> == current with every surface consistent is
#     a no-op success (exit 0; no duplicate CHANGELOG section, no churn).
#   - Post-write verification: every surface is re-grepped at <new-version>
#     after editing; any miss fails loudly (exit 4) with restore advice.
#   - NEVER runs git or gh: no commit, no tag, no push, no release. The
#     script edits files and prints the remaining ritual checklist —
#     foreground control over the destructive tag/release steps stays with
#     the operator, serialized against /merge landings (RFC 0012 §7.7). The
#     checklist is printed here because CLAUDE.md (where the ritual is
#     documented) is gitignored and invisible to worktree agents (R-15).
#
# Exit codes:
#   0  bumped (or already at target — idempotent no-op)
#   2  usage error (bad/missing version, unknown flag, bad --repo-root path)
#   3  drift refusal (surfaces disagree / missing surface file / target
#      version already has a CHANGELOG section)
#   4  post-write verification failed (repo may be half-edited — see stderr)
#
# Portability: macOS bash 3.2, GNU bash, Git Bash on Windows. In-place edits
# go through a tempfile + copy-back helper (bv_edit_inplace) instead of sed's
# in-place flag — GNU sed and BSD/macOS sed disagree on that flag's argument
# shape, and copy-back also preserves the target file's inode + permissions.

set -u
set -o pipefail

# Strict SemVer X.Y.Z: numeric components, no leading zeros, no prefix/suffix.
SEMVER_ERE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

EXIT_OK=0
EXIT_USAGE=2
EXIT_DRIFT=3
EXIT_VERIFY=4

usage() {
  cat <<'USAGE'
bump-version.sh — propagate a new UberDev version to every CI-locked surface.

Usage:
  bash plugins/uberdev/lib/bump-version.sh <new-version> [--repo-root <path>]

  <new-version>        strict SemVer X.Y.Z (e.g. 0.37.0)
  --repo-root <path>   repo root to operate on (default: derived from this
                       script's own location, <root>/plugins/uberdev/lib/)
  -h, --help           show this help

Updates: plugin.json + marketplace.json "version", the README version badge,
a dated CHANGELOG section stub, and the version locks in tests/goal.test.sh +
tests/solve-claim.test.sh (assert_version_bump args + echo headers). Refuses
on pre-existing drift. Never runs git/gh — it prints the remaining
tag/release checklist instead.
USAGE
}

err() { printf 'bump-version: %s\n' "$*" >&2; }

is_semver() { grep -Eq -e "$SEMVER_ERE" <<<"$1"; }

# bv_edit_inplace <file> <sed -e args...>
# Portable in-place edit: render through a tempfile next to the target, then
# copy the bytes back (keeps inode + permissions; sidesteps the GNU-vs-BSD
# in-place-flag divergence).
bv_edit_inplace() {
  local target="$1"; shift
  local tmp="${target}.bump-version.$$"
  if ! sed "$@" "$target" > "$tmp"; then
    rm -f "$tmp"
    err "sed edit failed for $target"
    return 1
  fi
  cat "$tmp" > "$target" && rm -f "$tmp"
}

# bv_insert_changelog_stub <file> <version> <date>
# Inserts a dated `## [<version>] — <date>` section stub (with a fill-me-in
# placeholder body) immediately above the topmost existing `## [` section.
bv_insert_changelog_stub() {
  local file="$1" ver="$2" d="$3"
  local tmp="${file}.bump-version.$$"
  if ! awk -v ver="$ver" -v d="$d" '
    !done && /^## \[/ {
      print "## [" ver "] — " d
      print ""
      print "- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    err "CHANGELOG stub insertion failed for $file"
    return 1
  fi
  cat "$tmp" > "$file" && rm -f "$tmp"
}

print_checklist() {
  local ver="$1"
  cat <<CHECKLIST

Remaining release ritual — NOT done by this script (foreground control over
the destructive tag/release steps stays with the operator; RFC 0012 §7.7):

  1. Fill in the CHANGELOG.md [${ver}] section stub (replace the pending
     placeholder line with the real release notes).
  2. Verify the version locks locally:
       bash tests/goal.test.sh && bash tests/solve-claim.test.sh
     (full suite = the ubuntu run list in .github/workflows/test.yml).
  3. Review the diff, then commit on the release branch:
       git commit -am "chore(release): v${ver}"
  4. Land SEQUENTIALLY — one release per landing, never parallel-bump two
     PRs off the same base (version-collision class, RFC 0012 §9).
  5. After the release commit is on main:
       git tag v${ver} && git push origin v${ver}
  6. Publish the release (notes = the CHANGELOG section):
       gh release create v${ver} --title "v${ver}" --notes-file <notes-file>
CHECKLIST
}

# --- argument parsing --------------------------------------------------------
NEW_VERSION=""
REPO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit "$EXIT_OK"
      ;;
    --repo-root)
      if [ $# -lt 2 ]; then
        err "--repo-root requires a path argument"
        exit "$EXIT_USAGE"
      fi
      REPO_ROOT="$2"
      shift
      ;;
    --repo-root=*)
      REPO_ROOT="${1#--repo-root=}"
      ;;
    -*)
      err "unknown flag: $1"
      usage >&2
      exit "$EXIT_USAGE"
      ;;
    *)
      if [ -n "$NEW_VERSION" ]; then
        err "unexpected extra argument: $1"
        usage >&2
        exit "$EXIT_USAGE"
      fi
      NEW_VERSION="$1"
      ;;
  esac
  shift
done

if [ -z "$NEW_VERSION" ]; then
  err "missing <new-version> argument"
  usage >&2
  exit "$EXIT_USAGE"
fi
if ! is_semver "$NEW_VERSION"; then
  err "invalid version '$NEW_VERSION' — expected strict SemVer X.Y.Z (no v prefix, no leading zeros, no suffix)"
  exit "$EXIT_USAGE"
fi

if [ -z "$REPO_ROOT" ]; then
  # The script lives at <root>/plugins/uberdev/lib/bump-version.sh.
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
fi
if ! REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd)"; then
  err "repo root does not exist or is not a directory: ${REPO_ROOT}"
  exit "$EXIT_USAGE"
fi

# --- surface inventory ---------------------------------------------------------
PLUGIN_JSON="$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
README_MD="$REPO_ROOT/README.md"
CHANGELOG_MD="$REPO_ROOT/CHANGELOG.md"
GOAL_TEST="$REPO_ROOT/tests/goal.test.sh"
SOLVE_CLAIM_TEST="$REPO_ROOT/tests/solve-claim.test.sh"

MISSING=""
for f in "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$README_MD" "$CHANGELOG_MD" "$GOAL_TEST" "$SOLVE_CLAIM_TEST"; do
  if [ ! -r "$f" ]; then
    MISSING="${MISSING}  - ${f}"$'\n'
  fi
done
if [ -n "$MISSING" ]; then
  err "not an UberDev repo root (version surfaces missing) — looked under: $REPO_ROOT"
  printf '%s' "$MISSING" >&2
  exit "$EXIT_DRIFT"
fi

# --- current version (canonical SSOT: plugin.json) ------------------------------
CURRENT="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$PLUGIN_JSON" | sed -n '1p')"
if [ -z "$CURRENT" ] || ! is_semver "$CURRENT"; then
  err "cannot determine the current version from $PLUGIN_JSON (got: '${CURRENT:-}')"
  exit "$EXIT_DRIFT"
fi

CUR_ERE="${CURRENT//./\\.}"      # dot-escaped for grep -E …
NEW_ERE="${NEW_VERSION//./\\.}"
CUR_SED="$CUR_ERE"               # … and the same escaping works for sed BRE
VERSION_KEY_RE='"version"[[:space:]]*:[[:space:]]*'

# --- drift-grep pre-check (REFUSE before touching anything) ---------------------
# The grep patterns below mirror the sed/awk edits 1:1 — a pre-check pass
# guarantees every line-scoped replace finds its line.
DRIFT=""
check_surface() {  # <file> <ere-pattern> <label>
  if ! grep -Eq -e "$2" "$1"; then
    DRIFT="${DRIFT}  - ${3}"$'\n'"      file:     ${1}"$'\n'"      expected: /${2}/"$'\n'
  fi
}

check_surface "$PLUGIN_JSON"      "${VERSION_KEY_RE}\"${CUR_ERE}\"" "plugin.json \"version\""
check_surface "$MARKETPLACE_JSON" "${VERSION_KEY_RE}\"${CUR_ERE}\"" "marketplace.json plugins[0].version"
check_surface "$README_MD"        "version-${CUR_ERE}-blue"         "README.md version badge"
# CHANGELOG: the TOPMOST released section must be the current version.
TOP_HEADER="$(awk '/^## \[/ { print; exit }' "$CHANGELOG_MD")"
case "$TOP_HEADER" in
  "## [$CURRENT]"*) : ;;
  *) DRIFT="${DRIFT}  - CHANGELOG.md topmost section"$'\n'"      file:     ${CHANGELOG_MD}"$'\n'"      expected: '## [$CURRENT] …', found: '${TOP_HEADER:-<no ## [ section>}'"$'\n' ;;
esac
check_surface "$GOAL_TEST"        "assert_version_bump[[:space:]].*\"${CUR_ERE}\""        "tests/goal.test.sh assert_version_bump arg"
check_surface "$GOAL_TEST"        "version bump locked \(${CUR_ERE}\)"                    "tests/goal.test.sh G20 echo header"
check_surface "$SOLVE_CLAIM_TEST" "assert_version_bump[[:space:]].*\"${CUR_ERE}\""        "tests/solve-claim.test.sh assert_version_bump arg"
check_surface "$SOLVE_CLAIM_TEST" "== Version bump [0-9.]+ -> ${CUR_ERE} propagated =="   "tests/solve-claim.test.sh echo header"

if [ -n "$DRIFT" ]; then
  err "DRIFT detected — the version surfaces disagree about the current version (${CURRENT}, per plugin.json)."
  err "Refusing to bump a half-bumped repo (RFC 0012 §7.7 drift pre-check). Reconcile these by hand, then re-run:"
  printf '%s' "$DRIFT" >&2
  exit "$EXIT_DRIFT"
fi

# --- idempotent no-op ------------------------------------------------------------
if [ "$NEW_VERSION" = "$CURRENT" ]; then
  printf 'bump-version: already at %s — every locked surface agrees; nothing to do.\n' "$CURRENT"
  print_checklist "$CURRENT"
  exit "$EXIT_OK"
fi

# --- duplicate-section guard -------------------------------------------------------
# Bumping "to" a version that already has a CHANGELOG section would insert a
# duplicate dated stub (downgrade / re-release typo). Refuse.
if grep -Eq -e "^## \[${NEW_ERE}\]" "$CHANGELOG_MD"; then
  err "CHANGELOG.md already has a '## [${NEW_VERSION}]' section while the current version is ${CURRENT}."
  err "Refusing: bumping to an already-released version would duplicate its CHANGELOG section."
  exit "$EXIT_DRIFT"
fi

# --- perform the bump ---------------------------------------------------------------
TODAY="$(date +%Y-%m-%d)"
EDIT_FAILED=0

bv_edit_inplace "$PLUGIN_JSON" \
  -e "s/\"version\"[[:space:]]*:[[:space:]]*\"${CUR_SED}\"/\"version\": \"${NEW_VERSION}\"/" || EDIT_FAILED=1
bv_edit_inplace "$MARKETPLACE_JSON" \
  -e "s/\"version\"[[:space:]]*:[[:space:]]*\"${CUR_SED}\"/\"version\": \"${NEW_VERSION}\"/" || EDIT_FAILED=1
bv_edit_inplace "$README_MD" \
  -e "s/version-${CUR_SED}-blue/version-${NEW_VERSION}-blue/" || EDIT_FAILED=1
bv_insert_changelog_stub "$CHANGELOG_MD" "$NEW_VERSION" "$TODAY" || EDIT_FAILED=1
# Line-scoped on purpose: only the assert_version_bump call site and the two
# cosmetic echo headers move; unrelated version literals in those tests
# (e.g. historical no-grep guards) must stay untouched.
bv_edit_inplace "$GOAL_TEST" \
  -e "/assert_version_bump/s/\"${CUR_SED}\"/\"${NEW_VERSION}\"/" \
  -e "/version bump locked/s/(${CUR_SED})/(${NEW_VERSION})/" || EDIT_FAILED=1
bv_edit_inplace "$SOLVE_CLAIM_TEST" \
  -e "/assert_version_bump/s/\"${CUR_SED}\"/\"${NEW_VERSION}\"/" \
  -e "s/== Version bump [0-9][0-9.]* -> [0-9][0-9.]* propagated ==/== Version bump ${CURRENT} -> ${NEW_VERSION} propagated ==/" || EDIT_FAILED=1

if [ "$EDIT_FAILED" -ne 0 ]; then
  err "one or more edits failed — the repo may be half-edited. Inspect and restore via your VCS before retrying."
  exit "$EXIT_VERIFY"
fi

# --- post-write verification ----------------------------------------------------------
VERIFY_FAIL=""
verify_surface() {  # <file> <ere-pattern> <label>
  if ! grep -Eq -e "$2" "$1"; then
    VERIFY_FAIL="${VERIFY_FAIL}  - ${3}: ${1} does not match /${2}/"$'\n'
  fi
}

verify_surface "$PLUGIN_JSON"      "${VERSION_KEY_RE}\"${NEW_ERE}\""                       "plugin.json"
verify_surface "$MARKETPLACE_JSON" "${VERSION_KEY_RE}\"${NEW_ERE}\""                       "marketplace.json"
verify_surface "$README_MD"        "version-${NEW_ERE}-blue"                               "README.md badge"
verify_surface "$CHANGELOG_MD"     "^## \[${NEW_ERE}\].*${TODAY//-/\\-}"                   "CHANGELOG.md dated stub"
verify_surface "$GOAL_TEST"        "assert_version_bump[[:space:]].*\"${NEW_ERE}\""        "tests/goal.test.sh assert_version_bump arg"
verify_surface "$GOAL_TEST"        "version bump locked \(${NEW_ERE}\)"                    "tests/goal.test.sh G20 echo header"
verify_surface "$SOLVE_CLAIM_TEST" "assert_version_bump[[:space:]].*\"${NEW_ERE}\""        "tests/solve-claim.test.sh assert_version_bump arg"
verify_surface "$SOLVE_CLAIM_TEST" "== Version bump ${CUR_ERE} -> ${NEW_ERE} propagated ==" "tests/solve-claim.test.sh echo header"
TOP_AFTER="$(awk '/^## \[/ { print; exit }' "$CHANGELOG_MD")"
case "$TOP_AFTER" in
  "## [$NEW_VERSION]"*) : ;;
  *) VERIFY_FAIL="${VERIFY_FAIL}  - CHANGELOG.md topmost section is '${TOP_AFTER}', expected '## [$NEW_VERSION] …'"$'\n' ;;
esac

if [ -n "$VERIFY_FAIL" ]; then
  err "post-write verification FAILED — the repo may be half-edited:"
  printf '%s' "$VERIFY_FAIL" >&2
  err "review with 'git -C \"$REPO_ROOT\" diff' and restore the touched files before retrying."
  exit "$EXIT_VERIFY"
fi

# --- summary + remaining ritual ----------------------------------------------------------
printf 'bump-version: %s -> %s — all locked surfaces updated:\n' "$CURRENT" "$NEW_VERSION"
printf '  - %s\n' \
  "plugins/uberdev/.claude-plugin/plugin.json  (\"version\")" \
  ".claude-plugin/marketplace.json             (plugins[0].version)" \
  "README.md                                   (version badge)" \
  "CHANGELOG.md                                (## [${NEW_VERSION}] — ${TODAY} stub inserted)" \
  "tests/goal.test.sh                          (G20 version lock + echo header)" \
  "tests/solve-claim.test.sh                   (version lock + echo header)"
print_checklist "$NEW_VERSION"
exit "$EXIT_OK"
