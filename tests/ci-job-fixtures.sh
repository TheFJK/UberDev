#!/usr/bin/env bash
# tests/ci-job-fixtures.sh — the fixture list one job of .github/workflows/test.yml
# actually invokes, one `<name>.test.sh` per line, in declaration order.
#
# ONE implementation, two consumers. The sharding step in the workflow needs this
# list to compute its bin-pack, and tests/ci-wiring.test.sh needs it to prove
# every on-disk fixture is wired. Those are the same question, and answering it
# twice is the "one contract, N uncompared copies" class this suite exists to
# catch — a second transcription would drift and BOTH copies would keep passing.
#
# The `run_one bash tests/<name>.test.sh` lines in the workflow stay the single
# source of truth. Nothing here introduces a manifest the workflow could disagree
# with: the list is read back out of the workflow itself.
#
# Comment-stripped BEFORE the match, so a fixture named only in prose
# ("mirroring secret-scan.test.sh", "# dropped for speed: bash tests/x.test.sh")
# never counts as wiring. That forgery is the exact mutation ci-wiring W11 drives.
#
# Matches BOTH `.test.sh` and `.test.py`. The Windows job invokes one python
# fixture (`run_one python -I -B tests/code-fixer-contract-windows.test.py`), and
# an extractor that saw only shell would leave it out of every shard's plan --
# where the harness's fail-open default then runs it in ALL of them. Correct, and
# six times the cost, silently.
#
# Usage:  ci-job-fixtures.sh <job-key> [<workflow-path>]
# Exits non-zero when the job key is absent or its block names no fixture — a
# caller that got an empty list because the extractor broke must not read that as
# "this job runs nothing".

set -u

CI_JOB_FIXTURES_JOB="${1-}"
if [ -z "$CI_JOB_FIXTURES_JOB" ]; then
  echo "usage: ${0##*/} <job-key> [<workflow-path>]" >&2
  exit 2
fi

CI_JOB_FIXTURES_ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2
CI_JOB_FIXTURES_WORKFLOW="${2:-$CI_JOB_FIXTURES_ROOT/.github/workflows/test.yml}"

if [ ! -r "$CI_JOB_FIXTURES_WORKFLOW" ]; then
  echo "${0##*/}: workflow unreadable: $CI_JOB_FIXTURES_WORKFLOW" >&2
  exit 2
fi

# The block stops at the next job key rather than running to EOF or to a named
# sibling: an awk range keyed on the FOLLOWING job swallows whatever is between
# them, so a fixture wired into a third job would be certified as this job's.
ci_job_fixtures_block="$(awk -v JOB="$CI_JOB_FIXTURES_JOB" '
  $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
  in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
  in_job { print }
' "$CI_JOB_FIXTURES_WORKFLOW")" || exit 2

if [ -z "$ci_job_fixtures_block" ]; then
  echo "${0##*/}: no job block for '$CI_JOB_FIXTURES_JOB' in $CI_JOB_FIXTURES_WORKFLOW" >&2
  exit 2
fi

# Declaration order, de-duplicated by FIRST occurrence. Order is what makes a
# sharded log comparable to an unsharded one; `sort -u` would destroy it, and the
# awk seen-check keeps the de-duplication without it.
ci_job_fixtures_list="$(printf '%s\n' "$ci_job_fixtures_block" \
  | grep -v '^[[:space:]]*#' \
  | grep -oE 'tests/[a-zA-Z0-9._-]+\.test\.(sh|py)' \
  | sed 's#tests/##' \
  | awk '!seen[$0]++')"

if [ -z "$ci_job_fixtures_list" ]; then
  echo "${0##*/}: job '$CI_JOB_FIXTURES_JOB' names no tests/*.test.{sh,py}" >&2
  exit 2
fi

printf '%s\n' "$ci_job_fixtures_list"
