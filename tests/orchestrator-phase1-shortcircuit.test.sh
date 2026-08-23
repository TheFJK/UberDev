#!/usr/bin/env bash
# Asserts the orchestrator Phase 1 artifact-reuse cache DELETION contract.
#
# History: issue #62 added a ~200-line freshness predicate that gated per-topic
# reuse of cached research before the fanout. RFC 0012 §3.5 / #308 DELETED it
# after a live repo-wide grep proved the cache had zero writers (the predicate
# could never fire). This test is the inverted oracle: it now locks the
# decision record + the absence of the predicate machinery, so the cache can
# never silently grow back without re-pointing this file.
#
# Modelled on tests/issue-causal-fanout.test.sh: grep-based structural
# assertions against the rendered skill file. No live gh CLI invocation.
# Tests run in CI before merge.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
# #747 — the cache-deletion decision record moved into this reference file
# when the orchestrator body was cut toward Anthropic's 500-line ceiling. The
# body keeps the heading and the "do not reintroduce without reading the
# binding rules" pointer; the binding rules themselves live here, so the two
# rows that quote them read this file.
SKILL_TIERS_REF="$REPO_ROOT/plugins/uberdev/skills/orchestrator/references/tiers-and-recovery.md"

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

echo "== Cache-deletion decision record present (#308 / RFC 0012 §3.5) =="
# The decision record is the load-bearing artifact: it documents WHY the
# predicate was deleted (zero writers) and the binding rules for any future
# reintroduction, so a reader cannot mistake the deletion for an oversight.
assert_grep "$SKILL" \
  '^### Phase 1 research cache — deleted' \
  'cache-deletion decision-record heading present'
assert_grep "$SKILL_TIERS_REF" \
  'zero writers' \
  'decision record cites the zero-writers finding'
assert_grep "$SKILL_TIERS_REF" \
  'git rev-parse --git-common-dir' \
  'future-reintroduction rule pins --git-common-dir for the MAIN repo root'
assert_grep "$SKILL_TIERS_REF" \
  'thin preflight probe' \
  'future-reintroduction rule forbids re-growing an inline freshness predicate'

echo
echo "== Freshness-predicate machinery is GONE =="
# These were the ~200-line predicate's distinctive tokens. None may survive,
# or the cache has crept back in. (The decision-record prose above is allowed
# to NAME the deleted predicate — these patterns match only the live machinery,
# which referenced the discriminators/array/log-lines/env-var as executable
# contract, not as a historical mention.)
assert_no_grep "$SKILL" \
  '^### The artifact-reuse contract' \
  'live artifact-reuse contract subsection removed'
assert_no_grep "$SKILL" \
  'TOPICS=\(codebase patterns prior-art constraints security test-coverage\)' \
  'six-topic TOPICS reuse-array declaration removed'
assert_no_grep "$SKILL" \
  'for TOPIC in "\$\{TOPICS\[@\]\}"; do' \
  'per-topic reuse loop removed'
assert_no_grep "$SKILL" \
  'note=fresh-run,reason=<no-cache\|stale-mtime\|missing-summary\|invalid-timestamp\|missing-head-sha\|head-divergence\|file-intersection\|pr-closed>' \
  'per-topic reuse log-line (eight reason discriminators) removed'
assert_no_grep "$SKILL" \
  'note=cache-hit,mtime=' \
  'cache-hit reused log-line removed'
assert_no_grep "$SKILL" \
  'UBERDEV_CACHE_DIVERGENCE_THRESHOLD' \
  'cache-divergence threshold env var removed'
assert_no_grep "$SKILL" \
  'git rev-list --count' \
  'divergence-count primitive removed'
assert_no_grep "$SKILL" \
  'gh pr list --state merged --search' \
  'closing-PR cache-invalidation primitive removed'

echo
echo "== Phase 1 dispatches fresh every run =="
# With the cache gone, the medium-tier fanout is unconditionally fresh.
assert_grep "$SKILL" \
  'always dispatched fresh' \
  'Phase 1 documents always-fresh fanout'
assert_grep "$SKILL" \
  'the cache short-circuit is deleted' \
  'Phase 1 fanout names the deletion inline'

echo
echo "== Trust-boundary cached-artifact clause retained (future reuse) =="
# The trust rule is retained verbatim for any future reintroduction — it is
# NOT deleted with the predicate (reused artifacts would still be untrusted).
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
