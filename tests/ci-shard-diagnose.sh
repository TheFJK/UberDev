#!/usr/bin/env bash
# tests/ci-shard-diagnose.sh — byte-level evidence for the CI shard plan (#753).
#
# REPORTER, NEVER A GATE. This script prints; it does not decide. The gates are
# tests/ci-shard-env.sh, which refuses to emit a CR-bearing plan, and the
# SHARD-COVERAGE tail in each job's run: block, which fails a shard that ran
# fewer fixtures than it was planned. Keeping the reporter separate from them
# is what lets it run on a runner whose plan is already broken.
#
# WHY BOTH SIDES OF THE GITHUB_ENV BOUNDARY. The plan is produced by one step
# and consumed by the next, and between them sits a file this repo's shell
# writes and the runner reads back. Under Git Bash the packer's stdout is a
# text stream, so every line it prints is terminated CRLF; the $( ) capture
# strips the trailing LF and leaves the CR, and `tr` converts the interior LFs
# and leaves every CR. Whether the FINAL CR survives that file boundary is the
# entire question: with it, `case " $PLAN " in *" $name "*` matches nothing;
# without it, it matches exactly the last entry. One side cannot tell those
# apart, so this script dumps both.
#
# TWO SHIMS, NOT ONE — the load-bearing distinction in this file.
#
#   `packer-bytes` drives the real packer through an IN-PROCESS CRLF text
#   stream, which is what `python3` IS under Git Bash. That is the correct
#   model for the question it asks — "does the packer pin its own newline?" —
#   precisely BECAUSE the answer flips the moment it does: a
#   `sys.stdout.reconfigure(newline="\n")` inside the packer overrides a
#   TextIOWrapper installed around it from outside. That flip is the assertion.
#
#   `simulate` must NOT inherit that flip. It exists to drive the CONSUMER —
#   tests/ci-shard-env.sh's CR refusal — and a guard whose only input arrives
#   through the producer it is meant to test stops being tested the moment that
#   producer is pinned. Measured: the same wrapper that yields 11 CR bytes
#   against an unpinned packer yields ZERO against a pinned one, so a
#   `simulate` built on the wrapper would return rc=0 with a clean plan and the
#   refusal would ship untested. So `simulate` re-applies the CR at the PROCESS
#   BOUNDARY instead — downstream of every byte the packer has already written,
#   where nothing the packer can reconfigure reaches it. That is the same move
#   `crlf-plan` makes on the consumer side, for the same reason.
#
# Usage:
#   ci-shard-diagnose.sh dump         <job-key> <shards> <shard>
#   ci-shard-diagnose.sh simulate     <job-key> <shards> <shard>
#   ci-shard-diagnose.sh crlf-plan    <job-key> <shards> <shard>
#   ci-shard-diagnose.sh packer-bytes <job-key> <shards> <shard>
#
# Every verb is invoked as `bash tests/ci-shard-diagnose.sh …`; the file needs
# no execute bit and no call site relies on one.

set -u
# PIPEFAIL, so a producer that dies inside a pipeline here cannot be reported as
# a clean empty answer — the doctrine tests/ci-shard-env.sh:16-20 already states
# for the plan itself. It also places this file in tests/epipe-guard.test.sh's
# scan set, so no pipeline below may end in an early-exiting reader (`head`,
# `read`, `grep -q`/`-l`/`-m`): every reader here drains its input.
set -o pipefail

ci_diag_usage() {
  echo "usage: ${0##*/} dump|simulate|crlf-plan|packer-bytes <job-key> <shards> <shard>" >&2
  exit 2
}

[ "$#" -eq 4 ] || ci_diag_usage
ci_diag_verb="$1"
ci_diag_job="$2"
ci_diag_shards="$3"
ci_diag_shard="$4"
ci_diag_dir="$(cd "$(dirname "$0")" && pwd)" || exit 2
ci_diag_cr="$(printf '\r')"

# ---------------------------------------------------------------------------
# Shim scaffolding
# ---------------------------------------------------------------------------

# A python that translates its stdout to CRLF is what `python3` IS under Git
# Bash. Reproducing that here drives the REAL packer through the REAL
# producer; a hand-written CRLF fixture would be a copy of the packer that
# could not drift with it.
ci_diag_write_driver() { # $1 = destination path
  cat >"$1" <<'PYDRIVER'
import io
import runpy
import sys

target = None
rest = []
for index, arg in enumerate(sys.argv[1:], start=1):
    if not arg.startswith("-"):
        target = arg
        rest = sys.argv[index + 1:]
        break
if target is None:
    sys.exit("ci-shard-diagnose driver: no script argument")

sys.argv = [target] + rest
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, newline="\r\n", write_through=True)
try:
    runpy.run_path(target, run_name="__main__")
finally:
    sys.stdout.flush()
PYDRIVER
}

# Common half of both shim builders: a scratch dir with an empty bin/ and the
# real interpreter resolved from the UNSHIMMED PATH. Sets ci_diag_tmp and
# ci_diag_real_python3 for the caller; the caller owns the removal.
ci_diag_new_shim_dir() {
  ci_diag_tmp="$(mktemp -d)" || return 2
  ci_diag_real_python3="$(command -v python3)" || { rm -rf "$ci_diag_tmp"; return 2; }
  mkdir -p "$ci_diag_tmp/bin" || { rm -rf "$ci_diag_tmp"; return 2; }
}

# Builds <tmp>/bin/python3, a shim that execs the real python3 through the
# IN-PROCESS driver above. Echoes the tmp dir on stdout; the caller removes it.
#
# For `packer-bytes` only. This is the shim the packer's own newline pin is
# supposed to defeat, which is exactly why the row built on it is falsifiable
# on a host whose python never emits a CR of its own.
ci_diag_make_stream_shim() {
  ci_diag_new_shim_dir || return 2
  ci_diag_write_driver "$ci_diag_tmp/crlf-driver.py" || { rm -rf "$ci_diag_tmp"; return 2; }
  {
    printf '#!/bin/sh\n'
    printf 'exec "%s" -I -B "%s" "$@"\n' "$ci_diag_real_python3" "$ci_diag_tmp/crlf-driver.py"
  } >"$ci_diag_tmp/bin/python3" || { rm -rf "$ci_diag_tmp"; return 2; }
  chmod +x "$ci_diag_tmp/bin/python3" || { rm -rf "$ci_diag_tmp"; return 2; }
  printf '%s\n' "$ci_diag_tmp"
}

# Builds <tmp>/bin/python3, a shim that runs the real python3 and re-terminates
# every line it printed as CRLF — AFTER the bytes have left that process.
# Echoes the tmp dir on stdout; the caller removes it.
#
# For `simulate` only, and the awk is the point: the packer cannot reconfigure a
# stream it has already written to and exited from, so this CR survives the
# newline pin that (correctly) defeats ci_diag_make_stream_shim. `set -o
# pipefail` inside the shim keeps awk's success from masking a packer refusal —
# ci-shard-env.sh checks that status with `|| exit 2` and must keep seeing it.
# stderr is untouched, so the packer's `--explain` balance report still passes
# through as the real producer would emit it.
ci_diag_make_boundary_shim() {
  ci_diag_new_shim_dir || return 2
  # The `sub` STRIPS an existing CR before the `printf` re-adds one, so the shim
  # emits exactly one CRLF per line on every host rather than `\r\r\n` on the one
  # host whose python already terminates its own lines CRLF. Both shapes would
  # trip a "contains a CR" refusal, but only the normalised one is the byte
  # sequence a Windows runner actually produces, and this verb exists to be that
  # byte sequence. Verified against one-true-awk (the most conservative of the
  # three implementations in play: BSD awk here, gawk on Git Bash, mawk/gawk on
  # ubuntu).
  #
  # Single-quoted, so `\r` reaches awk as an escape for awk to interpret and
  # `$0` is awk's field, not this shell's argv.
  ci_diag_boundary_awk='{ sub(/\r$/, ""); printf "%s\r\n", $0 }'
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'set -o pipefail\n'
    printf '"%s" -I -B "$@" | awk %s\n' "$ci_diag_real_python3" "'$ci_diag_boundary_awk'"
  } >"$ci_diag_tmp/bin/python3" || { rm -rf "$ci_diag_tmp"; return 2; }
  chmod +x "$ci_diag_tmp/bin/python3" || { rm -rf "$ci_diag_tmp"; return 2; }
  printf '%s\n' "$ci_diag_tmp"
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

ci_diag_dump() {
  echo "=== ci-shard-diagnose dump: $ci_diag_job shard $ci_diag_shard/$ci_diag_shards"
  # $BASH_VERSION rather than a `bash --version` pipeline into an
  # early-exiting reader: it names the shell actually interpreting the harness
  # instead of whichever bash sits first on PATH, and it keeps this file clean
  # against the rule the pipefail note above puts it in scope for. (The banned
  # shape is described, never spelled, for the reason A4 in
  # tests/test-harness-source-guards.test.sh states: a guard's own corpus must
  # not contain its needle.)
  echo "--- host: $(uname -s 2>/dev/null) / bash ${BASH_VERSION-unknown}"

  echo "--- [A] producer stdout, exactly as tests/ci-shard-env.sh emits it"
  if ci_diag_emitted="$(bash "$ci_diag_dir/ci-shard-env.sh" "$ci_diag_job" "$ci_diag_shards" "$ci_diag_shard" 2>/dev/null)"; then
    printf '%s\n' "$ci_diag_emitted" | sed -n 's/^UBERDEV_SHARD_PLAN=//p' | od -c
  else
    echo "    (the producer refused; its diagnostic is on stderr in the planning step)"
  fi

  echo "--- [B] \$UBERDEV_SHARD_PLAN as THIS step inherited it (after the GITHUB_ENV round trip)"
  if [ -n "${UBERDEV_SHARD_PLAN-}" ]; then
    printf '%s' "$UBERDEV_SHARD_PLAN" | od -c
  else
    echo "    (unset in this step's environment)"
  fi

  echo "--- [C] membership probe, using the harness's own rule against [B]"
  ci_diag_hit=0
  ci_diag_miss=0
  while IFS= read -r ci_diag_name; do
    [ -n "$ci_diag_name" ] || continue
    case " ${UBERDEV_SHARD_PLAN-} " in
      *" ${ci_diag_name} "*) ci_diag_hit=$((ci_diag_hit + 1)); ci_diag_verdict=MATCH ;;
      *) ci_diag_miss=$((ci_diag_miss + 1)); ci_diag_verdict=MISS ;;
    esac
    printf '    %-5s %s\n' "$ci_diag_verdict" "$ci_diag_name"
  done <<CI_DIAG_NAMES
$(printf '%s' "${UBERDEV_SHARD_PLAN-}" | tr -d "$ci_diag_cr" | tr ' ' '\n')
CI_DIAG_NAMES
  echo "    match=$ci_diag_hit miss=$ci_diag_miss"
  echo "    A plan of length N with match=1 is the #753 signature: only the entry"
  echo "    whose trailing CR was consumed at the file boundary is space-bounded."
  return 0
}

# simulate — the REAL producer, with a CRLF-emitting packer underneath it.
# Passes the producer's stdout and exit status through unchanged, so a caller
# sees exactly what a Windows planning step would see.
#
# The CR arrives at the process boundary (ci_diag_make_boundary_shim), NOT
# through an in-process stdout wrapper, so this verb keeps reproducing the
# Windows condition after the packer pins its own newline. See TWO SHIMS above.
ci_diag_simulate() {
  ci_diag_shim_dir="$(ci_diag_make_boundary_shim)" || return 2
  PATH="$ci_diag_shim_dir/bin:$PATH" bash "$ci_diag_dir/ci-shard-env.sh" \
    "$ci_diag_job" "$ci_diag_shards" "$ci_diag_shard"
  ci_diag_rc=$?
  rm -rf "$ci_diag_shim_dir"
  return "$ci_diag_rc"
}

# packer-bytes — the REAL packer with its stdout wrapped in a CRLF-translating
# text stream, raw. On a packer that pins its own newline this comes back
# LF-only; on one that does not, every line is terminated CRLF.
#
# The fixture list is piped in rather than captured first: with pipefail on, an
# extractor that dies takes the pipeline's status with it, and the packer itself
# refuses an empty stdin — so neither half can fail into a silent empty answer.
ci_diag_packer_bytes() {
  ci_diag_shim_dir="$(ci_diag_make_stream_shim)" || return 2
  bash "$ci_diag_dir/ci-job-fixtures.sh" "$ci_diag_job" \
    | "$ci_diag_shim_dir/bin/python3" -I -B "$ci_diag_dir/ci-shard-plan.py" \
        --shards "$ci_diag_shards" --shard "$ci_diag_shard"
  ci_diag_rc=$?
  rm -rf "$ci_diag_shim_dir"
  return "$ci_diag_rc"
}

# crlf-plan — the value the HARNESS receives when the plan's delimiters are
# CR-terminated, printed raw with no trailing newline.
#
# This models the PLATFORM, not the packer, and that is deliberate. Once the
# packer pins its stdout to LF the CRLF path is unreachable through the real
# producer, and a consumer-side guard whose only input came through that
# producer would quietly stop being tested. So the delimiter model is applied
# to real per-shard names here: CR before every separator, none after the last
# entry, which is the shape measured on the runner and the only one that
# reproduces one-fixture-per-shard.
ci_diag_crlf_plan() {
  ci_diag_packed="$(bash "$ci_diag_dir/ci-job-fixtures.sh" "$ci_diag_job" \
    | python3 -I -B "$ci_diag_dir/ci-shard-plan.py" \
        --shards "$ci_diag_shards" --shard "$ci_diag_shard")" || return 2
  [ -n "$ci_diag_packed" ] || return 2
  # `@` as the placeholder, translated afterwards: a `\r` in a sed replacement
  # is not portable (BSD sed inserts a literal r), and `@` cannot occur in a
  # fixture name, which tests/ci-shard-env.sh:13 pins to [A-Za-z0-9._-]+.
  printf '%s' "$ci_diag_packed" | sed '$!s/$/@/' | tr '\n' ' ' | tr '@' "$ci_diag_cr"
}

case "$ci_diag_verb" in
  dump)         ci_diag_dump ;;
  simulate)     ci_diag_simulate ;;
  packer-bytes) ci_diag_packer_bytes ;;
  crlf-plan)    ci_diag_crlf_plan ;;
  *)            ci_diag_usage ;;
esac
