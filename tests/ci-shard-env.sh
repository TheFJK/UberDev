#!/usr/bin/env bash
# tests/ci-shard-env.sh — emit the GITHUB_ENV lines one sharded CI job needs.
#
# Usage:  ci-shard-env.sh <job-key> <shards> <shard>   >> "$GITHUB_ENV"
#
# Joins the two halves: tests/ci-job-fixtures.sh says what the job invokes,
# tests/ci-shard-plan.py says which of those belong to this shard. Nothing here
# re-derives either answer.
#
# UBERDEV_SHARD_PLAN is SPACE-separated, not newline-separated, for two reasons:
# a GITHUB_ENV line cannot carry a raw newline without heredoc delimiters, and
# the consumer's membership test is a `case " $PLAN " in *" $name "*)` — exact,
# and safe because a fixture name is `[A-Za-z0-9._-]+` and can never contain a
# space.
#
# FAILS LOUDLY, never emits a partial plan. The harness treats an unset plan as
# "run everything", which is the right default for a test runner extracted and
# run standalone — but it would turn a broken pack into a silent 6x duplicate
# run. So a plan that cannot be computed must stop the job here instead of
# reaching the harness as an absence.

set -u

if [ "$#" -ne 3 ]; then
  echo "usage: ${0##*/} <job-key> <shards> <shard>" >&2
  exit 2
fi

ci_shard_env_job="$1"
ci_shard_env_shards="$2"
ci_shard_env_shard="$3"
ci_shard_env_dir="$(cd "$(dirname "$0")" && pwd)" || exit 2

case "$ci_shard_env_shards" in ''|*[!0-9]*) echo "${0##*/}: shards must be a positive integer, got '$ci_shard_env_shards'" >&2; exit 2 ;; esac
case "$ci_shard_env_shard"  in ''|*[!0-9]*) echo "${0##*/}: shard must be a positive integer, got '$ci_shard_env_shard'" >&2; exit 2 ;; esac

# Producer status checked on its own line. `<producer> | python3 … ` binds `||`
# to the PIPELINE's status, which is the packer's — and the packer succeeds on an
# empty list only by refusing, so a silent extractor failure would still be
# caught here; writing it this way makes that independent of the packer's
# internals rather than dependent on them.
ci_shard_env_fixtures="$("$ci_shard_env_dir/ci-job-fixtures.sh" "$ci_shard_env_job")" || exit 2

ci_shard_env_plan="$(printf '%s\n' "$ci_shard_env_fixtures" \
  | python3 -I -B "$ci_shard_env_dir/ci-shard-plan.py" \
      --shards "$ci_shard_env_shards" --shard "$ci_shard_env_shard" --explain)" || exit 2

if [ -z "$ci_shard_env_plan" ]; then
  echo "${0##*/}: empty plan for $ci_shard_env_job shard $ci_shard_env_shard/$ci_shard_env_shards" >&2
  exit 2
fi

# CR REFUSAL, NOT CR REMOVAL (#753). On windows-latest the packer's stdout is
# a text stream, so every line it prints is terminated CRLF: the $( ) capture
# above strips the trailing LF and leaves the CR, the `tr` below converts the
# interior LFs and leaves every CR, and the GITHUB_ENV file's final CRLF is
# consumed as one line terminator. The harness then receives
# `a<CR> b<CR> ... y<CR> z` and its `case " $PLAN " in *" $name "*` membership
# test matches only `z`. Six shards ran one fixture each and reported green.
#
# Stripping the CR here would work, and would be a band-aid: the plan would be
# correct while the packer stayed wrong, and the next thing to read that
# stdout would inherit the bug with nothing left to warn it.
# tests/ci-shard-plan.py pins its own stdout to LF; this refusal is what makes
# a regression in that pin kill the planning step instead of silently
# shrinking the suite. Same rule as the empty-plan refusal above.
#
# UNREACHABLE ON A HEALTHY TREE, BY TWO INDEPENDENT MECHANISMS, so this can
# never fire on a legitimate plan: ci-job-fixtures.sh extracts names with
# `grep -oE 'tests/[a-zA-Z0-9._-]+\.test\.(sh|py)'`, whose character class
# cannot match a CR even from a CRLF checkout, and ci-shard-plan.py `.strip()`s
# every line it reads off stdin. The packer's own stdout is the only remaining
# CR source on this path, and pinning it is the fix this guard backstops.
ci_shard_env_cr="$(printf '\r')"
case "$ci_shard_env_plan" in
  *"$ci_shard_env_cr"*)
    echo "${0##*/}: the packed plan for $ci_shard_env_job shard $ci_shard_env_shard/$ci_shard_env_shards carries a CR byte." >&2
    echo "${0##*/}: a CR-delimited plan makes the shard filter match only the last entry (#753)." >&2
    echo "${0##*/}: dump the bytes with: bash $ci_shard_env_dir/ci-shard-diagnose.sh dump $ci_shard_env_job $ci_shard_env_shards $ci_shard_env_shard" >&2
    exit 2
    ;;
esac

printf 'UBERDEV_SHARD_PLAN=%s\n' "$(printf '%s' "$ci_shard_env_plan" | tr '\n' ' ')"
printf 'UBERDEV_SHARD=%s\n' "$ci_shard_env_shard"
printf 'UBERDEV_SHARDS=%s\n' "$ci_shard_env_shards"
