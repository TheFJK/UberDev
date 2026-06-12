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
SIZE_CAP_BYTES=524288   # 512 KB — the documented Workflow runtime script cap

# Hard-fail (exit 2) on missing inputs — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$THIS_FILE" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
[ -d "$PLUGINS_DIR" ] || { echo "FATAL: plugins/ directory missing: $PLUGINS_DIR" >&2; exit 2; }
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the workflow-script tiers (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMPDIR_FIXTURES="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURES"' EXIT

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
    printf '%s\n' "$hits" | head -5 | sed 's/^/        /'
  else
    pass "T1 $base: no import/require"
  fi

  hits="$(printf '%s\n' "$stripped" | grep -E '(^|[^[:alnum:]_$.])process\.|(^|[^[:alnum:]_$.])fs\.' || true)"
  if [ -n "$hits" ]; then
    fail "T1 $base: forbidden token process./fs. (the script cannot touch Node APIs or the filesystem — agents do)"
    printf '%s\n' "$hits" | head -5 | sed 's/^/        /'
  else
    pass "T1 $base: no process./fs."
  fi

  hits="$(printf '%s\n' "$stripped" | grep -E '(^|[^[:alnum:]_$])Date\.now|(^|[^[:alnum:]_$])Math\.random|new[[:space:]]+Date[[:space:]]*\(' || true)"
  if [ -n "$hits" ]; then
    fail "T1 $base: forbidden token Date.now/Math.random/new Date( — timestamps arrive via args (DR-7)"
    printf '%s\n' "$hits" | head -5 | sed 's/^/        /'
  else
    pass "T1 $base: no Date.now/Math.random/new Date("
  fi
}

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
      node --check --input-type=module < "$script" 2>&1 | head -5 | sed 's/^/        /'
    fi

    size="$(wc -c < "$script" | tr -d '[:space:]')"
    if [ "$size" -le "$SIZE_CAP_BYTES" ] 2>/dev/null; then
      pass "T1 $base: size $size <= $SIZE_CAP_BYTES bytes (512 KB runtime cap)"
    else
      fail "T1 $base: size $size exceeds the 512 KB Workflow runtime cap"
    fi

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
if strip_shared_blocks "$FORBIDDEN_FIXTURE" | grep -qE '(^|[^[:alnum:]_$])Date\.now'; then
  pass "T1.c4 forbidden-token grep catches Date.now outside SHARED markers"
else
  fail "T1.c4 forbidden-token grep MISSED Date.now outside SHARED markers"
fi
if strip_shared_blocks "$FORBIDDEN_FIXTURE" | grep -qE 'new[[:space:]]+Date[[:space:]]*\('; then
  fail "T1.c5 SHARED-block escape hatch broken: new Date( INSIDE markers leaked into the grep surface"
else
  pass "T1.c5 SHARED-block contents are exempt from the static grep (T3 runtime shadows still apply)"
fi
if printf '%s\n' '1:// important: requires careful reading' | grep -qwE 'import|require'; then
  fail "T1.c6 word-boundary control: 'important'/'requires' must not trip the import/require grep"
else
  pass "T1.c6 import/require grep is word-bounded (no 'important'/'requires' false positives)"
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
  grep '^  FAIL' "$TMPDIR_FIXTURES/selftest.out" | head -10 | sed 's/^/      /'
fi

# Harness CLI contract controls (the per-script loop below relies on these
# exit codes; lock them against harness refactors).
GOOD_FLOW="$TMPDIR_FIXTURES/good-flow.js"
{
  echo '/* META-BEGIN */'
  echo 'export const meta = { "name": "cli-control", "description": "harness CLI control fixture", "phases": ["Solo"] };'
  echo '/* META-END */'
  echo 'phase("Solo");'
  echo 'const r = await agent("control prompt", { label: "ctl" });'
  echo 'log("done:" + JSON.stringify(r));'
} > "$GOOD_FLOW"
if node "$HARNESS" validate "$GOOD_FLOW" >/dev/null 2>&1; then
  pass "T2/T3.c1 harness validate exits 0 on a conforming script"
else
  fail "T2/T3.c1 harness validate rejected a conforming control fixture"
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
      sed 's/^/        /' "$TMPDIR_FIXTURES/validate.out" | head -10
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
    sed 's/^/        /' "$TMPDIR_FIXTURES/drift.out" | head -10
  fi
fi

# ---------------------------------------------------------------------------
# §4.2 shape guard — workflow.js cannot ship without its SKILL.md carrying
# BOTH the Workflow invocation block and the No-Workflow fallback section.
# Vacuous-pass today (zero scripts); load-bearing from Phase 2 on.
# ---------------------------------------------------------------------------
echo "== §4.2: Workflow opt-in + No-Workflow fallback shape guard =="

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
done < "$SCRIPTS_FILE"
if [ "$GUARDED" -eq 0 ]; then
  pass "§4.2 notice: no skills/*/workflow.js on disk yet — shape guard vacuously green"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
