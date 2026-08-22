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

printf 'UBERDEV_SHARD_PLAN=%s\n' "$(printf '%s' "$ci_shard_env_plan" | tr '\n' ' ')"
printf 'UBERDEV_SHARD=%s\n' "$ci_shard_env_shard"
printf 'UBERDEV_SHARDS=%s\n' "$ci_shard_env_shards"
