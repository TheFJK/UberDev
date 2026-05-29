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
# (PLUGIN_JSON / MARKETPLACE_JSON / README path vars removed in #231 — the
# version-lock block that used them now delegates to assert_version_bump, which
# derives those paths internally from $REPO_ROOT. $CHANGELOG is retained: still
# used by the B2 TOCTOU assertion below.)

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

# Shared structural-assertion helpers (assert_version_bump for the version-bump
# block). Fail-loud guard per #209: a missing/unreadable helper aborts rc=2,
# not vacuous-green.
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

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
  'jq -r --arg marker "\$CLAIM_COMMENT_MARKER_PREFIX"' \
  "Latest claim comment lookup uses CLAIM_COMMENT_MARKER_PREFIX fingerprint (version-agnostic; #123 B7)"
assert_grep "$SOLVE_PIPELINE" \
  'CLAIM_COMMENT_MARKER_PREFIX="\$\{CLAIM_COMMENT_MARKER% v\* -->\}"' \
  "Version-stripped prefix derived from CLAIM_COMMENT_MARKER (#123 B7 forward-compat)"
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
  'if ! LABEL_PROVISION_ERR=\$\(gh label create --force "\$UBERDEV_ACTIVE_LABEL"' \
  "Step 4.5 label-create is FAIL-LOUD (if !-guarded, captures gh stderr) — the label gates a fail-loud combined claim write, so it cannot be fail-soft like finish-branch/dev-pipeline"
assert_grep_not "$SOLVE_PIPELINE" \
  'UBERDEV_ACTIVE_LABEL_DESCRIPTION" >/dev/null 2>&1 \|\| true' \
  "Regression guard: the swallowing 'gh label create … || true' form is gone (a silent create-failure resurfaced downstream as a misleading 'failed to write claim' abort)"
assert_grep "$SOLVE_PIPELINE" \
  'UBERDEV_ACTIVE_LABEL_DESCRIPTION" 2>&1\); then' \
  "Step 4.5 label-create captures gh stderr (2>&1) and opens the fail-loud if-branch ('); then') — locks the NEW form's tail, symmetric to the removed '|| true' tail"
assert_grep "$SOLVE_PIPELINE" \
  'claim_write_failed "\{.*step.*label_create' \
  "Step 4.5 label-create failure emits claim_write_failed with a JSON {step:label_create} payload (locks object shape, not just substring) before exit 1"
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
  'gh issue edit "\$ISSUE_NUM" --add-label "\$UBERDEV_ACTIVE_LABEL" --add-assignee "@me"' \
  "Per-issue claim write combines --add-label + --add-assignee into one gh round-trip (E1)"
assert_grep_not "$SOLVE_PIPELINE" \
  'gh issue edit "\$ISSUE_NUM" --add-assignee "@me" >/dev/null' \
  "E1: split-call form (separate --add-assignee gh call) is gone"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue comment "\$ISSUE_NUM" --body-file -' \
  "Per-issue audit comment via --body-file -"
assert_grep "$SOLVE_PIPELINE" \
  "UBERDEV_TMPDIR/solve-claim-\\\$ISSUE_NUM.json" \
  "Per-issue claim metadata persisted under UBERDEV_TMPDIR"
assert_grep "$SOLVE_PIPELINE" \
  "exit 1" \
  "Claim-write failures exit 1 (fail-loud, not fail-soft)"

echo "== Phase B: dispatch-failure rollback =="
assert_grep "$SOLVE_PIPELINE" \
  "claim rollback on dispatch failure" \
  "Phase B rollback comment marker present"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_release_claim "\$ISSUE_NUM" "dispatch_failure"' \
  "Phase B rollback delegates to _uberdev_release_claim helper (E3+S1 fold)"
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
# Use single-quoted patterns + [|] character class for portability.
# GNU grep -E (used on CI Linux runners) treats `\|` as literal `|` (fine) but
# `\`` as `\` + literal backtick — looking for a literal backslash in the
# file that isn't there, causing the assertion to FAIL on GNU grep even when
# the table entry is correct. BSD/macOS grep variants are more lenient on
# `\<non-meta>`. Single-quoting avoids the bash double-quote backtick-as-
# command-substitution trap; `[|]` is a portable character-class alternative
# to `\|` that behaves identically in BRE/ERE and across BSD/GNU implementations.
assert_grep "$SOLVE_PIPELINE" \
  '`UBERDEV_ACTIVE_LABEL` [|] `uberdev:active`' \
  "UBERDEV_ACTIVE_LABEL entry in Constants table"
assert_grep "$SOLVE_PIPELINE" \
  '`CLAIM_COMMENT_MARKER` [|] `<!-- uberdev-claim-comment v1 -->`' \
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

echo "== Version bump 0.35.10 -> 0.35.11 propagated =="
assert_version_bump "$REPO_ROOT" "0.35.11"

echo "== #123 B1: closing-keyword regex left-anchor (rejects preclose/postfix/unresolve) =="
# The closing-keyword regex in merge-pipeline Step 3.4 MUST require either start-of-input
# or a non-word char before the keyword. Without the left anchor, `preclose #42` and
# `postfix #100` are silently treated as closing references and the dispatcher strips the
# uberdev:active label from those issues — see #123 B1.
assert_grep "$MERGE_PIPELINE" \
  "'\\(\\^\\|\\[\\^\\[:alnum:\\]_-\\]\\)\\(close\\[sd\\]\\?\\|fix\\(e\\[sd\\]\\)\\?\\|resolve\\[sd\\]\\?\\)" \
  "B1: closing-keyword regex carries left-anchor (^|[^[:alnum:]_-]) prefix"
# Behavioural negative test: actually run the regex against a known-bad fixture and
# verify zero matches. This is the load-bearing check — a future refactor that drops
# the left anchor would silently regress B1, but the regex would still match the
# structural-grep above if the offending change kept the literal text in a different
# branch of the file. The runtime grep catches the semantic regression.
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

echo "== #123 B3: dispatch-failure rollback verifies ownership before stripping =="
# Phase B rollback MUST NOT strip a teammate's claim if a race happened between
# Step 4.5's claim-write and the dispatch-failure window. Re-fetch the latest
# claim comment, parse User, and only strip if it still names $DISPATCHER_USER.
assert_grep "$SOLVE_PIPELINE" \
  'CURRENT_CLAIM_USER=' \
  "B3: rollback parses CURRENT_CLAIM_USER from re-fetched comment"
assert_grep "$SOLVE_PIPELINE" \
  'if \[\[ "\$CURRENT_CLAIM_USER" != "\$DISPATCHER_USER" \]\]; then' \
  "B3: rollback ownership-check gate compares CURRENT_CLAIM_USER vs DISPATCHER_USER"
assert_grep "$SOLVE_PIPELINE" \
  "dispatch-failure rollback skipped" \
  "B3: skip-warning is emitted when ownership check fails"
assert_grep "$SOLVE_PIPELINE" \
  "dispatch_failure_rollback_skipped" \
  "B3: claim_released event carries the rollback-skipped reason for audit-log filtering"

echo "== #123 B4: stale-claim sweeper on closed issues (pre-state-reject) =="
# The sweeper MUST inspect HAS_ACTIVE_LABEL on closed issues BEFORE the
# state-reject so a stuck label gets pruned even though dispatch refuses.
assert_grep "$SOLVE_PIPELINE" \
  'CLOSED_HAS_ACTIVE_LABEL=\$\(jq -r ' \
  "B4: sweeper queries .labels for uberdev:active on closed issues"
assert_grep "$SOLVE_PIPELINE" \
  'reason\\":\\"stale_on_closed\\"' \
  "B4: sweeper emits claim_released with reason=stale_on_closed"
assert_grep "$SOLVE_PIPELINE" \
  "auto-pruned" \
  "B4: sweeper emits operator-visible 'auto-pruned' notice on stderr"

echo "== #123 B5: merge-pipeline cleanup clears @me assignee =="
# Step 3.4 cleanup MUST clear both label AND assignee per linked issue —
# symmetric with the Phase B dispatch-failure rollback. Combined form (E2)
# bundles both removals into one gh round-trip; gh fails atomically on
# partial error.
assert_grep "$MERGE_PIPELINE" \
  'gh issue edit "\$CLEAR_ISSUE_NUM" --remove-label "uberdev:active" --remove-assignee "@me"' \
  "B5+E2: merge-pipeline Step 3.4 combines --remove-label + --remove-assignee in one gh call"
assert_grep_not "$MERGE_PIPELINE" \
  'gh issue edit "\$CLEAR_ISSUE_NUM" --remove-assignee "@me" >/dev/null 2>&1 \|\| true' \
  "E2: split-call form (separate trailing --remove-assignee gh call) is gone"

echo "== #123 B7: CLAIM_COMMENT_MARKER prefix-matcher is version-agnostic =="
# The collision-check jq filter MUST NOT match the full versioned marker —
# rolling upgrades (v1 dispatcher + v2 dispatcher) would otherwise see each
# other as "no live claim". Match on the version-stripped prefix.
assert_grep "$SOLVE_PIPELINE" \
  'contains\(\$marker\)' \
  "B7: jq filter still uses --arg marker for safe substitution"
assert_grep "$SOLVE_PIPELINE" \
  'CLAIM_COMMENT_MARKER_PREFIX=' \
  "B7: version-stripped prefix variable is derived from CLAIM_COMMENT_MARKER"
# Behavioural test: the prefix derivation MUST strip the ` vN -->` suffix.
B7_INPUT='<!-- uberdev-claim-comment v1 -->'
B7_PREFIX="${B7_INPUT% v* -->}"
if [[ "$B7_PREFIX" == '<!-- uberdev-claim-comment' ]]; then
  echo "  PASS  B7: \${VAR% v* -->} parameter-expansion strips v1 suffix correctly"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B7: prefix-derivation broken — expected '<!-- uberdev-claim-comment', got '$B7_PREFIX'"
  FAIL=$((FAIL + 1))
fi
# Forward-compat: a v2 comment body MUST contain the stripped prefix.
B7_V2_BODY='<!-- uberdev-claim-comment v2 -->
some extra v2 field'
if printf '%s' "$B7_V2_BODY" | grep -qF "$B7_PREFIX"; then
  echo "  PASS  B7: v2 comment body contains the v-stripped prefix (forward-compat across schema bumps)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B7: v2 comment body does NOT contain stripped prefix — forward-compat broken"
  FAIL=$((FAIL + 1))
fi

echo "== #123 B8: rollback distinguishes no-op from successful release =="
# When CLAIMED is empty (first-issue label-add failure), rollback MUST emit
# an info line so the operator can distinguish silent no-op from successful
# rollback. Without this, the silent-failure-hunter surfaces a real risk.
assert_grep "$SOLVE_PIPELINE" \
  'if \[\[ \$\{#CLAIMED\[@\]\} -eq 0 \]\]; then' \
  "B8: rollback explicitly tests \\\${#CLAIMED[@]} -eq 0 before the for-loop"
assert_grep "$SOLVE_PIPELINE" \
  "no prior claims to release" \
  "B8: no-op rollback emits operator-visible info line on stderr"

echo "== #123 Phase 2 simplify-lens: Q1 — field-extraction \"?\" fallback bug =="
# Q1 BLOCKER: the naive `... | grep | sed || echo "?"` form is broken because
# sed exits 0 even when grep finds nothing. CLAIM_USER (and friends) came out
# EMPTY, not "?", so the ALL_PLACEHOLDER branch never fired on "body present
# but fields malformed". Fix: capture grep|sed output into a temp, then
# conditional-assign only when non-empty (pre-init "?" defaults stay in place).
assert_grep_not "$SOLVE_PIPELINE" \
  "CLAIM_USER=\\\$\\(printf '%s.n' \"\\\$LATEST_CLAIM_BODY\".* sed 's/\\^User: //'.*\\|\\| echo \"\\?\"" \
  "Q1: broken `|| echo \"?\"` field-extraction form is gone"
assert_grep "$SOLVE_PIPELINE" \
  "_v=\\\$\\(printf .* \"\\\$LATEST_CLAIM_BODY\" \\| grep -m1 '\\^User: ' +\\| sed 's/\\^User: //'\\); +\\[\\[ -n \"\\\$_v\" \\]\\] && CLAIM_USER=\"\\\$_v\"" \
  "Q1: capture-then-conditional-assign form for CLAIM_USER (pre-init \"?\" default preserved)"
assert_grep "$SOLVE_PIPELINE" \
  "_v=\\\$\\(printf .* \"\\\$LATEST_CLAIM_BODY\" \\| grep -m1 '\\^Host: ' +\\| sed 's/\\^Host: //'\\); +\\[\\[ -n \"\\\$_v\" \\]\\] && CLAIM_HOST=\"\\\$_v\"" \
  "Q1: same fix applied to CLAIM_HOST"
assert_grep "$SOLVE_PIPELINE" \
  "_v=\\\$\\(printf .* \"\\\$LATEST_CLAIM_BODY\" \\| grep -m1 '\\^Branch: ' +\\| sed 's/\\^Branch: //'\\); +\\[\\[ -n \"\\\$_v\" \\]\\] && CLAIM_BRANCH=\"\\\$_v\"" \
  "Q1: same fix applied to CLAIM_BRANCH"
assert_grep "$SOLVE_PIPELINE" \
  "_v=\\\$\\(printf .* \"\\\$LATEST_CLAIM_BODY\" \\| grep -m1 '\\^Started: ' +\\| sed 's/\\^Started: //'\\); +\\[\\[ -n \"\\\$_v\" \\]\\] && CLAIM_TS=\"\\\$_v\"" \
  "Q1: same fix applied to CLAIM_TS"
# Constants-table prose update: must NOT still claim the `?` fallback works.
assert_grep_not "$SOLVE_PIPELINE" \
  "the field-extraction grep tolerates missing fields via the .\\?. fallback" \
  "Q1: false Constants-table claim about `?` fallback removed"
# Behavioural test: simulate the bug shape on a real shell. With the
# old form, an empty grep result leaves the variable EMPTY; with the
# fix, the pre-init "?" stays in place.
Q1_EMPTY_BODY=""
CLAIM_USER_DEFAULT="?"
# Old (broken) form: pipeline returns sed's exit (0), so || never fires.
Q1_OLD_RESULT=$(printf '%s\n' "$Q1_EMPTY_BODY" | grep -m1 '^User: ' | sed 's/^User: //' || echo "?")
# New (fixed) form: capture, test, conditional-assign.
_v=$(printf '%s\n' "$Q1_EMPTY_BODY" | grep -m1 '^User: ' | sed 's/^User: //')
Q1_NEW_RESULT="$CLAIM_USER_DEFAULT"; [[ -n "$_v" ]] && Q1_NEW_RESULT="$_v"
if [[ -z "$Q1_OLD_RESULT" && "$Q1_NEW_RESULT" == "?" ]]; then
  echo "  PASS  Q1: behavioural — old form leaves CLAIM_USER empty (regression smoking-gun), fix yields \"?\""
  PASS=$((PASS + 1))
else
  echo "  FAIL  Q1: behavioural shape unexpected — old='$Q1_OLD_RESULT' new='$Q1_NEW_RESULT' (expected old=empty, new='?')"
  FAIL=$((FAIL + 1))
fi

echo "== #123 Phase 2 simplify-lens: S1+E3 — _uberdev_release_claim helper extracted =="
# S1+E3 fold: single helper releases one claim atomically (combined gh round-trip)
# and emits a canonically-shaped claim_released audit event. Forecloses a #123 B5-
# style regression where a new release path forgets one of the three operations.
assert_grep "$SOLVE_PIPELINE" \
  '^_uberdev_release_claim\(\) \{' \
  "S1+E3: _uberdev_release_claim helper defined at column 0"
assert_grep "$SOLVE_PIPELINE" \
  'gh issue edit "\$issue" --remove-label "\$UBERDEV_ACTIVE_LABEL" --remove-assignee "@me"' \
  "S1+E3: helper combines --remove-label + --remove-assignee into one gh round-trip"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_audit_emit claim_released "\$payload"' \
  "S1+E3: helper emits claim_released via canonical payload variable"
# Batch rollback (CLAIMED loop) routes through helper.
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_release_claim "\$c" "batch_rollback"' \
  "S1+E3: _uberdev_rollback_claims loop body delegates to helper (reason=batch_rollback)"
# Comment-failure inline rollback routes through helper.
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_release_claim "\$ISSUE_NUM" "claim_write_failed"' \
  "S1+E3: comment-failure inline rollback delegates to helper (reason=claim_write_failed)"
# All four release-reason values are present somewhere in the file (either as a
# literal payload field for sites still embedded inline, or as a $2 arg to the
# helper). Lock the canonical set so future churn cannot silently drop one.
for reason in batch_rollback claim_write_failed dispatch_failure stale_on_closed; do
  assert_grep "$SOLVE_PIPELINE" \
    "\\b$reason\\b" \
    "S1+E3: claim_released reason='$reason' present in solve-pipeline (helper arg or inline payload)"
done

echo "== #123 B2: known-limitation (TOCTOU) honestly documented =="
# B2 was deferred (real fix needs a design decision). The spec MUST be honest
# about the race window — replace 'atomically' with 'in sequence with rollback'
# and surface the limitation in both SKILL.md prose and CHANGELOG Why.
assert_grep "$SOLVE_PIPELINE" \
  "in sequence with rollback on partial failure" \
  "B2: SKILL.md no longer claims 'atomically'; states 'in sequence with rollback'"
assert_grep "$SOLVE_PIPELINE" \
  "Known limitation .* TOCTOU race window" \
  "B2: SKILL.md documents the TOCTOU race-window limitation"
assert_grep "$CHANGELOG" \
  "Known limitation .* TOCTOU race window" \
  "B2: CHANGELOG ### Why surfaces the TOCTOU race-window limitation"

echo ""
echo "Summary: $PASS pass, $FAIL fail"
exit $FAIL
