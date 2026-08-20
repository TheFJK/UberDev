#!/usr/bin/env bash
# tests/merge-pipeline-zsh.test.sh — RUNTIME coverage for the executable fences
# of `plugins/uberdev/skills/merge-pipeline/SKILL.md` under the REAL shell the
# Claude-Code Bash tool runs SKILL.md fences with: zsh.
#
# Why this fixture exists (#412).
# #401 closed the *library* half of the zsh blind spot: `merge-pipeline/lib/
# discover.sh` is now executed under a real `zsh -c` (B23 in
# tests/merge-discovery-resilience.test.sh). The *fence* half stayed open by
# construction. tests/merge.test.sh is the only thing that executes merge fence
# bodies at all (M95, M97) and it is bash-bound — it is wired into
# `shape-checks-windows`, so it runs under Git Bash there and under bash on
# ubuntu; it never invokes zsh. merge-discovery-resilience.test.sh's zsh row is
# scoped to `lib/*.sh`. So every bashism that lives in the SKILL body rather
# than in a library was invisible: the same blind spot that let `trap … RETURN`
# ship and survive a 296-row test file, because the code was only ever run by
# bash.
#
# What it does: slices each contract-delimited fence out of the Markdown by
# `# BEGIN <marker>` / `# END <marker>` (never by line number or fence ordinal —
# RFC 0012 §3.2 queues a thin-SKILL rewrite of this file and an ordinal anchor
# would survive it as a successful slice of the WRONG block), assembles a real
# child script and executes it with `zsh -f` against on-disk sandboxes.
#
# Launcher (matches test.yml — runs alongside the other four *-zsh fixtures):
#
#   zsh  tests/merge-pipeline-zsh.test.sh   # CI launcher: the real fence runtime
#   bash tests/merge-pipeline-zsh.test.sh   # also works — the HARNESS is dual-
#                                           # launchable; every extracted fence is
#                                           # ALWAYS run under `zsh -f` regardless.
#
# No divergence exists between bash and zsh for these fences TODAY (verified by
# executing all five under both shells and diffing the output). This file is a
# REGRESSION LOCK, not a red->green bugfix — so its falsifiability is bought with
# the mutation-guard table below plus the MZ6 negative controls, never asserted.
#
# Mutation guard. Every MZ id this file can emit appears below with the exact
# production edit whose revert reds it. Each entry was EXECUTED against a mutated
# copy of SKILL.md during authoring; a row with no named guard would be
# decorative, and no row here is a floor row without saying so.
#
#   MZ0.1  child-is-zsh              -- harness floor: proves slices run under zsh
#                                       (if it reds, every row below is vacuous).
#   MZ0.2  <marker>.extract          -- rename either marker line, or delete the
#                                       named production token from the fence body
#                                       (six markers, incl. merge-trust-gate-fence-v1).
#   MZ0.3  <marker>.markers-present  -- rename/remove either `# BEGIN` or `# END`
#                                       marker line: the pair IS the contract.
#   MZ1.a  fresh-acquire             -- floor row for Step 1.1 (no single guard).
#   MZ1.b  contention                -- neutralise `[ -n "$HB" ] && [ $((NOW-HB))
#                                       -le "$STALE_THRESHOLD" ]`; every live lock
#                                       then reads as stale and gets stolen.
#   MZ1.c  stale-reclaim             -- drop the stale `rm -rf "$LOCK_DIR"` +
#                                       retry `mkdir` (also reds MZ1.d).
#   MZ1.d  crashed-acquisition       -- remove `case "$HB" in ''|*[!0-9]*) HB='' ;;`.
#   MZ1.e  hostile-inherited-RUN_ID  -- replace the RUN_ID_REGEX re-mint with a
#                                       bare `[ -z "$RUN_ID" ]` emptiness test
#                                       (.quote and .newline both red).
#   MZ1.f  filesystem-error          -- delete the `if [ ! -d "$LOCK_DIR" ]` branch;
#                                       the FS error then mis-reports as contention
#                                       (.not-contention is the second half).
#   MZ2.a  touch-holder-match        -- floor row for the heartbeat touch.
#   MZ2.b  touch-holder-mismatch     -- vacate the touch holder check: keep the
#                                       `jq -r '.run_id // empty'` read but compare
#                                       with `-n` instead of `= "$RUN_ID"`.
#   MZ2.c  release-holder-match      -- floor row for Step 4.6.
#   MZ2.d  release-holder-mismatch   -- same vacating edit in the Step 4.6 release
#                                       (also reds MZ2.e).
#   MZ2.e  release-unset-RUN_ID      -- the Step 4.6 holder check (the "an unset
#                                       RUN_ID always mismatches" contract).
#   MZ3.a  positives-dedup-order     -- remove the `awk '!seen[...]++'` dedupe.
#   MZ3.b  negatives                 -- drop the `(^|[^[:alnum:]_-])` left-anchor;
#                                       `preclose #61` is then parsed as `close #61`.
#   MZ3.c  empty-body                -- floor row (`// ""` + empty-array-under-`set -u`).
#   MZ3.d  call-shape                -- drop `--remove-label uberdev:active` or
#                                       `--remove-assignee "@me"` from the edit.
#   MZ3.e  gh-failure-is-fail-soft   -- move the audit emit out of the
#                                       `if gh issue edit …; then` guard.
#   MZ3.f  partial-alone             -- delete the `PARTIAL_ISSUES=(…)` harvest
#                                       (or its `merge-partial` reason literal):
#                                       a landed PARTIAL PR then strands the
#                                       claim on a still-OPEN issue forever.
#   MZ3.g  union-dedupe              -- drop the `_CLEAR_SEEN` padded-haystack
#                                       `case … continue` skip; an issue carrying
#                                       BOTH forms is then edited twice, the
#                                       second time under the wrong reason.
#   MZ3.h  prose-negative            -- relax either anchor of the partial
#                                       harvest past the bounded #603 decoration
#                                       set; the trailer then fires from
#                                       mid-sentence prose (the twin of MZ3.b's
#                                       `preclose #61`).
#   MZ3.k/l/m standalone decorations -- re-tighten the harvest to a bare
#                                       `^UberDev-Partial: #N$`; a trailer the
#                                       producer bulleted, backticked or left a
#                                       trailing space on is then harvested as
#                                       NOTHING and the claim strands silently
#                                       on a still-OPEN issue (#603).
#   MZ3.n  trailing-prose-negative   -- widen the #603 relaxation into an
#                                       unanchoring; a sentence that merely
#                                       discusses a claim then releases it, on
#                                       every PR /merge runs over.
#   MZ3.i  neither-form              -- floor row for the two-harvest no-op (and
#                                       the empty-array expansion of the SECOND
#                                       array under `set -u` — MZ3.c only ever
#                                       covered the first).
#   MZ3.j  crlf                      -- remove `tr -d '\r'` from the partial
#                                       harvest: a body edited in GitHub's web
#                                       textarea arrives CRLF, the `$` anchor
#                                       stops matching, and the claim strands
#                                       silently. NOTE: falsifiable only under a
#                                       grep that SEES the CR (GNU/BSD grep do;
#                                       some drop-in replacements strip it).
#   MZ4.stub                         -- harness floor for the dispatch-line
#                                       substitution (0 or >=2 matches red it).
#   MZ4.a  first-claim               -- floor row for Step 1.4.5.
#   MZ4.b  cap-eexist                -- replace the on-disk
#                                       `$AUTO_REVIEW_MARKER_DIR/${PR}.${RUN_ID}`
#                                       claim with a fence-scoped shell variable.
#   MZ4.c  lock-dir-gone             -- replace the `[ ! -d "$LOCK_DIR" ]` assert
#                                       with a `mkdir -p` (resurrects a record-less
#                                       lock; .no-resurrect is the second half).
#   MZ4.d  rc-classifier             -- collapse any `case "$rc"` arm (.rc0/.rc1/
#                                       .rc2/.rc137 read the emitted outcome).
#   MZ5.a  trust-gate-zsh            -- mis-resolve the `absent)` arm of the
#                                       DISCOVERY_STATE case in Step (c.0); the
#                                       bash twin is merge.test.sh M95.
#   MZ5.a  .no-leak                  -- delete `[ -z "$DISCOVERY_STDERR" ] ||
#                                       rm -f "$DISCOVERY_STDERR"` (SKILL.md's
#                                       trust-gate fence tail), OR revert the
#                                       DISCOVERY_STDERR allocation to a bare
#                                       `mktemp`. Both are needed: the cleanup is
#                                       the subject, and the ${TMPDIR}-rooted
#                                       template is what puts the carrier inside
#                                       $MZ5_TMP where this row can see it (BSD
#                                       mktemp ignores $TMPDIR for the bare form,
#                                       so without the template the row is blind
#                                       on macOS and discriminating only on
#                                       ubuntu -- #521).
#   MZ5.a  .tmpdir-template          -- revert SKILL.md's DISCOVERY_STDERR
#                                       allocation to a bare `mktemp`; this is
#                                       the guard that keeps .no-leak's own
#                                       precondition falsifiable on EVERY
#                                       platform that runs this file.
#   MZ6.a  scalar-split-control      -- negative control: proves MZ3.a CAN go red
#                                       (locks the `CLOSED_ISSUES=(…)` array form).
#   MZ6.b  trap-RETURN-control       -- negative control: proves this fixture would
#                                       catch the #401 `trap … RETURN` class.

set -u

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

if [ ! -r "$SKILL" ]; then
  echo "FATAL: required file missing/unreadable: $SKILL" >&2
  exit 2
fi

# Locate a real zsh — this fixture's whole point is the zsh runtime. CI installs
# zsh on ubuntu-latest (see test.yml). If the harness itself was launched under
# zsh we reuse that interpreter; otherwise we find zsh on PATH.
if [ -n "${ZSH_VERSION:-}" ]; then
  LAUNCH_SHELL="zsh"
  ZSH_BIN="$(command -v zsh 2>/dev/null || echo zsh)"
else
  LAUNCH_SHELL="bash"
  ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
fi
if [ -z "$ZSH_BIN" ] || ! "$ZSH_BIN" -c 'exit 0' 2>/dev/null; then
  echo "FATAL: zsh not found on PATH — this fixture must run the merge fences under zsh" >&2
  echo "       (CI installs zsh on ubuntu-latest; locally: brew install zsh / apt-get install zsh)" >&2
  exit 2
fi

# Hard-FATAL on every other tool the fences themselves invoke. There is no SKIP
# path in this file: a missing tool means the fences were NOT exercised, and a
# green run that proved nothing is the exact failure mode this fixture exists to
# close (precedent: merge-discovery-resilience.test.sh B23 hard-FAILs too).
for _tool in jq git python3; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "FATAL: $_tool not found on PATH — the merge fences invoke it directly;" >&2
    echo "       skipping would produce a vacuous green run" >&2
    exit 2
  fi
done

echo "== merge-pipeline-zsh.test.sh — harness launched under: $LAUNCH_SHELL; fences run under: $ZSH_BIN =="

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

LAST_OUT="$WORK/last.out"
LAST_ERR="$WORK/last.err"
LAST_RC=0

# run_child <sandbox-dir> <child-script> [NAME=VALUE ...]
# Executes the assembled child under a real `zsh -f`, cwd'd into its sandbox.
# Seeded values go in as an `env` command prefix and are NEVER interpolated into
# the child text: this repo's checkout path contains a space and MZ1.e
# deliberately feeds a quote-bearing, newline-bearing RUN_ID.
run_child() {
  _rc_sandbox="$1"; _rc_child="$2"; shift 2
  ( cd "$_rc_sandbox" || exit 97; env "$@" "$ZSH_BIN" -f "$_rc_child" ) >"$LAST_OUT" 2>"$LAST_ERR"
  LAST_RC=$?
}

# build_child <out> <body> [preamble] [postamble] — file assembly, never string
# splicing: nothing seeded ever reaches the child through its text.
build_child() {
  : > "$1"
  [ -z "${3:-}" ] || cat "$3" >> "$1"
  cat "$2" >> "$1"
  [ -z "${4:-}" ] || cat "$4" >> "$1"
}

# slice_marker <marker-name> <outfile> [--dedent] — extract one contract-delimited
# fence body out of the Markdown, BEGIN/END lines included.
#
# Anchored on the marker names only: no line numbers, no `NR ==`, no fence
# ordinals. RFC 0012 §3.2 queues a thin-SKILL rewrite of merge-pipeline/SKILL.md,
# and an ordinal anchor would survive that rewrite as a SUCCESSFUL slice of the
# wrong block — a vacuous green. A missing pair returns rc 3 so the caller emits
# a loud `.extract` FAIL instead of executing an empty slice.
slice_marker() {
  _sm_name="$1"; _sm_out="$2"; _sm_mode="${3:-}"
  awk -v N="$_sm_name" '
    $0 ~ "^[[:space:]]*# BEGIN " N "$" { inb = 1 }
    inb { print }
    $0 ~ "^[[:space:]]*# END " N "$"   { found = 1; exit }
    END { if (found != 1) exit 3 }
  ' "$SKILL" > "$_sm_out" || return 3
  if [ "$_sm_mode" = "--dedent" ]; then
    # ONLY for the list-indented trust-gate fence (byte-identical to the
    # dedent merge.test.sh M95 already applies). The other five fences open at
    # column 0, where this sed would strip real continuation indentation.
    sed 's/^   //' "$_sm_out" > "$_sm_out.dedent" || return 3
    mv "$_sm_out.dedent" "$_sm_out" || return 3
  fi
  [ -s "$_sm_out" ]
}

SLICES="$WORK/slices"
PRE="$WORK/preambles"
SANDBOXES="$WORK/sandboxes"
mkdir -p "$SLICES" "$PRE" "$SANDBOXES"

printf 'set -u\n' > "$PRE/setu.zsh"

# init_repo <dir> — a real git work tree with one commit, so the acquire fence's
# `git rev-parse --short HEAD` mints a RUN_ID_REGEX-valid run id for real.
# Sandbox construction failures abort the whole file: a half-built sandbox would
# make every MZ1 row fail for a reason that has nothing to do with the fence.
init_repo() {
  mkdir -p "$1" \
    && git -C "$1" init -q >/dev/null 2>&1 \
    && git -C "$1" -c user.email=merge-zsh@example.invalid -c user.name='merge zsh fixture' \
         commit -q --allow-empty -m init >/dev/null 2>&1 \
    && return 0
  echo "FATAL: could not build a git sandbox at $1 — the acquire fence needs a real work tree" >&2
  exit 2
}

# seed_lock <dir> <run_id> <heartbeat-bytes> — hand-build a held lock directory.
seed_lock() {
  mkdir -p "$1/.git/uberdev-merge.lock.d" \
    && printf '{"run_id":"%s","started_at":"2026-01-01T00:00:00Z","workflowRunId":null}\n' \
         "$2" > "$1/.git/uberdev-merge.lock.d/record.json" \
    && printf '%s' "$3" > "$1/.git/uberdev-merge.lock.d/heartbeat" \
    && return 0
  echo "FATAL: could not seed a lock directory under $1" >&2
  exit 2
}

# A RUN_ID_REGEX-valid literal used wherever the row is not about minting.
SEED_RUN_ID='20260101-000000-aaa1111'
OTHER_RUN_ID='20260101-000000-bbb2222'

# --------------------------------------------------------------------------
# MZ0.1 — the slices really do run under zsh.
# --------------------------------------------------------------------------
echo
echo "== MZ0: harness floor + fence marker contract =="

mkdir -p "$WORK/mz0"
cat > "$WORK/mz0/probe.zsh" <<'PROBE'
set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  echo "ZSH_RUNTIME_CONFIRMED $ZSH_VERSION"
else
  echo "NOT_ZSH"
fi
PROBE
run_child "$WORK/mz0" "$WORK/mz0/probe.zsh"
if [ "$LAST_RC" -eq 0 ] && grep -q 'ZSH_RUNTIME_CONFIRMED' "$LAST_OUT"; then
  pass "MZ0.1 child-is-zsh — extracted fences execute under a real zsh interpreter"
else
  fail "MZ0.1 child-is-zsh — the child did not report ZSH_VERSION (rc=$LAST_RC); every row below would be vacuous"
fi

# --------------------------------------------------------------------------
# MZ0.3 — the five fences carry their `# BEGIN`/`# END` contract markers.
# SKILL.md already declares this convention for two other fences
# (merge-trust-gate-fence-v1, merge-stale-rebase-precondition-b-v1): the markers
# "are a CONTRACT, not a comment". These five extend it to the fences this
# fixture executes, so slicing never depends on a line number or fence ordinal.
# --------------------------------------------------------------------------
MARKERS="merge-lock-acquire-fence-v1
merge-lock-heartbeat-touch-fence-v1
merge-lock-release-fence-v1
merge-issue-cleanup-fence-v3
merge-autoreview-dispatch-fence-v1"

while IFS= read -r m; do
  [ -n "$m" ] || continue
  if grep -qE "^[[:space:]]*# BEGIN $m\$" "$SKILL" && grep -qE "^[[:space:]]*# END $m\$" "$SKILL"; then
    pass "MZ0.3 $m.markers-present — SKILL.md delimits the fence with # BEGIN/# END"
  else
    fail "MZ0.3 $m.markers-present — SKILL.md MUST delimit the fence with '# BEGIN $m' and '# END $m' (contract markers, not comments)"
  fi
done <<EOF
$MARKERS
EOF

# --------------------------------------------------------------------------
# MZ0.2 — each slice extracts AND still contains its named production token.
# "Non-empty" alone is not enough: a slice that lost its body to a bad marker
# move would still be non-empty (the two marker lines survive), so every row
# also names one token the fence cannot do its job without.
# --------------------------------------------------------------------------
ACQUIRE_SLICE="$SLICES/acquire.zsh"
TOUCH_SLICE="$SLICES/touch.zsh"
RELEASE_SLICE="$SLICES/release.zsh"
CLEANUP_SLICE="$SLICES/cleanup.zsh"
DISPATCH_SLICE="$SLICES/dispatch.zsh"
TRUSTGATE_SLICE="$SLICES/trustgate.zsh"

assert_extract() {   # assert_extract <marker> <outfile> <required-token> [--dedent]
  _ae_marker="$1"; _ae_out="$2"; _ae_token="$3"; _ae_mode="${4:-}"
  if ! slice_marker "$_ae_marker" "$_ae_out" "$_ae_mode"; then
    fail "MZ0.2 $_ae_marker.extract — the # BEGIN/# END pair is missing or the slice is empty"
    return 1
  fi
  if grep -qF -- "$_ae_token" "$_ae_out"; then
    pass "MZ0.2 $_ae_marker.extract — slice carries its production anchor ($_ae_token)"
    return 0
  fi
  fail "MZ0.2 $_ae_marker.extract — slice does NOT contain the required token: $_ae_token"
  return 1
}

MZ1_READY=0; MZ2_READY=0; MZ3_READY=0; MZ4_READY=0; MZ5_READY=0
assert_extract merge-lock-acquire-fence-v1          "$ACQUIRE_SLICE"   'RUN_ID_REGEX=' && MZ1_READY=1
assert_extract merge-lock-heartbeat-touch-fence-v1  "$TOUCH_SLICE"     "jq -r '.run_id // empty'" && MZ2_READY=1
assert_extract merge-lock-release-fence-v1          "$RELEASE_SLICE"   'rm -rf "$LOCK_DIR"' || MZ2_READY=0
assert_extract merge-issue-cleanup-fence-v3         "$CLEANUP_SLICE"   'CLOSED_ISSUES=' && MZ3_READY=1
assert_extract merge-autoreview-dispatch-fence-v1   "$DISPATCH_SLICE"  'AUTO_REVIEW_MARKER_DIR' && MZ4_READY=1
assert_extract merge-trust-gate-fence-v1            "$TRUSTGATE_SLICE" 'discover_review_verdict_json "$PR_NUMBER"' --dedent && MZ5_READY=1

# --------------------------------------------------------------------------
# MZ1 — `merge-lock-acquire-fence-v1` (Step 1.1).
#
# CLAUDE_PLUGIN_ROOT is seeded so the fence's
# `. "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"` + `uberdev_read_int_in_range`
# run FOR REAL under zsh. Without it the fence dies on `set -u` in BOTH shells,
# which would be a harness bug rather than a finding.
# --------------------------------------------------------------------------
echo
echo "== MZ1: Step 1.1 mkdir-atomic lock acquire, under zsh =="

mz1_run() {   # mz1_run <sandbox> [NAME=VALUE ...]
  _m1_box="$1"; shift
  build_child "$WORK/child-acquire.zsh" "$ACQUIRE_SLICE" "$PRE/setu.zsh"
  run_child "$_m1_box" "$WORK/child-acquire.zsh" \
    "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" "$@"
}

if [ "$MZ1_READY" -ne 1 ]; then
  fail "MZ1.* — skipped because the acquire slice did not extract (see MZ0.2)"
else
  # -- MZ1.a fresh-acquire (floor row) --------------------------------------
  BOX="$SANDBOXES/mz1a"; init_repo "$BOX"
  mz1_run "$BOX" 'RUN_ID='
  MZ1A_ECHOED="$(sed -n 's/^merge lock acquired (run_id \(.*\))$/\1/p' "$LAST_OUT")"
  MZ1A_RECORDED="$(jq -r '.run_id' "$BOX/.git/uberdev-merge.lock.d/record.json" 2>/dev/null || printf '')"
  if [ "$LAST_RC" -eq 0 ] \
     && [ -n "$MZ1A_ECHOED" ] \
     && [ -f "$BOX/.git/uberdev-merge.lock.d/record.json" ] \
     && [ -f "$BOX/.git/uberdev-merge.lock.d/heartbeat" ] \
     && [ "$MZ1A_ECHOED" = "$MZ1A_RECORDED" ]; then
    pass "MZ1.a fresh-acquire — lock stamped and the echoed run_id IS the recorded run_id"
  else
    fail "MZ1.a fresh-acquire — rc=$LAST_RC echoed='$MZ1A_ECHOED' recorded='$MZ1A_RECORDED'; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ1.b contention ------------------------------------------------------
  BOX="$SANDBOXES/mz1b"; init_repo "$BOX"
  seed_lock "$BOX" "$SEED_RUN_ID" "$(date +%s)"
  mz1_run "$BOX" 'RUN_ID='
  if [ "$LAST_RC" -eq 1 ] \
     && grep -qE 'another /merge run in progress \(run_id .*, started .*, heartbeat [0-9]+s ago\)' "$LAST_ERR" \
     && [ "$(jq -r '.run_id' "$BOX/.git/uberdev-merge.lock.d/record.json" 2>/dev/null)" = "$SEED_RUN_ID" ]; then
    pass "MZ1.b contention — a fresh heartbeat fails fast and the holder's record is untouched"
  else
    fail "MZ1.b contention — rc=$LAST_RC; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ1.c stale-reclaim ---------------------------------------------------
  # UBERDEV_MERGE_TIMEOUT=60 pins the config read so STALE_THRESHOLD clamps to
  # the 900 floor regardless of any repo config; heartbeat=1 is epoch+1s.
  BOX="$SANDBOXES/mz1c"; init_repo "$BOX"
  seed_lock "$BOX" "$SEED_RUN_ID" '1'
  mz1_run "$BOX" 'RUN_ID=' 'UBERDEV_MERGE_TIMEOUT=60'
  MZ1C_NEW="$(jq -r '.run_id' "$BOX/.git/uberdev-merge.lock.d/record.json" 2>/dev/null || printf '')"
  if [ "$LAST_RC" -eq 0 ] && [ -n "$MZ1C_NEW" ] && [ "$MZ1C_NEW" != "$SEED_RUN_ID" ]; then
    pass "MZ1.c stale-reclaim — an expired heartbeat is reclaimed and re-stamped with the NEW run_id"
  else
    fail "MZ1.c stale-reclaim — rc=$LAST_RC new_run_id='$MZ1C_NEW'; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ1.d crashed-acquisition --------------------------------------------
  BOX="$SANDBOXES/mz1d"; init_repo "$BOX"
  seed_lock "$BOX" "$SEED_RUN_ID" 'not-a-number'
  mz1_run "$BOX" 'RUN_ID=' 'UBERDEV_MERGE_TIMEOUT=60'
  MZ1D_NEW="$(jq -r '.run_id' "$BOX/.git/uberdev-merge.lock.d/record.json" 2>/dev/null || printf '')"
  if [ "$LAST_RC" -eq 0 ] && [ -n "$MZ1D_NEW" ] && [ "$MZ1D_NEW" != "$SEED_RUN_ID" ]; then
    pass "MZ1.d crashed-acquisition — a non-integer heartbeat is classified stale, not arithmetic-crashed"
  else
    fail "MZ1.d crashed-acquisition — rc=$LAST_RC new_run_id='$MZ1D_NEW'; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ1.e hostile-inherited-RUN_ID ---------------------------------------
  # The inherited value is interpolated UNESCAPED into record.json, so a `"`- or
  # newline-bearing value would write a record whose .run_id never round-trips
  # and every later holder check would warn-skip — including Step 4.6's release.
  mz1_hostile() {   # mz1_hostile <label> <sandbox> <hostile-run-id>
    _mh_label="$1"; _mh_box="$2"; _mh_id="$3"
    init_repo "$_mh_box"
    mz1_run "$_mh_box" "RUN_ID=$_mh_id"
    _mh_rec="$_mh_box/.git/uberdev-merge.lock.d/record.json"
    if [ "$LAST_RC" -eq 0 ] \
       && grep -qF 'inherited RUN_ID does not match RUN_ID_REGEX — re-minting' "$LAST_ERR" \
       && jq -e . "$_mh_rec" >/dev/null 2>&1 \
       && grep -qE '^[0-9]{8}-[0-9]{6}-[a-f0-9]+$' <<<"$(jq -r '.run_id' "$_mh_rec" 2>/dev/null)"; then
      pass "MZ1.e.$_mh_label hostile-inherited-RUN_ID — re-minted; record.json round-trips as JSON"
    else
      fail "MZ1.e.$_mh_label hostile-inherited-RUN_ID — rc=$LAST_RC; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
    fi
  }
  mz1_hostile quote   "$SANDBOXES/mz1e1" 'a" ,"x":"y'
  mz1_hostile newline "$SANDBOXES/mz1e2" "$(printf 'aa\nbb')"

  # -- MZ1.f filesystem-error ------------------------------------------------
  # No .git parent, so `mkdir .git/uberdev-merge.lock.d` fails ENOENT. A
  # regex-valid RUN_ID MUST be seeded: without one the fence dies earlier at
  # "cannot mint a RUN_ID" and the row would pass for the wrong reason.
  BOX="$SANDBOXES/mz1f"; mkdir -p "$BOX"
  mz1_run "$BOX" "RUN_ID=$SEED_RUN_ID"
  if [ "$LAST_RC" -eq 1 ] \
     && grep -qE 'cannot create \.git/uberdev-merge\.lock\.d \(filesystem error' "$LAST_ERR"; then
    pass "MZ1.f filesystem-error — a non-EEXIST mkdir failure reports the filesystem-error diagnostic"
  else
    fail "MZ1.f filesystem-error — rc=$LAST_RC; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi
  if grep -qF 'another /merge run in progress' "$LAST_ERR"; then
    fail "MZ1.f filesystem-error.not-contention — an FS error MUST NOT be reported as contention"
  else
    pass "MZ1.f filesystem-error.not-contention — the FS error is never mis-reported as contention"
  fi
fi

# --------------------------------------------------------------------------
# MZ2 — heartbeat touch + explicit release, under zsh.
# --------------------------------------------------------------------------
echo
echo "== MZ2: holder-verified heartbeat touch + Step 4.6 release, under zsh =="

if [ "$MZ2_READY" -ne 1 ]; then
  fail "MZ2.* — skipped because the touch and/or release slice did not extract (see MZ0.2)"
else
  build_child "$WORK/child-touch.zsh"   "$TOUCH_SLICE"   "$PRE/setu.zsh"
  build_child "$WORK/child-release.zsh" "$RELEASE_SLICE" "$PRE/setu.zsh"

  # -- MZ2.a touch-holder-match ---------------------------------------------
  BOX="$SANDBOXES/mz2a"; mkdir -p "$BOX"; seed_lock "$BOX" "$SEED_RUN_ID" '1000'
  run_child "$BOX" "$WORK/child-touch.zsh" "RUN_ID=$SEED_RUN_ID"
  MZ2A_HB="$(cat "$BOX/.git/uberdev-merge.lock.d/heartbeat" 2>/dev/null || printf '')"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ2A_HB" != "1000" ] && [ -n "$MZ2A_HB" ] && [ ! -s "$LAST_ERR" ]; then
    pass "MZ2.a touch-holder-match — the holder advances the heartbeat, silently"
  else
    fail "MZ2.a touch-holder-match — rc=$LAST_RC heartbeat='$MZ2A_HB'; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ2.b touch-holder-mismatch ------------------------------------------
  BOX="$SANDBOXES/mz2b"; mkdir -p "$BOX"; seed_lock "$BOX" "$SEED_RUN_ID" '1000'
  run_child "$BOX" "$WORK/child-touch.zsh" "RUN_ID=$OTHER_RUN_ID"
  MZ2B_HB="$(cat "$BOX/.git/uberdev-merge.lock.d/heartbeat" 2>/dev/null || printf '')"
  if grep -qF 'merge lock not held by this run' "$LAST_ERR" && [ "$MZ2B_HB" = "1000" ]; then
    pass "MZ2.b touch-holder-mismatch — a dispossessed run warns and leaves the heartbeat byte-unchanged"
  else
    fail "MZ2.b touch-holder-mismatch — heartbeat='$MZ2B_HB'; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ2.c release-holder-match -------------------------------------------
  BOX="$SANDBOXES/mz2c"; mkdir -p "$BOX"; seed_lock "$BOX" "$SEED_RUN_ID" '1000'
  run_child "$BOX" "$WORK/child-release.zsh" "RUN_ID=$SEED_RUN_ID"
  if [ "$LAST_RC" -eq 0 ] && [ ! -d "$BOX/.git/uberdev-merge.lock.d" ]; then
    pass "MZ2.c release-holder-match — the holder removes the lock directory"
  else
    fail "MZ2.c release-holder-match — rc=$LAST_RC, lock dir still present; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ2.d release-holder-mismatch ----------------------------------------
  BOX="$SANDBOXES/mz2d"; mkdir -p "$BOX"; seed_lock "$BOX" "$SEED_RUN_ID" '1000'
  run_child "$BOX" "$WORK/child-release.zsh" "RUN_ID=$OTHER_RUN_ID"
  if grep -qF 'owned by a different run_id at release time' "$LAST_ERR" \
     && [ -d "$BOX/.git/uberdev-merge.lock.d" ]; then
    pass "MZ2.d release-holder-mismatch — a reclaimed lock is NOT stolen at release time"
  else
    fail "MZ2.d release-holder-mismatch — lock dir gone or no warning; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ2.e release-unset-RUN_ID -------------------------------------------
  BOX="$SANDBOXES/mz2e"; mkdir -p "$BOX"; seed_lock "$BOX" "$SEED_RUN_ID" '1000'
  run_child "$BOX" "$WORK/child-release.zsh" 'RUN_ID='
  if grep -qF 'owned by a different run_id at release time' "$LAST_ERR" \
     && [ -d "$BOX/.git/uberdev-merge.lock.d" ]; then
    pass "MZ2.e release-unset-RUN_ID — an unre-established RUN_ID always mismatches and never removes"
  else
    fail "MZ2.e release-unset-RUN_ID — lock dir gone or no warning; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi
fi

# --------------------------------------------------------------------------
# MZ3 — `merge-issue-cleanup-fence-v3` (Step 3.4).
# `gh` and `_uberdev_audit_emit` are shell FUNCTIONS, not PATH executables:
# a function wins over PATH lookup in every POSIX shell and needs no exec bit
# (the precedent is merge.test.sh M97). `git`, `jq`, `awk`, `grep` stay real.
# --------------------------------------------------------------------------
echo
echo "== MZ3: Step 3.4 post-merge issue cleanup, under zsh =="

cat > "$PRE/cleanup.zsh" <<'CLEANUP_PRE'
set -u
gh() { printf '%s\n' "$*" >> "$GHLOG"; return "${GH_RC:-0}"; }
_uberdev_audit_emit() { printf '%s %s\n' "$1" "${2:-}" >> "$AUDITLOG"; }
PR=99
if [ -n "${PR_JSON_RAW:-}" ]; then
  PR_JSON="$PR_JSON_RAW"
else
  PR_JSON="$(jq -cn --arg b "${BODY:-}" '{body:$b}')"
fi
CLEANUP_PRE

MZ3_POS_BODY='Closes #42, Fixes #42 and resolves #7'
MZ3_NEG_BODY='I tried to preclose #61 and unresolve #50, then a postfix #100 plus a code-fix #50'

# `UberDev-Partial: #N` — the NON-closing linkage trailer a solve-fleet PR carries
# when its task chain stopped early (#554). It releases the `uberdev:active` claim
# without closing the issue, so these bodies deliberately carry no closing keyword:
# the claim can only come off the trailer. Whole-line and namespaced, exactly like
# the `Blocks: #N` trailer `lib/goal-state.sh` already parses.
MZ3_PARTIAL_BODY='UberDev-Partial: #77'
MZ3_UNION_BODY='Closes #42
UberDev-Partial: #42'
MZ3_PARTIAL_PROSE_BODY='see UberDev-Partial: #50 for context'
MZ3_NEITHER_BODY='Refactors the discovery projection. Background in #33.'
# Built with real CR bytes: a body edited in the GitHub web textarea decodes to
# CRLF, and a `$`-anchored match with no CR strip silently harvests nothing.
MZ3_CRLF_BODY="$(printf 'intro\r\nUberDev-Partial: #88\r\n')"

# #603 — the near-misses. The producer is a free-text agent told to emit a
# "line"; the three shapes below are what it writes when it renders that line
# into a markdown body, and every one of them was harvested as NOTHING by the
# v2 anchor, stranding `uberdev:active` on a still-OPEN issue. They are still
# STANDALONE lines — the trailer is the only content the line carries — so
# tolerating them costs the anchor none of its authority, which is why the
# relaxation is bounded to exactly these three decorations (leading list
# marker, surrounding backticks, trailing whitespace) rather than unanchored.
MZ3_PARTIAL_BACKTICK_BODY='intro
`UberDev-Partial: #66`'
MZ3_PARTIAL_BULLET_BODY='intro
- `UberDev-Partial: #67`'
MZ3_PARTIAL_TRAILWS_BODY='UberDev-Partial: #68   '
# The BOUNDARY, and the row that proves the relaxation is not an unanchoring:
# once prose follows the trailer on its own line the line is no longer the
# trailer, and /merge runs on EVERY PR — a sentence that merely discusses a
# claim must never release it. The producer mandate (the trailer MUST stand
# alone) is the half that keeps this form from being emitted at all.
MZ3_PARTIAL_TRAILPROSE_BODY='- `UberDev-Partial: #69` — chain stopped at task 3'

# MZ3.o — the INDENTED form, and the reason the left anchor is flush. Four
# leading spaces is a markdown CODE BLOCK, so this body DOCUMENTS the trailer
# rather than emitting one. An earlier cut of the #603 relaxation tolerated a
# leading whitespace run and harvested 70 from exactly this shape, which would
# strip uberdev:active and the assignee from a live issue and write a
# merge-partial audit row asserting a legitimate release — and /merge runs over
# EVERY PR, so any body quoting the format would do it. The three producer
# renderings k/l/m are all left-flush, so nothing legitimate needs the
# tolerance; this row is what stops it being re-added.
MZ3_PARTIAL_INDENTED_BODY='Mark a partial delivery like this:

    UberDev-Partial: #70

Nothing above releases anything.'

mz3_run() {   # mz3_run <label> [NAME=VALUE ...]
  _m3_box="$SANDBOXES/mz3-$1"; shift
  rm -rf "$_m3_box"; mkdir -p "$_m3_box"
  : > "$_m3_box/gh.log"; : > "$_m3_box/audit.log"
  build_child "$WORK/child-cleanup.zsh" "$CLEANUP_SLICE" "$PRE/cleanup.zsh"
  run_child "$_m3_box" "$WORK/child-cleanup.zsh" \
    "GHLOG=$_m3_box/gh.log" "AUDITLOG=$_m3_box/audit.log" "$@"
  MZ3_GHLOG="$_m3_box/gh.log"
  MZ3_AUDITLOG="$_m3_box/audit.log"
}

count_lines() { _cl_n=0; while IFS= read -r _cl_l; do [ -z "$_cl_l" ] || _cl_n=$((_cl_n + 1)); done < "$1"; printf '%s' "$_cl_n"; }

if [ "$MZ3_READY" -ne 1 ]; then
  fail "MZ3.* — skipped because the cleanup slice did not extract (see MZ0.2)"
else
  # -- MZ3.a positives-dedup-order ------------------------------------------
  mz3_run a "BODY=$MZ3_POS_BODY" 'PR_JSON_RAW='
  MZ3A_N="$(count_lines "$MZ3_GHLOG")"
  MZ3A_1="$(sed -n '1p' "$MZ3_GHLOG")"
  MZ3A_2="$(sed -n '2p' "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3A_N" = "2" ] \
     && grep -qE '^issue edit 42( |$)' <<<"$MZ3A_1" \
     && grep -qE '^issue edit 7( |$)'  <<<"$MZ3A_2"; then
    pass "MZ3.a positives-dedup-order — 'Closes #42, Fixes #42 and resolves #7' yields exactly 42 then 7"
  else
    fail "MZ3.a positives-dedup-order — rc=$LAST_RC calls=$MZ3A_N [$MZ3A_1 | $MZ3A_2]; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ3.d call-shape (same body as MZ3.a) --------------------------------
  MZ3D_BAD=0
  while IFS= read -r call; do
    [ -n "$call" ] || continue
    grep -qF -- '--remove-label uberdev:active' <<<"$call" || MZ3D_BAD=1
    grep -qF -- '--remove-assignee @me'         <<<"$call" || MZ3D_BAD=1
  done < "$MZ3_GHLOG"
  MZ3D_AUDITS=0
  while IFS= read -r ev; do
    case "$ev" in uberdev_active_label_cleared*) MZ3D_AUDITS=$((MZ3D_AUDITS + 1)) ;; esac
  done < "$MZ3_AUDITLOG"
  if [ "$MZ3D_BAD" -eq 0 ] && [ "$MZ3A_N" = "2" ] && [ "$MZ3D_AUDITS" -eq 2 ]; then
    pass "MZ3.d call-shape — every edit clears BOTH label and assignee, one audit event per success"
  else
    fail "MZ3.d call-shape — bad_call=$MZ3D_BAD calls=$MZ3A_N audits=$MZ3D_AUDITS"
  fi

  # -- MZ3.b negatives -------------------------------------------------------
  mz3_run b "BODY=$MZ3_NEG_BODY" 'PR_JSON_RAW='
  MZ3B_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3B_N" = "0" ]; then
    pass "MZ3.b negatives — preclose/unresolve/postfix/code-fix never reach gh (left-anchor holds)"
  else
    fail "MZ3.b negatives — rc=$LAST_RC calls=$MZ3B_N: $(tr '\n' ' ' < "$MZ3_GHLOG")"
  fi

  # -- MZ3.c empty-body ------------------------------------------------------
  # `{}` (no .body at all) exercises the `// ""` fallback AND the empty-array
  # expansion under `set -u` — the divergence surface this row exists for.
  mz3_run c 'BODY=' 'PR_JSON_RAW={}'
  MZ3C_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3C_N" = "0" ] \
     && ! grep -qiE 'unbound|bad substitution|parameter not set' "$LAST_ERR"; then
    pass "MZ3.c empty-body — an absent .body is a clean no-op under set -u (no unbound-variable death)"
  else
    fail "MZ3.c empty-body — rc=$LAST_RC calls=$MZ3C_N; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ3.e gh-failure-is-fail-soft ----------------------------------------
  mz3_run e "BODY=$MZ3_POS_BODY" 'PR_JSON_RAW=' 'GH_RC=1'
  MZ3E_CALLS="$(count_lines "$MZ3_GHLOG")"
  MZ3E_AUDITS="$(count_lines "$MZ3_AUDITLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3E_CALLS" = "2" ] && [ "$MZ3E_AUDITS" = "0" ]; then
    pass "MZ3.e gh-failure-is-fail-soft — a failing gh keeps rc 0 and emits NO audit event"
  else
    fail "MZ3.e gh-failure-is-fail-soft — rc=$LAST_RC calls=$MZ3E_CALLS audits=$MZ3E_AUDITS"
  fi

  # -- MZ3.f partial-alone ---------------------------------------------------
  # #554's whole point. A chain that stopped early lands a PR that must NOT
  # close the issue, so the claim can only come off the non-closing trailer.
  # Without this arm the issue stays OPEN with `uberdev:active` set forever, and
  # every later /solve, /turbo and /goal Phase 1 refuses to pick it up.
  # `merge-partial` is what tells this release apart in the audit trail from one
  # that happened *because* the issue closed.
  mz3_run f "BODY=$MZ3_PARTIAL_BODY" 'PR_JSON_RAW='
  MZ3F_N="$(count_lines "$MZ3_GHLOG")"
  MZ3F_1="$(sed -n '1p' "$MZ3_GHLOG")"
  MZ3F_AUDITS=0
  while IFS= read -r ev; do
    case "$ev" in *'"reason":"merge-partial"'*) MZ3F_AUDITS=$((MZ3F_AUDITS + 1)) ;; esac
  done < "$MZ3_AUDITLOG"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3F_N" = "1" ] \
     && [ "$MZ3F_1" = 'issue edit 77 --remove-label uberdev:active --remove-assignee @me' ] \
     && [ "$MZ3F_AUDITS" -eq 1 ]; then
    pass "MZ3.f partial-alone — 'UberDev-Partial: #77' releases the claim exactly once, reason merge-partial"
  else
    fail "MZ3.f partial-alone — rc=$LAST_RC calls=$MZ3F_N partial_audits=$MZ3F_AUDITS [$MZ3F_1]; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ3.g union-dedupe ----------------------------------------------------
  # Both forms naming the SAME issue is one release, not two, and the closing
  # form wins the reason: a closed issue is released BECAUSE it closed.
  mz3_run g "BODY=$MZ3_UNION_BODY" 'PR_JSON_RAW='
  MZ3G_N="$(count_lines "$MZ3_GHLOG")"
  MZ3G_1="$(sed -n '1p' "$MZ3_GHLOG")"
  MZ3G_MERGE=0; MZ3G_PARTIAL=0
  while IFS= read -r ev; do
    case "$ev" in
      *'"reason":"merge"'*)         MZ3G_MERGE=$((MZ3G_MERGE + 1)) ;;
      *'"reason":"merge-partial"'*) MZ3G_PARTIAL=$((MZ3G_PARTIAL + 1)) ;;
    esac
  done < "$MZ3_AUDITLOG"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3G_N" = "1" ] \
     && grep -qE '^issue edit 42( |$)' <<<"$MZ3G_1" \
     && [ "$MZ3G_MERGE" -eq 1 ] && [ "$MZ3G_PARTIAL" -eq 0 ]; then
    pass "MZ3.g union-dedupe — an issue named by BOTH forms is edited once, under the closing reason"
  else
    fail "MZ3.g union-dedupe — rc=$LAST_RC calls=$MZ3G_N merge=$MZ3G_MERGE partial=$MZ3G_PARTIAL [$MZ3G_1]"
  fi

  # -- MZ3.h prose-negative --------------------------------------------------
  # The twin of MZ3.b: the trailer must be the whole content of its line, so
  # prose that merely mentions it must not release anything. /merge runs on
  # EVERY PR, so an unanchored match would let a drive-by sentence strip a claim
  # a live solver still holds. #603 relaxed the harvest to tolerate a leading
  # list marker, surrounding backticks and trailing whitespace (MZ3.k/l/m) —
  # this row and MZ3.n are the two that pin that relaxation as a BOUNDED one
  # rather than an unanchoring.
  mz3_run h "BODY=$MZ3_PARTIAL_PROSE_BODY" 'PR_JSON_RAW='
  MZ3H_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3H_N" = "0" ]; then
    pass "MZ3.h prose-negative — a mid-sentence 'UberDev-Partial: #50' never reaches gh (the line anchor holds)"
  else
    fail "MZ3.h prose-negative — rc=$LAST_RC calls=$MZ3H_N: $(tr '\n' ' ' < "$MZ3_GHLOG")"
  fi

  # -- MZ3.i neither-form ----------------------------------------------------
  # No-op semantics for a drive-by PR are unchanged by the second harvest — and
  # this is the row that expands the SECOND empty array under `set -u` (MZ3.c
  # only ever covered the first).
  mz3_run i "BODY=$MZ3_NEITHER_BODY" 'PR_JSON_RAW='
  MZ3I_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3I_N" = "0" ] \
     && ! grep -qiE 'unbound|bad substitution|parameter not set' "$LAST_ERR"; then
    pass "MZ3.i neither-form — a body with neither linkage form is a clean no-op under set -u"
  else
    fail "MZ3.i neither-form — rc=$LAST_RC calls=$MZ3I_N; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ3.j crlf ------------------------------------------------------------
  # A body edited in the GitHub web textarea comes back CRLF. Anchoring on `$`
  # without stripping CR strands the claim — the exact failure this arm exists
  # to prevent, so it would fail silently and look like "no trailer present".
  mz3_run j "BODY=$MZ3_CRLF_BODY" 'PR_JSON_RAW='
  MZ3J_N="$(count_lines "$MZ3_GHLOG")"
  MZ3J_1="$(sed -n '1p' "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3J_N" = "1" ] \
     && grep -qE '^issue edit 88( |$)' <<<"$MZ3J_1"; then
    pass "MZ3.j crlf — a CRLF body still releases the claim (the harvest strips CR before anchoring)"
  else
    fail "MZ3.j crlf — rc=$LAST_RC calls=$MZ3J_N [$MZ3J_1]; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi

  # -- MZ3.k/l/m standalone-line decorations (#603) ---------------------------
  # Each body's trailer is the ONLY content on its line; only the decoration
  # differs. A miss here is silent by construction — the harvest finds nothing,
  # the loop iterates zero times, rc stays 0 — so the stranded claim looks
  # exactly like "this PR carried no trailer".
  mz3_decor() {   # mz3_decor <label> <body> <issue> <why>
    mz3_run "$1" "BODY=$2" 'PR_JSON_RAW='
    _md_n="$(count_lines "$MZ3_GHLOG")"
    _md_1="$(sed -n '1p' "$MZ3_GHLOG")"
    _md_audits=0
    while IFS= read -r ev; do
      case "$ev" in *'"reason":"merge-partial"'*) _md_audits=$((_md_audits + 1)) ;; esac
    done < "$MZ3_AUDITLOG"
    if [ "$LAST_RC" -eq 0 ] && [ "$_md_n" = "1" ] \
       && [ "$_md_1" = "issue edit $3 --remove-label uberdev:active --remove-assignee @me" ] \
       && [ "$_md_audits" -eq 1 ]; then
      pass "MZ3.$1 $4 — the trailer still releases the claim exactly once, reason merge-partial"
    else
      fail "MZ3.$1 $4 — rc=$LAST_RC calls=$_md_n partial_audits=$_md_audits [$_md_1]; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
    fi
  }
  mz3_decor k "$MZ3_PARTIAL_BACKTICK_BODY" 66 "backticked-standalone"
  mz3_decor l "$MZ3_PARTIAL_BULLET_BODY"   67 "bulleted-backticked-standalone"
  mz3_decor m "$MZ3_PARTIAL_TRAILWS_BODY"  68 "trailing-whitespace"

  # -- MZ3.n trailing-prose-negative (#603) ----------------------------------
  # The boundary of the k/l/m relaxation, and the twin of MZ3.h pointed the
  # other way: MZ3.h refuses prose BEFORE the trailer, this refuses prose
  # AFTER it. Without this row "tolerate a bullet and backticks" is
  # indistinguishable from "match anywhere on the line", which is the
  # unanchoring MZ3.h exists to forbid.
  mz3_run n "BODY=$MZ3_PARTIAL_TRAILPROSE_BODY" 'PR_JSON_RAW='
  MZ3N_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3N_N" = "0" ]; then
    pass "MZ3.n trailing-prose-negative — a trailer with commentary after it on the same line never reaches gh"
  else
    fail "MZ3.n trailing-prose-negative — rc=$LAST_RC calls=$MZ3N_N: $(tr '\n' ' ' < "$MZ3_GHLOG")"
  fi

  # -- MZ3.o indented-code-block negative (#603) -----------------------------
  # The LEFT anchor's boundary, and the one k/l/m cannot imply: they all sit
  # flush, so a relaxation that also tolerated leading whitespace would keep
  # every one of them green while turning documentation into a claim release.
  mz3_run o "BODY=$MZ3_PARTIAL_INDENTED_BODY" 'PR_JSON_RAW='
  MZ3O_N="$(count_lines "$MZ3_GHLOG")"
  if [ "$LAST_RC" -eq 0 ] && [ "$MZ3O_N" = "0" ]; then
    pass "MZ3.o indented-code-block negative — a four-space-indented trailer is documentation and never reaches gh"
  else
    fail "MZ3.o indented-code-block negative — rc=$LAST_RC calls=$MZ3O_N: $(tr '\n' ' ' < "$MZ3_GHLOG")"
  fi
fi

# --------------------------------------------------------------------------
# MZ4 — `merge-autoreview-dispatch-fence-v1` (Step 1.4.5).
#
# The one `Skill("uberdev:review-pr", …)` line is not shell in ANY shell, so it
# is substituted for `( exit "${MOCK_REVIEW_RC:-0}" )` — a SUBSHELL, not an
# assignment, precisely so the fence's own next line (`rc=$?`) still reads the
# dispatch's exit status. MZ4.stub asserts the substitution matched exactly one
# line: zero or two matches would silently change what the row exercises.
# --------------------------------------------------------------------------
echo
echo "== MZ4: Step 1.4.5 auto-review dispatch guard ladder, under zsh =="

if [ "$MZ4_READY" -ne 1 ]; then
  fail "MZ4.* — skipped because the dispatch slice did not extract (see MZ0.2)"
else
  DISPATCH_SUB="$SLICES/dispatch-sub.zsh"
  MZ4_MATCHES=0
  while IFS= read -r dl; do
    case "$dl" in 'Skill("uberdev:review-pr'*) MZ4_MATCHES=$((MZ4_MATCHES + 1)) ;; esac
  done < "$DISPATCH_SLICE"
  sed 's|^Skill("uberdev:review-pr".*$|( exit "${MOCK_REVIEW_RC:-0}" )|' "$DISPATCH_SLICE" > "$DISPATCH_SUB"
  if [ "$MZ4_MATCHES" -eq 1 ] && grep -qF '( exit "${MOCK_REVIEW_RC:-0}" )' "$DISPATCH_SUB"; then
    pass "MZ4.stub — the Skill() dispatch line is substituted exactly once"
    MZ4_STUB_OK=1
  else
    fail "MZ4.stub — expected exactly 1 Skill(\"uberdev:review-pr\" line, found $MZ4_MATCHES; the row would exercise something else"
    MZ4_STUB_OK=0
  fi

  mz4_box() {   # mz4_box <label> [--no-lock]
    _m4_box="$SANDBOXES/mz4-$1"
    rm -rf "$_m4_box"; mkdir -p "$_m4_box/.uberdev"
    [ "${2:-}" = "--no-lock" ] || mkdir -p "$_m4_box/.git/uberdev-merge.lock.d"
  }
  mz4_run() {   # mz4_run <box> <run_id> <rc>
    build_child "$WORK/child-dispatch.zsh" "$DISPATCH_SUB" "$PRE/setu.zsh"
    run_child "$1" "$WORK/child-dispatch.zsh" \
      "RUN_ID=$2" 'PR=99' 'reason=trust_trail_label_missing' "MOCK_REVIEW_RC=$3"
  }
  # Counted by reading the file, never by `grep -c … || printf 0`: grep -c
  # PRINTS "0" and exits 1 on a no-match, so the `||` fallback concatenates a
  # second zero and yields "00" — a count that silently compares unequal to
  # every expected value.
  mz4_count() {
    _m4c_n=0
    [ -f "$1/.uberdev/audit.jsonl" ] || { printf '0'; return 0; }
    while IFS= read -r _m4c_l; do
      case "$_m4c_l" in *"\"event\":\"$2\""*) _m4c_n=$((_m4c_n + 1)) ;; esac
    done < "$1/.uberdev/audit.jsonl"
    printf '%s' "$_m4c_n"
  }

  if [ "$MZ4_STUB_OK" -ne 1 ]; then
    fail "MZ4.a/.b/.c/.d — skipped: the dispatch substitution did not apply cleanly"
  else
    # -- MZ4.a first-claim ---------------------------------------------------
    mz4_box a; BOX="$_m4_box"
    mz4_run "$BOX" "$SEED_RUN_ID" 0
    MZ4A_D="$(mz4_count "$BOX" auto_review_dispatched)"
    MZ4A_R="$(mz4_count "$BOX" auto_review_returned)"
    MZ4A_JSON=no-audit-file
    if [ -f "$BOX/.uberdev/audit.jsonl" ]; then
      MZ4A_JSON=ok
      while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        jq -e . >/dev/null 2>&1 <<<"$ln" || MZ4A_JSON=bad
      done < "$BOX/.uberdev/audit.jsonl"
    fi
    if [ "$MZ4A_D" = "1" ] && [ "$MZ4A_R" = "1" ] && [ "$MZ4A_JSON" = "ok" ]; then
      pass "MZ4.a first-claim — one dispatched + one returned event, both valid JSON"
    else
      fail "MZ4.a first-claim — dispatched=$MZ4A_D returned=$MZ4A_R json=$MZ4A_JSON; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
    fi

    # -- MZ4.b cap-eexist ----------------------------------------------------
    mz4_run "$BOX" "$SEED_RUN_ID" 0
    MZ4B_D="$(mz4_count "$BOX" auto_review_dispatched)"
    MZ4B_R="$(mz4_count "$BOX" auto_review_returned)"
    if [ "$MZ4B_D" = "1" ] && [ "$MZ4B_R" = "1" ]; then
      pass "MZ4.b cap-eexist — the on-disk (pr, run_id) marker survives the fence boundary; no second dispatch"
    else
      fail "MZ4.b cap-eexist — re-run added events: dispatched=$MZ4B_D returned=$MZ4B_R"
    fi

    # -- MZ4.c lock-dir-gone -------------------------------------------------
    mz4_box c --no-lock; BOX="$_m4_box"
    mz4_run "$BOX" "$SEED_RUN_ID" 0
    MZ4C_D="$(mz4_count "$BOX" auto_review_dispatched)"
    if grep -qE 'merge lock dir .* is gone' "$LAST_ERR" && [ "$MZ4C_D" = "0" ]; then
      pass "MZ4.c lock-dir-gone — no cap, no dispatch"
    else
      fail "MZ4.c lock-dir-gone — dispatched=$MZ4C_D; stderr: $(tr '\n' ' ' < "$LAST_ERR")"
    fi
    if [ -d "$BOX/.git/uberdev-merge.lock.d" ]; then
      fail "MZ4.c lock-dir-gone.no-resurrect — the fence RE-CREATED the lock dir (mkdir -p regression: a record-less lock)"
    else
      pass "MZ4.c lock-dir-gone.no-resurrect — the vanished lock dir is asserted, never re-created"
    fi

    # -- MZ4.d rc-classifier -------------------------------------------------
    # Each rc needs its OWN run_id: the on-disk cap is keyed (pr, run_id), so a
    # shared run_id would suppress runs 2-4 and this row would assert nothing.
    mz4_box d; BOX="$_m4_box"
    mz4_expect_outcome() {   # mz4_expect_outcome <rc> <run_id_suffix> <want>
      mz4_run "$BOX" "20260101-000000-$2" "$1"
      _m4_got="$(jq -r 'select(.event=="auto_review_returned") | .data.outcome' \
        "$BOX/.uberdev/audit.jsonl" 2>/dev/null | tail -1)"
      if [ "$_m4_got" = "$3" ]; then
        pass "MZ4.d.rc$1 rc-classifier — rc=$1 classified as outcome=$3"
      else
        fail "MZ4.d.rc$1 rc-classifier — rc=$1 expected outcome=$3, got '$_m4_got'"
      fi
    }
    mz4_expect_outcome 0   ddd0000 green
    mz4_expect_outcome 1   ddd1111 blocked
    mz4_expect_outcome 2   ddd2222 refused_non_green
    mz4_expect_outcome 137 ddd3333 refused_non_green
  fi
fi

# --------------------------------------------------------------------------
# MZ5 — two-shell parity for the already-marked trust-gate fence.
# merge.test.sh M95 executes this exact block under bash; this row converts
# that into a two-shell execution for free.
# --------------------------------------------------------------------------
echo
echo "== MZ5: Step (c.0) trust-gate discovery/recapture/cleanup, under zsh =="

if [ "$MZ5_READY" -ne 1 ]; then
  fail "MZ5.a — skipped because the trust-gate slice did not extract (see MZ0.2)"
else
  cat > "$PRE/trustgate.zsh" <<'TG_PRE'
set -u
# The fence may only assume CLAUDE_PLUGIN_ROOT, PR_NUMBER, and an `audit`
# emitter. Anything else it reaches for is a contract break and `set -u` says so.
audit() { printf 'AUDIT %s\n' "$*" >&2; }
TG_PRE
  cat > "$WORK/trustgate.post" <<'TG_POST'
printf 'DISCOVERY_STATE=%s\n' "${DISCOVERY_STATE-<unset>}"
printf 'PHASE2_5_AUDIT_STATE=%s\n' "${PHASE2_5_AUDIT_STATE-<unset>}"
printf 'AUDIT_CAPTURE_CLEANED=%s\n' "${AUDIT_CAPTURE_CLEANED-<unset>}"
TG_POST
  BOX="$SANDBOXES/mz5"; rm -rf "$BOX"; mkdir -p "$BOX"
  MZ5_TMP="$WORK/mz5-tmp"; rm -rf "$MZ5_TMP"; mkdir -p "$MZ5_TMP"
  build_child "$WORK/child-trustgate.zsh" "$TRUSTGATE_SLICE" "$PRE/trustgate.zsh" "$WORK/trustgate.post"
  run_child "$BOX" "$WORK/child-trustgate.zsh" \
    "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" 'PR_NUMBER=4242' "TMPDIR=$MZ5_TMP"
  mz5_field() { sed -n "s/^$1=//p" "$LAST_OUT" | tail -1; }
  if [ "$(mz5_field DISCOVERY_STATE)" = "absent" ] \
     && [ "$(mz5_field PHASE2_5_AUDIT_STATE)" = "absent" ] \
     && [ "$(mz5_field AUDIT_CAPTURE_CLEANED)" = "false" ]; then
    pass "MZ5.a trust-gate-zsh — exhaustive no-match resolves absent/absent under zsh, same as bash (M95)"
  else
    fail "MZ5.a trust-gate-zsh — discovery=$(mz5_field DISCOVERY_STATE) audit_state=$(mz5_field PHASE2_5_AUDIT_STATE) cleaned=$(mz5_field AUDIT_CAPTURE_CLEANED); stderr: $(tr '\n' ' ' < "$LAST_ERR")"
  fi
  # `ls -A` rather than a glob: under zsh an unmatched glob is a hard NOMATCH
  # error, and "no residue" is exactly the unmatched case this row expects.
  MZ5_RESIDUE="$(ls -A "$MZ5_TMP" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${MZ5_RESIDUE:-1}" -eq 0 ]; then
    pass "MZ5.a trust-gate-zsh.no-leak — the fence left no private capture directory behind under zsh"
  else
    fail "MZ5.a trust-gate-zsh.no-leak — the fence leaked $MZ5_RESIDUE entr(y|ies) under TMPDIR"
  fi
  # #521 — .no-leak above can only SEE a leak that lands inside $MZ5_TMP, and it
  # only lands there when every temp the fence allocates is rooted at an EXPLICIT
  # $TMPDIR template. BSD mktemp(1) ignores the TMPDIR environment variable for
  # the bare `mktemp` form (verified on Darwin: bare -> /var/folders/.../T/, the
  # supplied dir keeps 0 entries), so reverting SKILL.md's DISCOVERY_STDERR
  # allocation to a bare `mktemp` re-blinds .no-leak on macOS while NOTHING reds
  # on ubuntu. This row is what makes that revert visible on every platform.
  if grep -qF 'mktemp "${TMPDIR:-/tmp}/uberdev-discovery-stderr-' "$TRUSTGATE_SLICE"; then
    pass "MZ5.a trust-gate-zsh.tmpdir-template — DISCOVERY_STDERR is allocated from an explicit \${TMPDIR}-rooted template"
  else
    fail "MZ5.a trust-gate-zsh.tmpdir-template — a BARE mktemp ignores TMPDIR on BSD, which blinds the .no-leak row above on macOS"
  fi
fi

# --------------------------------------------------------------------------
# MZ6 — negative controls. Without these the whole file is decorative: every
# row above passes today, so nothing here proves a regression WOULD be caught.
# --------------------------------------------------------------------------
echo
echo "== MZ6: negative controls (the rows that prove this fixture can go red) =="

# -- MZ6.a scalar-split-control --------------------------------------------
# Runs the production array form AND the zsh-hostile scalar form of the same
# extraction in ONE child. Under zsh SH_WORD_SPLIT is OFF, so the scalar form
# binds the whole joined list to a single token. Two numbers vs one is the exact
# discrimination MZ3.a depends on — this proves MZ3.a can fail.
cat > "$WORK/mz6a.zsh" <<'MZ6A'
set -u
BODY='Closes #42, Fixes #42 and resolves #7'
EXTRACT() {
  printf '%s' "$BODY" \
    | grep -oiE '(^|[^[:alnum:]_-])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | awk -v c0=0 '!seen[$c0]++'
}
ARR=($(EXTRACT))
n=0
for X in "${ARR[@]}"; do n=$((n + 1)); done
printf 'ARRAY_COUNT=%s\n' "$n"
SCALAR="$(EXTRACT)"
m=0
for X in $SCALAR; do m=$((m + 1)); done
printf 'SCALAR_COUNT=%s\n' "$m"
MZ6A
mkdir -p "$SANDBOXES/mz6a"
run_child "$SANDBOXES/mz6a" "$WORK/mz6a.zsh"
MZ6A_ARR="$(sed -n 's/^ARRAY_COUNT=//p' "$LAST_OUT")"
MZ6A_SCA="$(sed -n 's/^SCALAR_COUNT=//p' "$LAST_OUT")"
if [ "$MZ6A_ARR" = "2" ] && [ "$MZ6A_SCA" = "1" ]; then
  pass "MZ6.a scalar-split-control — array form yields 2 issues, the scalar form yields 1 mangled token (MZ3.a is falsifiable)"
else
  fail "MZ6.a scalar-split-control — array_count='$MZ6A_ARR' (want 2), scalar_count='$MZ6A_SCA' (want 1); stderr: $(tr '\n' ' ' < "$LAST_ERR")"
fi

# -- MZ6.b trap-RETURN-control ---------------------------------------------
# The #401 class: `trap … RETURN` is a bashism; zsh rejects the signal name on
# stderr and CARRIES ON with rc 0, so the cleanup silently never runs. Keyed on
# stderr text, never on rc (same classifier as
# merge-discovery-resilience.test.sh's zsh row).
cat > "$WORK/mz6b.zsh" <<'MZ6B'
set -u
f() { trap 'echo CLEANUP_RAN' RETURN; echo BODY_RAN; }
f
MZ6B
mkdir -p "$SANDBOXES/mz6b"
run_child "$SANDBOXES/mz6b" "$WORK/mz6b.zsh"
if grep -qF 'undefined signal' "$LAST_ERR" \
   && grep -qF 'BODY_RAN' "$LAST_OUT" \
   && ! grep -qF 'CLEANUP_RAN' "$LAST_OUT"; then
  pass "MZ6.b trap-RETURN-control — zsh rejects 'trap … RETURN' on stderr and skips the cleanup (rc stays $LAST_RC)"
else
  fail "MZ6.b trap-RETURN-control — expected an 'undefined signal' stderr with the body run and the cleanup skipped; rc=$LAST_RC stderr: $(tr '\n' ' ' < "$LAST_ERR")"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
