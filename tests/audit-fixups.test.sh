#!/usr/bin/env bash
# Regression tests for the Round 1 critical fixes from PR #13 (audit-findings-q2-2026).
#
# These assertions are "fixup didn't silently regress" canaries — they are
# cross-cutting (touching agents, hooks, scripts, command files, and a skill)
# and don't slot cleanly into any of the per-feature test files. Folding them
# into existing tests would mix concerns; this dedicated file keeps the audit
# fixup contract auditable in one place.
#
# Sections:
#   C1 — code-simplifier auto-trigger gate (positive + negative)
#   C3 — stop-server JSON status shape (stopped_no_cleanup + reason field)
#   C4 — gh prereq moved from command markdown to runtime session-start hook
#   C5 — brainstorm SKILL.md threat-model section exists
#
# Style mirrors tests/turbo-flow.test.sh and tests/post-impl-review.test.sh:
# grep-based structural assertions against the rendered files, no live
# command/agent invocation, runs in CI before merge.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CODE_SIMPLIFIER="$REPO_ROOT/plugins/uberdev/agents/code-simplifier.md"
STOP_SERVER="$REPO_ROOT/plugins/uberdev/skills/brainstorm/scripts/stop-server.sh"
SESSION_START="$REPO_ROOT/plugins/uberdev/hooks/session-start"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
TURBO_CMD="$REPO_ROOT/plugins/uberdev/commands/turbo.md"
ISSUE_CMD="$REPO_ROOT/plugins/uberdev/commands/issue.md"
BRAINSTORM_SKILL="$REPO_ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"

# Pre-flight: refuse to run if any asserted-against file is missing or unreadable.
# Without this, every assertion fails with a confusing "pattern not found"
# instead of the real cause (mirrors issue-causal-fanout.test.sh).
for f in "$CODE_SIMPLIFIER" "$STOP_SERVER" "$SESSION_START" \
         "$SOLVE_CMD" "$TURBO_CMD" "$ISSUE_CMD" "$BRAINSTORM_SKILL"; do
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

# Case-insensitive negative match. Inline because turbo-flow.test.sh has a
# bespoke inverted block but no reusable helper.
assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qiE -e "$pattern" "$file"; then
    echo "  FAIL  $desc — pattern '$pattern' should not appear"
    echo "        file: $file"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== C1: code-simplifier auto-trigger gate =="
# POSITIVE: the gating prose must be present so the agent only runs when
# explicitly dispatched. Either phrasing in the agent body satisfies this
# (the file contains both the description-level "ONLY when explicitly
# invoked" and the body-level "Do not self-trigger after generic coding
# work" — pattern accepts either to stay robust to gentle rewording).
assert_grep "$CODE_SIMPLIFIER" \
  'Do not self-trigger after generic coding work|activate ONLY when explicitly invoked' \
  "code-simplifier has the explicit-invocation gating prose"

# NEGATIVE: previous failure mode was license-y wording in the description
# field that nudged the harness to auto-dispatch the agent after any code
# write. None of these tokens should appear anywhere in the file (case
# insensitive). The forbidden pattern is narrow on purpose: the gating prose
# above uses "explicitly invoked", not any of these forbidden words, so a
# correct fix doesn't accidentally trip this assertion.
assert_grep_not "$CODE_SIMPLIFIER" \
  'autonomously|proactively|immediately after|without requiring explicit' \
  "code-simplifier does NOT contain auto-trigger licensing words"

echo
echo "== C3: stop-server JSON partial-failure status shape =="
# Without these fields, callers can't distinguish a clean stop from a
# process-killed-but-session-leaked outcome — the script previously lied
# about cleanup completing in that case.
assert_grep "$STOP_SERVER" \
  'stopped_no_cleanup' \
  "stop-server emits the stopped_no_cleanup partial-failure status"
assert_grep "$STOP_SERVER" \
  '"reason"' \
  "stop-server includes a reason field alongside the status"

echo
echo "== C4: gh prereq moved from command markdown to session-start hook =="
# POSITIVE: the real runtime guard lives in the hook now.
assert_grep "$SESSION_START" \
  'command -v gh' \
  "session-start hook contains the runtime gh availability check"

# NEGATIVE: the command markdown files used to carry a `command -v gh ... ||
# { echo "❌ gh CLI required` block at the top — that was theatre because
# Claude reads markdown command files as instructions, not bash. The fixup
# removed those blocks, leaving only HTML-comment prose that *mentions*
# command -v gh inside backticks while explaining the history. The unique
# fingerprint of the removed theatre block is the literal "❌ gh CLI required"
# string, which would never appear in the new HTML-comment context. If it
# ever resurfaces, someone re-introduced the theatre block.
assert_grep_not "$SOLVE_CMD" \
  'gh CLI required' \
  "solve.md no longer carries the removed gh-CLI theatre block"
assert_grep_not "$TURBO_CMD" \
  'gh CLI required' \
  "turbo.md no longer carries the removed gh-CLI theatre block"
assert_grep_not "$ISSUE_CMD" \
  'gh CLI required' \
  "issue.md no longer carries the removed gh-CLI theatre block"

# Belt-and-braces count check: each command file should mention `command -v
# gh` exactly once, and only inside the HTML comment that explains why the
# theatre was removed. A second occurrence implies someone re-added an
# executable check outside the comment context.
for f in "$SOLVE_CMD" "$TURBO_CMD" "$ISSUE_CMD"; do
  count=$(grep -c 'command -v gh' "$f" || true)
  if [ "$count" = "1" ]; then
    echo "  PASS  $(basename "$f") mentions 'command -v gh' exactly once (inside HTML comment)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $(basename "$f") has $count occurrences of 'command -v gh' (expected 1, all inside HTML comment)"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== C5: brainstorm SKILL.md threat-model section =="
# Without the threat-model section, the localhost-only / single-user / no-auth
# trust assumptions of the visual-companion server are undocumented and the
# next contributor to touch server.cjs has no anchor for "why is this 127.0.0.1?".
assert_grep "$BRAINSTORM_SKILL" \
  '^## Threat model' \
  "brainstorm SKILL.md has a top-level Threat model section heading"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
