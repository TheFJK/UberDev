#!/usr/bin/env bash
# Asserts the contract invariants for the orchestrator Phase 1
# artifact-reuse short-circuit added by issue #62.
#
# Modelled on tests/issue-causal-fanout.test.sh: grep-based structural
# assertions against the rendered skill file. No live gh CLI invocation.
# Tests run in CI before merge.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"

# Pre-flight: refuse to run if the files we're asserting against are missing
# or unreadable — without this, every assertion fails with a confusing
# "pattern not found" instead of the real cause.
for f in "$SKILL"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

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

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== Artifact-reuse contract present =="
assert_grep "$SKILL" \
  '^### The artifact-reuse contract' \
  'contract subsection heading present'
assert_grep "$SKILL" \
  'Freshness predicate' \
  'freshness predicate label present'
assert_grep "$SKILL" \
  'no-cache' \
  'no-cache reason discriminator listed'
assert_grep "$SKILL" \
  'stale-mtime' \
  'stale-mtime reason discriminator listed'
assert_grep "$SKILL" \
  'missing-summary' \
  'missing-summary reason discriminator listed'
assert_grep "$SKILL" \
  'invalid-timestamp' \
  'invalid-timestamp reason discriminator listed'
assert_grep "$SKILL" \
  'missing-head-sha' \
  'missing-head-sha reason discriminator listed'
assert_grep "$SKILL" \
  'head-divergence' \
  'head-divergence reason discriminator listed'
assert_grep "$SKILL" \
  'file-intersection' \
  'file-intersection reason discriminator listed'
assert_grep "$SKILL" \
  'pr-closed' \
  'pr-closed reason discriminator listed'

echo
echo "== All six topics enumerated =="
assert_grep "$SKILL" \
  'for TOPIC in codebase patterns prior-art constraints security test-coverage' \
  'six-topic loop literal preserved'

echo
echo "== Per-topic log emission documented =="
assert_grep "$SKILL" \
  'status=reused' \
  'status=reused log line present'
assert_grep "$SKILL" \
  'status=dispatched' \
  'status=dispatched log line present'
assert_grep "$SKILL" \
  'note=fresh-run,reason=<no-cache\|stale-mtime\|missing-summary\|invalid-timestamp\|missing-head-sha\|head-divergence\|file-intersection\|pr-closed>' \
  'dispatched-line bullet enumerates all eight reasons'
assert_grep "$SKILL" \
  'note=cache-hit,mtime=' \
  'reused-line bullet present with mtime'

echo
echo "== New front-matter and env-var contract present =="
assert_grep "$SKILL" \
  'head_sha:' \
  'head_sha front-matter field documented'
assert_grep "$SKILL" \
  'UBERDEV_CACHE_DIVERGENCE_THRESHOLD' \
  'divergence threshold env var documented'
assert_grep "$SKILL" \
  'git cat-file -e' \
  'git cat-file -e reachability probe documented'
assert_grep "$SKILL" \
  'git rev-list --count' \
  'divergence count primitive documented'
assert_grep "$SKILL" \
  'gh pr list --state merged --search' \
  'gh pr list closing-PR primitive documented'
assert_grep "$SKILL" \
  'Files investigated' \
  'Files investigated section reference documented'

echo
echo "== Stale brainstorm cross-reference removed =="
assert_no_grep "$SKILL" \
  'brainstorm/SKILL\.md:87-131' \
  'stale brainstorm cross-reference removed'

echo
echo "== Trust-boundary cached-artifact clause present =="
assert_grep "$SKILL" \
  'cached-research-issue-' \
  'trust-boundary mentions cached-research-issue- envelope'
assert_grep "$SKILL" \
  'Cached research artifacts' \
  'trust-boundary clause leads with Cached research artifacts'

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
