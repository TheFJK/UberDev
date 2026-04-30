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
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

# Pre-flight: refuse to run if any asserted-against file is missing or unreadable.
# Without this, every assertion fails with a confusing "pattern not found"
# instead of the real cause (mirrors issue-causal-fanout.test.sh).
for f in "$CODE_SIMPLIFIER" "$STOP_SERVER" "$SESSION_START" \
         "$SOLVE_CMD" "$TURBO_CMD" "$ISSUE_CMD" "$BRAINSTORM_SKILL" "$SOLVE_PIPELINE"; do
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
# NOTE: solve.md and turbo.md are now thin wrappers (the launcher moved to
# solve-pipeline/SKILL.md after #15). Their `command -v gh` count is 0; the
# gh-CLI-theatre concern now lives in the skill.
for f in "$ISSUE_CMD"; do
  count=$(grep -c 'command -v gh' "$f" || true)
  if [ "$count" = "1" ]; then
    echo "  PASS  $(basename "$f") mentions 'command -v gh' exactly once (inside HTML comment)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $(basename "$f") has $count occurrences of 'command -v gh' (expected 1, all inside HTML comment)"
    FAIL=$((FAIL + 1))
  fi
done

# solve.md and turbo.md MUST have ZERO `command -v gh` mentions.
for f in "$SOLVE_CMD" "$TURBO_CMD"; do
  count=$(grep -c 'command -v gh' "$f" || true)
  if [ "$count" = "0" ]; then
    echo "  PASS  $(basename "$f") thin wrapper has 0 occurrences of 'command -v gh' (correct: launcher moved to solve-pipeline skill)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $(basename "$f") thin wrapper has $count occurrences of 'command -v gh' (expected 0; refactor regressed)"
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
echo "== C6: solve-pipeline skill exists (#15 refactor) =="
if [[ -f "$SOLVE_PIPELINE" ]]; then
  echo "  PASS  solve-pipeline/SKILL.md exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL  solve-pipeline/SKILL.md missing"
  FAIL=$((FAIL + 1))
fi

# Frontmatter audit: forbid `context: fork` (would isolate skill from caller's
# shell scope; see spec Risk 2).
if awk '/^---$/{f=!f; if(!f){exit}; next} f' "$SOLVE_PIPELINE" | grep -qE '^context:'; then
  echo "  FAIL  solve-pipeline/SKILL.md has a forbidden 'context:' frontmatter key (must render inline)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  solve-pipeline/SKILL.md has no 'context:' frontmatter key (renders inline)"
  PASS=$((PASS + 1))
fi

# Rename audit: AUTO_PERMISSIONS must appear (Risk 1 mitigation).
perm_count=$(grep -c 'AUTO_PERMISSIONS' "$SOLVE_PIPELINE")
if [ "$perm_count" -ge 3 ]; then
  echo "  PASS  solve-pipeline mentions AUTO_PERMISSIONS in $perm_count places (≥ 3 required)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  solve-pipeline mentions AUTO_PERMISSIONS in only $perm_count place(s) (expected ≥ 3)"
  FAIL=$((FAIL + 1))
fi

# pr-test-analyzer Gap #3 (#15 collision guard): the legacy permission-mode
# pattern `[[ "$AUTO_MODE" == "1" ]] && PERM_FLAG_VAL=...` must NOT reappear.
# AUTO_MODE is now the turbo flag; the permission-mode flag is AUTO_PERMISSIONS.
# A copy-paste accident reintroducing the old pattern would silently alias the
# two semantics — the test catches it.
if grep -qE '\[\[ "\$AUTO_MODE" == "1" \]\][[:space:]]*&&[[:space:]]*PERM_FLAG_VAL' "$SOLVE_PIPELINE"; then
  echo "  FAIL  solve-pipeline contains legacy AUTO_MODE/PERM_FLAG_VAL pattern (Risk 1 collision regression)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  solve-pipeline does NOT contain legacy AUTO_MODE/PERM_FLAG_VAL pattern (collision guard intact)"
  PASS=$((PASS + 1))
fi

echo
echo "== C7: thin /solve and /turbo line-count budget (#15 refactor) =="
for f in "$SOLVE_CMD" "$TURBO_CMD"; do
  lc=$(wc -l < "$f")
  if [ "$lc" -le 100 ]; then
    echo "  PASS  $(basename "$f") is $lc lines (≤ 100)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $(basename "$f") is $lc lines (> 100; #15 thin-wrapper budget violated)"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
