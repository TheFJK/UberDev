#!/usr/bin/env bash
# tests/goal-verdict-receipt.test.sh
#
# The /goal trust-verdict RECEIPT surface: everything between
# `uberdev_goal_locate_review_pr_audit_by_pr` (which mints the closed controller
# state) and `uberdev_goal_read_trust_signal` (which turns it into a colour).
#
# Why this file exists rather than more cases in tests/goal.test.sh: that file is
# the release-driver surface (it carries the version-lock ratchet), so the
# receipt matrix — which needs one scratch checkout per case and its own gh /
# selector stubs — gets its own home.
#
# Coverage:
#   A  #347  closed-receipt colour matrix built THROUGH the real locator:
#            green / yellow / red, stale on SHA mismatch, stale on
#            audit_state=legacy, and `missing` for EVERY clause of the closed
#            shape gate (a receipt that fails validation must never yield a
#            colour, because /goal auto-merges on green).
#   B  #348  the discovery-classification channel: found / absent /
#            indeterminate / tamper / cleanup_failed / selector_unavailable are
#            distinguishable, where before all six were empty-stdout-rc-0.
#   C  #348  a verdict PROVEN before an unrelated cleanup failure is still
#            emitted, and the cleanup's stderr reaches the operator.
#   D  #345  the legacy pathname branch validates `.sha` against the same
#            lowercase-40-hex shape the closed branch enforces, and says so.
#
# Shell: bash (CI ubuntu + windows). No zsh-only constructs; the zsh mirror of
# the colour matrix lives in tests/goal-state-zsh.test.sh.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT
GOAL_LIB="$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
DISCOVER_LIB="$CLAUDE_PLUGIN_ROOT/skills/merge-pipeline/lib/discover.sh"

for f in "$GOAL_LIB" "$DISCOVER_LIB"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq is required by the verdict receipt surface\n' >&2
  exit 2
fi

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (got=[%s] want=[%s])\n' "$label" "$got" "$want" >&2
  fi
}
assert_contains() {
  local hay="$1" needle="$2" label="$3"
  # Herestring, never `printf | grep -q`: a pipe into `grep -q` can EPIPE-race
  # under pipefail on Linux CI when grep exits on its first match.
  if grep -qF -- "$needle" <<<"$hay"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (missing [%s] in [%s])\n' "$label" "$needle" "$hay" >&2
  fi
}

SHA_OK='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'
SHA_OTHER='0f1e2d3c4b5a6978869504132435465768798a0b'

# ---------------------------------------------------------------------------
# Receipt factory. Writes a canonical .uberdev/runs/<ts>/review-pr-verdict.json
# into a fresh scratch checkout and returns the CLOSED CONTROLLER STATE the real
# locator mints from it — the exact value the Phase-2 watch loop hands to
# read_trust_signal. Building receipts through the locator (rather than
# hand-writing the closed JSON) is what makes this a regression guard on the
# producer/consumer PAIR instead of on one hand-written string.
# ---------------------------------------------------------------------------
mint_receipt() {
  local pr="$1" blocker="$2" critical="$3" halted="$4" sha="$5" overflow="${6:-false}"
  local scratch; scratch="$(mktemp -d)"
  mkdir -p "$scratch/.uberdev/runs/20260401-101112-deadbeef"
  cat > "$scratch/.uberdev/runs/20260401-101112-deadbeef/review-pr-verdict.json" <<EOF
{"pr":$pr,"sha":"$sha","phases":{"phase2_5":{"by_severity":{"blocker":$blocker,"critical":$critical},"halted":$halted,"halted_due_to_overflow":$overflow}}}
EOF
  ( cd "$scratch" && . "$GOAL_LIB" && uberdev_goal_locate_review_pr_audit_by_pr "$pr" 2>/dev/null )
  rm -rf "$scratch"
}

# Evaluate a receipt's colour with `gh pr view <pr> --json headRefOid` stubbed to
# HEAD_SHA. Runs in a subshell so the stub cannot leak into a later case.
signal_for() {
  local receipt="$1" head_sha="$2"
  (
    . "$GOAL_LIB"
    gh() { case "$1 $2" in "pr view") printf '%s\n' "$head_sha" ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$receipt" 2>/dev/null
  )
}

echo "== A (#347): closed-receipt colour matrix, built through the real locator =="
R_GREEN="$(mint_receipt 4101 0 0 false "$SHA_OK")"
R_YELLOW="$(mint_receipt 4102 0 2 false "$SHA_OK")"
R_RED_BLOCKER="$(mint_receipt 4103 1 0 false "$SHA_OK")"
R_RED_HALTED="$(mint_receipt 4104 0 0 true "$SHA_OK")"

if [ -z "$R_GREEN" ] || [ -z "$R_YELLOW" ] || [ -z "$R_RED_BLOCKER" ] || [ -z "$R_RED_HALTED" ]; then
  printf '  FAIL  A.setup — the locator minted no receipt (canonical selector broken?)\n' >&2
  FAIL=$((FAIL + 1))
else
  assert_eq "$(signal_for "$R_GREEN"       "$SHA_OK")" "green"  "A1.green — no findings, HEAD bound"
  assert_eq "$(signal_for "$R_YELLOW"      "$SHA_OK")" "yellow" "A2.yellow — critical findings only"
  assert_eq "$(signal_for "$R_RED_BLOCKER" "$SHA_OK")" "red"    "A3.red — blocker findings"
  assert_eq "$(signal_for "$R_RED_HALTED"  "$SHA_OK")" "red"    "A4.red — phase2_5 halted with zero counts"
  # A commit landed after the review: the WHOLE verdict is invalidated, colour
  # irrespective. A green receipt that survived a HEAD advance would authorise
  # an auto-merge of unreviewed commits.
  assert_eq "$(signal_for "$R_GREEN"       "$SHA_OTHER")" "stale" "A5.stale — HEAD advanced past a GREEN verdict"
  assert_eq "$(signal_for "$R_RED_BLOCKER" "$SHA_OTHER")" "stale" "A6.stale — HEAD advance overrides RED too"
fi

echo "== A (#347): audit_state=legacy is stale, never a colour =="
# audit_state is projected from the on-disk verdict; a `legacy` receipt passes
# the shape gate and the SHA binding but must NOT produce a colour, because the
# phase2_5 counters it carries were not written by the current producer.
R_LEGACY="$(jq -c '.audit_state = "legacy"' <<<"$R_GREEN" 2>/dev/null)"
assert_eq "$(signal_for "$R_LEGACY" "$SHA_OK")" "stale" "A7.stale — audit_state=legacy short-circuits before the colour decision"
R_CURRENT="$(jq -c '.audit_state = "current"' <<<"$R_GREEN" 2>/dev/null)"
assert_eq "$(signal_for "$R_CURRENT" "$SHA_OK")" "green" "A8.control — the same receipt with audit_state=current IS green"

echo "== A (#347): every clause of the closed shape gate maps to \`missing\` =="
# One mutation per clause. `missing` (not stale, not a colour) is the required
# answer: an unparseable trust artifact means "no usable verdict", and the
# caller's recovery is to re-review.
shape_case() {
  local label="$1" filter="$2"
  local mutated
  mutated="$(jq -c "$filter" <<<"$R_CURRENT" 2>/dev/null)"
  if [ -z "$mutated" ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (fixture mutation produced nothing)\n' "$label" >&2
    return
  fi
  assert_eq "$(signal_for "$mutated" "$SHA_OK")" "missing" "$label"
}
shape_case "A9.schema_version-wrong"        '.schema_version = 2'
shape_case "A10.kind-wrong"                 '.kind = "something-else"'
shape_case "A11.pr-not-a-number"            '.pr = "4101"'
shape_case "A12.pr-below-one"               '.pr = 0'
shape_case "A13.pr-not-an-integer"          '.pr = 4101.5'
shape_case "A14.sha-not-a-string"           '.sha = 12345'
shape_case "A15.sha-not-40-hex"             '.sha = "abc123"'
shape_case "A16.sha-uppercase-hex"          '.sha = "A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0"'
shape_case "A17.audit_state-outside-enum"   '.audit_state = "malformed"'
shape_case "A18.halted-not-boolean"         '.phase2_5_halted = "false"'
shape_case "A19.blocker-not-a-number"       '.phase2_5_blocker_count = "0"'
shape_case "A20.blocker-negative"           '.phase2_5_blocker_count = -1'
shape_case "A21.blocker-not-an-integer"     '.phase2_5_blocker_count = 1.5'
shape_case "A22.critical-not-a-number"      '.phase2_5_critical_count = "0"'
shape_case "A23.critical-negative"          '.phase2_5_critical_count = -1'
shape_case "A24.critical-not-an-integer"    '.phase2_5_critical_count = 0.5'
assert_eq "$(signal_for '{' "$SHA_OK")" "missing" "A25.unparseable-json-is-missing"

echo "== B (#348): the six discovery outcomes are distinguishable, not all \`missing\` =="
# Each case runs in its own fresh shell with its own UBERDEV_TMPDIR + GOAL_ID, so
# the classification sidecar of one case can never be read by another.
verdict_state_case() {
  local label="$1" want_state="$2" want_stdout_empty="$3" stubs="$4"
  local dir; dir="$(mktemp -d)"
  local out
  out="$(
    UBERDEV_TMPDIR="$dir" UBERDEV_GOAL_ID="goaltestverdict" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
    bash -c '
      . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
      '"$stubs"'
      receipt="$(uberdev_goal_locate_review_pr_audit_by_pr 555 2>/dev/null)"
      printf "state=%s|empty=%s\n" \
        "$(uberdev_goal_last_verdict_state 555)" \
        "$([ -z "$receipt" ] && printf yes || printf no)"
    '
  )"
  rm -rf "$dir"
  assert_eq "$out" "state=${want_state}|empty=${want_stdout_empty}" "$label"
}

verdict_state_case "B1.selector-unavailable" "selector_unavailable" "yes" '
  unset -f discover_review_verdict_json
'
verdict_state_case "B2.absent" "absent" "yes" '
  discover_review_verdict_json() { return 1; }
  review_verdict_discovery_state() { printf "absent\n"; }
'
verdict_state_case "B3.indeterminate-is-NOT-absent" "indeterminate" "yes" '
  discover_review_verdict_json() { return 2; }
  review_verdict_discovery_state() { printf "indeterminate\n"; }
'
verdict_state_case "B4.tamper-is-NOT-absent" "tamper" "yes" '
  discover_review_verdict_json() { printf "{\"pr\":555}\n"; return 0; }
  review_verdict_discovery_state() { printf "found\n"; }
  recapture_review_verdict_snapshot() { printf "{\"pr\":999}\n"; }
  cleanup_review_verdict_snapshot() { return 0; }
'
verdict_state_case "B5.projection-failure-is-its-own-state" "projection_failed" "yes" '
  discover_review_verdict_json() { printf "not json at all\n"; return 0; }
  review_verdict_discovery_state() { printf "found\n"; }
  recapture_review_verdict_snapshot() { printf "not json at all\n"; }
  cleanup_review_verdict_snapshot() { return 0; }
'
verdict_state_case "B6.found" "found" "no" '
  _V="{\"run_timestamp\":\"20260401-101112\",\"pr\":555,\"artifact_sha\":\"'"$SHA_OK"'\",\"audit_state\":\"current\",\"phase2_5_halted\":false,\"phase2_5_blocker_count\":0,\"phase2_5_critical_count\":0,\"phase2_5_halted_due_to_overflow\":false}"
  discover_review_verdict_json() { printf "%s\n" "$_V"; return 0; }
  review_verdict_discovery_state() { printf "found\n"; }
  recapture_review_verdict_snapshot() { printf "%s\n" "$_V"; }
  cleanup_review_verdict_snapshot() { return 0; }
'
# A forged sidecar must degrade to `unknown`, never invent a control-flow arm.
b7_dir="$(mktemp -d)"
printf 'totally-made-up\n' > "$b7_dir/goal-goaltestverdict-verdict-state-555.txt"
b7_out="$(UBERDEV_TMPDIR="$b7_dir" UBERDEV_GOAL_ID="goaltestverdict" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  bash -c '. "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"; uberdev_goal_last_verdict_state 555')"
assert_eq "$b7_out" "unknown" "B7.forged-classification-degrades-to-unknown"
rm -rf "$b7_dir"

echo "== C (#348): a PROVEN verdict survives a cleanup failure, with a diagnostic =="
# Pre-#348 this path returned empty: a valid GREEN was thrown away because a
# temp file could not be deleted, with the cleanup's stderr sent to /dev/null.
c_dir="$(mktemp -d)"
c_out="$(
  UBERDEV_TMPDIR="$c_dir" UBERDEV_GOAL_ID="goaltestcleanup" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    _V="{\"run_timestamp\":\"20260401-101112\",\"pr\":606,\"artifact_sha\":\"'"$SHA_OK"'\",\"audit_state\":\"current\",\"phase2_5_halted\":false,\"phase2_5_blocker_count\":0,\"phase2_5_critical_count\":0,\"phase2_5_halted_due_to_overflow\":false}"
    discover_review_verdict_json() { printf "%s\n" "$_V"; return 0; }
    review_verdict_discovery_state() { printf "found\n"; }
    recapture_review_verdict_snapshot() { printf "%s\n" "$_V"; }
    cleanup_review_verdict_snapshot() { printf "rmdir: directory not empty\n" >&2; return 1; }
    receipt="$(uberdev_goal_locate_review_pr_audit_by_pr 606 2>"$UBERDEV_TMPDIR/c-err.txt")"
    printf "empty=%s state=%s\n" \
      "$([ -z "$receipt" ] && printf yes || printf no)" \
      "$(uberdev_goal_last_verdict_state 606)"
  '
)"
assert_eq "$c_out" "empty=no state=cleanup_failed" "C1.cleanup-failure-still-publishes-the-proven-verdict"
c_err="$(cat "$c_dir/c-err.txt" 2>/dev/null)"
assert_contains "$c_err" "could not clean the verdict carrier" "C2.cleanup-failure-names-itself-on-stderr"
assert_contains "$c_err" "rmdir: directory not empty"          "C3.the-cleanup-tool-stderr-is-relayed-not-discarded"
rm -rf "$c_dir"

echo "== C (#348): tamper announces itself instead of reading as never-reviewed =="
t_dir="$(mktemp -d)"
t_err="$(
  UBERDEV_TMPDIR="$t_dir" UBERDEV_GOAL_ID="goaltesttamper" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    discover_review_verdict_json() { printf "{\"pr\":707}\n"; return 0; }
    review_verdict_discovery_state() { printf "found\n"; }
    recapture_review_verdict_snapshot() { printf "{\"pr\":708}\n"; }
    cleanup_review_verdict_snapshot() { return 0; }
    uberdev_goal_locate_review_pr_audit_by_pr 707 >/dev/null
  ' 2>&1
)"
assert_contains "$t_err" "TAMPER" "C4.tamper-is-announced-on-stderr"
rm -rf "$t_dir"

echo "== D (#345): the legacy pathname branch validates .sha shape and says so =="
d_dir="$(mktemp -d)"
printf '%s\n' '{"pr":42,"sha":"abc123","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}' > "$d_dir/short-sha.json"
printf '%s\n' "{\"pr\":42,\"sha\":\"$SHA_OK\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":0,\"critical\":0},\"halted\":false}}}" > "$d_dir/good-sha.json"
d_short_err="$(
  (
    . "$GOAL_LIB"
    gh() { case "$1 $2" in "pr view") printf '%s\n' "$SHA_OK" ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$d_dir/short-sha.json" >/dev/null
  ) 2>&1
)"
assert_contains "$d_short_err" "malformed .sha anchor" "D1.malformed-sha-is-diagnosed-not-silent"
d_good_err="$(
  (
    . "$GOAL_LIB"
    gh() { case "$1 $2" in "pr view") printf '%s\n' "$SHA_OK" ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$d_dir/good-sha.json" >/dev/null
  ) 2>&1
)"
if grep -qF "malformed .sha anchor" <<<"$d_good_err"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  D2.well-formed-sha-is-silent (spurious warning: [%s])\n' "$d_good_err" >&2
else
  PASS=$((PASS + 1)); printf '  PASS  D2.well-formed-sha-is-silent\n'
fi
# The binding is still PERFORMED on a malformed anchor. Skipping it would let an
# unbound colour through, which is strictly less safe than the status quo — a
# 6-char string can never equal a real object name, so the outcome is `stale`.
d_signal="$(
  (
    . "$GOAL_LIB"
    gh() { case "$1 $2" in "pr view") printf '%s\n' "$SHA_OK" ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$d_dir/short-sha.json" 2>/dev/null
  )
)"
assert_eq "$d_signal" "stale" "D3.malformed-sha-still-fails-closed-to-stale-never-green"
rm -rf "$d_dir"

echo "== D (#345): the 40-hex predicate itself =="
hex_case() {
  local val="$1" want="$2" label="$3"
  local got
  got="$( . "$GOAL_LIB"; _uberdev_goal_is_object_name "$val" && printf yes || printf no )"
  assert_eq "$got" "$want" "$label"
}
hex_case "$SHA_OK" "yes" "D4.accepts-lowercase-40-hex"
hex_case "abc123"  "no"  "D5.rejects-short"
hex_case "A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0" "no" "D6.rejects-uppercase"
hex_case "${SHA_OK}0" "no" "D7.rejects-41-chars"
hex_case "" "no" "D8.rejects-empty"
hex_case "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9bz" "no" "D9.rejects-non-hex-byte"

echo
echo "== Summary =="
printf 'goal-verdict-receipt: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
