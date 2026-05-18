#!/usr/bin/env bash
# Shape-check tests for /merge command (issue #24).
# Covers: command-file frontmatter contract, dispatcher-vs-skill split,
# skill phase headings, conflict-resolve safety guards, integration-branch
# config-read prose, no-Claude-trailer rule, atomic-rollback prose.
#
# Sections:
#   M1  — commands/merge.md exists, has frontmatter, has description,
#         argument-hint, allowed-tools.
#   M2  — commands/merge.md is ≤ 50 lines (thin-dispatcher contract).
#   M3  — commands/merge.md references uberdev:merge-pipeline skill (not merge-prs).
#   M4  — skills/merge-pipeline/SKILL.md has all four Phase headings (1..4).
#   M5  — SKILL.md uses git merge-tree --write-tree for conflict probe (D9).
#   M6  — SKILL.md references the .claude/worktrees/merge-<run-id> scratch path (D10).
#   M7  — SKILL.md documents the integration-branch precedence chain (D8).
#   M8  — SKILL.md mandates single-message Task() fanout for conflict-resolve (D12).
#   M9  — SKILL.md forbids --force against PR head refs (D13).
#   M10 — SKILL.md references .git/uberdev-merge.lock for single-instance lock (D14).
#   M11 — SKILL.md references .uberdev/runs/<run-id>/audit.jsonl (D15).
#   M12 — SKILL.md mandates pre-push test gate (D16, no skip path).
#   M13 — SKILL.md describes fork-PR preflight refusal for org-owned forks (Q3).
#   M14 — agents/conflict-resolver.md exists with frontmatter + return contract.
#   M15 — SKILL.md Phase 3 spells out chore(merge): commit format AND no-Claude-trailer rule (D13).
#   M16 — SKILL.md Phase 1 atomic-write uses same-directory mktemp pattern (D8a).
#   M17 — SKILL.md declares AUTO_CONFIRM_* constants (deprecated) and DEPRECATED_FLAGS_NOTE.
#   M18 — SKILL.md Phase 2.4 is unconditional autopilot (no ON/OFF branches, no [y/N] prompt).
#   M19 — SKILL.md Phase 4.5 carries autopilot affirmative-decision invariant.
#   M20 — commands/merge.md surfaces --yes / -y as DEPRECATED.
#   M21 — using-uberdev/SKILL.md flags auto_confirm as DEPRECATED.
#   M22 — SKILL.md STRATEGY_ENUM declares drop (and does NOT declare the removed `defer`).
#   M23 — SKILL.md AUDIT_EVENT_ENUM declares all new autopilot events.
#   M24 — SKILL.md declares PARK_REASON_ENUM, STRATEGY_REASON_ENUM, STALE_REBASE_DECISION_ENUM.
#   M25 — SKILL.md Phase 3.3v test-fail covers RE-RESOLVE/STRATEGY-SWITCH/PARK with bounds.
#   M26 — SKILL.md Phase 4.5 documents agent-decided rebase with safety preconditions.
#   M27 — SKILL.md run-summary block describes Parked outcomes.
#   M28 — SKILL.md pre-flight banner advertises the no-prompts-no-halts autopilot contract.
#   M29 — SKILL.md Phase 1.4 explicitly removes the PR-author allow-list as a gate condition.
#   M30 — SKILL.md Phase 1.3 falls back to literal `main` (no integration-branch prompt).
#   M31 — SKILL.md Phase 4.2 auto-rebases on ff-only fail (no halt).
#   M32 — SKILL.md Phase 3.3vi parks PR on push-non-FF (no halt).
#   M33 — SKILL.md Phase 2.1 auto-breaks dependency cycles (no halt).
#   M34 — SKILL.md Phase 3.4 failure-mode table contains no 'halt' actions.
#   M64 — SKILL.md run-summary per-PR detail block includes conflict-files sub-block
#         for parked PRs with per-file verdict + justification (issue #60).
#   M64 — SKILL.md Inputs "No args" bullet documents bare-discover dual path (single-PR fast path OR multi-discover fall-through).
#   M65 — SKILL.md Constants table declares DISCOVERY_FILTER exactly once with --base / --state open / draft:false.
#   M66 — SKILL.md Constants table declares BARE_MODE_FAST_PATH_QUERY exactly once with --head / --state open / draft:false.
#   M67 — SKILL.md Constants table declares PREFLIGHT_SUMMARY_FORMAT with literal "merging %d PR%s in order: %s" and 80-char wrap convention.
#   M68 — SKILL.md Step 1.0.5 mode-detect cites BARE_MODE_FAST_PATH_QUERY and three-way branch; does NOT mention DISCOVERY_FILTER (split-detection invariant).
#   M69 — SKILL.md Step 1.2.5 multi-discover dispatch cites DISCOVERY_FILTER and $integration_branch; does NOT mention BARE_MODE_FAST_PATH_QUERY (split-detection invariant).
#   M70 — SKILL.md Step 2.2 entry mentions PREFLIGHT_SUMMARY_FORMAT pre-flight line emitted in multi-discover mode only; full ordered set, not per-wave.
#   M71 — SKILL.md Step 1.7 cross-references bare-mode zero-eligible (clean exit 0); preserves "Not an error, not a halt" prose.
#   M72 — commands/merge.md frontmatter argument-hint omits --yes|-y; Usage bullet 1 documents context-aware bare-mode dual path.
#   M73 — SKILL.md Phase 1.4 prose preserves "for each" / "per discovered PR" fanout language; Step 2.2 preserves "ONE assistant turn" single-message invariant.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD_FILE="$REPO_ROOT/plugins/uberdev/commands/merge.md"
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
AGENT_FILE="$REPO_ROOT/plugins/uberdev/agents/conflict-resolver.md"

# Pre-flight: refuse to run if any asserted-against file is missing.
for f in "$CMD_FILE" "$SKILL_FILE"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL  $1"
  FAIL=$((FAIL + 1))
}

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    pass "$desc"
  else
    fail "$desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
  fi
}

# Negative-presence helper — mirrors `assert_no_grep` in
# tests/issue-causal-fanout.test.sh so the convention stays one-name across
# the suite. Use this instead of inline `if grep ... ; then FAIL=... else
# PASS=... fi` blocks for "must NOT match" assertions.
assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    fail "$desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
  else
    pass "$desc"
  fi
}

echo "== M1: commands/merge.md exists with required frontmatter =="
assert_grep "$CMD_FILE" '^description:' "M1.1 — has description key"
assert_grep "$CMD_FILE" '^argument-hint:' "M1.2 — has argument-hint key"
assert_grep "$CMD_FILE" '^allowed-tools:' "M1.3 — has allowed-tools key"

echo
echo "== M2: commands/merge.md is a thin dispatcher (≤ 75 lines) =="
# Cap raised from 50 to 75 in #89 to absorb the documented Inputs section
# (active config keys consumed by /merge — `auto_review_on_merge` and future
# additions). Still a thin dispatcher: SKILL.md owns the implementation.
LINE_COUNT=$(wc -l < "$CMD_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -le 75 ]; then
  pass "M2 — $LINE_COUNT lines (≤ 75)"
else
  fail "M2 — $LINE_COUNT lines (> 75, dispatcher should stay thin)"
fi

echo
echo "== M3: commands/merge.md references uberdev:merge-pipeline skill =="
assert_grep "$CMD_FILE" 'uberdev:merge-pipeline\b' \
  "M3 — invokes uberdev:merge-pipeline (renamed to disambiguate from /uberdev:merge command)"
# Negative: must NOT reference the rejected skill name 'merge-prs'.
if grep -qE 'merge-prs\b' "$CMD_FILE"; then
  fail "M3.neg — references rejected skill name 'merge-prs'"
else
  pass "M3.neg — does NOT reference rejected skill name 'merge-prs'"
fi
# Regression guard: must NOT invoke the bare `uberdev:merge` skill — that name
# collides with the /uberdev:merge command and causes double-load. The pattern
# `` `uberdev:merge` skill `` is a literal string with no regex metachars, so
# `assert_no_grep`'s ERE shape works identically while honouring the helper's
# stated contract (see helper docstring at line ~96).
assert_no_grep "$CMD_FILE" '`uberdev:merge` skill' \
  "M3.collision — does NOT reference the bare uberdev:merge skill (no command/skill name collision)"

echo
echo "== M4: skills/merge-pipeline/SKILL.md exists with all four phase headings =="
assert_grep "$SKILL_FILE" '^name: merge-pipeline$' \
  "M4.0 — skill frontmatter name field is 'merge-pipeline' (not 'merge')"
if [ -d "$REPO_ROOT/plugins/uberdev/skills/merge" ]; then
  fail "M4.neg — old skills/merge/ folder still present (rename incomplete)"
else
  pass "M4.neg — old skills/merge/ folder correctly removed (rename complete)"
fi
for n in 1 2 3 4; do
  case "$n" in
    1) heading='Pre-flight gate' ;;
    2) heading='Merge plan' ;;
    3) heading='Merge and conflict-resolve' ;;
    4) heading='Post-merge local sync' ;;
  esac
  assert_grep "$SKILL_FILE" "## Phase $n — $heading" \
    "M4.$n — Phase $n heading exists"
done

echo
echo "== M5: SKILL.md uses git merge-tree --write-tree for the conflict probe (D9) =="
assert_grep "$SKILL_FILE" 'git merge-tree --write-tree' \
  "M5 — references git merge-tree --write-tree (non-destructive probe)"

echo
echo "== M6: SKILL.md references the scratch worktree path pattern (D10) =="
assert_grep "$SKILL_FILE" '\.claude/worktrees/merge-' \
  "M6 — uses .claude/worktrees/merge-<run-id> scratch path"

echo
echo "== M7: SKILL.md documents the integration-branch precedence chain (D8) =="
assert_grep "$SKILL_FILE" '\.claude/uberdev\.local\.md' \
  "M7.1 — references .claude/uberdev.local.md (config tier)"
assert_grep "$SKILL_FILE" 'gh repo view --json defaultBranchRef' \
  "M7.2 — references gh repo view --json defaultBranchRef (fallback tier)"
assert_grep "$SKILL_FILE" 'UBERDEV_INTEGRATION_BRANCH' \
  "M7.3 — references env var UBERDEV_INTEGRATION_BRANCH"

echo
echo "== M8: SKILL.md mandates single-message Task() fanout for conflict-resolve (D12) =="
assert_grep "$SKILL_FILE" 'SINGLE ASSISTANT TURN|ONE assistant turn|single message' \
  "M8 — Phase 3 mandates single-message fanout"

echo
echo "== M9: SKILL.md forbids --force against PR head refs (D13) =="
assert_grep "$SKILL_FILE" 'Never `--force`|never --force|MUST NOT.*--force' \
  "M9 — explicit no-force-push prose"

echo
echo "== M10: SKILL.md references .git/uberdev-merge.lock for single-instance lock (D14) =="
assert_grep "$SKILL_FILE" '\.git/uberdev-merge\.lock' \
  "M10 — lock-file path declared"

echo
echo "== M11: SKILL.md references .uberdev/runs/<run-id>/audit.jsonl (D15) =="
assert_grep "$SKILL_FILE" '\.uberdev/runs/.*audit\.jsonl' \
  "M11 — audit log path declared"

echo
echo "== M12: SKILL.md mandates pre-push test gate runs ALWAYS, with agent-decided fail response =="
assert_grep "$SKILL_FILE" 'ALWAYS RUNS|test gate.*always' \
  "M12.1 — Phase 3.3v test gate ALWAYS RUNS prose present"
assert_grep "$SKILL_FILE" 'agent picks ONE of three|agent picks one of three|agent picks the best applicable branch' \
  "M12.2 — Phase 3.3v agent-decided test-fail response prose present"

echo
echo "== M13: SKILL.md describes fork-PR preflight refusal for org-owned forks (Q3) =="
assert_grep "$SKILL_FILE" 'maintainerCanModify' \
  "M13.1 — maintainerCanModify field consumed"
assert_grep "$SKILL_FILE" 'org-owned|Organization' \
  "M13.2 — fork-org refusal prose"

echo
echo "== M14: agents/conflict-resolver.md exists with frontmatter + return contract =="
if [ ! -r "$AGENT_FILE" ]; then
  fail "M14 — agent file missing: $AGENT_FILE"
else
  assert_grep "$AGENT_FILE" '^name: conflict-resolver' \
    "M14.1 — agent has name frontmatter key"
  assert_grep "$AGENT_FILE" '^model:' \
    "M14.2 — agent has model frontmatter key"
  assert_grep "$AGENT_FILE" 'status: RESOLVED \| AMBIGUOUS \| REFUSED' \
    "M14.3 — return-contract enum present"
  assert_grep "$AGENT_FILE" '^textual_evidence:' \
    "M14.4 — textual_evidence return key present"
fi

echo
echo "== M15: SKILL.md Phase 3 spells out resolution-commit format AND the no-Claude-trailer rule (D13) =="
# M15 is load-bearing: D13's rule forbids 'Co-Authored-By: Claude' trailer
# on the agent-generated resolution commit. Without this assertion, a
# well-meaning future edit could silently re-introduce the trailer.
assert_grep "$SKILL_FILE" 'chore\(merge\):' \
  "M15.1 — Conventional Commits prefix 'chore(merge):' literal present"
# Use grep -B5 -A5 to slice a 5-line bidirectional window around every
# 'Co-Authored-By' hit, then grep that window for 'MUST NOT'. This catches
# the marker whether it appears before OR after the Co-Authored-By literal,
# which awk's forward-streaming approach misses.
if grep -B5 -A5 'Co-Authored-By' "$SKILL_FILE" | grep -qE 'MUST NOT|must not'; then
  pass "M15.2 — 'MUST NOT' (or 'must not') near Co-Authored-By reference"
else
  fail "M15.2 — no 'MUST NOT' guard near Co-Authored-By in SKILL.md"
  echo "         (D13 mandates the resolution commit MUST NOT include the Claude trailer)"
fi

echo
echo "== M16: SKILL.md Phase 1.3 falls back to literal main without prompting OR writing to disk (autopilot) =="
# M16 was originally an atomic-rename mktemp guard for the ask-and-persist
# integration_branch flow in Step 1.3. That flow was removed when /merge
# became unconditional autopilot — autopilot does not ask, and so does not
# write. The replacement assertion verifies Step 1.3 is now a pure
# literal-fallback step: no `mktemp`, no `mv` (since there's nothing to
# persist), no `[Y/n]`. Without this negative guard, a well-meaning future
# edit could re-introduce ask-and-persist and silently re-add a prompt.
PHASE_1_3_BLOCK=$(awk '/^### Step 1\.3/,/^### Step 1\.4/' "$SKILL_FILE")
if echo "$PHASE_1_3_BLOCK" | grep -qE 'mktemp|\bmv\b|\[Y/n\]|persist the answer'; then
  fail "M16 — Phase 1.3 MUST NOT ask-and-persist; it falls back to INTEGRATION_BRANCH_FALLBACK with no disk write"
  echo "         (the prior atomic-rename pattern was removed alongside the prompt)"
else
  pass "M16 — Phase 1.3 is a pure literal-fallback step (no mktemp / no mv / no prompt)"
fi

# M16b — Phase 1.3 verifies the fallback branch exists on origin before proceeding.
# Without this, repos whose default branch is not `main` would hit a confusing
# `gh pr merge --base main` 404 several phases downstream.
if echo "$PHASE_1_3_BLOCK" | grep -qE 'git ls-remote.*--heads.*origin|fallback-branch-missing'; then
  pass "M16b — Phase 1.3 verifies fallback branch exists on origin before proceeding"
else
  fail "M16b — Phase 1.3 MUST verify the fallback branch exists on origin (\`git ls-remote --heads origin\`) and emit \`fallback-branch-missing\` on miss"
fi

echo
echo "== M17: SKILL.md declares AUTO_CONFIRM_* constants and the auto-confirm precedence chain =="
# M17 locks the new auto-confirm spec invariants from the PR that
# softened Phase 2.4. Without these asserts, a future "simplify the
# prose" pass could silently delete the constants or the precedence
# chain — the implementation would still work, but readers (human and
# LLM) would lose the contract.
assert_grep "$SKILL_FILE" '`AUTO_CONFIRM_KEY`' \
  "M17.1 — AUTO_CONFIRM_KEY constant declared"
assert_grep "$SKILL_FILE" '`AUTO_CONFIRM_FLAGS`' \
  "M17.2 — AUTO_CONFIRM_FLAGS constant declared (CLI flags)"
if grep -qE '^\| `AUTO_CONFIRM_DEFAULT_(SINGLE|MULTI)`' "$SKILL_FILE"; then
  fail "M17.3 — AUTO_CONFIRM_DEFAULT_(SINGLE|MULTI) constants must be REMOVED for autopilot (no scope-based default)"
else
  pass "M17.3 — AUTO_CONFIRM_DEFAULT_(SINGLE|MULTI) constants correctly absent (autopilot is unconditional)"
fi
assert_grep "$SKILL_FILE" 'Autopilot \(always ON\)|Autopilot.*always.*ON' \
  "M17.4 — Inputs section declares 'Autopilot (always ON)' (autopilot mode, no precedence chain)"
assert_grep "$SKILL_FILE" '`DEPRECATED_FLAGS_NOTE`' \
  "M17.5 — DEPRECATED_FLAGS_NOTE constant declared"
assert_grep "$SKILL_FILE" 'no behavioural effect' \
  "M17.6 — DEPRECATED_FLAGS_NOTE value contains 'no behavioural effect'"

echo
echo "== M18: SKILL.md Phase 2.4 is unconditional autopilot (no ON/OFF branches, no [y/N] prompt) =="
PHASE_2_4=$(awk '/^### Step 2\.4/,/^## Phase 3/' "$SKILL_FILE")
if echo "$PHASE_2_4" | grep -qE 'If auto-confirm is ON|If auto-confirm is OFF'; then
  fail "M18.1 — Phase 2.4 must NOT contain 'If auto-confirm is ON/OFF' branches (autopilot is unconditional)"
else
  pass "M18.1 — Phase 2.4 has NO ON/OFF branches (autopilot is unconditional)"
fi
if echo "$PHASE_2_4" | grep -qE 'autopilot|Autopilot'; then
  pass "M18.2 — Phase 2.4 carries autopilot prose"
else
  fail "M18.2 — Phase 2.4 MUST mention autopilot"
fi
# A positive prompt would have either [y/N] near it, OR `Apply this plan?` without
# a preceding "NO" / "no" within the same line. Scan for that pattern.
if echo "$PHASE_2_4" | grep -qE '\[y/N\].*Apply this plan\?|Apply this plan\?.*\[y/N\]'; then
  fail "M18.3 — Phase 2.4 must NOT contain a positive 'Apply this plan?' [y/N] prompt (autopilot is unconditional)"
elif echo "$PHASE_2_4" | grep -E 'Apply this plan\?' | grep -qvE '\bNO\b|\bno\b'; then
  fail "M18.3 — Phase 2.4 has 'Apply this plan?' without a NO/no qualifier (likely a positive prompt)"
else
  pass "M18.3 — Phase 2.4 has no positive 'Apply this plan?' prompt"
fi
if echo "$PHASE_2_4" | grep -qE 'autopilot-default'; then
  pass "M18.4 — Phase 2.4 emits 'autopilot-default' as data.reason for order_confirmed"
else
  fail "M18.4 — Phase 2.4 MUST emit data.reason='autopilot-default' for order_confirmed"
fi

echo
echo "== M19: SKILL.md Phase 4.5 carries the autopilot affirmative-decision invariant =="
PHASE_4_5=$(awk '/^### Step 4\.5/,/^### Step 4\.6/' "$SKILL_FILE")
if echo "$PHASE_4_5" | grep -qE 'never rebases without an explicit affirmative decision'; then
  pass "M19.1 — Phase 4.5 carries Q2 invariant 'never rebases without an explicit affirmative decision'"
else
  fail "M19.1 — Phase 4.5 MUST contain verbatim 'never rebases without an explicit affirmative decision'"
fi
if echo "$PHASE_4_5" | grep -qE "agent's typed decision-record is the affirmative form|typed decision-record is the affirmative form"; then
  pass "M19.2 — Phase 4.5 names the typed decision-record as the affirmative form"
else
  fail "M19.2 — Phase 4.5 MUST state 'the agent's typed decision-record is the affirmative form for autopilot mode'"
fi
if echo "$PHASE_4_5" | grep -qE 'If auto-confirm is ON|If auto-confirm is OFF'; then
  fail "M19.3 — Phase 4.5 must NOT branch on auto-confirm (autopilot is unconditional)"
else
  pass "M19.3 — Phase 4.5 has no auto-confirm ON/OFF branching (autopilot is unconditional)"
fi
if echo "$PHASE_4_5" | grep -qE 'Force-push to PR head refs remains absolutely forbidden|Never `--force`|never --force|Force-push to PR head refs remains forbidden absolutely'; then
  pass "M19.4 — Phase 4.5 preserves the no-force-push invariant"
else
  fail "M19.4 — Phase 4.5 MUST preserve the 'no force-push to PR head refs' invariant"
fi

echo
echo "== M20: commands/merge.md surfaces --yes / -y as DEPRECATED with stable user-facing notice =="
# M20.1 / M20.2 retired in #56 (Q3 fix #3): --yes / -y dropped from the visible
# argument-hint and Usage signature per the deprecation lifecycle. The flag is
# still parsed at runtime, but the active-surface hint should reflect the
# supported surface only. Negative regression guards replace the old positives;
# the new M72.no-yes-flag-in-hint (issue #56) is the authoritative contract.
if grep -qE '^argument-hint:.*--yes\|-y' "$CMD_FILE"; then
  fail "M20.1 — argument-hint frontmatter MUST NOT list --yes|-y (deprecated; #56 Q3)"
else
  pass "M20.1 — argument-hint frontmatter correctly omits --yes|-y (deprecated; #56 Q3)"
fi
if grep -qE '^\*\*Usage:\*\*.*--yes\|-y' "$CMD_FILE"; then
  fail "M20.2 — Usage signature MUST NOT list --yes|-y (deprecated; #56 Q3)"
else
  pass "M20.2 — Usage signature correctly omits --yes|-y (deprecated; #56 Q3)"
fi
assert_grep "$CMD_FILE" '## Deprecated Flags' \
  "M20.3 — '## Deprecated Flags' section present"
assert_grep "$CMD_FILE" 'no behavioural effect' \
  "M20.4 — deprecation notice text 'no behavioural effect' present"
assert_grep "$CMD_FILE" '`--yes` / `-y`.*deprecated|deprecated.*`--yes` / `-y`' \
  "M20.5 — bullet for --yes / -y is annotated deprecated"
if grep -qE 'autopilot|Autopilot' "$CMD_FILE"; then
  pass "M20.6 — commands/merge.md mentions autopilot mode"
else
  fail "M20.6 — commands/merge.md MUST describe autopilot mode"
fi

echo
echo "== M21: using-uberdev/SKILL.md auto_confirm key documented as DEPRECATED =="
USING_SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
if [ ! -r "$USING_SKILL_FILE" ]; then
  fail "M21 — using-uberdev SKILL.md missing or unreadable: $USING_SKILL_FILE"
else
  assert_grep "$USING_SKILL_FILE" '^auto_confirm:' \
    "M21.1 — auto_confirm key still present in YAML example (parsed for backward compat)"
  assert_grep "$USING_SKILL_FILE" '\*\*`auto_confirm` precedence:\*\*' \
    "M21.2 — auto_confirm precedence paragraph still present (now flags deprecation)"
  if grep -qiE 'DEPRECATED' "$USING_SKILL_FILE"; then
    pass "M21.3 — using-uberdev/SKILL.md flags auto_confirm as DEPRECATED"
  else
    fail "M21.3 — using-uberdev/SKILL.md MUST flag auto_confirm as DEPRECATED"
  fi
fi

echo
echo "== M22: SKILL.md STRATEGY_ENUM declares drop (and does NOT declare the removed defer) =="
STRATEGY_ROW=$(grep -E '^\| `STRATEGY_ENUM` \|' "$SKILL_FILE" || true)
if echo "$STRATEGY_ROW" | grep -qE '`drop`'; then
  pass "M22.drop — STRATEGY_ENUM lists \`drop\`"
else
  fail "M22.drop — STRATEGY_ENUM row in Constants must list \`drop\`"
fi
if echo "$STRATEGY_ROW" | grep -qE '`defer`'; then
  fail "M22.no-defer — STRATEGY_ENUM MUST NOT list \`defer\` (the defer strategy was removed when author-identity gating was deleted)"
else
  pass "M22.no-defer — STRATEGY_ENUM correctly omits the removed \`defer\` strategy"
fi

echo
echo "== M23: SKILL.md AUDIT_EVENT_ENUM declares all autopilot events =="
# Cache the AUDIT_EVENT_ENUM row once; greps below run against the variable
# (mirrors the M22 STRATEGY_ROW pattern — one extraction, six in-memory checks).
AUDIT_EVENT_ROW=$(grep -E '^\| `AUDIT_EVENT_ENUM` \|' "$SKILL_FILE" || true)
for ev in pr_parked stale_branch_rebase_decision deprecated_flag_used agent_strategy_switch test_fail_agent_decision; do
  if echo "$AUDIT_EVENT_ROW" | grep -qE "\`$ev\`"; then
    pass "M23.$ev — AUDIT_EVENT_ENUM declares \`$ev\`"
  else
    fail "M23.$ev — AUDIT_EVENT_ENUM missing \`$ev\`"
  fi
done
# Negative assertion: pr_deferred was removed alongside the defer strategy.
if echo "$AUDIT_EVENT_ROW" | grep -qE '`pr_deferred`'; then
  fail "M23.no-pr_deferred — AUDIT_EVENT_ENUM MUST NOT list \`pr_deferred\` (removed alongside the defer strategy)"
else
  pass "M23.no-pr_deferred — AUDIT_EVENT_ENUM correctly omits the removed \`pr_deferred\` event"
fi

echo
echo "== M24: SKILL.md declares PARK_REASON_ENUM, STRATEGY_REASON_ENUM, STALE_REBASE_DECISION_ENUM =="
for c in PARK_REASON_ENUM STRATEGY_REASON_ENUM STALE_REBASE_DECISION_ENUM; do
  assert_grep "$SKILL_FILE" "\`$c\`" "M24.$c — \`$c\` constant declared"
done
# M24.PARK_REASON_ENUM values: test-fail-exhausted (kept) + push-non-ff (new); external-author-not-allow-listed removed.
assert_grep "$SKILL_FILE" '`test-fail-exhausted`' \
  "M24.PARK.test-fail — PARK_REASON_ENUM lists \`test-fail-exhausted\`"
assert_grep "$SKILL_FILE" '`push-non-ff`' \
  "M24.PARK.push-non-ff — PARK_REASON_ENUM lists \`push-non-ff\` (Phase 3.3vi parks instead of halting)"
PARK_ROW=$(grep -E '^\| `PARK_REASON_ENUM` \|' "$SKILL_FILE" || true)
if echo "$PARK_ROW" | grep -qE '`external-author-not-allow-listed`'; then
  fail "M24.PARK.no-ext-author — PARK_REASON_ENUM MUST NOT list \`external-author-not-allow-listed\` (author-identity gate removed)"
else
  pass "M24.PARK.no-ext-author — PARK_REASON_ENUM correctly omits the removed \`external-author-not-allow-listed\` reason"
fi

echo
echo "== M25: SKILL.md Phase 3.3v test-fail response covers re-resolve / strategy-switch / park =="
PHASE_3_3V=$(awk '/^v\. \*\*Pre-push test gate/,/^vi\. \*\*Push the resolution/' "$SKILL_FILE")
for branch in 'RE-RESOLVE' 'STRATEGY-SWITCH' 'PARK'; do
  if echo "$PHASE_3_3V" | grep -qE "$branch"; then
    pass "M25.$branch — Phase 3.3v documents $branch branch"
  else
    fail "M25.$branch — Phase 3.3v MUST document $branch branch (agent-decided test-fail response)"
  fi
done
if echo "$PHASE_3_3V" | grep -qE 'Max 1 retry|max.{0,5}1.{0,5}retry'; then
  pass "M25.bound-retry — Phase 3.3v bounds re-resolve to max 1 retry"
else
  fail "M25.bound-retry — Phase 3.3v MUST cap re-resolve at max 1 retry per PR per run"
fi
if echo "$PHASE_3_3V" | grep -qE 'Max 1 switch|max.{0,5}1.{0,5}switch'; then
  pass "M25.bound-switch — Phase 3.3v bounds strategy-switch to max 1 per PR per run"
else
  fail "M25.bound-switch — Phase 3.3v MUST cap strategy-switch at max 1 per PR per run"
fi
if echo "$PHASE_3_3V" | grep -qE 'max 3 test runs per PR per run|Worst-case test runs per PR per run:[[:space:]]*3|3 test runs per PR per run'; then
  pass "M25.worst-case — Phase 3.3v states max 3 test runs per PR per run"
else
  fail "M25.worst-case — Phase 3.3v MUST state max 3 test runs per PR per run (initial + re-resolve-retry + strategy-switch-retry)"
fi

echo
echo "== M26: SKILL.md Phase 4.5 documents agent-decided rebase with safety preconditions =="
PHASE_4_5=$(awk '/^### Step 4\.5/,/^### Step 4\.6/' "$SKILL_FILE")
if echo "$PHASE_4_5" | grep -qE 'never rebases without an explicit affirmative decision'; then
  pass "M26.invariant — Phase 4.5 carries the Q2 'never rebases without affirmative decision' invariant"
else
  fail "M26.invariant — Phase 4.5 MUST include verbatim 'never rebases without an explicit affirmative decision'"
fi
if echo "$PHASE_4_5" | grep -qE "agent's typed decision-record is the affirmative form|structured decision-record"; then
  pass "M26.affirmation — Phase 4.5 names the typed decision-record as the affirmative form"
else
  fail "M26.affirmation — Phase 4.5 MUST state the typed decision-record is the affirmative form for autopilot mode"
fi
for cond in 'merge-tree --write-tree' 'PR head ref' 'force-push'; do
  if echo "$PHASE_4_5" | grep -qE "$cond"; then
    pass "M26.precond[$cond] — Phase 4.5 references safety precondition: $cond"
  else
    fail "M26.precond[$cond] — Phase 4.5 MUST reference $cond as part of safety preconditions"
  fi
done
for choice in 'rebased-ff-clean' 'skipped-conflicts' 'skipped-pr-head-ref' 'rebase-aborted'; do
  if echo "$PHASE_4_5" | grep -qE "\`$choice\`"; then
    pass "M26.choice[$choice] — Phase 4.5 emits STALE_REBASE_DECISION_ENUM value \`$choice\`"
  else
    fail "M26.choice[$choice] — Phase 4.5 MUST document STALE_REBASE_DECISION_ENUM value \`$choice\`"
  fi
done

echo
echo "== M27: SKILL.md run-summary block describes Parked outcome =="
SUMMARY_BLOCK=$(awk '/^### Run-summary block/,/^## /' "$SKILL_FILE")
if echo "$SUMMARY_BLOCK" | grep -qE '^[[:space:]]*Parked:'; then
  pass "M27.Parked — run-summary block names Parked outcome at top level"
else
  fail "M27.Parked — run-summary block MUST list Parked: <count> at top level (alongside Merged/Skipped/Aborted)"
fi
# Negative: Deferred was removed alongside the defer strategy.
if echo "$SUMMARY_BLOCK" | grep -qE '^[[:space:]]*Deferred:'; then
  fail "M27.no-Deferred — run-summary block MUST NOT list Deferred: (removed alongside defer strategy)"
else
  pass "M27.no-Deferred — run-summary block correctly omits the removed Deferred outcome"
fi
for field in 'strategy:' 'rationale:' 'outcome:' 'park reason:'; do
  if echo "$SUMMARY_BLOCK" | grep -qiE "$field"; then
    pass "M27.field[$field] — run-summary detail block names \"$field\" field"
  else
    fail "M27.field[$field] — run-summary detail block MUST include \"$field\" field"
  fi
done

echo
echo "== M28: SKILL.md pre-flight banner advertises no-prompts-no-halts autopilot contract =="
# Scope the negative grep to JUST the Step 1.0 banner block — Phase 1.4
# legitimately mentions bot_authors_allow_list to call out its deprecated
# status, and that prose should not trip this assertion.
STEP_1_0=$(awk '/^### Step 1\.0/,/^### Step 1\.1/' "$SKILL_FILE")
if echo "$STEP_1_0" | grep -qE 'no prompts.*no halts|no halts.*no prompts'; then
  pass "M28.preflight — pre-flight banner advertises the no-prompts-no-halts autopilot contract"
else
  fail "M28.preflight — Step 1.0 banner MUST surface the no-prompts-no-halts autopilot contract verbatim"
fi
# Negative: legacy bot_authors_allow_list banner was removed from Step 1.0.
if echo "$STEP_1_0" | grep -qiE 'allow-listed authors|bot_authors_allow_list'; then
  fail "M28.no-allow-list — Step 1.0 banner MUST NOT print bot_authors_allow_list (the trust-boundary gate was removed)"
else
  pass "M28.no-allow-list — Step 1.0 banner correctly omits the removed bot_authors_allow_list listing"
fi

echo
echo "== M29: SKILL.md Phase 1.4 explicitly removes the PR-author allow-list as a gate condition =="
PHASE_1_4=$(awk '/^### Step 1\.4/,/^### Step 1\.5/' "$SKILL_FILE")
if echo "$PHASE_1_4" | grep -qiE 'Author identity is NOT a gate condition'; then
  pass "M29.no-author-gate — Phase 1.4 explicitly states author identity is NOT a gate"
else
  fail "M29.no-author-gate — Phase 1.4 MUST explicitly state \"Author identity is NOT a gate condition\""
fi
if echo "$PHASE_1_4" | grep -qiE 'PR author is repo collaborator|author\.login.*bot_authors_allow_list'; then
  fail "M29.no-old-condition — Phase 1.4 MUST NOT contain the old author-collaborator gate clause"
else
  pass "M29.no-old-condition — Phase 1.4 correctly omits the removed author-collaborator gate clause"
fi

echo
echo "== M30: SKILL.md Phase 1.3 falls back to literal main (no integration-branch prompt) =="
PHASE_1_3=$(awk '/^### Step 1\.3/,/^### Step 1\.4/' "$SKILL_FILE")
if echo "$PHASE_1_3" | grep -qE 'INTEGRATION_BRANCH_FALLBACK'; then
  pass "M30.fallback — Phase 1.3 references INTEGRATION_BRANCH_FALLBACK"
else
  fail "M30.fallback — Phase 1.3 MUST reference INTEGRATION_BRANCH_FALLBACK (literal main)"
fi
if echo "$PHASE_1_3" | grep -qiE 'Never prompt'; then
  pass "M30.never-prompt — Phase 1.3 explicitly forbids prompting"
else
  fail "M30.never-prompt — Phase 1.3 MUST explicitly state \"Never prompt the user\""
fi

echo
echo "== M31: SKILL.md Phase 4.2 auto-rebases on ff-only fail (no halt) =="
PHASE_4_2=$(awk '/^### Step 4\.2/,/^### Step 4\.3/' "$SKILL_FILE")
if echo "$PHASE_4_2" | grep -qE 'auto-rebase|git rebase origin/'; then
  pass "M31.auto-rebase — Phase 4.2 auto-rebases on ff-only fail"
else
  fail "M31.auto-rebase — Phase 4.2 MUST auto-rebase local onto origin on ff-only fail"
fi
if echo "$PHASE_4_2" | grep -qiE 'MUST NOT halt|never halt|does NOT halt'; then
  pass "M31.no-halt — Phase 4.2 explicitly forbids halting on local divergence"
else
  fail "M31.no-halt — Phase 4.2 MUST explicitly state the run does NOT halt on local divergence"
fi

echo
echo "== M32: SKILL.md Phase 3.3vi parks PR on push-non-FF (no halt) =="
PHASE_3_3VI=$(awk '/^vi\. \*\*Push the resolution/,/^vii\. /' "$SKILL_FILE")
if echo "$PHASE_3_3VI" | grep -qE 'park THIS PR|park.*drop.*push-non-ff|push-non-ff'; then
  pass "M32.park — Phase 3.3vi parks PR on push-non-FF"
else
  fail "M32.park — Phase 3.3vi MUST park PR via drop on push-non-FF (instead of halting)"
fi
if echo "$PHASE_3_3VI" | grep -qE 'continue with the next PR|queue does NOT halt|queue continues'; then
  pass "M32.continue — Phase 3.3vi states queue continues after park"
else
  fail "M32.continue — Phase 3.3vi MUST state the queue continues after parking the PR"
fi

echo
echo "== M33: SKILL.md Phase 2.1 auto-breaks dependency cycles (no halt) =="
PHASE_2_1=$(awk '/^### Step 2\.1/,/^### Step 2\.2/' "$SKILL_FILE")
if echo "$PHASE_2_1" | grep -qE 'createdAt|drop the cycle|fall through'; then
  pass "M33.auto-break — Phase 2.1 auto-breaks cycles via createdAt fallback"
else
  fail "M33.auto-break — Phase 2.1 MUST auto-break cycles (drop edges + fall through to createdAt order)"
fi
# Single positive check + explicit regression check against the OLD "never auto-break" rule.
if echo "$PHASE_2_1" | grep -qE 'Never halt|never halts'; then
  pass "M33.no-halt — Phase 2.1 explicitly forbids halting on cycle"
else
  fail "M33.no-halt — Phase 2.1 MUST contain 'Never halt' / 'never halts' (the cycle-auto-break contract)"
fi
# Negative regression guard: the OLD rule "Never auto-break" must be gone — it's
# now reversed (auto-break IS the new contract).
if echo "$PHASE_2_1" | grep -qE 'Never auto-break|never auto-break\b'; then
  fail "M33.no-old-rule — Phase 2.1 MUST NOT carry the old 'Never auto-break' prose (auto-break IS the new contract)"
else
  pass "M33.no-old-rule — Phase 2.1 correctly omits the reversed 'Never auto-break' rule"
fi

echo
echo "== M34: SKILL.md Phase 3.4 failure-mode table contains no 'halt' actions =="
# The table is the canonical contract for the no-halt invariant. M28/M29/...
# guard the prose; M34 guards the table directly. The Action column must
# never list 'halt' for any failure mode. Lock contention is in Phase 1.1
# (out-of-scope for this table); every Phase-3 failure mode here is a
# per-PR park or auto-recovery, never a queue halt.
PHASE_3_4=$(awk '/^### Step 3\.4/,/^## Phase 4/' "$SKILL_FILE")
# Look only at table rows (lines starting with `| `) inside Phase 3.4.
TABLE_HALT_ROWS=$(echo "$PHASE_3_4" | grep -E '^\| ' | grep -iE '\bhalt\b' || true)
if [ -z "$TABLE_HALT_ROWS" ]; then
  pass "M34 — Phase 3.4 failure-mode table lists no 'halt' actions"
else
  fail "M34 — Phase 3.4 failure-mode table MUST NOT list 'halt' as any Action; offending row(s):"
  echo "$TABLE_HALT_ROWS" | sed 's/^/         /'
fi

echo
echo "== M35: SKILL.md Phase 1.4 enumerated set drops PATH_3 (issue #47) =="
# M35: updated for issue #47 — PATH_3 retired; PATH_1 + PATH_2 only.
# Pre-redesign assertion that PATH_3 is named in Phase 1.4 is REMOVED, not extended.
PHASE_14_BODY=$(awk '/^### Step 1.4/,/^### Step 1.5/' "$SKILL_FILE")
if echo "$PHASE_14_BODY" | grep -qE 'PATH_1.*PATH_2|PATH_2.*PATH_1'; then
  echo "  PASS  M35.path12 — Phase 1.4 body still names PATH_1 and PATH_2"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M35.path12 — Phase 1.4 body must still name PATH_1 and PATH_2"
  FAIL=$((FAIL + 1))
fi
if echo "$PHASE_14_BODY" | grep -qE 'PATH_3'; then
  echo "  FAIL  M35.no-path3 — Phase 1.4 body must NOT name PATH_3 (retired in issue #47)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  M35.no-path3 — Phase 1.4 body correctly omits PATH_3 (retired)"
  PASS=$((PASS + 1))
fi
assert_grep "$SKILL_FILE" 'trust resolution|trust-resolution' "M35.reframe — trust-resolution reframe present"

echo
echo "== M36: SKILL.md gate_pass.data.trust_anchor enum values present (AC5) =="
assert_grep "$SKILL_FILE" 'reviewDecision_approved' "M36.tea1 — TRUST_ANCHOR_ENUM value reviewDecision_approved"
assert_grep "$SKILL_FILE" 'uberdev_review_trail'    "M36.tea2 — TRUST_ANCHOR_ENUM value uberdev_review_trail"
assert_grep "$SKILL_FILE" 'bypass_with_waiver'      "M36.tea3 — TRUST_ANCHOR_ENUM value bypass_with_waiver"

echo
echo "== M37: SKILL.md GATE_FAIL_REASON_ENUM — 13 members (issue #52, narrowed by #78) =="
# M37 row composition: 8 trust-resolution + 4 pre-condition + 1 infrastructure-failure = 13.
# Issue #52 split the (d) sub-condition's JSON-absent vs JSON-present-but-SHA-mismatch cases:
# absent → advisory only (by-design on fresh clone, see D1); present-but-mismatch → gate_fail
# trust_trail_json_sha_mismatch (genuine staleness signal). Earlier issue #47 added
# trust_trail_agent_invalid_input. v0.19.3 added the pr_view_unreachable infrastructure-failure
# reason (R2 lib-call failure), bringing the row total to 13. Issue #78 then narrowed the
# trust_trail_json_sha_mismatch *emission scope* (in Phase 1.4 (d) prose, not the enum row) from
# strict-SHA-equality to shape-malformed-only — the M37.gfr8 row-membership assertion below stays
# unchanged by #78 (deprecation pattern keeps the enum row); see M63.{strict-equality-retired,
# shape-malformed-narrow,inequality-phrasing-absent} for the prose-shape assertions that pin the
# narrowed emission scope. The four pre-condition reasons (pr_state_not_open / is_draft / ci_red /
# merge_state_blocked) are emitted by Step 1.4 pre-flight gates that fire regardless of trust path.
assert_grep "$SKILL_FILE" 'review_decision_not_approved'      "M37.gfr1 — trust-resolution reason review_decision_not_approved"
assert_grep "$SKILL_FILE" 'trust_trail_missing'                "M37.gfr2 — trust-resolution reason trust_trail_missing"
assert_grep "$SKILL_FILE" 'trust_trail_stale_sha'              "M37.gfr3 — trust-resolution reason trust_trail_stale_sha"
assert_grep "$SKILL_FILE" 'trust_trail_label_missing'          "M37.gfr4 — trust-resolution reason trust_trail_label_missing"
assert_grep "$SKILL_FILE" 'trust_trail_trailer_missing'        "M37.gfr5 — trust-resolution reason trust_trail_trailer_missing"
assert_grep "$SKILL_FILE" 'trust_trail_json_missing'           "M37.gfr6 — trust-resolution reason trust_trail_json_missing"
assert_grep "$SKILL_FILE" 'trust_trail_agent_invalid_input'    "M37.gfr7 — trust-resolution reason trust_trail_agent_invalid_input (NEW)"
assert_grep "$SKILL_FILE" 'trust_trail_json_sha_mismatch'      "M37.gfr8 — trust-resolution reason trust_trail_json_sha_mismatch (NEW; narrowed post-#78 — see M63.{strict-equality-retired,shape-malformed-narrow,inequality-phrasing-absent})"
assert_grep "$SKILL_FILE" 'pr_state_not_open'                  "M37.precond1 — pre-condition reason pr_state_not_open"
assert_grep "$SKILL_FILE" 'is_draft'                           "M37.precond2 — pre-condition reason is_draft"
assert_grep "$SKILL_FILE" 'ci_red'                             "M37.precond3 — pre-condition reason ci_red"
assert_grep "$SKILL_FILE" 'merge_state_blocked'                "M37.precond4 — pre-condition reason merge_state_blocked"
assert_grep "$SKILL_FILE" 'pr_view_unreachable'                "M37.infra1 — infrastructure-failure reason pr_view_unreachable (R2 lib-call failure)"
ENUM_ROW=$(grep -E '\| `GATE_FAIL_REASON_ENUM` \|' "$SKILL_FILE" || true)
# `[a-z_]+` matches lowercase snake_case reason tokens only (not the
# UPPERCASE enum-name `GATE_FAIL_REASON_ENUM` itself, and not dotted
# tokens like `gate_fail.data.reason`), so the count equals exactly
# the number of reasons backticked in the row: 8 trust-resolution + 4
# pre-condition + 1 infrastructure-failure (R2; v0.19.3) = 13.
REASON_COUNT=$(echo "$ENUM_ROW" | grep -oE '`[a-z_]+`' | wc -l | tr -d ' ')
if [ "$REASON_COUNT" -eq 13 ]; then
  echo "  PASS  M37.count — GATE_FAIL_REASON_ENUM row contains exactly 13 reasons (8 trust-resolution + 4 pre-condition + 1 infrastructure-failure)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M37.count — GATE_FAIL_REASON_ENUM row contains $REASON_COUNT reasons; expected exactly 13"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M38: SKILL.md stale-SHA detection compares trailer vs live headRefOid (AC7, AC10) =="
# Anchor on the verbatim "live" qualifier so a future implementer can't
# silently substitute a local ref. Two-of-three alternatives so phrasing
# variations don't false-fail.
assert_grep "$SKILL_FILE" \
  'live.*headRefOid|gh pr view.*--json headRefOid.*NOT.*local|NOT.*local ref' \
  "M38 — stale-SHA primitive compares against live headRefOid (not local ref)"
# Negative: must NOT compare against `git rev-parse HEAD` or `origin/<branch>`
# for the stale-SHA check (those are stale by definition vs. the PR head ref).
assert_no_grep "$SKILL_FILE" 'stale[- ]SHA.*git rev-parse HEAD' \
  "M38.no-local-ref — stale-SHA check does not compare against local git rev-parse HEAD"

echo
echo "== M39: SKILL.md RUN_ID_REGEX constant present (AC11) =="
assert_grep "$SKILL_FILE" '\| `RUN_ID_REGEX` \|' "M39 — RUN_ID_REGEX constant declared in Constants table"
assert_grep "$SKILL_FILE" '\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$' \
  "M39.regex — RUN_ID_REGEX value is the spec-mandated regex literal"

echo
echo "== M40: SKILL.md UBERDEV_APPROVED_LABEL constant present (AC1) =="
assert_grep "$SKILL_FILE" '\| `UBERDEV_APPROVED_LABEL` \|.*`uberdev-approved`' \
  "M40 — UBERDEV_APPROVED_LABEL constant declared with literal value"

echo
echo "== M41: SKILL.md REVIEW_PR_TRAILER_PREFIX constant present (AC13) =="
assert_grep "$SKILL_FILE" '\| `REVIEW_PR_TRAILER_PREFIX` \|.*Reviewed-by: uberdev/review-pr@' \
  "M41 — REVIEW_PR_TRAILER_PREFIX constant declared with literal trailer prefix"

echo
echo "== M42: SKILL.md TRUST_ANCHOR_ENUM constant present (AC5) =="
assert_grep "$SKILL_FILE" '\| `TRUST_ANCHOR_ENUM` \|' \
  "M42 — TRUST_ANCHOR_ENUM constant row declared"

echo
echo "== M43: SKILL.md GATE_FAIL_REASON_ENUM constant present (AC5) =="
assert_grep "$SKILL_FILE" '\| `GATE_FAIL_REASON_ENUM` \|' \
  "M43 — GATE_FAIL_REASON_ENUM constant row declared"

echo
echo "== M44: commands/merge.md mirror sites synced (AC6) =="
# Both mirror sites (lines 23 + 31 in the original spec; positions may have
# drifted slightly post-edit) must contain the PATH_1 + PATH_2 layered
# wording. Two assertions so a partial sync (one site updated, one
# stale) fails loudly.
PATH_HITS_CMD=$(grep -cE 'PATH_1.*PATH_2|PATH_2.*PATH_1' "$CMD_FILE" || true)
if [ "$PATH_HITS_CMD" -ge 2 ]; then
  echo "  PASS  M44 — commands/merge.md contains ≥ 2 mirror sites with PATH_1+PATH_2 layered wording"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M44 — commands/merge.md contains $PATH_HITS_CMD mirror sites; expected ≥ 2 (Autopilot paragraph + Deprecated Flags bullet)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M45: using-uberdev/SKILL.md mirror site synced (AC6) =="
# Path is repo-relative; resolve from REPO_ROOT.
USING_FILE="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
if [ ! -r "$USING_FILE" ]; then
  echo "  FAIL  M45 — required file missing: $USING_FILE"
  FAIL=$((FAIL + 1))
else
  assert_grep "$USING_FILE" 'PATH_1.*PATH_2|PATH_2.*PATH_1' \
    "M45 — using-uberdev/SKILL.md bot_authors_allow_list paragraph contains PATH_1+PATH_2 layered wording"
  # M45.trail: updated for issue #47 — T6 rewrote using-uberdev/SKILL.md mirror to
  # describe the agent-decided trail (ancestor + diff-empty + log-empty primitives,
  # verdict enum {PASS, STALE, INVALID, FORCE_PUSHED}). The old label+trailer
  # composition string was retired from this mirror site.
  assert_grep "$USING_FILE" 'trust-trail-evaluator' \
    "M45.trail — using-uberdev/SKILL.md names the trust-trail-evaluator agent"
  assert_grep "$USING_FILE" 'PASS, STALE, INVALID, FORCE_PUSHED|PASS.*STALE.*INVALID.*FORCE_PUSHED' \
    "M45.verdict — using-uberdev/SKILL.md cites the verdict enum"
fi

echo
echo "== M46: SKILL.md editor note corrected to 'five mirror sites' with enumeration (D8, AC14) =="
assert_grep "$SKILL_FILE" 'five mirror sites' "M46.count — editor note says 'five mirror sites' (not 'four mirrors')"
# Negative regression guard against the old wording.
assert_no_grep "$SKILL_FILE" 'those four mirrors' \
  "M46.no-old — old 'those four mirrors' wording removed"
# Enumeration: 5 numbered list entries citing file:section.
ENUM_HITS=$(grep -cE '^> [1-5]\. `plugins/uberdev/' "$SKILL_FILE" || true)
if [ "$ENUM_HITS" -eq 5 ]; then
  echo "  PASS  M46.enum — editor note enumerates exactly 5 mirror sites by file:path"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M46.enum — editor note has $ENUM_HITS enumerated mirror-site entries; expected 5"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M47: agents/trust-trail-evaluator.md exists with frontmatter + return contract =="
TTE_FILE="$REPO_ROOT/plugins/uberdev/agents/trust-trail-evaluator.md"
if [ ! -r "$TTE_FILE" ]; then
  echo "  FAIL  M47 — agent file missing: $TTE_FILE"
  FAIL=$((FAIL + 1))
else
  assert_grep "$TTE_FILE" '^name: trust-trail-evaluator'           "M47.1 — agent name frontmatter"
  assert_grep "$TTE_FILE" '^model: sonnet'                          "M47.2 — agent model frontmatter"
  assert_grep "$TTE_FILE" '^description: '                           "M47.3 — agent description frontmatter non-empty"
  assert_grep "$TTE_FILE" '^## Inputs'                              "M47.4 — Inputs section present"
  assert_grep "$TTE_FILE" '^## Tools authorised'                    "M47.5 — Tools authorised section present"
  assert_grep "$TTE_FILE" '^## Process'                             "M47.6 — Process section present"
  assert_grep "$TTE_FILE" '^## Refusal triggers'                    "M47.7 — Refusal triggers section present"
  assert_grep "$TTE_FILE" '^## Return contract'                     "M47.8 — Return contract section present"
  assert_grep "$TTE_FILE" 'verdict: PASS \| STALE \| INVALID \| FORCE_PUSHED' "M47.9 — verdict enum in return-contract YAML"
fi

echo
echo "== M48: agents/merge-strategy-decider.md exists with frontmatter + return contract =="
MSD_FILE="$REPO_ROOT/plugins/uberdev/agents/merge-strategy-decider.md"
if [ ! -r "$MSD_FILE" ]; then
  echo "  FAIL  M48 — agent file missing: $MSD_FILE"
  FAIL=$((FAIL + 1))
else
  assert_grep "$MSD_FILE" '^name: merge-strategy-decider'           "M48.1 — agent name frontmatter"
  assert_grep "$MSD_FILE" '^model: sonnet'                          "M48.2 — agent model frontmatter"
  assert_grep "$MSD_FILE" '^description: '                          "M48.3 — agent description frontmatter non-empty"
  assert_grep "$MSD_FILE" '^## Inputs'                              "M48.4 — Inputs section present"
  assert_grep "$MSD_FILE" '^## Tools authorised'                    "M48.5 — Tools authorised section present"
  assert_grep "$MSD_FILE" '^## Process'                             "M48.6 — Process section present"
  assert_grep "$MSD_FILE" '^## Refusal triggers'                    "M48.7 — Refusal triggers section present"
  assert_grep "$MSD_FILE" '^## Return contract'                     "M48.8 — Return contract section present"
  assert_grep "$MSD_FILE" 'strategy: squash \| rebase \| merge'     "M48.9 — strategy enum in return-contract YAML"
  # Negative: drop must NOT appear as a verdict in the return-contract YAML
  YAML_BLOCK=$(awk '/^```yaml$/,/^```$/' "$MSD_FILE")
  if echo "$YAML_BLOCK" | grep -qE '^strategy:.*drop'; then
    echo "  FAIL  M48.no-drop — return-contract YAML must NOT name 'drop' as a verdict"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  M48.no-drop — return-contract YAML correctly omits 'drop'"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "== M49: SKILL.md Phase 1.4 PATH_2 (c) dispatches trust-trail-evaluator via Task() =="
PHASE_14_BODY=$(awk '/^### Step 1.4/,/^### Step 1.5/' "$SKILL_FILE")
if echo "$PHASE_14_BODY" | grep -qE 'trust-trail-evaluator'; then
  echo "  PASS  M49.1 — Phase 1.4 names trust-trail-evaluator agent"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M49.1 — Phase 1.4 must name trust-trail-evaluator agent in PATH_2 (c) dispatch"
  FAIL=$((FAIL + 1))
fi
if echo "$PHASE_14_BODY" | grep -qE 'Task\('; then
  echo "  PASS  M49.2 — Phase 1.4 mentions Task() dispatch"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M49.2 — Phase 1.4 must mention Task() dispatch for trust-trail-evaluator"
  FAIL=$((FAIL + 1))
fi
if echo "$PHASE_14_BODY" | grep -qE 'PATH_3'; then
  echo "  FAIL  M49.no-path3-bypass — Phase 1.4 must NOT name PATH_3 (admin-bypass anchor retired)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  M49.no-path3-bypass — PATH_3 correctly absent from Phase 1.4"
  PASS=$((PASS + 1))
fi

echo
echo "== M50: SKILL.md Phase 2.2 dispatches merge-strategy-decider via Task() =="
PHASE_22_BODY=$(awk '/^### Step 2.2/,/^### Step 2.3/' "$SKILL_FILE")
if echo "$PHASE_22_BODY" | grep -qE 'merge-strategy-decider'; then
  echo "  PASS  M50.1 — Phase 2.2 names merge-strategy-decider agent"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M50.1 — Phase 2.2 must name merge-strategy-decider agent"
  FAIL=$((FAIL + 1))
fi
if echo "$PHASE_22_BODY" | grep -qE 'Task\('; then
  echo "  PASS  M50.2 — Phase 2.2 mentions Task() dispatch"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M50.2 — Phase 2.2 must mention Task() dispatch for merge-strategy-decider"
  FAIL=$((FAIL + 1))
fi
if echo "$PHASE_22_BODY" | grep -qE 'Per-invocation flag always wins'; then
  echo "  FAIL  M50.no-cli-wins — Phase 2.2 must NOT contain 'Per-invocation flag always wins' clause"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  M50.no-cli-wins — CLI-flag-wins clause correctly absent from Phase 2.2"
  PASS=$((PASS + 1))
fi

echo
echo "== M51: SKILL.md Constants table contains TRUST_TRAIL_VERDICT_ENUM, MERGE_STRATEGY_DECIDER_VERDICT_ENUM, deprecation notes =="
assert_grep "$SKILL_FILE" '\| `TRUST_TRAIL_VERDICT_ENUM` \|.*PASS.*STALE.*INVALID.*FORCE_PUSHED' \
  "M51.1 — TRUST_TRAIL_VERDICT_ENUM row with literal verdict values"
assert_grep "$SKILL_FILE" '\| `MERGE_STRATEGY_DECIDER_VERDICT_ENUM` \|.*squash.*rebase.*merge' \
  "M51.2 — MERGE_STRATEGY_DECIDER_VERDICT_ENUM row with literal strategy subset"
assert_grep "$SKILL_FILE" '\| `STRATEGY_FLAGS_DEPRECATED_NOTE` \|' \
  "M51.3 — STRATEGY_FLAGS_DEPRECATED_NOTE row"
assert_grep "$SKILL_FILE" '\| `BYPASS_PROTECTIONS_DEPRECATED_NOTE` \|' \
  "M51.4 — BYPASS_PROTECTIONS_DEPRECATED_NOTE row"

echo
echo "== M52: SKILL.md AUDIT_EVENT_ENUM contains new agent-decision events; STRATEGY_REASON_ENUM contains agent_decided =="
AUDIT_ROW=$(grep -E '\| `AUDIT_EVENT_ENUM` \|' "$SKILL_FILE" || true)
for EV in trust_trail_agent_decision merge_strategy_agent_decision merge_strategy_fanout_wave_started; do
  if echo "$AUDIT_ROW" | grep -qE "$EV"; then
    echo "  PASS  M52.$EV — AUDIT_EVENT_ENUM declares $EV"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  M52.$EV — AUDIT_EVENT_ENUM must declare $EV"
    FAIL=$((FAIL + 1))
  fi
done
if grep -qE '\| `STRATEGY_REASON_ENUM` \|.*agent_decided' "$SKILL_FILE"; then
  echo "  PASS  M52.agent_decided — STRATEGY_REASON_ENUM declares agent_decided"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M52.agent_decided — STRATEGY_REASON_ENUM must declare agent_decided"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M53: commands/merge.md Deprecated Flags section lists --squash, --rebase, --merge, --bypass-protections =="
CMD_DEP_BODY=$(awk '/^## Deprecated Flags/,EOF' "$CMD_FILE")
for FL in '--squash' '--rebase' '--merge' '--bypass-protections'; do
  # Use `grep -e <pattern>` so flag-style patterns starting with `--` are
  # not parsed as grep options (BSD grep on macOS is strict about this).
  if echo "$CMD_DEP_BODY" | grep -qE -e "$FL"; then
    echo "  PASS  M53.$FL — Deprecated Flags section names $FL"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  M53.$FL — Deprecated Flags section must name $FL"
    FAIL=$((FAIL + 1))
  fi
done
if echo "$CMD_DEP_BODY" | grep -qE 'warning: --squash / --rebase / --merge are deprecated'; then
  echo "  PASS  M53.notice-strategy — verbatim STRATEGY_FLAGS_DEPRECATED_NOTE present"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M53.notice-strategy — verbatim STRATEGY_FLAGS_DEPRECATED_NOTE missing"
  FAIL=$((FAIL + 1))
fi
if echo "$CMD_DEP_BODY" | grep -qE 'warning: --bypass-protections is deprecated'; then
  echo "  PASS  M53.notice-bypass — verbatim BYPASS_PROTECTIONS_DEPRECATED_NOTE present"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M53.notice-bypass — verbatim BYPASS_PROTECTIONS_DEPRECATED_NOTE missing"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M54: no forbidden 'use --bypass-protections to override' / 're-run /review-pr, then re-invoke /merge' wording in any mirror site =="
USING_FILE="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
for FILE in "$SKILL_FILE" "$CMD_FILE" "$USING_FILE"; do
  if grep -qE 'supply --bypass-protections to override|use --bypass-protections to override' "$FILE"; then
    echo "  FAIL  M54.bypass-override — forbidden 'supply/use --bypass-protections to override' in $FILE"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  M54.bypass-override — $FILE clean of bypass-override prose"
    PASS=$((PASS + 1))
  fi
  if grep -qE 're-run /review-pr, then re-invoke /merge' "$FILE"; then
    echo "  FAIL  M54.re-run-prescription — forbidden 're-run /review-pr, then re-invoke /merge' in $FILE"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  M54.re-run-prescription — $FILE clean of re-run prescription"
    PASS=$((PASS + 1))
  fi
done

echo
# M55 (deleted, simplify pass): was a literal duplicate of M37.gfr3 — same regex,
# same file; M37.gfr3 already covers the trust_trail_stale_sha preservation invariant.

echo "== M56: trust-trail-evaluator agent input contract cites live gh pr view --json headRefOid =="
TTE_FILE="$REPO_ROOT/plugins/uberdev/agents/trust-trail-evaluator.md"
if grep -qE 'gh pr view.*--json headRefOid|live.*headRefOid' "$TTE_FILE"; then
  echo "  PASS  M56 — agent inputs cite live headRefOid (M38 mandate preserved)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M56 — agent inputs MUST cite live gh pr view --json headRefOid (per M38 mandate)"
  FAIL=$((FAIL + 1))
fi

echo
# M57 (deleted, simplify pass): was a meta-marker that emitted a NOTE line without
# incrementing PASS/FAIL or asserting anything. Atomicity across the five mirror sites
# is enforced by M44/M45/M46/M54 directly; the meta-marker contributed nothing
# beyond a comment masquerading as a test result.

echo "== M58: SKILL.md Constants table declares GATE_FAIL_REASON_TRUST_TRAIL_AGENT_INVALID_INPUT and MAX_PARALLEL_AGENTS =="
assert_grep "$SKILL_FILE" '\| `GATE_FAIL_REASON_TRUST_TRAIL_AGENT_INVALID_INPUT` \|.*trust_trail_agent_invalid_input' \
  "M58.1 — GATE_FAIL_REASON_TRUST_TRAIL_AGENT_INVALID_INPUT row with literal value"
assert_grep "$SKILL_FILE" '\| `MAX_PARALLEL_AGENTS` \|.*10' \
  "M58.2 — MAX_PARALLEL_AGENTS row with default 10"

echo
echo "== M59: SKILL.md Phase 2.2 documents MAX_PARALLEL_AGENTS chunking + merge_strategy_fanout_wave_started =="
PHASE_22_BODY=$(awk '/^### Step 2.2/,/^### Step 2.3/' "$SKILL_FILE")
for KW in 'MAX_PARALLEL_AGENTS' 'merge_strategy_fanout_wave_started' 'wave_index' 'wave_size'; do
  if echo "$PHASE_22_BODY" | grep -qE "$KW"; then
    echo "  PASS  M59.$KW — Phase 2.2 mentions $KW"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  M59.$KW — Phase 2.2 must mention $KW"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== M60: SKILL.md Phase 1.4 PATH_2 (c) specifies INVALID retry path with git fetch --prune + max retry=1 =="
PHASE_14_BODY=$(awk '/^### Step 1.4/,/^### Step 1.5/' "$SKILL_FILE")
for KW in 'trailer_sha_not_in_local_clone' 'git fetch --prune' 'retry_attempt' 'input_malformed'; do
  if echo "$PHASE_14_BODY" | grep -qE "$KW"; then
    echo "  PASS  M60.$KW — Phase 1.4 mentions $KW"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  M60.$KW — Phase 1.4 must mention $KW"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== M61: trust-trail-evaluator handles sibling-equivalent commits (non-ancestor + empty tree diff) as PASS =="
# Motivating case (post-v0.18.1): user-side `git commit --amend` between /review-pr and /merge
# produces a sibling commit with identical tree contents but a different SHA. The trailer
# references the pre-amend SHA, which is not an ancestor of the post-amend HEAD. Pre-fix, the
# agent's Step 2 short-circuited to FORCE_PUSHED on Exit 1 without ever checking the tree diff,
# blocking legitimate trust trails. (/review-pr itself no longer amends post-v0.18.1 — it
# emits an empty trust-trail-anchor commit instead — but sibling-equivalence remains supported
# for user-side amends.)
TTE_FILE="$REPO_ROOT/plugins/uberdev/agents/trust-trail-evaluator.md"
if [ ! -r "$TTE_FILE" ]; then
  echo "  FAIL  M61 — agent file missing: $TTE_FILE"
  FAIL=$((FAIL + 1))
else
  # Negative: Step 2 Exit 1 must NOT short-circuit to FORCE_PUSHED — must defer to Step 3.
  if grep -qE 'Exit 1[^E]*[Vv]erdict:?[[:space:]]*`?FORCE_PUSHED' "$TTE_FILE"; then
    echo "  FAIL  M61.no-shortcircuit — Step 2 Exit 1 must NOT short-circuit to FORCE_PUSHED; should continue to Step 3 for tree-diff check (sibling-equivalent case)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  M61.no-shortcircuit — Step 2 Exit 1 correctly defers FORCE_PUSHED decision to Step 3"
    PASS=$((PASS + 1))
  fi
  # Positive: Process documents the is_ancestor flag passed from Step 2 to Step 3.
  assert_grep "$TTE_FILE" 'is_ancestor' \
    "M61.is_ancestor-flag — Process documents the is_ancestor flag passed from Step 2 to Step 3"
  # Positive: Step 3 cites the sibling-equivalent case (commit --amend with identical tree).
  assert_grep "$TTE_FILE" 'sibling' \
    "M61.sibling-cited — Step 3 cites the sibling-equivalent case"
  # Positive: Step 3 documents non-ancestor + non-empty-diff → FORCE_PUSHED.
  assert_grep "$TTE_FILE" 'is_ancestor=false.*FORCE_PUSHED|non-ancestor.*FORCE_PUSHED' \
    "M61.real-rewrite — Step 3 documents non-ancestor + non-empty-diff FORCE_PUSHED (real history rewrite)"
  # Positive: cite the motivating commit --amend case so future maintainers see the why.
  assert_grep "$TTE_FILE" 'commit --amend' \
    "M61.amend-cited — agent file cites commit --amend as the motivating case"
fi

echo
echo "== M62: SKILL.md Step 1.1 guards against missing flock(1) (issue #51) =="
# Motivating case: macOS ships without flock(1), so the unguarded `flock` invocation
# in Step 1.1 exits 127 ("command not found") and the prior prose mis-classified
# every non-zero exit from the lock invocation as genuine contention. Result:
# stock-macOS users see "another /merge run in progress" with no actual contender.
# This test pins the contract that Step 1.1 (a) detects flock availability before
# invoking it, (b) provides a portable fallback (mkdir-based mutex is the natural
# POSIX-atomic choice) so /merge works out-of-the-box, and (c) explicitly
# distinguishes the missing-binary path from real contention so the diagnostic
# never mis-fires again.
PHASE_1_1_BLOCK=$(awk '/^### Step 1\.1/,/^### Step 1\.2/' "$SKILL_FILE")
if [ -z "$PHASE_1_1_BLOCK" ]; then
  fail "M62 — could not slice Step 1.1 block; heading layout changed"
else
  if echo "$PHASE_1_1_BLOCK" | grep -qE 'command -v flock'; then
    pass "M62.1 — Step 1.1 probes flock availability via 'command -v flock' before invoking it"
  else
    fail "M62.1 — Step 1.1 must probe flock availability via 'command -v flock' before invoking it"
  fi
  if echo "$PHASE_1_1_BLOCK" | grep -qE '\bmkdir\b'; then
    pass "M62.2 — Step 1.1 specifies a portable mkdir-based mutex fallback"
  else
    fail "M62.2 — Step 1.1 must specify a portable mkdir-based mutex fallback (POSIX-atomic, no flock dep)"
  fi
  if echo "$PHASE_1_1_BLOCK" | grep -qE '(MUST NOT|must not|never).*(contention|contended)|missing.*flock.*not.*contention|not.*lock.*contention'; then
    pass "M62.3 — Step 1.1 explicitly forbids classifying missing-flock as contention"
  else
    fail "M62.3 — Step 1.1 must explicitly state that the missing-flock case is NOT contention (the issue-#51 mis-classification regression guard)"
  fi
  # Phase 4.6 must clean up the mkdir fallback explicitly (flock auto-releases; mkdir does not).
  PHASE_4_6_BLOCK=$(awk '/^### Step 4\.6/,/^## Quick Reference/' "$SKILL_FILE")
  if echo "$PHASE_4_6_BLOCK" | grep -qE '\brmdir\b|rm -rf.*LOCK_DIR|remove.*lock dir|cleanup.*fallback|trap.*EXIT'; then
    pass "M62.4 — Step 4.6 documents explicit cleanup for the mkdir fallback"
  else
    fail "M62.4 — Step 4.6 must document explicit cleanup (rmdir / trap EXIT) for the mkdir fallback path"
  fi
  # M62.5 — Step 1.1 must distinguish mkdir filesystem errors from contention so users see the
  # right diagnostic. Without this, ENOSPC / EACCES / EROFS get mis-reported as "another /merge
  # run in progress" — the same silent-failure family as the original issue #51 mis-classification.
  if echo "$PHASE_1_1_BLOCK" | grep -qE 'filesystem error|ENOSPC|EACCES|EROFS|non-EEXIST'; then
    pass "M62.5 — Step 1.1 distinguishes mkdir filesystem errors from lock contention"
  else
    fail "M62.5 — Step 1.1 must distinguish mkdir filesystem errors (ENOSPC / EACCES / EROFS) from lock contention so the diagnostic does not mis-fire"
  fi
  # M62.6 — Step 1.1 must prescribe a concrete trap so cleanup-on-exit is consistent across
  # every codegen pass. "MUST install a trap" without the literal trap line is hopeful prose;
  # the literal `trap ... EXIT INT TERM` syntax pins the contract.
  if echo "$PHASE_1_1_BLOCK" | grep -qE 'trap.*EXIT[ ]+INT[ ]+TERM|trap.*EXIT.*TERM'; then
    pass "M62.6 — Step 1.1 prescribes concrete trap syntax (trap ... EXIT INT TERM) for fallback cleanup"
  else
    fail "M62.6 — Step 1.1 must prescribe concrete trap syntax (trap 'rm -rf \$LOCK_DIR' EXIT INT TERM) so cleanup-on-exit is generated consistently"
  fi
fi

echo
echo "== M63: Phase 1.4 PATH_2 sub-condition (d) hybrid present/absent behavior (issue #52, narrowed by #78) =="

assert_grep "$SKILL_FILE" 'trust_trail_json_absent' \
  "M63.absent-advisory — JSON-absent advisory reason documented in PATH_2 (d) prose"

assert_grep "$SKILL_FILE" 'trust_trail_json_sha_mismatch' \
  "M63.mismatch-gatefail — JSON shape-malformed gate_fail reason still documented (narrowed scope post-#78 — emits on shape failures only)"

# M63.missing-retired — scoped to Phase 1.4 body (between Step 1.4 heading and Step 1.5 heading);
# the OLD reason must NOT appear as a gate_fail data.reason inside the (d) bullet body.
PHASE_14_BODY=$(awk '/^### Step 1\.4/,/^### Step 1\.5/' "$SKILL_FILE")
if echo "$PHASE_14_BODY" | grep -qE 'gate_fail.*data\.reason="trust_trail_json_missing"'; then
  fail "M63.missing-retired — gate_fail with trust_trail_json_missing must NOT appear inside Phase 1.4 PATH_2 (d) prose post-#52"
else
  pass "M63.missing-retired — Phase 1.4 PATH_2 (d) no longer emits gate_fail trust_trail_json_missing (deprecation-pattern preserved at the constants row only)"
fi

assert_grep "$SKILL_FILE" 'absence on a fresh clone is by design|fresh clone.*by design' \
  "M63.absence-by-design — design-intent prose for fresh-clone JSON absence preserved"

assert_grep "$SKILL_FILE" 'short-circuit.*sub-condition.*d|d.*only.*checked.*c.*returned.*PASS' \
  "M63.short-circuit-preserved — (c) short-circuit-on-non-PASS clause still documented in PATH_2"

# Issue #78 — PR-filter and strict-SHA-equality retirement assertions, scoped to the
# Phase 1.4 PATH_2 (d) body so they don't accidentally match other prose.
PATH2_D_BODY=$(echo "$PHASE_14_BODY" | awk '/^d\. /,/^On all four sub-conditions met:/')

if echo "$PATH2_D_BODY" | grep -qE 'top-level `?\.pr`? integer field equals'; then
  pass "M63.pr-filter — sub-condition (d) prose explicitly requires filtering JSONs by top-level .pr field"
else
  fail "M63.pr-filter — sub-condition (d) prose must require filtering .uberdev/runs/*/review-pr-verdict.json by top-level .pr == <N> (issue #78)"
fi

if echo "$PATH2_D_BODY" | grep -qE 'strict.*"sha"[[:space:]]*==[[:space:]]*headRefOid.*RETIRED|equality check is RETIRED|equality check is no longer performed|RETIRED.*post-#78'; then
  pass "M63.strict-equality-retired — sub-condition (d) prose explicitly retires strict \"sha\" == headRefOid equality check (issue #78)"
else
  fail "M63.strict-equality-retired — sub-condition (d) prose must explicitly retire the strict \"sha\" == headRefOid check (issue #78)"
fi

if echo "$PATH2_D_BODY" | grep -qE 'shape-malformed only|narrowed to.*shape-malformed|shape failures.*only'; then
  pass "M63.shape-malformed-narrow — sub-condition (d) narrows trust_trail_json_sha_mismatch emission to shape-malformed cases only (issue #78)"
else
  fail "M63.shape-malformed-narrow — sub-condition (d) must narrow trust_trail_json_sha_mismatch to shape-malformed cases only post-#78"
fi

if echo "$PATH2_D_BODY" | grep -qE 'lex-greatest|most recent.*run-id|most-recent.*run-id'; then
  pass "M63.most-recent-tiebreak — sub-condition (d) prose specifies tie-break to most-recent run-id when multiple JSONs match the PR (issue #78)"
else
  fail "M63.most-recent-tiebreak — sub-condition (d) must specify a deterministic tie-break (most-recent run-id) when multiple matching JSONs exist (issue #78)"
fi

# M63.inequality-phrasing-absent — negative regression guard that asserts the OLD
# strict-inequality phrasing is absent from (d). The earlier (pre-#78) prose described
# the check as `gate_fail when "sha" != headRefOid` (or the unicode `≠` variant); #78
# retired the strict equality, narrowing emission to shape-malformed-only. This guard
# ensures a future edit can't silently re-introduce the inequality phrasing inside the
# (d) body. The name signals the assertion's nature (this asserts the phrasing is
# ABSENT) and disambiguates from the near-synonym M63.strict-equality-retired (which
# asserts the retirement *prose* is PRESENT). Mirrors the `assert_no_grep` convention
# but operates on $PATH2_D_BODY (a variable, not a file) so it stays consistent with
# the surrounding M63 inline-grep style.
if echo "$PATH2_D_BODY" | grep -qE '"sha"[[:space:]]*!=[[:space:]]*headRefOid|"sha"[[:space:]]*≠[[:space:]]*headRefOid|sha[[:space:]]+(does[[:space:]]+not|!=)[[:space:]]+(equal|match)[[:space:]]+headRefOid'; then
  fail "M63.inequality-phrasing-absent — strict-inequality phrasing (\"sha\" != headRefOid / \"sha\" ≠ headRefOid) must NOT return to sub-condition (d) post-#78 — see M63.strict-equality-retired"
else
  pass "M63.inequality-phrasing-absent — sub-condition (d) does not carry the retired strict-inequality phrasing (issue #78 regression guard)"
fi

# M63.worktree-glob — regression guard that asserts both the Step (c.0) bash
# discovery code AND sub-condition (d) prose include the worktree-mirror glob
# `.claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json` alongside the
# main `.uberdev/runs/*/review-pr-verdict.json`. Without the worktree mirror,
# /merge cannot find audit JSONs written by /review-pr inside a /solve|/turbo
# worktree (which is the default for medium+ tier per solve-pipeline/SKILL.md),
# silently short-circuiting trust-trail-evaluator to STALE via
# phase2_5_present=false and gating valid trust trails. The fix lives in two
# co-located sites; this guard locks both.

# (a) bash discovery code in Step (c.0)
STEP_C0_BLOCK=$(awk '/Step \(c\.0\) — discover \$AUDIT_JSON_PATH/,/AUDIT_JSON_PATH is now the most-recent verdict JSON/' "$SKILL_FILE")
if echo "$STEP_C0_BLOCK" | grep -qF '.claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json'; then
  pass "M63.worktree-glob.c0 — Step (c.0) bash discovery code globs the worktree-mirror path (.claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json)"
else
  fail "M63.worktree-glob.c0 — Step (c.0) MUST glob .claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json alongside .uberdev/runs/*/review-pr-verdict.json — without it /merge cannot see audit JSONs written by /review-pr from inside a /solve|/turbo worktree (.claude/worktrees/solve-issue-N/)"
fi

# (b) sub-condition (d) prose at line ~418
if echo "$PATH2_D_BODY" | grep -qF '.claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json'; then
  pass "M63.worktree-glob.d — sub-condition (d) prose names the worktree-mirror glob path (.claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json) so the prose mirrors Step (c.0)'s bash"
else
  fail "M63.worktree-glob.d — sub-condition (d) prose MUST mention the worktree-mirror glob path .claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json (prose-bash drift between (c.0) and (d) is the regression class this guards against)"
fi

echo
echo "== M64: SKILL.md run-summary per-PR conflict-files sub-block (issue #60) =="
# SUMMARY_BLOCK is set at file scope by M27; reuse it. PHASE_33IV is M64-specific.
PHASE_33IV=$(awk '/^iv\. \*\*Apply resolutions\*\*/,/^v\. /' "$SKILL_FILE")
# CONFLICT_BLOCK: the new conflict-files sub-block within the run-summary
# template fence. Bounding to this slice keeps the field/tag/conditional
# assertions from matching incidental occurrences elsewhere in the file.
CONFLICT_BLOCK=$(echo "$SUMMARY_BLOCK" | awk '/^[[:space:]]*conflict files:/,/^```$/')
# SANITIZE_BODY: bound the sanitize_agent_text body so M64.sanitize-impl below
# matches the helper definition itself, not an incidental occurrence elsewhere.
SANITIZE_BODY=$(awk '/sanitize_agent_text\(\) \{/,/^[[:space:]]*\}[[:space:]]*$/' "$SKILL_FILE")

# AC1 + AC4 — per-file conflict sub-block presence (4 fields). Case-sensitive
# (literal -F) so a future "Conflict Files:" or "VERDICT:" mistake fails loudly
# instead of silently matching the lowercase contract.
for field in 'conflict files:' 'verdict:' 'justification:' 'risks:'; do
  if echo "$CONFLICT_BLOCK" | grep -qF "$field"; then
    pass "M64.field[$field] — conflict-files sub-block names \"$field\" (lowercase, within sub-block)"
  else
    fail "M64.field[$field] — conflict-files sub-block MUST include \"$field\" lowercase, within the sub-block (not just elsewhere in SKILL.md)"
  fi
done

# Q1 decision — verdict casing must be lowercase, bracketed (2 tags), and the
# tags must appear inside the conflict-files sub-block (not in an unrelated
# example or comment elsewhere in the run-summary section).
for tag in '\[refused\]' '\[ambiguous\]'; do
  if echo "$CONFLICT_BLOCK" | grep -qE "$tag"; then
    pass "M64.tag[$tag] — verdict casing matches PARK_REASON_ENUM (lowercase, bracketed) within sub-block"
  else
    fail "M64.tag[$tag] — verdict tag $tag MUST appear inside the conflict-files sub-block (lowercase bracketed form per PARK_REASON_ENUM)"
  fi
done

# Phase 3.3iv prose must explicitly name the source fields (4 tokens).
for prose_token in 'resolution_summary' 'risks' 'sanitize_agent_text' 'fmt -w 80'; do
  if echo "$PHASE_33IV" | grep -qF "$prose_token"; then
    pass "M64.prose[$prose_token] — Phase 3.3iv mentions \"$prose_token\""
  else
    fail "M64.prose[$prose_token] — Phase 3.3iv MUST mention \"$prose_token\" so consumer wiring is unambiguous"
  fi
done

# AC3 — conditional render: the gate clause must appear INSIDE the
# conflict-files sub-block template, not merely somewhere in SKILL.md. This
# catches the regression where the gate is removed from the template but the
# phrase survives in surrounding prose.
if echo "$CONFLICT_BLOCK" | grep -qF 'only if outcome is Parked AND park reason'; then
  pass "M64.conditional — conflict-files sub-block render-condition documented inline with the sub-block (gates RESOLVED path unchanged)"
else
  fail "M64.conditional — conflict-files sub-block MUST inline the render-condition clause; gate removal from template would leave RESOLVED path unprotected"
fi

# Sanitization helper body must be present (literal C0/C1+DEL strip range)
# AND must appear within the awk-bounded sanitize_agent_text() function — so
# the assertion fails if the helper definition is removed but the byte range
# survives in a comment or example elsewhere.
if echo "$SANITIZE_BODY" | grep -qF "tr -d '\\000-\\010\\013-\\037\\177\\200-\\237'"; then
  pass "M64.sanitize-impl — sanitize_agent_text body documents the C0/C1+DEL strip range (within helper definition)"
else
  fail "M64.sanitize-impl — sanitize_agent_text body MUST contain literal C0/C1+DEL strip range inside the helper definition"
fi

echo
echo "== M64: SKILL.md Inputs 'No args' bullet documents bare-discover dual path =="
# Anchor scoping: extract the "No args" bullet from the Inputs list. The bullet
# starts with "- **No args**" and ends at the next "- **`<PR#" bullet (which is
# the next argument-parsing entry). M33's awk-range pattern.
BARE_MODE_BULLET=$(awk '/^- \*\*No args\*\*/,/^- \*\*`<PR/' "$SKILL_FILE")

if echo "$BARE_MODE_BULLET" | grep -qE 'single-PR mode|context-aware'; then
  pass "M64.fast-path-described — Inputs 'No args' bullet describes the single-PR fast path (context-aware wording)"
else
  fail "M64.fast-path-described — Inputs 'No args' bullet MUST describe the single-PR fast path (single-PR mode / context-aware) per spec Components § SKILL.md item 2"
fi

if echo "$BARE_MODE_BULLET" | grep -qE 'fall through.*--all|same discovery pipeline as `--all`|multi-discover'; then
  pass "M64.multi-discover-described — Inputs 'No args' bullet describes the multi-discover fall-through to the --all pipeline"
else
  fail "M64.multi-discover-described — Inputs 'No args' bullet MUST describe the multi-discover fall-through (fall through / same discovery pipeline as --all / multi-discover)"
fi

if echo "$BARE_MODE_BULLET" | grep -qE 'errors if none|error out.*finish-branch'; then
  fail "M64.no-old-error — Inputs 'No args' bullet MUST NOT carry the old 'errors if none' / 'error out…finish-branch' prose (bare-discover replaces it)"
else
  pass "M64.no-old-error — Inputs 'No args' bullet correctly omits the old finish-branch error wording"
fi

echo
echo "== M65: SKILL.md Constants declares DISCOVERY_FILTER exactly once =="
# Count constant rows where the Name column literal is `DISCOVERY_FILTER`.
# Constants table rows match `^| \`DISCOVERY_FILTER\` |`.
DISCOVERY_FILTER_ROWS=$(grep -cE '^\| `DISCOVERY_FILTER` \|' "$SKILL_FILE" || true)
if [ "$DISCOVERY_FILTER_ROWS" = "1" ]; then
  pass "M65.unique — DISCOVERY_FILTER declared exactly once in Constants table"
else
  fail "M65.unique — DISCOVERY_FILTER MUST be declared exactly once in Constants table (got $DISCOVERY_FILTER_ROWS rows; spec Components § SKILL.md item 1 / Q4)"
fi
# Value-cell content checks — must reference --base, --state open, draft:false.
DISCOVERY_FILTER_ROW=$(grep -E '^\| `DISCOVERY_FILTER` \|' "$SKILL_FILE" || true)
if echo "$DISCOVERY_FILTER_ROW" | grep -qE 'gh pr list --base'; then
  pass "M65.base-flag — DISCOVERY_FILTER value cites 'gh pr list --base'"
else
  fail "M65.base-flag — DISCOVERY_FILTER value MUST cite 'gh pr list --base' (canonical query; spec Q4)"
fi
if echo "$DISCOVERY_FILTER_ROW" | grep -qE -- '--state open'; then
  pass "M65.state-open — DISCOVERY_FILTER value cites '--state open'"
else
  fail "M65.state-open — DISCOVERY_FILTER value MUST cite '--state open' (canonical query; spec Q4)"
fi
if echo "$DISCOVERY_FILTER_ROW" | grep -qE 'draft:false'; then
  pass "M65.draft-filter — DISCOVERY_FILTER value cites 'draft:false'"
else
  fail "M65.draft-filter — DISCOVERY_FILTER value MUST cite 'draft:false' (canonical query; spec Q4)"
fi

echo
echo "== M66: SKILL.md Constants declares BARE_MODE_FAST_PATH_QUERY exactly once =="
BARE_FAST_PATH_ROWS=$(grep -cE '^\| `BARE_MODE_FAST_PATH_QUERY` \|' "$SKILL_FILE" || true)
if [ "$BARE_FAST_PATH_ROWS" = "1" ]; then
  pass "M66.unique — BARE_MODE_FAST_PATH_QUERY declared exactly once in Constants table"
else
  fail "M66.unique — BARE_MODE_FAST_PATH_QUERY MUST be declared exactly once in Constants table (got $BARE_FAST_PATH_ROWS rows; spec Components § SKILL.md item 1)"
fi
BARE_FAST_PATH_ROW=$(grep -E '^\| `BARE_MODE_FAST_PATH_QUERY` \|' "$SKILL_FILE" || true)
if echo "$BARE_FAST_PATH_ROW" | grep -qE 'gh pr list --head'; then
  pass "M66.head-flag — BARE_MODE_FAST_PATH_QUERY value cites 'gh pr list --head'"
else
  fail "M66.head-flag — BARE_MODE_FAST_PATH_QUERY value MUST cite 'gh pr list --head' (current-branch detection; spec Architecture § Branch (a))"
fi
if echo "$BARE_FAST_PATH_ROW" | grep -qE -- '--state open'; then
  pass "M66.state-open — BARE_MODE_FAST_PATH_QUERY value cites '--state open'"
else
  fail "M66.state-open — BARE_MODE_FAST_PATH_QUERY value MUST cite '--state open'"
fi
if echo "$BARE_FAST_PATH_ROW" | grep -qE 'draft:false'; then
  pass "M66.draft-filter — BARE_MODE_FAST_PATH_QUERY value cites 'draft:false'"
else
  fail "M66.draft-filter — BARE_MODE_FAST_PATH_QUERY value MUST cite 'draft:false'"
fi

echo
echo "== M67: SKILL.md Constants declares PREFLIGHT_SUMMARY_FORMAT with literal format string =="
PREFLIGHT_FORMAT_ROWS=$(grep -cE '^\| `PREFLIGHT_SUMMARY_FORMAT` \|' "$SKILL_FILE" || true)
if [ "$PREFLIGHT_FORMAT_ROWS" = "1" ]; then
  pass "M67.unique — PREFLIGHT_SUMMARY_FORMAT declared exactly once in Constants table"
else
  fail "M67.unique — PREFLIGHT_SUMMARY_FORMAT MUST be declared exactly once in Constants table (got $PREFLIGHT_FORMAT_ROWS rows; spec Q5)"
fi
# Mirror M65/M66: scope sub-checks to the row literal so future Step 2.2 prose
# additions that quote the format string don't accidentally satisfy these.
PREFLIGHT_FORMAT_ROW=$(grep -E '^\| `PREFLIGHT_SUMMARY_FORMAT` \|' "$SKILL_FILE" || true)
if echo "$PREFLIGHT_FORMAT_ROW" | grep -qE 'merging %d PR%s in order: %s'; then
  pass "M67.format-literal — PREFLIGHT_SUMMARY_FORMAT contains the literal 'merging %d PR%s in order: %s'"
else
  fail "M67.format-literal — PREFLIGHT_SUMMARY_FORMAT MUST contain literal 'merging %d PR%s in order: %s' (spec Q5)"
fi
if echo "$PREFLIGHT_FORMAT_ROW" | grep -qE '80-char|80 char'; then
  pass "M67.wrap-convention — Constants prose mentions 80-char line-wrap convention"
else
  fail "M67.wrap-convention — Constants prose MUST mention the 80-char line-wrap convention for long PR-number lists (spec Q5)"
fi

echo
echo "== M68: SKILL.md Step 1.0.5 mode-detect cites BARE_MODE_FAST_PATH_QUERY but NOT DISCOVERY_FILTER =="
# Range-scope to Step 1.0.5 body: from "### Step 1.0.5" to next "### Step 1." heading.
STEP_105_BLOCK=$(awk '/^### Step 1\.0\.5/,/^### Step 1\.1/' "$SKILL_FILE")
if [ -n "$STEP_105_BLOCK" ]; then
  pass "M68.exists — Step 1.0.5 section exists between Step 1.0 and Step 1.1"
else
  fail "M68.exists — Step 1.0.5 (mode-detect) section MUST exist between Step 1.0 and Step 1.1 (spec Components § SKILL.md item 3)"
fi
if echo "$STEP_105_BLOCK" | grep -qE 'BARE_MODE_FAST_PATH_QUERY'; then
  pass "M68.fast-path-query-cited — Step 1.0.5 cites BARE_MODE_FAST_PATH_QUERY"
else
  fail "M68.fast-path-query-cited — Step 1.0.5 MUST cite BARE_MODE_FAST_PATH_QUERY (the constant for the detection query)"
fi
if echo "$STEP_105_BLOCK" | grep -qE 'three-way|1.*0.*>1|fast-path.*multi-discover.*ambiguous'; then
  pass "M68.three-way-branch — Step 1.0.5 documents the three-way branch (1 / 0 / >1)"
else
  fail "M68.three-way-branch — Step 1.0.5 MUST document the three-way branch on candidate count (1 / 0 / >1; spec Components § SKILL.md item 3)"
fi
if echo "$STEP_105_BLOCK" | grep -qE 'NOT consume.*integration_branch|does not consume.*integration_branch|deferred to Step 1\.2\.5'; then
  pass "M68.no-integration-branch-dep — Step 1.0.5 explicitly states it does NOT consume \$integration_branch"
else
  fail "M68.no-integration-branch-dep — Step 1.0.5 MUST explicitly state it does NOT consume \$integration_branch (sequencing invariant; spec Architecture § Sequencing)"
fi
# Negative regression — Step 1.0.5 must NOT mention DISCOVERY_FILTER (which lives in Step 1.2.5).
if echo "$STEP_105_BLOCK" | grep -qE 'DISCOVERY_FILTER'; then
  fail "M68.no-discovery-filter — Step 1.0.5 MUST NOT mention DISCOVERY_FILTER (split-detection invariant; DISCOVERY_FILTER lives in Step 1.2.5)"
else
  pass "M68.no-discovery-filter — Step 1.0.5 correctly omits DISCOVERY_FILTER (lives in Step 1.2.5)"
fi

echo
echo "== M69: SKILL.md Step 1.2.5 multi-discover dispatch cites DISCOVERY_FILTER + integration_branch =="
STEP_125_BLOCK=$(awk '/^### Step 1\.2\.5/,/^### Step 1\.3/' "$SKILL_FILE")
if [ -n "$STEP_125_BLOCK" ]; then
  pass "M69.exists — Step 1.2.5 section exists between Step 1.2 and Step 1.3"
else
  fail "M69.exists — Step 1.2.5 (multi-discover dispatch) section MUST exist between Step 1.2 and Step 1.3 (spec Components § SKILL.md item 4)"
fi
if echo "$STEP_125_BLOCK" | grep -qE 'DISCOVERY_FILTER|discover_multi'; then
  pass "M69.discovery-filter-cited — Step 1.2.5 cites DISCOVERY_FILTER or discover_multi (R2 canonical alias)"
else
  fail "M69.discovery-filter-cited — Step 1.2.5 MUST cite DISCOVERY_FILTER or discover_multi (spec Components § SKILL.md item 4; R2 v0.19.3 introduces lib-function alias)"
fi
if echo "$STEP_125_BLOCK" | grep -qE '\$integration_branch|integration_branch'; then
  pass "M69.integration-branch-cited — Step 1.2.5 cites \$integration_branch"
else
  fail "M69.integration-branch-cited — Step 1.2.5 MUST cite \$integration_branch (consumed by DISCOVERY_FILTER post-Step-1.2)"
fi
if echo "$STEP_125_BLOCK" | grep -qE 'multi-discover|--all'; then
  pass "M69.triggers-cited — Step 1.2.5 mentions both bare-mode and --all as triggers"
else
  fail "M69.triggers-cited — Step 1.2.5 MUST mention both bare-mode (multi-discover) and --all as triggers (spec Components § SKILL.md item 4)"
fi
# Negative regression — Step 1.2.5 must NOT mention BARE_MODE_FAST_PATH_QUERY (which lives in Step 1.0.5).
if echo "$STEP_125_BLOCK" | grep -qE 'BARE_MODE_FAST_PATH_QUERY'; then
  fail "M69.no-fast-path-query — Step 1.2.5 MUST NOT mention BARE_MODE_FAST_PATH_QUERY (split-detection invariant; lives in Step 1.0.5)"
else
  pass "M69.no-fast-path-query — Step 1.2.5 correctly omits BARE_MODE_FAST_PATH_QUERY (lives in Step 1.0.5)"
fi

echo
echo "== M70: SKILL.md Step 2.2 entry emits PREFLIGHT_SUMMARY_FORMAT pre-flight in multi-discover mode only =="
STEP_22_BLOCK=$(awk '/^### Step 2\.2/,/^### Step 2\.3/' "$SKILL_FILE")
if echo "$STEP_22_BLOCK" | grep -qE 'PREFLIGHT_SUMMARY_FORMAT'; then
  pass "M70.format-cited — Step 2.2 entry cites PREFLIGHT_SUMMARY_FORMAT"
else
  fail "M70.format-cited — Step 2.2 entry MUST cite PREFLIGHT_SUMMARY_FORMAT (spec Components § SKILL.md item 7)"
fi
if echo "$STEP_22_BLOCK" | grep -qE 'multi-discover.*mode|mode.*multi-discover|in multi-discover mode'; then
  pass "M70.mode-gated — Step 2.2 entry pre-flight line is emitted in multi-discover mode only"
else
  fail "M70.mode-gated — Step 2.2 entry pre-flight line MUST be mode-gated (multi-discover mode only; not single-PR fast path; spec Q2)"
fi
if echo "$STEP_22_BLOCK" | grep -qE 'full ordered set|full.*ordered'; then
  pass "M70.full-set — Step 2.2 entry pre-flight enumerates the full ordered set (not per-wave)"
else
  fail "M70.full-set — Step 2.2 entry pre-flight MUST enumerate the full ordered set, not a per-wave subset (spec Q5)"
fi
# Negative regression — pre-flight is informational, NOT a [y/N] prompt or abortable.
if echo "$STEP_22_BLOCK" | grep -qE 'pre-flight.*\[y/N\]|y/N.*pre-flight|prompt.*pre-flight|pre-flight.*prompt|pre-flight.*abort'; then
  fail "M70.no-prompt — Step 2.2 entry pre-flight line MUST NOT be described as a [y/N] prompt or abortable (autopilot contract; spec Q2)"
else
  pass "M70.no-prompt — Step 2.2 entry pre-flight correctly avoids [y/N] / abort wording"
fi

echo
echo "== M71: SKILL.md Step 1.7 cross-references bare-mode zero-eligible (clean exit 0) =="
STEP_17_BLOCK=$(awk '/^### Step 1\.7/,/^## Phase 2/' "$SKILL_FILE")
if echo "$STEP_17_BLOCK" | grep -qE 'Not an error, not a halt|nothing to merge'; then
  pass "M71.contract-preserved — Step 1.7 preserves 'Not an error, not a halt' / 'nothing to merge' baseline prose"
else
  fail "M71.contract-preserved — Step 1.7 MUST preserve baseline prose ('Not an error, not a halt' / 'nothing to merge') — bare-mode is a documentation-only addition"
fi
if echo "$STEP_17_BLOCK" | grep -qE 'bare-mode|bare-discover|bare-mode discovery|empty eligible set'; then
  pass "M71.bare-mode-xref — Step 1.7 cross-references bare-mode zero-eligible behaviour"
else
  fail "M71.bare-mode-xref — Step 1.7 MUST add a cross-reference to bare-mode zero-eligible (spec Components § SKILL.md item 6 / Q3)"
fi
# Negative regression — must NOT introduce a non-zero exit code on the same logical state.
if echo "$STEP_17_BLOCK" | grep -qE 'exit 1|non-zero.*exit|exit code.*1'; then
  fail "M71.no-nonzero-exit — Step 1.7 MUST NOT introduce a non-zero exit on zero-eligible (Q3 amends issue AC #6 to clean exit 0)"
else
  pass "M71.no-nonzero-exit — Step 1.7 correctly preserves exit 0 (no non-zero exit reference; spec Q3)"
fi

echo
echo "== M72: commands/merge.md argument-hint omits --yes|-y; Usage bullet documents bare-discover dual path =="
# Frontmatter argument-hint must NOT contain the deprecated --yes|-y string.
if grep -qE '^argument-hint: .*--yes\|-y' "$CMD_FILE"; then
  fail "M72.no-yes-flag-in-hint — commands/merge.md argument-hint MUST NOT contain '--yes|-y' (deprecated flag dropped from active hint surface; spec Components § commands/merge.md item 1 / Q3 fix #3)"
else
  pass "M72.no-yes-flag-in-hint — commands/merge.md argument-hint correctly omits '--yes|-y' (deprecated flag)"
fi
# Frontmatter argument-hint MUST still contain --integration-branch=<name>.
if grep -qE '^argument-hint: .*--integration-branch=<name>' "$CMD_FILE"; then
  pass "M72.integration-branch-in-hint — commands/merge.md argument-hint preserves --integration-branch=<name>"
else
  fail "M72.integration-branch-in-hint — commands/merge.md argument-hint MUST preserve --integration-branch=<name> (spec Components § commands/merge.md item 1)"
fi
# Usage bullet 1 must describe the bare-mode dual path.
if grep -qE '^- No args.*context-aware|^- No args.*single PR if on a PR branch.*else discover' "$CMD_FILE"; then
  pass "M72.usage-bullet-bare-discover — Usage bullet 1 describes context-aware bare-discover dual path"
else
  fail "M72.usage-bullet-bare-discover — Usage bullet 1 MUST describe context-aware bare-discover (single PR if on a PR branch, else discover; spec Components § commands/merge.md item 2)"
fi
# Negative regression — old Usage prose 'errors if none' must be gone.
if grep -qE '^- No args.*errors if none' "$CMD_FILE"; then
  fail "M72.no-old-usage — commands/merge.md Usage bullet 1 MUST NOT carry the old 'errors if none' wording"
else
  pass "M72.no-old-usage — commands/merge.md Usage bullet 1 correctly omits the old 'errors if none' wording"
fi
# M72.length-cap dropped — duplicate of M2 (line 115). M2 already enforces the ≤50-line
# thin-dispatcher cap on every run; re-asserting it inside M72 added no coverage.

echo
echo "== M73: SKILL.md Phase 1.4 'per discovered PR' fanout + Step 2.2 single-message invariant preserved =="
PHASE_14_BLOCK=$(awk '/^### Step 1\.4/,/^### Step 1\.5/' "$SKILL_FILE")
if echo "$PHASE_14_BLOCK" | grep -qE 'for each|per discovered PR|per-PR|every PR'; then
  pass "M73.per-pr-fanout — Phase 1.4 prose preserves per-PR fanout language (one gate dispatch per discovered PR)"
else
  fail "M73.per-pr-fanout — Phase 1.4 MUST preserve 'for each' / 'per discovered PR' / 'per-PR' fanout language (AC#2: bare-discover does not relax dispatch shape)"
fi
if echo "$STEP_22_BLOCK" | grep -qE 'ONE assistant turn|single-message Task|single-message invariant'; then
  pass "M73.single-message-preserved — Step 2.2 fanout preserves the single-message Task() invariant"
else
  fail "M73.single-message-preserved — Step 2.2 MUST preserve 'ONE assistant turn' / 'single-message Task()' invariant (AC#2/AC#4: bare-discover changes candidate set but not dispatch shape)"
fi
# Negative regression — Phase 1.4 must NOT hard-code single-PR-only language.
if echo "$PHASE_14_BLOCK" | grep -qE 'only one PR can|single PR only|exactly one PR per gate|hard-coded.*single'; then
  fail "M73.no-single-pr-hardcode — Phase 1.4 MUST NOT enumerate a fixed PR count or hard-code single-PR-only language (bare-discover supplies a multi-PR candidate set)"
else
  pass "M73.no-single-pr-hardcode — Phase 1.4 correctly avoids single-PR-only hard-coding"
fi

echo
echo "== M74: AUDIT_EVENT_ENUM declares auto_review_dispatched (#89) =="
if grep -E '^\| `AUDIT_EVENT_ENUM`' "$SKILL_FILE" | grep -q '`auto_review_dispatched`'; then
  pass "M74 — AUDIT_EVENT_ENUM row contains auto_review_dispatched literal"
else
  fail "M74 — AUDIT_EVENT_ENUM MUST declare auto_review_dispatched (spec C2.1; D8 cites PR #77 bracketing precedent)"
fi

echo
echo "== M75: AUDIT_EVENT_ENUM declares auto_review_returned (#89) =="
if grep -E '^\| `AUDIT_EVENT_ENUM`' "$SKILL_FILE" | grep -q '`auto_review_returned`'; then
  pass "M75 — AUDIT_EVENT_ENUM row contains auto_review_returned literal"
else
  fail "M75 — AUDIT_EVENT_ENUM MUST declare auto_review_returned (spec C2.1; bracketed pair with auto_review_dispatched)"
fi

echo
echo "== M76: AUDIT_EVENT_ENUM prose names the data.outcome enum for auto_review_returned (#89) =="
ENUM_ROW=$(grep -E '^\| `AUDIT_EVENT_ENUM`' "$SKILL_FILE")
for token in 'green' 'blocked' 'refused_non_green' 'reason_triggering' 'duration_ms'; do
  if echo "$ENUM_ROW" | grep -qE "$token"; then
    pass "M76.$token — AUDIT_EVENT_ENUM prose names $token"
  else
    fail "M76.$token — AUDIT_EVENT_ENUM prose MUST name $token (spec '## Data flow & return contracts')"
  fi
done

echo
echo "== M77: Constants table declares AUTO_REVIEW_DISPATCH_CAP = 1 (#89) =="
if grep -E '^\| `AUTO_REVIEW_DISPATCH_CAP` \| `1`' "$SKILL_FILE" | head -1 | grep -q '`1`'; then
  pass "M77 — AUTO_REVIEW_DISPATCH_CAP = 1 declared in Constants table (spec D4; no inline literal)"
else
  fail "M77 — Constants table MUST declare AUTO_REVIEW_DISPATCH_CAP = 1 as a named constant (per CI_FIX_LOOP_CAP / RERUN_FLAKY_CAP pattern; constraints.md §Summary #4)"
fi

echo
echo "== M78: Constants table declares AUTO_REVIEW_ON_MERGE_KEY (#89) =="
KEY_ROW=$(grep -E '^\| `AUTO_REVIEW_ON_MERGE_KEY`' "$SKILL_FILE" | head -1)
if [ -n "$KEY_ROW" ]; then
  if echo "$KEY_ROW" | grep -q 'auto_review_on_merge' && \
     echo "$KEY_ROW" | grep -q 'UBERDEV_AUTO_REVIEW_ON_MERGE'; then
    pass "M78 — AUTO_REVIEW_ON_MERGE_KEY row cites config-key name + env-var (spec D7 reuses uberdev_read_enum)"
  else
    fail "M78 — AUTO_REVIEW_ON_MERGE_KEY row MUST cite both 'auto_review_on_merge' (config key) and 'UBERDEV_AUTO_REVIEW_ON_MERGE' (env override)"
  fi
else
  fail "M78 — Constants table MUST declare AUTO_REVIEW_ON_MERGE_KEY row (spec C2.1)"
fi

echo
echo "== M79: SKILL.md declares Step 1.4.5 auto-review intercept (#89) =="
if grep -nE '^### Step 1\.4\.5' "$SKILL_FILE" | head -1 | grep -q '1\.4\.5'; then
  pass "M79.heading — Step 1.4.5 sub-section heading present"
else
  fail "M79.heading — SKILL.md MUST declare ### Step 1.4.5 sub-section heading (spec C2.3)"
fi
STEP_145_BLOCK=$(awk '/^### Step 1\.4\.5/,/^### Step 1\.5/' "$SKILL_FILE")
for token in 'AUTO_REVIEW_ON_MERGE' 'AUTO_REVIEW_DISPATCHED' 'AUTO_REVIEW_DISPATCH_CAP'; do
  if echo "$STEP_145_BLOCK" | grep -q "$token"; then
    pass "M79.$token — Step 1.4.5 references $token"
  else
    fail "M79.$token — Step 1.4.5 MUST reference $token (spec '## Architecture' counter lifecycle + trigger guard)"
  fi
done

echo
echo "== M80: Step 1.4.5 dispatches Skill(uberdev:review-pr) with --turbo (#89) =="
STEP_145_BLOCK=$(awk '/^### Step 1\.4\.5/,/^### Step 1\.5/' "$SKILL_FILE")
if echo "$STEP_145_BLOCK" | grep -qE 'Skill\("uberdev:review-pr".*--turbo'; then
  pass "M80.dispatch — Step 1.4.5 invokes Skill(uberdev:review-pr) with --turbo flag (spec D1: --turbo unconditional)"
else
  fail "M80.dispatch — Step 1.4.5 MUST invoke Skill(uberdev:review-pr) with --turbo flag (spec D1)"
fi
L_COUNTER=$(grep -n 'AUTO_REVIEW_DISPATCHED\["\${PR}:\${RUN_ID}"\]=1' "$SKILL_FILE" | head -1 | cut -d: -f1)
# Match the actual dispatch call (with `args:` keyword), not the `Skill("uberdev:review-pr")` mentions
# in the AUDIT_EVENT_ENUM prose, R7 dispatch-failure paragraph, or Common Mistakes bullet.
L_DISPATCH=$(grep -n 'Skill("uberdev:review-pr", args:' "$SKILL_FILE" | head -1 | cut -d: -f1)
if [ -n "$L_COUNTER" ] && [ -n "$L_DISPATCH" ] && [ "$L_COUNTER" -lt "$L_DISPATCH" ]; then
  pass "M80.cap-ordering — counter write precedes Skill() dispatch in source order (R6 invariant)"
else
  fail "M80.cap-ordering — AUTO_REVIEW_DISPATCHED write MUST precede Skill(uberdev:review-pr) dispatch in source order (R6 / spec)"
fi

echo
echo "== M81: Common Mistakes bullet enumerates the excluded gate-fail reasons (#89) =="
CM_BLOCK=$(awk '/^## Common Mistakes/,/^## Red Flags/' "$SKILL_FILE")
if echo "$CM_BLOCK" | grep -qE "Don't trigger auto-review on .review_decision_not_approved. alone"; then
  pass "M81.bullet-present — Common Mistakes bullet present"
else
  fail "M81.bullet-present — Common Mistakes MUST include 'Don't trigger auto-review on review_decision_not_approved alone' bullet (spec C2.6 / D11)"
fi
for reason in review_decision_not_approved trust_trail_stale_sha trust_trail_agent_invalid_input \
              trust_trail_json_sha_mismatch pr_state_not_open is_draft ci_red merge_state_blocked \
              pr_view_unreachable; do
  if echo "$CM_BLOCK" | grep -qF "$reason"; then
    pass "M81.excluded-$reason — bullet names $reason"
  else
    fail "M81.excluded-$reason — Common Mistakes bullet MUST name excluded reason $reason (spec D11 + Q6)"
  fi
done

echo
echo "== M82: Step 3.4 failure-mode table has auto-review blocked + refused_non_green rows (#89) =="
STEP_34_BLOCK=$(awk '/^### Step 3\.4/,/^## Phase 4/' "$SKILL_FILE")
if echo "$STEP_34_BLOCK" | grep -q 'Auto-review returned `blocked`'; then
  pass "M82.blocked-row — Step 3.4 table has 'Auto-review returned blocked' row"
else
  fail "M82.blocked-row — Step 3.4 table MUST include 'Auto-review returned blocked' failure-mode row (spec C2.5)"
fi
if echo "$STEP_34_BLOCK" | grep -q 'Auto-review returned `refused_non_green`'; then
  pass "M82.refused-row — Step 3.4 table has 'Auto-review returned refused_non_green' row"
else
  fail "M82.refused-row — Step 3.4 table MUST include 'Auto-review returned refused_non_green' failure-mode row (spec C2.5)"
fi

echo
echo "== M83: editor's note adds 6th bullet about #89 auto-review carve-out =="
EDITORS_NOTE=$(awk '/^> \*\*Note for editors:\*\*/,/^[^>]/' "$SKILL_FILE")
if echo "$EDITORS_NOTE" | grep -qE '^> 6\..*auto_review_on_merge'; then
  pass "M83.6th-bullet — editor's note has 6th bullet referencing auto_review_on_merge (spec C2.4 / Q5)"
else
  fail "M83.6th-bullet — editor's note MUST add a 6th bullet describing the #89 auto-review carve-out (spec C2.4 / Q5 mitigates R5 mirror-site drift)"
fi

echo
echo "== M84: commands/merge.md Autopilot paragraph mentions auto_review_on_merge (#89) =="
CMD_FILE="plugins/uberdev/commands/merge.md"
if awk '/\*\*Autopilot:\*\*/,/^## /' "$CMD_FILE" | grep -q 'auto_review_on_merge'; then
  pass "M84 — commands/merge.md Autopilot paragraph cites auto_review_on_merge (spec C3.1)"
else
  fail "M84 — commands/merge.md Autopilot paragraph MUST cite auto_review_on_merge as opt-in inner workflow (spec C3.1 / AC8)"
fi

echo
echo "== M85: commands/merge.md documents auto_review_on_merge with the excluded reasons (#89) =="
if grep -nE 'auto_review_on_merge: true\|false' "$CMD_FILE" | head -1 | grep -q 'auto_review_on_merge'; then
  pass "M85.config-key — commands/merge.md documents auto_review_on_merge with true|false enum (spec C3.2)"
else
  fail "M85.config-key — commands/merge.md MUST document auto_review_on_merge with true|false enum (spec C3.2)"
fi
INPUTS_BLOCK=$(awk '/auto_review_on_merge: true\|false/,/^##|^---/' "$CMD_FILE")
for reason in trust_trail_stale_sha trust_trail_agent_invalid_input trust_trail_json_sha_mismatch \
              review_decision_not_approved; do
  if echo "$INPUTS_BLOCK" | grep -qF "$reason"; then
    pass "M85.excluded-$reason — Inputs section names excluded reason $reason"
  else
    fail "M85.excluded-$reason — Inputs section MUST name excluded reason $reason (spec C3.2)"
  fi
done

echo "== M86: review-pr:pending label-present probe in Step 1.4.5 (#95) =="

# M86.1 — Constants table declares REVIEW_PR_PENDING_LABEL (Task 1)
assert_grep "$SKILL_FILE" \
  '\| `REVIEW_PR_PENDING_LABEL` \| `review-pr:pending` \|' \
  "M86.1 — Constants table declares REVIEW_PR_PENDING_LABEL = review-pr:pending (#95 spec C4 / T1, R8.6 simplify drops inner quotes for table parity)"

# M86.2 — Step 1.4.5 contains the probe reusing cached $PR_JSON (Task 4)
assert_grep "$SKILL_FILE" \
  'jq -r .\.labels\[\]\.name. <<<"\$PR_JSON"' \
  "M86.2 — probe reuses cached \$PR_JSON via jq -r .labels[].name in Step 1.4.5 (#95 spec C3 / T4, R8.6 simplify)"

# M86.3 — probe assigns reason="trust_trail_label_missing" (reuses existing enum; no new member)
PROBE_START=$(grep -n 'NEW (#95): label-present probe' "$SKILL_FILE" | head -1 | cut -d: -f1)
PROBE_END=$(awk -v s="$PROBE_START" 'NR > s && /^fi$/ { print NR; exit }' "$SKILL_FILE")
if [[ -n "$PROBE_START" && -n "$PROBE_END" ]]; then
  PROBE_BLOCK=$(sed -n "${PROBE_START},${PROBE_END}p" "$SKILL_FILE")
  if echo "$PROBE_BLOCK" | grep -qE 'reason="trust_trail_label_missing"'; then
    pass "M86.3 — probe assigns reason=trust_trail_label_missing on label match (spec D1; no new AUDIT_EVENT_ENUM member)"
  else
    fail "M86.3 — probe MUST assign reason=\"trust_trail_label_missing\" on label match (spec D1)"
  fi

  # M86.4 — AUTO_REVIEW_ON_MERGE gate wraps the probe block
  if echo "$PROBE_BLOCK" | grep -qE 'AUTO_REVIEW_ON_MERGE.*==.*"true"'; then
    pass "M86.4 — probe gated by AUTO_REVIEW_ON_MERGE=true (spec C3; default-off bit-identity contract preserved)"
  else
    fail "M86.4 — probe MUST be gated by AUTO_REVIEW_ON_MERGE == \"true\" (spec C3)"
  fi
else
  fail "M86.3 — could not locate probe block (PROBE_START=$PROBE_START PROBE_END=$PROBE_END)"
  fail "M86.4 — could not locate probe block"
fi

# M86.5 — AUDIT_EVENT_ENUM declaration unchanged: only auto_review_dispatched and auto_review_returned
# This is a set-equality check on the AUDIT_EVENT_ENUM table row at line ~30 specifically;
# we extract only that row to avoid false matches from other lines that may legitimately
# reference auto_review_on_merge (the config-key constant).
AUDIT_ROW=$(grep -E '^\| `AUDIT_EVENT_ENUM`' "$SKILL_FILE")
GOT=$(echo "$AUDIT_ROW" | grep -oE '`auto_review_[a-z_]+`' | sort -u | tr '\n' ' ')
EXPECTED='`auto_review_dispatched` `auto_review_returned` '
if [[ "$GOT" == "$EXPECTED" ]]; then
  pass "M86.5 — AUDIT_EVENT_ENUM row unchanged (#95 Q5: no new audit events; D1 reuses trust_trail_label_missing)"
else
  fail "M86.5 — AUDIT_EVENT_ENUM row MUST contain ONLY auto_review_dispatched and auto_review_returned (got: $GOT)"
fi

# M86.6 — cap-ordering preserved: AUTO_REVIEW_DISPATCHED counter write still precedes
# the Skill(uberdev:review-pr) dispatch in source order. The bash code dispatch is the
# `Skill("uberdev:review-pr",` line inside the dispatch sequence (lines ~410), not the
# AUDIT_EVENT_ENUM prose row.  We anchor on the bash code by requiring "args:" on the
# same line.
L_COUNTER=$(grep -n 'AUTO_REVIEW_DISPATCHED\["\${PR}:\${RUN_ID}"\]=1' "$SKILL_FILE" | head -1 | cut -d: -f1)
L_DISPATCH=$(grep -n -E 'Skill\("uberdev:review-pr",[[:space:]]*args:' "$SKILL_FILE" | head -1 | cut -d: -f1)
if [[ -n "$L_COUNTER" && -n "$L_DISPATCH" && "$L_COUNTER" -lt "$L_DISPATCH" ]]; then
  pass "M86.6 — AUTO_REVIEW_DISPATCHED counter write precedes Skill() dispatch (#89 cap-ordering preserved after #95 probe insertion; L_COUNTER=$L_COUNTER < L_DISPATCH=$L_DISPATCH)"
else
  fail "M86.6 — AUTO_REVIEW_DISPATCHED counter MUST precede Skill() dispatch (L_COUNTER=$L_COUNTER L_DISPATCH=$L_DISPATCH)"
fi

# M86.7 — Common Mistakes section documents the #95 probe (defends against future
# extensions that try to introduce review_pr_pending_label_present as a new enum value)
CM_START=$(grep -n '^## Common Mistakes' "$SKILL_FILE" | head -1 | cut -d: -f1)
CM_END=$(awk -v s="$CM_START" 'NR > s && /^## / { print NR; exit }' "$SKILL_FILE")
if [[ -n "$CM_START" && -n "$CM_END" ]]; then
  CM_BLOCK=$(sed -n "${CM_START},${CM_END}p" "$SKILL_FILE")
  if echo "$CM_BLOCK" | grep -q '#95'; then
    pass "M86.7 — Common Mistakes section documents the #95 probe (defends against review_pr_pending_label_present regression)"
  else
    fail "M86.7 — Common Mistakes section MUST mention #95 (spec C3 / T4 Edit B)"
  fi
else
  fail "M86.7 — could not locate ## Common Mistakes section (CM_START=$CM_START CM_END=$CM_END)"
fi

# M86.8 — AUDIT_EVENT_ENUM declares audit_json_phase2_5_parse_failure (#116 / O1)
# Naming convention: snake_case matches the 50+ existing enum members (review-pr finding B4).
if grep -qE '^\| `AUDIT_EVENT_ENUM`.*`audit_json_phase2_5_parse_failure`' "$SKILL_FILE"; then
  pass "M86.8 — AUDIT_EVENT_ENUM row contains audit_json_phase2_5_parse_failure literal (#116 / RFC 0002 O1 + B4 snake_case rename)"
else
  fail "M86.8 — AUDIT_EVENT_ENUM MUST declare audit_json_phase2_5_parse_failure (#116 spec D8; constraints [hard]; B4 snake_case convention)"
fi

# M86.9 — AUDIT_EVENT_ENUM declares halt_tool_unavailable (#116 / O3 + B3)
# The O3 ToolSearch fail-fast block in commands/review-pr.md emits this event
# on AskUserQuestion load failure; it MUST be declared in the canonical enum.
if grep -qE '^\| `AUDIT_EVENT_ENUM`.*`halt_tool_unavailable`' "$SKILL_FILE"; then
  pass "M86.9 — AUDIT_EVENT_ENUM row contains halt_tool_unavailable literal (#116 / RFC 0002 O3; constraints [hard])"
else
  fail "M86.9 — AUDIT_EVENT_ENUM MUST declare halt_tool_unavailable (#116 O3; constraints [hard])"
fi

echo
echo "== M87: Three /merge override flags declared in both commands/merge.md and merge-pipeline/SKILL.md =="

# M87.1–M87.3 — argument-hint declarations in commands/merge.md frontmatter
for FLAG in --accept-blocker-deferred --accept-critical-deferred --i-know-what-im-doing; do
  if grep -E '^argument-hint:' "$CMD_FILE" | grep -q -- "$FLAG"; then
    pass "M87.argv-$FLAG — commands/merge.md argument-hint declares $FLAG"
  else
    fail "M87.argv-$FLAG — commands/merge.md argument-hint MUST declare $FLAG"
  fi
done

# M87.4–M87.6 — flag-purpose prose in commands/merge.md (bulleted-list entries
# in the Usage section).
assert_grep "$CMD_FILE" \
  '`--accept-blocker-deferred`.*opt-in override' \
  "M87.4 — commands/merge.md documents --accept-blocker-deferred purpose"
assert_grep "$CMD_FILE" \
  '`--accept-critical-deferred`.*opt-in override' \
  "M87.5 — commands/merge.md documents --accept-critical-deferred purpose"
assert_grep "$CMD_FILE" \
  '`--i-know-what-im-doing`.*required.*override|required to land.*--i-know-what-im-doing' \
  "M87.6 — commands/merge.md documents --i-know-what-im-doing purpose"

# M87.7–M87.9 — Constants table entries OR Inputs prose in merge-pipeline/SKILL.md
# (the spec records these under `## Inputs` not a literal `Constants` table row;
# accept either anchor).
assert_grep "$SKILL_FILE" \
  '`--accept-blocker-deferred`.*RFC 0002.*added v0\.26\.0' \
  "M87.7 — SKILL.md declares --accept-blocker-deferred (RFC 0002 §3.6)"
assert_grep "$SKILL_FILE" \
  '`--accept-critical-deferred`.*RFC 0002.*added v0\.26\.0' \
  "M87.8 — SKILL.md declares --accept-critical-deferred (RFC 0002 §3.6)"
assert_grep "$SKILL_FILE" \
  '`--i-know-what-im-doing`.*RFC 0002.*added v0\.26\.0' \
  "M87.9 — SKILL.md declares --i-know-what-im-doing (RFC 0002 §3.5)"

# M87.10–M87.12 — Inputs prose body in merge-pipeline/SKILL.md mentions each flag
# by exact string with RFC reference. (Same SKILL_FILE; different surface — the
# full-sentence prose body that downstream agents read.)
assert_grep "$SKILL_FILE" \
  'accept_blocker_deferred_flag' \
  "M87.10 — SKILL.md names accept_blocker_deferred_flag input variable"
assert_grep "$SKILL_FILE" \
  'accept_critical_deferred_flag' \
  "M87.11 — SKILL.md names accept_critical_deferred_flag input variable"
assert_grep "$SKILL_FILE" \
  'i_know_what_im_doing_flag' \
  "M87.12 — SKILL.md names i_know_what_im_doing_flag input variable"

# M87.13 — tombstone: no env-var or config-key variant exists for these flags
# (constraints [hard]: "all per-invocation only (no env-var, no config key)").
# Check that the deprecated env-var pattern does NOT appear for these specific
# tokens in either file (allow-list other AUTO_REVIEW / UBERDEV_ env-vars).
for TOKEN in ACCEPT_BLOCKER_DEFERRED ACCEPT_CRITICAL_DEFERRED I_KNOW_WHAT_IM_DOING; do
  if grep -qE "UBERDEV_${TOKEN}|env override.*${TOKEN}" "$CMD_FILE" "$SKILL_FILE"; then
    fail "M87.13.$TOKEN — env-var ${TOKEN} MUST NOT exist (constraints [hard]: per-invocation only)"
  else
    pass "M87.13.$TOKEN — no env-var variant for ${TOKEN} (constraints [hard]; tombstone)"
  fi
done

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
