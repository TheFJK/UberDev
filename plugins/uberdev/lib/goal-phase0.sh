#!/usr/bin/env bash
# lib/goal-phase0.sh — /uberdev:goal Phase 0 (preflight), RFC 0015 §5.
#
# WHY THIS IS A FILE AND NOT A SKILL.md FENCE.
# Every phase of /goal used to live in a ```bash fence inside
# skills/goal-pipeline/SKILL.md. Two structural problems came with that:
#
#   1. The Skill renderer substitutes the positional non-flag arguments of
#      $ARGUMENTS into the ENTIRE SKILL.md body — including inside single-quoted
#      awk one-liners — so a bare `$1`/`$2`/`$3` was silently rewritten to the
#      issue numbers the operator typed (project memory
#      project_uberdev_skill_renderer_dollar_arg_collision). lib/*.sh is NEVER
#      rendered, so positional parameters and awk field refs are safe here.
#   2. Each fence is a SEPARATE shell. Functions, arrays, traps, exports and
#      PIDs all died at the fence boundary, which is the root of the
#      false-converge / rollover-wipe / dead-circuit-breaker class this file's
#      sibling scripts and skills/goal-pipeline/workflow.js exist to end.
#
# CONTRACT
#   bash lib/goal-phase0.sh <ARGUMENTS...>
#     Parses the /goal argument string, resolves every tunable, mints (or with
#     --resume rehydrates) GOAL_ID, initialises the on-disk state files, and
#     prints the `goal` Workflow args envelope between
#     WORKFLOW_ARGS_BEGIN / WORKFLOW_ARGS_END on stdout.
#   exit 0  — envelope emitted (or --dry-run preview printed).
#   exit 2  — usage error, invalid issue number, or no bash >= 4 anywhere.
#   exit 3  — run-state could not be persisted.
#
# REGION MARKERS. `# >>> region: NAME` / `# <<< region: NAME` delimit blocks
# that tests/goal-pipeline-zsh.test.sh extracts and executes STANDALONE under
# zsh. Keep a region self-contained: everything it needs must either be set
# before it or stubbed by the fixture. Renaming a region reds that fixture's
# extract assertion loudly (exit 3), never silently.

set -u

# Plugin-root resolution. Keep the whole chain: it is `set -u` safety plus
# parity with lib/dispatch.sh's own resolution order, and BOTH still apply.
# Under `set -u` a bare ${CLAUDE_PLUGIN_ROOT} is a FATAL unbound-variable abort,
# not a graceful missing-file skip, and CLAUDE_PLUGIN_ROOT is unset whenever
# this file is sourced outside a plugin session (a direct `bash lib/goal-*.sh`,
# and every fixture that does the same). Do NOT "simplify" this to the single
# CLAUDE_PLUGIN_ROOT read. (#381 note: the reason this comment used to give —
# a byte-identical Codex mirror running with `PLUGIN_ROOT` — is void, that tree
# is deleted. The chain is not: it was always load-bearing for the above.)
UBERDEV_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"

# >>> region: bash4-resolver
# Execution-contract resolver (issue #294). Three outcomes:
#   (a) already running under bash >= 4  -> publish THIS interpreter and
#       proceed (CI / explicit `bash` run).
#   (b) NOT bash >= 4, but a bash >= 4 binary is discoverable -> resolve it,
#       publish it as UBERDEV_GOAL_BASH, and re-exec THIS script under it so the
#       glob/array semantics are correct from here on. The re-exec is the
#       issue-#294 `exec "$(command -v bash)" …` fix. When the caller has no
#       script path to re-feed (a sourced region, or an inline `zsh -c` body
#       whose $0 is the interpreter, not a file), the exec is skipped and we
#       fall through to (b'): proceed under the published contract.
#       NEVER a silent dead-end while bash>=4 exists (issue #294 acceptance
#       criterion).
#   (c) no bash >= 4 anywhere -> exit 2 with the brew-install directive.
#
# `command -v` (NOT `type -t`, a bashism that misreports under the zsh-backed
# runner — project memory project_uberdev_type_t_bashism_zsh) + the explicit
# brew paths mirror lib/dispatch.sh's TIMEOUT_BIN resolver and tests/goal.test.sh
# G40's `[ -x /opt/homebrew/bin/bash ]` fallback. Each candidate's MAJOR
# version is verified >= 4 via `--version` (a `bash` on PATH could itself be
# 3.2 on stock macOS), so we never publish a too-old interpreter.
if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  # (a) already bash >= 4. Publishing the interpreter is NOT redundant here:
  # the re-exec below only fixes THIS process, while Phases 1/2/3 are launched
  # as SEPARATE processes by skills/goal-pipeline/workflow.js. Without a
  # published path the driver falls back to PATH `bash`, which is 3.2 on stock
  # macOS — and lib/goal-watch.sh's unmatched-glob verdict locator needs >= 4.
  # $BASH is the absolute path of the running interpreter; an inherited value
  # (the re-exec arm exports it before exec'ing) always wins so the two arms
  # agree on one answer.
  UBERDEV_GOAL_BASH="${UBERDEV_GOAL_BASH:-${BASH:-}}"
  export UBERDEV_GOAL_BASH
else
  UBERDEV_GOAL_BASH=""
  for _cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [ -n "$_cand" ] && [ -x "$_cand" ] || continue
    _cand_major="$("$_cand" -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)"
    case "$_cand_major" in ''|*[!0-9]*) continue ;; esac
    if [ "$_cand_major" -ge 4 ]; then UBERDEV_GOAL_BASH="$_cand"; break; fi
  done
  if [ -z "$UBERDEV_GOAL_BASH" ]; then
    # (c) genuinely unrunnable — no bash >= 4 on this host.
    echo "goal: requires bash >= 4 (the watch loop's unmatched-glob verdict locator fatals under zsh, and macOS's default /bin/bash is 3.2). No bash >= 4 found." >&2
    echo "  - install a modern bash:  brew install bash      # -> /opt/homebrew/bin/bash 5.x" >&2
    echo "  - then re-run /uberdev:goal (its scripts will run under that bash)." >&2
    exit 2
  fi
  export UBERDEV_GOAL_BASH
  # (b) re-exec THIS script under the discovered bash ONLY when $0 is a real
  # shebang SCRIPT FILE — never the bare interpreter binary. Under an inline
  # `zsh -c '<body>'` $0 is `/bin/zsh`, which IS a readable regular file, so a
  # naive `[ -f "$0" ]` test wrongly matches and `exec bash /bin/zsh` dies with
  # "cannot execute binary file" (rc 126). Gate on a `#!` shebang in the first
  # two bytes: true for a text script, false for the ELF/Mach-O interpreter
  # binary. The UBERDEV_GOAL_BASH_REEXEC sentinel prevents an exec loop.
  _is_script=0
  if [ "${UBERDEV_GOAL_BASH_REEXEC:-0}" != "1" ] && [ -f "${0:-}" ] && [ -r "${0:-}" ]; then
    case "$(head -c2 "$0" 2>/dev/null)" in '#!') _is_script=1 ;; esac
  fi
  if [ "$_is_script" = "1" ]; then
    export UBERDEV_GOAL_BASH_REEXEC=1
    exec "$UBERDEV_GOAL_BASH" "$0" "$@"
  fi
  # (b') scriptless fall-through: cannot re-exec a sourced/inline body, so
  # proceed under the published contract. Phase-0's own steps are bash-safe
  # under zsh; the bash-requiring watch-loop glob lives in lib/goal-watch.sh,
  # which skills/goal-pipeline/workflow.js runs under $UBERDEV_GOAL_BASH.
  echo "goal: not running under bash >= 4 (BASH_VERSINFO unset/old); resolved UBERDEV_GOAL_BASH=$UBERDEV_GOAL_BASH — run /goal's phase scripts under it (see commands/goal.md execution contract)." >&2
fi
# <<< region: bash4-resolver

# The argument string. Callers pass the /goal argument tokens as argv; the
# extracted-region fixtures set $ARGUMENTS directly. `$*` (not `$@`) because the
# parser below word-splits deliberately.
ARGUMENTS="${ARGUMENTS:-$*}"

# >>> region: argparse
# Parse positional issue numbers + flags. Every token matching ^[0-9]+$ joins
# the input queue; recognised flag tokens are listed in the case arms below.
queue=()
max_cycles_cli=""
max_parallel_cli=""
barrier_timeout_cli=""
review_grace_cli=""
watch_passes_cli=""
watch_budget_cli=""
max_watch_ticks_cli=""
only_mine=0
dry_run=0
resume=0
backend_cli=""
for tok in $ARGUMENTS; do
  case "$tok" in
    --max-cycles=*)         max_cycles_cli="${tok#--max-cycles=}" ;;
    --max-parallel=*)       max_parallel_cli="${tok#--max-parallel=}" ;;
    --barrier-timeout=*)    barrier_timeout_cli="${tok#--barrier-timeout=}" ;;
    --review-grace-secs=*)  review_grace_cli="${tok#--review-grace-secs=}" ;;
    --watch-passes=*)       watch_passes_cli="${tok#--watch-passes=}" ;;
    --watch-budget=*)       watch_budget_cli="${tok#--watch-budget=}" ;;
    --max-watch-ticks=*)    max_watch_ticks_cli="${tok#--max-watch-ticks=}" ;;
    --only-mine)            only_mine=1 ;;
    --dry-run)              dry_run=1 ;;
    --resume)               resume=1 ;;
    --backend=*)            backend_cli="${tok#--backend=}" ;;
    *) case "$tok" in ''|*[!0-9]*) ;; *) queue+=("$tok") ;; esac ;;
  esac
done
# <<< region: argparse

[ -r "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh"

# >>> region: validate
# Numeric-validate every positional argument (T3 mitigation). Any failure aborts
# before any `gh` call sees the value — the first defence against `gh` argument
# injection via PR/issue numbers (R3).
#
# The ${#queue[@]} gate is not decoration: bash 4.3 and older raise an
# unbound-variable error for "${arr[@]}" on an EMPTY array under `set -u`, and
# --resume legitimately arrives with an empty positional queue.
if [ "${#queue[@]}" -gt 0 ]; then
  for issue in "${queue[@]}"; do
    _uberdev_goal_validate_int "$issue" || {
      printf 'goal: invalid issue number: %s\n' "$issue" >&2; exit 2
    }
  done
fi
# <<< region: validate

if [ "${#queue[@]}" -eq 0 ] && [ "$resume" = "0" ]; then
  echo "usage: /uberdev:goal <issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--review-grace-secs=N] [--watch-passes=N] [--watch-budget=SECS] [--max-watch-ticks=N] [--only-mine] [--dry-run] [--resume] [--backend=<name>]" >&2
  exit 2
fi

# >>> region: tunables
# Read --max-cycles via the config-read range helper. Resolves the CLI flag →
# UBERDEV_GOAL_* env → goal.* config key → the _UBERDEV_GOAL_DEFAULT_* constant.
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
MAX_CYCLES="$(UBERDEV_GOAL_MAX_CYCLES="${max_cycles_cli:-${UBERDEV_GOAL_MAX_CYCLES:-}}" \
  uberdev_read_int_in_range goal.max_cycles UBERDEV_GOAL_MAX_CYCLES 1 20 "$_UBERDEV_GOAL_DEFAULT_MAX_CYCLES")"

MAX_PARALLEL="$(UBERDEV_GOAL_MAX_PARALLEL="${max_parallel_cli:-${UBERDEV_GOAL_MAX_PARALLEL:-}}" \
  uberdev_read_int_in_range goal.max_parallel UBERDEV_GOAL_MAX_PARALLEL 1 10 \
  "$_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL")"

BARRIER_TIMEOUT_S="$(UBERDEV_GOAL_BARRIER_TIMEOUT_S="${barrier_timeout_cli:-${UBERDEV_GOAL_BARRIER_TIMEOUT_S:-}}" \
  uberdev_read_int_in_range goal.barrier_timeout_s UBERDEV_GOAL_BARRIER_TIMEOUT_S 60 86400 \
  "$_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S")"

REVIEW_GRACE_SECS="$(UBERDEV_GOAL_REVIEW_GRACE_SECS="${review_grace_cli:-${UBERDEV_GOAL_REVIEW_GRACE_SECS:-}}" \
  uberdev_read_int_in_range goal.review_grace_secs UBERDEV_GOAL_REVIEW_GRACE_SECS 60 86400 \
  "$_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS")"

# Bounded watch mode (issue #299 finding 2). WATCH_PASSES / WATCH_BUDGET use
# range [0, N] with default 0 — 0 is the UNBOUNDED sentinel. A positive value
# bounds ONE lib/goal-watch.sh invocation to N poll passes / SECS wall-clock; on
# the bound the script persists run-state and exits 42 ("still-active,
# re-invoke"). GOAL_SINGLE_TICK=1 is the env shorthand for --watch-passes=1
# (applied only when neither a pass nor a budget bound was given).
WATCH_PASSES="$(UBERDEV_GOAL_WATCH_PASSES="${watch_passes_cli:-${UBERDEV_GOAL_WATCH_PASSES:-}}" \
  uberdev_read_int_in_range goal.watch_passes UBERDEV_GOAL_WATCH_PASSES 0 100000 0)"
WATCH_BUDGET="$(UBERDEV_GOAL_WATCH_BUDGET="${watch_budget_cli:-${UBERDEV_GOAL_WATCH_BUDGET:-}}" \
  uberdev_read_int_in_range goal.watch_budget UBERDEV_GOAL_WATCH_BUDGET 0 86400 0)"

# MAX_WATCH_TICKS is the driver-side CB3 bound: how many lib/goal-watch.sh
# invocations skills/goal-pipeline/workflow.js will relay in ONE cycle before it
# halts deterministically. It is resolved HERE (rather than left to the driver's
# hardcoded clamp default) so an operator can actually tune it — the same
# CLI-flag → UBERDEV_GOAL_* env → goal.* config key → default chain every other
# goal tunable uses. Range matches the driver's clampInt(…, 1, 500, 40).
MAX_WATCH_TICKS="$(UBERDEV_GOAL_MAX_WATCH_TICKS="${max_watch_ticks_cli:-${UBERDEV_GOAL_MAX_WATCH_TICKS:-}}" \
  uberdev_read_int_in_range goal.max_watch_ticks UBERDEV_GOAL_MAX_WATCH_TICKS 1 500 40)"
if [ "${GOAL_SINGLE_TICK:-0}" = "1" ] && [ "${WATCH_PASSES:-0}" -eq 0 ] && [ "${WATCH_BUDGET:-0}" -eq 0 ]; then
  WATCH_PASSES=1
fi
# #301 (RFC 0012 §3.3 goal-R1 item 3) — bounded-watch DEFAULT under the
# Claude-Code Bash tool. The legacy 0-default (unbounded `while true … sleep`)
# is wrong under the Bash-tool runtime: a single Bash call is hard-capped at
# 600s, so an unbounded watch invocation gets SIGTERMed mid-watch ~10 minutes in
# (and pre-#301 that TERM also fired the reaper, killing every live solver).
# When the operator gave NO explicit bound anywhere AND we are executing under
# the Claude-Code Bash tool (CLAUDECODE env marker), default WATCH_BUDGET to
# _UBERDEV_GOAL_DEFAULT_WATCH_BUDGET (480s = the 600s call cap minus headroom
# for one worst-case serial gh walk). An explicit `--watch-budget=0` /
# UBERDEV_GOAL_WATCH_BUDGET=0 opts back into the unbounded loop.
if [ -n "${CLAUDECODE:-}" ] \
   && [ "${WATCH_PASSES:-0}" -eq 0 ] && [ "${WATCH_BUDGET:-0}" -eq 0 ] \
   && [ -z "${watch_passes_cli:-}" ] && [ -z "${watch_budget_cli:-}" ] \
   && [ -z "${UBERDEV_GOAL_WATCH_PASSES:-}" ] && [ -z "${UBERDEV_GOAL_WATCH_BUDGET:-}" ]; then
  WATCH_BUDGET="${_UBERDEV_GOAL_DEFAULT_WATCH_BUDGET:-480}"
  echo "goal: defaulting WATCH_BUDGET=${WATCH_BUDGET}s under the Claude-Code Bash tool (600s call cap; bounded-tick 0/42/1 re-invocation contract; pass --watch-budget=0 to force the unbounded loop)" >&2
fi
export WATCH_PASSES WATCH_BUDGET
# <<< region: tunables

# >>> region: backend
# Source lib/dispatch.sh; call uberdev_dispatch_preflight → sets
# UBERDEV_RESOLVED_BACKEND once for the whole run (D15). RFC 0015 §5: /goal now
# runs on the Workflow-native backend that `auto` resolves to — its solvers are
# spawned by skills/solve-fleet/workflow.js from inside the calling session,
# NOT by lib/dispatch.sh. The interim
# `uberdev_dispatch_demote_workflow_to_detached` call that used to sit here is
# GONE; there is no demotion, and no detached transport is on any default path.
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh"
UBERDEV_DISPATCH_BACKEND_REQUESTED="${backend_cli:-${UBERDEV_DISPATCH_BACKEND_REQUESTED:-auto}}"
export UBERDEV_DISPATCH_BACKEND_REQUESTED
uberdev_dispatch_preflight
# /goal dispatches its solvers through the solve-fleet; mirror /turbo's
# unattended dispatch env so the launcher and every child inherit the same flags
# /turbo would have set.
export AUTO_MODE=1            # matches commands/turbo.md (enables UBERDEV_TURBO=1 in the child env)
# /goal opts every dispatched child into bypassPermissions so the cmux
# PermissionRequest hook (or any --settings-shadowing daemon hook) does not
# stall first-tool-use. The autonomous-loop contract requires it; standalone
# /turbo + /solve defensively unset this var. EFFORT_LEVEL stays unset ->
# helper applies :-max.
export SKIP_PERMISSIONS=1     # (#241) /goal autonomous-loop opt-in
uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || exit 1   # establishes TIMEOUT_BIN/SOLVE_TIMEOUT/MODEL/PERM_FLAG/EFFORT_FLAG once
# <<< region: backend

# >>> region: goal-id
# Generate GOAL_ID. Random suffix per D4 — NEVER derived from $@ or issue
# numbers (those are attacker-controlled; using them would let a caller collide
# TMPDIR paths).
export UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"   # D7 — stable sidecar dir for the watcher
if [ "$resume" = "1" ]; then
  # --resume rehydrates the run this host last started, via the fixed-path
  # goal-active-id.txt pointer uberdev_goal_write_run_state maintains. Without
  # the pointer there is nothing to resume — say so instead of silently minting
  # a fresh (empty) run that would look like convergence on cycle 1.
  #
  # Rehydration deliberately OVERWRITES the tunables resolved above: a resumed
  # run keeps the cycle counter, queue and bounds it was started with, so
  # `--resume --max-cycles=9` does not silently re-open a ceiling the original
  # run was already measured against. Change a bound by starting a new run.
  unset UBERDEV_GOAL_ID
  if ! uberdev_goal_read_run_state; then
    echo "goal: --resume found no resumable run-state under $UBERDEV_TMPDIR (goal-active-id.txt missing or unreadable)" >&2
    exit 2
  fi
  GOAL_ID="${UBERDEV_GOAL_ID:-}"
  if [ -z "$GOAL_ID" ]; then
    echo "goal: --resume rehydrated run-state but no GOAL_ID — refusing to continue on an ambiguous run" >&2
    exit 2
  fi
  echo "goal: resuming run $GOAL_ID at cycle ${cycle:-1} (queue=${queue[*]:-})" >&2
else
  # #299 finding 3 — GOAL_ID does NOT carry a leading `goal-`. Every per-goal
  # sidecar path is formatted `goal-$GOAL_ID-<suffix>`, so a `goal-`-prefixed
  # GOAL_ID produced `goal-goal-…` on disk — a debugging foot-gun. The id is
  # digits/dash/alnum only, so _uberdev_goal_validate_id accepts it, and it
  # never begins with `goal-` so the sidecar mis-pathing guard cannot trip.
  GOAL_ID="$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
  export UBERDEV_GOAL_ID="$GOAL_ID"
fi
# <<< region: goal-id

# >>> region: state-init
# uberdev_goal_state_init truncate-creates the per-goal state files (jsonl + the
# TSV sidecars) under $UBERDEV_TMPDIR and refuses unsafe path characters (T4).
# On --resume the files already exist and MUST NOT be truncated.
if [ "$resume" != "1" ]; then
  uberdev_goal_state_init "$GOAL_ID" || exit 1
fi
# <<< region: state-init

# >>> region: counters
# Initialize the cycle counter + goal-level wall-clock anchor. `watch_start` is
# the GOAL-level anchor — it must persist across cycles so the 4h stuck-loop
# breaker (_UBERDEV_GOAL_STUCK_SECS) measures total goal wall-clock, not
# per-cycle. `overflow_count` / `overflow_detected` are per-cycle accumulators
# set by lib/goal-watch.sh and reset at the end of lib/goal-phase3.sh.
if [ "$resume" != "1" ]; then
  cycle=1
  watch_start="$(date +%s)"
  overflow_count=0
  overflow_detected=0
  # #171 — persist the run-state pointer + loop accumulators so the later phase
  # scripts (fresh processes) can rehydrate GOAL_ID + counters.
  uberdev_goal_write_run_state || { echo "goal: failed to persist run-state" >&2; exit 3; }
fi
# <<< region: counters

# >>> region: dry-run
# --dry-run is the audit/preview surface — no `gh` calls, no agent spawns, no
# merges, no audit events (S9 — goal_dispatched must NOT fire on dry-run so the
# audit log only carries real runs). This runs BEFORE the real goal_dispatched
# emit below — order matters.
if [ "$dry_run" = "1" ]; then
  printf 'goal: dry-run preview (no agent spawn, no audit emit)\n'
  printf '  MAX_CYCLES=%s\n' "$MAX_CYCLES"
  printf '  MAX_PARALLEL=%s\n' "$MAX_PARALLEL"
  printf '  BARRIER_TIMEOUT_S=%s\n' "$BARRIER_TIMEOUT_S"
  printf '  WATCH_PASSES=%s WATCH_BUDGET=%s (0=unbounded watch loop)\n' \
    "${WATCH_PASSES:-0}" "${WATCH_BUDGET:-0}"
  printf '  MAX_WATCH_TICKS=%s (driver-side CB3 bound)\n' "$MAX_WATCH_TICKS"
  printf '  backend=%s\n' "$UBERDEV_RESOLVED_BACKEND"
  printf '  issues=%s\n' "${queue[*]}"
  printf '  would emit goal_dispatched\n'
  printf '  would claim + solve issues %s via the solve-fleet Workflow (cap=%s per cycle)\n' \
    "${queue[*]}" "$MAX_PARALLEL"
  printf '  would poll GitHub (gh pr list) for each issue'\''s PR\n'
  exit 0
fi
# <<< region: dry-run

# >>> region: dispatched-emit
# Emit goal_dispatched with {goal_id, cycle: 0, issues, dry_run, backend} —
# the audit anchor. cycle: 0 distinguishes the initial dispatch from the
# per-cycle Phase-1 claim.
if [ "${#queue[@]}" -gt 0 ]; then
  issues_json="$(printf '%s\n' "${queue[@]}" | jq -R . | jq -sc .)"
else
  # An empty queue is a --resume run with nothing left to dispatch. `printf
  # '%s\n' "${queue[@]}"` would emit ONE blank line there, and jq -R would turn
  # that into `[""]` — a phantom issue in the audit anchor.
  issues_json='[]'
fi
uberdev_goal_audit goal_dispatched \
  "{\"goal_id\":\"$GOAL_ID\",\"cycle\":0,\"issues\":$issues_json,\"dry_run\":$dry_run,\"backend\":\"$UBERDEV_RESOLVED_BACKEND\"}"
# <<< region: dispatched-emit

# >>> region: rate-limit
# `gh api rate_limit` soft pre-flight (Q5 tertiary). Warn-only — never halt. Per
# cycle the watcher generates roughly `5 × N × 60` gh calls; rate-limit
# exhaustion mid-run is the highest-likelihood "stuck loop" cause that is NOT a
# real bug, so surface it up-front.
remaining="$(gh api rate_limit --jq '.resources.core.remaining // 0' 2>/dev/null || echo 0)"
if [ "$remaining" -lt 1000 ]; then
  printf 'goal: warning — gh API rate-limit remaining=%s < 1000; long runs may stall on 403s\n' \
    "$remaining" >&2
fi
# <<< region: rate-limit

# >>> region: emit-args
# The Workflow args envelope. RFC 0012 §4.1: refuse at PREFLIGHT when the
# on-disk driver is missing, never at the runtime layer.
GOAL_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
GOAL_WORKFLOW_JS="$GOAL_PLUGIN_ROOT/skills/goal-pipeline/workflow.js"
if [ ! -f "$GOAL_WORKFLOW_JS" ]; then
  echo "error: $GOAL_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin — /goal has no non-Workflow driver" >&2
  exit 2
fi
if ! command -v uberdev_emit_workflow_args >/dev/null 2>&1; then
  if [ -r "$GOAL_PLUGIN_ROOT/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "$GOAL_PLUGIN_ROOT/lib/config-read.sh"
  fi
fi
if ! command -v uberdev_emit_workflow_args >/dev/null 2>&1; then
  echo "error: uberdev_emit_workflow_args unavailable (lib/config-read.sh not loadable from $GOAL_PLUGIN_ROOT); cannot emit the goal args envelope" >&2
  exit 2
fi
if ! GOAL_REPO_ROOT_ABS="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$GOAL_REPO_ROOT_ABS" ]; then
  echo "error: unable to resolve the repository root for the goal args envelope" >&2
  exit 2
fi
GOAL_QUEUE_CSV=""
if [ "${#queue[@]}" -gt 0 ]; then
  GOAL_QUEUE_CSV="$(printf '%s,' "${queue[@]}")"; GOAL_QUEUE_CSV="${GOAL_QUEUE_CSV%,}"
fi
# The bash >= 4 EXECUTION CONTRACT, carried to the phases that actually need it.
# Phases 1/2/3 run as fresh processes launched by
# skills/goal-pipeline/workflow.js's relays; nothing of this process's
# environment reaches them, so the resolver's re-exec above protects Phase 0
# ONLY. Ship the resolved interpreter in the envelope and the driver launches
# `"$bashBin" lib/goal-*.sh` instead of PATH `bash` (3.2 on stock macOS, where
# lib/goal-watch.sh dies on `active_issues[@]: unbound variable`). Absolute
# executable path or nothing — the driver falls back to `bash` on an empty or
# malformed value rather than trusting a relative word.
GOAL_BASH_BIN="${UBERDEV_GOAL_BASH:-}"
case "$GOAL_BASH_BIN" in
  /*) [ -x "$GOAL_BASH_BIN" ] || GOAL_BASH_BIN="" ;;
  *)  GOAL_BASH_BIN="" ;;
esac
if [ -z "$GOAL_BASH_BIN" ]; then
  echo "goal: WARN could not publish a bash >= 4 path for the relay-run phase scripts; they will run under PATH \`bash\` (lib/goal-watch.sh requires >= 4)" >&2
fi
uberdev_emit_workflow_args goal \
  repo_root="$GOAL_REPO_ROOT_ABS" \
  pluginRootAbs="$GOAL_PLUGIN_ROOT" \
  repoRootAbs="$GOAL_REPO_ROOT_ABS" \
  tmpDirAbs="$UBERDEV_TMPDIR" \
  goalId="$GOAL_ID" \
  issues="$GOAL_QUEUE_CSV" \
  maxCycles="$MAX_CYCLES" \
  maxParallel="$MAX_PARALLEL" \
  barrierTimeoutS="$BARRIER_TIMEOUT_S" \
  reviewGraceSecs="$REVIEW_GRACE_SECS" \
  watchPasses="${WATCH_PASSES:-0}" \
  watchBudgetS="${WATCH_BUDGET:-0}" \
  maxWatchTicks="$MAX_WATCH_TICKS" \
  bashBin="$GOAL_BASH_BIN" \
  onlyMine="$([ "$only_mine" = "1" ] && echo true || echo false)" \
  resumed="$([ "$resume" = "1" ] && echo true || echo false)" \
  backend="$UBERDEV_RESOLVED_BACKEND" \
  maxAgents="${UBERDEV_GOAL_MAX_AGENTS:-250}"

echo "goal: run $GOAL_ID prepared (issues=${queue[*]:-none} max_cycles=$MAX_CYCLES max_parallel=$MAX_PARALLEL backend=$UBERDEV_RESOLVED_BACKEND)" >&2
echo "Relay the JSON between WORKFLOW_ARGS_BEGIN/WORKFLOW_ARGS_END verbatim into Workflow({scriptPath: \"$GOAL_WORKFLOW_JS\"}, <args>)." >&2
# <<< region: emit-args
exit 0
