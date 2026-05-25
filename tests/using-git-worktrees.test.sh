#!/usr/bin/env bash
# Shape-check harness for skills/using-git-worktrees/SKILL.md.
#
# Regression guard for #194: the global-directory worktree path was built with a
# literal tilde inside double quotes —
#   path="~/.config/uberdev/worktrees/$project/$BRANCH_NAME"
# Tilde does NOT expand inside double quotes nor on the RHS of a quoted
# assignment (verified bash AND zsh), so `git worktree add "$path"` created a
# directory literally named "~" under the cwd instead of under $HOME. The case
# pattern on the same arm was also tilde-fragile. Fix: expand explicitly with
# ${HOME} and match LOCATION in both its literal-"~/" and expanded-"$HOME/"
# forms. These assertions lock that in.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SKILL="$REPO_ROOT/plugins/uberdev/skills/using-git-worktrees/SKILL.md"

# Pre-flight: refuse to run if the asserted-against file is missing.
if [ ! -r "$SKILL" ]; then
  printf 'FATAL: required file missing or unreadable: %s\n' "$SKILL" >&2
  exit 2
fi

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s\n' "$file" >&2
    printf '        pattern: %s\n' "$pattern" >&2
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s\n' "$file" >&2
    printf '        pattern: %s (should NOT match)\n' "$pattern" >&2
  else
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  fi
}

echo "== #194: global-dir worktree path uses \${HOME}, not a literal tilde =="
# Positive: the worktree-add path assignment is built with ${HOME} expansion.
assert_grep "$SKILL" 'path="\$\{HOME\}/\.config/uberdev/worktrees/' \
  "W1.path-uses-HOME-expansion"
# Negative (the crown-jewel regression guard): no path assignment whose RHS
# begins with a quoted literal tilde — that is the exact #194 bug.
assert_no_grep "$SKILL" 'path="~' \
  "W2.no-quoted-literal-tilde-path"
# Positive: the global-dir case arm matches LOCATION in its expanded $HOME form.
assert_grep "$SKILL" '"\$HOME"/\.config/uberdev/worktrees/' \
  "W3.case-matches-HOME-form"
# Positive: ...and also in the literal "~/" form the menu actually produces, so
# the global branch is still selected when LOCATION arrives unexpanded.
assert_grep "$SKILL" '"~/\.config/uberdev/worktrees/"' \
  "W4.case-matches-literal-tilde-form"
# Defensive (surfaced in #205 review): the case block must fail loudly on an
# unrecognized LOCATION rather than silently leave $path unset for git worktree.
assert_grep "$SKILL" 'unrecognized worktree LOCATION' \
  "W5.case-has-loud-default-arm"

echo
echo "== Summary =="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
