#!/usr/bin/env bash
# tests/goal-version-bump.test.sh — /goal must never land a PR that does not
# advance the project version (issue #364).
#
# THE BUG THIS LOCKS. `skills/solve-fleet/workflow.js` forbids every fleet
# solver from bumping the version — correctly, because N solvers off one base
# all resolve the SAME next version and the duplicate change auto-merges
# without a conflict (project_uberdev_merge_version_collision). Nothing
# downstream added the bump back, so `/ubergoal` auto-merged PRs that touched
# zero version surfaces. It failed SILENTLY: the two CI version-lock tests
# assert the surfaces agree with EACH OTHER, not that the version ADVANCED, so
# an unbumped landing leaves everything consistently at the old version, CI
# stays green, and the marketplace never serves the update.
#
# Sections:
#   V1 — pure resolvers: SemVer parse/compare, next-version, conventional-commit
#        bump kind, untrusted-text sanitiser, CHANGELOG entry derivation
#   V2 — an unbumped PR gets EXACTLY ONE `chore(release):` commit and all seven
#        surfaces advance; the CHANGELOG stub is replaced by the PR-derived entry
#   V3 — an already-bumped PR is a no-op (no double bump)
#   V4 — two PRs landing in one cycle get CONSECUTIVE versions, not the same one
#   V5 — fail-closed: bump-version.sh refuses -> rc 1, nothing pushed, audit row
#   V6 — a repo with no version ratchet is skipped (rc 0), nothing pushed
#   V7 — a cross-repository (fork) PR fails closed rather than pushing to origin
#   V8 — BEHAVIOURAL over the REAL watch-lane region: ensure-fails => /merge is
#        NOT dispatched and the PR stays green; ensure pushed-this-pass (rc 2)
#        and checks-still-running both defer instead of burning a merge attempt;
#        ensure-ok + settled CI => dispatch happens, and both gates run first
#   V9 — structural: the ordering, the three-way exit status, a single guarded
#        merge-dispatch site, and the /merge-side trust-head resolution the push
#        depends on
#   V10 — _uberdev_goal_pr_checks_pending withholds on pending, falls through on
#        an unusable probe (it can never AUTHORISE a merge)
#   V11 — the SemVer step follows the PR's COMMITS, not just its title
#
# Portable: bash + git + coreutils + sed/awk/grep only (no python3, no zsh, no
# jq), so it runs on BOTH CI jobs (ubuntu-latest and windows-latest Git Bash).
#
# `set -e` intentionally NOT enabled: a failed assertion must not abort the rest
# of the suite.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT
GOAL_LIB="$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
GOAL_WATCH="$CLAUDE_PLUGIN_ROOT/lib/goal-watch.sh"
BUMP_SH="$CLAUDE_PLUGIN_ROOT/lib/bump-version.sh"
export GOAL_LIB

for f in "$GOAL_LIB" "$GOAL_WATCH" "$BUMP_SH"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done
if ! command -v git >/dev/null 2>&1; then
  printf 'FATAL: git is required by this fixture\n' >&2
  exit 2
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then pass "$label"
  else fail "$label (got=[$got] want=[$want])"; fi
}

assert_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then pass "$label"
  else fail "$label — $file does not match /$pattern/"; fi
}

assert_no_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — $file matches /$pattern/ but must not"
  else pass "$label"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# V1 — pure resolvers. No git, no gh, no network.
# ---------------------------------------------------------------------------
echo "== V1: SemVer + conventional-commit resolvers =="
v1() { bash -c '. "$GOAL_LIB"; '"$1"; }

assert_eq "$(v1 '_uberdev_goal_semver_parts 1.2.3')" "1 2 3" "V1.parts: 1.2.3 -> 1 2 3"
v1 '_uberdev_goal_semver_parts 1.2 >/dev/null'   ; assert_eq "$?" "1" "V1.parts: 1.2 is rejected (rc 1)"
v1 '_uberdev_goal_semver_parts 1.2.3.4 >/dev/null'; assert_eq "$?" "1" "V1.parts: 1.2.3.4 is rejected (rc 1)"
v1 '_uberdev_goal_semver_parts v1.2.3 >/dev/null' ; assert_eq "$?" "1" "V1.parts: a 'v' prefix is rejected (rc 1)"

v1 '_uberdev_goal_semver_gt 1.2.4 1.2.3'; assert_eq "$?" "0" "V1.gt: 1.2.4 > 1.2.3"
v1 '_uberdev_goal_semver_gt 1.2.3 1.2.4'; assert_eq "$?" "1" "V1.gt: 1.2.3 is NOT > 1.2.4"
v1 '_uberdev_goal_semver_gt 1.2.3 1.2.3'; assert_eq "$?" "1" "V1.gt: equal is NOT greater"
v1 '_uberdev_goal_semver_gt 1.0.0 0.99.99'; assert_eq "$?" "0" "V1.gt: major dominates minor/patch"
# The load-bearing case: a PR branched BEFORE two releases landed sits BELOW its
# base. A plain `!=` would read that as "already bumped" and let it land unbumped.
v1 '_uberdev_goal_semver_gt 0.41.0 0.41.3'; assert_eq "$?" "1" \
  "V1.gt: a PR BEHIND its base is not 'already bumped' (the != trap)"
# Zero-padded components must not be read as octal (10# base forcing).
assert_eq "$(v1 '_uberdev_goal_next_version 0.9.8 patch')" "0.9.9" "V1.next: leading-zero major stays base-10"

assert_eq "$(v1 '_uberdev_goal_next_version 0.41.3 patch')" "0.41.4" "V1.next: patch"
assert_eq "$(v1 '_uberdev_goal_next_version 0.41.3 minor')" "0.42.0" "V1.next: minor resets patch"
assert_eq "$(v1 '_uberdev_goal_next_version 0.41.3 major')" "1.0.0"  "V1.next: major resets minor+patch"
v1 '_uberdev_goal_next_version 0.41.3 sideways >/dev/null'; assert_eq "$?" "1" "V1.next: unknown kind is rejected"

assert_eq "$(v1 '_uberdev_goal_bump_kind "feat(goal): x" ""')"  "minor" "V1.kind: feat: -> minor"
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" ""')"   "patch" "V1.kind: fix: -> patch"
assert_eq "$(v1 '_uberdev_goal_bump_kind "docs: x" ""')"        "patch" "V1.kind: docs: -> patch"
assert_eq "$(v1 '_uberdev_goal_bump_kind "chore: x" ""')"       "patch" "V1.kind: chore: -> patch"
assert_eq "$(v1 '_uberdev_goal_bump_kind "feat(goal)!: x" ""')" "major" "V1.kind: the ! marker -> major"
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix: x" "body

BREAKING CHANGE: gone"')" "major" "V1.kind: a BREAKING CHANGE footer -> major"
# The COMMITS are part of the predicate. A /goal PR title is written by the
# solver agent, not a release engineer: title-only derivation silently ships a
# feature as a patch release.
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" "body" "fix(a): one
feat(b): two" ""')" "minor" \
  "V1.kind: a feat: COMMIT under a fix: title -> minor (not a silent under-release)"
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" "body" "fix(a): one
refactor(b)!: two" ""')" "major" \
  "V1.kind: a ! marker on a COMMIT subject -> major"
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" "body" "fix(a): one" "text

BREAKING CHANGE: gone"')" "major" \
  "V1.kind: a BREAKING CHANGE footer in a COMMIT body -> major"
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" "body" "fix(a): one
chore(b): two" ""')" "patch" \
  "V1.kind: ordinary commits under a fix: title stay a patch"
# A commit BODY line that merely mentions a type must not be read as a subject —
# only the tagged subject stream feeds the feat:/! probes.
assert_eq "$(v1 '_uberdev_goal_bump_kind "fix(goal): x" "body" "fix(a): one" "we considered
feat: something else here"')" "patch" \
  "V1.kind: prose inside a commit BODY does not promote the release"

# Untrusted title: a leading markdown header would forge a CHANGELOG section and
# break the NEXT release's drift pre-check; a backslash would be re-escaped by
# `awk -v`. Both must be stripped.
assert_eq "$(v1 '_uberdev_goal_sanitize_release_text "## [9.9.9] pwned"')" "[9.9.9] pwned" \
  "V1.sanitize: a leading markdown header marker is stripped"
assert_eq "$(v1 '_uberdev_goal_sanitize_release_text "a\\\\nb"')" "anb" \
  "V1.sanitize: backslashes are stripped (awk -v escape processing)"
assert_eq "$(v1 '_uberdev_goal_release_entry 363 "fix(goal): stop unbumped merges" "text
Closes #364
closes #12"')" "- fix(goal): stop unbumped merges (#363; closes #12, #364)" \
  "V1.entry: derives the bullet from the PR title + the issue refs in its body"
assert_eq "$(v1 '_uberdev_goal_release_entry 363 "" "no refs"')" "- PR #363 (#363)" \
  "V1.entry: an empty title degrades to a PR reference, never an empty bullet"

# A branch name arrives from gh and goes straight into `git` argv.
v1 '_uberdev_goal_validate_ref "fix/364-thing"'; assert_eq "$?" "0" "V1.ref: an ordinary branch name is accepted"
v1 '_uberdev_goal_validate_ref "--upload-pack=touch /tmp/pwn"'; assert_eq "$?" "1" \
  "V1.ref: a leading dash is refused (git would parse it as an option)"
v1 '_uberdev_goal_validate_ref "a b"'; assert_eq "$?" "1" "V1.ref: whitespace is refused"
v1 '_uberdev_goal_validate_ref ""';    assert_eq "$?" "1" "V1.ref: an empty ref is refused"

# ---------------------------------------------------------------------------
# Git + gh fixture builders.
# ---------------------------------------------------------------------------
git_id() {   # <repo>  — local identity so the fixture never depends on ~/.gitconfig
  git -C "$1" config user.email "fixture@uberdev.invalid"
  git -C "$1" config user.name  "UberDev Fixture"
  git -C "$1" config commit.gpgsign false
}

write_surfaces() {  # <root> <version> <prev-version>
  local root="$1" ver="$2" prev="$3"
  mkdir -p "$root/plugins/uberdev/.claude-plugin" "$root/.claude-plugin" \
           "$root/tests"
  printf '{\n  "name": "uberdev",\n  "version": "%s"\n}\n' "$ver" \
    > "$root/plugins/uberdev/.claude-plugin/plugin.json"
  printf '{\n  "name": "uberdev",\n  "plugins": [\n    {\n      "name": "uberdev",\n      "version": "%s"\n    }\n  ]\n}\n' "$ver" \
    > "$root/.claude-plugin/marketplace.json"
  printf '# Fixture\n\n[![Version](https://img.shields.io/badge/version-%s-blue)](./CHANGELOG.md)\n' "$ver" \
    > "$root/README.md"
  {
    printf '# Changelog\n\n'
    printf '## [%s] — 2026-01-02\n\n- Something recent.\n\n' "$ver"
    printf '## [%s] — 2026-01-01\n\n- Initial fixture release.\n' "$prev"
  } > "$root/CHANGELOG.md"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "== G20: version bump locked (%s) =="\n' "$ver"
    printf 'assert_version_bump "$REPO_ROOT" "%s"\n' "$ver"
  } > "$root/tests/goal.test.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "== Version bump %s -> %s propagated =="\n' "$prev" "$ver"
    printf 'assert_version_bump "$REPO_ROOT" "%s"\n' "$ver"
  } > "$root/tests/solve-claim.test.sh"
}

# new_sandbox <name> <version> [--no-ratchet] — build origin.git + a work clone
# whose `main` carries the version surfaces, plus a gh-fixture dir and a gh shim
# on PATH. Echoes the sandbox root.
new_sandbox() {
  local name="$1" ver="$2" mode="${3:-}" root seed
  root="$WORK/$name"
  seed="$root/seed"
  mkdir -p "$seed" "$root/bin" "$root/ghfix" "$root/state"
  if [ "$mode" = "--no-ratchet" ]; then
    printf '# plain repo, no uberdev version ratchet\n' > "$seed/README.md"
  else
    write_surfaces "$seed" "$ver" "0.0.1"
  fi
  git -C "$seed" init -q
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  git_id "$seed"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "seed"
  git init -q --bare "$root/origin.git"
  git -C "$seed" remote add origin "$root/origin.git"
  git -C "$seed" push -q origin main
  git clone -q "$root/origin.git" "$root/work"
  git_id "$root/work"
  # gh shim: answers the two calls the helper makes, from on-disk fixtures.
  cat > "$root/bin/gh" <<'GHSHIM'
#!/usr/bin/env bash
pr=""
for a in "$@"; do
  case "$a" in [0-9]*) pr="$a"; break ;; esac
done
printf '%s\n' "$*" >> "$GH_FIX/calls.txt"
case "$*" in
  *"--json statusCheckRollup"*)  cat "$GH_FIX/pr-$pr.checks" 2>/dev/null || printf '0\n'; exit 0 ;;
  *"--json commits"*)            cat "$GH_FIX/pr-$pr.commits" 2>/dev/null; exit 0 ;;
  *"--json body"*)               cat "$GH_FIX/pr-$pr.body" 2>/dev/null; exit 0 ;;
  *headRefName*)                 cat "$GH_FIX/pr-$pr.meta" 2>/dev/null; exit 0 ;;
esac
exit 1
GHSHIM
  chmod +x "$root/bin/gh"
  printf '%s\n' "$root"
}

# add_pr <root> <pr> <branch> <base> <title> <body> [cross]
add_pr() {
  local root="$1" pr="$2" branch="$3" base="$4" title="$5" body="$6" cross="${7:-false}"
  git -C "$root/work" checkout -q -b "$branch" "origin/$base"
  printf 'change for PR %s\n' "$pr" > "$root/work/pr-$pr.txt"
  git -C "$root/work" add -A
  git -C "$root/work" commit -q -m "$title"
  git -C "$root/work" push -q origin "$branch"
  git -C "$root/work" checkout -q "$base"
  printf '%s\t%s\t%s\t%s\n' "$branch" "$base" "$cross" "$title" > "$root/ghfix/pr-$pr.meta"
  printf '%s\n' "$body" > "$root/ghfix/pr-$pr.body"
  # Default commit projection: the single commit this fixture actually made.
  # `S|` tags a commit SUBJECT, `B|` one line of a commit BODY — the same shape
  # `_uberdev_goal_fetch_pr_commits` asks gh for.
  printf 'S|%s\nB|\n' "$title" > "$root/ghfix/pr-$pr.commits"
}

# set_pr_commits <root> <pr> <tagged-lines> — override the commit projection so
# a PR's TITLE and its COMMITS can disagree (the #364-review case).
set_pr_commits() { printf '%s\n' "$3" > "$1/ghfix/pr-$2.commits"; }

# set_pr_checks <root> <pr> <pending-count> — the statusCheckRollup projection
# `_uberdev_goal_pr_checks_pending` reads (gh runs the --jq server-side, so the
# shim returns the already-reduced count). Absent file => 0 via the shim default.
set_pr_checks() { printf '%s\n' "$3" > "$1/ghfix/pr-$2.checks"; }

# run_ensure <root> <pr> — run the REAL helper with cwd = the work clone.
# Captures stderr into $root/state/ensure-<pr>.err and returns its rc.
run_ensure() {
  local root="$1" pr="$2"
  ( cd "$root/work" && \
    PATH="$root/bin:$PATH" \
    GH_FIX="$root/ghfix" \
    UBERDEV_TMPDIR="$root/state" \
    UBERDEV_GOAL_ID="goaltestvb" \
    bash -c '. "$GOAL_LIB"; _uberdev_goal_ensure_version_bump "$1"' _ "$pr" \
      2> "$root/state/ensure-$pr.err" )
}

origin_branch_commits() {  # <root> <branch>
  git -C "$1/origin.git" rev-list --count "refs/heads/$2" 2>/dev/null || printf 'ERR'
}
origin_file() {            # <root> <branch> <path>
  # Resolve the blob by OID — deliberately NOT `git show <rev>:<path>`.
  #
  # Git for Windows rewrites an argument containing `:` when the segment after
  # the colon looks like a POSIX path, and a LEADING DOT is exactly the marker
  # its path-LIST heuristic keys on. On windows-latest that made
  # `git show <rev>:.claude-plugin/marketplace.json` resolve to nothing, and the
  # surface assertion read as "marketplace.json was never bumped". Exactly one of
  # the seven surfaces failed, because it is the only path that starts with a
  # dot — that asymmetry is the tell.
  #
  # Suppressing the conversion is NOT the fix: `MSYS_NO_PATHCONV=1` /
  # `MSYS2_ARG_CONV_EXCL='*'` also stop `-C <dir>` being translated, so all seven
  # reads fail instead of one (observed). `ls-tree` + `cat-file` put no colon in
  # argv at all, on any platform.
  local sha
  sha="$(git -C "$1/origin.git" ls-tree -r "refs/heads/$2" 2>/dev/null \
           | awk -F'\t' -v p="$3" '$2 == p { split($1, f, " "); print f[3]; exit }')"
  [ -n "$sha" ] || return 1
  git -C "$1/origin.git" cat-file blob "$sha" 2>/dev/null
}
origin_subject() {         # <root> <branch>
  git -C "$1/origin.git" log -1 --format=%s "refs/heads/$2" 2>/dev/null
}
audit_log() { printf '%s/state/goal-goaltestvb.jsonl' "$1"; }

# ---------------------------------------------------------------------------
# V2 — an unbumped PR is bumped: one release commit, all seven surfaces move.
# ---------------------------------------------------------------------------
echo
echo "== V2: an unbumped PR gets exactly one chore(release): commit and all 7 surfaces advance =="
S2="$(new_sandbox v2 1.2.3)"
add_pr "$S2" 101 "fix/101-thing" main "fix(goal): stop unbumped merges" "body
Closes #364"
before="$(origin_branch_commits "$S2" fix/101-thing)"
run_ensure "$S2" 101; rc=$?
assert_eq "$rc" "2" "V2.rc: a bump that was PUSHED reports rc 2 (defer /merge one pass — the push restarted CI)"
after="$(origin_branch_commits "$S2" fix/101-thing)"
assert_eq "$((after - before))" "1" "V2.commits: EXACTLY ONE commit was pushed (no double bump, no stray commits)"
assert_eq "$(origin_subject "$S2" fix/101-thing)" "chore(release): v1.2.4" \
  "V2.subject: the pushed commit is a conventional chore(release) for the resolved version"
# Prove the READ works before asserting on what it returned. An unreadable blob
# and an unbumped surface both make the greps below count 0, and they demand
# opposite fixes — the Windows argv-mangling class (see origin_file) presented
# as "marketplace.json was never bumped" for exactly that reason.
for v2_surface in plugins/uberdev/.claude-plugin/plugin.json .claude-plugin/marketplace.json \
                  README.md CHANGELOG.md \
                  tests/goal.test.sh tests/solve-claim.test.sh; do
  if [ -n "$(origin_file "$S2" fix/101-thing "$v2_surface")" ]; then
    pass "V2.readable: $v2_surface reads back from the pushed branch"
  else
    fail "V2.readable: origin_file returned NOTHING for $v2_surface — the blob READ is broken (argv mangling / bad ref), not the bump"
  fi
done
# All six CI-locked surfaces must carry the new version on the PR branch.
assert_eq "$(origin_file "$S2" fix/101-thing plugins/uberdev/.claude-plugin/plugin.json | grep -c '"version": "1\.2\.4"')" "1" \
  "V2.surface1: plugin.json (canonical SSOT)"
assert_eq "$(origin_file "$S2" fix/101-thing .claude-plugin/marketplace.json | grep -c '"version": "1\.2\.4"')" "1" \
  "V2.surface2: marketplace.json"
assert_eq "$(origin_file "$S2" fix/101-thing README.md | grep -c 'version-1\.2\.4-blue')" "1" \
  "V2.surface3: the README version badge"
assert_eq "$(origin_file "$S2" fix/101-thing CHANGELOG.md | awk '/^## \[/ {print; exit}' | cut -c1-10)" "## [1.2.4]" \
  "V2.surface4: the CHANGELOG's topmost section is the new version"
assert_eq "$(origin_file "$S2" fix/101-thing tests/goal.test.sh | grep -c 'version bump locked (1\.2\.4)')" "1" \
  "V2.surface5: the tests/goal.test.sh version lock"
assert_eq "$(origin_file "$S2" fix/101-thing tests/solve-claim.test.sh | grep -c 'Version bump 1\.2\.3 -> 1\.2\.4 propagated')" "1" \
  "V2.surface6: the tests/solve-claim.test.sh version lock"
# The stub bump-version.sh writes is a placeholder, not release notes — it must
# be replaced with content derived from the PR before the commit is made.
S2_CL="$WORK/v2-changelog.md"
origin_file "$S2" fix/101-thing CHANGELOG.md > "$S2_CL"
assert_no_grep "$S2_CL" '_Release notes pending' "V2.changelog: the pending-release stub is GONE from the committed CHANGELOG"
assert_grep "$S2_CL" '^- fix\(goal\): stop unbumped merges \(#101; closes #364\)$' \
  "V2.changelog: the stub is replaced by the PR-derived entry"
assert_grep "$(audit_log "$S2")" '"event":"goal_version_bumped"' "V2.audit: a goal_version_bumped row is emitted"
assert_grep "$(audit_log "$S2")" '"action":"bumped","from":"1.2.3","to":"1.2.4","kind":"patch"' \
  "V2.audit: the row names the resolved from/to/kind"
# The /goal session's own checkout must be untouched: the bump runs in a
# throwaway detached worktree (project_uberdev_turbo_main_index_pollution).
assert_eq "$(git -C "$S2/work" status --porcelain | wc -l | tr -d ' ')" "0" \
  "V2.hygiene: the /goal checkout's working tree is left clean"
assert_eq "$(git -C "$S2/work" worktree list | wc -l | tr -d ' ')" "1" \
  "V2.hygiene: no throwaway worktree is left registered"

# ---------------------------------------------------------------------------
# V3 — an already-bumped PR is a no-op.
# ---------------------------------------------------------------------------
echo
echo "== V3: an already-bumped PR is a no-op (the helper must not double-bump) =="
S3="$(new_sandbox v3 1.2.3)"
add_pr "$S3" 102 "feat/102-thing" main "feat(goal): a thing" "body"
# Hand-bump the PR branch the way a release-aware author would.
git -C "$S3/work" checkout -q feat/102-thing
bash "$BUMP_SH" 1.3.0 --repo-root "$S3/work" >/dev/null 2>&1
git -C "$S3/work" commit -q -a -m "chore(release): v1.3.0"
git -C "$S3/work" push -q origin feat/102-thing
git -C "$S3/work" checkout -q main
before="$(origin_branch_commits "$S3" feat/102-thing)"
run_ensure "$S3" 102; rc=$?
assert_eq "$rc" "0" "V3.rc: an already-bumped PR is accepted with rc 0 — nothing was pushed, so CI is undisturbed"
assert_eq "$(origin_branch_commits "$S3" feat/102-thing)" "$before" \
  "V3.no-op: no second commit was pushed (no double bump)"
assert_eq "$(origin_file "$S3" feat/102-thing plugins/uberdev/.claude-plugin/plugin.json | grep -c '"version": "1\.3\.0"')" "1" \
  "V3.no-op: the author's own version is left exactly as it was"
assert_grep "$(audit_log "$S3")" '"action":"already_bumped"' "V3.audit: the no-op is recorded, not silent"

# ---------------------------------------------------------------------------
# V4 — THE WHOLE POINT: two PRs landing in one cycle get CONSECUTIVE versions.
# ---------------------------------------------------------------------------
echo
echo "== V4: two PRs landed in one cycle get CONSECUTIVE versions, not the same one =="
S4="$(new_sandbox v4 1.2.3)"
add_pr "$S4" 201 "fix/201-a" main "fix(a): first"  "body"
add_pr "$S4" 202 "fix/202-b" main "fix(b): second" "body"
run_ensure "$S4" 201; rc1=$?
assert_eq "$rc1" "2" "V4.first: the lowest PR bumps (rc 2 — pushed this pass)"
assert_eq "$(origin_subject "$S4" fix/201-a)" "chore(release): v1.2.4" "V4.first: PR 201 -> v1.2.4"
# The serialized lane lands PR 201 before it ever looks at PR 202. Simulate the
# landing, then bump the second PR — it MUST see the new base.
git -C "$S4/origin.git" update-ref refs/heads/main "$(git -C "$S4/origin.git" rev-parse refs/heads/fix/201-a)"
run_ensure "$S4" 202; rc2=$?
assert_eq "$rc2" "2" "V4.second: the next PR bumps (rc 2 — pushed this pass)"
assert_eq "$(origin_subject "$S4" fix/202-b)" "chore(release): v1.2.5" \
  "V4.second: PR 202 -> v1.2.5 — CONSECUTIVE, not a second v1.2.4 (the collision class)"
assert_eq "$(origin_file "$S4" fix/202-b plugins/uberdev/.claude-plugin/plugin.json | grep -c '"version": "1\.2\.5"')" "1" \
  "V4.second: PR 202's manifest carries the consecutive version"
# PR 202 branched off 1.2.3 and was NEVER rebased. Resolving the next version
# from the PR branch instead of the freshly-landed base would hand it 1.2.4 —
# the same version PR 201 just landed, which is the collision this whole lane
# exists to prevent.
assert_eq "$(origin_file "$S4" fix/202-b CHANGELOG.md | awk '/^## \[/ {print; exit}' | cut -c1-10)" "## [1.2.5]" \
  "V4.second: the CHANGELOG section is the consecutive version too"

# ---------------------------------------------------------------------------
# V5 — fail-closed when bump-version.sh refuses.
# ---------------------------------------------------------------------------
echo
echo "== V5: a refused bump FAILS CLOSED — nothing pushed, and /merge must not run =="
S5="$(new_sandbox v5 1.2.3)"
add_pr "$S5" 301 "fix/301-drift" main "fix(x): drifted" "body"
# Introduce the exact drift bump-version.sh refuses on (exit 3): marketplace.json
# disagreeing with the canonical plugin.json.
git -C "$S5/work" checkout -q fix/301-drift
printf '{\n  "name": "uberdev",\n  "plugins": [\n    {\n      "name": "uberdev",\n      "version": "9.9.9"\n    }\n  ]\n}\n' \
  > "$S5/work/.claude-plugin/marketplace.json"
git -C "$S5/work" commit -q -a -m "chore: drift the marketplace manifest"
git -C "$S5/work" push -q origin fix/301-drift
git -C "$S5/work" checkout -q main
before="$(origin_branch_commits "$S5" fix/301-drift)"
run_ensure "$S5" 301; rc=$?
assert_eq "$rc" "1" "V5.rc: a refused bump returns non-zero (the caller must not dispatch /merge)"
assert_eq "$(origin_branch_commits "$S5" fix/301-drift)" "$before" \
  "V5.no-push: nothing was pushed to the PR branch"
assert_grep "$(audit_log "$S5")" '"reason":"version_bump_failed"' "V5.audit: a version_bump_failed row is emitted"
assert_grep "$(audit_log "$S5")" '"stage":"bump_script"' "V5.audit: the row names the stage that refused"
assert_grep "$S5/state/ensure-301.err" 'DRIFT detected' "V5.diagnostic: bump-version.sh's own refusal reason is surfaced"

# ---------------------------------------------------------------------------
# V6 — a repo with no version ratchet has nothing to enforce.
# ---------------------------------------------------------------------------
echo
echo "== V6: a repo with no version ratchet is skipped, not blocked =="
S6="$(new_sandbox v6 0.0.0 --no-ratchet)"
add_pr "$S6" 401 "fix/401-plain" main "fix(x): plain repo" "body"
before="$(origin_branch_commits "$S6" fix/401-plain)"
run_ensure "$S6" 401; rc=$?
assert_eq "$rc" "0" "V6.rc: /goal is not blocked on a repo that carries no version surfaces"
assert_eq "$(origin_branch_commits "$S6" fix/401-plain)" "$before" "V6.no-push: nothing was pushed"
assert_grep "$(audit_log "$S6")" '"action":"skipped","reason":"no_version_ratchet"' \
  "V6.audit: the skip is recorded, not silent"
assert_eq "$([ -e "$S6/ghfix/calls.txt" ] && printf yes || printf no)" "no" \
  "V6.cheap: the no-ratchet probe is offline — gh is never called"

# ---------------------------------------------------------------------------
# V7 — a fork PR cannot be pushed through origin; refuse rather than mis-push.
# ---------------------------------------------------------------------------
echo
echo "== V7: a cross-repository PR fails closed instead of pushing to the base repo =="
S7="$(new_sandbox v7 1.2.3)"
add_pr "$S7" 501 "fix/501-fork" main "fix(x): from a fork" "body" true
before="$(origin_branch_commits "$S7" fix/501-fork)"
run_ensure "$S7" 501; rc=$?
assert_eq "$rc" "1" "V7.rc: a fork PR is refused"
assert_eq "$(origin_branch_commits "$S7" fix/501-fork)" "$before" "V7.no-push: nothing was pushed"
assert_grep "$(audit_log "$S7")" '"stage":"cross_repository"' "V7.audit: the refusal names the cause"

# ---------------------------------------------------------------------------
# V8 — BEHAVIOURAL over the REAL watch-lane region. The region markers in
# lib/goal-watch.sh exist so this runs the shipped bytes, not a copy of them.
# ---------------------------------------------------------------------------
echo
echo "== V8: the REAL merge-dispatch gate — fail-closed and ensure-before-dispatch =="
REGION_AWK="$WORK/region.awk"
cat > "$REGION_AWK" <<'AWK'
BEGIN { inregion = 0; found = 0 }
{
  if (inregion == 0) {
    if ($0 ~ ("^[[:space:]]*# >>> region: " NAME "[[:space:]]*$")) { inregion = 1; found = 1; next }
    next
  }
  if ($0 ~ ("^[[:space:]]*# <<< region: " NAME "[[:space:]]*$")) { exit }
  print
}
END { if (found == 0) exit 3 }
AWK
GATE="$WORK/merge-gate.sh"
if awk -v NAME="merge-dispatch-gate" -f "$REGION_AWK" "$GOAL_WATCH" > "$GATE" \
   && [ -s "$GATE" ] \
   && grep -q '_uberdev_goal_ensure_version_bump' "$GATE" \
   && grep -q '_uberdev_goal_dispatch_merge' "$GATE"; then
  pass "V8.extract: sliced the real merge-dispatch gate out of lib/goal-watch.sh"
else
  fail "V8.extract: could NOT slice the merge-dispatch-gate region (markers moved/removed?)"
fi
if bash -n "$GATE" 2>/dev/null; then
  pass "V8.extract: the sliced region is a syntactically complete block"
else
  fail "V8.extract: the sliced region does not parse standalone"
fi

# run_gate <ensure-rc> [checks-pending-rc] — drive the real region with recording
# stubs. CHECKS_RC defaults to 1 ("nothing pending"), the only state in which
# /merge may run.
run_gate() {
  local ensure_rc="$1" checks_rc="${2:-1}" log="$WORK/gate-$1-${2:-1}.log"
  : > "$log"
  GATE_LOG="$log" ENSURE_RC="$ensure_rc" CHECKS_RC="$checks_rc" bash -c '
    set -u
    GOAL_ID="g1"; pr=""; any_active=0
    _uberdev_goal_batch_green_prs_ordered() { printf "%s\n" 100; }
    uberdev_goal_pr_is_merged()             { return 1; }
    uberdev_goal_review_pr_in_flight()      { return 1; }
    uberdev_goal_should_automerge()         { return 0; }
    _uberdev_goal_ensure_version_bump()     { printf "ensure:%s\n"   "$1" >> "$GATE_LOG"; return "$ENSURE_RC"; }
    _uberdev_goal_pr_checks_pending()       { printf "checks:%s\n"   "$1" >> "$GATE_LOG"; return "$CHECKS_RC"; }
    _uberdev_goal_dispatch_merge()          { printf "dispatch:%s\n" "$1" >> "$GATE_LOG"; return 0; }
    uberdev_goal_pr_state_transition()      { printf "transition:%s:%s->%s\n" "$2" "$3" "$4" >> "$GATE_LOG"; }
    _uberdev_goal_set_batch_terminal_state(){ printf "batch:%s:%s\n" "$2" "$3" >> "$GATE_LOG"; }
    _uberdev_goal_rebase_collision_chain()  { printf "chain:%s\n" "$2" >> "$GATE_LOG"; }
    uberdev_goal_audit()                    { printf "audit:%s:%s\n" "$1" "${2:-}" >> "$GATE_LOG"; }
    . "$1"
  ' _ "$GATE" >/dev/null 2>&1
  cat "$log"
}

GATE_OK="$(run_gate 0)"
case "$GATE_OK" in
  "ensure:100"*"dispatch:100"*) pass "V8.order: the version bump runs BEFORE /merge is dispatched" ;;
  *) fail "V8.order: expected ensure:100 then dispatch:100 (got: [$GATE_OK])" ;;
esac
case "$GATE_OK" in
  *"checks:100"*"dispatch:100"*) pass "V8.order: the CI-settle probe runs BEFORE /merge is dispatched" ;;
  *) fail "V8.order: expected checks:100 then dispatch:100 (got: [$GATE_OK])" ;;
esac
case "$GATE_OK" in
  *"transition:100:green->merging"*) pass "V8.happy: a bumped PR still transitions green -> merging" ;;
  *) fail "V8.happy: the green->merging transition is missing (got: [$GATE_OK])" ;;
esac
case "$GATE_OK" in
  *"batch:100:MERGING"*) pass "V8.happy: the MERGING serialization sentinel is still set" ;;
  *) fail "V8.happy: the MERGING sentinel is missing (got: [$GATE_OK])" ;;
esac

GATE_FAIL="$(run_gate 1)"
case "$GATE_FAIL" in
  *"ensure:100"*) pass "V8.closed: the gate did attempt the bump" ;;
  *) fail "V8.closed: the bump was never attempted (got: [$GATE_FAIL])" ;;
esac
case "$GATE_FAIL" in
  *dispatch:*) fail "V8.closed: /merge WAS dispatched for a PR whose bump failed (got: [$GATE_FAIL])" ;;
  *) pass "V8.closed: /merge is NOT dispatched when the bump could not be guaranteed" ;;
esac
case "$GATE_FAIL" in
  *"->merging"*) fail "V8.closed: the PR left green even though the bump failed (got: [$GATE_FAIL])" ;;
  *) pass "V8.closed: the PR STAYS green for a later pass" ;;
esac
case "$GATE_FAIL" in
  *"batch:100:MERGING"*) fail "V8.closed: the MERGING sentinel was set without a merge (got: [$GATE_FAIL])" ;;
  *) pass "V8.closed: the batch row is left GREEN (the barrier stays open for a retry)" ;;
esac

# rc 2 = "the bump was pushed JUST NOW". The push restarted the PR's checks, so
# dispatching /merge in the same pass is a deterministic gate_fail on
# reason=ci_red that burns one of the three merge attempts — three of those and
# should_automerge stops firing and the run stalls to the 4h stuck_loop.
GATE_PUSHED="$(run_gate 2)"
case "$GATE_PUSHED" in
  *dispatch:*) fail "V8.settle: /merge was dispatched in the SAME pass as the bump push (got: [$GATE_PUSHED])" ;;
  *) pass "V8.settle: rc 2 (bump pushed this pass) does NOT dispatch /merge — the restarted checks get a pass to settle" ;;
esac
case "$GATE_PUSHED" in
  *"->merging"*) fail "V8.settle: the PR left green on the push pass (got: [$GATE_PUSHED])" ;;
  *) pass "V8.settle: the PR stays green so the NEXT pass re-enters on the already_bumped arm" ;;
esac
case "$GATE_PUSHED" in
  *"audit:goal_merge_deferred"*ci_restarted_by_version_bump*)
    pass "V8.settle: the deferral is audited with reason=ci_restarted_by_version_bump" ;;
  *) fail "V8.settle: no goal_merge_deferred/ci_restarted_by_version_bump audit row (got: [$GATE_PUSHED])" ;;
esac

# Already bumped (rc 0) but the rollup still carries a pending entry: /merge must
# still be withheld, for the same reason — Step 1.4 reads pending as ci_red.
GATE_PENDING="$(run_gate 0 0)"
case "$GATE_PENDING" in
  *dispatch:*) fail "V8.pending: /merge was dispatched while checks were still running (got: [$GATE_PENDING])" ;;
  *) pass "V8.pending: /merge is withheld while any check is queued/in-progress" ;;
esac
case "$GATE_PENDING" in
  *"audit:goal_merge_deferred"*ci_pending*) pass "V8.pending: the deferral is audited with reason=ci_pending" ;;
  *) fail "V8.pending: no goal_merge_deferred/ci_pending audit row (got: [$GATE_PENDING])" ;;
esac
case "$GATE_PENDING" in
  *"batch:100:MERGING"*) fail "V8.pending: the MERGING sentinel was set without a merge (got: [$GATE_PENDING])" ;;
  *) pass "V8.pending: the batch row is left GREEN" ;;
esac
# An exit status this lane does not recognise must fail CLOSED too — a future
# status added to the helper cannot be allowed to silently mean "merge it".
GATE_UNKNOWN="$(run_gate 7)"
case "$GATE_UNKNOWN" in
  *dispatch:*) fail "V8.unknown: an UNRECOGNISED bump status reached the /merge dispatch (got: [$GATE_UNKNOWN])" ;;
  *) pass "V8.unknown: an unrecognised bump status fails closed — no /merge dispatch" ;;
esac
case "$GATE_UNKNOWN" in
  *"->merging"*) fail "V8.unknown: the PR left green on an unrecognised status (got: [$GATE_UNKNOWN])" ;;
  *) pass "V8.unknown: the PR stays green on an unrecognised status" ;;
esac

# The CI gate must never even be consulted when the bump itself failed — fail
# closed beats fail-closed-by-accident.
case "$GATE_FAIL" in
  *checks:*) fail "V8.closed: the CI probe ran after a failed bump (the arms are not mutually exclusive)" ;;
  *) pass "V8.closed: a failed bump short-circuits before the CI probe" ;;
esac

# ---------------------------------------------------------------------------
# V9 — structural: ordering, and exactly one guarded dispatch site.
# ---------------------------------------------------------------------------
echo
echo "== V9: structural — ensure-before-dispatch, one guarded dispatch site =="
ensure_ln="$(grep -n '_uberdev_goal_ensure_version_bump "\$pr"' "$GOAL_WATCH" | head -n 1 | cut -d: -f1)"
checks_ln="$(grep -n '_uberdev_goal_pr_checks_pending "\$pr"' "$GOAL_WATCH" | head -n 1 | cut -d: -f1)"
disp_ln="$(grep -n '_uberdev_goal_dispatch_merge "\$pr"' "$GOAL_WATCH" | head -n 1 | cut -d: -f1)"
if [ -n "$ensure_ln" ] && [ -n "$disp_ln" ] && [ "$ensure_ln" -lt "$disp_ln" ]; then
  pass "V9.order: _uberdev_goal_ensure_version_bump precedes _uberdev_goal_dispatch_merge in the watch lane"
else
  fail "V9.order: expected ensure (line ${ensure_ln:-none}) before dispatch (line ${disp_ln:-none})"
fi
if [ -n "$checks_ln" ] && [ -n "$disp_ln" ] && [ "$checks_ln" -lt "$disp_ln" ]; then
  pass "V9.order: _uberdev_goal_pr_checks_pending precedes _uberdev_goal_dispatch_merge in the watch lane"
else
  fail "V9.order: expected the CI probe (line ${checks_ln:-none}) before dispatch (line ${disp_ln:-none})"
fi
assert_eq "$(grep -c '_uberdev_goal_dispatch_merge "\$pr"' "$GOAL_WATCH")" "1" \
  "V9.single: exactly ONE /merge dispatch site exists, so the gate cannot be bypassed"
# The bump's exit status is captured and branched THREE ways — collapsing it back
# to a boolean would either merge into a pending rollup (rc 2 read as success) or
# stall the lane forever (rc 2 read as failure).
assert_grep "$GOAL_WATCH" '^[[:space:]]*version_bump_rc=\$\?' \
  "V9.guard: the bump's exit status is captured, not collapsed by an if/!"
assert_grep "$GOAL_WATCH" '^[[:space:]]*if \[ "\$version_bump_rc" -eq 2 \]; then' \
  "V9.guard: rc 2 (pushed this pass) has its own arm"
# `-ne 0`, never a literal `-eq 1`: an exit status this lane does not recognise
# must fail CLOSED, not fall through to the merge dispatch.
assert_grep "$GOAL_WATCH" '^[[:space:]]*elif \[ "\$version_bump_rc" -ne 0 \]; then' \
  "V9.guard: every non-zero status other than 2 fails closed (catch-all, not just rc 1)"
assert_no_grep "$GOAL_WATCH" '\[ "\$version_bump_rc" -eq 1 \]' \
  "V9.guard: the fail-closed arm is NOT narrowed to a literal rc 1"
# The dispatch must sit on an `elif` arm downstream of BOTH gates — an unguarded
# `if _uberdev_goal_dispatch_merge` would re-open the hole.
assert_grep "$GOAL_WATCH" '^[[:space:]]*elif _uberdev_goal_pr_checks_pending "\$pr"; then' \
  "V9.guard: the CI-settle probe is an arm of the same chain"
assert_grep "$GOAL_WATCH" '^[[:space:]]*elif _uberdev_goal_dispatch_merge "\$pr"; then' \
  "V9.guard: /merge runs only on the arm reachable when the bump succeeded AND CI settled"
# The solver prompt must KEEP forbidding solver-side bumps — the fix is to add
# the bump at the serialized landing point, not to hand it back to the fleet.
SOLVE_FLEET="$CLAUDE_PLUGIN_ROOT/skills/solve-fleet/workflow.js"
if [ -r "$SOLVE_FLEET" ]; then
  assert_grep "$SOLVE_FLEET" 'Do NOT bump the project version' \
    "V9.invariant: fleet solvers are still forbidden from bumping (the collision class stays closed)"
else
  fail "V9.invariant: $SOLVE_FLEET is missing"
fi
# The other half of the contract lives in /merge: pushing a release commit onto a
# reviewed head is only survivable because PATH_2 resolves a trust head first.
# Without this the bump lands and the PR can NEVER be merged.
MERGE_SKILL="$CLAUDE_PLUGIN_ROOT/skills/merge-pipeline/SKILL.md"
RELEASE_ANCHOR_LIB="$CLAUDE_PLUGIN_ROOT/skills/merge-pipeline/lib/release-anchor.sh"
if [ -r "$MERGE_SKILL" ] && [ -x "$RELEASE_ANCHOR_LIB" ] || [ -r "$RELEASE_ANCHOR_LIB" ]; then
  assert_grep "$MERGE_SKILL" 'release-anchor\.sh' \
    "V9.invariant: /merge PATH_2 resolves its trust head through release-anchor.sh"
else
  fail "V9.invariant: $RELEASE_ANCHOR_LIB is missing — /goal's bump would make every PR unmergeable"
fi

# ---------------------------------------------------------------------------
# V10 — the CI-settle probe itself.
# ---------------------------------------------------------------------------
echo
echo "== V10: _uberdev_goal_pr_checks_pending — withholding only, never authorising =="
S10="$(new_sandbox v10 1.2.3)"
add_pr "$S10" 601 "fix/601-ci" main "fix(x): ci" "body"
run_checks() {   # <root> <pr>
  ( cd "$1/work" && PATH="$1/bin:$PATH" GH_FIX="$1/ghfix" \
      bash -c '. "$GOAL_LIB"; _uberdev_goal_pr_checks_pending "$1"' _ "$2" >/dev/null 2>&1 )
}
set_pr_checks "$S10" 601 2
run_checks "$S10" 601; assert_eq "$?" "0" "V10.pending: a rollup with running checks reports pending (rc 0 — withhold)"
set_pr_checks "$S10" 601 0
run_checks "$S10" 601; assert_eq "$?" "1" "V10.settled: an all-settled rollup reports not-pending (rc 1 — proceed)"
# A gh failure / malformed count must NOT wedge the landing lane: /merge Step 1.4
# owns the hard CI gate and re-probes with its own settle logic.
set_pr_checks "$S10" 601 "boom"
run_checks "$S10" 601; assert_eq "$?" "1" "V10.soft: an unusable probe result falls through (rc 1) instead of stalling the lane"
run_checks "$S10" "not-a-number"; assert_eq "$?" "1" "V10.validate: a non-numeric PR is refused without touching gh"

# ---------------------------------------------------------------------------
# V11 — the SemVer step follows the PR's COMMITS, not just its title.
# ---------------------------------------------------------------------------
echo
echo "== V11: a feat: commit under a fix: title is released as a MINOR, end to end =="
S11="$(new_sandbox v11 1.2.3)"
add_pr "$S11" 701 "fix/701-mislabelled" main "fix(goal): tidy up" "body"
set_pr_commits "$S11" 701 'S|fix(goal): tidy up
B|
S|feat(goal): a whole new subcommand
B|'
run_ensure "$S11" 701; rc=$?
assert_eq "$rc" "2" "V11.rc: the PR is bumped and pushed"
assert_eq "$(origin_subject "$S11" fix/701-mislabelled)" "chore(release): v1.3.0" \
  "V11.kind: the feat: COMMIT drove a MINOR bump (1.2.3 -> 1.3.0), not the title's patch"
assert_grep "$(audit_log "$S11")" '"kind":"minor"' "V11.audit: the audited kind is minor"

echo
echo "== Summary =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
