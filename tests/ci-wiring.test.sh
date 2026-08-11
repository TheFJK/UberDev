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
#
# Portable: bash + awk + grep + sed + sort + comm. Runs on ubuntu-latest
# (native bash) and windows-latest (Git Bash) without any extra deps.

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
macos_supervision_block=$(awk '/^  supervision-smoke-macos:/,/^  shape-checks-windows:/' "$WORKFLOW")
for required in review-pr-entry.test.sh agent-dispatch.test.sh \
                dispatch-child-worktree-teardown.test.sh \
                child-dispatch.test.sh \
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

LINUX_TIMEOUT_MINUTES=40
WINDOWS_TIMEOUT_MINUTES=30
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
ubuntu_wired=$(awk '/^  shape-checks:/,/^  shape-checks-windows:/' "$WORKFLOW" \
  | grep -v '^[[:space:]]*#' \
  | grep -oE 'tests/[a-zA-Z0-9._-]+\.test\.sh' | sed 's#tests/##' | sort -u)
windows_wired=$(awk '/^  shape-checks-windows:/,0' "$WORKFLOW" \
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

# W5 — the complete Linux matrix exhausted the 30-minute budget even though
# its final suite reported 91/0 immediately before cancellation. Preserve a
# bounded ten-minute recovery margin without falling back to Actions' default.
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

# W6 — the exhaustive native Windows portability shard needs measured runtime
# headroom; retain a bounded hang guard without falling back to Actions'
# 360-minute default or weakening the Linux/macOS job-specific guards.
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
