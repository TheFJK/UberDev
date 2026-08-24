#!/usr/bin/env bash
# tests/solve-claim.test.sh — release version surface #6 + the #123 B1 regex guard.
#
# THIS FILE CANNOT BE DELETED WITHOUT A PRODUCTION CHANGE.
# plugins/uberdev/lib/bump-version.sh:221 binds it into the release surface
# inventory and :224-233 fails CLOSED — `exit $EXIT_DRIFT`, "not an UberDev repo
# root (version surfaces missing)" — if it is merely unreadable. :268-269 and
# :334-335 then grep it for the two anchors below. It is also named by
# merge-pipeline/lib/release-anchor.sh:74 and AGENTS.md:46. Removing or renaming
# it refuses every release, every /merge release-anchor pass and every /goal
# version bump. A true removal is a coordinated change across 9 files.
#
# The ~99 structural-grep rows this file used to carry were retired: they
# asserted that particular prose still appeared in solve-launcher.sh, two
# SKILL.md files and two command docs, so they reddened on every reword and
# caught no runtime defect. What survives is the release ratchet plus the one
# block that actually executes something.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERGE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        pattern: $pattern"
    echo "        file:    $file"
    FAIL=$((FAIL + 1))
  fi
}

# Shared structural-assertion helpers (assert_version_bump for the version-bump
# block). Fail-loud guard per #209: a missing/unreadable helper aborts rc=2,
# not vacuous-green.
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

# --- release ratchet ----------------------------------------------------------
# Both lines below are read by bump-version.sh as literal anchors. The echo text
# and the assert_version_bump argument must carry the CURRENT version, and both
# must be bumped together every release.
echo "== Version bump 0.56.0 -> 0.56.1 propagated =="
assert_version_bump "$REPO_ROOT" "0.56.1"

# --- #123 B1: closing-keyword regex left-anchor -------------------------------
# Kept because it EXECUTES the regex rather than only asserting its presence,
# and because the assert_grep immediately below pins the executed copy to the
# shipped bytes — without that pairing the runtime checks would drift free of
# merge-pipeline/SKILL.md and stay green after the shipped regex changed.
#
# The regex in merge-pipeline Step 3.4 MUST require start-of-input or a non-word
# char before the keyword. Without the left anchor, `preclose #42` and
# `postfix #100` are read as closing references and the dispatcher strips the
# uberdev:active label from those issues — see #123 B1.
echo "== #123 B1: closing-keyword regex left-anchor (rejects preclose/postfix/unresolve) =="
assert_grep "$MERGE_PIPELINE" \
  "'\\(\\^\\|\\[\\^\\[:alnum:\\]_-\\]\\)\\(close\\[sd\\]\\?\\|fix\\(e\\[sd\\]\\)\\?\\|resolve\\[sd\\]\\?\\)" \
  "B1: closing-keyword regex carries left-anchor (^|[^[:alnum:]_-]) prefix"

B1_BAD_INPUT='I tried to preclose #42 first, then unresolve #50, postfix #100 after.'
B1_MATCHES=$(printf '%s' "$B1_BAD_INPUT" \
  | grep -oiE '(^|[^[:alnum:]_-])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
  | grep -oE '#[0-9]+' \
  | tr -d '#' \
  | awk '!seen[$0]++' \
  | sort -u | tr '\n' ',' | sed 's/,$//')
if [[ -z "$B1_MATCHES" ]]; then
  echo "  PASS  B1: preclose/unresolve/postfix #N do NOT false-match the closing-keyword regex"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B1: closing-keyword regex matched issues ($B1_MATCHES) in '$B1_BAD_INPUT' — left anchor missing or broken"
  FAIL=$((FAIL + 1))
fi

# Positive smoke: legitimate `Closes #42` MUST still match. Guards against
# over-tightening the anchor to the point that the happy path breaks.
B1_GOOD_INPUT='Closes #42. Fixes #43. Resolved #44.'
B1_GOOD_MATCHES=$(printf '%s' "$B1_GOOD_INPUT" \
  | grep -oiE '(^|[^[:alnum:]_-])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
  | grep -oE '#[0-9]+' \
  | tr -d '#' \
  | awk '!seen[$0]++' \
  | sort -u | tr '\n' ',' | sed 's/,$//')
if [[ "$B1_GOOD_MATCHES" == "42,43,44" ]]; then
  echo "  PASS  B1: Closes/Fixes/Resolved #N still extract correctly (regression guard)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B1: positive happy-path regression — expected 42,43,44, got '$B1_GOOD_MATCHES'"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Summary: $PASS pass, $FAIL fail"
exit $FAIL
