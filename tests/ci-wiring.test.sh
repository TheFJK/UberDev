#!/usr/bin/env bash
# tests/ci-wiring.test.sh — drift-guard for .github/workflows/test.yml.
# Issue #210: locks the SYNC convention between the shape-checks ubuntu and
# shape-checks-windows jobs into an enforced invariant so a new
# tests/*.test.sh that is committed on disk but NOT wired into the ubuntu
# shape-checks job reds CI immediately (closes the silent-orphan failure
# mode of #196). Ubuntu is the completeness oracle; windows is the subset
# (Unix-only fixtures are declared in the marker block — see W4).
#
# Invariants:
#   W1  — every tests/*.test.sh on disk is wired into the ubuntu
#         shape-checks job's run: block. Ubuntu is the completeness oracle.
#   W1b — the ubuntu job has no references to nonexistent test files.
#   W2  — the windows shape-checks-windows job is a subset of the ubuntu
#         job (no windows-only entries or stray refs).
#   W3  — the windows job has no references to nonexistent test files.
#   W4  — (ubuntu − windows) equals the canonical windows-skip-list marker
#         block delimited by `# === BEGIN ci-wiring windows-skip-list ===`
#         / `# === END ci-wiring windows-skip-list ===` in test.yml. A new
#         Unix-only fixture cannot be added to ubuntu without also being
#         declared in the marker block, and the marker block cannot drift
#         from the actual skip set.
#   W5  — the Linux job retains its evidence-based 40-minute hang guard.
#   W6  — the Windows job retains its evidence-based 30-minute hang guard.
#   W7  — the dispatcher-owned child-worktree teardown runs on Linux AND
#         macOS. It used to be receipt retirement on all three runners; #381
#         deleted lib/worktree_receipts.py with the codex backend that was its
#         only caller, and the teardown that replaced it (RULING 4) is a
#         declared Unix-only fixture, so native Windows is no longer in the set.
#         Recorded as a real coverage loss, not quietly dropped.
#   W9  — every fixture the windows-skip-list DECLARES Unix-only refuses to run
#         under Git Bash, and the enforcing set equals the declared set in BOTH
#         directions. W1-W4 compare filenames, so before this the declaration
#         was forgeable: a wired file could nest a declared-skipped fixture and
#         W4 stayed green (#520). Because the two sets are locked together,
#         un-skipping a fixture stays one atomic edit.
#   W10 — no tests/*.test.sh may announce that it is asserting nothing and then
#         finish with a zero status. That shape made a file wired INTO the
#         windows job certify sixteen rows it never ran (#520).
#         BOUNDARY: W10 catches the ANNOUNCED bail-out only. A silent one — a
#         body wrapped in a host conditional that falls through to EOF, or a
#         bail-out worded without a "skip" token — is not caught. The per-file
#         executed-row floor (see tests/ubersimplify-aggregate.test.sh) is the
#         mechanism for that, and is required of any new file gating on an
#         optional dependency.
#   W12 — no job joins its test list into ONE `&&` command list, so the first
#         non-zero exit can no longer skip every invocation after it (#628).
#         Includes an EXECUTION proof: the harness the run: blocks actually
#         carry is extracted from the workflow and run against a failing
#         fixture, and must still reach the fixtures behind it.
#   W11 — the macOS supervision job's block is comment-stripped before any
#         wiring grep, so the required-subset floor and W7 are satisfied by the
#         FACT that the job runs a fixture and never by a comment CLAIMING it
#         does. #548 put prose inside that block, which is what opened the
#         surface; the row re-runs the floor's own predicate against exactly
#         that forgery.
#
# Portable: bash + awk + grep + sed + sort + comm + mktemp. Runs on
# ubuntu-latest (native bash) and windows-latest (Git Bash) without any extra
# deps.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

# macOS is the only BSD/userland signal in the matrix, and process-supervision
# primitives are exactly where it diverges. #381 removed three fixtures from
# this job (review-pr-codex-entry -> renamed, review-pr-codex-six-child and
# worktree-receipts -> deleted with the codex backend), so the job is BACKFILLED
# rather than left thinner: the renamed entrypoint test, the Workflow-native
# review driver that replaced the six-child codex driver, and the real-git
# child-worktree teardown that replaced the receipt transaction.
#
# #548 added dispatch-background and dispatch-wezterm. Each binds the runtime
# PATH its dispatch runs under and then asserts WHICH preflight arm that
# dispatch took (bounded vs unbounded). RFC 0004 §3.8 has the resolver try the
# absolute /usr/bin/timeout BEFORE any PATH name, and both ubuntu-latest and
# windows-latest ship one — so on those two runners the arm row passes whether
# or not the binding keeps the host $PATH. macOS (no /usr/bin/timeout; the real
# binary arrives via `brew install coreutils`) is the ONLY runner where the
# widening changes behaviour, so this wiring is what stops that row being a
# permanent tautology. Dropping either file from the job silently restores the
# tautology, which is why the floor names them.
#
# The floor below and W7 both grep this block for `bash tests/<name>`, so the
# block must carry only what the job DOES. Strip whole-line comments at capture
# — the same "comment-strip BEFORE grep" convention this file applies to the
# ubuntu and windows sets and states its reason for further down. Until #548 the
# macOS block held no whole-line comment at all and the raw capture was harmless;
# the nine lines of prose above the `run:` chain are what opened the surface, so
# the strip lands with them. W11 re-runs the floor's predicate against a forged
# comment and reds if this is ever simplified back out.
macos_supervision_block_of() {  # $1 = a workflow file -> that job's block on stdout
  awk '/^  supervision-smoke-macos:/,/^  shape-checks-windows:/' "$1" \
    | grep -v '^[[:space:]]*#'
}
macos_supervision_block=$(macos_supervision_block_of "$WORKFLOW")
for required in review-pr-entry.test.sh agent-dispatch.test.sh \
                dispatch-child-worktree-teardown.test.sh \
                child-dispatch.test.sh \
                dispatch-background.test.sh \
                dispatch-wezterm.test.sh \
                review-pr-workflow.test.sh; do
  if ! grep -q "bash tests/$required" <<<"$macos_supervision_block"; then
    echo "  FAIL  macOS supervision smoke job is missing $required"
    exit 1
  fi
done

PASS=0; FAIL=0
echo "## ci-wiring drift guard (#210)"

if [ ! -r "$WORKFLOW" ]; then
  echo "  ABORT — workflow file missing or unreadable: $WORKFLOW"; exit 99
fi
if [ ! -d "$REPO_ROOT/tests" ]; then
  echo "  ABORT — tests/ directory missing: $REPO_ROOT/tests"; exit 99
fi

# Both were sized for a job that ran the WHOLE suite. Each job is now a shard of
# it (six on Linux and Windows, two on macOS), so the same ceilings would be a
# 10x licence to hang rather than a guard. Twelve is roughly 3x the packed
# ~219s a Linux shard carries -- headroom for runner variance, not for a hang.
LINUX_TIMEOUT_MINUTES=12
WINDOWS_TIMEOUT_MINUTES=12
# How many shards each job's matrix declares. W13 reads these back out of the
# workflow rather than trusting them, so a matrix widened without updating this
# file is a failure and not a silently half-run suite.
LINUX_SHARDS=6
WINDOWS_SHARDS=6
MACOS_SHARDS=2
linux_job_block=$(awk '
  /^  shape-checks:[[:space:]]*$/ { in_job=1; next }
  in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
  in_job { print }
' "$WORKFLOW")
windows_job_block=$(awk '
  /^  shape-checks-windows:[[:space:]]*$/ { in_job=1; next }
  in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
  in_job { print }
' "$WORKFLOW")

on_disk=$(cd "$REPO_ROOT" && ls tests/*.test.sh 2>/dev/null | sed 's#tests/##' | sort -u)
if [ -z "$on_disk" ]; then
  echo "  ABORT — no tests/*.test.sh on disk"; exit 99
fi

# Comment-strip BEFORE grep so references inside free-text comments
# (e.g. "mirroring secret-scan.test.sh") never pollute the wiring set.
#
# Both sets are derived from the JOB BLOCKS above, which stop at the next job
# key, rather than from an awk range. The ranges these replace were wrong in
# both directions and only accidentally harmless: `/^  shape-checks:/,/^
# shape-checks-windows:/` swallowed supervision-smoke-macos, so a macOS-only
# fixture would have been certified as ubuntu-wired, and `/^
# shape-checks-windows:/,0` runs to EOF, so a job appended after it would be
# read as windows wiring. Verified set-neutral on the tree at the time of the
# change (#520): both forms yield the identical name sets.
ubuntu_wired=$(printf '%s\n' "$linux_job_block" \
  | grep -v '^[[:space:]]*#' \
  | grep -oE 'tests/[a-zA-Z0-9._-]+\.test\.sh' | sed 's#tests/##' | sort -u)
windows_wired=$(printf '%s\n' "$windows_job_block" \
  | grep -v '^[[:space:]]*#' \
  | grep -oE 'tests/[a-zA-Z0-9._-]+\.test\.sh' | sed 's#tests/##' | sort -u)

# Canonical windows-skip-list marker block. Lines of the form `#   - foo.test.sh`
# between the BEGIN/END delimiters; everything else inside the block is ignored
# so an in-block comment line ("# Update both this block AND the run: block.")
# does not pollute the set.
marker_block=$(awk '
  /^[[:space:]]*#[[:space:]]+===[[:space:]]+BEGIN ci-wiring windows-skip-list[[:space:]]+===/ { inb=1; next }
  /^[[:space:]]*#[[:space:]]+===[[:space:]]+END ci-wiring windows-skip-list[[:space:]]+===/   { inb=0 }
  inb { print }
' "$WORKFLOW" \
  | grep -oE '#[[:space:]]+-[[:space:]]+[a-zA-Z0-9._-]+\.test\.sh' \
  | grep -oE '[a-zA-Z0-9._-]+\.test\.sh' | sort -u)

# W1 — every on-disk test must be wired into ubuntu.
missing_from_ubuntu=$(comm -23 <(echo "$on_disk") <(echo "$ubuntu_wired"))
if [ -z "$missing_from_ubuntu" ]; then
  echo "  PASS  W1 every tests/*.test.sh is wired into the ubuntu shape-checks job"
  PASS=$((PASS+1))
else
  echo "  FAIL  W1 these on-disk tests are NOT wired into the ubuntu shape-checks job:"
  printf '          %s\n' $missing_from_ubuntu
  echo "         Add them to .github/workflows/test.yml under the shape-checks job's run: block."
  FAIL=$((FAIL+1))
fi

# W1b — ubuntu must not reference nonexistent tests.
phantom_in_ubuntu=$(comm -13 <(echo "$on_disk") <(echo "$ubuntu_wired"))
if [ -z "$phantom_in_ubuntu" ]; then
  echo "  PASS  W1b the ubuntu job has no references to nonexistent test files"
  PASS=$((PASS+1))
else
  echo "  FAIL  W1b the ubuntu job references tests that do NOT exist on disk:"
  printf '          %s\n' $phantom_in_ubuntu
  FAIL=$((FAIL+1))
fi

# W2 — windows must be a subset of ubuntu.
windows_only=$(comm -13 <(echo "$ubuntu_wired") <(echo "$windows_wired"))
if [ -z "$windows_only" ]; then
  echo "  PASS  W2 the windows job is a subset of the ubuntu job"
  PASS=$((PASS+1))
else
  echo "  FAIL  W2 the windows job references tests NOT in the ubuntu job (windows-only or phantom):"
  printf '          %s\n' $windows_only
  FAIL=$((FAIL+1))
fi

# W3 — windows must not reference nonexistent tests.
phantom_in_windows=$(comm -13 <(echo "$on_disk") <(echo "$windows_wired"))
if [ -z "$phantom_in_windows" ]; then
  echo "  PASS  W3 the windows job has no references to nonexistent test files"
  PASS=$((PASS+1))
else
  echo "  FAIL  W3 the windows job references tests that do NOT exist on disk:"
  printf '          %s\n' $phantom_in_windows
  FAIL=$((FAIL+1))
fi

# W4 — (ubuntu - windows) must equal the marker block exactly.
actual_skipped=$(comm -23 <(echo "$ubuntu_wired") <(echo "$windows_wired"))
if [ -z "$marker_block" ]; then
  echo "  FAIL  W4 the windows-skip-list marker block is missing or empty in test.yml"
  echo "         Expected a block delimited by:"
  echo "           # === BEGIN ci-wiring windows-skip-list ==="
  echo "           # === END ci-wiring windows-skip-list ==="
  echo "         with one entry per line in the form '#   - <filename>.test.sh'."
  FAIL=$((FAIL+1))
elif [ "$actual_skipped" = "$marker_block" ]; then
  echo "  PASS  W4 (ubuntu − windows) matches the windows-skip-list marker block"
  PASS=$((PASS+1))
else
  echo "  FAIL  W4 (ubuntu − windows) drifted from the windows-skip-list marker block."
  echo "         marker block declares:"
  printf '           %s\n' $marker_block
  echo "         actual (ubuntu − windows):"
  printf '           %s\n' $actual_skipped
  echo "         Either wire the missing tests into windows OR update the marker block to match."
  echo "         Marker block lives in .github/workflows/test.yml between"
  echo "           # === BEGIN ci-wiring windows-skip-list ==="
  echo "           # === END ci-wiring windows-skip-list ==="
  FAIL=$((FAIL+1))
fi

# W5 — the Linux job's hang guard, resized for a shard.
#
# The 40-minute ceiling this replaces was evidence-based for a job that ran all
# ~130 fixtures sequentially: the complete matrix exhausted a 30-minute budget
# even though its final suite reported 91/0 immediately before cancellation.
# That job no longer exists. Each shard carries ~219s of measured work, so the
# old number is not conservative, it is inert -- a guard that cannot fire before
# the run is long dead is not a guard.
linux_timeout_rows=$(printf '%s\n' "$linux_job_block" \
  | sed -n 's/^    timeout-minutes:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p')
if [ "$linux_timeout_rows" = "$LINUX_TIMEOUT_MINUTES" ]; then
  echo "  PASS  W5 the linux job timeout is ${LINUX_TIMEOUT_MINUTES} minutes"
  PASS=$((PASS+1))
else
  echo "  FAIL  W5 the linux job must have exactly one ${LINUX_TIMEOUT_MINUTES}-minute timeout"
  echo "         observed timeout rows: ${linux_timeout_rows:-<none>}"
  FAIL=$((FAIL+1))
fi

# W6 — the Windows job's hang guard, resized for the same reason as W5.
#
# Windows keeps the largest relative margin of the three: Git Bash process
# spawning is the slowest runner and its 19-minute measured total is the least
# precisely attributed per fixture, so its shards are the ones most likely to
# come in over the pack's estimate.
windows_timeout_rows=$(printf '%s\n' "$windows_job_block" \
  | sed -n 's/^    timeout-minutes:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p')
if [ "$windows_timeout_rows" = "$WINDOWS_TIMEOUT_MINUTES" ]; then
  echo "  PASS  W6 the windows job timeout is ${WINDOWS_TIMEOUT_MINUTES} minutes"
  PASS=$((PASS+1))
else
  echo "  FAIL  W6 the windows job must have exactly one ${WINDOWS_TIMEOUT_MINUTES}-minute timeout"
  echo "         observed timeout rows: ${windows_timeout_rows:-<none>}"
  FAIL=$((FAIL+1))
fi

# W7 — the dispatcher-owned child-worktree teardown exercises real git and real
# filesystem semantics on both POSIX runners. It is the successor to the receipt
# transaction #381 deleted; native Windows is NOT in the set because the fixture
# is declared Unix-only in the windows-skip-list (real `git worktree add`, nohup
# detachment, a POSIX geteuid predicate). Losing the Windows runner for this
# guarantee is a stated cost of retiring the codex arm, recorded here so it
# cannot be mistaken for coverage that still exists.
teardown_test='bash tests/dispatch-child-worktree-teardown.test.sh'
missing_teardown_jobs=''
for job_and_block in \
  "Linux|$linux_job_block" \
  "macOS|$macos_supervision_block"; do
  job=${job_and_block%%|*}
  block=${job_and_block#*|}
  if ! grep -qF "$teardown_test" <<<"$block"; then
    missing_teardown_jobs="${missing_teardown_jobs}${missing_teardown_jobs:+, }$job"
  fi
done
if [ -z "$missing_teardown_jobs" ]; then
  echo "  PASS  W7 child-worktree teardown runs on Linux and macOS"
  PASS=$((PASS+1))
else
  echo "  FAIL  W7 child-worktree teardown is missing from: $missing_teardown_jobs"
  FAIL=$((FAIL+1))
fi

# W11 — the macOS haystack must carry FACT, not CLAIM (#548).
#
# The required-subset floor and W7 both read $macos_supervision_block, and both
# predicates are a bare grep for `bash tests/<name>`. #548 added nine lines of
# prose inside that awk range, so from then on a comment could satisfy either
# guard: drop `bash tests/dispatch-wezterm.test.sh` from the run: chain, write
# `# dropped for speed: bash tests/dispatch-wezterm.test.sh` beside it, and a
# guard whose entire purpose is to prove the fixture RUNS certifies wiring that
# does not exist — measured rc=0, 22 PASS / 0 FAIL on exactly that mutation.
# That is the forgeable-declaration shape W9 exists to close, so it is closed
# here rather than left as a documented hole.
#
# The forgery is driven through macos_supervision_block_of — the SAME capture
# the floor and W7 consume — over a mutated COPY of the real workflow, never
# through a re-implementation of it here. A row that re-stripped the comments
# itself would pass whatever the capture does, which is the disjoint-predicate
# failure this suite keeps finding in other people's guards.
#
# Both arms are load-bearing. The negative arm alone would pass on a stale probe
# name: the awk would rewrite no line, and the misspelled needle would be absent
# from both blocks either way. The positive arm is what keeps the probe honest,
# and it also proves the strip does not eat genuine wiring.
w11_probe='dispatch-wezterm.test.sh'
w11_fx_dir="$(mktemp -d)"
# The mutation targets any NON-COMMENT line that names the probe, rather than a
# line that begins with `bash `. #628 de-chained the run: blocks, so the live
# spelling is now `run_one bash tests/<name>` and a shape-anchored mutation
# rewrote nothing — leaving the real wiring in the "forged" copy and reporting a
# forgery that had not happened. Keying on "names the fixture and is not already
# a comment" is what the forgery actually is, and it survives the next
# re-spelling of the invocation.
awk -v claim="bash tests/$w11_probe" '
  index($0, claim) && $0 !~ /^[[:space:]]*#/ { print "        # dropped for speed: " claim; next }
  { print }
' "$WORKFLOW" > "$w11_fx_dir/test.yml"
w11_forged_block="$(macos_supervision_block_of "$w11_fx_dir/test.yml")"
rm -rf "$w11_fx_dir"
w11_err=''
if [ -z "$w11_forged_block" ]; then
  # A failed mktemp or an unwritable copy leaves an EMPTY block, in which the
  # forged claim is absent for the wrong reason — the negative arm below would
  # pass having tested nothing. Fail loudly instead.
  w11_err='the forged workflow copy yielded no macOS block — mktemp or the copy failed'
elif ! grep -q "bash tests/$w11_probe" <<<"$macos_supervision_block"; then
  w11_err="the macOS block no longer wires $w11_probe — the probe is stale or the strip ate real wiring"
elif grep -q "bash tests/$w11_probe" <<<"$w11_forged_block"; then
  w11_err="a comment claiming $w11_probe satisfies the macOS floor — capture the block comment-stripped"
fi
if [ -z "$w11_err" ]; then
  echo "  PASS  W11 the macOS floor reads wiring, not comments claiming it"
  PASS=$((PASS+1))
else
  echo "  FAIL  W11 $w11_err"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# W9 / W10 — the coverage matrix must state something about EXECUTION, not
# about filenames (#520).
#
# W1-W4 above compare two lists of NAMES. That predicate cannot tell a file
# that is LISTED for a job from one that ASSERTS anything there, so both halves
# of the matrix were forgeable:
#
#   * a fixture the marker block declares Unix-only could still be executed on
#     windows-latest by a wired file that nests it — tests/simplify.test.sh
#     runs tests/simplify-standalone-flow.test.sh directly, and W4 stayed green
#     because the nested name never appears in the windows run: block; and
#   * a file wired INTO the windows job could finish with a zero status having
#     asserted nothing — tests/ubersimplify-aggregate.test.sh abandoned its
#     whole body (all 16 rows, including the #183 envelope-breakout security
#     rows) when PyYAML was absent, and W4 counted it as covered.
#
# W9 closes the first half AT RUNTIME: every declared Unix-only fixture carries
# a refusal guard, and the ENFORCING set equals the DECLARED set in both
# directions, so a nested execution on Git Bash reds instead of silently
# certifying, and un-declaring a fixture stays one atomic edit.
#
# W10 closes the second half by banning the whole-file bail-out shape outright:
# no tests/*.test.sh may announce that it is asserting nothing and then finish
# with a zero status. A file that gates on an optional dependency must refuse
# (non-zero) or run its rows.
#
# DECLARED BOUNDARY — W10 catches the ANNOUNCED bail-out: a line that says
# "skip" through echo/printf, followed within three lines by a zero-status
# exit. It does NOT catch a silent one — a body wrapped in a host conditional
# that falls through to EOF, or a bail-out worded without that token. So W10 is
# a corpus-wide floor, not a proof that every wired file asserts on every host.
# The per-file executed-row floor (see tests/ubersimplify-aggregate.test.sh) is
# the mechanism for that, and is required of any new file that gates on an
# optional dependency. A guard whose name promises more than its predicate
# delivers is the #370 / RFC 0016 shape, so the promise is written down rather
# than left implied.
#
# SELF-TRIP WARNING: this file IS a tests/*.test.sh and IS inside both corpora
# below. The guard token is assembled from fragments and the W10 fixtures are
# written with printf escapes, so neither needle ever appears contiguously in
# these bytes — the same discipline as tests/test-harness-source-guards.test.sh
# A3/A4. W10.1 and W9.2 scanning this very file is what keeps that honest.
# ---------------------------------------------------------------------------

# Assembled, never contiguous: W9.2 greps every tests/*.test.sh for this token
# and would otherwise name ci-wiring.test.sh as an undeclared enforcer.
GUARD_MARK='# ci-wiring: declared Unix-''only'

# guard_state — reads a test file's source on stdin and prints one word:
#   present     the complete refusal guard IS the file's first executable
#               statement
#   incomplete  it is first, but the Git-Bash branch or the non-zero exit is
#               gone
#   misplaced   the token is in the file, but not as the first statement
#   missing     the token is absent
# "First executable statement" = the first line that is not the #! line, not a
# comment, not blank, and not a `set …` options line.
# Bracket classes rather than backslash escapes throughout: the BSD, GNU and
# MSYS awks this suite runs under disagree least about those. `[[:space:]]*$`
# absorbs the trailing CR a core.autocrlf=true Windows checkout leaves behind.
GUARD_STATE_AWK='
  !mark_at && index($0, MARK) > 0 { mark_at = FNR }
  mark_at && FNR > mark_at && FNR <= mark_at + 5 {
    if ($0 ~ /MINGW[*][|]MSYS[*][|]CYGWIN[*]/) branch = 1
    if ($0 ~ /(^|[;&|[:space:]])exit[[:space:]]+2([[:space:]]|;|$)/) refuses = 1
  }
  seen { next }
  FNR == 1 && /^#!/ { next }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*set[[:space:]]/ { next }
  { first = $0; first_at = FNR; seen = 1 }
  END {
    if (mark_at == 0) { print "missing"; exit }
    if (!seen || first_at != mark_at + 1 || first !~ /^[[:space:]]*case[[:space:]]+"[$][(]uname[[:space:]]+-s[)]"[[:space:]]+in[[:space:]]*$/) {
      print "misplaced"; exit
    }
    if (!branch || !refuses) { print "incomplete"; exit }
    print "present"
  }
'
guard_state() { awk -v MARK="$GUARD_MARK" "$GUARD_STATE_AWK"; }

# W9.0 — the declared set must be non-empty and every entry must resolve to a
# readable file. A marker typo would otherwise let W9.1 pass over a shorter
# set, and a marker block that stopped parsing would let it pass over nothing.
w9_declared_count=0
w9_resolved_count=0
w9_unresolved=''
while IFS= read -r w9_name; do
  [ -n "$w9_name" ] || continue
  w9_declared_count=$((w9_declared_count+1))
  if [ -r "$REPO_ROOT/tests/$w9_name" ]; then
    w9_resolved_count=$((w9_resolved_count+1))
  else
    w9_unresolved="${w9_unresolved}${w9_unresolved:+ }$w9_name"
  fi
done <<EOF
$marker_block
EOF
if [ "$w9_declared_count" -gt 0 ] && [ "$w9_resolved_count" -eq "$w9_declared_count" ]; then
  echo "  PASS  W9.0 the windows-skip-list declares $w9_declared_count fixture(s), all on disk"
  PASS=$((PASS+1))
else
  echo "  FAIL  W9.0 the windows-skip-list declares $w9_declared_count fixture(s), of which $w9_resolved_count resolve on disk"
  if [ -n "$w9_unresolved" ]; then
    printf '          unresolved: %s\n' "$w9_unresolved"
  fi
  FAIL=$((FAIL+1))
fi

# W9.1 — declared implies enforced.
w9_not_guarded=''
while IFS= read -r w9_name; do
  [ -n "$w9_name" ] || continue
  w9_file="$REPO_ROOT/tests/$w9_name"
  if [ -r "$w9_file" ]; then
    w9_state="$(guard_state < "$w9_file")"
  else
    w9_state="unreadable"
  fi
  if [ "$w9_state" != "present" ]; then
    w9_not_guarded="${w9_not_guarded}${w9_not_guarded:+ }$w9_name($w9_state)"
  fi
done <<EOF
$marker_block
EOF
if [ -z "$w9_not_guarded" ]; then
  echo "  PASS  W9.1 every declared Unix-only fixture refuses to run under Git Bash"
  PASS=$((PASS+1))
else
  echo "  FAIL  W9.1 declared Unix-only fixture(s) whose first statement is not the refusal guard:"
  printf '          %s\n' $w9_not_guarded
  echo "         Copy the guard block from any other declared fixture. Without it a wired"
  echo "         file that nests this one certifies windows coverage that never ran."
  FAIL=$((FAIL+1))
fi

# W9.2 — enforced implies declared. Without this direction the guard could be
# pasted into a file that really does run on windows-latest, and the run: block
# would go red for a reason the marker block never predicted.
w9_enforcing="$( { grep -lF "$GUARD_MARK" "$REPO_ROOT"/tests/*.test.sh 2>/dev/null || true; } \
  | sed 's#.*/##' | sort -u )"
if [ "$w9_enforcing" = "$marker_block" ]; then
  echo "  PASS  W9.2 the enforcing set equals the declared set, both directions"
  PASS=$((PASS+1))
else
  echo "  FAIL  W9.2 the set of files carrying the refusal guard drifted from the marker block."
  echo "         declared (marker block):"
  printf '           %s\n' $marker_block
  echo "         enforcing (guard token on disk):"
  printf '           %s\n' $w9_enforcing
  FAIL=$((FAIL+1))
fi

# W9.3 — anti-vacuity control for W9.1/W9.2: the classifier must actually
# discriminate. A predicate that answered "present" for everything would make
# W9.1 green over a corpus with no guards at all.
w9_fx_present="$(printf '#!/usr/bin/env bash\nset -u\n%s\ncase "$(uname -s)" in\n  MINGW*|MSYS*|CYGWIN*)\n    exit 2 ;;\nesac\nreal_rows\n' "$GUARD_MARK")"
w9_fx_incomplete="$(printf '#!/usr/bin/env bash\n%s\ncase "$(uname -s)" in\n  Linux)\n    : ;;\nesac\nreal_rows\n' "$GUARD_MARK")"
w9_fx_misplaced="$(printf '#!/usr/bin/env bash\nreal_rows\n%s\ncase "$(uname -s)" in\n  MINGW*|MSYS*|CYGWIN*)\n    exit 2 ;;\nesac\n' "$GUARD_MARK")"
w9_fx_missing="$(printf '#!/usr/bin/env bash\nset -u\nreal_rows\n')"
w9_fx_bad=''
for w9_fixture in \
  "present|$w9_fx_present" \
  "incomplete|$w9_fx_incomplete" \
  "misplaced|$w9_fx_misplaced" \
  "missing|$w9_fx_missing"; do
  w9_want=${w9_fixture%%|*}
  w9_got="$(guard_state <<<"${w9_fixture#*|}")"
  if [ "$w9_got" != "$w9_want" ]; then
    w9_fx_bad="${w9_fx_bad}${w9_fx_bad:+ }want=$w9_want,got=$w9_got"
  fi
done
if [ -z "$w9_fx_bad" ]; then
  echo "  PASS  W9.3 the guard classifier separates present/incomplete/misplaced/missing"
  PASS=$((PASS+1))
else
  echo "  FAIL  W9.3 the guard classifier is not discriminating: $w9_fx_bad"
  echo "         W9.1 above is only as strong as this row — fix the classifier, not the fixtures."
  FAIL=$((FAIL+1))
fi

# W10 — the whole-file bail-out ban. One awk over the corpus: a line that
# announces the file is asserting nothing, followed within three lines by a
# zero-status exit, is the vacuous-green shape. Three lines of slack covers the
# `then echo …; exit …; fi` spellings without reaching an unrelated exit.
W10_SCAN_AWK='
  FNR == 1 { bail_at = 0; scanned++ }
  /(echo|printf)[^;]*[Ss][Kk][Ii][Pp]/ { bail_at = FNR }
  /(^|[;&|[:space:]])exit[[:space:]]+0([[:space:]]|;|$)/ {
    if (bail_at > 0 && FNR - bail_at <= 3) print "hit " FILENAME ":" FNR
  }
  END { print "scanned " scanned+0 }
'
# The glob is expanded by the shell and never word-split, so a checkout path
# containing a space (a real local case here) is safe.
w10_out="$(awk "$W10_SCAN_AWK" "$REPO_ROOT"/tests/*.test.sh)"
w10_scanned="$(sed -n 's/^scanned //p' <<<"$w10_out")"
w10_hits="$(sed -n 's/^hit //p' <<<"$w10_out" | sed 's#.*/tests/#tests/#')"
w10_expected="$(printf '%s\n' "$on_disk" | grep -c '\.test\.sh')"

# W10.0 — anti-vacuity for W10.1: a glob or an awk that stopped matching reads
# zero files and reports a clean corpus.
if [ "${w10_scanned:-0}" -gt 0 ] && [ "${w10_scanned:-0}" -eq "$w10_expected" ]; then
  echo "  PASS  W10.0 the bail-out scan read $w10_scanned tests/*.test.sh file(s)"
  PASS=$((PASS+1))
else
  echo "  FAIL  W10.0 the bail-out scan read ${w10_scanned:-<none>} file(s), expected $w10_expected"
  FAIL=$((FAIL+1))
fi

# W10.1 — the corpus itself.
if [ -z "$w10_hits" ]; then
  echo "  PASS  W10.1 no tests/*.test.sh abandons its body and still reports success"
  PASS=$((PASS+1))
else
  echo "  FAIL  W10.1 whole-file bail-out(s) — these announce that nothing ran and then succeed:"
  printf '          %s\n' $w10_hits
  echo "         Make the dependency hard instead: report it on stderr and leave with a"
  echo "         non-zero status, or run the rows. A vacuous green certifies coverage that"
  echo "         does not exist (#520)."
  FAIL=$((FAIL+1))
fi

# W10.2 — anti-vacuity control for W10.1. W10.1's population is zero by design,
# so on its own it cannot distinguish "the corpus is clean" from "the predicate
# stopped matching". These two fixtures pin both polarities of the SAME awk
# program: the vacuous shape must be flagged, and a PATH-stub `case` arm that
# legitimately leaves with a zero status must not.
BAIL_TOKEN='SKI'; BAIL_TOKEN="${BAIL_TOKEN}P"
w10_fx_dir="$(mktemp -d)"
printf 'echo "%s: PyYAML not installed"\nexit 0\n' "$BAIL_TOKEN" > "$w10_fx_dir/positive.test.sh"
printf 'stub_gh() { case "$1" in pr) echo ok; exit 0 ;; esac; }\nreal_rows\nexit 0\n' > "$w10_fx_dir/negative.test.sh"
w10_fx_out="$(awk "$W10_SCAN_AWK" "$w10_fx_dir/positive.test.sh" "$w10_fx_dir/negative.test.sh")"
w10_fx_hits="$(sed -n 's/^hit //p' <<<"$w10_fx_out" | sed 's#.*/##')"
rm -rf "$w10_fx_dir"
if [ "$w10_fx_hits" = "positive.test.sh:2" ]; then
  echo "  PASS  W10.2 the bail-out predicate flags the vacuous shape and spares the control"
  PASS=$((PASS+1))
else
  echo "  FAIL  W10.2 the bail-out predicate is not discriminating:"
  echo "         expected exactly 'positive.test.sh:2', got: ${w10_fx_hits:-<nothing>}"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# W12 — no job may join its test list into ONE `&&` command list (#628).
#
# Every job used to write its whole list as `bash tests/a.test.sh && \` … so the
# block was a single shell command list. The first non-zero exit short-circuits
# every invocation after it, which makes the job structurally incapable of the
# claim its name implies: it can report "nothing failed before it stopped", and
# it can never report "the suite is green". At the time this row was written the
# three blocks held 197 chained invocations — 125 on ubuntu, 8 on macOS, 67 on
# windows — so one early red hid up to 124 files.
#
# #551 is the recorded instance rather than a hypothetical: supervision-smoke
# ran 630 of tests/child-dispatch.test.sh's 1338 lines, exited 0 through a bash
# 3.2 status laundering, and the `&&` chain happily continued past it. The exit
# floor (tests/exit-floor.test.sh) closed the laundering; this row closes the
# hiding.
#
# Rows:
#   W12.0  denominator — all three run: blocks were located and each carries a
#          floor of invocation lines, so W12.1 is not judging an empty string
#   W12.1  the verdict — no invocation line in any block carries `&&`
#   W12.2  polarity, BOTH directions, through the SAME classifier W12.1 uses:
#          a re-chained copy of the LIVE ubuntu block must be flagged on every
#          invocation, and the same text with the join removed on none
#   W12.3  execution proof — the harness the blocks actually carry is extracted
#          from the workflow, run against three synthetic fixtures whose middle
#          one fails, and must run ALL THREE and still exit non-zero
#   W12.4  the three harnesses are byte-identical (one contract, three copies —
#          the #370 drift class)
# ---------------------------------------------------------------------------

# run_block_of <workflow> <job-key> -> that job's `run: |` body on stdout,
# de-indented by the ten spaces the YAML block scalar carries.
run_block_of() {
  awk -v JOB="$2" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+run:[[:space:]]*[|][[:space:]]*$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { in_run = 0; next }
      sub(/^          /, "")
      print
    }
  ' "$1"
}

# ONE classifier, four consumers. W12.0 counts with it, W12.1 judges with it,
# W12.2 proves both of its polarities with it, and W12.3/W12.4 carve the harness
# out with its inverse. A second transcription of "what counts as an invocation"
# would be the uncompared-copy defect W12.4 itself exists to refuse, one level up.
#
# Tags, one per line of the block:
#   C  an invocation line that IS joined into a command list  (the defect)
#   I  an invocation line that is not                          (the fixed shape)
#   H  everything else — the failure-accumulating harness itself
#
# A full-line comment is never an invocation however it is worded, so the
# `run: |` blocks may describe the retired `&& \` shape in prose without the
# description satisfying the predicate. A TRAILING comment is deliberately not
# stripped: a chained line does not stop being chained because someone annotated
# it, and guessing where a `#` stops being data is worse than the rule.
W12_INVOCATION_RE='tests/[A-Za-z0-9._-]+\.test\.(sh|py)'
# The join needle is assembled, never written contiguously beside an invocation
# literal: these bytes are read by tests/epipe-guard.test.sh L0 and by
# tests/test-harness-source-guards.test.sh, and a contiguous copy is a self-trip
# waiting for either corpus to widen. Same discipline as GUARD_MARK above.
W12_JOIN='&'; W12_JOIN="${W12_JOIN}&"
W12_CLASSIFY_AWK='
  {
    tag = "H"
    if ($0 !~ /^[[:space:]]*#/ && $0 ~ RE) { tag = (index($0, JOIN) > 0) ? "C" : "I" }
    printf "%s\t%d\t%s\n", tag, FNR, $0
  }
'
w12_classify() { awk -v RE="$W12_INVOCATION_RE" -v JOIN="$W12_JOIN" "$W12_CLASSIFY_AWK"; }

# job-key|floor. Floors carry headroom below the live counts (125/8/67 at the
# time of writing) — they exist to catch an extractor that COLLAPSED, not to pin
# the inventory.
W12_JOB_SPECS='shape-checks|100
supervision-smoke-macos|6
shape-checks-windows|50'

w12_blocks_ok=1
w12_denom_detail=''
w12_hits=''
while IFS= read -r w12_spec; do
  [ -n "$w12_spec" ] || continue
  w12_job=${w12_spec%%|*}
  w12_floor=${w12_spec#*|}
  w12_tagged="$(run_block_of "$WORKFLOW" "$w12_job" | w12_classify)"
  w12_n="$(grep -cE '^[CI]	' <<<"$w12_tagged")"
  w12_denom_detail="${w12_denom_detail}${w12_denom_detail:+, }$w12_job=$w12_n"
  if [ "${w12_n:-0}" -lt "$w12_floor" ]; then
    w12_blocks_ok=0
  fi
  w12_job_hits="$(sed -n "s/^C	/$w12_job:/p" <<<"$w12_tagged")"
  if [ -n "$w12_job_hits" ]; then
    w12_hits="$w12_hits$w12_job_hits
"
  fi
done <<EOF
$W12_JOB_SPECS
EOF

if [ "$w12_blocks_ok" -eq 1 ]; then
  echo "  PASS  W12.0 all three run: blocks located with their invocation floors ($w12_denom_detail)"
  PASS=$((PASS+1))
else
  echo "  FAIL  W12.0 a run: block is missing or below its invocation floor ($w12_denom_detail)"
  echo "         run_block_of could not find 'run: |' under one of the three job keys,"
  echo "         so W12.1 below would be judging an empty string."
  FAIL=$((FAIL+1))
fi

if [ -z "$w12_hits" ]; then
  echo "  PASS  W12.1 no test invocation in any job is joined into a command list"
  PASS=$((PASS+1))
else
  echo "  FAIL  W12.1 test invocations are chained — one red file hides every file after it:"
  sed 's/^/          /' <<<"$w12_hits"
  echo "         Each job's run: block must call every fixture, accumulate failures, and"
  echo "         exit non-zero at the end naming the ones that failed (#628)."
  FAIL=$((FAIL+1))
fi

# W12.2 — polarity. W12.1's population is zero by design, so on its own it cannot
# tell a de-chained workflow from a classifier that stopped matching. Both arms
# run the SAME w12_classify the verdict uses. The positive arm re-chains the LIVE
# ubuntu block, so the fixture is real bytes rather than a hand-written imitation
# that could drift from the shape actually shipped; the negative arm strips the
# join back off that very same text.
w12_real="$(run_block_of "$WORKFLOW" shape-checks)"
w12_real_n="$(grep -cE '^[CI]	' <<<"$(w12_classify <<<"$w12_real")")"
w12_rechained="$(awk -v RE="$W12_INVOCATION_RE" -v JOIN="$W12_JOIN" '
  $0 !~ /^[[:space:]]*#/ && $0 ~ RE { printf "%s %s \\\n", $0, JOIN; next }
  { print }
' <<<"$w12_real")"
w12_unchained="$(awk -v JOIN="$W12_JOIN" '
  { gsub(JOIN, ""); sub(/[[:space:]]+\\$/, ""); print }
' <<<"$w12_rechained")"
w12_pos_n="$(grep -cE '^C	' <<<"$(w12_classify <<<"$w12_rechained")")"
w12_neg_n="$(grep -cE '^C	' <<<"$(w12_classify <<<"$w12_unchained")")"
if [ "${w12_real_n:-0}" -gt 0 ] && [ "${w12_pos_n:-0}" -eq "${w12_real_n:-0}" ] && [ "${w12_neg_n:-1}" -eq 0 ]; then
  echo "  PASS  W12.2 the classifier flags all $w12_pos_n re-chained invocations and none of the de-chained ones"
  PASS=$((PASS+1))
else
  echo "  FAIL  W12.2 the chain classifier is not discriminating:"
  echo "         invocations=$w12_real_n  flagged-when-chained=$w12_pos_n  flagged-when-not=$w12_neg_n"
  echo "         W12.1 above is only as strong as this row."
  FAIL=$((FAIL+1))
fi

# W12.3 — the execution proof the whole issue turns on. A grep can only say the
# `&&` is gone; running the harness is the only thing that can say a red file no
# longer hides the ones after it. The harness is carved out of the LIVE ubuntu
# block by the inverse of the same classifier, three synthetic fixtures are
# spliced in where the real ones were, and the middle one fails.
W12_MARK='@@W12-INVOCATIONS@@'
w12_fx="$(mktemp -d)"
w12_err=''
if [ ! -d "$w12_fx" ]; then
  w12_err='mktemp -d failed; the execution proof could not run'
else
  printf '#!/usr/bin/env bash\necho w12-ran-a\nexit 0\n' > "$w12_fx/a.sh"
  printf '#!/usr/bin/env bash\necho w12-ran-b\nexit 3\n' > "$w12_fx/b.sh"
  printf '#!/usr/bin/env bash\necho w12-ran-c\nexit 0\n' > "$w12_fx/c.sh"
  w12_classify <<<"$w12_real" \
    | awk -v MARK="$W12_MARK" -v D="$w12_fx" -F'\t' '
        $1 == "H" { sub(/^H\t[0-9]+\t/, ""); print; next }
        !ins {
          printf "run_one bash \"%s/a.sh\"\n", D
          printf "run_one bash \"%s/b.sh\"\n", D
          printf "run_one bash \"%s/c.sh\"\n", D
          ins = 1
        }
      ' > "$w12_fx/runner.sh"
  # `bash -e`, because that is the shell GitHub Actions hands a run: block. A
  # harness that only accumulates correctly WITHOUT errexit would pass here and
  # abort on the first failing fixture in CI — the exact difference this row is
  # for.
  w12_out="$(bash -e "$w12_fx/runner.sh" 2>&1)" && w12_rc=0 || w12_rc=$?
  w12_saw=''
  case "$w12_out" in *w12-ran-a*) ;; *) w12_saw="$w12_saw a" ;; esac
  case "$w12_out" in *w12-ran-b*) ;; *) w12_saw="$w12_saw b" ;; esac
  case "$w12_out" in *w12-ran-c*) ;; *) w12_saw="$w12_saw c" ;; esac
  if [ -n "$w12_saw" ]; then
    w12_err="the harness skipped fixture(s):$w12_saw — a failing file still hides the ones after it"
  elif [ "${w12_rc:-0}" -eq 0 ]; then
    w12_err="the harness ran every fixture but exited 0 with one of them at rc=3 — a red suite reports green"
  fi
  rm -rf "$w12_fx"
fi
if [ -z "$w12_err" ]; then
  echo "  PASS  W12.3 the shipped harness runs every fixture past a failing one and still exits non-zero"
  PASS=$((PASS+1))
else
  echo "  FAIL  W12.3 $w12_err"
  FAIL=$((FAIL+1))
fi

# W12.4 — one contract, three copies. The harness is duplicated per job because
# each run: block is its own shell, and until now nothing compared them: exactly
# the register #370 opened. Comparing each block MINUS its invocation lines is
# that comparison, and it costs one row.
w12_harness_of() {  # $1 = job key
  run_block_of "$WORKFLOW" "$1" | w12_classify \
    | sed -n 's/^H	[0-9]*	//p'
}
w12_h_linux="$(w12_harness_of shape-checks)"
w12_h_macos="$(w12_harness_of supervision-smoke-macos)"
w12_h_windows="$(w12_harness_of shape-checks-windows)"
if [ -n "$w12_h_linux" ] && [ "$w12_h_linux" = "$w12_h_macos" ] && [ "$w12_h_linux" = "$w12_h_windows" ]; then
  echo "  PASS  W12.4 the three per-job failure-accumulating harnesses are byte-identical"
  PASS=$((PASS+1))
else
  if [ -z "$w12_h_linux" ]; then w12_d_empty=yes; else w12_d_empty=no; fi
  if [ "$w12_h_linux" = "$w12_h_macos" ]; then w12_d_macos=no; else w12_d_macos=yes; fi
  if [ "$w12_h_linux" = "$w12_h_windows" ]; then w12_d_win=no; else w12_d_win=yes; fi
  echo "  FAIL  W12.4 the three per-job harnesses have drifted, or the linux one is empty:"
  echo "         linux harness empty:  $w12_d_empty"
  echo "         linux/macos differ:   $w12_d_macos"
  echo "         linux/windows differ: $w12_d_win"
  echo "         Keep one spelling of run_one + the failure tail in all three run: blocks."
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# W13 — a sharded job must still run the whole list.
#
# W1-W4 above prove the WORKFLOW names every fixture. Once the jobs are sharded
# that is no longer the same claim as "every fixture RUNS": the workflow can name
# all 128 while the six shards between them execute 127, and every row above
# stays green. A test that silently stops running is the failure this file exists
# to refuse, so the new seam gets the same treatment as the old one.
#
# Executed, not read. The pack is recomputed here by invoking the SAME scripts
# CI invokes -- tests/ci-job-fixtures.sh for the list, tests/ci-shard-plan.py for
# the split -- because a transcription of the packing rule into this file would
# be the uncompared-copy class W12.4 is about, and both copies would agree with
# each other while disagreeing with CI.
#
#   W13.0  the shard counts in this file match the matrices in the workflow
#   W13.1  union of a job's shards == that job's wired list  (nothing dropped)
#   W13.2  the shards are pairwise disjoint                  (nothing doubled)
#   W13.3  polarity: a plan that DROPS a fixture must be caught by W13.1
# ---------------------------------------------------------------------------
W13_FIXTURES="$REPO_ROOT/tests/ci-job-fixtures.sh"
W13_PLAN="$REPO_ROOT/tests/ci-shard-plan.py"

# `<job-key>|<declared shards>` — the same three specs W13.0 verifies against the
# workflow before W13.1/W13.2 trust them.
W13_JOB_SPECS="shape-checks|$LINUX_SHARDS
supervision-smoke-macos|$MACOS_SHARDS
shape-checks-windows|$WINDOWS_SHARDS"

# matrix_shards_of <workflow> <job-key> -> the shard count that job's matrix
# declares, or the empty string. Reads the `shard: [1, 2, ...]` row inside the
# job block, so a matrix removed or widened is visible here rather than assumed.
matrix_shards_of() {
  awk -v JOB="$2" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+shard:[[:space:]]*\[/ {
      n = gsub(/,/, ",") + 1
      print n
      exit
    }
  ' "$1"
}

if [ ! -x "$W13_FIXTURES" ] || [ ! -r "$W13_PLAN" ]; then
  echo "  FAIL  W13 the shard scripts are missing: $W13_FIXTURES / $W13_PLAN"
  FAIL=$((FAIL+1))
elif ! command -v python3 >/dev/null 2>&1; then
  # Not a skip. This row proves no test was dropped; standing it down on a runner
  # without python3 would be the vacuous-green shape W10 bans outright.
  echo "  FAIL  W13 python3 is required to recompute the shard pack"
  FAIL=$((FAIL+1))
else
  w13_ok=1
  w13_detail=''
  while IFS= read -r w13_spec; do
    [ -n "$w13_spec" ] || continue
    w13_job=${w13_spec%%|*}
    w13_want=${w13_spec#*|}

    # W13.0 — the declared count must match the workflow's own matrix.
    w13_got="$(matrix_shards_of "$WORKFLOW" "$w13_job")"
    if [ "$w13_got" != "$w13_want" ]; then
      w13_ok=0
      w13_detail="${w13_detail}${w13_detail:+; }$w13_job matrix declares '${w13_got:-<none>}', this file expects $w13_want"
      continue
    fi

    w13_wired="$("$W13_FIXTURES" "$w13_job" "$WORKFLOW" | LC_ALL=C sort)" || {
      w13_ok=0
      w13_detail="${w13_detail}${w13_detail:+; }$w13_job: could not extract its fixture list"
      continue
    }

    # Recompute every shard and concatenate. `sort` WITHOUT -u, so a fixture
    # landing in two shards survives into the comparison instead of being
    # deduplicated into a false match — W13.2 is only meaningful if the union is
    # counted with multiplicity.
    w13_union=''
    w13_shard=1
    while [ "$w13_shard" -le "$w13_want" ]; do
      w13_part="$("$W13_FIXTURES" "$w13_job" "$WORKFLOW" \
        | python3 -I -B "$W13_PLAN" --shards "$w13_want" --shard "$w13_shard")" || {
          w13_ok=0
          w13_detail="${w13_detail}${w13_detail:+; }$w13_job shard $w13_shard: plan failed"
          break
        }
      w13_union="${w13_union}${w13_part}
"
      w13_shard=$((w13_shard + 1))
    done

    w13_union_sorted="$(printf '%s' "$w13_union" | grep -v '^$' | LC_ALL=C sort)"
    if [ "$w13_union_sorted" != "$w13_wired" ]; then
      w13_ok=0
      w13_missing="$(comm -23 <(printf '%s\n' "$w13_wired") <(printf '%s\n' "$w13_union_sorted" | LC_ALL=C sort -u) | tr '\n' ' ')"
      w13_dup="$(printf '%s\n' "$w13_union_sorted" | uniq -d | tr '\n' ' ')"
      w13_detail="${w13_detail}${w13_detail:+; }$w13_job: dropped='${w13_missing% }' duplicated='${w13_dup% }'"
    fi
  done <<EOF
$W13_JOB_SPECS
EOF

  if [ "$w13_ok" = 1 ]; then
    echo "  PASS  W13.1/W13.2 every sharded job's shards cover its wired list exactly once"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W13 a sharded job does not run its whole list: $w13_detail"
    FAIL=$((FAIL+1))
  fi

  # W13.3 — polarity. W13.1 compares two lists that are BOTH derived from the
  # same extractor, so it would pass just as happily if the pack were a no-op
  # that returned everything to every shard. Drive a plan that deliberately drops
  # one fixture through the SAME comparison and require it to be caught.
  w13_ctl_wired="$("$W13_FIXTURES" shape-checks "$WORKFLOW" | LC_ALL=C sort)"
  w13_ctl_union="$(printf '%s\n' "$w13_ctl_wired" | tail -n +2 | LC_ALL=C sort)"
  if [ "$w13_ctl_union" != "$w13_ctl_wired" ]; then
    echo "  PASS  W13.3 the comparison catches a plan that drops a fixture"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W13.3 the union comparison cannot tell a dropped fixture from a complete plan"
    FAIL=$((FAIL+1))
  fi
fi

# ---------------------------------------------------------------------------
# W8 — every OTHER workflow in .github/workflows/ (#434).
#
# W1–W7 above are hardcoded to test.yml because that file is the test-set SSOT.
# But `.github/workflows/` grew a second file, and nothing checked it at all:
# a workflow with no trigger, no timeout, a floating action tag, or a
# workflow-level write token would have shipped unnoticed. The scope of this
# suite is therefore generalised from ONE file to a SET.
#
# W8.0 is written first and is not decoration. A `for f in .github/workflows/*.yml`
# loop that excludes test.yml iterates zero times when test.yml is the only
# workflow, and every row below it then passes vacuously — the exact
# silent-green class this repo keeps rediscovering. Non-emptiness is asserted
# before anything is asserted about the contents.
# ---------------------------------------------------------------------------
# NEWLINE-delimited, never space-delimited: a checkout path containing a space
# (a real local case here) would otherwise word-split into nonexistent paths and
# every row below would fail for the wrong reason.
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
OTHER_WORKFLOWS=''
OTHER_COUNT=0
for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -f "$wf" ] || continue
  case "$(basename "$wf")" in
    test.yml) continue ;;
  esac
  OTHER_WORKFLOWS="${OTHER_WORKFLOWS}${wf}
"
  OTHER_COUNT=$((OTHER_COUNT+1))
done

if [ "$OTHER_COUNT" -gt 0 ]; then
  echo "  PASS  W8.0 .github/workflows/ carries $OTHER_COUNT workflow(s) besides test.yml"
  PASS=$((PASS+1))
else
  echo "  FAIL  W8.0 no workflow besides test.yml — W8.1-W8.5 would be vacuous"
  echo "         dir: $WORKFLOW_DIR"
  FAIL=$((FAIL+1))
fi

USES_SEEN=0
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  wf_name="$(basename "$wf")"
  wf_body="$(cat "$wf")"

  # W8.1 — a workflow with no trigger never runs, and looks identical to one
  # that runs and finds nothing.
  if grep -qE '^on:' <<<"$wf_body" \
     && grep -qE '^[[:space:]]+(schedule|workflow_dispatch|push|pull_request|workflow_call):' <<<"$wf_body"; then
    echo "  PASS  W8.1 $wf_name declares a trigger"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W8.1 $wf_name has no 'on:' block with at least one event"
    FAIL=$((FAIL+1))
  fi

  # W8.2 — an un-capped job inherits the 360-minute default and can burn the
  # public-repo Actions allowance on a hang.
  if grep -qE '^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+' <<<"$wf_body"; then
    echo "  PASS  W8.2 $wf_name caps its job runtime"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W8.2 $wf_name declares no timeout-minutes"
    FAIL=$((FAIL+1))
  fi

  # W8.3 — every third-party action is SHA-pinned with a readable version
  # trailer. A floating tag is a supply-chain hole that moves under you.
  # `uses_seen` feeds the anti-vacuity row below: a pattern that stops matching
  # `uses:` lines at all would otherwise report a clean pin sweep over nothing.
  unpinned=''
  while IFS= read -r uses_line; do
    [ -n "$uses_line" ] || continue
    USES_SEEN=$((USES_SEEN+1))
    grep -qE 'uses:[[:space:]]*\./' <<<"$uses_line" && continue
    grep -qE 'uses:[[:space:]]*[^@]+@[0-9a-f]{40}[[:space:]]*#[[:space:]]*v[0-9]' <<<"$uses_line" \
      || unpinned="${unpinned}${unpinned:+; }$(printf '%s' "$uses_line" | sed 's/^[[:space:]]*//')"
  done <<EOF
$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' <<<"$wf_body")
EOF
  if [ -z "$unpinned" ]; then
    echo "  PASS  W8.3 $wf_name SHA-pins every action with a version trailer"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W8.3 $wf_name has unpinned action(s): $unpinned"
    FAIL=$((FAIL+1))
  fi

  # W8.4 — least privilege at the workflow level. Any write scope a job needs
  # must be declared on that job, not handed to the whole file.
  wf_level_perms="$(awk '/^permissions:/{f=1;next} f&&/^[^[:space:]]/{exit} f{print}' <<<"$wf_body")"
  if grep -qE ':[[:space:]]*write' <<<"$wf_level_perms"; then
    echo "  FAIL  W8.4 $wf_name grants a write scope at the workflow level"
    FAIL=$((FAIL+1))
  else
    echo "  PASS  W8.4 $wf_name keeps workflow-level permissions read-only"
    PASS=$((PASS+1))
  fi
done <<EOF
$OTHER_WORKFLOWS
EOF

# W8.3b — anti-vacuity for W8.3. Every non-test workflow on disk today checks out
# the repo, so the pin sweep must have inspected at least one `uses:` line. Zero
# means the extractor stopped matching, not that the workflows stopped using
# actions — and a silent zero would certify an unpinned action as pinned.
if [ "$USES_SEEN" -gt 0 ]; then
  echo "  PASS  W8.3b the pin sweep inspected $USES_SEEN uses: line(s)"
  PASS=$((PASS+1))
else
  echo "  FAIL  W8.3b the pin sweep found no uses: line at all — W8.3 is vacuous"
  FAIL=$((FAIL+1))
fi

# W8.5 — the vendored-drift reporter specifically. It is the compensating
# control RFC 0019 trades "free upstream updates" for, so its schedule and its
# single write scope are contract, not configuration.
DRIFT_WORKFLOW="$WORKFLOW_DIR/vendor-drift.yml"
if [ -r "$DRIFT_WORKFLOW" ]; then
  drift_body="$(cat "$DRIFT_WORKFLOW")"
  drift_missing=''
  grep -qE '^[[:space:]]+schedule:' <<<"$drift_body" || drift_missing="${drift_missing} schedule:"
  grep -qE '^[[:space:]]+workflow_dispatch:' <<<"$drift_body" || drift_missing="${drift_missing} workflow_dispatch:"
  grep -qE '^[[:space:]]{4,}issues:[[:space:]]*write' <<<"$drift_body" || drift_missing="${drift_missing} job-level-issues:write"
  if [ -z "$drift_missing" ]; then
    echo "  PASS  W8.5 vendor-drift.yml is scheduled, dispatchable, and takes issues: write at job level"
    PASS=$((PASS+1))
  else
    echo "  FAIL  W8.5 vendor-drift.yml is missing:$drift_missing"
    FAIL=$((FAIL+1))
  fi
else
  echo "  FAIL  W8.5 the vendored-drift reporter workflow is missing: $DRIFT_WORKFLOW"
  FAIL=$((FAIL+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
