#!/usr/bin/env bash
# release-anchor.sh — resolve the TRUST HEAD for /merge Phase 1.4 PATH_2.
#
# WHY THIS EXISTS (issue #364). `/goal` must guarantee a version bump before it
# lands a PR, and the serialized landing lane is the only place the next version
# is unambiguous (N parallel solvers off one base all resolve the SAME next
# version, and the duplicate change auto-merges without a conflict —
# project_uberdev_merge_version_collision). So the bump necessarily lands on the
# PR head AFTER `/review-pr` anchored the trust trail. Without this helper that
# is fatal: PATH_2 (b) reads the trailer off the most-recent commit (now the
# release commit, which has none) and PATH_2 (c) sees a non-empty cumulative
# diff over the trailer SHA (verdict STALE) — the PR can never land.
#
# WHAT IT DOES. It answers exactly one question: "is the top commit a release
# commit that provably changed NO reviewed code?" If yes, the trust head is its
# parent — (b) reads the trailer there and (c) is dispatched with that OID, so
# the trust-trail-evaluator agent is untouched and still sees an empty diff. If
# anything about the top commit is unproven, the trust head is the head itself
# and the gate behaves exactly as it did before this file existed.
#
# THE PREDICATE IS THE SECURITY BOUNDARY. A subject match alone would be a way
# to smuggle arbitrary code past the trust gate — two of the six version
# surfaces (tests/goal.test.sh, tests/solve-claim.test.sh) are executable test
# files, so a path allow-list alone is not enough either. Every one of these
# must hold:
#   1. the commit has exactly ONE parent (no merges),
#   2. its subject is exactly `chore(release): vX.Y.Z`,
#   3. its parent is NOT itself a release commit (tolerance depth is exactly 1),
#   4. its diff — enumerated with rename detection DISABLED, so a rename's
#      deleted SOURCE is in the set and not collapsed away — is non-empty and
#      touches ONLY the six version surfaces,
#   5. the canonical manifest version strictly ADVANCES, to the X.Y.Z named in
#      the subject,
#   6. every changed line outside CHANGELOG.md is a pure version-token
#      substitution — normalising SemVer tokens away, the removed and added
#      line sequences are IDENTICAL AND IN THE SAME ORDER (order matters: a
#      multiset comparison would tolerate reordering executable test lines),
#   7. CHANGELOG.md is insertion-only and every inserted line is a release
#      section header, a bullet, a stub marker, or blank — bounded by
#      RELEASE_ANCHOR_MAX_CHANGELOG_LINES.
#
# USAGE
#   bash release-anchor.sh <head-oid-or-rev> [<working-dir>]
#
# STDOUT — KEY=VALUE lines, always including TRUST_HEAD and RELEASE_ANCHOR:
#   TRUST_HEAD=<40-hex>              the OID (b)/(c) must be evaluated against
#   RELEASE_ANCHOR=none|tolerated
#   RELEASE_ANCHOR_REASON=<slug>     why not tolerated (closed vocabulary)
#   RELEASE_ANCHOR_VERSION=<X.Y.Z>   only when tolerated
#
# EXIT — 0 when the resolution ran; 2 when the inputs are unusable (bad rev,
# not a git worktree, missing argument). Callers treat ANY non-zero exit and any
# `RELEASE_ANCHOR` value other than `tolerated` identically: no tolerance, read
# the trailer off the head itself. There is no fail-open path.

set -u

RELEASE_ANCHOR_MAX_CHANGELOG_LINES=40
RELEASE_ANCHOR_MAX_DIFF_LINES=400

# The six version surfaces. SSOT is lib/bump-version.sh, which owns the edit;
# tests/merge.test.sh asserts this list has not drifted from that script.
# It was SEVEN until the Codex distribution was retired (issue #381) and
# codex/uberdev-codex/.codex-plugin/plugin.json stopped existing; the entry was
# removed here because bump-version.sh no longer owns that path, not to widen
# what a release commit may touch.
release_anchor_surfaces() {
  cat <<'SURFACES'
plugins/uberdev/.claude-plugin/plugin.json
.claude-plugin/marketplace.json
README.md
CHANGELOG.md
tests/goal.test.sh
tests/solve-claim.test.sh
SURFACES
}

RELEASE_ANCHOR_MANIFEST='plugins/uberdev/.claude-plugin/plugin.json'
RELEASE_ANCHOR_CHANGELOG='CHANGELOG.md'

# emit <trust-head> <state> <reason> [version]
release_anchor_emit() {
  printf 'TRUST_HEAD=%s\n' "$1"
  printf 'RELEASE_ANCHOR=%s\n' "$2"
  printf 'RELEASE_ANCHOR_REASON=%s\n' "$3"
  [ -n "${4:-}" ] && printf 'RELEASE_ANCHOR_VERSION=%s\n' "$4"
  return 0
}

# release_anchor_subject_version SUBJECT -> X.Y.Z on stdout, empty when the
# subject is not exactly a release subject. Anchored at both ends on purpose:
# `chore(release): v1.2.3 and also rm -rf` must NOT match.
release_anchor_subject_version() {
  printf '%s\n' "$1" \
    | sed -n 's/^chore(release): v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p'
}

# release_anchor_manifest_version   (manifest JSON on stdin)
release_anchor_manifest_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
    | head -n 1
}

# release_anchor_semver_gt A B -> rc 0 when A > B (numeric, field by field).
release_anchor_semver_gt() {
  local a="$1" b="$2" i av bv
  for i in 1 2 3; do
    av="$(printf '%s' "$a" | cut -d. -f"$i")"
    bv="$(printf '%s' "$b" | cut -d. -f"$i")"
    case "$av$bv" in *[!0-9]*|'') return 1 ;; esac
    [ "$(( 10#$av ))" -gt "$(( 10#$bv ))" ] && return 0
    [ "$(( 10#$av ))" -lt "$(( 10#$bv ))" ] && return 1
  done
  return 1
}

# release_anchor_hunk_lines PARENT HEAD PATH SIGN
# The +/- body lines of a single-path unified diff, with the SIGN stripped.
# Everything before the first `@@` is dropped rather than filtered by pattern:
# `--- a/x` and a removed content line `--foo` both start with `---` in a raw
# diff, so a `grep -Ev '^---'` header filter silently eats real deletions.
# `--no-renames` is a PROVEN NO-OP here (#397): the single-path pathspec already
# keeps git from pairing a rename, because the counterpart is outside it —
# output is byte-identical with and without the flag. It is present because that
# immunity is a property of the PATHSPEC, so widening or dropping the pathspec
# in a future refactor would silently reintroduce the collapse; the flag is what
# would keep this function sound if that happened.
release_anchor_hunk_lines() {
  git diff --unified=0 --no-renames "$1" "$2" -- "$3" 2>/dev/null \
    | sed -n '/^@@/,$p' \
    | grep -v '^@@' \
    | sed -n "s/^[$4]//p"
}

# release_anchor_normalize   (diff body lines on stdin)
# Collapse every SemVer token to a fixed placeholder so a pure version
# substitution normalises to the byte-identical line it replaced. Also collapses
# the BACKSLASH-ESCAPED forms (`0\.32\.0`, `0\\.32\\.0`) that the two version-lock
# test files carry inside regexes — without this they read as content changes.
release_anchor_normalize() {
  sed -E 's/[0-9]+\\*\.[0-9]+\\*\.[0-9]+/@SEMVER@/g'
}

main() {
  local head_arg="${1:-}" work_dir="${2:-.}"
  if [ -z "$head_arg" ]; then
    printf 'release-anchor: usage: release-anchor.sh <head-oid> [<working-dir>]\n' >&2
    release_anchor_emit "${head_arg:-HEAD}" none usage_error
    return 2
  fi
  if ! cd "$work_dir" 2>/dev/null; then
    release_anchor_emit "$head_arg" none working_dir_unusable
    return 2
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    release_anchor_emit "$head_arg" none not_a_git_worktree
    return 2
  fi

  local head
  if ! head="$(git rev-parse --verify --quiet "${head_arg}^{commit}" 2>/dev/null)" || [ -z "$head" ]; then
    release_anchor_emit "$head_arg" none head_not_resolvable
    return 2
  fi

  # (1) exactly one parent — a merge commit is never inert.
  local parents parent count
  parents="$(git rev-list --parents -n 1 "$head" 2>/dev/null)" || parents=""
  count="$(printf '%s\n' "$parents" | tr ' ' '\n' | grep -c '[0-9a-f]')"
  if [ "$count" != "2" ]; then
    release_anchor_emit "$head" none not_single_parent
    return 0
  fi
  parent="$(printf '%s\n' "$parents" | cut -d' ' -f2)"

  # (2) the subject is EXACTLY a release subject.
  local subject version
  subject="$(git log -1 --format=%s "$head" 2>/dev/null)"
  version="$(release_anchor_subject_version "$subject")"
  if [ -z "$version" ]; then
    release_anchor_emit "$head" none subject_not_release
    return 0
  fi

  # (3) tolerance depth is exactly 1 — a stack of release commits is not a
  # single inert commit, and chaining them would let an attacker push code in
  # commit N-2 and hide it behind two release subjects.
  if [ -n "$(release_anchor_subject_version "$(git log -1 --format=%s "$parent" 2>/dev/null)")" ]; then
    release_anchor_emit "$head" none release_commit_chain
    return 0
  fi

  # (4) the changed path set is non-empty and a SUBSET of the six surfaces.
  # `--no-renames`: rename detection is ON by default and collapses a rename to
  # its DESTINATION path only, so the deleted SOURCE reaches this set nowhere. A
  # subset test is only sound over a TOTAL set — a collapsed rename is vacuously
  # a subset, satisfied by exactly the path it omits. `git mv src/guard.sh
  # CHANGELOG.md` inside an otherwise-clean bump therefore reported six
  # surfaces, the permitted shape, and rode the trust gate with an arbitrary
  # deletion attached (#397). Same defect as #393 (lib/code_fixer_contract.py).
  local changed surfaces stray
  changed="$(git diff --name-only --no-renames "$parent" "$head" -- 2>/dev/null)"
  if [ -z "$changed" ]; then
    release_anchor_emit "$head" none empty_release_commit
    return 0
  fi
  surfaces="$(release_anchor_surfaces)"
  stray="$(printf '%s\n' "$changed" | while IFS= read -r p; do
             [ -n "$p" ] || continue
             printf '%s\n' "$surfaces" | grep -Fxq -- "$p" || printf '%s\n' "$p"
           done)"
  if [ -n "$stray" ]; then
    release_anchor_emit "$head" none non_version_paths
    return 0
  fi

  # (5) the canonical manifest version strictly ADVANCES, to the subject's
  # version. A "release" that does not move the ratchet is not a release.
  local old_ver new_ver
  old_ver="$(git show "$parent:$RELEASE_ANCHOR_MANIFEST" 2>/dev/null | release_anchor_manifest_version)"
  new_ver="$(git show "$head:$RELEASE_ANCHOR_MANIFEST" 2>/dev/null | release_anchor_manifest_version)"
  if [ -z "$old_ver" ] || [ -z "$new_ver" ]; then
    release_anchor_emit "$head" none manifest_unreadable
    return 0
  fi
  if [ "$new_ver" != "$version" ]; then
    release_anchor_emit "$head" none subject_version_mismatch
    return 0
  fi
  if ! release_anchor_semver_gt "$new_ver" "$old_ver"; then
    release_anchor_emit "$head" none version_not_advanced
    return 0
  fi

  # Bound the whole probe so a pathological commit cannot turn the trust gate
  # into an unbounded diff walk.
  local total
  total="$(git diff --unified=0 --no-renames "$parent" "$head" -- 2>/dev/null | wc -l | tr -d '[:space:]')"
  # An unreadable size is treated as OVER the bound, not under it: this is a
  # trust gate, so an unusable measurement must never widen what it tolerates.
  case "$total" in ''|*[!0-9]*) total=$(( RELEASE_ANCHOR_MAX_DIFF_LINES + 1 )) ;; esac
  if [ "$total" -gt "$RELEASE_ANCHOR_MAX_DIFF_LINES" ]; then
    release_anchor_emit "$head" none diff_too_large
    return 0
  fi

  # (6)/(7) per-path content shape. The loop variable is `changed_path`, not
  # `path`: in zsh `path` IS `$PATH`, so `local path` would empty the command
  # search path and turn the very next `git` call into `command not found`.
  local changed_path removed added chg_added bad
  bad=""
  while IFS= read -r changed_path; do
    [ -n "$changed_path" ] || continue
    if [ "$changed_path" = "$RELEASE_ANCHOR_CHANGELOG" ]; then
      # (7) insertion-only, bounded, and every inserted line is release-section
      # shaped: the dated header, a bullet, the pending-notes stub, or blank.
      if [ -n "$(release_anchor_hunk_lines "$parent" "$head" "$changed_path" -)" ]; then
        bad="changelog_deletions"; break
      fi
      chg_added="$(release_anchor_hunk_lines "$parent" "$head" "$changed_path" +)"
      if [ "$(printf '%s\n' "$chg_added" | wc -l | tr -d '[:space:]')" -gt "$RELEASE_ANCHOR_MAX_CHANGELOG_LINES" ]; then
        bad="changelog_too_large"; break
      fi
      if printf '%s\n' "$chg_added" \
           | grep -qEv "^(## \[${version//./\\.}\] .*|[-*] .*|_.*|[[:space:]]*)$"; then
        bad="changelog_shape"; break
      fi
      continue
    fi
    # (6) the removed and added line SEQUENCES must be identical once SemVer
    # tokens are normalised away. Sequence, not set: a multiset comparison would
    # let an attacker REORDER lines of tests/goal.test.sh — executable code —
    # while every individual line stayed byte-identical.
    removed="$(release_anchor_hunk_lines "$parent" "$head" "$changed_path" - | release_anchor_normalize)"
    added="$(release_anchor_hunk_lines "$parent" "$head" "$changed_path" + | release_anchor_normalize)"
    if [ "$removed" != "$added" ]; then
      bad="content_not_version_only"; break
    fi
    if [ -z "$removed" ]; then
      bad="content_not_version_only"; break
    fi
  done <<EOF
$changed
EOF

  if [ -n "$bad" ]; then
    release_anchor_emit "$head" none "$bad"
    return 0
  fi

  release_anchor_emit "$parent" tolerated inert_release_commit "$version"
  return 0
}

main "$@"
