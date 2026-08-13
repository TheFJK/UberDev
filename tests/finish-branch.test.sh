#!/usr/bin/env bash
# tests/finish-branch.test.sh — regression lock for the lib/secret-scan.sh extraction.
#
# Tests assert that finish-branch/SKILL.md sources the extracted library and
# no longer inlines run_secret_scan_stdin. Behaviour-preserving — pre-refactor
# state has the function inline; post-refactor state has the `source` line.
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
LIB="$REPO_ROOT/plugins/uberdev/lib/secret-scan.sh"
ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
MERGE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
COMMAND_WORKSPACE="$REPO_ROOT/plugins/uberdev/lib/command-workspace.py"

PASS=0; FAIL=0
# shellcheck source=tests/_lib_assert_structural.sh
source "$THIS_DIR/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

echo "## finish-branch lib/secret-scan extraction regression suite"

# F1: SKILL.md MUST contain the source line for the extracted library.
if grep -qF 'source "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"' "$SKILL"; then
  echo "  PASS  F1 SKILL.md sources lib/secret-scan.sh"; PASS=$((PASS+1))
else
  echo "  FAIL  F1 SKILL.md must source lib/secret-scan.sh"; FAIL=$((FAIL+1))
fi

# F2: SKILL.md MUST NOT define run_secret_scan_stdin inline anymore — the
# extraction is behaviour-preserving via the sourced library. Detects the
# function-definition line specifically (not a call site).
if grep -qE '^[[:space:]]*run_secret_scan_stdin\(\)[[:space:]]*\{' "$SKILL"; then
  echo "  FAIL  F2 SKILL.md still defines run_secret_scan_stdin inline (should be sourced from lib)"; FAIL=$((FAIL+1))
else
  echo "  PASS  F2 SKILL.md no longer inlines run_secret_scan_stdin definition"; PASS=$((PASS+1))
fi

# F3: lib/secret-scan.sh exists and defines uberdev_run_secret_scan_stdin.
if [[ ! -f "$LIB" ]]; then
  echo "  FAIL  F3 lib/secret-scan.sh missing"; FAIL=$((FAIL+1))
elif grep -qE '^[[:space:]]*uberdev_run_secret_scan_stdin\(\)[[:space:]]*\{' "$LIB"; then
  echo "  PASS  F3 lib/secret-scan.sh defines uberdev_run_secret_scan_stdin"; PASS=$((PASS+1))
else
  echo "  FAIL  F3 lib/secret-scan.sh missing function uberdev_run_secret_scan_stdin"; FAIL=$((FAIL+1))
fi

# F4: Source-time idempotency guard mirrors lib/config-read.sh:26-29.
if grep -qE '_UBERDEV_SECRET_SCAN_LOADED:?-?0[^a-zA-Z]+=.+1' "$LIB" 2>/dev/null \
   || grep -qF '_UBERDEV_SECRET_SCAN_LOADED=1' "$LIB" 2>/dev/null; then
  echo "  PASS  F4 lib/secret-scan.sh has _UBERDEV_SECRET_SCAN_LOADED guard"; PASS=$((PASS+1))
else
  echo "  FAIL  F4 lib/secret-scan.sh missing source-time idempotency guard"; FAIL=$((FAIL+1))
fi

# F5: The library MUST retain both the gitleaks primary and the regex fallback
# (fail-CLOSED on either) — behaviour parity with the pre-refactor function.
if grep -qF 'command -v gitleaks' "$LIB" && grep -qE 'AKIA|aws_access_key|BEGIN .* PRIVATE KEY' "$LIB"; then
  echo "  PASS  F5 lib/secret-scan.sh retains gitleaks primary + regex fallback"; PASS=$((PASS+1))
else
  echo "  FAIL  F5 lib/secret-scan.sh missing gitleaks primary or regex fallback patterns"; FAIL=$((FAIL+1))
fi

# F6: Runtime integration — pipe a known AKIA-bearing input through the lib
# using the SKILL.md caller idiom (`SCAN_DIAG=$(... 2>&1 >/dev/null); SCAN_RC=$?`)
# and assert the abort decision triggers. This is the regression that the
# structural-only F1-F5 assertions missed before; F6 plugs that gap.
#
# The canonical AWS example key is ASSEMBLED AT RUNTIME ("AKIA" + the rest) so
# the flaggable token never appears contiguously in these source bytes. That is
# not cosmetic: finish-branch's own pre-push scan runs over the to-be-pushed
# DIFF, so a contiguous literal on a changed (or merely adjacent context) line
# hard-aborts the push of this very file. Same rule as secret-scan.test.sh S2.
F6_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
if ( CLAUDE_PLUGIN_ROOT="$F6_PLUGIN_ROOT" \
     bash -c '
       set -u
       source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
       example_key="AKIA""IOSFODNN7EXAMPLE"
       # Test 1: clean input -> rc=0, no abort
       SCAN_DIAG=$(printf "%s" "clean code line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -eq 0 ] || exit 1
       # Test 2: AKIA leak -> rc!=0, abort should trigger
       SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -ne 0 ] || exit 2
       # Test 3: SKILL.md caller idiom verbatim — assert abort decision triggers on leak
       SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       if [ "$SCAN_RC" -eq 0 ]; then exit 3; fi
       # Test 4: diagnostic captures the matched line (anchors the abort message)
       [ -n "$SCAN_DIAG" ] || exit 4
       grep -q AKIA <<<"$SCAN_DIAG" || exit 5
       exit 0
     ' ); then
  echo "  PASS  F6 runtime: lib aborts on AKIA leak via SKILL.md caller idiom"; PASS=$((PASS+1))
else
  rc=$?
  echo "  FAIL  F6 runtime integration test failed (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# F7-F10 — run-id contract convergence (#345).
#
# finish-branch used to declare its OWN widened run-id dialect
# (^[0-9]{8}-[0-9]{6}-[0-9a-z]{4,40}$) so it would accept the `nohead` sentinel
# that orchestrator Phase 0 minted. Every other consumer validates the canonical
# RUN_ID_REGEX (^[0-9]{8}-[0-9]{6}-[a-f0-9]+$), so a `nohead` run resolved here
# and was rejected as invalid_run_id there. Nothing locked either literal, which
# is exactly how the two drifted apart. These four assertions are that lock.
# ---------------------------------------------------------------------------

# Canonical form, declared once here and cross-checked against every producer
# and consumer below.
CANONICAL_RUN_ID_REGEX='^[0-9]{8}-[0-9]{6}-[a-f0-9]+$'

# Extract, never re-type: the assertions must fail when the FILES drift, not
# when this test's copy of a literal drifts.
FB_RUN_ID_FORMAT="$(sed -nE "s/^RUN_ID_FORMAT='(.*)'\$/\1/p" "$SKILL" | head -1)"
ORCH_SENTINEL="$(sed -nE 's/.*git rev-parse --short HEAD 2>\/dev\/null \|\| echo ([A-Za-z0-9]+).*/\1/p' "$ORCHESTRATOR" | head -1)"

# F7: finish-branch declares the canonical regex — no local dialect.
if [[ "$FB_RUN_ID_FORMAT" == "$CANONICAL_RUN_ID_REGEX" ]]; then
  echo "  PASS  F7 finish-branch RUN_ID_FORMAT is the canonical RUN_ID_REGEX"; PASS=$((PASS+1))
else
  echo "  FAIL  F7 finish-branch RUN_ID_FORMAT drifted: got '$FB_RUN_ID_FORMAT' want '$CANONICAL_RUN_ID_REGEX'"; FAIL=$((FAIL+1))
fi

# F8: the cited source of truth still declares that same regex. If merge-pipeline
# renames or re-shapes RUN_ID_REGEX, this reds instead of letting finish-branch's
# comment silently become a lie.
if grep -qF "\`RUN_ID_REGEX\` | \`$CANONICAL_RUN_ID_REGEX\`" "$MERGE_PIPELINE" \
   && grep -qF 'RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")' "$COMMAND_WORKSPACE"; then
  echo "  PASS  F8 merge-pipeline RUN_ID_REGEX + command-workspace.py agree with F7"; PASS=$((PASS+1))
else
  echo "  FAIL  F8 canonical RUN_ID_REGEX missing from merge-pipeline/SKILL.md or lib/command-workspace.py"; FAIL=$((FAIL+1))
fi

# F9: the orchestrator Phase 0 mint must PRODUCE a run-id that F7's regex
# accepts. This is the root-cause assertion — it runs the actual sentinel token
# through the actual extracted regex, so any future sentinel that leaves the
# hex alphabet (as `nohead` did) reds here rather than in production.
F9_FAILURES=''
[[ -n "$ORCH_SENTINEL" ]] || F9_FAILURES="$F9_FAILURES sentinel-not-extractable"
[[ -n "$FB_RUN_ID_FORMAT" ]] || F9_FAILURES="$F9_FAILURES format-not-extractable"
if [[ -n "$ORCH_SENTINEL" && -n "$FB_RUN_ID_FORMAT" ]]; then
  [[ "20260101-120000-$ORCH_SENTINEL" =~ $FB_RUN_ID_FORMAT ]] \
    || F9_FAILURES="$F9_FAILURES sentinel-rejected:$ORCH_SENTINEL"
  # A real short SHA must still resolve, and the retired sentinel must not.
  [[ "20260101-120000-a1b2c3d" =~ $FB_RUN_ID_FORMAT ]] \
    || F9_FAILURES="$F9_FAILURES short-sha-rejected"
  [[ "20260101-120000-nohead" =~ $FB_RUN_ID_FORMAT ]] \
    && F9_FAILURES="$F9_FAILURES nohead-still-accepted"
fi
grep -qF '|| echo nohead' "$ORCHESTRATOR" && F9_FAILURES="$F9_FAILURES nohead-sentinel-still-minted"
if [[ -z "$F9_FAILURES" ]]; then
  echo "  PASS  F9 orchestrator sentinel '$ORCH_SENTINEL' satisfies finish-branch RUN_ID_FORMAT"; PASS=$((PASS+1))
else
  echo "  FAIL  F9 run-id producer/consumer disagree:$F9_FAILURES"; FAIL=$((FAIL+1))
fi

# F10: the PR TITLE is secret-scanned before it ships (#303). finish-branch used
# to enumerate exactly two scan targets (the push diff and the composed body)
# while `gh pr create --title` published a third, unscanned text.
F10_FAILURES=''
grep -qF 'abort_if_secret "composed PR title"' "$SKILL" || F10_FAILURES="$F10_FAILURES no-title-abort"
grep -qF 'PR_TITLE_VAR" | uberdev_run_secret_scan_stdin' "$SKILL" || F10_FAILURES="$F10_FAILURES title-not-piped-to-scanner"
# Order matters: the scan must precede the publish, not follow it.
L_TITLE_SCAN="$(grep -nF 'abort_if_secret "composed PR title"' "$SKILL" | head -1 | cut -d: -f1)"
L_PR_CREATE="$(grep -nF 'PR_URL=$(gh pr create --title' "$SKILL" | head -1 | cut -d: -f1)"
if [[ -n "$L_TITLE_SCAN" && -n "$L_PR_CREATE" && "$L_TITLE_SCAN" -lt "$L_PR_CREATE" ]]; then :; else
  F10_FAILURES="$F10_FAILURES scan-not-before-publish($L_TITLE_SCAN/$L_PR_CREATE)"
fi
# The abort message names the escape hatch by expanding the library's marker
# variable — never by re-typing the literal.
grep -qF 'UBERDEV_SECRET_SCAN_ALLOW_MARKER' "$SKILL" || F10_FAILURES="$F10_FAILURES abort-message-omits-allow-marker"
if [[ -z "$F10_FAILURES" ]]; then
  echo "  PASS  F10 PR title is scanned before gh pr create and the abort names the allowlist"; PASS=$((PASS+1))
else
  echo "  FAIL  F10 PR-title scan contract broken:$F10_FAILURES"; FAIL=$((FAIL+1))
fi

# F11: the abort message must respect the library's TRI-STATE return code.
# rc 1 is a detected secret; rc>=2 means the scanner could not run at all
# (crashed gitleaks, unreadable ruleset, broken fallback grep). Reporting the
# latter as "secret found" and offering the allowlist marker talks the operator
# into stripping the line from the regex fallback too — removing the second
# layer while the first stays broken, which is the exact fail-OPEN the tri-state
# handling exists to prevent (#189 principle, applied at the caller).
#
# The function is EXTRACTED from SKILL.md and executed, so this asserts the
# shipped behaviour rather than the presence of a string.
F11_FN="$(sed -n '/^abort_if_secret() {$/,/^}$/p' "$SKILL")"
F11_FAILURES=''
if [[ -z "$F11_FN" ]]; then
  F11_FAILURES="$F11_FAILURES abort_if_secret-not-extractable"
else
  F11_DRIVER="$(mktemp)" && F11_T1="$(mktemp)" && F11_T2="$(mktemp)" || {
    echo "FATAL: mktemp failed" >&2; exit 2
  }
  {
    printf '%s\n' 'UBERDEV_SECRET_SCAN_ALLOW_MARKER="gitleaks:allow"'
    printf '%s\n' 'TITLE_FILE="$1"; PR_BODY_FILE="$2"'
    printf '%s\n' "$F11_FN"
    printf '%s\n' 'abort_if_secret "unit-under-test" "raw scanner diagnostic" "$3"'
    printf '%s\n' 'exit 0'
  } > "$F11_DRIVER"
  F11_MATCH="$(bash "$F11_DRIVER" "$F11_T1" "$F11_T2" 1 2>&1)"; F11_MATCH_RC=$?
  F11_CRASH="$(bash "$F11_DRIVER" "$F11_T1" "$F11_T2" 2 2>&1)"; F11_CRASH_RC=$?
  F11_CLEAN="$(bash "$F11_DRIVER" "$F11_T1" "$F11_T2" 0 2>&1)"; F11_CLEAN_RC=$?
  rm -f "$F11_DRIVER" "$F11_T1" "$F11_T2"
  # rc 0 -> no abort at all.
  [[ "$F11_CLEAN_RC" -eq 0 && -z "$F11_CLEAN" ]] || F11_FAILURES="$F11_FAILURES clean-rc-aborts"
  # rc 1 -> a real match: name the escape hatch, do not cry scanner failure.
  [[ "$F11_MATCH_RC" -ne 0 ]] || F11_FAILURES="$F11_FAILURES match-does-not-abort"
  grep -qF 'secret found' <<<"$F11_MATCH" || F11_FAILURES="$F11_FAILURES match-not-named"
  grep -qF 'gitleaks:allow' <<<"$F11_MATCH" || F11_FAILURES="$F11_FAILURES match-omits-marker"
  grep -qF 'BROKEN SCANNER' <<<"$F11_MATCH" && F11_FAILURES="$F11_FAILURES match-claims-broken-scanner"
  # rc>=2 -> broken scanner: opposite advice, and never "secret found".
  [[ "$F11_CRASH_RC" -ne 0 ]] || F11_FAILURES="$F11_FAILURES crash-does-not-abort"
  grep -qF 'BROKEN SCANNER' <<<"$F11_CRASH" || F11_FAILURES="$F11_FAILURES crash-not-named"
  grep -qF 'secret found' <<<"$F11_CRASH" && F11_FAILURES="$F11_FAILURES crash-claims-secret-found"
  grep -qF 'False positive' <<<"$F11_CRASH" && F11_FAILURES="$F11_FAILURES crash-offers-allowlist"
fi
if [[ -z "$F11_FAILURES" ]]; then
  echo "  PASS  F11 abort_if_secret separates a detected secret from a broken scanner"; PASS=$((PASS+1))
else
  echo "  FAIL  F11 abort_if_secret tri-state advice broken:$F11_FAILURES"; FAIL=$((FAIL+1))
fi

# F12: the PR base is resolved ONCE (#439), explicit-first, and — critically —
# the tier-3 fallback chain is REACHABLE. The shipped shape used to be
#   BASE_REF=$(git symbolic-ref … | sed … || git rev-parse --verify origin/main …)
# where `||` binds to the whole PIPELINE and `sed` exits 0 on empty input: when
# symbolic-ref failed the pipeline still returned 0, BASE_REF came back EMPTY,
# and every fallback arm was unreachable dead code. The scan then degraded to
# `git diff --staged`, which on a fully-committed branch scans nothing — a
# fail-OPEN security control.
#
# The block is EXTRACTED from SKILL.md and EXECUTED against a real git fixture,
# so this asserts shipped behaviour rather than the presence of a string.
#
# Mutation guard (revert the fix in your worktree, re-run):
#   - restore the `| sed … || git rev-parse …` chain  => F12b RED (empty base).
#   - gate `--base` on nothing (always emit)          => F12a RED (flag leaks
#                                                        into the default path).
#   - build the flag as a scalar `PR_BASE_ARG="--base $PR_BASE"` => F12c RED
#     under zsh (see finish-branch-zsh.test.sh FBZ-3 for the argv proof).
F12_FAILURES=''
F12_BLOCK="$(sed -n '/^# --- BEGIN pr-base resolution (#439) ---$/,/^# --- END pr-base resolution (#439) ---$/p' "$SKILL")"
if [[ -z "$F12_BLOCK" ]]; then
  F12_FAILURES="$F12_FAILURES base-block-not-extractable"
else
  F12_ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  F12_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
  (
    cd "$F12_ROOT" || exit 2
    git init -q . >/dev/null 2>&1 || exit 2
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git config commit.gpgsign false
    # Three commits, and the repo default deliberately AHEAD of the root: that is
    # what separates "scan from the origin default branch" (RANGE=c.txt) from
    # "scan the whole branch history" (RANGE=b.txt,c.txt). In a 1-commit fixture
    # those two refs coincide and the difference is invisible.
    printf 'one\n' > a.txt && git add a.txt && git commit -qm one >/dev/null 2>&1 || exit 2
    git update-ref refs/remotes/origin/feat/parent HEAD || exit 2
    # The repo default is deliberately AHEAD of the root commit.
    printf 'two\n' > b.txt && git add b.txt && git commit -qm two >/dev/null 2>&1 || exit 2
    git update-ref refs/remotes/origin/main HEAD || exit 2
    printf 'three\n' > c.txt && git add c.txt && git commit -qm three >/dev/null 2>&1 || exit 2
  ) || F12_FAILURES="$F12_FAILURES fixture-setup-failed"

  F12_DRIVER="$F12_ROOT/f12-driver.sh"
  {
    printf '%s\n' "$F12_BLOCK"
    printf '%s\n' 'printf "PR_BASE=%s\n" "$PR_BASE"'
    printf '%s\n' 'printf "PR_BASE_EXPLICIT=%s\n" "$PR_BASE_EXPLICIT"'
    printf '%s\n' 'printf "BASE_REF=%s\n" "$BASE_REF"'
    # Index-free rendering: zsh arrays are 1-based, so ${a[0]} is not portable.
    # ARGN is the load-bearing empty-case assertion — `printf "%s|"` with zero
    # arguments still applies the format once and prints a bare "|", so the
    # joined form cannot distinguish "no args" from "one empty arg".
    printf '%s\n' 'printf "ARGN=%s\n" "${#PR_BASE_ARGS[@]}"'
    printf '%s\n' 'printf "ARGS=[%s]\n" "$(printf "%s|" ${PR_BASE_ARGS[@]+"${PR_BASE_ARGS[@]}"})"'
    # The range the pre-push secret scan will actually read. Asserting the REF
    # NAME alone is not enough: it cannot tell a narrowed range from a widened
    # one when two refs happen to point at the same commit.
    printf '%s\n' 'printf "RANGE=%s\n" "$(git diff --name-only "$BASE_REF..HEAD" | tr "\n" ",")"'
  } > "$F12_DRIVER"

  f12_run() {  # f12_run <extra-env-assignment-or-empty>
    ( cd "$F12_ROOT" \
      && env -u UBERDEV_PR_BASE_BRANCH -u UBERDEV_CONFIG_FILE \
             CLAUDE_PLUGIN_ROOT="$F12_PLUGIN_ROOT" ${1:+"$1"} \
             bash "$F12_DRIVER" 2>/dev/null )
  }
  f12_run_err() {  # f12_run_err <extra-env-assignment-or-empty>  -> stderr only
    ( cd "$F12_ROOT" \
      && env -u UBERDEV_PR_BASE_BRANCH -u UBERDEV_CONFIG_FILE \
             CLAUDE_PLUGIN_ROOT="$F12_PLUGIN_ROOT" ${1:+"$1"} \
             bash "$F12_DRIVER" 2>&1 >/dev/null )
  }
  f12_expect() {  # f12_expect <output> <needle> <tag>
    grep -qF "$2" <<<"$1" || F12_FAILURES="$F12_FAILURES $3"
  }
  f12_refute() {  # f12_refute <output> <needle> <tag>
    grep -qF "$2" <<<"$1" && F12_FAILURES="$F12_FAILURES $3"
    return 0
  }

  # F12a — legacy path: origin/HEAD present, no override. Base resolves to the
  # repo default AND NO --base flag is emitted (byte-identical to today).
  ( cd "$F12_ROOT" && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main )
  F12_A="$(f12_run "")"
  f12_expect "$F12_A" 'PR_BASE=main'         a-base
  f12_expect "$F12_A" 'PR_BASE_EXPLICIT=0'   a-explicit
  f12_expect "$F12_A" 'BASE_REF=origin/main' a-ref
  f12_expect "$F12_A" 'ARGN=0'               a-noflag

  # F12b — THE LATENT BUG: origin/HEAD missing. The fallback must FIRE.
  ( cd "$F12_ROOT" && git symbolic-ref -d refs/remotes/origin/HEAD )
  F12_B="$(f12_run "")"
  f12_expect "$F12_B" 'PR_BASE=main'         b-fallback-unreachable
  f12_expect "$F12_B" 'BASE_REF=origin/main' b-scan-range-empty
  f12_expect "$F12_B" 'ARGN=0'               b-noflag

  # F12c — tier 1: explicit env override wins and reaches BOTH consumers.
  F12_C="$(f12_run "UBERDEV_PR_BASE_BRANCH=feat/parent")"
  f12_expect "$F12_C" 'PR_BASE=feat/parent'         c-base
  f12_expect "$F12_C" 'PR_BASE_EXPLICIT=1'          c-explicit
  f12_expect "$F12_C" 'BASE_REF=origin/feat/parent' c-scan-range
  f12_expect "$F12_C" 'ARGN=2'                      c-argc
  f12_expect "$F12_C" 'ARGS=[--base|feat/parent|]'  c-flag

  # F12e — a CONFIGURED base that resolves to NO ref here (the normal state of a
  # fresh stacked worktree that never fetched the parent branch, and also what a
  # typo produces). The scan range must degrade to the origin default branch, NOT
  # to the branch root commit: the root commit is strictly wider than pre-#439
  # behaviour and drags the parent PR's secret-shaped fixtures back into range,
  # re-creating the hard-abort-with-no-override this change exists to prevent.
  # And it must not do it silently. `--base` is still emitted — GitHub has the
  # branch even when this clone does not, so dropping the flag would silently
  # retarget the default branch.
  #
  # Mutation guard: collapse the two arms back into one bare
  #   if [ -z "$BASE_REF" ]; then BASE_REF="$(git rev-list --max-parents=0 …)"; fi
  # => e-widened-to-root AND e-silent both RED.
  F12_ROOT_COMMIT="$( cd "$F12_ROOT" && git rev-list --max-parents=0 --max-count=1 HEAD )"
  F12_E="$(f12_run "UBERDEV_PR_BASE_BRANCH=feat/never-fetched")"
  f12_expect "$F12_E" 'PR_BASE=feat/never-fetched'  e-base
  f12_expect "$F12_E" 'BASE_REF=origin/main'        e-degrades-to-default
  f12_refute "$F12_E" "BASE_REF=$F12_ROOT_COMMIT"   e-widened-to-root
  # The semantic form of the same claim, and the load-bearing one: the ref NAME
  # alone cannot separate a narrowed range from a widened one when two refs point
  # at the same commit. origin/main is deliberately AHEAD of the root here, so
  # the root-commit fallback yields RANGE=b.txt,c.txt and this assertion goes RED.
  f12_expect "$F12_E" 'RANGE=c.txt,'                e-range-not-narrowed
  f12_expect "$F12_E" 'ARGN=2'                      e-base-still-passed
  F12_E_ERR="$(f12_run_err "UBERDEV_PR_BASE_BRANCH=feat/never-fetched")"
  f12_expect "$F12_E_ERR" 'feat/never-fetched'      e-silent
  f12_expect "$F12_E_ERR" 'WARNING'                 e-not-a-warning

  # F12d — tier 2: the per-project config key, read through the shared helper.
  mkdir -p "$F12_ROOT/.claude"
  printf -- '---\npr_base_branch: feat/parent\n---\n' > "$F12_ROOT/.claude/uberdev.local.md"
  F12_D="$(f12_run "")"
  f12_expect "$F12_D" 'PR_BASE=feat/parent'         d-base
  f12_expect "$F12_D" 'PR_BASE_EXPLICIT=1'          d-explicit
  f12_expect "$F12_D" 'ARGN=2'                      d-argc
  f12_expect "$F12_D" 'ARGS=[--base|feat/parent|]'  d-flag
  rm -rf "$F12_ROOT"
fi
if [[ -z "$F12_FAILURES" ]]; then
  echo "  PASS  F12 PR base resolves explicit-first, the tier-3 fallback is reachable, and --base is emitted only when configured"; PASS=$((PASS+1))
else
  echo "  FAIL  F12 base resolution broken:$F12_FAILURES"; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# F13 — the Step 5 worktree-teardown block (#460), EXTRACTED from SKILL.md and
# EXECUTED against a recording `git` shim.
#
# Four defects lived in the prose this block replaces, all four reproduced by an
# executed probe rather than inferred from a reading:
#
#   1. `git checkout <base>` was never rc-checked. From a linked worktree it
#      exits 128 ("fatal: 'main' is already used by worktree at ..."), HEAD stays
#      on the feature branch, and the next `git merge <feature>` merges the
#      branch into itself: rc=0, "Already up to date." Option 1 reported a merge
#      that never happened — worse than the silent no-op the issue hypothesised.
#   2. The worktree probe `git worktree list | grep $(git branch --show-current)`
#      matched the main checkout's own row in an ordinary clone (rc=0), so the
#      flow went on to `git worktree remove` and got "is a main working tree".
#   3. On a detached HEAD `git branch --show-current` prints nothing, so the same
#      probe degraded to `grep ""` and matched every row.
#   4. The branch delete ran BEFORE the worktree removal, and git refuses to
#      delete a branch a live worktree still has checked out.
#
# WHY A SHIM AND NOT A REAL REPO: this file runs on ubuntu AND windows CI, and
# the real-worktree fixtures live in the ubuntu-only finish-branch-zsh.test.sh
# (FBT-*). The shim tier asserts CONTROL FLOW — which git verbs ran, in which
# order, and which ones did NOT run — on every platform. The two tiers assert
# different things on purpose; neither replaces the other.
#
# F13a is the vacuity backstop for the whole group: without it, every other case
# would pass on a block that never executed a single git call.
# ---------------------------------------------------------------------------
F13_FAILURES=''
F13_BLOCK="$(sed -n '/^# --- BEGIN worktree teardown (#460) ---$/,/^# --- END worktree teardown (#460) ---$/p' "$SKILL")"
if [[ -z "$F13_BLOCK" ]]; then
  F13_FAILURES="$F13_FAILURES worktree-teardown-block-not-extractable"
else
  # Physical (symlink-resolved) fixture root. git itself returns physical paths
  # from --absolute-git-dir / --show-toplevel / worktree list, so a fixture that
  # handed the block a /var/... path while `pwd -P` produced /private/var/...
  # would make the linked-worktree comparison pass for the wrong reason on macOS.
  F13_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  F13_DIR="$(cd "$F13_DIR" && pwd -P)" || { echo "FATAL: cannot resolve fixture dir" >&2; exit 2; }
  F13_ROOT="$F13_DIR/root"
  mkdir -p "$F13_ROOT/.git" "$F13_DIR/home" || { echo "FATAL: fixture mkdir failed" >&2; exit 2; }
  F13_LOG="$F13_DIR/git-calls.log"
  F13_ERR="$F13_DIR/stderr.txt"
  F13_DRIVER="$F13_DIR/driver.sh"
  F13_BLOCK_FILE="$F13_DIR/block.sh"
  printf '%s\n' "$F13_BLOCK" > "$F13_BLOCK_FILE"

  # Default porcelain: main checkout on the base branch, one linked worktree on
  # the feature branch. `git worktree list --porcelain` always emits the MAIN
  # worktree first (verified), which is how the block resolves the main root.
  F13_PORCELAIN="$F13_DIR/porcelain.txt"
  {
    printf 'worktree %s\n' "$F13_ROOT"
    printf 'HEAD 1111111111111111111111111111111111111111\n'
    printf 'branch refs/heads/main\n'
    printf '\n'
    printf 'worktree %s\n' "$F13_ROOT/.worktrees/feat-x"
    printf 'HEAD 2222222222222222222222222222222222222222\n'
    printf 'branch refs/heads/feat/x\n'
    printf '\n'
  } > "$F13_PORCELAIN"

  # Base-busy porcelain: the base branch is checked out by a DIFFERENT worktree.
  # This is the exact state that made the shipped `git checkout <base>` exit 128.
  F13_PORCELAIN_BUSY="$F13_DIR/porcelain-busy.txt"
  {
    printf 'worktree %s\n' "$F13_ROOT"
    printf 'HEAD 1111111111111111111111111111111111111111\n'
    printf 'branch refs/heads/idle\n'
    printf '\n'
    printf 'worktree %s\n' "$F13_ROOT/.worktrees/other"
    printf 'HEAD 3333333333333333333333333333333333333333\n'
    printf 'branch refs/heads/main\n'
    printf '\n'
    printf 'worktree %s\n' "$F13_ROOT/.worktrees/feat-x"
    printf 'HEAD 2222222222222222222222222222222222222222\n'
    printf 'branch refs/heads/feat/x\n'
    printf '\n'
  } > "$F13_PORCELAIN_BUSY"

  # The recording shim. `git` is a SHELL FUNCTION, which is why the block must
  # call git unqualified — a `command git` anywhere in it vacates this entire
  # tier, and F13a is the assertion that notices.
  F13_SHIM="$F13_DIR/shim.sh"
  cat > "$F13_SHIM" <<'F13_SHIM_EOF'
git() {
  printf '%s\n' "$*" >> "$FB_LOG"
  case "$*" in
    "branch --show-current")        printf '%s\n' "$FB_SHIM_CURRENT" ;;
    "rev-parse --absolute-git-dir") printf '%s\n' "$FB_SHIM_GITDIR" ;;
    "rev-parse --git-common-dir")   printf '%s\n' "$FB_SHIM_COMMON" ;;
    "rev-parse --show-toplevel")    printf '%s\n' "$FB_SHIM_TOPLEVEL" ;;
    "worktree list --porcelain")    cat "$FB_SHIM_PORCELAIN" ;;
    rev-parse*)                     return "$FB_SHIM_RC_UPSTREAM" ;;
    checkout*)                      return "$FB_SHIM_RC_CHECKOUT" ;;
    pull*)                          return "$FB_SHIM_RC_PULL" ;;
    merge*)                         return "$FB_SHIM_RC_MERGE" ;;
    "worktree remove"*)             return "$FB_SHIM_RC_REMOVE" ;;
    "worktree prune")               return 0 ;;
    branch\ -*)                     return "$FB_SHIM_RC_BRANCHDEL" ;;
    *)                              return 0 ;;
  esac
  return 0
}
fbtest() {
  printf 'TESTCOMMAND\n' >> "$FB_LOG"
  return "$FB_SHIM_RC_TEST"
}
F13_SHIM_EOF
  cat "$F13_SHIM" "$F13_BLOCK_FILE" > "$F13_DRIVER"

  F13_ENV_DEFAULTS=(
    "FB_MODE=merge"
    "FB_BASE_BRANCH=main"
    "FB_TEST_COMMAND=fbtest"
    "FB_LOG=$F13_LOG"
    "FB_SHIM_CURRENT=feat/x"
    "FB_SHIM_GITDIR=$F13_ROOT/.git/worktrees/feat-x"
    "FB_SHIM_COMMON=$F13_ROOT/.git"
    "FB_SHIM_TOPLEVEL=$F13_ROOT/.worktrees/feat-x"
    "FB_SHIM_PORCELAIN=$F13_PORCELAIN"
    "FB_SHIM_RC_UPSTREAM=0"
    "FB_SHIM_RC_CHECKOUT=0"
    "FB_SHIM_RC_PULL=0"
    "FB_SHIM_RC_MERGE=0"
    "FB_SHIM_RC_REMOVE=0"
    "FB_SHIM_RC_BRANCHDEL=0"
    "FB_SHIM_RC_TEST=0"
    "HOME=$F13_DIR/home"
  )

  F13_OUT=''; F13_RC=0; F13_CALLS=''; F13_STDERR=''
  f13_run() {  # f13_run <extra env assignments...>  -> sets F13_OUT/RC/CALLS/STDERR
    : > "$F13_LOG"
    : > "$F13_ERR"
    F13_OUT="$( cd "$F13_ROOT" && env "${F13_ENV_DEFAULTS[@]}" "$@" bash "$F13_DRIVER" 2>"$F13_ERR" )"
    F13_RC=$?
    F13_CALLS="$(cat "$F13_LOG")"
    F13_STDERR="$(cat "$F13_ERR")"
  }
  f13_saw()   { grep -qE "$1" <<<"$F13_CALLS"; }
  f13_index() { grep -nE "$1" <<<"$F13_CALLS" | head -1 | cut -d: -f1; }
  f13_bad()   { F13_FAILURES="$F13_FAILURES $1"; }

  # F13a — vacuity backstop. Mutation guard: change `git` to `command git`
  # anywhere in the block and the shim stops recording => this goes RED, which
  # is the signal that F13b..F13j have stopped asserting anything.
  f13_run
  [[ -n "$F13_CALLS" ]] || f13_bad a-shim-recorded-nothing
  f13_saw '^rev-parse ' || f13_bad a-no-rev-parse-call
  [[ "$F13_RC" -eq 0 ]] || f13_bad "a-happy-path-rc=$F13_RC"

  # F13b — an unchecked checkout is the root cause of the reported-but-absent
  # merge. Mutation guard: drop the rc check after `git checkout` => `merge`
  # appears in the log => RED.
  f13_run "FB_SHIM_RC_CHECKOUT=1"
  [[ "$F13_RC" -ne 0 ]]          || f13_bad b-checkout-failure-not-fatal
  f13_saw '^checkout '           || f13_bad b-checkout-never-attempted
  f13_saw '^merge '              && f13_bad b-merged-after-failed-checkout
  f13_saw '^branch -[dD] '       && f13_bad b-deleted-branch-after-failed-checkout
  f13_saw '^worktree remove'     && f13_bad b-removed-worktree-after-failed-checkout

  # F13c — refuse BEFORE any mutation when the base branch is held elsewhere.
  # Mutation guard: delete the availability probe => `checkout` appears => RED.
  f13_run "FB_SHIM_PORCELAIN=$F13_PORCELAIN_BUSY"
  [[ "$F13_RC" -ne 0 ]] || f13_bad c-busy-base-not-refused
  f13_saw '^checkout '  && f13_bad c-checkout-attempted-on-busy-base
  f13_saw '^merge '     && f13_bad c-merged-on-busy-base
  grep -qF "$F13_ROOT/.worktrees/other" <<<"$F13_STDERR" || f13_bad c-holder-path-not-named

  # F13d — a detached HEAD must refuse, not degrade. Mutation guard: accept an
  # empty current branch => RED.
  f13_run "FB_SHIM_CURRENT="
  [[ "$F13_RC" -ne 0 ]]      || f13_bad d-detached-head-not-refused
  f13_saw '^merge '          && f13_bad d-merged-on-detached-head
  f13_saw '^branch -[dD] '   && f13_bad d-deleted-branch-on-detached-head
  f13_saw '^worktree remove' && f13_bad d-removed-worktree-on-detached-head

  # F13e — removal before delete. Mutation guard: swap the two steps => RED.
  f13_run
  F13_I_REMOVE="$(f13_index '^worktree remove')"
  F13_I_DELETE="$(f13_index '^branch -d')"
  [[ -n "$F13_I_REMOVE" ]] || f13_bad e-worktree-never-removed
  [[ -n "$F13_I_DELETE" ]] || f13_bad e-branch-never-deleted
  if [[ -n "$F13_I_REMOVE" && -n "$F13_I_DELETE" && "$F13_I_REMOVE" -lt "$F13_I_DELETE" ]]; then :; else
    f13_bad "e-remove-not-before-delete($F13_I_REMOVE/$F13_I_DELETE)"
  fi

  # F13f — the test gate. A failing test command must stop the branch delete,
  # and an EMPTY test command must refuse outright rather than degrade to "skip"
  # (a defaulted value is the silent-no-op class this whole change removes).
  # Mutation guard: default FB_TEST_COMMAND to `true` => the empty case goes RED.
  f13_run "FB_SHIM_RC_TEST=1"
  [[ "$F13_RC" -ne 0 ]] || f13_bad f-failing-tests-not-fatal
  f13_saw 'TESTCOMMAND'  || f13_bad f-test-command-never-ran
  f13_saw '^branch -d'   && f13_bad f-branch-deleted-after-failing-tests
  f13_run "FB_TEST_COMMAND="
  [[ "$F13_RC" -ne 0 ]] || f13_bad f-empty-test-command-not-refused
  f13_saw '^checkout '   && f13_bad f-empty-test-command-mutated-anyway

  # F13g — the provenance table. The block is SOURCED with FB_MODE unset so the
  # top-level entry point refuses immediately (no git call, no mutation); the
  # function definitions survive that refusal, which is what makes the classifier
  # callable standalone. Do NOT "fix" this into a direct invocation of the block.
  # Mutation guards, both measured rather than assumed: rewriting the anchored
  # case as a substring match (`*worktrees*`) reds g-substring-collision, and
  # rewriting it as a grep over the path reds g-worktrees and g-global-worktrees.
  # The metacharacter row is a VALUE-SIDE lock rather than a mutation guard: it
  # pins that the classifier never treats the path it is handed as a pattern,
  # which is precisely what the retired `grep $(git branch --show-current)` did.
  # Stated plainly because a mutation guard that does not actually flip is the
  # counterfeit-falsifiability class this repo keeps rediscovering.
  F13G_DRIVER="$F13_DIR/f13g-driver.sh"
  {
    printf '%s\n' "$F13_BLOCK"
    printf '%s\n' 'for probe_path in "$F13G_ROOT/.worktrees/a" "$F13G_ROOT/worktrees/a" "$F13G_HOME/.config/uberdev/worktrees/proj/b" "$F13G_ROOT/.claude/worktrees/solve-issue-9" "$F13G_ROOT/notworktrees/a" "/elsewhere/w" "$F13G_ROOT/.worktrees/v1.0|x"; do'
    printf '%s\n' '  printf "%s => %s\n" "$probe_path" "$(uberdev_fb_worktree_class "$probe_path" "$F13G_ROOT" "$F13G_HOME")"'
    printf '%s\n' 'done'
  } > "$F13G_DRIVER"
  F13G_OUT="$( cd "$F13_ROOT" && env -u FB_MODE -u FB_BASE_BRANCH -u FB_TEST_COMMAND \
      "F13G_ROOT=$F13_ROOT" "F13G_HOME=$F13_DIR/home" bash "$F13G_DRIVER" 2>/dev/null )"
  f13g_expect() {  # f13g_expect <path> <class> <tag>
    grep -qF "$1 => $2" <<<"$F13G_OUT" || f13_bad "$3"
  }
  f13g_expect "$F13_ROOT/.worktrees/a"                        owned            g-dot-worktrees
  f13g_expect "$F13_ROOT/worktrees/a"                         owned            g-worktrees
  f13g_expect "$F13_DIR/home/.config/uberdev/worktrees/proj/b" owned           g-global-worktrees
  f13g_expect "$F13_ROOT/.claude/worktrees/solve-issue-9"     dispatcher-owned g-dispatcher
  f13g_expect "$F13_ROOT/notworktrees/a"                      foreign          g-substring-collision
  f13g_expect "/elsewhere/w"                                  foreign          g-outside
  f13g_expect "$F13_ROOT/.worktrees/v1.0|x"                   owned            g-metacharacter

  # F13h — a skip is never silent. Mutation guard: make either arm a bare `:`
  # and the reason line disappears => RED.
  f13_run "FB_SHIM_TOPLEVEL=$F13_ROOT/.claude/worktrees/solve-issue-9"
  f13_saw '^worktree remove' && f13_bad h-removed-a-dispatcher-owned-worktree
  grep -qF "$F13_ROOT/.claude/worktrees/solve-issue-9" <<<"$F13_OUT" || f13_bad h-dispatcher-skip-unnamed
  grep -qF 'dispatcher-owned' <<<"$F13_OUT" || f13_bad h-dispatcher-skip-reasonless
  f13_run "FB_SHIM_TOPLEVEL=$F13_DIR/elsewhere/feat-y"
  f13_saw '^worktree remove' && f13_bad h-removed-a-foreign-worktree
  grep -qF "$F13_DIR/elsewhere/feat-y" <<<"$F13_OUT" || f13_bad h-foreign-skip-unnamed
  grep -qF 'foreign' <<<"$F13_OUT" || f13_bad h-foreign-skip-reasonless

  # F13i — safety canary, NOT a behavioural proof: the teardown must never reach
  # for `rm -rf`. Removal goes through git so a still-registered worktree cannot
  # be orphaned (same protocol as merge-pipeline/SKILL.md teardown).
  grep -qF 'rm -rf' <<<"$F13_BLOCK" && f13_bad i-block-contains-rm-rf

  # F13j — discard mode. No pull, no merge, no test run; worktree removed with
  # --force (the typed confirmation in Option 4 is what authorises that) BEFORE
  # the force-delete of the branch.
  f13_run "FB_MODE=discard" "FB_TEST_COMMAND="
  [[ "$F13_RC" -eq 0 ]] || f13_bad "j-discard-rc=$F13_RC"
  f13_saw '^merge '      && f13_bad j-discard-merged
  f13_saw '^pull '       && f13_bad j-discard-pulled
  f13_saw 'TESTCOMMAND'  && f13_bad j-discard-ran-tests
  f13_saw '^worktree remove --force ' || f13_bad j-discard-remove-not-forced
  f13_saw '^branch -D '  || f13_bad j-discard-branch-not-force-deleted
  F13_J_REMOVE="$(f13_index '^worktree remove')"
  F13_J_DELETE="$(f13_index '^branch -D')"
  if [[ -n "$F13_J_REMOVE" && -n "$F13_J_DELETE" && "$F13_J_REMOVE" -lt "$F13_J_DELETE" ]]; then :; else
    f13_bad "j-remove-not-before-delete($F13_J_REMOVE/$F13_J_DELETE)"
  fi

  rm -rf "$F13_DIR"
fi
if [[ -z "$F13_FAILURES" ]]; then
  echo "  PASS  F13 the Step 5 teardown block resolves before it mutates, refuses on a busy base or a detached HEAD, and removes the worktree before deleting the branch"; PASS=$((PASS+1))
else
  echo "  FAIL  F13 worktree teardown broken:$F13_FAILURES"; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# F14 — the Q2 adjudication record in plugins/uberdev/vendor.json is LOCKED here
# because the vendor checker cannot lock it: check_files() short-circuits on any
# component whose stance is not `track` (tools/vendor/vendor-check.py), and
# skills/finish-branch is `fork` — so its divergences[] is never read, and no
# check anywhere resolves a divergences[].ref against permanent_divergences[].id.
# A dangling ref would therefore pass every existing gate. This case is the
# missing resolution check, scoped to the component it belongs to.
#
# Mutation guard: delete the `interactive-discard-option` entry, or the ref that
# points at it, and F14 goes RED while vendor-check.py stays green.
# ---------------------------------------------------------------------------
F14_VENDOR="$REPO_ROOT/plugins/uberdev/vendor.json"
if [[ ! -r "$F14_VENDOR" ]]; then
  echo "  FAIL  F14 vendor.json missing/unreadable: $F14_VENDOR"; FAIL=$((FAIL+1))
else
  F14_OUT="$(python3 -I -B - "$F14_VENDOR" <<'F14_PY' 2>&1
import json, sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
divergence_ids = {entry.get("id") for entry in document.get("permanent_divergences", [])}
problems = []

target = "interactive-discard-option"
entry = next((e for e in document.get("permanent_divergences", []) if e.get("id") == target), None)
if entry is None:
    problems.append("no-permanent-divergence-entry")
else:
    if entry.get("permanent") is not True:
        problems.append("entry-not-permanent")
    if entry.get("scope") != "skills/finish-branch":
        problems.append("entry-scope-wrong")
    if not str(entry.get("note", "")).strip():
        problems.append("entry-note-empty")

component = next((c for c in document.get("components", []) if c.get("id") == "skills/finish-branch"), None)
if component is None:
    problems.append("no-finish-branch-component")
else:
    refs = [d.get("ref") for d in component.get("divergences", [])]
    if target not in refs:
        problems.append("component-does-not-reference-entry")
    for ref in refs:
        if ref not in divergence_ids:
            problems.append("dangling-ref:%s" % ref)

print(" ".join(problems) if problems else "OK")
F14_PY
)"
  if [[ "$F14_OUT" == "OK" ]]; then
    echo "  PASS  F14 the declined-discard-prompt divergence is recorded in vendor.json and every finish-branch divergence ref resolves"; PASS=$((PASS+1))
  else
    echo "  FAIL  F14 vendor.json divergence record broken: $F14_OUT"; FAIL=$((FAIL+1))
  fi
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
