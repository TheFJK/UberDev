#!/usr/bin/env bash
# Guard against the documentation-drift class fixed in issue #273:
#   1. plugins/uberdev/docs/testing.md must describe the REAL harness
#      (tests/*.test.sh shape-checks + test.yml two-job matrix; marketplace key
#      uberdev@uberdev) — not verbatim upstream Superpowers (tests/claude-code/,
#      test-helpers.sh, analyze-token-usage.py, run-skill-tests.sh,
#      superpowers@superpowers-dev, "run FROM the superpowers directory").
#   2. CONTRIBUTING.md must not carry the dead [Repo layout](README.md#repo-layout)
#      link (README has no such anchor) nor the false "no behavioral tests" claim,
#      and must point at .github/workflows/test.yml as the test-set SSOT.
#   3. docs/rfc/ must have NO duplicate RFC numbers (the 0004 collision: the
#      alias RFC was renumbered to 0011; the dispatch RFC keeps 0004).
#   4. The dispatch RFC (0004) §4/§5 version refs must agree with its Status
#      line + the CHANGELOG: target v0.30.0, not v0.29.0.
#   5. The alias-RFC cross-refs in hooks/session-start + lib/aliases-sync.sh must
#      point at RFC 0011, and no stale 0004-alias-install path ref may survive.
#
# These are structural greps over the shipped docs/shell files — they exercise
# the source bytes, not a running session. Every assertion below FAILS on the
# pre-#273 tree and PASSES after the fix.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTING_MD="$REPO_ROOT/plugins/uberdev/docs/testing.md"
CONTRIBUTING_MD="$REPO_ROOT/CONTRIBUTING.md"
RFC_DIR="$REPO_ROOT/docs/rfc"
DISPATCH_RFC="$RFC_DIR/0004-cross-platform-dispatch-backends.md"
ALIAS_RFC="$RFC_DIR/0011-alias-install-reliability.md"
SESSION_START="$REPO_ROOT/plugins/uberdev/hooks/session-start"
ALIASES_SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
TEST_YML="$REPO_ROOT/.github/workflows/test.yml"
# Hook-diet surfaces (#309 / RFC 0012 §7.7): the session-start injection is
# using-uberdev/SKILL.md (primer only); the config schema lives in the sibling
# references/configuration.md.
USING_SKILL="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
CONFIG_REF="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/references/configuration.md"
HOOKS_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks.json"
HOOKS_CURSOR_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks-cursor.json"
PRE_COMPACT="$REPO_ROOT/plugins/uberdev/hooks/pre-compact"

# Hard-fail (exit 2) on a missing input — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$TESTING_MD" "$CONTRIBUTING_MD" "$DISPATCH_RFC" "$ALIAS_RFC" \
         "$SESSION_START" "$ALIASES_SYNC" "$TEST_YML" \
         "$USING_SKILL" "$CONFIG_REF" "$HOOKS_JSON" "$HOOKS_CURSOR_JSON" \
         "$PRE_COMPACT"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

PASS=0
FAIL=0

# Assert a regex IS present in a file.
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# Assert a fixed string is ABSENT from a file (grep -F: literal, no regex).
assert_absent_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        unexpected literal: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

echo "== testing.md describes the REAL harness, not vendored Superpowers =="
# Vendored-upstream tokens that must NOT survive (the whole pre-#273 file).
assert_absent_fixed "$TESTING_MD" "tests/claude-code/"        "T1.1 testing.md drops the upstream tests/claude-code/ path"
assert_absent_fixed "$TESTING_MD" "test-helpers.sh"           "T1.2 testing.md drops upstream test-helpers.sh"
assert_absent_fixed "$TESTING_MD" "analyze-token-usage.py"    "T1.3 testing.md drops upstream analyze-token-usage.py"
assert_absent_fixed "$TESTING_MD" "run-skill-tests.sh"        "T1.4 testing.md drops upstream run-skill-tests.sh"
assert_absent_fixed "$TESTING_MD" "superpowers@superpowers-dev" "T1.5 testing.md drops upstream superpowers@superpowers-dev marketplace key"
# Case-insensitive: kill any 'superpowers directory' instruction in any casing.
if grep -qiE 'superpowers (plugin )?directory' "$TESTING_MD"; then
  echo "  FAIL  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"
  echo "        file: $TESTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"; PASS=$((PASS + 1))
fi
# Real harness IS described.
assert_grep "$TESTING_MD" 'tests/\*\.test\.sh'              "T1.7 testing.md names the real tests/*.test.sh shape-checks"
assert_grep "$TESTING_MD" '\.github/workflows/test\.yml'    "T1.8 testing.md points at .github/workflows/test.yml"
assert_grep "$TESTING_MD" 'uberdev@uberdev'                 "T1.9 testing.md uses the real uberdev@uberdev marketplace key"
assert_grep "$TESTING_MD" 'shape-checks-windows|two-job|windows-latest' "T1.10 testing.md documents the two-job CI matrix"
assert_grep "$TESTING_MD" 'solve-pipeline-zsh\.test\.sh'    "T1.11 testing.md names the zsh-runtime fixture"

echo
echo "== CONTRIBUTING.md: no dead link, no false claim, test.yml is SSOT =="
assert_absent_fixed "$CONTRIBUTING_MD" "README.md#repo-layout" "T2.1 CONTRIBUTING drops the dead README.md#repo-layout link"
# The false 'no runtime behavioral tests' sentence must be gone.
if grep -qiE 'no runtime behavioral tests' "$CONTRIBUTING_MD"; then
  echo "  FAIL  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"
  echo "        file: $CONTRIBUTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"; PASS=$((PASS + 1))
fi
assert_grep "$CONTRIBUTING_MD" '\.github/workflows/test\.yml' "T2.3 CONTRIBUTING points at test.yml"
assert_grep "$CONTRIBUTING_MD" 'single source of truth|source of truth' "T2.4 CONTRIBUTING frames test.yml as the test-set SSOT"

echo
echo "== docs/rfc/: no duplicate RFC numbers =="
# Extract the leading 4-digit number from every docs/rfc/NNNN-*.md filename and
# assert each appears exactly once. Catches the 0004 collision (and any future
# one) dynamically, without hardcoding the current RFC set.
DUP_NUMS="$(
  for f in "$RFC_DIR"/[0-9][0-9][0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    echo "${base%%-*}"
  done | sort | uniq -d
)"
if [ -n "$DUP_NUMS" ]; then
  echo "  FAIL  T3.1 every docs/rfc/ number is unique"
  echo "        duplicate RFC number(s): $(echo "$DUP_NUMS" | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T3.1 every docs/rfc/ number is unique (no NNNN collision)"; PASS=$((PASS + 1))
fi
# The renumbered alias RFC exists at 0011 and self-identifies as RFC 0011.
assert_grep "$ALIAS_RFC" '^# RFC 0011 — Alias-Install Reliability' "T3.2 alias RFC header self-identifies as RFC 0011"
# The dispatch RFC keeps 0004.
assert_grep "$DISPATCH_RFC" '^# RFC 0004 — Cross-Platform Dispatch' "T3.3 dispatch RFC keeps RFC 0004 header"

echo
echo "== dispatch RFC 0004: internal version refs agree on v0.30.0 =="
# Status line is the anchor of truth (already v0.30.0); §4/§5 must match it.
assert_grep "$DISPATCH_RFC" 'Status.*Implemented — v0\.30\.0' "T4.1 dispatch RFC Status is v0.30.0"
# NOTE: the RFC uses a multibyte UTF-8 arrow (U+2192) between versions. Match
# it with `.*` (not a single `.`) so the pattern holds in a C/POSIX locale too
# (where `.` is one byte and the arrow is three) — env -i / Git Bash safe.
assert_grep "$DISPATCH_RFC" 'version bump .0\.29\.0.*0\.30\.0' "T4.2 §4 File-impact bump reads 0.29.0 -> 0.30.0"
assert_grep "$DISPATCH_RFC" 'CHANGELOG\.md.*## \[0\.30\.0\].*section' "T4.3 §5 Migration cites the [0.30.0] CHANGELOG section"
assert_grep "$DISPATCH_RFC" 'git tag .v0\.30\.0' "T4.4 §5 Migration cites tag v0.30.0"
# The wrong target version must be gone from §4/§5 (the contradiction). A bare
# 0.28.0/0.29.0 as the bump TARGET '-> 0.29.0' or tag 'v0.29.0' must not survive.
if grep -qE '0\.28\.0.*0\.29\.0|## \[0\.29\.0\] section|git tag .v0\.29\.0' "$DISPATCH_RFC"; then
  echo "  FAIL  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"
  echo "        file: $DISPATCH_RFC"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"; PASS=$((PASS + 1))
fi

echo
echo "== alias-RFC cross-refs repointed to RFC 0011; no stale 0004-alias path =="
assert_grep "$SESSION_START" 'RFC 0011' "T5.1 hooks/session-start cites RFC 0011"
assert_grep "$ALIASES_SYNC"  'RFC 0011' "T5.2 lib/aliases-sync.sh cites RFC 0011"
# The cross-ref files must no longer cite the alias work as 'RFC 0004' (the
# dispatch RFC owns 0004; neither of these two files references dispatch).
assert_absent_fixed "$SESSION_START" "RFC 0004" "T5.3 hooks/session-start no longer cites the (dispatch-owned) RFC 0004"
assert_absent_fixed "$ALIASES_SYNC"  "RFC 0004" "T5.4 lib/aliases-sync.sh no longer cites the (dispatch-owned) RFC 0004"
# No surviving path reference to the old alias-RFC filename anywhere in the two
# cross-ref files or the renamed RFC itself.
for f in "$SESSION_START" "$ALIASES_SYNC" "$ALIAS_RFC"; do
  assert_absent_fixed "$f" "0004-alias-install-reliability" "T5.5 no stale 0004-alias-install-reliability path in $(basename "$f")"
done

echo
echo "== T6: hook diet (#309 / RFC 0012 §7.7) — schema in references/configuration.md, primer slim =="
# The SessionStart hook injects using-uberdev/SKILL.md on EVERY startup/clear/
# compact. The 11 KB config schema moved to references/configuration.md; the
# primer keeps only a pointer. These pins make the diet a ratchet.
assert_grep "$USING_SKILL" 'references/configuration\.md' \
  "T6.1 SKILL.md primer points at references/configuration.md"
assert_absent_fixed "$USING_SKILL" "solve_tier_floor" \
  "T6.2 SKILL.md no longer carries the config schema (solve_tier_floor moved)"
assert_absent_fixed "$USING_SKILL" "bot_authors_allow_list" \
  "T6.3 SKILL.md no longer carries the config schema (bot_authors_allow_list moved)"
assert_grep "$CONFIG_REF" 'solve_tier_floor' \
  "T6.4 references/configuration.md carries the moved schema (solve_tier_floor)"
# Size ratchet: the per-session-event injection payload stays dieted. 7168 B
# (7 KiB) leaves headroom over the ~6.5 KB post-diet primer without allowing
# the schema back in (pre-diet was 16,511 B).
USING_SKILL_BYTES="$(wc -c < "$USING_SKILL" | tr -d '[:space:]')"
if [ "$USING_SKILL_BYTES" -le 7168 ] 2>/dev/null; then
  echo "  PASS  T6.5 using-uberdev/SKILL.md stays dieted (${USING_SKILL_BYTES} B <= 7168 B)"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6.5 using-uberdev/SKILL.md regressed past the diet ratchet (${USING_SKILL_BYTES} B > 7168 B)"
  echo "        file: $USING_SKILL"; FAIL=$((FAIL + 1))
fi
# Workflow sanction lines (RFC 0012 §4.1): the primer must sanction
# skill-mandated Workflow calls so migrated pipelines are covered from day one.
assert_grep "$USING_SKILL" 'Skill-mandated Workflow calls' \
  "T6.6 primer carries the Workflow sanction section"
assert_grep "$USING_SKILL" 'WORKFLOW_ARGS_BEGIN' \
  "T6.7 primer names the WORKFLOW_ARGS_BEGIN/END relay markers"
assert_grep "$USING_SKILL" 'No-Workflow fallback' \
  "T6.8 primer routes tool-less platforms to the No-Workflow fallback section"

echo
echo "== T6b: alias-count claims are SSOT-derived (lib/aliases-sync.sh ALIASES) =="
# Derive the canonical alias count + short names from the ALIASES table (the
# SSOT) instead of hardcoding, so adding alias #14 reds this test until the
# docs follow. Range: the ALIASES='...' assignment through the closing quote;
# every row contains a pipe.
ALIAS_ROWS="$(sed -n "/^ALIASES='/,/^'\$/p" "$ALIASES_SYNC" | grep '|' | sed "s/^ALIASES='//")"
ALIAS_COUNT="$(printf '%s\n' "$ALIAS_ROWS" | grep -c '|')"
if [ "$ALIAS_COUNT" -ge 1 ] 2>/dev/null; then
  echo "  PASS  T6b.1 ALIASES SSOT parsed (${ALIAS_COUNT} rows)"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6b.1 could not parse ALIASES rows from $ALIASES_SYNC"; FAIL=$((FAIL + 1))
fi
assert_grep "$CONFIG_REF" "installs ${ALIAS_COUNT} top-level forwarder commands" \
  "T6b.2 configuration.md alias paragraph claims the SSOT count (${ALIAS_COUNT})"
MISSING_ALIAS=""
while IFS='|' read -r short _rest; do
  [ -n "$short" ] || continue
  grep -qF -e "/${short}" "$CONFIG_REF" || MISSING_ALIAS="${MISSING_ALIAS} /${short}"
done <<EOF_ALIASES
$ALIAS_ROWS
EOF_ALIASES
if [ -z "$MISSING_ALIAS" ]; then
  echo "  PASS  T6b.3 configuration.md lists every SSOT short alias"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6b.3 configuration.md missing SSOT alias name(s):${MISSING_ALIAS}"
  echo "        file: $CONFIG_REF"; FAIL=$((FAIL + 1))
fi
# The hook must not re-grow a hardcoded count claim (the 7-vs-11-vs-13 drift
# class): no number word / digit immediately before 'top-level forwarder'.
if grep -qE '(seven|nine|ten|eleven|twelve|thirteen|[0-9]+) top-level forwarder' "$SESSION_START"; then
  echo "  FAIL  T6b.4 hooks/session-start carries a hardcoded forwarder count (drift-prone)"
  echo "        file: $SESSION_START"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T6b.4 hooks/session-start carries no hardcoded forwarder count"; PASS=$((PASS + 1))
fi

echo
echo "== T7: CONTRIBUTING.md hook-event + zsh-fixture claims match reality =="
assert_absent_fixed "$CONTRIBUTING_MD" "PreToolUse" \
  "T7.1 CONTRIBUTING drops the false PreToolUse hook claim (no such handler is wired)"
assert_grep "$CONTRIBUTING_MD" 'UserPromptSubmit' \
  "T7.2 CONTRIBUTING names the real UserPromptSubmit handler"
assert_absent_fixed "$CONTRIBUTING_MD" "one fixture," \
  "T7.3 CONTRIBUTING drops the stale 'one fixture' zsh claim (three -zsh fixtures run under zsh)"
assert_grep "$CONTRIBUTING_MD" 'tests/\*-zsh\.test\.sh' \
  "T7.4 CONTRIBUTING's local-run loop special-cases the *-zsh.test.sh fixtures"
# SSOT cross-check: every fixture test.yml runs under zsh must match the
# *-zsh.test.sh glob CONTRIBUTING documents — keeps T7.4's pattern truthful.
BAD_ZSH_WIRING="$(grep -E '^[[:space:]]*zsh tests/' "$TEST_YML" | grep -vE 'zsh tests/[A-Za-z0-9_-]*-zsh\.test\.sh' || true)"
if [ -z "$BAD_ZSH_WIRING" ]; then
  echo "  PASS  T7.5 every zsh-run fixture in test.yml matches the *-zsh.test.sh naming convention"; PASS=$((PASS + 1))
else
  echo "  FAIL  T7.5 test.yml runs zsh fixture(s) outside the *-zsh.test.sh convention CONTRIBUTING documents:"
  echo "$BAD_ZSH_WIRING" | sed 's/^/        /'; FAIL=$((FAIL + 1))
fi

echo
echo "== T8: hooks wiring contract — run-hook.cmd on Claude Code; Cursor is POSIX-direct =="
# hooks.json (Claude Code) must route EVERY handler through the run-hook.cmd
# polyglot (Windows compat). Key-count equality catches a handler added
# without the wrapper.
HOOK_CMD_KEYS="$(grep -c '"command":' "$HOOKS_JSON")"
HOOK_RUNHOOK_REFS="$(grep -c 'run-hook\.cmd' "$HOOKS_JSON")"
if [ "$HOOK_CMD_KEYS" -ge 1 ] && [ "$HOOK_CMD_KEYS" -eq "$HOOK_RUNHOOK_REFS" ]; then
  echo "  PASS  T8.1 hooks.json routes all ${HOOK_CMD_KEYS} handlers through run-hook.cmd"; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.1 hooks.json has ${HOOK_CMD_KEYS} command entries but ${HOOK_RUNHOOK_REFS} run-hook.cmd routes"
  echo "        file: $HOOKS_JSON"; FAIL=$((FAIL + 1))
fi
# hooks-cursor.json deliberately does NOT route through run-hook.cmd: Cursor's
# hook runner execs the bash scripts directly via their shebangs (POSIX hosts).
# run-hook.cmd has no shebang (cmd.exe polyglot), so routing Cursor through it
# would trade a working POSIX path for an unverified Windows one. The decision
# (RFC 0012 §3.13): Cursor on Windows is UNSUPPORTED and documented as such in
# CONTRIBUTING.md. If you flip this, verify Cursor-on-Windows end-to-end first.
assert_absent_fixed "$HOOKS_CURSOR_JSON" "run-hook.cmd" \
  "T8.2 hooks-cursor.json keeps direct POSIX exec (no run-hook.cmd routing)"
assert_grep "$HOOKS_CURSOR_JSON" 'CLAUDE_PLUGIN_ROOT}/hooks/' \
  "T8.3 hooks-cursor.json commands resolve under \${CLAUDE_PLUGIN_ROOT}/hooks/"
assert_grep "$CONTRIBUTING_MD" 'Cursor on Windows is unsupported' \
  "T8.4 CONTRIBUTING documents Cursor-on-Windows as unsupported"
# pre-compact's auto-memory.md contract is live-verified dead-in-repo but kept
# as a documented user/tooling-facing contract (CHANGELOG-published); the hook
# header must say so explicitly so the next reader doesn't re-litigate.
assert_grep "$PRE_COMPACT" 'Contract status \(live-verified' \
  "T8.5 pre-compact documents the verified auto-memory.md contract status"
assert_grep "$PRE_COMPACT" 'DOCUMENTED user/tooling-facing contract' \
  "T8.6 pre-compact states the keep-as-documented-contract decision"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
