#!/usr/bin/env bash
# Issue #470 — /uberdev:review-pr Phase 0: the multi-PR consolidation offer.
#
# WHAT THIS FILE IS FOR. `/review-pr` reviews exactly one PR per invocation.
# With N open PRs that costs N full pipeline runs even when the PRs land
# together anyway. Phase 0 offers, once and interactively, to combine every open
# PR onto one branch and review the combined result — and the offer is a PROMPT,
# never a default, because consolidating N PRs into one loses per-PR revert
# granularity and per-PR finding attribution.
#
# Two halves, both executable rather than grep-only:
#
#   RCX1–RCX8, RCX13  — the 0a SCAN fence, carved out of commands/review-pr.md
#                       and EXECUTED under `env -i` with a stubbed `gh`. These
#                       rows are about WHEN the offer is made; the no-offer arms
#                       must reach their verdict without a single `gh`
#                       round-trip, which is why the call log is asserted empty
#                       rather than merely unread.
#   RCXP, RCXF, RCX9–RCX12, RCX14
#                     — lib/review-consolidate.sh against REAL git fixtures.
#                       These rows are about what the combine may and may not do
#                       to the operator's checkout.
#
# Repo convention: `set -u` + `set -o pipefail` + manual PASS/FAIL counters,
# never `set -e` — an early abort turns "20 rows red" into "1 row red and 19
# never evaluated", which is how a broken guard looks healthy.
#
# ubuntu-only (a Unix-fixture file: pty allocation, real `git merge` conflict
# states, mode bits). Listed in the windows-skip-list block of test.yml.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
CONSOLIDATE_LIB="$REPO_ROOT/plugins/uberdev/lib/review-consolidate.sh"
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

for f in "$REVIEW_PR" "$MERGE_SKILL"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() {
  echo "  FAIL  $1"
  shift
  for line in "$@"; do echo "        $line"; done
  FAIL=$((FAIL + 1))
}
assert_eq() {
  local got="$1" want="$2" desc="$3"
  if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc" "expected: $want" "got:      $got"; fi
}
assert_contains() {
  local hay="$1" needle="$2" desc="$3"
  case "$hay" in
    *"$needle"*) pass "$desc" ;;
    *) fail "$desc" "expected to contain: $needle" "got: $hay" ;;
  esac
}
assert_not_contains() {
  local hay="$1" needle="$2" desc="$3"
  case "$hay" in
    *"$needle"*) fail "$desc" "must NOT contain: $needle" "got: $hay" ;;
    *) pass "$desc" ;;
  esac
}
# Once a SCAN_ID has been minted the verdict line carries it (and the count), so
# OFFER and REASON are no longer adjacent. Match the whole line rather than
# loosening either half into a bare substring.
assert_line() {
  local hay="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" <<<"$hay"; then
    pass "$desc"
  else
    fail "$desc" "expected a line matching: $pattern" "got: $hay"
  fi
}

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0a SCAN fence — carve and execute
# ---------------------------------------------------------------------------
# Same awk idiom tests/review-pr-entry.test.sh uses on the setup fence: keyed on
# the fence's `uberdev-executable origin=` tag, terminated by the next fence
# marker at column 0. Carving-and-executing (rather than grepping) is what makes
# these rows falsifiable — a fence that documents the gate but does not
# implement it greps green and executes wrong.
SCAN_FENCE="$TMP/consolidate-scan.sh"
awk '
  /uberdev-executable origin=review-pr-consolidate-scan/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$REVIEW_PR" >"$SCAN_FENCE"

if [ -s "$SCAN_FENCE" ]; then
  pass "RCX0: the 0a SCAN fence was carved out of commands/review-pr.md"
else
  fail "RCX0: no 0a fence found (origin=review-pr-consolidate-scan) — every RCX row below is unevaluable" \
       "file: $REVIEW_PR"
fi

# A real pty on stdin. `[ -t 0 ]` is the interactivity gate, and a test that
# could only ever produce the not-a-tty answer would leave the entire
# offer-is-made half unproven. python3 is already a hard dependency of this
# repo's runtime (code_fixer_contract.py, run_manifest.py).
cat >"$TMP/with-tty.py" <<'PY'
import os
import pty
import subprocess
import sys

master, slave = pty.openpty()
try:
    proc = subprocess.Popen(
        sys.argv[1:], stdin=slave,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    os.close(slave)
    slave = -1
    out, err = proc.communicate()
finally:
    if slave >= 0:
        os.close(slave)
    os.close(master)
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
raise SystemExit(proc.returncode)
PY

# A stubbed `gh`. It records argv to $STUB_GH_CALL_LOG (so a "no gh round-trip"
# claim is falsifiable), exits $STUB_GH_RC, and otherwise emits the JSON array
# in $STUB_GH_PAYLOAD. It honours `--jq` for the same reason the fake-gh
# fixture's success-mixed-base mode does: real gh filters in-process.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_GH_CALL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$STUB_GH_CALL_LOG"
fi
if [ "${STUB_GH_RC:-0}" != "0" ]; then
  printf 'gh: stub failure\n' >&2
  exit "${STUB_GH_RC}"
fi
payload="$(cat "${STUB_GH_PAYLOAD:-/dev/null}" 2>/dev/null)"
[ -n "$payload" ] || payload='[]'
want=0
filter=""
for arg in "$@"; do
  if [ "$want" = "1" ]; then filter="$arg"; want=0; continue; fi
  if [ "$arg" = "--jq" ]; then want=1; fi
done
if [ -n "$filter" ]; then
  jq -c "$filter" <<<"$payload"
else
  printf '%s\n' "$payload"
fi
SH
chmod +x "$TMP/bin/gh"

# A throwaway git repo: the fence resolves the repo root and mints a SCAN_ID
# from `git rev-parse --short HEAD`.
SCAN_REPO="$TMP/scan-repo"
mkdir -p "$SCAN_REPO"
(
  cd "$SCAN_REPO" || exit 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name Tester
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -qm seed
) >/dev/null 2>&1

_payload_n() {  # $1 = how many candidate rows to emit
  local n="$1" i=1
  printf '['
  while [ "$i" -le "$n" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"number":%s,"title":"candidate %s","headRefName":"feat/c%s","headRefOid":"%s","baseRefName":"%s","isDraft":false,"state":"OPEN","body":"","reviewDecision":null,"labels":[],"author":{"login":"a"},"headRepositoryOwner":{"login":"TheFJK"},"createdAt":"2026-08-0%sT00:00:00Z"}' \
      "$((200 + i))" "$i" "$i" \
      "$(printf '%040d' "$i")" \
      "$(case "$i" in 1) echo main ;; 2) echo release/2.0 ;; 3) echo hotfix/1.0 ;; *) echo main ;; esac)" \
      "$i"
    i=$((i + 1))
  done
  printf ']\n'
}

# Run the carved fence. $1 = "tty" | "notty"; remaining args are NAME=VALUE env
# assignments layered on top of the minimal environment.
_tool_dir() { d="$(command -v "$1" 2>/dev/null)"; [ -n "$d" ] && dirname "$d"; }
SCAN_PATH="$TMP/bin"
for tool in git jq python3 date sed grep; do
  d="$(_tool_dir "$tool")"
  case ":$SCAN_PATH:" in *":$d:"*) ;; *) [ -n "$d" ] && SCAN_PATH="$SCAN_PATH:$d" ;; esac
done
SCAN_PATH="$SCAN_PATH:/usr/bin:/bin:/usr/local/bin"

_run_scan() {
  local ttymode="$1"; shift
  local outf errf rc
  outf="$(mktemp)"; errf="$(mktemp)"
  if [ "$ttymode" = "tty" ]; then
    env -i HOME="$TMP/home" PATH="$SCAN_PATH" \
      PLUGIN_ROOT="$PLUGIN_ROOT" "$@" \
      python3 -I -B "$TMP/with-tty.py" bash -c "cd '$SCAN_REPO' && exec bash '$SCAN_FENCE'" \
      >"$outf" 2>"$errf"
    rc=$?
  else
    env -i HOME="$TMP/home" PATH="$SCAN_PATH" \
      PLUGIN_ROOT="$PLUGIN_ROOT" "$@" \
      bash -c "cd '$SCAN_REPO' && exec bash '$SCAN_FENCE'" \
      >"$outf" 2>"$errf" </dev/null
    rc=$?
  fi
  _SCAN_RC="$rc"
  _SCAN_OUT="$(cat "$outf")"
  _SCAN_ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

echo
echo "== RCX1–RCX8, RCX13: the 0a SCAN gate (executed, not grepped) =="

PAYLOAD5="$TMP/payload5.json"; _payload_n 5 >"$PAYLOAD5"
PAYLOAD4="$TMP/payload4.json"; _payload_n 4 >"$PAYLOAD4"
PAYLOAD1="$TMP/payload1.json"; _payload_n 1 >"$PAYLOAD1"

# RCX1 — --turbo / UBERDEV_TURBO must not gain a blocking prompt, and must not
# pay for a gh round-trip to find that out. An unattended run that queries the
# open-PR list before deciding is a rate-limit cost with no consumer.
LOG1="$TMP/log1.txt"; : >"$LOG1"
_run_scan notty UBERDEV_TURBO=1 ARGUMENTS='' \
  STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG1"
assert_eq "$_SCAN_RC" "0" "RCX1a: the turbo arm exits 0"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=no REASON=turbo" \
  "RCX1b: UBERDEV_TURBO=1 reports OFFER=no REASON=turbo on stderr"
assert_eq "$([ -s "$LOG1" ] && echo nonempty || echo empty)" "empty" \
  "RCX1c: the turbo arm made ZERO gh calls (the decision is env-only, before any round-trip)"

# RCX2 — non-interactive is the same class as turbo: nothing to prompt.
LOG2="$TMP/log2.txt"; : >"$LOG2"
_run_scan notty ARGUMENTS='' STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG2"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=no REASON=no_tty" \
  "RCX2a: no TTY on stdin reports OFFER=no REASON=no_tty"
assert_eq "$([ -s "$LOG2" ] && echo nonempty || echo empty)" "empty" \
  "RCX2b: the no-tty arm made ZERO gh calls"

# RCX3 — the explicit opt-out, and its precedence over the explicit opt-in.
# A flag pair that resolved by argv order would make `--no-consolidate` a
# coin-flip in any wrapper that appends flags.
LOG3="$TMP/log3.txt"; : >"$LOG3"
_run_scan tty ARGUMENTS='--no-consolidate' STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG3"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=no REASON=opt_out" \
  "RCX3a: --no-consolidate reports OFFER=no REASON=opt_out"
_run_scan tty ARGUMENTS='--consolidate --no-consolidate' STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG3"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=no REASON=opt_out" \
  "RCX3b: --no-consolidate WINS over --consolidate regardless of order"

# RCX4 — nothing to consolidate is not a prompt.
LOG4="$TMP/log4.txt"; : >"$LOG4"
_run_scan tty ARGUMENTS='' STUB_GH_PAYLOAD="$PAYLOAD1" STUB_GH_CALL_LOG="$LOG4"
assert_line "$_SCAN_ERR" '^REVIEW_CONSOLIDATE OFFER=no SCAN_ID=[0-9]{8}-[0-9]{6}-[a-f0-9]+ COUNT=1 REASON=too_few$' \
  "RCX4a: a single open PR reports OFFER=no COUNT=1 REASON=too_few"
assert_eq "$(jq 'length' <"$PAYLOAD1" 2>/dev/null)" "1" \
  "RCX4b: anti-vacuity — the stub really offered exactly 1 candidate"

# RCX5 — the offer itself. Number, title AND base per candidate: a set spanning
# several bases is exactly the set the operator must be able to see and decline.
LOG5="$TMP/log5.txt"; : >"$LOG5"
_run_scan tty ARGUMENTS='' STUB_GH_PAYLOAD="$PAYLOAD4" STUB_GH_CALL_LOG="$LOG5"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=yes" \
  "RCX5a: 4 candidates on a TTY with no flags reports OFFER=yes"
assert_contains "$_SCAN_ERR" "COUNT=4" "RCX5b: the offer reports COUNT=4"
RCX5_LINES="$(grep -cE '^#[0-9]+ — .+ \(base: .+\)$' <<<"$_SCAN_ERR" || true)"
assert_eq "${RCX5_LINES:-0}" "4" \
  "RCX5c: one '#N — <title> (base: <base>)' line per candidate"
RCX5_BASES="$(grep -oE '\(base: [^)]+\)' <<<"$_SCAN_ERR" | sort -u | wc -l | tr -d ' ')"
if [ "${RCX5_BASES:-0}" -ge 3 ]; then
  pass "RCX5d: the rendered block spans >=3 distinct bases (the cross-base case is visible, not hidden)"
else
  fail "RCX5d: the rendered block collapsed the bases — an operator cannot decline what is not shown" \
       "distinct bases rendered: ${RCX5_BASES:-0}" "stderr: $_SCAN_ERR"
fi
# `sed … ;q` rather than `… | head -n 1`, and a herestring rather than
# `printf | grep -q`: both pipe into a reader that exits on its first hit, and
# this file sets `pipefail`, so the producer's SIGPIPE would become the
# pipeline's status (tests/epipe-guard.test.sh scans every tracked *.sh for it).
RCX5_ID="$(sed -n '/SCAN_ID=/{s/.*SCAN_ID=\([0-9a-f-]*\).*/\1/p;q;}' <<<"$_SCAN_ERR")"
if grep -qE '^[0-9]{8}-[0-9]{6}-[a-f0-9]+$' <<<"${RCX5_ID:-}"; then
  pass "RCX5e: SCAN_ID matches RUN_ID_REGEX (it becomes a path segment, so its shape forecloses traversal)"
else
  fail "RCX5e: SCAN_ID does not match ^[0-9]{8}-[0-9]{6}-[a-f0-9]+\$" "got: ${RCX5_ID:-<none>}"
fi
if [ -n "${RCX5_ID:-}" ] && [ -s "$SCAN_REPO/.uberdev/consolidate/$RCX5_ID/candidates.json" ]; then
  pass "RCX5f: the candidate set was recorded to .uberdev/consolidate/<SCAN_ID>/candidates.json"
else
  fail "RCX5f: no candidates.json under .uberdev/consolidate/${RCX5_ID:-<none>}" \
       "the ASK turn and the COMBINE fence are different shells; an unrecorded set cannot cross"
fi
if [ -n "${RCX5_ID:-}" ] && [ -e "$SCAN_REPO/.uberdev/runs/$RCX5_ID" ]; then
  fail "RCX5g: Phase 0 wrote under .uberdev/runs/ — the reaper, the 'locked' marker and the receipt identity pinning are REVIEW-RUN invariants a pre-binding scan must not resemble"
else
  pass "RCX5g: Phase 0's scan dir is NOT under .uberdev/runs/ (no review-run invariants are implied)"
fi

# RCX6 — discovery failure is fail-soft. /review-pr has not bound a PR yet; a
# transient gh failure must degrade the OFFER, never abort the review.
LOG6="$TMP/log6.txt"; : >"$LOG6"
_run_scan tty ARGUMENTS='' STUB_GH_RC=1 STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG6"
assert_eq "$_SCAN_RC" "0" "RCX6a: a gh failure still exits 0 — the review proceeds single-PR"
assert_line "$_SCAN_ERR" '^REVIEW_CONSOLIDATE OFFER=no SCAN_ID=[0-9]{8}-[0-9]{6}-[a-f0-9]+ COUNT=0 REASON=discovery_failed$' \
  "RCX6b: the failure is reported as REASON=discovery_failed, not as an empty candidate set"
assert_eq "$([ -s "$LOG6" ] && echo nonempty || echo empty)" "nonempty" \
  "RCX6c: anti-vacuity — gh really was called on this arm"

# RCX7 — the explicit opt-in overrides both suppressors. An operator who typed
# `--consolidate` asked for it; turbo is a default, not a veto.
LOG7="$TMP/log7.txt"; : >"$LOG7"
_run_scan notty UBERDEV_TURBO=1 ARGUMENTS='--consolidate' \
  STUB_GH_PAYLOAD="$PAYLOAD4" STUB_GH_CALL_LOG="$LOG7"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=yes" \
  "RCX7: --consolidate under UBERDEV_TURBO=1 with no TTY still reports OFFER=yes"

# RCX8 — render stability. The skill templater substitutes positional
# parameters into the ENTIRE rendered body, including fence text, so a `$1` in
# a fence arrives as the user's first non-flag argument (the awk `$N` collision
# class, #294 / skill-renderer-awk-collision.test.sh).
if grep -qE '\$\{?[1-9][0-9]*\}?' "$SCAN_FENCE"; then
  fail "RCX8a: the 0a fence carries a positional parameter reference — the renderer will substitute it" \
       "$(grep -nE '\$\{?[1-9][0-9]*\}?' "$SCAN_FENCE" | head -n 3)"
else
  pass "RCX8a: the 0a fence carries no \$N / \${N} positional reference"
fi
if grep -qE "awk[^\\n]*'[^']*\\\$[0-9]" "$SCAN_FENCE"; then
  fail "RCX8b: the 0a fence carries an awk \$N column reference — the renderer mangles it"
else
  pass "RCX8b: the 0a fence carries no awk \$N column reference"
fi

# RCX13 — the chained-run gate. `finish-branch` auto-selects Option 2 and chains
# into /review-pr in its DEFAULT mode too, not only under --turbo, and that
# chain forwards no flag. Gating on turbo alone would put a blocking
# AskUserQuestion immediately after a /solve run pushed one PR. A chained solve
# run inherits UBERDEV_RUN_CARRIER_JSON; a standalone run does not.
LOG13="$TMP/log13.txt"; : >"$LOG13"
_run_scan tty ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON='{"x":1}' \
  STUB_GH_PAYLOAD="$PAYLOAD5" STUB_GH_CALL_LOG="$LOG13"
assert_contains "$_SCAN_ERR" "REVIEW_CONSOLIDATE OFFER=no REASON=chained" \
  "RCX13a: an inherited run carrier reports OFFER=no REASON=chained"
assert_eq "$([ -s "$LOG13" ] && echo nonempty || echo empty)" "empty" \
  "RCX13b: the chained arm made ZERO gh calls"

# ---------------------------------------------------------------------------
# lib/review-consolidate.sh — against real git
# ---------------------------------------------------------------------------
echo
echo "== RCXP, RCXF, RCX9–RCX12, RCX14: lib/review-consolidate.sh =="

if [ ! -r "$CONSOLIDATE_LIB" ]; then
  fail "RCXLIB: plugins/uberdev/lib/review-consolidate.sh is missing — every library row below is unevaluable" \
       "expected: $CONSOLIDATE_LIB"
  echo
  echo "== Summary =="
  echo "  passed: $PASS"
  echo "  failed: $FAIL"
  [ "$FAIL" -eq 0 ]
  exit
fi
pass "RCXLIB: lib/review-consolidate.sh is present and readable"

# A two-remote fixture: `origin` is a bare repo, `work` is the checkout the
# combine runs in. Two feature branches conflict on one file.
_mk_fixture() {  # $1 = fixture root
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q --bare origin.git
    git init -q -b main work
    cd work || exit 1
    git config user.email t@example.com
    git config user.name Tester
    git remote add origin ../origin.git
    printf 'base\n' > shared.txt
    printf 'untouched\n' > other.txt
    git add shared.txt other.txt
    git commit -qm base
    git push -q -u origin main

    git checkout -q -b feat/one
    printf 'one\n' > shared.txt
    git commit -qam one
    git push -q -u origin feat/one

    git checkout -q main
    git checkout -q -b feat/two
    printf 'two\n' > shared.txt
    git commit -qam two
    git push -q -u origin feat/two

    git checkout -q main
    git checkout -q -b feat/three
    printf 'three\n' > other.txt
    git commit -qam three
    git push -q -u origin feat/three

    git checkout -q main
  ) >/dev/null 2>&1
}

_oid() { git -C "$1" rev-parse "$2"; }

_write_candidates() {  # $1 = scan dir, $2... = JSON objects
  local dir="$1"; shift
  mkdir -p "$dir"
  { printf '['; local first=1
    for obj in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '%s' "$obj"
    done
    printf ']\n'
  } >"$dir/candidates.json"
}

# ---- RCXP: the preflight gate ---------------------------------------------
# The combine happens in the operator's live checkout, because
# `review_assert_selected_pr_head` compares the PR head to LOCAL HEAD later in
# the run. A dirty tree, a detached HEAD or a half-finished merge must therefore
# stop the whole thing BEFORE the first `git checkout -b`, not be steamrolled.
RCXP_ROOT="$TMP/rcxp"; _mk_fixture "$RCXP_ROOT"
RCXP_WORK="$RCXP_ROOT/work"
RCXP_SCAN="$TMP/rcxp-scan"; mkdir -p "$RCXP_SCAN"

# shellcheck source=/dev/null
. "$CONSOLIDATE_LIB" 2>/dev/null || true

if command -v review_consolidate_preflight >/dev/null 2>&1; then
  pass "RCXP0: review_consolidate_preflight is defined"

  review_consolidate_preflight "$RCXP_WORK" "$RCXP_SCAN" >/dev/null 2>&1
  assert_eq "$?" "0" "RCXPa: a clean tree on a named branch passes the gate"
  assert_eq "$(cat "$RCXP_SCAN/origin-branch.txt" 2>/dev/null)" "main" \
    "RCXPb: the ORIGINAL BRANCH NAME is recorded (never 'git checkout -', which does not survive intermediate checkouts)"

  printf 'dirty\n' >>"$RCXP_WORK/other.txt"
  RCXP_BEFORE="$(git -C "$RCXP_WORK" rev-parse --abbrev-ref HEAD)"
  review_consolidate_preflight "$RCXP_WORK" "$RCXP_SCAN" >/dev/null 2>&1
  assert_eq "$?" "2" "RCXPc: a dirty working tree is refused with rc 2"
  assert_eq "$(git -C "$RCXP_WORK" rev-parse --abbrev-ref HEAD)" "$RCXP_BEFORE" \
    "RCXPd: the refusal mutated nothing — still on the same branch"
  git -C "$RCXP_WORK" checkout -q -- other.txt

  git -C "$RCXP_WORK" checkout -q --detach
  review_consolidate_preflight "$RCXP_WORK" "$RCXP_SCAN" >/dev/null 2>&1
  assert_eq "$?" "2" "RCXPe: a detached HEAD is refused with rc 2 (there is no branch to restore to)"
  git -C "$RCXP_WORK" checkout -q main

  : >"$RCXP_WORK/.git/MERGE_HEAD"
  review_consolidate_preflight "$RCXP_WORK" "$RCXP_SCAN" >/dev/null 2>&1
  assert_eq "$?" "2" "RCXPf: an in-progress merge is refused with rc 2"
  rm -f "$RCXP_WORK/.git/MERGE_HEAD"
else
  fail "RCXP0: review_consolidate_preflight is not defined"
fi

# ---- RCXF: an unfetchable candidate is excluded, not fatal -----------------
RCXF_ROOT="$TMP/rcxf"; _mk_fixture "$RCXF_ROOT"
RCXF_WORK="$RCXF_ROOT/work"
RCXF_SCAN="$TMP/rcxf-scan"
_write_candidates "$RCXF_SCAN" \
  "{\"number\":301,\"title\":\"one\",\"headRefName\":\"feat/one\",\"headRefOid\":\"$(_oid "$RCXF_WORK" feat/one)\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-01T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}" \
  "{\"number\":399,\"title\":\"ghost\",\"headRefName\":\"feat/does-not-exist\",\"headRefOid\":\"0000000000000000000000000000000000000000\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-02T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}"

if command -v review_consolidate_fetch >/dev/null 2>&1; then
  review_consolidate_fetch "$RCXF_WORK" "$RCXF_SCAN" >/dev/null 2>&1
  RCXF_RC=$?
  assert_eq "$RCXF_RC" "0" "RCXFa: one unfetchable candidate does not abort the run"
  assert_contains "$(cat "$RCXF_SCAN/excluded.jsonl" 2>/dev/null)" '"number":399' \
    "RCXFb: the unfetchable candidate is excluded BY NUMBER"
  assert_contains "$(cat "$RCXF_SCAN/excluded.jsonl" 2>/dev/null)" '"reason":"fetch_failed"' \
    "RCXFc: the exclusion carries the typed fetch_failed reason"
  assert_not_contains "$(cat "$RCXF_SCAN/excluded.jsonl" 2>/dev/null)" '"number":301' \
    "RCXFd: the fetchable candidate is NOT excluded (anti-vacuity — this is a filter, not a refusal)"
else
  fail "RCXF0: review_consolidate_fetch is not defined"
fi

# ---- RCX9: conflict enumeration and the CONTINUE safety boundary -----------
RCX9_ROOT="$TMP/rcx9"; _mk_fixture "$RCX9_ROOT"
RCX9_WORK="$RCX9_ROOT/work"
RCX9_SCAN="$TMP/rcx9-scan"
RCX9_ONE="$(_oid "$RCX9_WORK" feat/one)"
RCX9_TWO="$(_oid "$RCX9_WORK" feat/two)"
_write_candidates "$RCX9_SCAN" \
  "{\"number\":401,\"title\":\"one\",\"headRefName\":\"feat/one\",\"headRefOid\":\"$RCX9_ONE\",\"baseRefName\":\"main\",\"body\":\"Closes #12\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-01T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}" \
  "{\"number\":402,\"title\":\"two\",\"headRefName\":\"feat/two\",\"headRefOid\":\"$RCX9_TWO\",\"baseRefName\":\"main\",\"body\":\"Fixes #12 and resolves #19\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-02T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}" \
  "{\"number\":403,\"title\":\"three\",\"headRefName\":\"feat/three\",\"headRefOid\":\"$(_oid "$RCX9_WORK" feat/three)\",\"baseRefName\":\"main\",\"body\":\"preclose #99\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-03T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}"

if command -v review_consolidate_merge_one >/dev/null 2>&1 \
   && command -v review_consolidate_continue >/dev/null 2>&1; then
  git -C "$RCX9_WORK" checkout -q -b chore/stack-rcx9 main
  review_consolidate_fetch "$RCX9_WORK" "$RCX9_SCAN" >/dev/null 2>&1

  review_consolidate_merge_one "$RCX9_WORK" "$RCX9_SCAN" 401 >/dev/null 2>&1
  assert_eq "$?" "0" "RCX9a: the first candidate merges cleanly (rc 0)"

  review_consolidate_merge_one "$RCX9_WORK" "$RCX9_SCAN" 402 >/dev/null 2>&1
  assert_eq "$?" "75" "RCX9b: a conflicting candidate returns the typed rc 75, not a generic failure"
  assert_contains "$(tr '\0' '\n' <"$RCX9_SCAN/conflicts-402.txt" 2>/dev/null)" "shared.txt" \
    "RCX9c: the conflicted path is written to conflicts-<number>.txt"

  # The safety boundary. Handing conflict resolution to an agent is only safe if
  # the controller refuses to stage anything outside the set the ENUMERATOR
  # produced — otherwise a resolver that also "tidied" an unrelated file would
  # silently land that edit inside a combine nobody reviewed as such.
  printf 'sneaky\n' >>"$RCX9_WORK/other.txt"
  review_consolidate_continue "$RCX9_WORK" "$RCX9_SCAN" 402 "other.txt" >/dev/null 2>&1
  assert_eq "$?" "2" "RCX9d: CONTINUE refuses to stage a path that is not in conflicts-402.txt"
  git -C "$RCX9_WORK" checkout -q -- other.txt 2>/dev/null || true

  # ...and refuses to finish while the enumerator still reports unmerged paths.
  review_consolidate_continue "$RCX9_WORK" "$RCX9_SCAN" 402 "shared.txt" >/dev/null 2>&1
  assert_eq "$?" "2" "RCX9e: CONTINUE refuses while the path is still unresolved (conflict markers left in place)"

  printf 'resolved\n' >"$RCX9_WORK/shared.txt"
  review_consolidate_continue "$RCX9_WORK" "$RCX9_SCAN" 402 "shared.txt" >/dev/null 2>&1
  assert_eq "$?" "0" "RCX9f: a genuine resolution completes the merge"
  if git -C "$RCX9_WORK" merge-base --is-ancestor "$RCX9_ONE" HEAD \
     && git -C "$RCX9_WORK" merge-base --is-ancestor "$RCX9_TWO" HEAD; then
    pass "RCX9g: BOTH candidate heads are ancestors of the combined HEAD"
  else
    fail "RCX9g: a candidate head is not an ancestor of HEAD — its change is not in the combine"
  fi
else
  fail "RCX90: review_consolidate_merge_one / review_consolidate_continue are not defined"
fi

# ---- RCX10: the ancestry gate ---------------------------------------------
# This is the ONLY gate that catches a lossy resolution.
# `review_assert_selected_pr_head` proves "PR head == local HEAD", which a
# combine that dropped a candidate's commit satisfies just as well.
RCX10_ROOT="$TMP/rcx10"; _mk_fixture "$RCX10_ROOT"
RCX10_WORK="$RCX10_ROOT/work"
RCX10_SCAN="$TMP/rcx10-scan"
RCX10_ONE="$(_oid "$RCX10_WORK" feat/one)"
RCX10_TWO="$(_oid "$RCX10_WORK" feat/two)"
_write_candidates "$RCX10_SCAN" \
  "{\"number\":501,\"title\":\"one\",\"headRefName\":\"feat/one\",\"headRefOid\":\"$RCX10_ONE\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-01T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}" \
  "{\"number\":502,\"title\":\"two\",\"headRefName\":\"feat/two\",\"headRefOid\":\"$RCX10_TWO\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-02T00:00:00Z\",\"headRepositoryOwner\":{\"login\":\"TheFJK\"}}"

if command -v review_consolidate_assert_ancestry >/dev/null 2>&1; then
  review_consolidate_preflight "$RCX10_WORK" "$RCX10_SCAN" >/dev/null 2>&1
  review_consolidate_fetch "$RCX10_WORK" "$RCX10_SCAN" >/dev/null 2>&1
  git -C "$RCX10_WORK" checkout -q -b chore/stack-rcx10 main
  review_consolidate_merge_one "$RCX10_WORK" "$RCX10_SCAN" 501 >/dev/null 2>&1
  printf '%s\n' "501" >"$RCX10_SCAN/included.txt"
  printf '%s\n' "502" >>"$RCX10_SCAN/included.txt"
  # 502 was never merged: exactly the shape a "resolution" that dropped a
  # candidate's commit leaves behind.
  review_consolidate_assert_ancestry "$RCX10_WORK" "$RCX10_SCAN" >/dev/null 2>&1
  assert_eq "$?" "2" "RCX10a: a combine missing an included candidate's commit fails the ancestry gate with rc 2"
  assert_contains "$(cat "$RCX10_SCAN/excluded.jsonl" 2>/dev/null)" '"reason":"ancestry_lost"' \
    "RCX10b: the failure is typed ancestry_lost, not a generic abort"
  if command -v review_consolidate_abort >/dev/null 2>&1; then
    review_consolidate_abort "$RCX10_WORK" "$RCX10_SCAN" >/dev/null 2>&1
    assert_eq "$(git -C "$RCX10_WORK" rev-parse --abbrev-ref HEAD)" "main" \
      "RCX10c: the abort restores the RECORDED branch name"
    if git -C "$RCX10_WORK" rev-parse --verify -q chore/stack-rcx10 >/dev/null 2>&1; then
      fail "RCX10d: the combine branch survived the abort — a half-built combine must not be left behind"
    else
      pass "RCX10d: the combine branch is gone after the abort"
    fi
  else
    fail "RCX10c: review_consolidate_abort is not defined"
  fi
else
  fail "RCX100: review_consolidate_assert_ancestry is not defined"
fi

# ---- RCXO: the merge order respects hard dependencies ----------------------
# A candidate stacked on another candidate's HEAD must merge after it, or the
# stacked commit arrives without its parent and the combine is a different
# change set than any of the PRs describe. `Depends on #N` in a body is the
# second edge, for stacks GitHub cannot express through baseRefName.
RCXO_SCAN="$TMP/rcxo-scan"
_write_candidates "$RCXO_SCAN" \
  '{"number":603,"title":"third","headRefName":"feat/c","headRefOid":"cccccccccccccccccccccccccccccccccccccccc","baseRefName":"feat/b","body":"","state":"OPEN","createdAt":"2026-08-03T00:00:00Z"}' \
  '{"number":601,"title":"first","headRefName":"feat/a","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main","body":"","state":"OPEN","createdAt":"2026-08-09T00:00:00Z"}' \
  '{"number":602,"title":"second","headRefName":"feat/b","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","baseRefName":"feat/a","body":"","state":"OPEN","createdAt":"2026-08-02T00:00:00Z"}' \
  '{"number":604,"title":"declared dependent","headRefName":"feat/d","headRefOid":"dddddddddddddddddddddddddddddddddddddddd","baseRefName":"main","body":"Depends on #603","state":"OPEN","createdAt":"2026-08-01T00:00:00Z"}'
if command -v review_consolidate_order >/dev/null 2>&1; then
  RCXO_OUT="$(review_consolidate_order "$RCXO_SCAN" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$RCXO_OUT" "601 602 603 604" \
    "RCXOa: the stack is topologically ordered (601 before 602 before 603) and 'Depends on #603' pushes 604 last"
  # Anti-vacuity: createdAt ALONE would have produced a different answer, so the
  # row is measuring the dependency edges and not the timestamps.
  RCXO_BY_DATE="$(jq -r 'sort_by(.createdAt) | .[].number' <"$RCXO_SCAN/candidates.json" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$RCXO_BY_DATE" = "$RCXO_OUT" ]; then
    fail "RCXOb: createdAt order equals the dependency order — the fixture cannot distinguish them"
  else
    pass "RCXOb: createdAt order ($RCXO_BY_DATE) differs from the emitted order, so RCXOa measured the dependency edges"
  fi
else
  fail "RCXO0: review_consolidate_order is not defined"
fi

# ---- RCXD: the resumable merge loop ----------------------------------------
# The loop hands control back on every conflict and is re-entered afterwards, so
# "skip what is already done" is not an optimisation — without it, re-entry
# re-merges an included candidate and the second `git merge` of the same commit
# is a no-op that silently masks the loop never advancing.
RCXD_ROOT="$TMP/rcxd"; _mk_fixture "$RCXD_ROOT"
RCXD_WORK="$RCXD_ROOT/work"
RCXD_SCAN="$TMP/rcxd-scan"
_write_candidates "$RCXD_SCAN" \
  "{\"number\":701,\"title\":\"one\",\"headRefName\":\"feat/one\",\"headRefOid\":\"$(_oid "$RCXD_WORK" feat/one)\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-01T00:00:00Z\"}" \
  "{\"number\":702,\"title\":\"two\",\"headRefName\":\"feat/two\",\"headRefOid\":\"$(_oid "$RCXD_WORK" feat/two)\",\"baseRefName\":\"main\",\"body\":\"\",\"state\":\"OPEN\",\"createdAt\":\"2026-08-02T00:00:00Z\"}"
if command -v review_consolidate_drive >/dev/null 2>&1 \
   && command -v review_consolidate_start_branch >/dev/null 2>&1; then
  review_consolidate_preflight "$RCXD_WORK" "$RCXD_SCAN" >/dev/null 2>&1
  review_consolidate_fetch "$RCXD_WORK" "$RCXD_SCAN" >/dev/null 2>&1
  review_consolidate_start_branch "$RCXD_WORK" "$RCXD_SCAN" main "chore/stack-rcxd" >/dev/null 2>&1
  assert_eq "$(git -C "$RCXD_WORK" rev-parse --abbrev-ref HEAD)" "chore/stack-rcxd" \
    "RCXDa: start_branch cuts the combine branch from the fetched base"
  review_consolidate_order "$RCXD_SCAN" >/dev/null 2>&1
  review_consolidate_drive "$RCXD_WORK" "$RCXD_SCAN" >/dev/null 2>&1
  assert_eq "$?" "75" "RCXDb: the loop stops at the first conflict with rc 75"
  assert_eq "$(cat "$RCXD_SCAN/pending-conflict.txt" 2>/dev/null)" "702" \
    "RCXDc: the stopped-at candidate is recorded so re-entry knows where it was"
  printf 'resolved\n' >"$RCXD_WORK/shared.txt"
  review_consolidate_continue "$RCXD_WORK" "$RCXD_SCAN" 702 "shared.txt" >/dev/null 2>&1
  review_consolidate_drive "$RCXD_WORK" "$RCXD_SCAN" >/dev/null 2>&1
  assert_eq "$?" "0" "RCXDd: re-entry after the resolution completes the loop"
  assert_eq "$(sort -un "$RCXD_SCAN/included.txt" | tr '\n' ' ' | sed 's/ $//')" "701 702" \
    "RCXDe: both candidates are recorded as included exactly once (re-entry did not re-merge 701)"
  if [ -e "$RCXD_SCAN/pending-conflict.txt" ]; then
    fail "RCXDf: the pending-conflict marker survived a completed loop — a later re-entry would resume a conflict that no longer exists"
  else
    pass "RCXDf: the pending-conflict marker is cleared when the loop completes"
  fi
else
  fail "RCXD0: review_consolidate_drive / review_consolidate_start_branch are not defined"
fi

# ---- RCX12: the Closes #N union -------------------------------------------
# The originals are superseded, not merged individually, so their `Closes #N`
# references have to travel to the combined PR or the underlying issues never
# close. `preclose #99` is the left-anchor negative: `close` preceded by a word
# character is not a closing keyword.
if command -v review_consolidate_closes >/dev/null 2>&1; then
  RCX12_OUT="$(review_consolidate_closes "$RCX9_SCAN" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$RCX12_OUT" "12 19" \
    "RCX12: the carried Closes set is exactly {12, 19} — deduped, multi-reference bodies harvested, 'preclose #99' rejected"
else
  fail "RCX120: review_consolidate_closes is not defined"
fi

# ---- RCX14: the closing-keyword ERE is ONE literal, byte for byte ----------
# /merge already owns this regex (its post-merge issue cleanup reads the same
# keywords out of the landed PR body). Two copies that drift produce two
# different answers to "which issues does this PR close", and the drift is
# invisible until an issue silently stays open. A byte-identity assertion is
# cheaper and stricter than a marker here: the vocabulary is a regex, not an
# enum, so the contract-marker machinery (which harvests closed member sets)
# does not fit it.
_extract_ere() {  # $1 = file; prints the single-quoted ERE on the closing-keyword line
  sed -n "/close\[sd\]?/{s/^[^']*'\\([^']*\\)'.*$/\\1/p;q;}" "$1"
}
RCX14_LIB="$(_extract_ere "$CONSOLIDATE_LIB")"
RCX14_SKILL="$(_extract_ere "$MERGE_SKILL")"
if [ -z "$RCX14_LIB" ] || [ -z "$RCX14_SKILL" ]; then
  fail "RCX14: one of the two ERE extractions came back EMPTY — the comparison would pass vacuously" \
       "lib:   ${RCX14_LIB:-<empty>}" "skill: ${RCX14_SKILL:-<empty>}"
else
  assert_eq "$RCX14_LIB" "$RCX14_SKILL" \
    "RCX14: lib/review-consolidate.sh and merge-pipeline/SKILL.md carry the SAME closing-keyword ERE, byte for byte"
fi

# ---- RCX11: trust-trail exclusivity ---------------------------------------
# AC 8 in its only falsifiable form. The combined PR is the sole carrier of the
# trust trail; an original that also received a label would let /merge land it
# on its own, outside the review that actually covered it.
echo
echo "== RCX11: the trust trail binds to the combined PR ONLY =="
RCX11_LOG="$TMP/rcx11-calls.txt"; : >"$RCX11_LOG"
if command -v review_consolidate_comment_originals >/dev/null 2>&1; then
  (
    PATH="$TMP/bin:$PATH"
    export STUB_GH_CALL_LOG="$RCX11_LOG"
    export STUB_GH_PAYLOAD=/dev/null
    review_consolidate_comment_originals "$RCX9_SCAN" 999
  ) >/dev/null 2>&1
  RCX11_CALLS="$(cat "$RCX11_LOG" 2>/dev/null)"
  if [ -s "$RCX11_LOG" ]; then
    pass "RCX11a: anti-vacuity — the run really made gh calls"
  else
    fail "RCX11a: the gh call log is empty; RCX11b/c would pass vacuously"
  fi
  assert_not_contains "$RCX11_CALLS" "--add-label uberdev-approved" \
    "RCX11b: no original PR receives an uberdev-approved label"
  assert_not_contains "$RCX11_CALLS" "--add-label uberdev-approved-with-concerns" \
    "RCX11c: no original PR receives an uberdev-approved-with-concerns label"
  assert_not_contains "$RCX11_CALLS" "pr merge" \
    "RCX11d: no original PR is merged by the supersession step"
  assert_not_contains "$RCX11_CALLS" "pr close" \
    "RCX11e: no original PR is closed by the supersession step (it lands through the combined PR)"
  assert_contains "$RCX11_CALLS" "999" \
    "RCX11f: the comment names the combined PR"
else
  fail "RCX110: review_consolidate_comment_originals is not defined"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
