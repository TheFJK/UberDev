#!/usr/bin/env bash
# Shape-check for the v0.28.0 small-team issue-claim protocol.
#
# The protocol spans three surfaces:
#   1. solve-pipeline/SKILL.md — Phase A claim-collision check (Step 4),
#      claim-write loop (Step 4.5), Phase B dispatch-failure rollback.
#   2. merge-pipeline/SKILL.md — Step 3.4 post-merge issue cleanup.
#   3. commands/turbo.md + commands/solve.md — --force flag documentation.
#
# This test is structural-grep only — it does NOT exercise live `gh` calls
# (that would require a scratch GitHub repo and auth). Behavioural smoke
# is documented in docs/uberdev/specs/.../verification.md and run manually
# per the plan file. The grep shape-checks lock the structure so a
# refactor that accidentally drops one of the three claim writes, or
# silently flips fail-loud to fail-soft, fails CI loudly.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
MERGE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
TURBO_CMD="$REPO_ROOT/plugins/uberdev/commands/turbo.md"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
PLUGIN_JSON="$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
README="$REPO_ROOT/README.md"

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

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        pattern: $pattern (must not appear)"
    echo "        file:    $file"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== Claim-protocol constants bound shell-side =="
assert_grep "$SOLVE_PIPELINE" \
  "^UBERDEV_ACTIVE_LABEL='uberdev:active'" \
  "UBERDEV_ACTIVE_LABEL bound to 'uberdev:active'"
assert_grep "$SOLVE_PIPELINE" \
  "^UBERDEV_ACTIVE_LABEL_COLOR='D93F0B'" \
  "UBERDEV_ACTIVE_LABEL_COLOR bound to warning-orange D93F0B"
assert_grep "$SOLVE_PIPELINE" \
  "^UBERDEV_ACTIVE_LABEL_DESCRIPTION='Issue currently being worked on" \
  "UBERDEV_ACTIVE_LABEL_DESCRIPTION bound (warns against manual edits)"
assert_grep "$SOLVE_PIPELINE" \
  "^CLAIM_COMMENT_MARKER='<!-- uberdev-claim-comment v1 -->'" \
  "CLAIM_COMMENT_MARKER bound (v1 schema)"

echo "== --force flag parser =="
assert_grep "$SOLVE_PIPELINE" \
  "FORCE_FLAG=.*grep -E '\\^\\(--force\\|-f\\)\\\$'" \
  "FORCE_FLAG parser anchors on ^(--force|-f)$ (rejects --force-foo)"
assert_grep "$SOLVE_PIPELINE" \
  "^  FORCE_CLAIM=1$" \
  "FORCE_CLAIM=1 set when flag present"
assert_grep "$SOLVE_PIPELINE" \
  "^  FORCE_CLAIM=0$" \
  "FORCE_CLAIM=0 default"

echo "== Phase A: gh issue view JSON extended with assignees,comments =="
assert_grep "$SOLVE_PIPELINE" \
  "gh issue view .*--json number,title,state,body,labels,assignees,comments" \
  "ISSUE_JSON projection now includes assignees,comments for collision check"

echo "== Phase A: collision check =="
assert_grep "$SOLVE_PIPELINE" \
  'jq -r .\[.labels\[\].name\] \| index\("uberdev:active"\)' \
  "Collision check filters .labels for uberdev:active via jq index"
assert_grep "$SOLVE_PIPELINE" \
  'jq -r --arg marker "\$CLAIM_COMMENT_MARKER"' \
  "Latest claim comment lookup uses CLAIM_COMMENT_MARKER fingerprint"
assert_grep "$SOLVE_PIPELINE" \
  "select\(.body \| contains\(\\\$marker\)\)\] \| last" \
  "Latest claim is .[-1] of marker-matching comments"
assert_grep "$SOLVE_PIPELINE" \
  "grep -m1 '\\^User: '" \
  "User field extracted from claim comment"
assert_grep "$SOLVE_PIPELINE" \
  "grep -m1 '\\^Host: '" \
  "Host field extracted from claim comment"
assert_grep "$SOLVE_PIPELINE" \
  "grep -m1 '\\^Branch: '" \
  "Branch field extracted from claim comment"
assert_grep "$SOLVE_PIPELINE" \
  "grep -m1 '\\^Started: '" \
  "Started timestamp extracted from claim comment"
assert_grep "$SOLVE_PIPELINE" \
  'ERRORS\+=\("#\$ISSUE_NUM: already claimed by .* pass --force to override"\)' \
  "Refusal message names the prior claim and points to --force"
assert_grep "$SOLVE_PIPELINE" \
  "--force override in effect" \
  "FORCE_CLAIM=1 path emits warning"

echo "== Phase A: claim-write loop (Step 4.5) =="
assert_grep "$SOLVE_PIPELINE" \
  '^### 4\.5\. Claim protocol' \
  "Step 4.5 sub-section header present"
assert_grep "$SOLVE_PIPELINE" \
  'gh label create --force "\$UBERDEV_ACTIVE_LABEL"' \
  "Idempotent gh label create (matches finish-branch/dev-pipeline pattern)"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCHER_USER=\$\(gh api user --jq \.login' \
  "DISPATCHER_USER from gh api user (matches @me assignee)"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCHER_HOST=\$\(hostname -s' \
  "DISPATCHER_HOST from hostname -s (short form)"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCH_TS=\$\(date -u \+%FT%TZ\)' \
  "DISPATCH_TS in ISO-8601 UTC"
assert_grep "$SOLVE_PIPELINE" \
  '^_uberdev_rollback_claims\(\) \{' \
  "_uberdev_rollback_claims helper defined"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue edit "\$ISSUE_NUM" --add-label "\$UBERDEV_ACTIVE_LABEL"' \
  "Per-issue add-label call"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue edit "\$ISSUE_NUM" --add-assignee "@me"' \
  "Per-issue add-assignee @me call"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue comment "\$ISSUE_NUM" --body-file -' \
  "Per-issue audit comment via --body-file -"
assert_grep "$SOLVE_PIPELINE" \
  "/tmp/solve-claim-\\\$ISSUE_NUM.json" \
  "Per-issue claim metadata persisted to /tmp"
assert_grep "$SOLVE_PIPELINE" \
  "exit 1" \
  "Claim-write failures exit 1 (fail-loud, not fail-soft)"

echo "== Phase B: dispatch-failure rollback =="
assert_grep "$SOLVE_PIPELINE" \
  "claim rollback on dispatch failure" \
  "Phase B rollback comment marker present"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue edit "\$ISSUE_NUM" --remove-label "\$UBERDEV_ACTIVE_LABEL"' \
  "Rollback removes uberdev:active label"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue edit "\$ISSUE_NUM" --remove-assignee "@me"' \
  "Rollback removes @me assignee"
assert_grep "$SOLVE_PIPELINE" \
  "uberdev:active claim released .* dispatch failed" \
  "Rollback posts release-comment to issue"

echo "== Audit-event emissions (all 5 claim_* events) =="
for evt in claim_acquired claim_collision claim_force_override claim_write_failed claim_released; do
  assert_grep "$SOLVE_PIPELINE" \
    "_uberdev_audit_emit $evt" \
    "$evt event emitted from solve-pipeline"
done

echo "== Audit-enum membership (all 5 claim_* events listed) =="
for evt in claim_acquired claim_collision claim_force_override claim_write_failed claim_released; do
  assert_grep "$SOLVE_PIPELINE" \
    "\`$evt\`" \
    "$evt listed in SOLVE_AUDIT_EVENT_ENUM Constants table"
done

echo "== Constants table updates =="
assert_grep "$SOLVE_PIPELINE" \
  "\\\`UBERDEV_ACTIVE_LABEL\\\` \\| \\\`uberdev:active\\\`" \
  "UBERDEV_ACTIVE_LABEL entry in Constants table"
assert_grep "$SOLVE_PIPELINE" \
  "\\\`CLAIM_COMMENT_MARKER\\\` \\| \\\`<!-- uberdev-claim-comment v1 -->\\\`" \
  "CLAIM_COMMENT_MARKER entry in Constants table"

echo "== Security: no Co-Authored-By in claim or release bodies =="
# CLAIM_BODY and RELEASE_BODY heredocs must NEVER include Claude attribution
# per global CLAUDE.md rule (no Co-Authored-By: Claude in any commit/PR/comment).
# This is a regression guard — if someone copies a Co-Authored-By line into the
# heredoc, this test fails.
assert_grep_not "$SOLVE_PIPELINE" \
  "Co-Authored-By: Claude" \
  "No Co-Authored-By: Claude trailer in solve-pipeline (claim/release bodies)"
assert_grep_not "$SOLVE_PIPELINE" \
  "Generated with .* Claude Code" \
  "No Generated with Claude Code footer in solve-pipeline"

echo "== merge-pipeline: Step 3.4 post-merge cleanup + Step 3.5 rename =="
assert_grep "$MERGE_PIPELINE" \
  '^### Step 3\.4 .* Post-merge issue cleanup' \
  "Step 3.4 post-merge cleanup section header present"
assert_grep "$MERGE_PIPELINE" \
  '^### Step 3\.5 .* Failure-mode summary' \
  "Step 3.5 (renamed from 3.4) Failure-mode summary header present"
assert_grep "$MERGE_PIPELINE" \
  'grep -oiE .*close\[sd\]\?\|fix\(e\[sd\]\)\?\|resolve\[sd\]\?' \
  "Closing-keyword regex parses Closes/Fixes/Resolves (case-insensitive)"
assert_grep "$MERGE_PIPELINE" \
  'gh issue edit "\$CLEAR_ISSUE_NUM" --remove-label "uberdev:active"' \
  "merge-pipeline removes uberdev:active label on merged issue"
assert_grep "$MERGE_PIPELINE" \
  "_uberdev_audit_emit uberdev_active_label_cleared" \
  "merge-pipeline emits uberdev_active_label_cleared event"
assert_grep "$MERGE_PIPELINE" \
  "\`uberdev_active_label_cleared\`" \
  "uberdev_active_label_cleared listed in AUDIT_EVENT_ENUM"
assert_grep_not "$MERGE_PIPELINE" \
  '^### Step 3\.4 .* Failure-mode summary' \
  "Old Step 3.4 'Failure-mode summary' header is gone (renamed to 3.5)"

echo "== commands/turbo.md: --force documented =="
assert_grep "$TURBO_CMD" \
  '\[--force\]' \
  "turbo.md argument-hint and Usage include [--force]"
assert_grep "$TURBO_CMD" \
  '`--force` / `-f`' \
  "turbo.md has --force / -f flag bullet"
assert_grep "$TURBO_CMD" \
  "small-team issue-claim protocol" \
  "turbo.md mentions small-team claim protocol"
assert_grep "$TURBO_CMD" \
  "claim_force_override" \
  "turbo.md mentions claim_force_override audit event"

echo "== commands/solve.md: --force documented =="
assert_grep "$SOLVE_CMD" \
  '\[--force\]' \
  "solve.md argument-hint and Usage include [--force]"
assert_grep "$SOLVE_CMD" \
  '`--force` / `-f`' \
  "solve.md has --force / -f flag bullet"
assert_grep "$SOLVE_CMD" \
  "small-team issue-claim protocol" \
  "solve.md mentions small-team claim protocol"

echo "== Version bump 0.27.1 -> 0.28.0 propagated =="
assert_grep "$PLUGIN_JSON" \
  '"version": "0.28.0"' \
  "plugin.json bumped to 0.28.0"
assert_grep "$MARKETPLACE_JSON" \
  '"version": "0.28.0"' \
  "marketplace.json bumped to 0.28.0"
assert_grep "$README" \
  "version-0\\.28\\.0-blue" \
  "README version badge bumped to 0.28.0"
assert_grep "$CHANGELOG" \
  '^## \[0\.28\.0\]' \
  "CHANGELOG has [0.28.0] section header"

echo ""
echo "Summary: $PASS pass, $FAIL fail"
exit $FAIL
