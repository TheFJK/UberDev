#!/usr/bin/env bash
# tests/workflow-scripts.test.sh — RFC 0012 §4.4 test architecture for
# on-disk Workflow orchestration scripts (the ultracode migration carrier).
#
# Tiers (suite entry for all four; T2/T3/T4 delegate to the node harness):
#   T1 — lint: `node --check --input-type=module < "$f"` over every
#        glob-discovered workflow script under plugins/, plus forbidden-token
#        greps (import/require/process./fs./Date.now/Math.random/new Date(
#        outside SHARED marker blocks) and the 512 KB runtime size cap.
#   T2 — meta validation: pure-JSON `export const meta` literal between
#        /* META-BEGIN */ and /* META-END */ markers; {name, description,
#        phases[]} shape; every phase()/opts.phase string literal declared
#        in meta.phases.            (via tests/_workflow_harness.js validate)
#   T3 — behavioral dry-run: preprocess (strip meta export, wrap in an async
#        IIFE) + vm.runInNewContext under faithful runtime stubs.
#                                   (via tests/_workflow_harness.js validate)
#   T4 — shared-snippet drift guard: `// === SHARED:<name> v<N> ===` blocks
#        with the same name+version must be byte-identical across scripts.
#                               (via tests/_workflow_harness.js shared-drift)
#   §4.2 shape guard — every on-disk skills/*/workflow.js must have a sibling
#        SKILL.md carrying BOTH the Workflow invocation block and a
#        `## No-Workflow fallback` section (a migrated pipeline cannot ship
#        workflow-only).
#
# NON-VACUOUS BY DESIGN: with ZERO workflow scripts on disk (the carrier
# lands before any workflow.js ships — RFC 0012 §9 Phase-1 gate) the
# per-script checks pass with a notice, while the harness SELF-TESTS (every
# stub semantic + the preprocessing step) and the T1/T2/T4 control fixtures
# below always execute, so stub drift and wrapper bugs red CI even today.
#
# T1 INVOCATION FORM IS LOAD-BEARING (asserted in this test, not left to
# runner defaults): workflow scripts are ESM-shaped (`export const meta` +
# top-level await) plain .js files with no package.json scoping. Verified
# live on Node v20.19.2: `node --check < "$f"` (stdin WITHOUT
# --input-type=module) REDS on that shape (stdin defaults to CommonJS),
# while runners with default module detection (>=22.7, backported into late
# 20.x for the file form) pass it — an unpinned guard flips on runner-image
# updates. The pinned stdin form `node --check --input-type=module < "$f"`
# is deterministic on every Node the CI images ship, with no .mjs renames
# and no package.json `type:module` side effects on the plugin.
#
# Runs on BOTH CI jobs (ubuntu + windows Git Bash): node ships on both
# GitHub images; harness paths are passed as plain argv (MSYS2 converts
# them), and stdin redirection is done by bash itself.
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): any secret-shaped fixture token must
# be assembled at runtime by concatenation, never contiguous source bytes —
# the finish-branch pre-push scanner hard-aborts on them. The fixtures below
# contain none.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIS_FILE="$REPO_ROOT/tests/workflow-scripts.test.sh"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"
PLUGINS_DIR="$REPO_ROOT/plugins"
# 512 KB — the documented Workflow runtime script cap. The UNIT compared against
# it is the worst-case CRLF checkout of the committed blob (blob bytes + newline
# count), NOT the bytes this particular checkout happens to hold; the marked
# T1 size-ratchet measurement region below says why. That region's markers are
# NOT restated here on purpose: rows T1.c7/T1.c8 slice on them, and a second
# copy of the literal is a second place for the slice to start (a mention in
# this comment made the slice span the whole file and pass vacuously).
SIZE_CAP_BYTES=524288
STRUCTURAL_LIB="$REPO_ROOT/tests/_lib_assert_structural.sh"

# Hard-fail (exit 2) on missing inputs — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$THIS_FILE" "$HARNESS" "$STRUCTURAL_LIB"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
[ -d "$PLUGINS_DIR" ] || { echo "FATAL: plugins/ directory missing: $PLUGINS_DIR" >&2; exit 2; }
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the workflow-script tiers (preinstalled on both CI images)" >&2
  exit 2
}
command -v git >/dev/null 2>&1 || {
  echo "FATAL: git is required for the platform-invariant size ratchet (#522)" >&2
  exit 2
}

# Shared structural helpers. This suite uses ONE of them — the measurement
# primitive checkout_worst_case_bytes (#522), which does not touch $PASS/$FAIL.
# Fail-loud guard per #209: a missing or unreadable helper aborts rc=2, never
# vacuous-green.
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }
# The guard above only catches a helper file that is MISSING or unparseable:
# `source` reports the status of the last command in the sourced file, so a
# helper that was renamed, moved or split out still sources rc=0. Every call to
# it would then fail with command-not-found (rc 127), which increments neither
# counter — and with no errexit this file would print `failed: 0` and exit 0
# with its size ratchet never executed. Assert the names actually called here,
# and extend this list when a new one is used.
for structural_fn in checkout_worst_case_bytes; do
  command -v "$structural_fn" >/dev/null 2>&1 || {
    echo "FATAL: _lib_assert_structural.sh sourced but $structural_fn is not defined (renamed helper?)" >&2
    exit 2
  }
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMPDIR_FIXTURES="$(mktemp -d)"
# The fixture tree below contains a throwaway git repo; on Git Bash a still-open
# handle can make `rm -rf` return non-zero, and this file sets pipefail. Teardown
# must never be the thing that reds the suite. ONE EXIT trap only — a second
# `trap ... EXIT` silently REPLACES this one.
trap 'rm -rf "$TMPDIR_FIXTURES" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Discovery: workflow scripts live at plugins/*/skills/<name>/workflow.js
# (children under skills/<name>/workflows/) per RFC 0012 DR-1. The glob also
# accepts workflow-*.js siblings so a renamed variant cannot dodge the lint.
# Newline-delimited; repo paths may contain spaces, so consume ONLY via
# `while IFS= read -r`.
# ---------------------------------------------------------------------------
discover_workflow_scripts() {
  find "$PLUGINS_DIR" -type f \( -name 'workflow*.js' -o -path '*/workflows/*.js' \) 2>/dev/null | sort
}

SCRIPTS_FILE="$TMPDIR_FIXTURES/discovered.txt"
discover_workflow_scripts > "$SCRIPTS_FILE"
SCRIPT_COUNT=0
while IFS= read -r _line; do
  [ -n "$_line" ] && SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
done < "$SCRIPTS_FILE"

echo "## workflow-scripts tiers T1-T4 (RFC 0012 §4.4) — discovered scripts: $SCRIPT_COUNT"

# ---------------------------------------------------------------------------
# T1 control fixtures — assert the pinned invocation form itself, every run.
# ---------------------------------------------------------------------------
echo "== T1: lint invocation-form controls =="

GOOD_ESM="$TMPDIR_FIXTURES/good-esm.js"
{
  echo '/* META-BEGIN */'
  echo 'export const meta = { "name": "control", "description": "T1 control fixture", "phases": ["Only"] };'
  echo '/* META-END */'
  echo 'phase("Only");'
  echo 'await Promise.resolve(1);'
} > "$GOOD_ESM"

if node --check --input-type=module < "$GOOD_ESM" >/dev/null 2>&1; then
  pass "T1.c1 pinned form accepts the spec-mandated ESM shape (export const meta + top-level await)"
else
  fail "T1.c1 pinned form rejected the spec-mandated ESM shape — Node on this runner broke the invocation contract"
fi

BAD_SYNTAX="$TMPDIR_FIXTURES/bad-syntax.js"
printf 'export const meta = {;\n' > "$BAD_SYNTAX"
if node --check --input-type=module < "$BAD_SYNTAX" >/dev/null 2>&1; then
  fail "T1.c2 pinned form must red on a syntax error (it passed a broken fixture)"
else
  pass "T1.c2 pinned form reds on a syntax error"
fi

# Self-anchor: the lint below must keep using the PINNED stdin form. A future
# edit that drops --input-type=module (reverting to runner-default module
# detection) reds here before it can flip on a runner-image update.
if grep -qF -- 'node --check --input-type=module <' "$THIS_FILE"; then
  pass "T1.c3 this test pins the stdin --input-type=module invocation form"
else
  fail "T1.c3 the pinned invocation form literal vanished from this test"
fi

# ---------------------------------------------------------------------------
# T1 per-script: lint + size cap + forbidden-token greps.
#
# Forbidden tokens are checked OUTSIDE `// === SHARED:<name> v<N> ===` blocks
# (RFC 0012 §4.4): a SHARED block is the audited escape hatch for coarse-grep
# false positives (e.g. a reviewed `new Date(epochValue)` formatter — the
# grep cannot see arguments). T4 keeps every such block byte-identical across
# scripts, and the T3 sandbox shadows still THROW on argless new Date() /
# Date.now() / Math.random() at run time, so the escape hatch never weakens
# the runtime contract.
# ---------------------------------------------------------------------------
echo "== T1: per-script lint + forbidden tokens + size cap =="

# Strip SHARED-marked regions; prefix surviving lines with their original
# line number (NN:) for actionable FAIL output. The boundary classes in the
# patterns below treat ':' as a non-identifier char, so the prefix never
# masks a real start-of-line hit.
strip_shared_blocks() {
  awk '
    /^[ \t]*\/\/ === SHARED:[A-Za-z0-9._-]+ v[0-9]+ ===[ \t]*$/ { inshared=1; next }
    /^[ \t]*\/\/ === END SHARED ===[ \t]*$/                     { inshared=0; next }
    !inshared { printf "%d:%s\n", NR, $0 }
  ' "$1"
}

# Each entry: <ERE pattern>|<human label>. Patterns run with grep -E over the
# SHARED-stripped, line-number-prefixed content. import/require additionally
# use -w (word match) so e.g. "important" cannot false-positive.
check_forbidden_tokens() {
  local file="$1" base="$2" stripped hits
  stripped="$(strip_shared_blocks "$file")"

  hits="$(printf '%s\n' "$stripped" | grep -wE 'import|require' || true)"
  if [ -n "$hits" ]; then
    fail "T1 $base: forbidden token import/require (scripts are self-contained — copy-paste via SHARED blocks)"
    sed -n '1,5s/^/        /p' <<<"$hits"
  else
    pass "T1 $base: no import/require"
  fi

  hits="$(printf '%s\n' "$stripped" | grep -E '(^|[^[:alnum:]_$.])process\.|(^|[^[:alnum:]_$.])fs\.' || true)"
  if [ -n "$hits" ]; then
    fail "T1 $base: forbidden token process./fs. (the script cannot touch Node APIs or the filesystem — agents do)"
    sed -n '1,5s/^/        /p' <<<"$hits"
  else
    pass "T1 $base: no process./fs."
  fi

  hits="$(printf '%s\n' "$stripped" | grep -E '(^|[^[:alnum:]_$])Date\.now|(^|[^[:alnum:]_$])Math\.random|new[[:space:]]+Date[[:space:]]*\(' || true)"
  if [ -n "$hits" ]; then
    fail "T1 $base: forbidden token Date.now/Math.random/new Date( — timestamps arrive via args (DR-7)"
    sed -n '1,5s/^/        /p' <<<"$hits"
  else
    pass "T1 $base: no Date.now/Math.random/new Date("
  fi
}

# === BEGIN T1 size-ratchet measurement (#522) ===
# The size cap is budgeted against the WORST-CASE CRLF CHECKOUT of the committed
# blob, never against the bytes this particular checkout happens to hold.
#
# WHY. core.autocrlf=true is live on windows-latest, so a worktree byte count is
# a checkout-TRANSLATED size and one literal cap is silently a stricter cap
# there. Measured on one commit of a 125-line file: 6454 B on the ubuntu job,
# 6579 B on the windows job — a delta of exactly its newline count.
#
# WHY /.gitattributes IS NOT THE FIX. tests/docs-accuracy.test.sh row T8.10
# forbids widening it beyond plugins/uberdev/hooks/**: three byte-exactness
# suites are windows-skipped on that scoping, and widening the rule would
# convert a documented skip into an untested claim.
#
# WHY NOT PLAIN BLOB BYTES. The Workflow runtime loads workflow.js FROM DISK, so
# blob-only bytes would LOOSEN the cap by one byte per line on the platform
# carrying the biggest payload. Worst-case keeps today's Windows strictness and
# raises every other platform to match.
#
# Rows T1.f8-T1.f11 drive these two functions against a throwaway repo; rows
# T1.c7/T1.c8 keep the whole measurement inside these markers.
wf_verdict_field() {  # <verdict_line> <1|2|3> -> that pipe-delimited field
  # The ONE parser. The live rows below and the T1.f fixtures both go through
  # it, so a parse bug cannot pass here while the fixtures split the line their
  # own way (#370: one contract, N uncompared copies).
  local line="$1" idx="$2" rest
  rest="${line#*|}"
  case "$idx" in
    1) printf '%s\n' "${line%%|*}" ;;
    2) printf '%s\n' "${rest%%|*}" ;;
    3) printf '%s\n' "${rest#*|}" ;;
  esac
}

wf_script_verdict() {  # <root> <repo_rel_path> <cap_bytes> -> "<verdict>|<size>|<basis>"
  local wf_root="$1" wf_base="$2" wf_cap="$3"
  local wf_size wf_rc wf_basis
  wf_size="$(checkout_worst_case_bytes "$wf_root" "$wf_base")"
  wf_rc=$?
  wf_basis="worst-case CRLF checkout of HEAD:$wf_base"
  if [ "$wf_rc" -eq 3 ]; then
    # No blob at HEAD: authored but not yet committed. Measure the WORKTREE
    # bytes and SAY SO on the row — the cap is about what the runtime loads, and
    # a silent skip here is the vacuity class #522 exists to close. On CI every
    # discovered script is committed, so this arm is local-dev only.
    wf_size="$(wc -c < "$wf_root/$wf_base" | tr -d '[:space:]')"
    wf_basis="worktree bytes — $wf_base has no blob at HEAD (uncommitted)"
    wf_rc=0
  fi
  # Only re-classify a SUCCESSFUL measurement, so an rc 2/3 keeps its own
  # identity in the basis instead of being flattened into "rc=4".
  if [ "$wf_rc" -eq 0 ]; then
    case "$wf_size" in ''|*[!0-9]*) wf_rc=4 ;; esac
  fi
  if [ "$wf_rc" -ne 0 ]; then
    # Empty size field, never "0": a cap is satisfied by 0 bytes, so a failed
    # measurement must not be able to wear a passing number.
    printf 'unmeasurable||checkout_worst_case_bytes rc=%s over HEAD:%s\n' "$wf_rc" "$wf_base"
    return 0
  fi
  if [ "$wf_size" -le "$wf_cap" ]; then
    printf 'ok|%s|%s\n' "$wf_size" "$wf_basis"
  else
    printf 'over|%s|%s\n' "$wf_size" "$wf_basis"
  fi
}
# === END T1 size-ratchet measurement (#522) ===

if [ "$SCRIPT_COUNT" -eq 0 ]; then
  pass "T1 notice: no workflow scripts on disk yet — per-script lint vacuously green (carrier lands before Phase 2 ships the first script)"
else
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    base="${script#"$REPO_ROOT"/}"

    if node --check --input-type=module < "$script" >/dev/null 2>&1; then
      pass "T1 $base: node --check --input-type=module < file"
    else
      fail "T1 $base: failed ESM lint (node --check --input-type=module)"
      node --check --input-type=module < "$script" 2>&1 | sed -n '1,5s/^/        /p'
    fi

    verdict_line="$(wf_script_verdict "$REPO_ROOT" "$base" "$SIZE_CAP_BYTES")"
    verdict="$(wf_verdict_field "$verdict_line" 1)"
    size="$(wf_verdict_field "$verdict_line" 2)"
    size_basis="$(wf_verdict_field "$verdict_line" 3)"
    case "$verdict" in
      ok)   pass "T1 $base: size $size <= $SIZE_CAP_BYTES bytes (512 KB runtime cap; $size_basis)" ;;
      over) fail "T1 $base: size $size exceeds the 512 KB Workflow runtime cap ($size_basis)" ;;
      *)    fail "T1 $base: size UNMEASURABLE ($size_basis)" ;;
    esac

    check_forbidden_tokens "$script" "$base"
  done < "$SCRIPTS_FILE"
fi

# Forbidden-token grep controls: the strip+grep machinery must (a) hit a
# violation outside SHARED markers, (b) honour the SHARED escape hatch.
FORBIDDEN_FIXTURE="$TMPDIR_FIXTURES/forbidden.js"
{
  echo 'const t = Date.now();'
  echo '// === SHARED:date-fmt v1 ==='
  echo 'const d = new Date(1700000000000).toISOString();'
  echo '// === END SHARED ==='
} > "$FORBIDDEN_FIXTURE"
if grep -qE '(^|[^[:alnum:]_$])Date\.now' <<<"$(strip_shared_blocks "$FORBIDDEN_FIXTURE")"; then
  pass "T1.c4 forbidden-token grep catches Date.now outside SHARED markers"
else
  fail "T1.c4 forbidden-token grep MISSED Date.now outside SHARED markers"
fi
if grep -qE 'new[[:space:]]+Date[[:space:]]*\(' <<<"$(strip_shared_blocks "$FORBIDDEN_FIXTURE")"; then
  fail "T1.c5 SHARED-block escape hatch broken: new Date( INSIDE markers leaked into the grep surface"
else
  pass "T1.c5 SHARED-block contents are exempt from the static grep (T3 runtime shadows still apply)"
fi
if grep -qwE 'import|require' <<<'1:// important: requires careful reading'; then
  fail "T1.c6 word-boundary control: 'important'/'requires' must not trip the import/require grep"
else
  pass "T1.c6 import/require grep is word-bounded (no 'important'/'requires' false positives)"
fi

# ---------------------------------------------------------------------------
# T1.f — controls for the T1 SIZE cap (#522). Same role for the size ratchet
# that T1.c* play for the lint greps.
#
# The cap is a fixed number of bytes, but a worktree byte count is a
# CHECKOUT-TRANSLATED size: core.autocrlf=true is live on windows-latest
# (/.gitattributes is deliberately scoped to plugins/uberdev/hooks/**), so one
# literal budget is silently a stricter budget there. Measured on the same
# commit: plugins/uberdev/skills/using-uberdev/SKILL.md is 6454 B on ubuntu and
# 6579 B on windows — a delta of exactly its 125 newlines.
#
# These rows build a throwaway repo, flip core.autocrlf across it, and prove the
# replacement measurement does not move. Every row is an explicit PASS or FAIL —
# never a skip: a fixture that could not be built reds T1.f0 AND every row that
# depends on it, because "no measurement" must never read as "measurement fine".
# ---------------------------------------------------------------------------
echo "== T1.f: size-ratchet fixtures (platform-invariant measurement, #522) =="

t1f_worktree_bytes() {  # <path> -> the bytes that file occupies ON DISK, right now
  # Argument form, not the redirect form, DELIBERATELY: T1.c8 below ratchets the
  # redirect token to the labelled measurement region only, so these fixtures
  # must reach the same number by an independent route (which is also what makes
  # T1.f3 a real comparison rather than a restatement). awk reads field 1 because
  # Git Bash pads the count.
  wc -c "$1" | awk '{ print $1 }' | tr -d '[:space:]'
}

t1f_recheckout() {  # <core.autocrlf value> — pin the conversion, restore f.txt from the index
  git -C "$T1F_REPO" config core.autocrlf "$1" >/dev/null 2>&1 || return 1
  rm -f "$T1F_REPO/f.txt" || return 1
  git -C "$T1F_REPO" checkout -- f.txt >/dev/null 2>&1 || return 1
}

T1F_REPO="$TMPDIR_FIXTURES/blob-ratchet"
T1F_NONREPO="$TMPDIR_FIXTURES/not-a-repo"
T1F_BLOB="$TMPDIR_FIXTURES/blob-bytes.bin"
T1F_READY=0
mkdir -p "$T1F_NONREPO"
# `-b main` keeps git's default-branch advice off stderr on Git Bash. The commit
# pins name/email AND commit.gpgsign so a host with global signing turned on
# cannot fail the fixture.
if git init -q -b main "$T1F_REPO" >/dev/null 2>&1 \
   && printf 'alpha\nbeta\ngamma\n' > "$T1F_REPO/f.txt" \
   && git -C "$T1F_REPO" add f.txt >/dev/null 2>&1 \
   && git -C "$T1F_REPO" -c user.name=uberdev-test -c user.email=uberdev-test@example.invalid \
          -c commit.gpgsign=false commit -qm fixture >/dev/null 2>&1 \
   && printf 'loose\n' > "$T1F_REPO/uncommitted.js"; then
  T1F_READY=1
fi

if [ "$T1F_READY" -eq 1 ] && git -C "$T1F_REPO" rev-parse --verify --quiet HEAD:f.txt >/dev/null 2>&1; then
  pass "T1.f0 throwaway fixture repo built, with a committed blob at HEAD:f.txt"
else
  fail "T1.f0 could not build the fixture repo (git init/add/commit failed) — every T1.f row below is unproven, not fine"
fi

W_LF=""; W_CRLF=""; H_LF=""; H_CRLF=""
if [ "$T1F_READY" -eq 1 ] && t1f_recheckout false; then
  W_LF="$(t1f_worktree_bytes "$T1F_REPO/f.txt")"
  H_LF="$(checkout_worst_case_bytes "$T1F_REPO" f.txt)"
fi
if [ "$T1F_READY" -eq 1 ] && t1f_recheckout true; then
  W_CRLF="$(t1f_worktree_bytes "$T1F_REPO/f.txt")"
  H_CRLF="$(checkout_worst_case_bytes "$T1F_REPO" f.txt)"
fi

# The property row: the same commit must budget to the same number on a host
# that translates line endings and one that does not.
if [ -n "$H_LF" ] && [ "$H_LF" = "$H_CRLF" ]; then
  pass "T1.f1 the measurement is invariant under core.autocrlf (${H_LF} B with false, ${H_CRLF} B with true)"
else
  fail "T1.f1 the measurement MOVED when core.autocrlf flipped (false='$H_LF', true='$H_CRLF') — one literal budget would be two different budgets"
fi

# Fixture integrity: without a REAL translation, T1.f1 passes vacuously on any
# host where autocrlf happens to be inert. The delta is checked arithmetically —
# MSYS2 grep reads text-mode and cannot see a CR at all, so a grep-based CR check
# is vacuously green on the one platform that matters
# (tests/crossplatform-shell-wrappers.test.sh XH2a measured this).
T1F_BLOB_LF=""
if [ "$T1F_READY" -eq 1 ] && git -C "$T1F_REPO" cat-file blob HEAD:f.txt > "$T1F_BLOB" 2>/dev/null; then
  T1F_BLOB_LF="$(wc -l < "$T1F_BLOB" | tr -d '[:space:]')"
fi
if [ -n "$W_LF" ] && [ -n "$W_CRLF" ] && [ -n "$T1F_BLOB_LF" ] \
   && [ "$W_CRLF" -ne "$W_LF" ] && [ "$((W_CRLF - W_LF))" -eq "$T1F_BLOB_LF" ]; then
  pass "T1.f2 the fixture genuinely translates on checkout (${W_LF} B -> ${W_CRLF} B on disk, +${T1F_BLOB_LF} = the blob's newline count)"
else
  fail "T1.f2 the fixture did NOT translate (LF='$W_LF', CRLF='$W_CRLF', blob newlines='$T1F_BLOB_LF') — T1.f1 proves nothing on this host"
fi

# The unit is the WORST-CASE checkout, not the blob: the runtime loads
# workflow.js from disk, so budgeting plain blob bytes would loosen the cap by
# one byte per line on exactly the platform that translates.
if [ -n "$H_CRLF" ] && [ "$H_CRLF" = "$W_CRLF" ]; then
  pass "T1.f3 the measured unit IS the worst-case checkout size (${H_CRLF} B == the translated file on disk)"
else
  fail "T1.f3 the measured value ('$H_CRLF') is not the translated checkout size ('$W_CRLF') — blob-only bytes LOOSEN the cap by one byte per line"
fi

# Anti-vacuity: the naive form of this fix, 'git cat-file blob HEAD:<path>'
# piped into a byte counter, prints 0 for a path that is not in HEAD — and 0
# satisfies every budget.
T1F_MISS="$(checkout_worst_case_bytes "$T1F_REPO" no/such/file 2>/dev/null)"
T1F_MISS_RC=$?
if [ "$T1F_MISS_RC" -eq 3 ] && [ -z "$T1F_MISS" ]; then
  pass "T1.f5 a path with no blob at HEAD returns rc=3 and prints nothing (never the '0' that satisfies any budget)"
else
  fail "T1.f5 a missing blob gave rc=$T1F_MISS_RC value='$T1F_MISS' — expected rc=3 and empty output; a value of '0' here is the #522 failure mode wearing a fix's clothes"
fi

T1F_NOREPO_VAL="$(checkout_worst_case_bytes "$T1F_NONREPO" f.txt 2>/dev/null)"
T1F_NOREPO_RC=$?
if [ "$T1F_NOREPO_RC" -eq 2 ] && [ -z "$T1F_NOREPO_VAL" ]; then
  pass "T1.f6 a directory that is not a git work tree returns rc=2 and prints nothing"
else
  fail "T1.f6 a non-work-tree gave rc=$T1F_NOREPO_RC value='$T1F_NOREPO_VAL' — expected rc=2 and empty output"
fi

# The helper is called inside a command substitution, where 'exit' would kill
# only the subshell and hand the caller an empty string — the exact vacuous-pass
# class it exists to prevent. Same contract as _t10_corpus in
# tests/docs-accuracy.test.sh. An empty slice is a FAIL, never a pass.
T1F_FN_BODY="$(sed -n '/^checkout_worst_case_bytes()/,/^}/p' "$STRUCTURAL_LIB")"
if [ -z "$T1F_FN_BODY" ]; then
  fail "T1.f7 could not slice checkout_worst_case_bytes out of $STRUCTURAL_LIB (renamed or reformatted) — an empty slice satisfies an absence check vacuously"
elif grep -qE '(^|[^[:alnum:]_.-])exit([[:space:]]|$)' <<<"$T1F_FN_BODY"; then
  fail "T1.f7 checkout_worst_case_bytes contains a bare 'exit' — inside a command substitution that kills the subshell only and returns an empty string to the caller"
else
  pass "T1.f7 checkout_worst_case_bytes is exit-free (it returns an rc a substitution caller can branch on)"
fi

# The rows above prove the measurement primitive. The rows below prove the
# SUITE'S OWN decision function — the one the live per-script ratchet calls — by
# driving it against the fixture repo. Without them the live `-le` comparison
# would be reachable only through the shipped scripts, i.e. only in the state
# where it happens to pass. They read the verdict line through the SAME
# wf_verdict_field parser the live rows use, so a fixture cannot stay green by
# splitting the line differently from production.
T1F_OVER_LINE="$(wf_script_verdict "$T1F_REPO" f.txt 10)"
T1F_EXPECT_SIZE="$(checkout_worst_case_bytes "$T1F_REPO" f.txt)"
if [ "$(wf_verdict_field "$T1F_OVER_LINE" 1)" = "over" ] \
   && [ -n "$T1F_EXPECT_SIZE" ] && [ "$(wf_verdict_field "$T1F_OVER_LINE" 2)" = "$T1F_EXPECT_SIZE" ]; then
  pass "T1.f8 a blob past its cap is reported over budget, carrying the measured size (${T1F_EXPECT_SIZE} B > 10 B)"
else
  fail "T1.f8 an over-budget blob gave '$T1F_OVER_LINE' — expected verdict 'over' with size '$T1F_EXPECT_SIZE'"
fi

# Control for T1.f8: without it, 'over' could be what this function says about
# everything.
T1F_UNDER_LINE="$(wf_script_verdict "$T1F_REPO" f.txt 100000)"
if [ "$(wf_verdict_field "$T1F_UNDER_LINE" 1)" = "ok" ]; then
  pass "T1.f9 a blob inside its cap is reported ok (the 'over' verdict is not this function's only answer)"
else
  fail "T1.f9 an in-budget blob gave '$T1F_UNDER_LINE' — expected verdict 'ok'"
fi

# A measurement that could not be made must never arrive as a number, because
# every number small enough to be believable also satisfies the cap.
T1F_UNMEAS_LINE="$(wf_script_verdict "$T1F_NONREPO" f.txt 10)"
T1F_UNMEAS_SIZE="$(wf_verdict_field "$T1F_UNMEAS_LINE" 2)"
if [ "$(wf_verdict_field "$T1F_UNMEAS_LINE" 1)" = "unmeasurable" ] && [ -z "$T1F_UNMEAS_SIZE" ] \
   && [ -n "$(wf_verdict_field "$T1F_UNMEAS_LINE" 3)" ]; then
  pass "T1.f10 an unmeasurable path is reported unmeasurable with an empty size and a basis naming the rc"
else
  fail "T1.f10 an unmeasurable path gave '$T1F_UNMEAS_LINE' — expected verdict 'unmeasurable', an EMPTY size (a '0' would silently satisfy any cap) and a non-empty basis"
fi

# The uncommitted arm: a script authored but not yet committed is still loaded
# from disk by the runtime, so it is measured — and the row says which bytes
# those are. Skipping it is the vacuity #522 is about.
T1F_LOOSE_LINE="$(wf_script_verdict "$T1F_REPO" uncommitted.js 1000)"
T1F_LOOSE_EXPECT="$(t1f_worktree_bytes "$T1F_REPO/uncommitted.js")"
if [ "$(wf_verdict_field "$T1F_LOOSE_LINE" 1)" = "ok" ] \
   && [ -n "$T1F_LOOSE_EXPECT" ] && [ "$(wf_verdict_field "$T1F_LOOSE_LINE" 2)" = "$T1F_LOOSE_EXPECT" ] \
   && case "$(wf_verdict_field "$T1F_LOOSE_LINE" 3)" in *"no blob at HEAD"*) true ;; *) false ;; esac; then
  pass "T1.f11 a file with no blob at HEAD is measured from the worktree (${T1F_LOOSE_EXPECT} B) and the basis says so"
else
  fail "T1.f11 an uncommitted file gave '$T1F_LOOSE_LINE' — expected verdict 'ok', size '$T1F_LOOSE_EXPECT' and a basis containing 'no blob at HEAD'"
fi

# --- T1.c7 / T1.c8: structural guards over the live measurement region -------
# Both must sit BELOW the region they slice: awk exits at the first END match,
# so the guards' own marker literals are never reachable and the region can
# never extract itself.
#
# The anchors are pinned to a WHOLE-LINE comment (`^# === …`), not to the bare
# phrase. Measured while writing this: an unanchored `/=== BEGIN …/` also
# matched a backtick-quoted MENTION of the marker in the header comment, so the
# slice began 200 lines early, ran to the first END match — this very line — and
# swallowed enough of the file to satisfy both rows with the region absent
# entirely. A guard whose slice can start somewhere other than the marker is
# a guard that passes on the violation.
T1_REGION="$(awk '/^# === BEGIN T1 size-ratchet measurement/{a=1} a{print} a && /^# === END T1 size-ratchet measurement/{exit}' "$THIS_FILE")"
if [ -z "$T1_REGION" ]; then
  fail "T1.c7 the T1 size-ratchet measurement region is EMPTY — its BEGIN/END markers are gone, and an empty region satisfies every check below vacuously (#347)"
elif ! grep -qF -- 'checkout_worst_case_bytes' <<<"$T1_REGION"; then
  fail "T1.c7 the T1 size-ratchet region no longer calls checkout_worst_case_bytes — the cap is being compared against checkout-translated bytes again (#522)"
elif ! grep -qF -- 'no blob at HEAD' <<<"$T1_REGION"; then
  fail "T1.c7 the T1 size-ratchet region no longer labels its uncommitted arm ('no blob at HEAD') — the printed row would not say which bytes it budgeted"
else
  pass "T1.c7 the T1 size-ratchet region measures via checkout_worst_case_bytes and labels its uncommitted arm"
fi

# Confinement: the checkout-translated byte count may appear ONLY inside that
# region, where it is the deliberate, labelled fallback. Assembled at runtime so
# this row cannot trip over its own source bytes.
WC_TOKEN="$(printf 'wc'; printf ' -c <')"
WC_ALL_COUNT="$(grep -c -F -- "$WC_TOKEN" "$THIS_FILE" || true)"
WC_REGION_COUNT="$(grep -c -F -- "$WC_TOKEN" <<<"$T1_REGION" || true)"
if [ "$WC_REGION_COUNT" -ge 1 ] && [ "$WC_ALL_COUNT" -eq "$WC_REGION_COUNT" ]; then
  pass "T1.c8 every checkout-translated byte count in this file ($WC_ALL_COUNT) sits inside the labelled measurement region"
else
  fail "T1.c8 this file has $WC_ALL_COUNT checkout-translated byte count(s) but only $WC_REGION_COUNT inside the labelled region — a size measured outside it is a platform-dependent budget (#522)"
fi

# ---------------------------------------------------------------------------
# Harness self-tests — lock every stub semantic + the preprocessing step.
# This is what keeps the suite non-vacuous while zero scripts exist.
# ---------------------------------------------------------------------------
echo "== T2/T3: harness self-tests (stub semantics + preprocessing) =="
if node "$HARNESS" self-test >"$TMPDIR_FIXTURES/selftest.out" 2>&1; then
  pass "harness self-test green ($(grep -c '^  PASS' "$TMPDIR_FIXTURES/selftest.out" || echo '?') stub-semantic asserts)"
else
  fail "harness self-test FAILED — stub drift or wrapper bug"
  grep '^  FAIL' "$TMPDIR_FIXTURES/selftest.out" | sed -n '1,10s/^/      /p'
fi

# ---------------------------------------------------------------------------
# #396 — the per-case dry-run budget is a HANG DETECTOR, not a stopwatch.
#
# H11 reddened otherwise-green PRs at random on `shape-checks-windows`. The
# harness is byte-identical across branches and the H11 block is self-contained
# (it builds its script from VALID_META and asserts on the recorders), so there
# is no data path from repo content into it; the same commit passed on a re-run
# twenty minutes later, with the whole T2/T3 block 6.3x slower on the failing
# attempt. The only wall-clock-sensitive input was a hard-coded 2000 ms
# runScript budget — a number that says nothing about correctness and
# everything about how contended the runner was.
#
# Two properties are locked here, and the second is why the first was hard to
# find: the suite surfaces harness failures with `grep '^  FAIL'` (above), so a
# cause printed on a continuation line never reaches the CI log. A silent
# budget overrun therefore read as "stub drift or wrapper bug".
# ---------------------------------------------------------------------------
echo "== #396: self-test budget is starvation-tolerant + failures name their cause =="

# Read the SHIPPED default with the override cleared, so a host-level export
# cannot mask a regression in the committed value.
HARNESS_BUDGET="$(env -u UBERDEV_HARNESS_TIMEOUT_MS \
  node -e 'process.stdout.write(String(require(process.argv[1]).RUN_TIMEOUT_MS))' "$HARNESS" 2>/dev/null)"
case "$HARNESS_BUDGET" in
  ''|*[!0-9]*)
    fail "#396.1 the harness exports no numeric RUN_TIMEOUT_MS (got '$HARNESS_BUDGET') — the dry-run budget is still a per-call-site literal"
    ;;
  *)
    if [ "$HARNESS_BUDGET" -ge 10000 ]; then
      pass "#396.1 the shipped dry-run budget is a generous hang detector (${HARNESS_BUDGET}ms >= 10000ms)"
    else
      fail "#396.1 the shipped dry-run budget is ${HARNESS_BUDGET}ms — tight enough for a starved runner to red a byte-identical harness (>= 10000ms required)"
    fi
    ;;
esac

# End-to-end proof the knob drives the REAL budget: at 1 ms every gated case
# (H7/H8 hold an agent() call open across a wall-clock probe) must overrun, on
# any machine — starvation can only make the overrun more certain, never less.
#
# The EVIDENCE is the per-case diagnostic, not the run summary. This row used to
# require `^  failed: [1-9]`, and that made it starvation-INTOLERANT — the exact
# defect #396 exists to retire, one layer up. At 1 ms under contention the
# self-test can abort before it prints its summary at all: rc is still 1, but
# there is no `failed:` line to match, so the row reds and blames a knob that is
# demonstrably working. Measured on a loaded host: 4 of 20 runs had rc=1 with no
# summary; every one of those 20 carried the diagnostic below. It red both CI
# jobs on byte-identical harnesses (ubuntu on #399, windows on main @ b2ad5db)
# while passing every unloaded local run.
#
# The diagnostic is also STRICTLY STRONGER than the summary was: it names the
# OVERRIDDEN value, so it can only appear if 1 reached the timeout path. A
# `failed:` count merely proved that something, anything, failed — which a stub
# drift or a wrapper bug would satisfy just as well.
TINY_SELFTEST="$TMPDIR_FIXTURES/selftest-tiny.out"
UBERDEV_HARNESS_TIMEOUT_MS=1 node "$HARNESS" self-test >"$TINY_SELFTEST" 2>&1
TINY_RC=$?
if [ "$TINY_RC" -eq 1 ] && grep -qF 'timed out after 1ms' "$TINY_SELFTEST"; then
  pass "#396.2 UBERDEV_HARNESS_TIMEOUT_MS drives the real per-case budget (1ms reds the self-test)"
else
  fail "#396.2 UBERDEV_HARNESS_TIMEOUT_MS is decorative (rc=$TINY_RC) — the budget is not sourced from one overridable knob"
fi

# Anti-vacuity for the row above: the diagnostic must carry the OVERRIDDEN value,
# so a harness that ignored the knob and timed out on its shipped default could
# not satisfy it. Pinned against the default, which must NOT appear at 1 ms.
if grep -qF "timed out after ${HARNESS_BUDGET}ms" "$TINY_SELFTEST"; then
  fail "#396.2a the 1ms run reports the shipped ${HARNESS_BUDGET}ms budget — the override never reached the timeout path"
else
  pass "#396.2a the 1ms run never reports the shipped ${HARNESS_BUDGET}ms default (the override, not the default, drove it)"
fi

TINY_FAILS="$(grep '^  FAIL' "$TINY_SELFTEST" 2>/dev/null || true)"
if grep -qF 'timed out after 1ms' <<<"$TINY_FAILS"; then
  pass "#396.3 a budget overrun names its cause on the FAIL line itself (so \`grep '^  FAIL'\` carries it into the CI log)"
else
  fail "#396.3 the self-test's FAIL lines print row names only — the errors array is swallowed, so a starved-runner timeout reads as stub drift"
fi

# Ratchet: every dry-run budget comes from the shared knob. A re-introduced
# literal (H11's 2000 was one) is invisible to the probes above, because a
# tight literal only reds under contention this suite cannot reproduce.
#
# STATEMENT-SCOPED, NOT LINE-SCOPED. `grep` matches per line, so the original
# line-anchored form required `runScript(` AND the numeric argument on the SAME
# line. The harness has exactly ONE multi-line `runScript(` call — the T3
# `validate` path in main(), i.e. the call that executes against every shipped
# skills/*/workflow.js in CI, which is precisely where #396's starvation flake
# reproduces. The line-anchored predicate was therefore disjoint from the drift
# this ratchet exists to find: mutating that call's `RUN_TIMEOUT_MS` to `2000`
# left the grep with zero hits, which this row read as clean and printed PASS.
# #396.2/#396.3 cannot compensate — both drive `self-test`, which never reaches
# main().
#
# So flatten first (`tr '\n' ' '`), the same idiom
# tests/skill-renderer-awk-collision.test.sh uses for its multi-line awk shape.
# Line numbers are sacrificed by the flatten; the matched call text is printed
# instead (`grep -n 'runScript(' tests/_workflow_harness.js` locates it).
#
# Why the argument list is bounded by `[^;]` — a JS STATEMENT boundary — and
# NOT by `[^)]`, measured on the mutated copy rather than assumed:
#   * `.*` after a flatten spans the entire file and would match digits from
#     anywhere, so an unbounded form is not an option.
#   * `[^)]` is TOO TIGHT for the one call site that matters: it carries a
#     nested `path.basename(file)` whose closing paren ends the character class
#     before the budget argument is ever reached, so a `[^)]`-bounded flatten
#     stays exactly as blind as the line-anchored form it replaced.
#   * `[^;]` reaches the end of the statement, nested parens included, and
#     catches it.
# The cost of `[^;]` is deliberate over-inclusion: a future call passing a
# numeric literal to some OTHER nested call (`runScript(src(x, 3), …)`) would
# also be flagged. For a ratchet that is the safe direction — the hit prints the
# offending call text and is fixed in one edit, whereas the failure mode being
# retired here was silent.
BUDGET_LITERAL_REGEX='runScript\([^;]*,[[:space:]]*[0-9]+[[:space:]]*\)'

# SSOT for the scan itself, not merely for its regex. The live ratchet below and
# the inverse fixtures after it call THIS function, so an edit that drops the
# `tr` flatten reds the fixtures too. A fixture that re-implemented the flatten
# inline would keep passing while the live scan silently went line-scoped again
# — which is the precise vacuity this whole block exists to retire (measured:
# with the fixtures flattening their own input, reverting the live scan to
# `grep -nE ... "$HARNESS"` left every #396.4* row green).
scan_budget_literals() {  # <file> -> one matched call fragment per line
  tr '\n' ' ' <"$1" | grep -oE "$BUDGET_LITERAL_REGEX" || true
}

BUDGET_LITERALS="$(scan_budget_literals "$HARNESS")"
if [ -z "$BUDGET_LITERALS" ]; then
  pass "#396.4 no runScript() call site carries a hard-coded numeric budget (statement-scoped scan)"
else
  fail "#396.4 hard-coded runScript() budget literal(s) — a starved runner reds them at random:"
  while IFS= read -r hit; do
    [ -n "$hit" ] && echo "        $hit"
  done <<<"$BUDGET_LITERALS"
  echo "        (locate with: grep -n 'runScript(' tests/_workflow_harness.js)"
fi

# Inverse fixtures for #396.4 — this ratchet went vacuous once by being
# line-scoped; these rows make it impossible for it to go vacuous the same way
# twice. The fixture reproduces the SHAPE of the real blind spot: the call split
# across two lines, with the nested `path.basename(file)` that defeats a
# `[^)]`-bounded scan. Built in $TMPDIR_FIXTURES — the real harness on disk is
# never mutated.
BUDGET_FIXTURE_BAD="$TMPDIR_FIXTURES/budget-literal-multiline.js"
{
  echo '      const { errors, record } = await runScript('
  echo '        source, { args: argsValue }, `${path.basename(file)} [args:${shapeName}]`, 2000);'
} > "$BUDGET_FIXTURE_BAD"

if [ -n "$(scan_budget_literals "$BUDGET_FIXTURE_BAD")" ]; then
  pass "#396.4a the live scan flags a TWO-LINE runScript() call carrying a numeric budget"
else
  fail "#396.4a the live scan MISSES a two-line runScript() budget literal — it has gone line-scoped again, and the harness's only multi-line call site (the T3 validate path that runs against every shipped workflow.js) is invisible to #396.4"
fi

# Pins that the fixture is genuinely TWO-LINE-shaped, so #396.4a cannot be
# satisfied by a fixture someone quietly collapsed onto one line: the SAME
# regex applied WITHOUT the flatten must still miss it. That is what isolates
# the flatten as the load-bearing half. Deliberately re-uses BUDGET_LITERAL_REGEX
# rather than an independent literal, so narrowing the regex re-evaluates both
# rows consistently instead of letting them drift apart.
if grep -qE "$BUDGET_LITERAL_REGEX" "$BUDGET_FIXTURE_BAD"; then
  fail "#396.4b the fixture is no longer multi-line — an unflattened grep matches it, so #396.4a no longer proves the flatten is load-bearing"
else
  pass "#396.4b the same regex without the flatten misses that fixture (the flatten is what buys the catch)"
fi

# Over-breadth guard: the SHIPPED shape (budget sourced from the knob) split
# across the same two lines must NOT be flagged, or #396.4 reds CI on correct
# code and teaches contributors to distrust it.
BUDGET_FIXTURE_SAFE="$TMPDIR_FIXTURES/budget-knob-multiline.js"
{
  echo '      const { errors, record } = await runScript('
  echo '        source, { args: argsValue }, `${path.basename(file)} [args:${shapeName}]`, RUN_TIMEOUT_MS);'
} > "$BUDGET_FIXTURE_SAFE"
if [ -n "$(scan_budget_literals "$BUDGET_FIXTURE_SAFE")" ]; then
  fail "#396.4c the live scan false-positives on a two-line runScript() that sources its budget from RUN_TIMEOUT_MS — #396.4 would red CI on the shipped shape"
else
  pass "#396.4c the live scan spares a two-line runScript() whose budget comes from the shared knob"
fi

# An unparseable override must refuse loudly: silently falling back to the
# default would run the whole suite under a budget nobody chose.
BAD_BUDGET_OUT="$TMPDIR_FIXTURES/selftest-bad-budget.out"
UBERDEV_HARNESS_TIMEOUT_MS=soon node "$HARNESS" self-test >"$BAD_BUDGET_OUT" 2>&1
BAD_BUDGET_RC=$?
if [ "$BAD_BUDGET_RC" -eq 2 ] && grep -qF 'UBERDEV_HARNESS_TIMEOUT_MS' "$BAD_BUDGET_OUT"; then
  pass "#396.5 an unparseable UBERDEV_HARNESS_TIMEOUT_MS refuses with rc=2 and names the variable"
else
  fail "#396.5 an unparseable UBERDEV_HARNESS_TIMEOUT_MS gave rc=$BAD_BUDGET_RC — it must refuse loudly, not fall back to a budget nobody chose"
fi

# Harness CLI contract controls (the per-script loop below relies on these
# exit codes; lock them against harness refactors).
GOOD_FLOW="$TMPDIR_FIXTURES/good-flow.js"
{
  echo '/* META-BEGIN */'
  echo 'export const meta = { "name": "cli-control", "description": "harness CLI control fixture", "phases": ["Solo"] };'
  echo '/* META-END */'
  echo 'phase("Solo");'
  # The fixture must CONSUME its args, because that is now part of the contract
  # it is controlling for: the runtime passes `args` as a JSON string, and the
  # harness requires proof the envelope was read (a script that drops it
  # silently no-ops rather than failing). Normalising both shapes here is the
  # same two lines every shipped workflow.js carries.
  echo 'const _a = (typeof args === "string") ? JSON.parse(args) : (args || {});'
  echo 'const r = await agent("control prompt", { label: "ctl" });'
  echo 'log("run:" + (_a.run_id || "") + " done:" + JSON.stringify(r));'
} > "$GOOD_FLOW"
if node "$HARNESS" validate "$GOOD_FLOW" >/dev/null 2>&1; then
  pass "T2/T3.c1 harness validate exits 0 on a conforming script"
else
  fail "T2/T3.c1 harness validate rejected a conforming control fixture"
fi

# T2/T3.c1b — the args-consumption oracle must RED on a script that guards with
# `typeof args === "object"`. That guard is what shipped in every workflow.js
# through v0.42.1: the runtime passes args as a JSON STRING, so the guard fell
# through to {} and every migrated pipeline returned success having dispatched
# nothing. Running both arg shapes does NOT catch it on its own (a silent no-op
# raises no error) — only requiring proof of consumption does.
ARGS_DROPPER="$TMPDIR_FIXTURES/args-dropper.js"
{
  echo '/* META-BEGIN */'
  echo 'export const meta = { "name": "args-dropper", "description": "object-only args guard", "phases": ["Solo"] };'
  echo '/* META-END */'
  echo 'const A = (args && typeof args === "object") ? args : {};'
  echo 'phase("Solo");'
  echo 'await agent("control prompt", { label: "ctl" });'
  echo 'log("run:" + (A.run_id || ""));'
} > "$ARGS_DROPPER"
if node "$HARNESS" validate "$ARGS_DROPPER" >/dev/null 2>&1; then
  fail "T2/T3.c1b args-consumption oracle MISSED an object-only args guard (the v0.42.1 silent-no-op bug would ship again)"
else
  pass "T2/T3.c1b args-consumption oracle reds on an object-only args guard"
fi

BAD_META="$TMPDIR_FIXTURES/bad-meta.js"
printf 'const meta = { name: "x" };\n' > "$BAD_META"
if node "$HARNESS" validate "$BAD_META" >/dev/null 2>&1; then
  fail "T2/T3.c2 harness validate must exit non-zero when the META markers are missing"
else
  pass "T2/T3.c2 harness validate reds on missing META markers"
fi

UNDECLARED_PHASE="$TMPDIR_FIXTURES/undeclared-phase.js"
{
  echo '/* META-BEGIN */'
  echo 'export const meta = { "name": "cli-control-2", "description": "phase-discipline control", "phases": ["Declared"] };'
  echo '/* META-END */'
  echo 'phase("Undeclared");'
} > "$UNDECLARED_PHASE"
if node "$HARNESS" validate "$UNDECLARED_PHASE" >/dev/null 2>&1; then
  fail "T2/T3.c3 harness validate must red on a phase() literal missing from meta.phases"
else
  pass "T2/T3.c3 harness validate reds on an undeclared phase() literal"
fi

# ---------------------------------------------------------------------------
# T2 + T3 per-script (meta shape, phase discipline, dry-run under stubs).
# ---------------------------------------------------------------------------
echo "== T2/T3: per-script validate =="
if [ "$SCRIPT_COUNT" -eq 0 ]; then
  pass "T2/T3 notice: no workflow scripts on disk yet — per-script validate vacuously green"
else
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    base="${script#"$REPO_ROOT"/}"
    if node "$HARNESS" validate "$script" >"$TMPDIR_FIXTURES/validate.out" 2>&1; then
      pass "T2/T3 $base: meta valid + dry-run clean"
    else
      fail "T2/T3 $base: validate failed"
      sed -n '1,10s/^/        /p' "$TMPDIR_FIXTURES/validate.out"
    fi
  done < "$SCRIPTS_FILE"
fi

# ---------------------------------------------------------------------------
# T4 — shared-snippet drift guard (controls always run; cross-script run
# only when scripts exist).
# ---------------------------------------------------------------------------
echo "== T4: shared-snippet drift guard =="

DRIFT_A="$TMPDIR_FIXTURES/drift-a.js"
DRIFT_B="$TMPDIR_FIXTURES/drift-b.js"
{
  echo '// === SHARED:envelope v1 ==='
  echo 'const WRAP = "begin";'
  echo '// === END SHARED ==='
} > "$DRIFT_A"
{
  echo '// === SHARED:envelope v1 ==='
  echo 'const WRAP = "BEGIN";'
  echo '// === END SHARED ==='
} > "$DRIFT_B"
if node "$HARNESS" shared-drift "$DRIFT_A" "$DRIFT_B" >/dev/null 2>&1; then
  fail "T4.c1 shared-drift must red on a same-name+version block that drifted by one byte"
else
  pass "T4.c1 shared-drift reds on byte drift in same-name+version SHARED blocks"
fi
cp "$DRIFT_A" "$DRIFT_B"
if node "$HARNESS" shared-drift "$DRIFT_A" "$DRIFT_B" >/dev/null 2>&1; then
  pass "T4.c2 shared-drift passes byte-identical SHARED blocks"
else
  fail "T4.c2 shared-drift rejected byte-identical SHARED blocks"
fi

if [ "$SCRIPT_COUNT" -eq 0 ]; then
  pass "T4 notice: no workflow scripts on disk yet — cross-script drift check vacuously green"
else
  # Build the argv list defensively (paths may contain spaces).
  drift_args=()
  while IFS= read -r script; do
    [ -n "$script" ] && drift_args+=("$script")
  done < "$SCRIPTS_FILE"
  if node "$HARNESS" shared-drift "${drift_args[@]}" >"$TMPDIR_FIXTURES/drift.out" 2>&1; then
    pass "T4 cross-script SHARED blocks are byte-identical"
  else
    fail "T4 SHARED block drift across workflow scripts"
    sed -n '1,10s/^/        /p' "$TMPDIR_FIXTURES/drift.out"
  fi
fi

# ---------------------------------------------------------------------------
# §4.2 shape guard — workflow.js cannot ship without its SKILL.md carrying
# BOTH the Workflow invocation block and the No-Workflow fallback section.
# Vacuous-pass today (zero scripts); load-bearing from Phase 2 on.
# ---------------------------------------------------------------------------
echo "== §4.2: Workflow opt-in + No-Workflow fallback shape guard =="

# RFC 0012 §4.1 existence-guard detector (shared by the per-script loop and the
# control fixtures below). Prints "inline"/"variable" + exit 0 when the SKILL.md
# carries a LIVE `[ -f ...workflow.js ]` preflight guard; exit 1 otherwise. It
# strips backtick-quoted inline-code spans (so the §3.10 prose-claims-the-check
# class cannot satisfy it) and requires a real shell CONSEQUENCE (||/&&/then)
# after the test bracket.
skill_workflow_existence_guard() {
  local md="$1" decoded var
  decoded="$(sed -E 's/`[^`]*`//g' "$md")"
  # Form (a): one decoded line with a `[ -f` test + workflow.js + a consequence.
  if [ -n "$(grep -E '\[[[:space:]]+-f[[:space:]].*workflow\.js.*\][[:space:]]*(\|\||&&|;?[[:space:]]*then)' \
       <<<"$decoded")" ]; then
    echo inline; return 0
  fi
  # Form (b): a `VAR=...workflow.js` assignment + a `[ -f "$VAR" ]` test with a
  # consequence referencing that same variable.
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    if [ -n "$(grep -E "\[[[:space:]]+-f[[:space:]]+\"\\\$$var\"[[:space:]]+\][[:space:]]*(\|\||&&|;?[[:space:]]*then)" \
         <<<"$decoded")" ]; then
      echo variable; return 0
    fi
  done < <(printf '%s\n' "$decoded" | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^=]*workflow\.js' | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')
  return 1
}

GUARDED=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  case "$script" in
    */skills/*/workflow.js) ;;   # the guard applies to top-level skill scripts
    *) continue ;;
  esac
  GUARDED=$((GUARDED + 1))
  skill_md="$(dirname "$script")/SKILL.md"
  base="${script#"$REPO_ROOT"/}"
  if [ ! -r "$skill_md" ]; then
    fail "§4.2 $base: sibling SKILL.md missing — a workflow script must version with its skill"
    continue
  fi
  if grep -qE 'Workflow\(' "$skill_md" && grep -qF 'workflow.js' "$skill_md"; then
    pass "§4.2 $base: SKILL.md carries the Workflow invocation block"
  else
    fail "§4.2 $base: SKILL.md lacks the Workflow invocation block (Workflow( + workflow.js scriptPath)"
  fi
  if grep -qF '## No-Workflow fallback' "$skill_md"; then
    pass "§4.2 $base: SKILL.md carries the '## No-Workflow fallback' section"
  else
    fail "§4.2 $base: SKILL.md lacks the mandatory '## No-Workflow fallback' section (DR-10)"
  fi
  # RFC 0012 §4.1: "The SKILL.md preflight validates
  # `[ -f "$CLAUDE_PLUGIN_ROOT/skills/<name>/workflow.js" ]` before mandating
  # the call." Assert an EXECUTABLE `[ -f ... workflow.js ]` test guard in the
  # preflight — NOT merely the prose claim or the scriptPath mandate — so a
  # missing/misnamed workflow.js on a target install refuses cleanly at
  # preflight instead of failing later at the runtime layer. Every future
  # migrated workflow.js inherits this requirement here (the §9 roadmap copies
  # the proving-ground template).
  #
  # CRITICAL discriminator (the §3.10 prose-claims-a-validation-that-doesn't-
  # exist class): the line-187/195-style prose ALSO contains a literal
  # `[ -f "...workflow.js" ]` inside backticks. skill_workflow_existence_guard
  # strips inline-code spans and requires a real shell consequence, so prose
  # alone cannot satisfy it (locked by the control fixtures below).
  if guard_form="$(skill_workflow_existence_guard "$skill_md")"; then
    pass "§4.2 $base: SKILL.md preflight runs the RFC §4.1 [ -f ...workflow.js ] existence guard ($guard_form form, real shell test — not prose)"
  else
    fail "§4.2 $base: SKILL.md preflight lacks the RFC §4.1 [ -f ...workflow.js ] existence guard before the Workflow mandate (a missing/misnamed workflow.js must refuse at preflight, not at runtime; a backtick-wrapped prose claim does NOT count)"
  fi
done < "$SCRIPTS_FILE"
if [ "$GUARDED" -eq 0 ]; then
  pass "§4.2 notice: no skills/*/workflow.js on disk yet — shape guard vacuously green"
fi

# §4.1 existence-guard control fixtures — keep skill_workflow_existence_guard
# non-vacuous and lock the prose-rejection (the §3.10 class). These run every
# invocation regardless of how many workflow.js files exist on disk.
PROSE_ONLY_MD="$TMPDIR_FIXTURES/prose-only-SKILL.md"
{
  echo 'The preflight validated `[ -f "$CLAUDE_PLUGIN_ROOT/skills/x/workflow.js" ]`. Relay the JSON into Workflow.'
  echo 'Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/x/workflow.js"}, <args>)'
} > "$PROSE_ONLY_MD"
if skill_workflow_existence_guard "$PROSE_ONLY_MD" >/dev/null; then
  fail "§4.1.c1 a backtick-wrapped PROSE [ -f ...workflow.js ] claim must NOT satisfy the existence guard (the §3.10 prose-claims-the-check class)"
else
  pass "§4.1.c1 prose-only [ -f ...workflow.js ] claim is rejected (real shell consequence required)"
fi

INLINE_GUARD_MD="$TMPDIR_FIXTURES/inline-guard-SKILL.md"
printf '%s\n' '[ -f "$CLAUDE_PLUGIN_ROOT/skills/x/workflow.js" ] || { echo missing >&2; exit 2; }' > "$INLINE_GUARD_MD"
if skill_workflow_existence_guard "$INLINE_GUARD_MD" >/dev/null; then
  pass "§4.1.c2 a live inline [ -f ...workflow.js ] || { exit; } guard is accepted"
else
  fail "§4.1.c2 a live inline [ -f ...workflow.js ] guard was rejected (false negative)"
fi

VAR_GUARD_MD="$TMPDIR_FIXTURES/var-guard-SKILL.md"
{
  echo 'WF="$CLAUDE_PLUGIN_ROOT/skills/x/workflow.js"'
  echo '[ -f "$WF" ] || { echo missing >&2; exit 2; }'
} > "$VAR_GUARD_MD"
if skill_workflow_existence_guard "$VAR_GUARD_MD" >/dev/null; then
  pass "§4.1.c3 a live variable-indirection [ -f \"\$VAR\" ] guard is accepted"
else
  fail "§4.1.c3 a live variable-indirection guard was rejected (false negative)"
fi

echo
echo "== #381 — the review-fleet default flip is coupled to the wiring =="
# lib/dispatch.sh has NO `workflow` provider arm by construction: reaching
# _uberdev_agent_dispatch_backend with backend=workflow is a declared wiring bug
# that fails loud. Every /review-pr and /simplify child still reaches it through
# uberdev_dispatch_child_capture, so resolving `workflow` for those two workflows
# BEFORE a command emits pipeline=review-fleet would fail after the RUN_ID
# reservation and the workspace prepare -- strictly worse than being unreachable,
# because it burns a real fanout's budget and leaves reservations behind.
#
# This guard is the mechanical form of that coupling, and it is BIDIRECTIONAL.
# It was written to red at the flip; the flip has now landed (#381 step 3), so
# the side it enforces has moved from "auto must stay OFF workflow" to "auto
# must resolve workflow" -- and if the wiring is ever ripped back out of the
# command files, it reds again from the other direction.
#
# It is a LIVE RESOLUTION PROBE now, not a grep over the arm's source. The old
# grep passed on the mere presence of the string `resolved="workflow"` anywhere
# in the ladder, which after the flip is true on a branch review-pr may never
# reach -- it would have gone green without proving the flip at all.
REVIEW_FLEET_EMITTED=0
for command_file in "$REPO_ROOT/plugins/uberdev/commands/review-pr.md" \
                    "$REPO_ROOT/plugins/uberdev/commands/simplify.md"; do
  if grep -Fq 'pipeline=review-fleet' "$command_file" \
     || grep -Fq 'uberdev_emit_workflow_args review-fleet' "$command_file"; then
    REVIEW_FLEET_EMITTED=1
  fi
done

# CODEX_HOME cleared, so the answer is the resolver's RULE and not this
# particular host's environment. #381 removed the
# `_uberdev_dispatch_codex_available` stub that used to sit here: the function
# was deleted with the transport, so redefining it was an inert no-op that made
# this probe read as though it forced a capability answer when it forced
# nothing. The resolution is now codex-independent by construction.
review_fleet_resolved() {  # WORKFLOW -> "<rc>:<resolved>"
  env -u CODEX_HOME bash -c '
    set +e
    . "$1" >/dev/null 2>&1
    unset UBERDEV_RESOLVED_BACKEND
    uberdev_dispatch_preflight "$2" >/dev/null 2>&1
    printf "%s:%s" "$?" "${UBERDEV_RESOLVED_BACKEND-}"
  ' _ "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" "$1"
}

for review_fleet_wf in review-pr simplify; do
  REVIEW_FLEET_RESOLUTION="$(review_fleet_resolved "$review_fleet_wf")"
  if [ "$REVIEW_FLEET_EMITTED" -eq 1 ]; then
    if [ "$REVIEW_FLEET_RESOLUTION" = "0:workflow" ]; then
      pass "#381 the command files emit review-fleet and auto resolves workflow for $review_fleet_wf"
    else
      fail "#381 the command files emit review-fleet but auto gave '$REVIEW_FLEET_RESOLUTION' for $review_fleet_wf"
    fi
  elif [ "$REVIEW_FLEET_RESOLUTION" = "0:workflow" ]; then
    fail "#381 auto resolves workflow for $review_fleet_wf but no command emits review-fleet — the halves have drifted apart"
  else
    pass "#381 no command emits review-fleet, so $review_fleet_wf auto stays off workflow"
  fi
done
if grep -Fq "backend 'workflow' is dispatched by the session's Workflow tool" \
     "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"; then
  pass "#381 _uberdev_agent_dispatch_backend keeps its loud workflow refusal"
else
  fail "#381 the loud workflow refusal in _uberdev_agent_dispatch_backend is gone"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
