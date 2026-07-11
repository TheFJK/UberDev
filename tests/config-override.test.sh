#!/usr/bin/env bash
# Tests for uberdev.local.md knobs expansion.
#
# Sections:
#   U1  — config-read.sh exports the documented public surface
#   U2  — uberdev_read_int_in_range: env-precedence, file fallback, default,
#         non-integer warn, out-of-range warn, sentinel cache (one-warn-per-run)
#   U3  — uberdev_read_enum: exact-match, invalid_enum warn, env-precedence
#   U4  — uberdev_read_string: regex_mismatch warn
#   U5  — uberdev_tier_rank / uberdev_tier_name round-trip
#   U6  — uberdev_clamp_tier: floor lift, ceiling drop, inversion warn,
#         asymmetric (only-floor / only-ceiling)
#   U7  — verbatim warning format matches D7 spec literal
#   U8  — audit-event line shape on .uberdev/audit.jsonl when dir present
#
# Section names beginning with `I` (I1..I8) are reserved for integration
# tests added by Task 7 in wave-3, after the consumer-side wirings (Tasks
# 2-5) have landed.
#
# Bash 3.2 compatible (associative arrays not used; array push via +=).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/plugins/uberdev/lib/config-read.sh"

for f in "$HELPER" "$REPO_ROOT/.github/workflows/test.yml"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

SKILL_DIR="$REPO_ROOT/plugins/uberdev/skills"
# CONFIG_REF (#309 hook diet): the user-facing config schema moved out of
# using-uberdev/SKILL.md into references/configuration.md; I6 asserts target it.
CONFIG_REF="$SKILL_DIR/using-uberdev/references/configuration.md"
for f in "$SKILL_DIR/solve-pipeline/SKILL.md" \
         "$SKILL_DIR/orchestrator/SKILL.md" \
         "$SKILL_DIR/post-impl-review/SKILL.md" \
         "$SKILL_DIR/merge-pipeline/SKILL.md" \
         "$SKILL_DIR/using-uberdev/SKILL.md" \
         "$CONFIG_REF"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

assert_grep_in() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    pass "$desc"
  else
    fail "$desc (file=$file pattern=$pattern)"
  fi
}

# _isolate runs a snippet in a clean PWD with a fresh HOME and an empty
# config file (caller may overwrite). Sentinels reset by running each
# snippet in a sub-shell.
_isolate() {
  local body="$1"
  local sandbox stderr
  sandbox="$(mktemp -d)"
  stderr="$(mktemp)"
  mkdir -p "$sandbox/.claude"
  : > "$sandbox/.claude/uberdev.local.md"
  (
    cd "$sandbox"
    # shellcheck source=/dev/null
    . "$HELPER"
    eval "$body"
  ) 2>"$stderr"
  _LAST_STDERR="$(cat "$stderr")"
  rm -rf "$sandbox" "$stderr"
}

echo "== U1: config-read.sh exports documented public surface =="
for fn in uberdev_read_int_in_range uberdev_read_enum uberdev_read_string uberdev_read_model_routing \
          uberdev_tier_rank uberdev_tier_name uberdev_clamp_tier; do
  if grep -qE "^${fn}\(\)" "$HELPER"; then
    pass "U1: function ${fn}() declared"
  else
    fail "U1: function ${fn}() missing"
  fi
done

if grep -qE '^_UBERDEV_WARN_FORMAT=' "$HELPER"; then
  pass "U1: warning-format constant declared"
else
  fail "U1: warning-format constant missing"
fi

echo
echo "== U2: uberdev_read_int_in_range precedence + validation + sentinel =="

# U2a: empty config file + no env => default
_isolate '
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "U2a: absent key -> default 6" || fail "U2a: absent key did not return default"

# U2b: config-file value used when env unset
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 4
---
EOF
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "4" ] || exit 1
'
[ $? -eq 0 ] && pass "U2b: config value 4 used when env unset" || fail "U2b: config value not used"

# U2c: env wins over config
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 4
---
EOF
  UBERDEV_FANOUT_RESEARCH=2 out="$(UBERDEV_FANOUT_RESEARCH=2 uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "2" ] || exit 1
'
[ $? -eq 0 ] && pass "U2c: env overrides config" || fail "U2c: env did not override config"

# U2d: out-of-range high warns + default
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 999
---
EOF
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "U2d: out-of-range high -> default" || fail "U2d: out-of-range high not defaulted"
printf "%s" "$_LAST_STDERR" | grep -qE "fanout_concurrency.research = .999. is invalid \(out_of_range\)" \
  && pass "U2d: stderr carries out_of_range warning" \
  || fail "U2d: out_of_range stderr line missing"

# U2e: out-of-range low (0) warns + default
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 0
---
EOF
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "U2e: out-of-range low (0) -> default" || fail "U2e: zero not defaulted"

# U2f: non-integer warns + default
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: abc
---
EOF
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "U2f: non-integer abc -> default" || fail "U2f: non-integer not defaulted"
printf "%s" "$_LAST_STDERR" | grep -qE "non_integer" \
  && pass "U2f: stderr non_integer reason" \
  || fail "U2f: non_integer reason missing"

# U2g: leading-zero rejected (defensive against octal interpretation)
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 007
---
EOF
  out="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ "$out" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "U2g: leading-zero 007 rejected" || fail "U2g: leading-zero accepted"

# U2h: sentinel cache - second call within same shell does NOT re-warn
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 999
---
EOF
  uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6 >/dev/null
  uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6 >/dev/null
'
warn_count=$(printf "%s\n" "$_LAST_STDERR" | grep -cE "fanout_concurrency.research = .999. is invalid")
[ "$warn_count" = "1" ] && pass "U2h: sentinel emits exactly one warning across two reads" \
  || fail "U2h: expected 1 warning, got $warn_count"

echo
echo "== U3: uberdev_read_enum =="
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
solve_tier_floor: medium
---
EOF
  out="$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium|large" trivial)"
  [ "$out" = "medium" ] || exit 1
'
[ $? -eq 0 ] && pass "U3a: valid enum medium accepted" || fail "U3a: enum medium rejected"

_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
solve_tier_floor: SMALL
---
EOF
  out="$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium|large" trivial)"
  [ "$out" = "trivial" ] || exit 1
'
[ $? -eq 0 ] && pass "U3b: case-sensitive reject SMALL -> default trivial" || fail "U3b: SMALL not rejected"
printf "%s" "$_LAST_STDERR" | grep -qE "invalid_enum" \
  && pass "U3b: invalid_enum reason emitted" \
  || fail "U3b: invalid_enum reason missing"

echo
echo "== U4: uberdev_read_string =="
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
integration_branch: feature/long-name
---
EOF
  out="$(uberdev_read_string integration_branch UBERDEV_INTEGRATION_BRANCH "^[A-Za-z0-9._/-]{1,255}$" main)"
  [ "$out" = "feature/long-name" ] || exit 1
'
[ $? -eq 0 ] && pass "U4a: valid branch name passes regex" || fail "U4a: valid branch name rejected"

_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
integration_branch: bad name with spaces
---
EOF
  out="$(uberdev_read_string integration_branch UBERDEV_INTEGRATION_BRANCH "^[A-Za-z0-9._/-]{1,255}$" main)"
  [ "$out" = "main" ] || exit 1
'
[ $? -eq 0 ] && pass "U4b: invalid branch name -> default main" || fail "U4b: invalid branch name accepted"
printf "%s" "$_LAST_STDERR" | grep -qE "regex_mismatch" \
  && pass "U4b: regex_mismatch reason emitted" \
  || fail "U4b: regex_mismatch reason missing"

echo
echo "== U5: uberdev_tier_rank / uberdev_tier_name round-trip =="
_isolate '
  [ "$(uberdev_tier_rank trivial)" = "0" ] || exit 1
  [ "$(uberdev_tier_rank small)"   = "1" ] || exit 1
  [ "$(uberdev_tier_rank medium)"  = "2" ] || exit 1
  [ "$(uberdev_tier_rank large)"   = "3" ] || exit 1
  [ "$(uberdev_tier_name 0)"       = "trivial" ] || exit 1
  [ "$(uberdev_tier_name 3)"       = "large" ] || exit 1
  [ -z "$(uberdev_tier_rank Trivial)" ] || exit 1
  [ -z "$(uberdev_tier_name 9)" ]       || exit 1
'
[ $? -eq 0 ] && pass "U5: tier rank/name round-trip + reject capitalised + reject out-of-domain" \
  || fail "U5: tier rank/name round-trip failed"

echo
echo "== U6: uberdev_clamp_tier =="
_isolate '
  [ "$(uberdev_clamp_tier small medium large)" = "medium" ] || exit 1   # floor lifts
  [ "$(uberdev_clamp_tier large trivial small)" = "small" ] || exit 1   # ceiling drops
  [ "$(uberdev_clamp_tier medium trivial large)" = "medium" ] || exit 1 # in-band passthrough
  [ "$(uberdev_clamp_tier large medium "")"     = "large" ] || exit 1   # only-floor (ceiling unset)
  [ "$(uberdev_clamp_tier trivial "" small)"    = "trivial" ] || exit 1 # only-ceiling above tier
  [ "$(uberdev_clamp_tier medium large small)"  = "medium" ] || exit 1  # inverted -> passthrough
'
[ $? -eq 0 ] && pass "U6: clamp_tier matrix passes (floor/ceiling/inverted/asymmetric)" \
  || fail "U6: clamp_tier matrix failed"

_isolate '
  uberdev_clamp_tier medium large small >/dev/null
'
printf "%s" "$_LAST_STDERR" | grep -qE "floor_gt_ceiling" \
  && pass "U6b: inversion emits floor_gt_ceiling reason" \
  || fail "U6b: inversion warning missing"

echo
echo "== U7: warning format matches D7 verbatim =="
# Expected literal (from spec D7): warning: <KEY> = '<VAL>' is invalid (<REASON>); falling back to default <DEFAULT>
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 999
---
EOF
  uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6 >/dev/null
'
printf "%s" "$_LAST_STDERR" \
  | grep -qE "^warning: fanout_concurrency.research = '999' is invalid \(out_of_range\); falling back to default 6$" \
  && pass "U7: warning format byte-matches D7 spec" \
  || fail "U7: warning format diverged from D7 spec"

echo
echo "== U8: audit-event JSON shape on .uberdev/audit.jsonl =="
_isolate '
  mkdir -p .uberdev
  cat > .claude/uberdev.local.md <<EOF
---
fanout_concurrency:
  research: 999
---
EOF
  uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6 >/dev/null
  cat .uberdev/audit.jsonl > /tmp/uberdev-audit-snapshot
'
if [ -s /tmp/uberdev-audit-snapshot ]; then
  grep -qE '"event":"uberdev_config_invalid"' /tmp/uberdev-audit-snapshot \
    && pass "U8: audit line carries uberdev_config_invalid event type" \
    || fail "U8: audit event type missing"
  grep -qE '"key":"fanout_concurrency.research"' /tmp/uberdev-audit-snapshot \
    && pass "U8: audit line carries key" \
    || fail "U8: audit key missing"
  grep -qE '"reason":"out_of_range"' /tmp/uberdev-audit-snapshot \
    && pass "U8: audit line carries reason" \
    || fail "U8: audit reason missing"
  rm -f /tmp/uberdev-audit-snapshot
else
  fail "U8: audit.jsonl was not written"
fi

echo
echo "== I1: solve-pipeline tier-clamp wiring (Task 2) =="
# #304 / RFC 0012 §3.4: the tier-clamp wiring lives in lib/solve-launcher.sh
# (the executable hoisted out of solve-pipeline/SKILL.md).
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh" \
  'uberdev_read_enum solve_tier_floor[[:space:]]+SOLVE_TIER_FLOOR' \
  "I1a: solve-pipeline reads solve_tier_floor with SOLVE_TIER_FLOOR env"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh" \
  'uberdev_read_enum solve_tier_ceiling[[:space:]]+SOLVE_TIER_CEILING' \
  "I1b: solve-pipeline reads solve_tier_ceiling with SOLVE_TIER_CEILING env"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh" \
  'uberdev_clamp_tier "\$TIER" "\$FLOOR" "\$CEILING"' \
  "I1c: solve-pipeline calls uberdev_clamp_tier with TIER/FLOOR/CEILING"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh" \
  'trivial\|small\|medium\|large' \
  "I1d: solve-pipeline enum allows all four tier names"

echo
echo "== I2: solve-pipeline claude --bg dispatch timeout-wrap (v0.22.0) =="
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'uberdev_read_int_in_range command_timeouts.solve[[:space:]]+UBERDEV_SOLVE_TIMEOUT[[:space:]]+60[[:space:]]+86400[[:space:]]+3600' \
  "I2a: launcher reads command_timeouts.solve with bounds [60,86400] default 3600"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'command -v timeout' \
  "I2b: launcher checks timeout(1) availability"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'command -v gtimeout' \
  "I2c: launcher probes gtimeout fallback (Homebrew coreutils installs the macOS binary as gtimeout, not timeout)"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  '"\$TIMEOUT_BIN" "\$SOLVE_TIMEOUT" env "\${BG_TURBO_ENV\[@\]}" claude --bg' \
  "I2d: bg dispatch wraps claude --bg in timeout(1)/gtimeout with env(1)-mediated zsh-safe BG_TURBO_ENV[@] inline-prefix (#97 — env(1) is required because timeout(1) sits between the shell and the env-prefix slot and would otherwise consume the KEY=value tokens as argv; array form preserves zsh SH_WORD_SPLIT=off compatibility)"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'brew install coreutils' \
  "I2e: missing-timeout warning includes remediation pointer"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'if \[\[ -n "\$TIMEOUT_BIN" \]\]; then' \
  "I2f: launcher guards wrap branch with -n TIMEOUT_BIN check (prevents silent regression on guard inversion/removal)"
assert_grep_in "$REPO_ROOT/plugins/uberdev/lib/dispatch.sh" \
  'case "\$BG_PROMPT_MODE" in' \
  "I2g: bg dispatch uses three-arm BG_PROMPT_MODE case-switch (file / stdin / argv)"

echo
echo "== I3: orchestrator research fanout cap (Task 3) =="
assert_grep_in "$SKILL_DIR/orchestrator/SKILL.md" \
  'uberdev_read_int_in_range fanout_concurrency.research[[:space:]]+UBERDEV_FANOUT_RESEARCH[[:space:]]+1[[:space:]]+50[[:space:]]+6' \
  "I3a: orchestrator reads fanout_concurrency.research with bounds [1,50] default 6"
assert_grep_in "$SKILL_DIR/orchestrator/SKILL.md" \
  'FANOUT_RESEARCH_CAP' \
  "I3b: orchestrator binds FANOUT_RESEARCH_CAP shell var"
assert_grep_in "$SKILL_DIR/orchestrator/SKILL.md" \
  'ceil\(6 / CAP\)' \
  "I3c: orchestrator documents ceil(6 / CAP) wave chunking"

echo
echo "== I4: post-impl-review fanout cap + review_pr advisory (Task 4) =="
assert_grep_in "$SKILL_DIR/post-impl-review/SKILL.md" \
  'uberdev_read_int_in_range fanout_concurrency.post_impl_review[[:space:]]+UBERDEV_FANOUT_POST_IMPL_REVIEW[[:space:]]+1[[:space:]]+50[[:space:]]+6' \
  "I4a: post-impl-review reads fanout_concurrency.post_impl_review with bounds [1,50] default 6"
assert_grep_in "$SKILL_DIR/post-impl-review/SKILL.md" \
  'POST_IMPL_REVIEW_CAP' \
  "I4b: post-impl-review binds POST_IMPL_REVIEW_CAP shell var"
assert_grep_in "$CONFIG_REF" \
  'post_impl_review:[[:space:]]+6[[:space:]]+# int \[1, 50\]; post-impl-review reviewer fanout cap; default 6;' \
  "I4b2: config reference documents post_impl_review default 6"
assert_grep_in "$SKILL_DIR/post-impl-review/SKILL.md" \
  'uberdev_read_int_in_range command_timeouts.review_pr[[:space:]]+UBERDEV_REVIEW_PR_TIMEOUT[[:space:]]+60[[:space:]]+86400[[:space:]]+900' \
  "I4c: post-impl-review reads command_timeouts.review_pr with bounds [60,86400] default 900"
assert_grep_in "$SKILL_DIR/post-impl-review/SKILL.md" \
  'advisory' \
  "I4d: post-impl-review documents advisory-only enforcement"

echo
echo "== I5: merge fanout caps + advisory + Constants update (Task 5) =="
assert_grep_in "$SKILL_DIR/merge-pipeline/SKILL.md" \
  'uberdev_read_int_in_range fanout_concurrency.merge_strategy[[:space:]]+UBERDEV_FANOUT_MERGE_STRATEGY[[:space:]]+1[[:space:]]+50[[:space:]]+10' \
  "I5a: merge reads fanout_concurrency.merge_strategy with bounds [1,50] default 10"
assert_grep_in "$SKILL_DIR/merge-pipeline/SKILL.md" \
  'uberdev_read_int_in_range fanout_concurrency.conflict_resolver[[:space:]]+UBERDEV_FANOUT_CONFLICT_RESOLVER[[:space:]]+1[[:space:]]+50[[:space:]]+10' \
  "I5b: merge reads fanout_concurrency.conflict_resolver with bounds [1,50] default 10"
assert_grep_in "$SKILL_DIR/merge-pipeline/SKILL.md" \
  'CONFLICT_RESOLVER_CAP' \
  "I5c: merge binds CONFLICT_RESOLVER_CAP for Phase 3.3 chunking"
assert_grep_in "$SKILL_DIR/merge-pipeline/SKILL.md" \
  'uberdev_read_int_in_range command_timeouts.merge[[:space:]]+UBERDEV_MERGE_TIMEOUT[[:space:]]+60[[:space:]]+86400[[:space:]]+600' \
  "I5d: merge reads command_timeouts.merge with bounds [60,86400] default 600"
assert_grep_in "$SKILL_DIR/merge-pipeline/SKILL.md" \
  '\| `MAX_PARALLEL_AGENTS` \| resolved integer' \
  "I5e: Constants table row updated to 'resolved integer'"
if grep -qE 'out-of-scope for this issue' "$SKILL_DIR/merge-pipeline/SKILL.md"; then
  fail "I5f: obsolete 'out-of-scope for this issue' note still present"
else
  pass "I5f: obsolete 'out-of-scope for this issue' note removed"
fi

echo
echo "== I6: using-uberdev config reference YAML example + prose (Task 6) =="
# Re-pointed (#309 hook diet): the YAML example + key prose moved from
# using-uberdev/SKILL.md into references/configuration.md.
for key in solve_tier_floor solve_tier_ceiling \
           "fanout_concurrency:" "research:" "post_impl_review:" \
           "merge_strategy:" "conflict_resolver:" \
           "command_timeouts:" "solve:" "review_pr:" "merge:"; do
  assert_grep_in "$CONFIG_REF" \
    "$key" \
    "I6: YAML example mentions $key"
done

for env in SOLVE_TIER_FLOOR SOLVE_TIER_CEILING UBERDEV_FANOUT_RESEARCH \
           UBERDEV_FANOUT_POST_IMPL_REVIEW UBERDEV_FANOUT_MERGE_STRATEGY \
           UBERDEV_FANOUT_CONFLICT_RESOLVER UBERDEV_SOLVE_TIMEOUT \
           UBERDEV_REVIEW_PR_TIMEOUT UBERDEV_MERGE_TIMEOUT; do
  assert_grep_in "$CONFIG_REF" \
    "$env" \
    "I6: prose mentions env override $env"
done

assert_grep_in "$CONFIG_REF" \
  'ADVISORY-ONLY' \
  "I6: prose explicitly notes command_timeouts.{merge,review_pr} are ADVISORY-ONLY"
assert_grep_in "$CONFIG_REF" \
  'NEW default cap of 10' \
  "I6: prose calls out conflict_resolver introducing a NEW default cap of 10"
# The SKILL.md primer must still POINT at the moved schema (the model has to
# know where config docs live without the schema in context).
assert_grep_in "$SKILL_DIR/using-uberdev/SKILL.md" \
  'references/configuration\.md' \
  "I6: SKILL.md primer points at references/configuration.md"

echo
echo "== I7: backward compat — pre-existing configs unaffected =="
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
auto_install_aliases: false
integration_branch: develop
---
EOF
  out_floor="$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium|large" "")"
  out_ceiling="$(uberdev_read_enum solve_tier_ceiling SOLVE_TIER_CEILING "trivial|small|medium|large" "")"
  out_fanout="$(uberdev_read_int_in_range fanout_concurrency.research UBERDEV_FANOUT_RESEARCH 1 50 6)"
  [ -z "$out_floor" ] || exit 1
  [ -z "$out_ceiling" ] || exit 1
  [ "$out_fanout" = "6" ] || exit 1
'
[ $? -eq 0 ] && pass "I7a: pre-existing config + no new keys -> silent defaults" \
  || fail "I7a: pre-existing config did not return silent defaults"
printf "%s" "$_LAST_STDERR" | grep -qE "warning:" \
  && fail "I7b: stderr should be silent (no warnings) on pre-existing config" \
  || pass "I7b: stderr silent on pre-existing config"

_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
auto_confirm: true
solve_tier_floor: medium
---
EOF
  out_floor="$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium|large" "")"
  [ "$out_floor" = "medium" ] || exit 1
'
[ $? -eq 0 ] && pass "I7c: deprecated auto_confirm + new solve_tier_floor coexist" \
  || fail "I7c: coexistence with deprecated keys broken"

echo
echo "== I8: goal-pipeline reads goal.max_parallel + goal.barrier_timeout_s via uberdev_read_int_in_range (#211 AC1) =="
# The verbatim call shape is the test surface: an editor cannot widen the
# range or drop the default without tripping these greps.
GOAL_SKILL_PATH="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"

assert_grep_in "$GOAL_SKILL_PATH" \
  'uberdev_read_int_in_range goal\.max_parallel UBERDEV_GOAL_MAX_PARALLEL 1 10' \
  "I8.max-parallel-call-shape"
assert_grep_in "$GOAL_SKILL_PATH" \
  '_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL=3' \
  "I8.max-parallel-default-constant"

assert_grep_in "$GOAL_SKILL_PATH" \
  'uberdev_read_int_in_range goal\.barrier_timeout_s UBERDEV_GOAL_BARRIER_TIMEOUT_S 60 86400' \
  "I8.barrier-timeout-call-shape"
assert_grep_in "$GOAL_SKILL_PATH" \
  '_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S=14400' \
  "I8.barrier-timeout-default-constant"

# Env-precedence pattern: the verbatim UBERDEV_GOAL_*=${*_cli:-${UBERDEV_GOAL_*:-}} guard
# is the same shape Phase 0 uses for goal.max_cycles (line ~98) — a regression that
# silently drops the CLI flag in favor of the env var would break /goal --max-parallel=N.
assert_grep_in "$GOAL_SKILL_PATH" \
  'UBERDEV_GOAL_MAX_PARALLEL="\$\{max_parallel_cli:-\$\{UBERDEV_GOAL_MAX_PARALLEL:-\}\}"' \
  "I8.max-parallel-cli-env-precedence"
assert_grep_in "$GOAL_SKILL_PATH" \
  'UBERDEV_GOAL_BARRIER_TIMEOUT_S="\$\{barrier_timeout_cli:-\$\{UBERDEV_GOAL_BARRIER_TIMEOUT_S:-\}\}"' \
  "I8.barrier-timeout-cli-env-precedence"

echo
echo "== U9: auto_review_on_merge config key (#89) =="

# U9.1: default — neither env nor config sets the key -> 'false'
_isolate '
  out="$(uberdev_read_enum auto_review_on_merge UBERDEV_AUTO_REVIEW_ON_MERGE "true|false" "false")"
  [ "$out" = "false" ] || exit 1
'
[ $? -eq 0 ] && pass "U9.1: default — unset env + no config -> 'false'" \
  || fail "U9.1: default MUST be 'false' (spec '## Decisions' D7 + AC1 default-off bit-identity)"

# U9.2: config file precedence — auto_review_on_merge: true in .claude/uberdev.local.md -> 'true'
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
auto_review_on_merge: true
---
EOF
  out="$(uberdev_read_enum auto_review_on_merge UBERDEV_AUTO_REVIEW_ON_MERGE "true|false" "false")"
  [ "$out" = "true" ] || exit 1
'
[ $? -eq 0 ] && pass "U9.2: config file -> 'true' wins over default" \
  || fail "U9.2: config file 'auto_review_on_merge: true' MUST resolve to 'true' (spec C1 precedence)"

# U9.3: env override — UBERDEV_AUTO_REVIEW_ON_MERGE=true overrides config-file false
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
auto_review_on_merge: false
---
EOF
  export UBERDEV_AUTO_REVIEW_ON_MERGE=true
  out="$(uberdev_read_enum auto_review_on_merge UBERDEV_AUTO_REVIEW_ON_MERGE "true|false" "false")"
  [ "$out" = "true" ] || exit 1
  unset UBERDEV_AUTO_REVIEW_ON_MERGE
'
[ $? -eq 0 ] && pass "U9.3: env override wins over config file" \
  || fail "U9.3: env UBERDEV_AUTO_REVIEW_ON_MERGE=true MUST override config-file false (spec C1 precedence)"

# U9.4: invalid config-file value -> default + uberdev_config_invalid audit event
_isolate '
  mkdir -p .uberdev
  : > .uberdev/audit.jsonl
  cat > .claude/uberdev.local.md <<EOF
---
auto_review_on_merge: maybe
---
EOF
  out="$(uberdev_read_enum auto_review_on_merge UBERDEV_AUTO_REVIEW_ON_MERGE "true|false" "false")"
  [ "$out" = "false" ] || exit 1
  grep -q "\"event\":\"uberdev_config_invalid\"" .uberdev/audit.jsonl || exit 2
  grep -q "\"key\":\"auto_review_on_merge\"" .uberdev/audit.jsonl || exit 3
'
rc=$?
case $rc in
  0) pass "U9.4: invalid config-file value 'maybe' -> default 'false' + uberdev_config_invalid emitted" ;;
  1) fail "U9.4: invalid value MUST fall back to default 'false' (spec C1 invalid-value semantics)" ;;
  2) fail "U9.4: uberdev_config_invalid audit event MUST emit for invalid auto_review_on_merge (spec C1 + existing helper machinery)" ;;
  3) fail "U9.4: uberdev_config_invalid event MUST carry key=auto_review_on_merge" ;;
esac

# U9.5: invalid env-var value -> default + uberdev_config_invalid audit event
_isolate '
  mkdir -p .uberdev
  : > .uberdev/audit.jsonl
  export UBERDEV_AUTO_REVIEW_ON_MERGE=garbage
  out="$(uberdev_read_enum auto_review_on_merge UBERDEV_AUTO_REVIEW_ON_MERGE "true|false" "false")"
  [ "$out" = "false" ] || exit 1
  grep -q "\"event\":\"uberdev_config_invalid\"" .uberdev/audit.jsonl || exit 2
  unset UBERDEV_AUTO_REVIEW_ON_MERGE
'
rc=$?
case $rc in
  0) pass "U9.5: invalid env-var value 'garbage' -> default 'false' + uberdev_config_invalid emitted" ;;
  1) fail "U9.5: invalid env value MUST fall back to default 'false'" ;;
  2) fail "U9.5: uberdev_config_invalid audit event MUST emit for invalid env UBERDEV_AUTO_REVIEW_ON_MERGE" ;;
esac

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
