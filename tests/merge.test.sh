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

echo "== M1: commands/merge.md exists with required frontmatter =="
assert_grep "$CMD_FILE" '^description:' "M1.1 — has description key"
assert_grep "$CMD_FILE" '^argument-hint:' "M1.2 — has argument-hint key"
assert_grep "$CMD_FILE" '^allowed-tools:' "M1.3 — has allowed-tools key"

echo
echo "== M2: commands/merge.md is a thin dispatcher (≤ 50 lines) =="
LINE_COUNT=$(wc -l < "$CMD_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -le 50 ]; then
  echo "  PASS  M2 — $LINE_COUNT lines (≤ 50)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M2 — $LINE_COUNT lines (> 50, dispatcher should stay thin)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M3: commands/merge.md references uberdev:merge skill =="
assert_grep "$CMD_FILE" 'uberdev:merge([^-A-Za-z0-9_]|$)' \
  "M3 — invokes uberdev:merge (not merge-prs or any other name)"
# Negative: must NOT reference the rejected skill name 'merge-prs'.
if grep -qE 'merge-prs\b' "$CMD_FILE"; then
  echo "  FAIL  M3.neg — references rejected skill name 'merge-prs'"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  M3.neg — does NOT reference rejected skill name 'merge-prs'"
  PASS=$((PASS + 1))
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
echo "== M12: SKILL.md mandates pre-push test gate (D16, no skip path) =="
assert_grep "$SKILL_FILE" 'test gate|test command runs in scratch worktree|run the project' \
  "M12 — pre-push test gate prose present"

echo
echo "== M13: SKILL.md describes fork-PR preflight refusal for org-owned forks (Q3) =="
assert_grep "$SKILL_FILE" 'maintainerCanModify' \
  "M13.1 — maintainerCanModify field consumed"
assert_grep "$SKILL_FILE" 'org-owned|Organization' \
  "M13.2 — fork-org refusal prose"

echo
echo "== M14: agents/conflict-resolver.md exists with frontmatter + return contract =="
if [ ! -r "$AGENT_FILE" ]; then
  echo "  FAIL  M14 — agent file missing: $AGENT_FILE"
  FAIL=$((FAIL + 1))
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
  echo "  PASS  M15.2 — 'MUST NOT' (or 'must not') near Co-Authored-By reference"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M15.2 — no 'MUST NOT' guard near Co-Authored-By in SKILL.md"
  echo "         (D13 mandates the resolution commit MUST NOT include the Claude trailer)"
  FAIL=$((FAIL + 1))
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
  echo "  PASS  M16 — Phase 1 mktemp roots tempfile in target directory (atomic mv guaranteed)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M16 — Phase 1 mktemp must use same-directory pattern (--tmpdir=\"\$(dirname …)\" or \"\$TARGET.XXXXXX\")"
  echo "         (bare mktemp defaults to \$TMPDIR; mv -f across filesystems is NOT atomic)"
  FAIL=$((FAIL + 1))
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
assert_grep "$SKILL_FILE" '`AUTO_CONFIRM_DEFAULT_(SINGLE|MULTI)`' \
  "M17.3 — AUTO_CONFIRM_DEFAULT_SINGLE/MULTI constants declared"
assert_grep "$SKILL_FILE" 'Auto-confirm resolution.*CLI flag wins' \
  "M17.4 — auto-confirm precedence chain (CLI > config > scope) documented in Inputs"

echo
echo "== M18: SKILL.md Phase 2.4 documents both auto-confirm ON and OFF branches =="
# M18 prevents silent deletion of either branch — interactive [y/N]
# users (auto-confirm OFF) and auto-mode users (auto-confirm ON) must
# both stay supported.
if awk '/^### Step 2\.4/,/^## Phase 3/' "$SKILL_FILE" | \
     grep -qE 'If auto-confirm is ON' && \
   awk '/^### Step 2\.4/,/^## Phase 3/' "$SKILL_FILE" | \
     grep -qE 'If auto-confirm is OFF'; then
  echo "  PASS  M18.1 — Phase 2.4 documents both auto-confirm ON and OFF branches"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M18.1 — Phase 2.4 must document BOTH 'If auto-confirm is ON' AND 'If auto-confirm is OFF'"
  FAIL=$((FAIL + 1))
fi
assert_grep "$SKILL_FILE" 'Apply this plan\?' \
  "M18.2 — interactive-mode prompt 'Apply this plan?' present"

echo
echo "== M19: SKILL.md Phase 4.5 states the no-auto-rebase invariant AND covers both modes =="
# M19 is load-bearing: Phase 4.5 stale-branch handling MUST never
# auto-rebase. Auto-confirm only suppresses the offer; it never
# authorises destructive history-rewriting. A future edit that wires
# auto-confirm to auto-rebase "for efficiency" could silently rewind
# the user's in-flight work.
assert_grep "$SKILL_FILE" 'never\*\* runs `git rebase` automatically|Never auto-execute' \
  "M19.1 — Phase 4.5 'never auto-rebase' invariant stated"
if awk '/^### Step 4\.5/,/^### Step 4\.6/' "$SKILL_FILE" | \
     grep -qE 'If auto-confirm is ON' && \
   awk '/^### Step 4\.5/,/^### Step 4\.6/' "$SKILL_FILE" | \
     grep -qE 'If auto-confirm is OFF'; then
  echo "  PASS  M19.2 — Phase 4.5 documents both auto-confirm ON (list-only) and OFF (per-branch typed yes) branches"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M19.2 — Phase 4.5 must document BOTH 'If auto-confirm is ON' AND 'If auto-confirm is OFF'"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M20: commands/merge.md exposes --yes / -y in argument-hint AND Usage line =="
# M20 keeps the dispatcher's frontmatter and body in sync. argument-hint
# powers slash-help auto-completion; Usage is the human-readable line.
# Drift between the two confuses the user.
assert_grep "$CMD_FILE" '^argument-hint:.*--yes\|-y' \
  "M20.1 — argument-hint frontmatter lists --yes|-y"
assert_grep "$CMD_FILE" '^\*\*Usage:\*\*.*--yes\|-y' \
  "M20.2 — Usage line lists --yes|-y"
assert_grep "$CMD_FILE" '`--yes` / `-y`.*skip' \
  "M20.3 — doc bullet for --yes / -y describes prompt suppression"

echo
echo "== M21: using-uberdev/SKILL.md documents auto_confirm in YAML example AND precedence recap =="
USING_SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
if [ ! -r "$USING_SKILL_FILE" ]; then
  echo "  FAIL  M21 — using-uberdev SKILL.md missing or unreadable: $USING_SKILL_FILE"
  FAIL=$((FAIL + 1))
else
  assert_grep "$USING_SKILL_FILE" '^auto_confirm:' \
    "M21.1 — auto_confirm key present in YAML example"
  assert_grep "$USING_SKILL_FILE" '\*\*`auto_confirm` precedence:\*\*' \
    "M21.2 — auto_confirm precedence paragraph present"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
