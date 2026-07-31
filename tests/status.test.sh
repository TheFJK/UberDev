#!/usr/bin/env bash
# tests/status.test.sh — /uberdev:status read-only run-state census (issue #310).
#
# Sections:
#   S1  — lib/status.sh + commands/status.md shape (thin-wrapper contract,
#         read-only contract, cross-shell discipline)
#   S2  — codex mirror parity
#   S3  — root discovery: BOTH roots present (hardened + bare fallback)
#   S4  — root discovery: ONLY the hardened root present
#   S5  — root discovery: ONLY the bare fallback present (the post-crash case)
#   S6  — env:UBERDEV_TMPDIR is probed as its own labelled candidate
#   S7  — solve claim + dispatch-status rows carry a re-entry hint
#   S8  — agent-lifecycle liveness (LIVE vs terminal), not `claude agents`
#   S9  — /review-pr reservations: FRESH / STALE (> grace) / ABANDONED (> reap)
#   S10 — /merge lock: held with a live heartbeat vs a stale heartbeat
#   S11 — empty repo renders "nothing in flight" with the probed roots still shown
#   S12 — READ-ONLY: a full render leaves the fixture tree byte-for-byte identical
#   S13 — per-file ownership gate (shared roots) + root-probe verdicts
#
# UNIX-ONLY (declared in the .github/workflows/test.yml windows-skip-list
# marker block): the fixtures drive `python3` over `mktemp -d` paths, POSIX
# ownership predicates, and `touch -t` mtime forgery — the same Git Bash
# path-translation class that keeps uberscan/uberthink/codex-port off the
# windows job. lib/status.sh ITSELF stays portable (it feeds Python on stdin
# and never puts a path in argv); only this harness is Unix-bound.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_LIB="$REPO_ROOT/plugins/uberdev/lib/status.sh"
STATUS_CMD="$REPO_ROOT/plugins/uberdev/commands/status.md"
CODEX_LIB="$REPO_ROOT/codex/uberdev-codex/lib/status.sh"
CODEX_SKILL="$REPO_ROOT/codex/uberdev-codex/skills/uberdev-cmd-status/SKILL.md"

for f in "$STATUS_LIB" "$STATUS_CMD"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

assert_in() {   # FILE PATTERN DESC
  if grep -qE -e "$2" "$1"; then
    pass "$3"
  else
    fail "$3"
    echo "        pattern: $2"
    echo "        --- output ---"
    sed -n '1,80p' "$1" | sed 's/^/        /'
  fi
}

assert_not_in() {   # FILE PATTERN DESC
  if grep -qE -e "$2" "$1"; then
    fail "$3"
    echo "        unexpected match for: $2"
  else
    pass "$3"
  fi
}

assert_eq() {   # ACTUAL EXPECTED DESC
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3"
    echo "        expected: $2"
    echo "        actual:   $1"
  fi
}

TMPROOT="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
# Physical path up front: lib/status.sh resolves every root with `pwd -P`, and
# on macOS $TMPDIR lives behind the /private symlink. Comparing a rendered
# resolved path against an unresolved fixture path would fail on macOS and pass
# on Linux — exactly the kind of platform-split this repo has been bitten by.
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

UID_NOW="$(id -u)"
FAKE_TMP="$TMPROOT/faketmp"
HARDENED="$FAKE_TMP/uberdev-$UID_NOW"
ALT_ROOT="$TMPROOT/altroot"
WORK_REPO="$TMPROOT/repo"
STUB_BIN="$TMPROOT/bin"
OUT_DIR="$TMPROOT/out"
RUNS="$WORK_REPO/.uberdev/runs"
LOCK_DIR="$WORK_REPO/.git/uberdev-merge.lock.d"
mkdir -p "$FAKE_TMP" "$STUB_BIN" "$OUT_DIR" "$WORK_REPO"

git -C "$WORK_REPO" init -q >/dev/null 2>&1 || { echo "FATAL: git init failed" >&2; exit 2; }

# Comment-stripped copy: the read-only shape asserts must not trip over the
# header comment, which legitimately NAMES the mutating calls it forbids.
CODE_ONLY="$TMPROOT/status-code.sh"
sed 's/#.*//' "$STATUS_LIB" > "$CODE_ONLY"
# EXEC_ONLY additionally drops the render emitters. Their arguments are OPERATOR
# GUIDANCE strings ("gh issue edit ... --remove-label", "never rm it by hand"),
# not commands this file runs; grepping them as if they were would make the
# read-only asserts unfalsifiable noise.
EXEC_ONLY="$TMPROOT/status-exec.sh"
grep -vE '(print\(|_uberdev_status_(note|row|hint))' "$CODE_ONLY" > "$EXEC_ONLY"

# --- gh stub (never contacts GitHub; the census must degrade cleanly) -------
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${GH_STUB_MODE:-ok}" = "fail" ]; then exit 1; fi
printf '%s' "${GH_STUB_JSON:-[]}"
STUB
chmod +x "$STUB_BIN/gh"

# --- fixture-tree snapshotter (the read-only oracle) ------------------------
SNAP_PY="$TMPROOT/snapshot.py"
cat > "$SNAP_PY" <<'PY'
import hashlib, os, stat, sys

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

for root in sys.argv[1:]:
    if not os.path.exists(root):
        print("%s\tABSENT" % root)
        continue
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            path = os.path.join(base, name)
            entry = os.lstat(path)
            if stat.S_ISDIR(entry.st_mode):
                kind = "dir"
            elif stat.S_ISLNK(entry.st_mode):
                kind = "link"
            else:
                kind = "file"
            sha = digest(path) if kind == "file" else "-"
            print("%s\t%s\t%o\t%d\t%d\t%s" % (
                path, kind, stat.S_IMODE(entry.st_mode), entry.st_size,
                int(entry.st_mtime), sha))
PY

snapshot() {   # OUT_FILE
  python3 -I -B "$SNAP_PY" "$FAKE_TMP" "$ALT_ROOT" "$WORK_REPO/.uberdev" "$LOCK_DIR" > "$1" 2>&1
}

# --- render driver ---------------------------------------------------------
# Each render runs in its own process with a controlled environment, so the
# developer's real TMPDIR / UBERDEV_TMPDIR / uberdev.local.md cannot leak in.
# Results land in the globals RENDER_OUT / RENDER_RC rather than on stdout: a
# `$(render ...)` capture would run the function in a subshell and discard the
# exit code.
RENDER_UBERDEV_TMPDIR=""
RENDER_GRACE=""
RENDER_REAP=""
RENDER_GH_MODE="ok"
RENDER_GH_JSON="[]"
RENDER_OUT=""
RENDER_RC=0
# The interpreter the census is driven through. Every section below pins bash;
# S14 re-drives one fixture through zsh and diffs the bytes, because zsh is the
# shell the Bash tool actually uses on macOS.
RENDER_SHELL="bash"

render() {   # OUT_BASENAME -> sets RENDER_OUT, RENDER_RC
  RENDER_OUT="$OUT_DIR/$1"
  (
    cd "$WORK_REPO" && env \
      TMPDIR="$FAKE_TMP" \
      UBERDEV_TMPDIR="$RENDER_UBERDEV_TMPDIR" \
      UBERDEV_GOAL_REVIEW_GRACE_SECS="$RENDER_GRACE" \
      REVIEW_RESERVATION_REAP_SECS="$RENDER_REAP" \
      UBERDEV_MERGE_TIMEOUT="" \
      UBERDEV_CONFIG_FILE="" \
      GH_STUB_MODE="$RENDER_GH_MODE" \
      GH_STUB_JSON="$RENDER_GH_JSON" \
      PATH="$STUB_BIN:$PATH" \
      "$RENDER_SHELL" -c 'set -u; . "$1" && uberdev_status_render' _ "$STATUS_LIB"
  ) > "$RENDER_OUT" 2> "$RENDER_OUT.err"
  RENDER_RC=$?
}

reset_roots() {
  rm -rf "$FAKE_TMP" "$ALT_ROOT"
  mkdir -p "$FAKE_TMP"
}

write_goal_fixture() {   # ROOT GOAL_ID CYCLE
  local root="$1" gid="$2" cycle="$3" now
  now="$(date +%s)"
  mkdir -p "$root"
  printf '%s\n' "$gid" > "$root/goal-active-id.txt"
  {
    printf 'GOAL_ID=%s\n' "$gid"
    printf 'cycle=%s\n' "$cycle"
    printf 'MAX_CYCLES=5\n'
    printf 'MAX_PARALLEL=3\n'
    printf 'UBERDEV_RESOLVED_BACKEND=workflow\n'
    printf 'CIRCUIT_BREAKER_HALT=\n'
  } > "$root/goal-$gid-runstate"
  printf '312\n313\n' > "$root/goal-$gid-runstate.queue"
  printf '310\n' > "$root/goal-$gid-runstate.active"
  printf 'cycle=%s\n314\n' "$cycle" > "$root/goal-$gid-runstate.candidates"
  printf '401\tpushed-reviewing\t%s\n' "$now" > "$root/goal-$gid-pr-states.tsv"
  printf '310\tsolving\t%s\n' "$now" > "$root/goal-$gid-issue-states.tsv"
}

write_lifecycle_fixture() {   # STATE_DIR
  mkdir -p "$1"
  {
    printf '{"schema_version":2,"event":"route_decided","run_id":"solve-codex-310-1","backend":"codex","issue_or_pr":310,"role":"solver"}\n'
    printf '{"schema_version":2,"event":"agent_started","run_id":"solve-codex-310-1","backend":"codex","issue_or_pr":310,"role":"solver","owner_pid":4242,"timeout_s":3600,"status_path":"%s/solve-codex-status-310.json"}\n' "$HARDENED"
    printf '{"schema_version":2,"event":"agent_started","run_id":"solve-codex-311-1","backend":"codex","issue_or_pr":311,"role":"solver","owner_pid":4243,"timeout_s":3600}\n'
    printf '{"schema_version":2,"event":"completed","run_id":"solve-codex-311-1","backend":"codex","issue_or_pr":311,"terminal_status":"completed"}\n'
    printf '{"schema_version":2,"event":"route_decided","run_id":"solve-codex-312-1","backend":"codex","issue_or_pr":312,"role":"solver"}\n'
  } > "$1/agent-lifecycle.jsonl"
}

echo "## /uberdev:status read-only census (#310)"

# ===========================================================================
echo "== S1: shape — thin wrapper, read-only contract, cross-shell discipline =="
# ===========================================================================
assert_in "$STATUS_LIB" '^uberdev_status_render\(\)' \
  "S1.1 lib/status.sh defines uberdev_status_render"
assert_in "$STATUS_CMD" 'lib/status\.sh' \
  "S1.2 commands/status.md points at lib/status.sh"

CMD_FENCES="$(grep -c '^```bash$' "$STATUS_CMD")"
assert_eq "$CMD_FENCES" "1" "S1.3 commands/status.md makes exactly ONE Bash call"
assert_in "$STATUS_CMD" '^allowed-tools: \["Bash"\]$' \
  "S1.4 commands/status.md allows Bash only (no Task fan-out)"

# The read-only contract, enforced structurally rather than by prose.
assert_not_in "$CODE_ONLY" 'mkdir' \
  "S1.5 no mkdir in lib/status.sh code (dispatch.sh hardening would CREATE the root)"
assert_not_in "$CODE_ONLY" '>>' \
  "S1.6 no append redirection in lib/status.sh code"
assert_not_in "$EXEC_ONLY" '(^|[^[:alnum:]_])rm[[:space:]]' \
  "S1.7 no rm executed by lib/status.sh"
assert_not_in "$EXEC_ONLY" 'gh (issue|pr|api|repo) [a-z-]*(edit|create|comment|merge|close|delete)' \
  "S1.8 no mutating gh sub-command executed by lib/status.sh"
# The trap this file was written around: config-read.sh's
# uberdev_read_int_in_range appends to .uberdev/audit.jsonl when the configured
# value is invalid, which would break the read-only guarantee.
assert_not_in "$CODE_ONLY" 'uberdev_read_int_in_range' \
  "S1.9 lib/status.sh never calls uberdev_read_int_in_range (it can write audit.jsonl)"
assert_in "$STATUS_LIB" '_uberdev_status_config_int' \
  "S1.10 thresholds resolve through the non-writing local reader instead"
assert_in "$STATUS_LIB" '\-I \-B' \
  "S1.11 python runs with -B so no __pycache__ is emitted"

# Cross-shell traps this repo has been bitten by before.
assert_not_in "$CODE_ONLY" 'type -t' \
  "S1.12 no 'type -t' bashism (misreports under the zsh-backed Bash tool)"
assert_not_in "$CODE_ONLY" 'BASH_REMATCH' \
  "S1.13 no BASH_REMATCH (unset under zsh)"
STAT_C_LINE="$(grep -n 'stat -c %Y' "$STATUS_LIB" | head -n1 | cut -d: -f1)"
STAT_F_LINE="$(grep -n 'stat -f %m' "$STATUS_LIB" | head -n1 | cut -d: -f1)"
if [ -n "$STAT_C_LINE" ] && [ -n "$STAT_F_LINE" ] && [ "$STAT_C_LINE" -lt "$STAT_F_LINE" ]; then
  pass "S1.14 'stat -c' is probed before 'stat -f' (GNU -f means --file-system)"
else
  fail "S1.14 'stat -c' is probed before 'stat -f' (GNU -f means --file-system)"
fi
assert_not_in "$CODE_ONLY" '(echo|printf) .*\| *grep -q' \
  "S1.15 no 'echo \$V | grep -q' EPIPE race under pipefail"

# The renderer must also load cleanly under zsh — the Bash tool's macOS shell.
# NOTE: uberdev_status_render is documented to ALWAYS return 0, so this assert
# can only catch a LOAD failure. Wrong-VALUE regressions under zsh are caught by
# S14, which diffs the rendered bytes bash-vs-zsh.
if command -v zsh >/dev/null 2>&1; then
  if zsh -c "set -u; . '$STATUS_LIB' && uberdev_status_render >/dev/null 2>&1"; then
    pass "S1.16 lib/status.sh sources and renders under zsh (load smoke only)"
  else
    fail "S1.16 lib/status.sh sources and renders under zsh (load smoke only)"
  fi
else
  pass "S1.16 skipped — zsh not installed on this host"
fi

# zsh TIES the `path` array to $PATH (and cdpath/fpath/manpath/mailpath/
# module_path/psvar likewise, plus `status`/`argv` which are reserved). A
# `local path="$1"` therefore REPLACES the command search path for that whole
# call frame: `stat`, `date`, `find` and `awk` become command-not-found, every
# external probe silently returns rc=1, and the safety-critical verdicts INVERT
# (a live /merge lock renders STALE and /status hands the operator a hint to
# steal it). Structural twin of the behavioural S14 diff.
assert_not_in "$CODE_ONLY" \
  '(^|[^_[:alnum:]])(path|cdpath|fpath|manpath|mailpath|module_path|psvar|watch|status|argv)=' \
  "S1.17 no local shadows a zsh tied/special parameter (zsh's \`path\` IS \$PATH)"

# ===========================================================================
echo "== S2: codex mirror parity =="
# ===========================================================================
if [ -r "$CODEX_LIB" ] && cmp -s "$STATUS_LIB" "$CODEX_LIB"; then
  pass "S2.1 codex/uberdev-codex/lib/status.sh is a byte-identical mirror"
else
  fail "S2.1 codex/uberdev-codex/lib/status.sh is a byte-identical mirror"
fi
if [ -r "$CODEX_SKILL" ]; then
  pass "S2.2 codex uberdev-cmd-status skill is generated"
else
  fail "S2.2 codex uberdev-cmd-status skill is generated"
fi

# ===========================================================================
echo "== S3: root discovery — BOTH roots present =="
# ===========================================================================
reset_roots
write_goal_fixture "$HARDENED" hardenedgoal 2
write_goal_fixture "$FAKE_TMP" fallbackgoal 4
render both-roots
assert_eq "$RENDER_RC" "0" "S3.0 render exits 0"
assert_in "$RENDER_OUT" "dispatch-hardened +ok +$HARDENED" \
  "S3.1 the hardened root probes ok"
assert_in "$RENDER_OUT" "goal-fallback:TMPDIR +ok +$FAKE_TMP" \
  "S3.2 the bare fallback root probes ok"
assert_in "$RENDER_OUT" "read from: $HARDENED  \(pointer goal-active-id\.txt -> hardenedgoal\)" \
  "S3.3 goal state under the hardened root is attributed to it"
assert_in "$RENDER_OUT" "read from: $FAKE_TMP  \(pointer goal-active-id\.txt -> fallbackgoal\)" \
  "S3.4 goal state under the bare fallback is attributed to it"
assert_in "$RENDER_OUT" 'cycle 2/5  backend=workflow  max_parallel=3' \
  "S3.5 hardened-root goal cycle scalars decoded"
assert_in "$RENDER_OUT" 'queue:      312 313' "S3.6 queue sidecar rehydrated"
assert_in "$RENDER_OUT" 'active:     310' "S3.7 active sidecar rehydrated"
assert_in "$RENDER_OUT" 'candidates: 314' "S3.8 cycle-tag-matching candidates rehydrated"
assert_in "$RENDER_OUT" '#401 pushed-reviewing \(age' "S3.9 pr-states.tsv rendered with age"
assert_in "$RENDER_OUT" '#310 solving \(age' "S3.10 issue-states.tsv rendered with age"
assert_in "$RENDER_OUT" 're-enter: /uberdev:goal 312 313' \
  "S3.11 the goal row carries a concrete re-entry command"

# A stale cycle tag must NOT be presented as the live candidate set.
printf 'cycle=99\n777\n' > "$HARDENED/goal-hardenedgoal-runstate.candidates"
render stale-candidates
assert_in "$RENDER_OUT" 'candidates: \(tagged cycle 99 != cycle 2 — stale, ignored by /goal\)' \
  "S3.12 stale cycle-tagged candidates are refused, not rendered as live"

# ===========================================================================
echo "== S4: root discovery — ONLY the hardened root present =="
# ===========================================================================
reset_roots
write_goal_fixture "$HARDENED" onlyhardened 1
render only-hardened
assert_in "$RENDER_OUT" "read from: $HARDENED  \(pointer goal-active-id\.txt -> onlyhardened\)" \
  "S4.1 hardened-root goal state is found"
assert_not_in "$RENDER_OUT" 'no goal-active-id\.txt under any readable root' \
  "S4.2 does not falsely report an absent /goal run"

# ===========================================================================
echo "== S5: root discovery — ONLY the bare fallback (the post-crash case) =="
# ===========================================================================
# This is the failure the discovery seam exists for: lib/dispatch.sh exports
# UBERDEV_TMPDIR process-scoped, so a fresh shell loses it and goal-state.sh
# writes/reads `${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}` — the bare fallback. A
# reader that only looked at the hardened root would report "nothing in flight".
reset_roots
write_goal_fixture "$FAKE_TMP" crashedgoal 3
render only-fallback
assert_in "$RENDER_OUT" 'dispatch-hardened +absent' \
  "S5.1 the hardened root is reported absent, not silently skipped"
assert_in "$RENDER_OUT" "read from: $FAKE_TMP  \(pointer goal-active-id\.txt -> crashedgoal\)" \
  "S5.2 the bare fallback is still read (post-crash /goal state is recovered)"
assert_in "$RENDER_OUT" 'cycle 3/5' "S5.3 fallback-root goal scalars decoded"
assert_in "$RENDER_OUT" 'goal-fallback:/tmp' \
  "S5.4 the literal /tmp candidate is probed and reported even when unused"

# ===========================================================================
echo "== S6: env:UBERDEV_TMPDIR is probed as its own labelled candidate =="
# ===========================================================================
reset_roots
write_goal_fixture "$ALT_ROOT" envgoal 7
RENDER_UBERDEV_TMPDIR="$ALT_ROOT"
render env-root
RENDER_UBERDEV_TMPDIR=""
assert_in "$RENDER_OUT" "env:UBERDEV_TMPDIR +ok +$ALT_ROOT" \
  "S6.1 UBERDEV_TMPDIR is probed under its own label"
assert_in "$RENDER_OUT" "read from: $ALT_ROOT  \(pointer goal-active-id\.txt -> envgoal\)" \
  "S6.2 goal state under UBERDEV_TMPDIR is read and attributed"

# ===========================================================================
echo "== S7: solve/turbo claims + per-issue dispatch status =="
# ===========================================================================
reset_roots
mkdir -p "$HARDENED"
printf '{"issue":310,"tier":"medium","backend":"codex","state":"running","pid":4242,"log":"%s/solve-codex-stdout-310.log","result":"%s/solve-codex-result-310.md"}\n' \
  "$HARDENED" "$HARDENED" > "$HARDENED/solve-codex-status-310.json"
RENDER_GH_JSON='[{"number":310,"title":"unified read-only status","assignees":[{"login":"TheFJK"}]}]'
render claims
RENDER_GH_JSON='[]'
assert_in "$RENDER_OUT" '#310  unified read-only status  \[TheFJK\]' \
  "S7.1 the uberdev:active label census renders the claimed issue"
assert_in "$RENDER_OUT" 're-enter: /uberdev:solve 310' \
  "S7.2 the claim row carries a re-entry command"
assert_in "$RENDER_OUT" 'release:  gh issue edit 310 --remove-label uberdev:active' \
  "S7.3 the claim row carries the release command"
assert_in "$RENDER_OUT" "dispatch status read from: $HARDENED" \
  "S7.4 the dispatch-status root is named"
assert_in "$RENDER_OUT" '#310  backend=codex  state=running  exit_code=  pid=4242' \
  "S7.5 per-issue dispatch status is decoded"
assert_in "$RENDER_OUT" "re-enter: tail -f $HARDENED/solve-codex-stdout-310\.log" \
  "S7.6 the dispatch-status row carries a tail hint"

RENDER_GH_MODE=fail
render gh-down
RENDER_GH_MODE=ok
assert_in "$RENDER_OUT" 'gh: query failed \(rc=1\)' \
  "S7.7 a failing gh degrades with a reported reason instead of aborting"
assert_in "$RENDER_OUT" '#310  backend=codex' \
  "S7.8 local artefacts still render when gh is unavailable"

# ===========================================================================
echo "== S8: agent-lifecycle liveness (not \`claude agents\`) =="
# ===========================================================================
STATE_DIR="$HARDENED/.agent-state-$UID_NOW"
write_lifecycle_fixture "$STATE_DIR"
render lifecycle
assert_in "$RENDER_OUT" "read from: $STATE_DIR/agent-lifecycle\.jsonl" \
  "S8.1 the lifecycle manifest path is named"
assert_in "$RENDER_OUT" 'solve-codex-310-1  LIVE  backend=codex  issue=310' \
  "S8.2 a started-with-no-terminal run is LIVE"
assert_in "$RENDER_OUT" 'owner_pid=4242  timeout_s=3600' \
  "S8.3 the live row carries owner_pid + timeout"
assert_in "$RENDER_OUT" 'solve-codex-311-1  terminal=completed' \
  "S8.4 a terminal run is not counted live"
assert_in "$RENDER_OUT" 'solve-codex-312-1  pending \(routed, never started\)' \
  "S8.5 a routed-but-never-started run is distinguished from LIVE"
assert_in "$RENDER_OUT" 'summary: 1 live, 2 finished-or-unstarted' \
  "S8.6 the liveness census totals are correct"
assert_not_in "$EXEC_ONLY" 'claude agents' \
  "S8.7 liveness is never taken from the claude-bg agent surface"

# ===========================================================================
echo "== S9: /review-pr reservations (FRESH / STALE / ABANDONED) =="
# ===========================================================================
mkdir -p "$RUNS/20260730-120000-aaaaaaa" "$RUNS/20200101-000000-bbbbbbb"
: > "$RUNS/20260730-120000-aaaaaaa/locked"
printf '{"issue":0,"pr":401,"started_at":"2026-07-30T12:00:00Z"}\n' \
  > "$RUNS/20260730-120000-aaaaaaa/pr-context.json"
: > "$RUNS/20200101-000000-bbbbbbb/locked"
printf '{"issue":0,"pr":398,"started_at":"2020-01-01T00:00:00Z"}\n' \
  > "$RUNS/20200101-000000-bbbbbbb/pr-context.json"
touch -t 202001010000 "$RUNS/20200101-000000-bbbbbbb/locked"

# grace 60s with an unreachable reap -> the aged marker is STALE, not reaped.
RENDER_GRACE=60
RENDER_REAP=999999999
render review-stale
assert_in "$RENDER_OUT" 'grace 60s, reap 999999999s' \
  "S9.1 the grace/reap thresholds actually in force are printed"
assert_in "$RENDER_OUT" '20260730-120000-aaaaaaa  pr=401  age=[0-9]+s  FRESH' \
  "S9.2 a just-written reservation is FRESH"
assert_in "$RENDER_OUT" '20200101-000000-bbbbbbb  pr=398  age=[0-9]+s  STALE' \
  "S9.3 a marker older than REVIEW_GRACE_SECS is STALE"
assert_in "$RENDER_OUT" 'in flight for PR #401 — wait for it' \
  "S9.4 the FRESH row hints 'wait', never a re-dispatch"
assert_in "$RENDER_OUT" 're-enter: /uberdev:review-pr 398' \
  "S9.5 the STALE row hints the owning command"
assert_not_in "$RENDER_OUT" 'rm -[rf]+ .*locked' \
  "S9.6 /status never hands the operator a raw rm of a producer's marker"

RENDER_REAP=120
render review-abandoned
RENDER_GRACE=""
RENDER_REAP=""
assert_in "$RENDER_OUT" '20200101-000000-bbbbbbb  pr=398  age=[0-9]+s  ABANDONED' \
  "S9.7 a marker past REVIEW_RESERVATION_REAP_SECS is ABANDONED"

# ===========================================================================
echo "== S10: /merge lock (live heartbeat vs stale heartbeat) =="
# ===========================================================================
mkdir -p "$LOCK_DIR"
printf '{"run_id":"20260730-091500-a1b2c3d","started_at":"2026-07-30T09:15:00Z","workflowRunId":null}\n' \
  > "$LOCK_DIR/record.json"
date +%s > "$LOCK_DIR/heartbeat"
render merge-live
assert_in "$RENDER_OUT" "read from: $LOCK_DIR  \(stale threshold 900s\)" \
  "S10.1 the merge-lock path and the floor threshold are printed"
assert_in "$RENDER_OUT" 'run_id=20260730-091500-a1b2c3d  started=2026-07-30T09:15:00Z  HELD-LIVE' \
  "S10.2 a fresh heartbeat classifies the lock HELD-LIVE"
assert_in "$RENDER_OUT" 'another /merge run owns this lock — wait; do NOT remove the directory' \
  "S10.3 a live lock is never offered for deletion"

touch -t 202001010000 "$LOCK_DIR/heartbeat"
render merge-stale
assert_in "$RENDER_OUT" 'run_id=20260730-091500-a1b2c3d.*STALE \(heartbeat [0-9]+s >= 900s\)' \
  "S10.4 an aged heartbeat classifies the lock STALE (heartbeat age, never started_at)"
assert_in "$RENDER_OUT" 're-enter: /uberdev:merge' \
  "S10.5 the stale lock hints /uberdev:merge, not a hand rm"

printf '{"event":"pr_merged","run_id":"20260730-091500-a1b2c3d","ts":"2026-07-30T09:20:00Z","data":{"pr":401}}\n' \
  > "$WORK_REPO/.uberdev/audit.jsonl"
render merge-audit
assert_in "$RENDER_OUT" '2026-07-30T09:20:00Z  pr_merged  20260730-091500-a1b2c3d  pr=401' \
  "S10.6 the audit tail is decoded into ts / event / run_id / pr"

# ===========================================================================
echo "== S11: empty repo renders a clean census with the roots still probed =="
# ===========================================================================
reset_roots
rm -rf "$WORK_REPO/.uberdev" "$LOCK_DIR"
render empty
assert_eq "$RENDER_RC" "0" "S11.0 an empty repo still exits 0"
assert_in "$RENDER_OUT" '== 0\. runtime-root discovery ==' \
  "S11.1 the discovery section is always rendered"
assert_in "$RENDER_OUT" 'env:UBERDEV_TMPDIR' "S11.2 the env candidate is listed even when unset"
assert_in "$RENDER_OUT" 'dispatch-hardened' "S11.3 the hardened candidate is listed"
assert_in "$RENDER_OUT" 'goal-fallback:TMPDIR' "S11.4 the TMPDIR fallback candidate is listed"
assert_in "$RENDER_OUT" 'goal-fallback:/tmp' "S11.5 the bare /tmp candidate is listed"
assert_in "$RENDER_OUT" 'readable roots \(deduped' "S11.6 the deduped readable-root list is printed"
assert_in "$RENDER_OUT" 'no goal-active-id\.txt under any readable root' "S11.7 no /goal in flight"
assert_in "$RENDER_OUT" 'per-issue dispatch status: none found under any readable root' \
  "S11.8 no dispatch status in flight"
assert_in "$RENDER_OUT" 'runs root absent' "S11.9 no /review-pr reservation"
assert_in "$RENDER_OUT" 'no lock held; probed:' "S11.10 no /merge lock held"
assert_in "$RENDER_OUT" 'no lifecycle manifest under any readable root' "S11.11 no dispatched agent"
assert_in "$RENDER_OUT" 'Nothing above was created, modified, or deleted' \
  "S11.12 the read-only claim is stated"

# ===========================================================================
echo "== S12: READ-ONLY — a full render mutates nothing =="
# ===========================================================================
reset_roots
write_goal_fixture "$HARDENED" readonlygoal 2
write_goal_fixture "$FAKE_TMP" readonlyfallback 5
write_goal_fixture "$ALT_ROOT" readonlyalt 1
write_lifecycle_fixture "$HARDENED/.agent-state-$UID_NOW"
printf '{"issue":310,"tier":"medium","backend":"codex","state":"running","pid":4242}\n' \
  > "$HARDENED/solve-codex-status-310.json"
mkdir -p "$RUNS/20260730-120000-aaaaaaa" "$LOCK_DIR"
: > "$RUNS/20260730-120000-aaaaaaa/locked"
printf '{"issue":0,"pr":401,"started_at":"2026-07-30T12:00:00Z"}\n' \
  > "$RUNS/20260730-120000-aaaaaaa/pr-context.json"
printf '{"run_id":"20260730-091500-a1b2c3d","started_at":"2026-07-30T09:15:00Z","workflowRunId":null}\n' \
  > "$LOCK_DIR/record.json"
date +%s > "$LOCK_DIR/heartbeat"
printf '{"event":"pr_merged","run_id":"x","ts":"2026-07-30T09:20:00Z","data":{"pr":401}}\n' \
  > "$WORK_REPO/.uberdev/audit.jsonl"

# An invalid configured threshold is the exact input that makes config-read.sh's
# uberdev_read_int_in_range append a row to .uberdev/audit.jsonl. /status must
# classify with the documented default AND still write nothing.
RENDER_GRACE=not-a-number
RENDER_UBERDEV_TMPDIR="$ALT_ROOT"
RENDER_GH_JSON='[{"number":310,"title":"claimed","assignees":[]}]'
snapshot "$TMPROOT/before.snap"
render readonly
snapshot "$TMPROOT/after.snap"
RENDER_GRACE=""
RENDER_UBERDEV_TMPDIR=""
RENDER_GH_JSON='[]'
assert_eq "$RENDER_RC" "0" "S12.0 the read-only render exits 0"
if diff -u "$TMPROOT/before.snap" "$TMPROOT/after.snap" > "$TMPROOT/readonly.diff" 2>&1; then
  pass "S12.1 fixture tree is identical after a full render (path/type/mode/size/mtime/sha256)"
else
  fail "S12.1 fixture tree is identical after a full render"
  sed -n '1,40p' "$TMPROOT/readonly.diff" | sed 's/^/        /'
fi
assert_in "$RENDER_OUT" 'grace 3600s' \
  "S12.2 an invalid goal.review_grace_secs falls back to the documented default"
assert_in "$RENDER_OUT.err" 'goal\.review_grace_secs = not-a-number is invalid' \
  "S12.3 the invalid threshold is surfaced on stderr, never swallowed"

# ===========================================================================
echo "== S13: per-file ownership gate + root-probe verdicts =="
# ===========================================================================
# shellcheck source=/dev/null
. "$STATUS_LIB"

PROBE="$(_uberdev_status_probe_root "$FAKE_TMP" private)"
assert_eq "${PROBE%% *}" "ok" "S13.1 an owned directory probes ok under the private rule"
PROBE="$(_uberdev_status_probe_root "$TMPROOT/definitely-absent" private)"
assert_eq "${PROBE%% *}" "absent" "S13.2 a missing candidate probes absent"
: > "$TMPROOT/not-a-dir"
PROBE="$(_uberdev_status_probe_root "$TMPROOT/not-a-dir" private)"
assert_eq "${PROBE%% *}" "not-directory" "S13.3 a non-directory candidate is rejected"

# The bare-/tmp case: root-owned on every Linux host. A private-rule probe must
# refuse it; the shared rule must accept it (and push the check down to files).
if [ "$UID_NOW" != "0" ] && [ -d /usr ] && [ ! -O /usr ]; then
  PROBE="$(_uberdev_status_probe_root /usr private)"
  assert_eq "${PROBE%% *}" "owner-mismatch" "S13.4 a foreign-owned PRIVATE root is refused"
  PROBE="$(_uberdev_status_probe_root /usr shared)"
  assert_eq "${PROBE%% *}" "ok-shared" "S13.5 a foreign-owned SHARED root is accepted"
else
  pass "S13.4 skipped — running as root, or /usr is owned by this uid"
  pass "S13.5 skipped — running as root, or /usr is owned by this uid"
fi

: > "$TMPROOT/owned-file"
if _uberdev_status_readable_file shared "$TMPROOT/owned-file"; then
  pass "S13.6 an owned regular file passes the shared-root gate"
else
  fail "S13.6 an owned regular file passes the shared-root gate"
fi
if ln -s "$TMPROOT/owned-file" "$TMPROOT/link-file" 2>/dev/null && [ -L "$TMPROOT/link-file" ]; then
  if _uberdev_status_readable_file shared "$TMPROOT/link-file"; then
    fail "S13.7 a symlink is refused by the shared-root gate"
  else
    pass "S13.7 a symlink is refused by the shared-root gate"
  fi
else
  pass "S13.7 skipped — this filesystem does not create real symlinks"
fi

# The load-bearing half of the shared-root design: a shared root is accepted
# (S13.5) precisely BECAUSE the per-FILE euid check refuses foreign content
# underneath it. Without a negative assert, deleting `[ -O "$target" ]` would
# leave the suite green while /status printed another user's /tmp artefacts.
# /etc/hosts is a foreign-owned, world-readable, non-symlink regular file on
# both ubuntu-latest and macOS — the two halves are asserted as a PAIR so the
# refusal is provably the OWNERSHIP check and not -f/-r failing.
if [ "$UID_NOW" != "0" ] && [ -f /etc/hosts ] && [ ! -L /etc/hosts ] \
   && [ -r /etc/hosts ] && [ ! -O /etc/hosts ]; then
  if _uberdev_status_readable_file shared /etc/hosts; then
    fail "S13.8 a foreign-owned regular file is REFUSED under a shared root"
  else
    pass "S13.8 a foreign-owned regular file is REFUSED under a shared root"
  fi
  if _uberdev_status_readable_file private /etc/hosts; then
    pass "S13.9 the same file is accepted under a private root (the gate is role-scoped)"
  else
    fail "S13.9 the same file is accepted under a private root (the gate is role-scoped)"
  fi
else
  pass "S13.8 skipped — running as root, or /etc/hosts is not a foreign-owned regular file"
  pass "S13.9 skipped — running as root, or /etc/hosts is not a foreign-owned regular file"
fi

# The directory twin of the same gate (goal sidecar roots are walked with it).
if [ "$UID_NOW" != "0" ] && [ -d /usr ] && [ ! -L /usr ] && [ ! -O /usr ]; then
  if _uberdev_status_readable_dir shared /usr; then
    fail "S13.10 a foreign-owned directory is REFUSED by the shared-root dir gate"
  else
    pass "S13.10 a foreign-owned directory is REFUSED by the shared-root dir gate"
  fi
else
  pass "S13.10 skipped — running as root, or /usr is not a foreign-owned directory"
fi

# ===========================================================================
echo "== S14: cross-shell — the RENDERED census is byte-identical under zsh =="
# ===========================================================================
# S1.16 can only catch a load failure: uberdev_status_render always returns 0 by
# design ("a status reader that aborts on the first unreadable store is useless"),
# so an exit-code assert is unfalsifiable for wrong-VALUE regressions. Every
# other section pins `bash -c`, yet /uberdev:status runs through the Bash tool,
# which is /bin/zsh on macOS. This section drives the SAME fixture through both
# interpreters and diffs the output, with the two safety-critical verdicts
# (HELD-LIVE merge lock, FRESH review reservation) asserted against the ZSH
# render specifically — those are the rows whose inversion tells an operator to
# steal a lock that a live run still owns.
if command -v zsh >/dev/null 2>&1; then
  reset_roots
  rm -rf "$WORK_REPO/.uberdev" "$LOCK_DIR"
  write_goal_fixture "$HARDENED" crossshell 3
  write_lifecycle_fixture "$HARDENED/.agent-state-$UID_NOW"
  printf '{"issue":310,"tier":"medium","backend":"codex","state":"running","pid":4242}\n' \
    > "$HARDENED/solve-codex-status-310.json"
  mkdir -p "$RUNS/20260730-120000-aaaaaaa" "$LOCK_DIR"
  : > "$RUNS/20260730-120000-aaaaaaa/locked"
  printf '{"issue":0,"pr":401,"started_at":"2026-07-30T12:00:00Z"}\n' \
    > "$RUNS/20260730-120000-aaaaaaa/pr-context.json"
  printf '{"run_id":"20260730-091500-a1b2c3d","started_at":"2026-07-30T09:15:00Z","workflowRunId":null}\n' \
    > "$LOCK_DIR/record.json"
  date +%s > "$LOCK_DIR/heartbeat"

  # The unit-level smoking gun first: _uberdev_status_mtime is the single
  # external-command probe every age/verdict is derived from.
  touch -t 202001010000 "$TMPROOT/mtime-probe"
  MTIME_BASH="$(bash -c 'set -u; . "$1" && _uberdev_status_mtime "$2"' _ "$STATUS_LIB" "$TMPROOT/mtime-probe" 2>/dev/null)"
  MTIME_ZSH="$(zsh -c 'set -u; . "$1" && _uberdev_status_mtime "$2"' _ "$STATUS_LIB" "$TMPROOT/mtime-probe" 2>/dev/null)"
  case "$MTIME_BASH" in
    ''|*[!0-9]*) fail "S14.0 _uberdev_status_mtime returns an epoch int under bash (got '$MTIME_BASH')" ;;
    *) pass "S14.0 _uberdev_status_mtime returns an epoch int under bash" ;;
  esac
  assert_eq "$MTIME_ZSH" "$MTIME_BASH" \
    "S14.1 _uberdev_status_mtime returns the SAME epoch int under zsh (zsh 'path' is \$PATH)"

  RENDER_SHELL="bash"
  render xshell-bash
  XS_BASH="$RENDER_OUT"
  XS_BASH_RC="$RENDER_RC"
  RENDER_SHELL="zsh"
  render xshell-zsh
  XS_ZSH="$RENDER_OUT"
  XS_ZSH_RC="$RENDER_RC"
  RENDER_SHELL="bash"

  assert_eq "$XS_ZSH_RC" "$XS_BASH_RC" "S14.2 both shells exit with the same status"

  # Only the elapsed-time values are normalised — the two renders are seconds
  # apart. Thresholds ("grace 3600s", "stale threshold 900s") are deliberately
  # NOT normalised, so a config-resolution divergence still reds. An `age=?s`
  # (the age-unknown signature of the zsh $PATH clobber) does not match the
  # numeric normaliser and therefore survives into the diff.
  normalise_ages() {   # IN OUT
    sed -E 's/(age[ =])[0-9]+s/\1<N>s/g; s/heartbeat [0-9]+s/heartbeat <N>s/g; s/^generated_at:.*/generated_at: <TS>/' \
      "$1" > "$2"
  }
  normalise_ages "$XS_BASH" "$XS_BASH.norm"
  normalise_ages "$XS_ZSH" "$XS_ZSH.norm"
  if diff -u "$XS_BASH.norm" "$XS_ZSH.norm" > "$TMPROOT/xshell.diff" 2>&1; then
    pass "S14.3 the rendered census is byte-identical under bash and zsh"
  else
    fail "S14.3 the rendered census is byte-identical under bash and zsh"
    sed -n '1,60p' "$TMPROOT/xshell.diff" | sed 's/^/        /'
  fi

  # Asserted against the ZSH render specifically: these are the rows that invert
  # when an external probe silently fails, and inverting them tells the operator
  # to re-dispatch an in-flight review or steal a live merge lock.
  assert_in "$XS_ZSH" 'run_id=20260730-091500-a1b2c3d  started=2026-07-30T09:15:00Z  HELD-LIVE \(heartbeat [0-9]+s ago\)' \
    "S14.4 zsh classifies a live merge lock HELD-LIVE with a numeric heartbeat age"
  assert_not_in "$XS_ZSH" 'STALE \(heartbeat missing or unreadable' \
    "S14.5 zsh never reports a present, readable heartbeat as missing"
  assert_in "$XS_ZSH" 'another /merge run owns this lock — wait; do NOT remove the directory' \
    "S14.6 zsh hints 'wait', never the stale-lock reclaim hint, for a live lock"
  assert_in "$XS_ZSH" '20260730-120000-aaaaaaa  pr=401  age=[0-9]+s  FRESH' \
    "S14.7 zsh classifies a just-written /review-pr reservation FRESH with a numeric age"
  assert_not_in "$XS_ZSH" 'age=\?s  age-unknown' \
    "S14.8 zsh resolves the reservation age instead of degrading to age-unknown"
  assert_in "$XS_ZSH" 'in flight for PR #401 — wait for it' \
    "S14.9 zsh hints 'wait', never '/uberdev:review-pr 401', for a FRESH reservation"
  assert_in "$XS_ZSH" '#310 (pushed-reviewing|solving) \(age [0-9]+s\)' \
    "S14.10 zsh resolves the goal TSV ages through awk (awk is external too)"
else
  for n in 0 1 2 3 4 5 6 7 8 9 10; do
    pass "S14.$n skipped — zsh not installed on this host"
  done
fi

echo
echo "  ---"
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
