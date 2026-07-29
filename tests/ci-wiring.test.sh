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
#   W7  — receipt retirement runs on Linux, macOS, and native Windows.
#
# Portable: bash + awk + grep + sed + sort + comm. Runs on ubuntu-latest
# (native bash) and windows-latest (Git Bash) without any extra deps.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

macos_supervision_block=$(awk '/^  supervision-smoke-macos:/,/^  shape-checks-windows:/' "$WORKFLOW")
for required in review-pr-codex-entry.test.sh agent-dispatch.test.sh \
                review-pr-codex-six-child.test.sh worktree-receipts.test.sh; do
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

# W7 — the receipt-retirement helper exercises real filesystem semantics on
# every supported runner, including native Windows rather than only Git Bash
# shape inspection on Unix.
receipt_test='bash tests/worktree-receipts.test.sh'
missing_receipt_jobs=''
for job_and_block in \
  "Linux|$linux_job_block" \
  "macOS|$macos_supervision_block" \
  "Windows|$windows_job_block"; do
  job=${job_and_block%%|*}
  block=${job_and_block#*|}
  if ! grep -qF "$receipt_test" <<<"$block"; then
    missing_receipt_jobs="${missing_receipt_jobs}${missing_receipt_jobs:+, }$job"
  fi
done
if [ -z "$missing_receipt_jobs" ]; then
  echo "  PASS  W7 worktree receipt retirement runs on Linux, macOS, and native Windows"
  PASS=$((PASS+1))
else
  echo "  FAIL  W7 worktree receipt retirement is missing from: $missing_receipt_jobs"
  FAIL=$((FAIL+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
