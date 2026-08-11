#!/usr/bin/env bash
# Guard against the documentation-drift class fixed in issue #273:
#   1. plugins/uberdev/docs/testing.md must describe the REAL harness
#      (tests/*.test.sh shape-checks + the test.yml CI job layout; marketplace key
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
#   6. (#349) RFC prose must not anchor on `file:line` literals, and every
#      symbol it DOES cite must still resolve in the shipped tree. The prior
#      edition of RFC 0012's §3.3 contract table anchored on line numbers and
#      rotted silently inside one release — its "audit-JSON write" anchor came
#      to point at sequential fanout-cap prose, its locked-marker anchor at a
#      Python heredoc, and its trust-reader anchor at the audit EMITTER rather
#      than the reader. Section T9 below makes both halves enforceable: no
#      `*.md:N` / `*.sh:N` literal inside §1 or the contract table, and every
#      named symbol grep-resolves in plugins/uberdev/.
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
# #349 anchor-rot surfaces: the two RFCs whose prose is consumed as a live
# contract checklist (RFC 0012 §3.3 is the /goal + /review-pr + /merge
# acceptance table; RFC 0005 §9.5 defines the behaviours it locks).
WORKFLOW_RFC="$RFC_DIR/0012-ultracode-workflow-orchestration.md"
GOAL_RFC="$RFC_DIR/0005-uberdev-goal.md"
PLUGIN_DIR="$REPO_ROOT/plugins/uberdev"
HOOKS_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks.json"
HOOKS_CURSOR_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks-cursor.json"
PRE_COMPACT="$REPO_ROOT/plugins/uberdev/hooks/pre-compact"

# Hard-fail (exit 2) on a missing input — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$TESTING_MD" "$CONTRIBUTING_MD" "$DISPATCH_RFC" "$ALIAS_RFC" \
         "$SESSION_START" "$ALIASES_SYNC" "$TEST_YML" \
         "$USING_SKILL" "$CONFIG_REF" "$HOOKS_JSON" "$HOOKS_CURSOR_JSON" \
         "$PRE_COMPACT" "$WORKFLOW_RFC" "$GOAL_RFC"; do
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
assert_grep "$TESTING_MD" 'solve-pipeline-zsh\.test\.sh'    "T1.11 testing.md names the zsh-runtime fixture"

echo
echo "== T1b: CI-layout prose is DERIVED from test.yml, not a hand-written count =="
# Root cause of the 'two-job matrix' rot: the docs hardcoded a job COUNT while
# test.yml grew a third job (supervision-smoke-macos). Derive the job ids from
# the workflow and require the docs to name each one, so the next job addition
# reds here instead of silently making the prose a lie. Scan starts at the
# top-level `jobs:` key so `on: push:` / `concurrency:` children never match.
CI_JOB_IDS="$(awk '
  /^jobs:[[:space:]]*$/          { in_jobs = 1; next }
  in_jobs && /^[^[:space:]#]/    { in_jobs = 0 }
  in_jobs && /^  [a-z0-9][a-z0-9_-]*:[[:space:]]*$/ {
    gsub(/[[:space:]:]/, ""); print
  }
' "$TEST_YML")"
CI_JOB_COUNT="$(printf '%s\n' "$CI_JOB_IDS" | grep -c '[a-z]' || true)"
if [ "${CI_JOB_COUNT:-0}" -ge 2 ] 2>/dev/null; then
  echo "  PASS  T1b.1 test.yml job ids parsed (${CI_JOB_COUNT}: $(printf '%s ' $CI_JOB_IDS))"; PASS=$((PASS + 1))
else
  echo "  FAIL  T1b.1 could not parse >=2 job ids from $TEST_YML"; FAIL=$((FAIL + 1))
fi
# BOTH prose surfaces hand-enumerate the job list, so both are checked: the
# CONTRIBUTING.md paragraph names all jobs inline and rots on the next job
# addition exactly like testing.md's table did.
for job_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  MISSING_JOB_DOC=""
  while IFS= read -r job_id; do
    [ -n "$job_id" ] || continue
    grep -qF -e "$job_id" "$job_doc" || MISSING_JOB_DOC="${MISSING_JOB_DOC} ${job_id}"
  done <<EOF_CI_JOBS
$CI_JOB_IDS
EOF_CI_JOBS
  if [ -z "$MISSING_JOB_DOC" ]; then
    echo "  PASS  T1b.2 $(basename "$job_doc") names every test.yml job"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T1b.2 $(basename "$job_doc") does not name test.yml job(s):${MISSING_JOB_DOC}"
    echo "        file: $job_doc"; FAIL=$((FAIL + 1))
  fi
done
# No hardcoded job-count claim may re-grow in either doc (the drift shape that
# produced 'two-job matrix'). Sharding a job changes the number of CI RUNS
# without changing the number of jobs, so a count in prose is wrong twice over.
# The count token need NOT be adjacent to 'job': 'two shape-check jobs' is the
# same rot as 'two-job matrix', so allow up to three intervening words.
JOB_COUNT_RE='(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+)([ -][a-z]+){0,3}[ -]jobs?([^a-z]|$)'
for count_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  if grep -qiE "$JOB_COUNT_RE" "$count_doc"; then
    echo "  FAIL  T1b.3 $(basename "$count_doc") carries a hardcoded CI job-count claim (drift-prone)"
    grep -inE "$JOB_COUNT_RE" "$count_doc" | cut -c1-120 | sed 's/^/        /'
    echo "        file: $count_doc"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  T1b.3 $(basename "$count_doc") carries no hardcoded CI job-count claim"; PASS=$((PASS + 1))
  fi
done
# Sharding is an execution detail; the docs must say wiring is per JOB so a
# reader never concludes a test needs re-wiring when a shard axis appears.
assert_grep "$TESTING_MD" 'shard' "T1b.4 testing.md explains the per-job (not per-shard) wiring contract"
# Stale-enumeration guard: any *-zsh fixture NAMED in the docs must be one
# test.yml actually invokes with zsh. Catches a renamed/removed fixture that
# the prose keeps advertising (the 'one fixture' / three-name-list class).
ZSH_WIRED="$(grep -oE 'zsh tests/[A-Za-z0-9_-]+-zsh\.test\.sh' "$TEST_YML" | sed 's|^zsh tests/||' | sort -u)"
STALE_ZSH_DOC=""
for zsh_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  while IFS= read -r cited; do
    [ -n "$cited" ] || continue
    grep -qF -e "$cited" <<EOF_ZSH_WIRED || STALE_ZSH_DOC="${STALE_ZSH_DOC} $(basename "$zsh_doc"):${cited}"
$ZSH_WIRED
EOF_ZSH_WIRED
  done <<EOF_ZSH_CITED
$(grep -oE '[A-Za-z0-9_-]+-zsh\.test\.sh' "$zsh_doc" | sort -u)
EOF_ZSH_CITED
done
if [ -z "$STALE_ZSH_DOC" ]; then
  echo "  PASS  T1b.5 every *-zsh fixture named in the docs is one test.yml runs under zsh"; PASS=$((PASS + 1))
else
  echo "  FAIL  T1b.5 docs cite zsh fixture(s) test.yml does not run under zsh:${STALE_ZSH_DOC}"; FAIL=$((FAIL + 1))
fi

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
echo "== T9: RFC anchors are SYMBOLS that resolve, not file:line literals (#349) =="
# Why this section exists: RFC 0012 §3.3's contract table is the acceptance
# checklist a /goal, /review-pr or /merge change is graded against. Its prior
# edition bound every row to a `file:line` literal, and nothing ever resolved
# one — so when the anchored code moved (in the same commits that edited the
# anchored rows), the pointers rotted with no test noticing. Two enforceable
# halves replace that: NO line literals inside the load-bearing prose, and
# every cited symbol must still grep-resolve in the shipped tree.

# --- §1 and the §3.3 contract table, sliced by heading ---------------------
RFC12_S1="$(awk '/^## 1\. Context/{f=1; next} f && /^## 2\./{exit} f' "$WORKFLOW_RFC")"
RFC12_TABLE="$(awk '/^\*\*Joint-migration contract table\.\*\*/{f=1} f && /^### /{exit} f' "$WORKFLOW_RFC")"
# Non-vacuity: a renamed heading must fail loudly, never silently pass zero
# assertions over an empty slice.
for slice_name in S1 TABLE; do
  case "$slice_name" in
    S1)    slice_body="$RFC12_S1"    slice_desc="§1 Context" ;;
    TABLE) slice_body="$RFC12_TABLE" slice_desc="§3.3 contract table" ;;
  esac
  slice_lines="$(printf '%s\n' "$slice_body" | grep -c . || true)"
  if [ "${slice_lines:-0}" -ge 10 ] 2>/dev/null; then
    echo "  PASS  T9.0 RFC 0012 ${slice_desc} slice extracted (${slice_lines} lines)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.0 RFC 0012 ${slice_desc} slice is empty/too small — heading renamed?"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
done

# ANCHOR-FREE: neither `lib/foo.sh:123` nor the `RP:954` / `GS:633-713` /
# `MP:698` / `SKILL:1341` shorthand the old table used may survive.
ANCHOR_RE='\.(md|sh|py|js|json|yaml|yml):[0-9]+|(^|[^A-Za-z])(RP|GS|MP|SKILL):[0-9]+'
for slice_name in S1 TABLE; do
  case "$slice_name" in
    S1)    slice_body="$RFC12_S1"    slice_desc="§1 Context" ;;
    TABLE) slice_body="$RFC12_TABLE" slice_desc="§3.3 contract table" ;;
  esac
  if grep -qE -e "$ANCHOR_RE" <<<"$slice_body"; then
    echo "  FAIL  T9.1 RFC 0012 ${slice_desc} still carries file:line anchors:"
    grep -oE -e "$ANCHOR_RE" <<<"$slice_body" | sort -u | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  T9.1 RFC 0012 ${slice_desc} is anchor-free (symbols only)"; PASS=$((PASS + 1))
  fi
done
assert_grep "$WORKFLOW_RFC" 'Reference convention \(normative for this RFC\)' \
  "T9.2 RFC 0012 states the symbol-over-line-number reference convention"

# --- The contract table names the symbols, and they still exist ------------
# Each pair is "symbol|human description". A rename in the shipped tree reds
# here, which is the entire point: the reference must be resolvable.
CONTRACT_SYMBOLS='review_reserve_run_directory|review-pr run-directory reservation
uberdev_goal_read_trust_signal|goal trust-signal READER (not the audit emitter)
_uberdev_goal_locked_marker_for_pr_fresh|goal locked-marker freshness probe
_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS|review grace window constant
discover_review_verdict_json|canonical verdict selector
uberdev_goal_locate_review_pr_audit_by_pr|PR-keyed verdict locator
uberdev_goal_read_merge_result|merge-result reader
uberdev_goal_review_pr_in_flight|review-pr in-flight probe
uberdev_dispatch_one|dispatch entry point'
while IFS='|' read -r sym desc; do
  [ -n "$sym" ] || continue
  if grep -qF -e "$sym" <<<"$RFC12_TABLE"; then
    echo "  PASS  T9.3 contract table cites \`$sym\` ($desc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.3 contract table no longer cites \`$sym\` ($desc)"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
  if grep -rqF -e "$sym" "$PLUGIN_DIR"; then
    echo "  PASS  T9.4 \`$sym\` resolves in plugins/uberdev/"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.4 \`$sym\` does NOT resolve in plugins/uberdev/ — the RFC cites a dead symbol"
    echo "        renamed? update RFC 0012 §3.3 in the SAME change"; FAIL=$((FAIL + 1))
  fi
done <<EOF_CONTRACT_SYMBOLS
$CONTRACT_SYMBOLS
EOF_CONTRACT_SYMBOLS

# --- §1 is the OTHER symbol-only surface: guard its references too ----------
# The reference convention scopes symbol-only to §1 AND the contract table, so
# §1 needs the same resolvability half. Without it §1 shipped two references
# (`CHUNK_ARRAY=($CHUNK_IDS)`, `_wave_count`) that resolved in NO file — code
# retired by the migration, cited as though it were live.
#
# T9.3b is a small CURATED presence list: the named `Step`/section headings the
# derived scan below cannot see (they are not identifier-shaped) plus the three
# correction anchors this change installed, so a silent revert to prose reds.
SECTION1_SYMBOLS='### Executable setup|the review-pr fence that reserves the run directory
Acquire the single-instance lock|the merge-pipeline single-instance lock step
review_reserve_run_directory|the shipped locked-marker writer
areaPrompt|the scan-fleet area fan-out that replaced the zsh-split wave loop
personaPrompt|the testers round loop that replaced the corrupted count helper'
while IFS='|' read -r sym desc; do
  [ -n "$sym" ] || continue
  if grep -qwF -e "$sym" <<<"$RFC12_S1"; then
    echo "  PASS  T9.3b §1 cites \`$sym\` ($desc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.3b §1 no longer cites \`$sym\` ($desc)"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
  if grep -rqwF -e "$sym" "$PLUGIN_DIR"; then
    echo "  PASS  T9.4b \`$sym\` resolves in plugins/uberdev/"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.4b \`$sym\` does NOT resolve in plugins/uberdev/ — §1 cites a dead symbol"
    echo "        retired by a migration? cite the SHIPPED replacement, not the corpse"
    FAIL=$((FAIL + 1))
  fi
done <<EOF_SECTION1_SYMBOLS
$SECTION1_SYMBOLS
EOF_SECTION1_SYMBOLS
# T9.4c is DERIVED, so a NEW dead reference reds without anyone remembering to
# extend a list: every identifier-shaped backticked token in §1 must resolve.
# `(memory: `key`)` spans are stripped first — those name Claude-memory files,
# not repo symbols, and the prose labels them as such. That exclusion is read
# off the prose marker, not hand-maintained per key.
S1_TOKENS="$(printf '%s\n' "$RFC12_S1" \
  | sed 's/memory: `[^`]*`//g' \
  | grep -oE '`[A-Za-z_][A-Za-z0-9_]{5,}`' | tr -d '`' | sort -u)"
S1_TOKEN_COUNT="$(printf '%s\n' "$S1_TOKENS" | grep -c '[A-Za-z]' || true)"
if [ "${S1_TOKEN_COUNT:-0}" -ge 5 ] 2>/dev/null; then
  echo "  PASS  T9.4c §1 yielded ${S1_TOKEN_COUNT} identifier references to resolve"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.4c §1 yielded only ${S1_TOKEN_COUNT} identifier references — slice/format broke"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi
S1_DEAD_TOKENS=""
while IFS= read -r s1_tok; do
  [ -n "$s1_tok" ] || continue
  grep -rqwF -e "$s1_tok" "$PLUGIN_DIR" || S1_DEAD_TOKENS="${S1_DEAD_TOKENS} ${s1_tok}"
done <<EOF_S1_TOKENS
$S1_TOKENS
EOF_S1_TOKENS
if [ -z "$S1_DEAD_TOKENS" ]; then
  echo "  PASS  T9.4c every identifier §1 cites resolves in plugins/uberdev/"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.4c §1 cites identifier(s) that resolve nowhere in plugins/uberdev/:${S1_DEAD_TOKENS}"
  echo "        retired by a migration? cite the SHIPPED replacement, not the corpse"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi

# The rotted claim of record: the trust-fields row must point at the READER.
# `uberdev_goal_audit` is the audit EMITTER the old line anchor landed on.
# Scoped to the table's DATA ROWS so the §3.3 anchoring-rule paragraph — which
# names the emitter deliberately, as the historical example — cannot mask a
# real re-rot, and matched on a symbol boundary so the backticked form the
# RFC's own convention produces (`uberdev_goal_audit` followed by a backtick,
# not a space) is caught too.
RFC12_TABLE_ROWS="$(grep '^|' <<<"$RFC12_TABLE" || true)"
RFC12_TRUST_ROW="$(awk -F'|' '$2 ~ /Trust fields/' <<<"$RFC12_TABLE_ROWS")"
EMITTER_RE='uberdev_goal_audit([^_[:alnum:]]|$)'
if [ -z "$RFC12_TRUST_ROW" ]; then
  echo "  FAIL  T9.5 no 'Trust fields' row found in the §3.3 contract table — renamed?"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
elif grep -qE -e "$EMITTER_RE" <<<"$RFC12_TABLE_ROWS"; then
  echo "  FAIL  T9.5 a contract-table row cites the audit emitter where the trust READER belongs"
  grep -nE -e "$EMITTER_RE" <<<"$RFC12_TABLE_ROWS" | cut -c1-120 | sed 's/^/        /'
  FAIL=$((FAIL + 1))
elif ! grep -qF -e 'uberdev_goal_read_trust_signal' <<<"$RFC12_TRUST_ROW"; then
  echo "  FAIL  T9.5 the 'Trust fields' row no longer names uberdev_goal_read_trust_signal"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T9.5 the Trust-fields row names the reader and no table row names the emitter"
  PASS=$((PASS + 1))
fi

# --- Per-corrected-claim greps (#349) --------------------------------------
# Marker retirement: only successful publication retires markers, so the
# Phase-3 seam must NOT carry an unconditional `rm marker` step beside it.
assert_absent_fixed "$WORKFLOW_RFC" "rm marker" \
  "T9.6 RFC 0012 drops the unconditional 'rm marker' that contradicted the publication rule"
assert_grep "$WORKFLOW_RFC" 'only successful verdict publication retires' \
  "T9.7 RFC 0012 states the publication-gated marker-retirement rule"
# Verdict-selection semantics match discover.sh: an OLDER unknown is ignored.
assert_grep "$WORKFLOW_RFC" 'at or after.*selected timestamp is indeterminate' \
  "T9.8 RFC 0012 qualifies indeterminacy as positional (at-or-after the selected timestamp)"

# Detached-session retirement (RFC 0015) annotations — annotate, never delete.
assert_grep "$WORKFLOW_RFC" 'SUPERSEDED IN PART — RFC 0015' \
  "T9.9 RFC 0012 annotates the detached-dispatch-dependent verdicts as superseded by RFC 0015"
assert_grep "$WORKFLOW_RFC" 'hybrid — shell preflight \+ solve-fleet workflow' \
  "T9.10 §3.0 verdict row for the /solve+/turbo launcher reads hybrid, not keep-shell"
assert_grep "$WORKFLOW_RFC" 'skills/goal-pipeline/workflow\.js' \
  "T9.11 §3.3 names the goal driver script"
# T9.11b — shipped-ness is DERIVED from disk, never asserted in prose. Naming a
# design target is fine; labelling it "shipped" while no such file exists is the
# unverifiable-claim class #349 exists to kill. Every `skills/<name>/workflow.js`
# the RFC names is resolved against the tree; a path that is absent may not
# appear on a line that calls it shipped.
RFC12_JS_PATHS="$(grep -oE 'skills/[a-z0-9_-]+/workflow\.js' "$WORKFLOW_RFC" | sort -u)"
RFC12_JS_COUNT="$(printf '%s\n' "$RFC12_JS_PATHS" | grep -c 'workflow\.js' || true)"
if [ "${RFC12_JS_COUNT:-0}" -ge 1 ] 2>/dev/null; then
  echo "  PASS  T9.11b RFC 0012 names ${RFC12_JS_COUNT} workflow.js driver path(s) to resolve"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.11b no skills/*/workflow.js path parsed from $WORKFLOW_RFC — renamed?"
  FAIL=$((FAIL + 1))
fi
JS_SHIPPED_LIE=""
while IFS= read -r js_path; do
  [ -n "$js_path" ] || continue
  [ -e "$PLUGIN_DIR/$js_path" ] && continue
  # No pipe into `grep -q`: its early exit SIGPIPEs the producer and pipefail
  # would then mask the match. Capture first, match against the capture.
  JS_CITING_LINES="$(grep -F -e "$js_path" "$WORKFLOW_RFC" || true)"
  if grep -qi -e 'shipped' <<<"$JS_CITING_LINES"; then
    JS_SHIPPED_LIE="${JS_SHIPPED_LIE} ${js_path}"
  fi
done <<EOF_RFC12_JS
$RFC12_JS_PATHS
EOF_RFC12_JS
if [ -z "$JS_SHIPPED_LIE" ]; then
  echo "  PASS  T9.11c every workflow.js RFC 0012 calls shipped exists in plugins/uberdev/"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.11c RFC 0012 claims shipped-ness for absent driver script(s):${JS_SHIPPED_LIE}"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi
assert_grep "$WORKFLOW_RFC" 'EXACTLY ONE nested workflow' \
  "T9.12 §3.3 pins one nested workflow() call per cycle"
assert_grep "$WORKFLOW_RFC" 'spends the single .workflow\(\). nesting level' \
  "T9.13 §3.3 records that /goal spends the single nesting level"
assert_grep "$WORKFLOW_RFC" '§3\.3 spends that level instead' \
  "T9.14 §3.6 retracts the sdd-waves nesting reservation it no longer holds"

# --- RFC 0005 corrected claims, cross-checked against the implementation ---
assert_grep "$GOAL_RFC" 'review_reserve_run_directory' \
  "T9.15 RFC 0005 D220b cites the reservation helper by symbol"
assert_grep "$GOAL_RFC" 'not.*\*\*Step 4\*\*|\*\*not\*\* "Step 4"' \
  "T9.16 RFC 0005 D220b retracts the wrong 'Step 4' pointer"
assert_grep "$GOAL_RFC" 'timestamp >= selected_timestamp' \
  "T9.17 RFC 0005 B13 states the positional indeterminacy predicate verbatim"
assert_grep "$GOAL_RFC" 'never absence\*\* — that half is unconditional' \
  "T9.18 RFC 0005 B13 scopes 'never absence' as the unconditional half"
assert_grep "$GOAL_RFC" 'POSIX; native Windows substitutes reparse-ancestor rejection' \
  "T9.19 RFC 0005 B14 annotates the non-POSIX O_NOFOLLOW substitute"
# Both RFC 0005 claims must match the code they describe, or the annotation is
# just a better-written lie.
DISCOVER_SH="$PLUGIN_DIR/skills/merge-pipeline/lib/discover.sh"
RUN_MANIFEST_PY="$PLUGIN_DIR/lib/run_manifest.py"
if [ -r "$DISCOVER_SH" ] && grep -qF -e 'timestamp >= selected_timestamp' "$DISCOVER_SH"; then
  echo "  PASS  T9.20 B13's predicate matches the canonical selector's code"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.20 B13 claims 'timestamp >= selected_timestamp' but discover.sh no longer does"
  echo "        file: $DISCOVER_SH"; FAIL=$((FAIL + 1))
fi
if [ -r "$RUN_MANIFEST_PY" ] && grep -qF -e '_reject_windows_reparse_ancestors' "$RUN_MANIFEST_PY"; then
  echo "  PASS  T9.21 B14's Windows substitute matches the runtime's reparse-ancestor rejection"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.21 B14 claims reparse-ancestor rejection but run_manifest.py no longer implements it"
  echo "        file: $RUN_MANIFEST_PY"; FAIL=$((FAIL + 1))
fi

# ── T10: no shipped doc may RECOMMEND a deleted dispatch backend (#381) ────────
# The class: `codex` and `claude-bg` were deleted from
# _UBERDEV_DISPATCH_BACKEND_ENUM, so `--backend=<either>` is an enum error at
# lib/solve-launcher.sh. Nine shipped surfaces still instructed the codex form
# after the deletion, TWO of them inside `## No-Workflow fallback` sections --
# the exact recipe a runtime WITHOUT the Workflow tool is routed to, where the
# model has no way to self-correct by re-running the primary path.
#
# A blanket "the string must not appear" grep is the wrong shape: every mention
# that survives is a deliberate TOMBSTONE, and tombstones are the thing that
# stops the surface silently coming back. So the rule is narrower and exactly
# matches the defect: every line naming `--backend=<deleted>` must ALSO carry a
# token that marks it dead on the same line. A line that names it with no such
# marker is an instruction, and instructions are what red here.
#
# CHANGELOG.md is exempt: it is an append-only historical record whose older
# entries legitimately describe the backends as live at the time of writing.
DEAD_BACKEND_MARKER='enum error|deleted|removed|retired|no longer|#381|~~|RETRACTED|was the'
# NEGATION BEATS THE TOMBSTONE, and must be tested FIRST.
#
# The marker above contains the bare word `deleted`, so a line reading
#   "`claude-bg` is deprecated, not deleted: --backend=claude-bg still works"
# MATCHED it and was skipped as a tombstone -- the very word that makes the
# claim false was the word certifying it as dead. That is not hypothetical:
# docs/rfc/0015 §1 shipped exactly that sentence on this branch and this guard
# waved it through.
#
# A line asserting the backend still works cannot be a tombstone no matter what
# else it contains, so this pattern is evaluated BEFORE the skip and a hit here
# is unconditional.
DEAD_BACKEND_NEGATION='not (deleted|removed|retired|gone)|still works|still passes|still (fully )?supported|remains? (fully )?supported|still (an? )?(available|selectable|valid)'
dead_backend_hits=""
while IFS= read -r shipped_doc; do
  case "$shipped_doc" in
    ./CHANGELOG.md|./.git/*|*/node_modules/*) continue ;;
  esac
  while IFS= read -r offending_line; do
    [ -n "$offending_line" ] || continue
    # Herestring, not a pipe: this file sets pipefail, and `grep -q` exits on
    # its first match, so a piped writer would take EPIPE (tests/epipe-guard.test.sh).
    # Three tiers, in this order and no other:
    #   1. struck through -> retracted BY CONSTRUCTION, excused whatever it says.
    #      A ~~...~~ line is the amend-in-place form this repo already uses; its
    #      text is quoted precisely to be contradicted.
    #   2. otherwise, a negation ("not deleted", "still works") -> ALWAYS a hit,
    #      even alongside a tombstone word, because that is the shape where the
    #      falsifying word is also the certifying word.
    #   3. otherwise, an ordinary tombstone word excuses the line.
    grep -qE -e '~~' <<<"$offending_line" && continue
    if ! grep -qE -e "$DEAD_BACKEND_NEGATION" <<<"$offending_line"; then
      grep -qE -e "$DEAD_BACKEND_MARKER" <<<"$offending_line" && continue
    fi
    dead_backend_hits="${dead_backend_hits}${shipped_doc}: ${offending_line}
"
  done <<EOF
$(grep -nE -e '--backend=(codex|claude-bg)' "$shipped_doc" 2>/dev/null || true)
EOF
done <<EOF
$(cd "$REPO_ROOT" && find . -type f \( -name '*.md' -o -name '*.json' \) \
    -not -path './.git/*' -not -path '*/node_modules/*' | sort)
EOF
if [ -z "$dead_backend_hits" ]; then
  echo "  PASS  T10.1 no shipped .md/.json instructs a deleted dispatch backend"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T10.1 a shipped doc names --backend=codex/claude-bg with nothing marking it dead"
  printf '%s' "$dead_backend_hits" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi
# Anti-vacuity: the scan must actually have looked at the surfaces that shipped
# the defect, or an empty/misrooted find would report a silent PASS.
for dead_backend_witness in \
  plugins/uberdev/skills/solve-fleet/SKILL.md \
  plugins/uberdev/skills/review-fleet/SKILL.md \
  plugins/uberdev/skills/goal-pipeline/SKILL.md \
  README.md; do
  if grep -qE -e '--backend=(codex|claude-bg)' "$REPO_ROOT/$dead_backend_witness"; then
    echo "  PASS  T10.2 $dead_backend_witness still carries a tombstone the scan reads"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T10.2 $dead_backend_witness has no --backend= mention at all — T10.1 may be vacuous"
    echo "        file: $REPO_ROOT/$dead_backend_witness"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== T11: the vendored confidence rubric attributes its upstream (#431) =="
# The 0-100 rubric is adapted from Anthropic's official `code-review` plugin
# (Apache 2.0). The bundled licence text already ships as
# licenses/pr-review-toolkit-Apache-2.0.txt; the rubric SSOT must NAME it, and
# the README's Bundled table must list the rubric like every other vendored
# surface. Attribution that lives only in a commit message is attribution
# nobody reading the plugin can find.
RUBRIC_SSOT="$REPO_ROOT/plugins/uberdev/shared/finding-confidence-rubric-v1.md"
if [ -r "$RUBRIC_SSOT" ]; then
  assert_grep "$RUBRIC_SSOT" 'licenses/pr-review-toolkit-Apache-2\.0\.txt' \
    "T11.1 rubric SSOT names its bundled Apache-2.0 licence file"
  assert_grep "$RUBRIC_SSOT" 'code-review' \
    "T11.2 rubric SSOT names the upstream plugin it was adapted from"
else
  echo "  FAIL  T11: rubric SSOT missing or unreadable: $RUBRIC_SSOT"
  FAIL=$((FAIL + 2))
fi
if [ -r "$REPO_ROOT/plugins/uberdev/licenses/pr-review-toolkit-Apache-2.0.txt" ]; then
  echo "  PASS  T11.3 the licence file the rubric points at exists on disk"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.3 the licence file the rubric points at is missing"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REPO_ROOT/README.md" 'finding-confidence-rubric-v1' \
  "T11.4 README Bundled table names the vendored rubric"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
