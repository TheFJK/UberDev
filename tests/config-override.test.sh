#!/usr/bin/env bash
# Tests for issue #63 — uberdev.local.md knobs expansion.
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

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

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
for fn in uberdev_read_int_in_range uberdev_read_enum uberdev_read_string \
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
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
