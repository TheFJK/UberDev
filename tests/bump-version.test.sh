#!/usr/bin/env bash
# tests/bump-version.test.sh — runtime fixture tests for
# plugins/uberdev/lib/bump-version.sh (RFC 0012 §7.7 infra-R5, issue #309).
#
# bump-version.sh is the one-command release ritual: it propagates a new
# SemVer to EVERY CI-locked version surface — plugin.json, marketplace.json,
# the README version badge, a dated CHANGELOG
# section stub, plus the two
# `assert_version_bump` call-site args and the two cosmetic version echo
# headers in tests/goal.test.sh / tests/solve-claim.test.sh — refuses on
# pre-existing drift, and prints the remaining tag/release checklist WITHOUT
# running git or gh itself (foreground control stays with the operator).
#
# These are sandbox tests: each section builds a throwaway mini-repo under
# mktemp -d carrying all six surface files, then runs the REAL script against
# it via --repo-root, so the full edit pipeline is exercised without touching
# this repo's actual manifests. git and gh are PATH-stubbed as fail-loud
# loggers so the never-runs-git/gh contract is proven behaviorally, not just
# by grep.
#
# Sections:
#   B1 — structural: shebang, surfaces named, --repo-root documented, no
#        non-portable in-place sed flag (edits go through tempfile copy-back)
#   B2 — happy bump: all 8 anchors updated, dated CHANGELOG stub inserted,
#        ritual checklist printed, git/gh never invoked
#   B3 — idempotent: re-run with the same target is a byte-identical no-op
#   B4 — manifest drift refusal: disagreeing marketplace.json -> exit 3,
#        NOTHING edited (no half-bump)
#   B5 — test-lock drift refusal: disagreeing assert_version_bump arg ->
#        exit 3, nothing edited
#   B6 — usage errors: missing/malformed semver, unknown flag -> exit 2,
#        nothing edited
#   B7 — duplicate-CHANGELOG-section guard: target version already has a
#        `## [X.Y.Z]` section -> exit 3 (no duplicate stub)
#   B8 — real-repo canary: THIS repo's 9 anchor sites are mutually consistent
#        and stay sed-compatible (no-op run over a copy is byte-identical)
#
# Portable: bash + coreutils + sed/awk/grep only (no python3, no zsh, no jq),
# so it runs on BOTH CI jobs (ubuntu-latest and windows-latest Git Bash).

# `set -e` intentionally NOT enabled: a failed assertion must not abort the
# rest of the suite. PASS/FAIL counters + non-zero exit at the end instead.
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUMP_SH="$REPO_ROOT/plugins/uberdev/lib/bump-version.sh"

# Pre-flight: refuse to run if the script under test is missing (mirrors
# install.test.sh — a clear FATAL beats forty confusing assertion failures).
if [ ! -r "$BUMP_SH" ]; then
  echo "FATAL: required file missing or unreadable: $BUMP_SH" >&2
  exit 2
fi

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc — pattern '$pattern' should not appear"
    echo "        file: $file"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

# Fixed-string variant for anchors that contain regex metacharacters
# (e.g. the literal `0\.30\.0` inside the goal.test.sh fixture).
assert_fgrep() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:   $file"
    echo "        needle: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local expected="$1" desc="$2"
  if [ "$RC" -eq "$expected" ]; then
    echo "  PASS  $desc (rc=$RC)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc — expected rc=$expected, got rc=$RC"
    echo "        output: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_out() {
  local pattern="$1" desc="$2"
  if grep -qE -e "$pattern" <<<"$OUT"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc — output does not match /$pattern/"
    echo "        output: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# --- git/gh stubs ------------------------------------------------------------
# Any invocation of git or gh by bump-version.sh is a contract violation
# (RFC 0012 §7.7: the script edits files and prints the checklist; the
# operator keeps foreground control over commit/tag/release). The stubs log
# and fail so a regression is caught behaviorally.
STUB_BIN_DIR="$(mktemp -d)"
for tool in git gh; do
  cat > "$STUB_BIN_DIR/$tool" <<STUB
#!/usr/bin/env bash
echo "\$0 \$*" >> "$STUB_BIN_DIR/invoked.log"
exit 99
STUB
  chmod +x "$STUB_BIN_DIR/$tool"
done

# --- fixture builder ----------------------------------------------------------
# make_fixture <version> [<prev-version>] — builds a consistent mini-repo
# carrying all six surface files at <version> and echoes its root path.
make_fixture() {
  local ver="$1" prev="${2:-1.2.2}" root
  root="$(mktemp -d)"
  mkdir -p "$root/plugins/uberdev/.claude-plugin" "$root/.claude-plugin" "$root/tests"
  cat > "$root/plugins/uberdev/.claude-plugin/plugin.json" <<EOF
{
  "name": "uberdev",
  "version": "$ver",
  "license": "MIT"
}
EOF
  cat > "$root/.claude-plugin/marketplace.json" <<EOF
{
  "name": "uberdev",
  "plugins": [
    {
      "name": "uberdev",
      "source": "./plugins/uberdev",
      "version": "$ver",
      "category": "workflow"
    }
  ]
}
EOF
  cat > "$root/README.md" <<EOF
# Fixture

[![Version](https://img.shields.io/badge/version-$ver-blue)](./CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
EOF
  cat > "$root/CHANGELOG.md" <<EOF
# Changelog

All notable changes are documented here.

## [$ver] — 2026-01-02

### Fixed
- Something recent.

## [$prev] — 2026-01-01

### Added
- Initial fixture release.
EOF
  cat > "$root/tests/goal.test.sh" <<EOF
#!/usr/bin/env bash
echo "== G20: version bump locked ($ver) =="
assert_version_bump "\$REPO_ROOT" "$ver"
assert_no_grep "\$REPO_ROOT/tests/solve-claim.test.sh" '0\\.30\\.0' "G20.solve-claim-no-old-version"
EOF
  cat > "$root/tests/solve-claim.test.sh" <<EOF
#!/usr/bin/env bash
echo "== Version bump $prev -> $ver propagated =="
assert_version_bump "\$REPO_ROOT" "$ver"
EOF
  printf '%s\n' "$root"
}

# fixture_cksums <root> — stable digest of all six surface files.
fixture_cksums() {
  local root="$1"
  cksum \
    "$root/plugins/uberdev/.claude-plugin/plugin.json" \
    "$root/.claude-plugin/marketplace.json" \
    "$root/README.md" \
    "$root/CHANGELOG.md" \
    "$root/tests/goal.test.sh" \
    "$root/tests/solve-claim.test.sh"
}

# run_bump <root> <args...> — run the real script against a fixture root with
# git/gh stubbed; captures combined output in $OUT and the exit code in $RC.
run_bump() {
  local root="$1"; shift
  OUT="$(PATH="$STUB_BIN_DIR:$PATH" bash "$BUMP_SH" "$@" --repo-root "$root" 2>&1)"
  RC=$?
}

changelog_top_header() {
  awk '/^## \[/ { print; exit }' "$1/CHANGELOG.md"
}

echo "== B1: structural shape of bump-version.sh =="
assert_grep "$BUMP_SH" '^#!/usr/bin/env bash' "B1.1 shebang is #!/usr/bin/env bash"
assert_grep "$BUMP_SH" 'plugins/uberdev/\.claude-plugin/plugin\.json' "B1.2 names plugin.json (canonical surface)"
assert_grep "$BUMP_SH" '\.claude-plugin/marketplace\.json' "B1.3 names marketplace.json"
assert_grep "$BUMP_SH" 'README\.md' "B1.4 names README.md"
assert_grep "$BUMP_SH" 'CHANGELOG\.md' "B1.5 names CHANGELOG.md"
assert_grep "$BUMP_SH" 'tests/goal\.test\.sh' "B1.6 names tests/goal.test.sh"
assert_grep "$BUMP_SH" 'tests/solve-claim\.test\.sh' "B1.7 names tests/solve-claim.test.sh"
assert_grep "$BUMP_SH" '\-\-repo-root' "B1.8 documents --repo-root"
assert_grep "$BUMP_SH" 'assert_version_bump' "B1.9 targets the assert_version_bump call sites"
# Portability lock: in-place edits must go through the tempfile copy-back
# helper, never sed's in-place flag (GNU and BSD/macOS sed disagree on its
# argument shape — the divergence this script exists to sidestep).
assert_grep_not "$BUMP_SH" 'sed[[:space:]]+-i' "B1.10 no non-portable in-place sed flag"
# Renderer-hazard hygiene is N/A here (lib/ is never rendered). B1.11, the
# bash-3.2 builtin ban, was retired into tests/epipe-guard.test.sh L9 (#628): it
# guarded this ONE script while every shipped lib declares the same floor in its
# own header, and L9 now enforces it across the whole shipped corpus with an
# exemption for the comment and backticked-prose mentions that make the floor
# describable. lib/bump-version.sh is inside that corpus.

echo
echo "== B2: happy bump 1.2.3 -> 1.3.0 updates all 8 anchors =="
FIX="$(make_fixture 1.2.3)"
run_bump "$FIX" 1.3.0
assert_rc 0 "B2.1 bump exits 0"
assert_grep "$FIX/plugins/uberdev/.claude-plugin/plugin.json" '"version": "1\.3\.0"' "B2.2 plugin.json bumped"
assert_grep "$FIX/.claude-plugin/marketplace.json" '"version": "1\.3\.0"' "B2.3 marketplace.json bumped"
assert_grep "$FIX/README.md" 'version-1\.3\.0-blue' "B2.4 README badge bumped"
assert_grep_not "$FIX/README.md" 'version-1\.2\.3-blue' "B2.5 old README badge gone"
assert_eq "$(changelog_top_header "$FIX" | cut -c1-10)" "## [1.3.0]" "B2.6 CHANGELOG topmost section is the new version"
assert_grep "$FIX/CHANGELOG.md" '^## \[1\.3\.0\].*[0-9]{4}-[0-9]{2}-[0-9]{2}' "B2.7 new CHANGELOG section header is dated"
assert_grep "$FIX/CHANGELOG.md" 'stub' "B2.8 CHANGELOG carries a fill-me-in stub body"
assert_grep "$FIX/CHANGELOG.md" '^## \[1\.2\.3\]' "B2.9 previous CHANGELOG section retained"
assert_grep "$FIX/tests/goal.test.sh" 'version bump locked \(1\.3\.0\)' "B2.10 goal.test.sh echo header bumped"
assert_grep "$FIX/tests/goal.test.sh" 'assert_version_bump "\$REPO_ROOT" "1\.3\.0"' "B2.11 goal.test.sh call-site arg bumped"
assert_fgrep "$FIX/tests/goal.test.sh" '0\.30\.0' "B2.12 unrelated version literal untouched (line-scoped edits)"
assert_grep "$FIX/tests/solve-claim.test.sh" '== Version bump 1\.2\.3 -> 1\.3\.0 propagated ==' "B2.13 solve-claim echo header rewritten old -> new"
assert_grep "$FIX/tests/solve-claim.test.sh" 'assert_version_bump "\$REPO_ROOT" "1\.3\.0"' "B2.14 solve-claim call-site arg bumped"
# Ritual checklist: the tag/release steps the script intentionally does NOT
# run must be printed so worktree agents see them (CLAUDE.md is gitignored
# and worktree-invisible — RFC 0012 §7.7 / R-15).
assert_out 'chore\(release\): v1\.3\.0' "B2.15 checklist names the chore(release) commit"
assert_out 'git tag v1\.3\.0' "B2.16 checklist names the git tag step"
assert_out 'gh release create v1\.3\.0' "B2.17 checklist names the gh release step"
assert_out 'tests/goal\.test\.sh' "B2.18 checklist points at the version-lock tests"
assert_out 'never parallel-bump' "B2.19 checklist carries the sequential-release rule"
assert_out 'CHANGELOG' "B2.20 checklist tells the operator to fill the CHANGELOG stub"
if [ -f "$STUB_BIN_DIR/invoked.log" ]; then
  echo "  FAIL  B2.21 bump-version.sh invoked git/gh (forbidden):"
  sed 's/^/        /' "$STUB_BIN_DIR/invoked.log"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  B2.21 git/gh never invoked (checklist instead)"
  PASS=$((PASS + 1))
fi

echo
echo "== B3: re-running with the same target is a byte-identical no-op =="
BEFORE="$(fixture_cksums "$FIX")"
run_bump "$FIX" 1.3.0
AFTER="$(fixture_cksums "$FIX")"
assert_rc 0 "B3.1 idempotent re-run exits 0"
assert_eq "$AFTER" "$BEFORE" "B3.2 re-run leaves all six files byte-identical"
assert_eq "$(grep -c '^## \[1\.3\.0\]' "$FIX/CHANGELOG.md")" "1" "B3.3 exactly one CHANGELOG section for 1.3.0 (no duplicate stub)"
assert_out 'nothing to do' "B3.4 no-op is reported, not silent"

echo
echo "== B4: manifest drift refusal (marketplace.json disagrees) =="
FIX="$(make_fixture 1.2.3)"
# Corrupt exactly one of the four manifest surfaces.
sed 's/"version": "1\.2\.3"/"version": "9.9.9"/' "$FIX/.claude-plugin/marketplace.json" > "$FIX/.claude-plugin/marketplace.json.tmp"
cat "$FIX/.claude-plugin/marketplace.json.tmp" > "$FIX/.claude-plugin/marketplace.json"
rm -f "$FIX/.claude-plugin/marketplace.json.tmp"
BEFORE="$(fixture_cksums "$FIX")"
run_bump "$FIX" 1.3.0
AFTER="$(fixture_cksums "$FIX")"
assert_rc 3 "B4.1 drift refusal exits 3"
assert_out 'marketplace\.json' "B4.2 refusal names the drifted surface"
assert_eq "$AFTER" "$BEFORE" "B4.3 refusal edits NOTHING (no half-bump)"
assert_grep_not "$FIX/CHANGELOG.md" '^## \[1\.3\.0\]' "B4.4 no CHANGELOG stub inserted on refusal"

echo
# B4b IS RETIRED, not silently dropped. It drove the drift pre-check through
# codex/uberdev-codex/.codex-plugin/plugin.json, a surface bump-version.sh no
# longer owns (issue #381 retired the Codex distribution). The manifest-drift
# refusal it exercised is still covered by B4 (marketplace.json) against a
# surface that still exists; re-seeding it on a deleted file would assert a
# refusal nothing can trigger. Restore an equivalent case if a third manifest
# surface is ever added.

echo "== B5: test-lock drift refusal (assert_version_bump arg disagrees) =="
FIX="$(make_fixture 1.2.3)"
sed 's/assert_version_bump "$REPO_ROOT" "1.2.3"/assert_version_bump "$REPO_ROOT" "0.0.1"/' "$FIX/tests/goal.test.sh" > "$FIX/tests/goal.test.sh.tmp"
cat "$FIX/tests/goal.test.sh.tmp" > "$FIX/tests/goal.test.sh"
rm -f "$FIX/tests/goal.test.sh.tmp"
BEFORE="$(fixture_cksums "$FIX")"
run_bump "$FIX" 1.3.0
AFTER="$(fixture_cksums "$FIX")"
assert_rc 3 "B5.1 test-lock drift refusal exits 3"
assert_out 'goal\.test\.sh' "B5.2 refusal names the drifted test lock"
assert_eq "$AFTER" "$BEFORE" "B5.3 refusal edits NOTHING (manifests not half-bumped)"

echo
echo "== B6: usage errors exit 2 and edit nothing =="
FIX="$(make_fixture 1.2.3)"
BEFORE="$(fixture_cksums "$FIX")"
run_bump "$FIX"
assert_rc 2 "B6.1 missing <new-version> exits 2"
assert_out '[Uu]sage' "B6.2 missing arg prints usage"
run_bump "$FIX" 1.2
assert_rc 2 "B6.3 non-semver '1.2' exits 2"
run_bump "$FIX" v1.3.0
assert_rc 2 "B6.4 'v'-prefixed version exits 2"
run_bump "$FIX" 1.03.0
assert_rc 2 "B6.5 leading-zero component exits 2"
run_bump "$FIX" 1.3.0 --frobnicate
assert_rc 2 "B6.6 unknown flag exits 2"
AFTER="$(fixture_cksums "$FIX")"
assert_eq "$AFTER" "$BEFORE" "B6.7 usage errors edit NOTHING"

echo
echo "== B7: duplicate-CHANGELOG-section guard =="
# Fixture is consistently at 1.4.0 with a buried [1.3.0] section; asking for
# 1.3.0 again must refuse rather than insert a duplicate dated stub.
FIX="$(make_fixture 1.4.0 1.3.0)"
BEFORE="$(fixture_cksums "$FIX")"
run_bump "$FIX" 1.3.0
AFTER="$(fixture_cksums "$FIX")"
assert_rc 3 "B7.1 already-released target exits 3"
assert_out 'CHANGELOG' "B7.2 refusal explains the CHANGELOG collision"
assert_eq "$AFTER" "$BEFORE" "B7.3 refusal edits NOTHING"

echo
echo "== B8: real-repo canary — this repo's anchor sites stay consistent + sed-compatible =="
# Copy THIS repo's six real surface files into a fixture layout and run the
# no-op path over the copy. Catches two drift classes the synthetic fixtures
# cannot: (a) a half-bumped real repo, (b) a formatting change in any real
# anchor site (plugin.json spacing, badge shape, echo-header wording …) that
# would make bump-version.sh's line-scoped greps/seds stop matching at the
# NEXT release. Runs over a copy so a regression can never mutate the repo.
FIX="$(mktemp -d)"
mkdir -p "$FIX/plugins/uberdev/.claude-plugin" "$FIX/.claude-plugin" "$FIX/tests"
cp "$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json" "$FIX/plugins/uberdev/.claude-plugin/plugin.json"
cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$FIX/.claude-plugin/marketplace.json"
cp "$REPO_ROOT/README.md" "$FIX/README.md"
cp "$REPO_ROOT/CHANGELOG.md" "$FIX/CHANGELOG.md"
cp "$REPO_ROOT/tests/goal.test.sh" "$FIX/tests/goal.test.sh"
cp "$REPO_ROOT/tests/solve-claim.test.sh" "$FIX/tests/solve-claim.test.sh"
REAL_CURRENT="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$FIX/plugins/uberdev/.claude-plugin/plugin.json" | sed -n '1p')"
if [ -z "$REAL_CURRENT" ]; then
  echo "  FAIL  B8.0 could not read the current version from the real plugin.json"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  B8.0 current version readable from plugin.json ($REAL_CURRENT)"
  PASS=$((PASS + 1))
  BEFORE="$(fixture_cksums "$FIX")"
  run_bump "$FIX" "$REAL_CURRENT"
  AFTER="$(fixture_cksums "$FIX")"
  assert_rc 0 "B8.1 no-op over the real surfaces exits 0 (drift pre-check passes on all 8 anchors)"
  assert_eq "$AFTER" "$BEFORE" "B8.2 no-op leaves the copied real surfaces byte-identical"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
