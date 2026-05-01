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
#   M3  — commands/merge.md references uberdev:merge skill (not merge-prs).
#   M4  — skills/merge/SKILL.md has all four Phase headings (1..4).
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
#   M22 — SKILL.md STRATEGY_ENUM declares defer and drop.
#   M23 — SKILL.md AUDIT_EVENT_ENUM declares all new autopilot events.
#   M24 — SKILL.md declares PARK_REASON_ENUM, STRATEGY_REASON_ENUM, STALE_REBASE_DECISION_ENUM.
#   M25 — SKILL.md Phase 3.3v test-fail covers RE-RESOLVE/STRATEGY-SWITCH/PARK with bounds.
#   M26 — SKILL.md Phase 4.5 documents agent-decided rebase with safety preconditions.
#   M27 — SKILL.md run-summary block describes Parked and Deferred outcomes.
#   M28 — SKILL.md prints bot_authors_allow_list at run start AND in run-summary block.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD_FILE="$REPO_ROOT/plugins/uberdev/commands/merge.md"
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/merge/SKILL.md"
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

echo "== M1: commands/merge.md exists with required frontmatter =="
assert_grep "$CMD_FILE" '^description:' "M1.1 — has description key"
assert_grep "$CMD_FILE" '^argument-hint:' "M1.2 — has argument-hint key"
assert_grep "$CMD_FILE" '^allowed-tools:' "M1.3 — has allowed-tools key"

echo
echo "== M2: commands/merge.md is a thin dispatcher (≤ 50 lines) =="
LINE_COUNT=$(wc -l < "$CMD_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -le 50 ]; then
  pass "M2 — $LINE_COUNT lines (≤ 50)"
else
  fail "M2 — $LINE_COUNT lines (> 50, dispatcher should stay thin)"
fi

echo
echo "== M3: commands/merge.md references uberdev:merge skill =="
assert_grep "$CMD_FILE" 'uberdev:merge([^-A-Za-z0-9_]|$)' \
  "M3 — invokes uberdev:merge (not merge-prs or any other name)"
# Negative: must NOT reference the rejected skill name 'merge-prs'.
if grep -qE 'merge-prs\b' "$CMD_FILE"; then
  fail "M3.neg — references rejected skill name 'merge-prs'"
else
  pass "M3.neg — does NOT reference rejected skill name 'merge-prs'"
fi

echo
echo "== M4: skills/merge/SKILL.md exists with all four phase headings =="
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
echo "== M16: SKILL.md Phase 1 atomic-write uses same-directory mktemp pattern (D8a) =="
# M16 is load-bearing: D8a's atomic write of .claude/uberdev.local.md
# relies on mv -f being atomic, which is only true when source and
# destination share a filesystem. A bare `mktemp` defaults to $TMPDIR
# and can degrade to copy+delete on machines where .claude/ lives on a
# different volume. Phase 1 MUST root the tempfile in the target's
# directory (sibling tempfile pattern). Without this assertion, a
# well-meaning future edit could silently re-introduce $TMPDIR-based
# mktemp and break atomicity.
if awk '/^## Phase 1/,/^## Phase 2/' "$SKILL_FILE" | \
     grep -qE 'mktemp[^|`]*(--tmpdir="?\$\(dirname|"\$\{?TARGET\}?\.[A-Za-z]*X{3,}"|"\$TARGET\.[A-Za-z]*X{3,}")'; then
  pass "M16 — Phase 1 mktemp roots tempfile in target directory (atomic mv guaranteed)"
else
  fail "M16 — Phase 1 mktemp must use same-directory pattern (--tmpdir=\"\$(dirname …)\" or \"\$TARGET.XXXXXX\")"
  echo "         (bare mktemp defaults to \$TMPDIR; mv -f across filesystems is NOT atomic)"
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
assert_grep "$CMD_FILE" '^argument-hint:.*--yes\|-y' \
  "M20.1 — argument-hint frontmatter still lists --yes|-y (parsed for backward compat)"
assert_grep "$CMD_FILE" '^\*\*Usage:\*\*.*--yes\|-y' \
  "M20.2 — Usage line still lists --yes|-y"
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
echo "== M22: SKILL.md STRATEGY_ENUM declares defer and drop =="
if grep -E '^\| `STRATEGY_ENUM` \|' "$SKILL_FILE" | grep -qE '`defer`' && \
   grep -E '^\| `STRATEGY_ENUM` \|' "$SKILL_FILE" | grep -qE '`drop`'; then
  pass "M22 — STRATEGY_ENUM lists both \`defer\` and \`drop\`"
else
  fail "M22 — STRATEGY_ENUM row in Constants must list both \`defer\` and \`drop\`"
fi

echo
echo "== M23: SKILL.md AUDIT_EVENT_ENUM declares all new autopilot events =="
for ev in pr_parked pr_deferred stale_branch_rebase_decision deprecated_flag_used agent_strategy_switch test_fail_agent_decision; do
  if grep -E '^\| `AUDIT_EVENT_ENUM` \|' "$SKILL_FILE" | grep -qE "\`$ev\`"; then
    pass "M23.$ev — AUDIT_EVENT_ENUM declares \`$ev\`"
  else
    fail "M23.$ev — AUDIT_EVENT_ENUM missing \`$ev\`"
  fi
done

echo
echo "== M24: SKILL.md declares PARK_REASON_ENUM, STRATEGY_REASON_ENUM, STALE_REBASE_DECISION_ENUM =="
for c in PARK_REASON_ENUM STRATEGY_REASON_ENUM STALE_REBASE_DECISION_ENUM; do
  assert_grep "$SKILL_FILE" "\`$c\`" "M24.$c — \`$c\` constant declared"
done
# M24.PARK_REASON_ENUM values
assert_grep "$SKILL_FILE" '`test-fail-exhausted`' \
  "M24.PARK.test-fail — PARK_REASON_ENUM lists \`test-fail-exhausted\`"
assert_grep "$SKILL_FILE" '`external-author-not-allow-listed`' \
  "M24.PARK.ext-author — PARK_REASON_ENUM lists \`external-author-not-allow-listed\`"

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
echo "== M27: SKILL.md run-summary block describes Parked and Deferred outcomes =="
SUMMARY_BLOCK=$(awk '/^### Run-summary block/,/^## /' "$SKILL_FILE")
for outcome in Parked Deferred; do
  if echo "$SUMMARY_BLOCK" | grep -qE "^[[:space:]]*${outcome}:"; then
    pass "M27.$outcome — run-summary block names $outcome outcome at top level"
  else
    fail "M27.$outcome — run-summary block MUST list ${outcome}: <count> at top level (alongside Merged/Skipped/Aborted)"
  fi
done
for field in 'strategy:' 'rationale:' 'outcome:' 'park reason:'; do
  if echo "$SUMMARY_BLOCK" | grep -qiE "$field"; then
    pass "M27.field[$field] — run-summary detail block names \"$field\" field"
  else
    fail "M27.field[$field] — run-summary detail block MUST include \"$field\" field"
  fi
done

echo
echo "== M28: SKILL.md prints bot_authors_allow_list at run start AND in run-summary block =="
PHASE_1=$(awk '/^## Phase 1/,/^## Phase 2/' "$SKILL_FILE")
if echo "$PHASE_1" | grep -qiE '/merge autopilot — allow-listed authors|/merge autopilot -- allow-listed authors|^### Step 1\.0|allow-listed authors:'; then
  pass "M28.preflight — Phase 1 prints bot_authors_allow_list summary at run start"
else
  fail "M28.preflight — Phase 1 MUST print bot_authors_allow_list summary at run start (pre-flight banner)"
fi
SUMMARY_BLOCK=$(awk '/^### Run-summary block/,/^## /' "$SKILL_FILE")
if echo "$SUMMARY_BLOCK" | grep -qiE 'Allow-listed authors|allow-list|bot_authors_allow_list'; then
  pass "M28.summary — run-summary block re-prints bot_authors_allow_list as audit anchor"
else
  fail "M28.summary — run-summary block MUST re-print bot_authors_allow_list (audit anchor)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
