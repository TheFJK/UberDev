# plugins/uberdev/lib/status.sh
#
# Read-only run-state aggregator for /uberdev:status (issue #310).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_status_render          -> print the whole census to stdout
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS (root cause: a missing discovery seam, not a table)
#
# UberDev keeps run state in FIVE disjoint stores:
#
#   1. /solve + /turbo claims      the `uberdev:active` GitHub label plus
#                                  per-issue solve-{bg,codex}-status-<N>.json
#                                  under the runtime root
#   2. /goal                       GOAL_ID-keyed sidecars (1 jsonl + 7 TSVs +
#                                  the runstate scalar/array files), reachable
#                                  only through the fixed-path
#                                  goal-active-id.txt bootstrap pointer
#   3. /review-pr                  .uberdev/runs/<RUN_ID>/{locked,pr-context.json}
#   4. /merge                      the mkdir-atomic <git-dir>/uberdev-merge.lock.d/
#                                  record + heartbeat, plus .uberdev/audit.jsonl
#   5. per-run agent lifecycle     <run_dir>/.agent-state-<euid>/agent-lifecycle.jsonl
#                                  written by lib/agent-dispatch.sh
#
# The stores do not agree on their ROOT. lib/dispatch.sh hardens the runtime
# root to `${TMPDIR:-/tmp}/uberdev-$(id -u)` and exports UBERDEV_TMPDIR — but a
# Bash tool call shares no shell state with the next one, so that export is
# process-scoped. lib/goal-state.sh falls back to bare `/tmp` in most helpers
# and to `${TMPDIR:-/tmp}` in the newer ones. A fresh post-crash shell therefore
# reads a DIFFERENT root than the one the artefacts were written to, and the
# operator is told "nothing in flight" while a half-finished run sits one
# directory over. The missing piece is a DISCOVERY SEAM: this reader probes
# every root a writer can reach and PRINTS which root each section actually
# read. That visibility is the deliverable; the table is the by-product.
#
# ---------------------------------------------------------------------------
# READ-ONLY CONTRACT (binding)
#
# Nothing here may create, modify, move, or delete a filesystem entry, and no
# `gh` sub-command that mutates GitHub state may be invoked. Consequences that
# are easy to get wrong:
#
#   - The runtime-root probe re-implements lib/dispatch.sh's SAFETY CHECKS
#     without its `mkdir`/`chmod` hardening. Calling
#     _uberdev_dispatch_runtime_root would CREATE the root it is asked about.
#   - config-read.sh's `uberdev_read_int_in_range` is NOT used, even though it
#     is the normal way to resolve these thresholds: on an invalid configured
#     value it calls _uberdev_audit_invalid, which APPENDS to
#     `$PWD/.uberdev/audit.jsonl`. _uberdev_status_config_int below reads the
#     same env/config tiers through config-read.sh's pure `_uberdev_read_project_key`
#     and validates locally, warning on stderr instead of writing.
#   - Python runs with `-B` (no __pycache__) and receives its data on STDIN —
#     never a filesystem path in argv, which would not survive the Git Bash ->
#     python.exe path translation on native Windows.
#
# tests/status.test.sh asserts the contract by diffing a fixture tree
# (path, type, size, mtime, sha256) before and after a full render.
#
# ---------------------------------------------------------------------------
# CROSS-SHELL NOTES
#
# The /uberdev:status command body runs through the Bash tool, which is backed
# by /bin/zsh on macOS. Therefore:
#   - `command -v`, never `type -t` (a bashism that misreports under zsh).
#   - no arrays and no unquoted scalar word-splitting (`for x in $LIST` splits
#     under bash and does NOT under zsh); every list is newline-delimited and
#     consumed with `while IFS= read -r`.
#   - no bare globs (an unmatched glob is a hard error under zsh); directory
#     listings go through `find`.
#   - `grep -q PAT <<<"$V"` herestrings, never `printf | grep -q` (a pipe into
#     a -q grep can EPIPE-race under `set -o pipefail` on Linux CI).
#   - `stat -c` is probed BEFORE `stat -f`: on GNU coreutils `-f` means
#     --file-system and exits 0 with unrelated output.
#   - NEVER name a local `path` (nor cdpath/fpath/manpath/mailpath/module_path/
#     psvar/watch/status/argv/options/commands). zsh TIES the `path` array to
#     `$PATH`, so `local path="$1"` replaces the command search path for the
#     whole call frame: `stat`, `date`, `find` and `awk` all become
#     command-not-found, every external probe silently returns rc=1, and the
#     safety-critical verdicts INVERT (a live /merge lock renders STALE, and
#     /status then tells the operator to steal it). Locals that hold a
#     filesystem path are named `target`/`file`/`dir`/`root`. Asserted
#     structurally by tests/status.test.sh S1.17 and behaviourally by S14.
#
# Sourced by:
#   - commands/status.md (the only production caller)
#   - tests/status.test.sh

if [ "${_UBERDEV_STATUS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

_uberdev_status_source_path() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    return 1
  fi
}
_UBERDEV_STATUS_FILE="$(_uberdev_status_source_path)" || return 1
case "$_UBERDEV_STATUS_FILE" in
  */*) _UBERDEV_STATUS_LIB_DIR="${_UBERDEV_STATUS_FILE%/*}" ;;
  *) _UBERDEV_STATUS_LIB_DIR='.' ;;
esac
_UBERDEV_STATUS_LIB_DIR="$(cd "$_UBERDEV_STATUS_LIB_DIR" 2>/dev/null && pwd -P)"
# config-read.sh is source-time inert and owns the project-config reader this
# file needs. Optional: a caller that already sourced it, or a stripped
# install, degrades to the shipped defaults.
if [ -r "$_UBERDEV_STATUS_LIB_DIR/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "$_UBERDEV_STATUS_LIB_DIR/config-read.sh" || true
fi
# lib/dispatch.sh is deliberately NOT sourced: it is the mutation surface
# (worktree creation, provider launch, lock acquisition). A read-only reader
# must not load it just to borrow a Python resolver.
_UBERDEV_STATUS_LOADED=1

# --- Constants -------------------------------------------------------------
# Contract mirrors, not independent policy. Each value restates a producer's
# constant; the comment names the producer so drift stays auditable.

# solve-launcher.sh:UBERDEV_ACTIVE_LABEL
_UBERDEV_STATUS_ACTIVE_LABEL='uberdev:active'
# goal-state.sh:_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS
_UBERDEV_STATUS_REVIEW_GRACE_DEFAULT_SECS=3600
# goal-pipeline/SKILL.md: --review-grace-secs accepted range
_UBERDEV_STATUS_REVIEW_GRACE_MIN_SECS=60
_UBERDEV_STATUS_REVIEW_GRACE_MAX_SECS=86400
# review-pr.md:REVIEW_RESERVATION_REAP_SECS (documented as 2 x the grace default)
_UBERDEV_STATUS_REVIEW_REAP_DEFAULT_SECS=7200
# merge-pipeline/SKILL.md:LOCK_STALE_FLOOR_SEC
_UBERDEV_STATUS_MERGE_LOCK_STALE_FLOOR_SECS=900
# merge-pipeline/SKILL.md Step 1.0a: command_timeouts.merge default + range
_UBERDEV_STATUS_MERGE_TIMEOUT_DEFAULT_SECS=600
_UBERDEV_STATUS_MERGE_TIMEOUT_MIN_SECS=60
_UBERDEV_STATUS_MERGE_TIMEOUT_MAX_SECS=86400
# merge-pipeline/SKILL.md:LOCK_FILE_PATH, relative to a git dir
_UBERDEV_STATUS_MERGE_LOCK_BASENAME='uberdev-merge.lock.d'
# review-pr.md run root; goal-state.sh globs the same shape
_UBERDEV_STATUS_REVIEW_RUNS_RELPATH='.uberdev/runs'
# merge-pipeline/SKILL.md:AUDIT_LOG_DIR_PATTERN + AUDIT_LOG_FILENAME
_UBERDEV_STATUS_AUDIT_RELPATH='.uberdev/audit.jsonl'
# goal-state.sh:uberdev_goal_write_run_state bootstrap pointer
_UBERDEV_STATUS_GOAL_POINTER_BASENAME='goal-active-id.txt'
# agent-dispatch.sh:_uberdev_agent_prepare_state_dir + the manifest it writes
_UBERDEV_STATUS_AGENT_STATE_PREFIX='.agent-state-'
_UBERDEV_STATUS_LIFECYCLE_BASENAME='agent-lifecycle.jsonl'
# agent-dispatch.sh:_uberdev_agent_event_json terminal event set
_UBERDEV_STATUS_TERMINAL_EVENTS='completed failed timed_out cancelled abandoned'
# Render bounds. Every store is append-only and unbounded; a census that
# scrolls off-screen is as useless as no census at all.
_UBERDEV_STATUS_MAX_ROWS=25
_UBERDEV_STATUS_AUDIT_TAIL_ROWS=5
_UBERDEV_STATUS_JSONL_TAIL_LINES=2000
_UBERDEV_STATUS_GH_QUERY_LIMIT=50
_UBERDEV_STATUS_TEXT_LIMIT=100

# Shared Python prelude. Every value this reader renders originates in a
# world-writable temp root or in GitHub-supplied text, so it is UNTRUSTED: a
# control byte or an embedded newline would corrupt the render (or the
# terminal). `clean` is the single choke point that neutralises it.
# argv[1] is the text limit; argv[2:] are the caller's extra scalars — never a
# filesystem path (see the READ-ONLY CONTRACT note on Windows path translation).
_UBERDEV_STATUS_PY_PRELUDE='
import json, sys

TEXT_LIMIT = int(sys.argv[1])
ARGS = sys.argv[2:]

def clean(value, limit=None):
    if value is None:
        return ""
    text = "".join(
        ch if (ch.isprintable() and ch != "\t") else " " for ch in str(value)
    ).strip()
    return text[: (TEXT_LIMIT if limit is None else limit)]

def rows(stream):
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            yield record
'

# --- Primitives ------------------------------------------------------------

_uberdev_status_is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Mirrors goal-state.sh:_uberdev_goal_validate_id. A GOAL_ID read back from the
# bootstrap pointer is untrusted input that would be interpolated into a path.
_uberdev_status_valid_goal_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *..*) return 1 ;;
    *) return 0 ;;
  esac
}

# Membership test over a newline-delimited list. Replaces the array/`in`
# idioms that do not behave identically under bash and zsh.
_uberdev_status_list_has() {
  local list="$1" needle="$2" item
  while IFS= read -r item; do
    [ "$item" = "$needle" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

_UBERDEV_STATUS_PYTHON_EXE=''
_UBERDEV_STATUS_PYTHON_PREFIX=''
_uberdev_status_python() {
  if [ -z "$_UBERDEV_STATUS_PYTHON_EXE" ]; then
    if command -v python3 >/dev/null 2>&1; then
      _UBERDEV_STATUS_PYTHON_EXE="$(command -v python3)"; _UBERDEV_STATUS_PYTHON_PREFIX=''
    elif command -v python >/dev/null 2>&1; then
      _UBERDEV_STATUS_PYTHON_EXE="$(command -v python)"; _UBERDEV_STATUS_PYTHON_PREFIX=''
    elif command -v py >/dev/null 2>&1; then
      _UBERDEV_STATUS_PYTHON_EXE="$(command -v py)"; _UBERDEV_STATUS_PYTHON_PREFIX='-3'
    else
      return 127
    fi
  fi
  if [ -n "$_UBERDEV_STATUS_PYTHON_PREFIX" ]; then
    "$_UBERDEV_STATUS_PYTHON_EXE" "$_UBERDEV_STATUS_PYTHON_PREFIX" -I -B "$@"
  else
    "$_UBERDEV_STATUS_PYTHON_EXE" -I -B "$@"
  fi
}

# _uberdev_status_py SCRIPT [EXTRA_SCALAR...]
# Run one JSON-decoding snippet against stdin. Extra scalars arrive as ARGS in
# the prelude — passing them as argv is what keeps the snippets free of the
# nested-quote splicing that silently corrupts embedded shell expansions.
_uberdev_status_py() {
  local script="$1"
  shift
  _uberdev_status_python -c "$_UBERDEV_STATUS_PY_PRELUDE
$script" "$_UBERDEV_STATUS_TEXT_LIMIT" "$@"
}

_uberdev_status_have_python() {
  _uberdev_status_python -c 'pass' 0 >/dev/null 2>&1
}

_uberdev_status_now_secs() { date +%s; }

# Epoch mtime of TARGET, or rc=1. `stat -c` FIRST: on GNU coreutils `stat -f`
# means --file-system and exits 0 with unrelated output, so a BSD-first probe
# yields silent garbage on Linux CI. The local is `target`, never `path` — see
# the zsh tied-array note in CROSS-SHELL NOTES; naming it `path` here empties
# $PATH for this frame and makes `stat` itself unfindable.
_uberdev_status_mtime() {
  local target="$1" value=''
  [ -e "$target" ] || return 1
  value="$(stat -c %Y "$target" 2>/dev/null)" || value=''
  if ! _uberdev_status_is_int "$value"; then
    value="$(stat -f %m "$target" 2>/dev/null)" || value=''
  fi
  _uberdev_status_is_int "$value" || return 1
  printf '%s\n' "$value"
}

_uberdev_status_age_secs() {
  local mtime now
  mtime="$(_uberdev_status_mtime "$1")" || return 1
  now="$(_uberdev_status_now_secs)"
  _uberdev_status_is_int "$now" || return 1
  if [ "$now" -lt "$mtime" ]; then printf '0\n'; else printf '%s\n' "$(( now - mtime ))"; fi
}

# Resolve a DIRECTORY to its physical path without touching it.
_uberdev_status_resolve_dir() {
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

# Newline-delimited, sorted listing of entries directly under DIR matching
# NAME_GLOB. `find` (not a shell glob) because an unmatched glob is a hard
# error under zsh; `-maxdepth 1` keeps the walk bounded.
_uberdev_status_list() {
  local dir="$1" kind="$2" pattern="$3"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -mindepth 1 -type "$kind" -name "$pattern" 2>/dev/null \
    | LC_ALL=C sort
}

_uberdev_status_rule() { printf '\n== %s ==\n' "$1"; }
_uberdev_status_note() { printf '  %s\n' "$1"; }
_uberdev_status_row() { printf '    %s\n' "$1"; }
_uberdev_status_hint() { printf '      re-enter: %s\n' "$1"; }

# --- Threshold resolution --------------------------------------------------

# _uberdev_status_config_int KEY ENV_VAR MIN MAX DEFAULT
# The read-only twin of config-read.sh:uberdev_read_int_in_range. Same env >
# project-config > default precedence and the same range clamp, but an invalid
# value warns on stderr instead of appending an audit row to
# $PWD/.uberdev/audit.jsonl (see the READ-ONLY CONTRACT note). ENV_VAR is
# matched, not eval'd — the two supported names are constants of this file.
_uberdev_status_config_int() {
  local key="$1" env_var="$2" min="$3" max="$4" default="$5" value=''
  case "$env_var" in
    UBERDEV_GOAL_REVIEW_GRACE_SECS) value="${UBERDEV_GOAL_REVIEW_GRACE_SECS:-}" ;;
    UBERDEV_MERGE_TIMEOUT) value="${UBERDEV_MERGE_TIMEOUT:-}" ;;
    *) printf 'uberdev status: unsupported config env var %s\n' "$env_var" >&2; return 1 ;;
  esac
  if [ -z "$value" ] && command -v _uberdev_read_project_key >/dev/null 2>&1; then
    value="$(_uberdev_read_project_key "$key" 2>/dev/null)" || value=''
  fi
  if [ -z "$value" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! _uberdev_status_is_int "$value" || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    printf 'uberdev status: %s = %s is invalid or out of [%s, %s]; classifying with default %s\n' \
      "$key" "$value" "$min" "$max" "$default" >&2
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$value"
}

_uberdev_status_review_grace_secs() {
  _uberdev_status_config_int goal.review_grace_secs UBERDEV_GOAL_REVIEW_GRACE_SECS \
    "$_UBERDEV_STATUS_REVIEW_GRACE_MIN_SECS" "$_UBERDEV_STATUS_REVIEW_GRACE_MAX_SECS" \
    "$_UBERDEV_STATUS_REVIEW_GRACE_DEFAULT_SECS"
}

# review-pr.md resolves this as a plain env-or-default. Mirror it exactly
# rather than re-deriving it from the grace window, so /status never classifies
# a reservation with a threshold its owner does not use.
_uberdev_status_review_reap_secs() {
  local value="${REVIEW_RESERVATION_REAP_SECS:-$_UBERDEV_STATUS_REVIEW_REAP_DEFAULT_SECS}"
  _uberdev_status_is_int "$value" || value="$_UBERDEV_STATUS_REVIEW_REAP_DEFAULT_SECS"
  printf '%s\n' "$value"
}

_uberdev_status_merge_stale_secs() {
  local timeout
  timeout="$(_uberdev_status_config_int command_timeouts.merge UBERDEV_MERGE_TIMEOUT \
    "$_UBERDEV_STATUS_MERGE_TIMEOUT_MIN_SECS" "$_UBERDEV_STATUS_MERGE_TIMEOUT_MAX_SECS" \
    "$_UBERDEV_STATUS_MERGE_TIMEOUT_DEFAULT_SECS")" \
    || timeout="$_UBERDEV_STATUS_MERGE_TIMEOUT_DEFAULT_SECS"
  _uberdev_status_is_int "$timeout" || timeout="$_UBERDEV_STATUS_MERGE_TIMEOUT_DEFAULT_SECS"
  if [ "$timeout" -lt "$_UBERDEV_STATUS_MERGE_LOCK_STALE_FLOOR_SECS" ]; then
    timeout="$_UBERDEV_STATUS_MERGE_LOCK_STALE_FLOOR_SECS"
  fi
  printf '%s\n' "$timeout"
}

# --- The discovery seam ----------------------------------------------------

# Two kinds of root, two trust models.
#
# lib/dispatch.sh:_uberdev_dispatch_runtime_root CREATES its root 0700 and
# rejects one that is a symlink, is not a directory, or is not owned by the
# effective uid. That ownership rule is correct for a PRIVATE root — and wrong
# for the SHARED one: /goal's documented `${UBERDEV_TMPDIR:-/tmp}` fallback
# lands in bare `/tmp`, which is root-owned and world-sticky on every Linux
# host (and a symlink to a root-owned `/private/tmp` on macOS). Applying the
# private rule to it would make /status blind to exactly the post-crash case it
# exists for — the operator would be told "nothing in flight" while /goal's
# sidecars sit in /tmp.
#
# So the trust boundary moves down one level for shared roots: the directory
# may be foreign-owned, but every FILE read out of it must be a non-symlink
# regular file owned by the effective uid before its contents are printed
# (the same rule goal-state.sh applies through _uberdev_dispatch_tmp_target_safe).
#
# Echoes `VERDICT RESOLVED` (verdict never contains a space; resolved may be
# empty). Verdicts: ok | ok-shared | absent | not-directory | owner-mismatch |
#                   unreadable | unresolvable
_uberdev_status_probe_root() {
  local target="$1" role="$2" resolved=''
  if [ -z "$target" ]; then printf 'absent \n'; return 0; fi
  if [ ! -e "$target" ]; then printf 'absent \n'; return 0; fi
  if [ ! -d "$target" ]; then printf 'not-directory \n'; return 0; fi
  resolved="$(_uberdev_status_resolve_dir "$target")" || { printf 'unresolvable \n'; return 0; }
  if [ ! -r "$resolved" ] || [ ! -x "$resolved" ]; then
    printf 'unreadable %s\n' "$resolved"; return 0
  fi
  if [ -O "$resolved" ]; then printf 'ok %s\n' "$resolved"; return 0; fi
  if [ "$role" = shared ]; then printf 'ok-shared %s\n' "$resolved"; return 0; fi
  printf 'owner-mismatch %s\n' "$resolved"
}

# Probe one candidate and fold it into the two render globals. Globals rather
# than a return value because the report is printed once while four sections
# each walk the deduped root list. Entries are `ROLE PATH` — the role travels
# with the root so every section knows which per-file rule to enforce.
_uberdev_status_consider_root() {
  local label="$1" target="$2" role="$3" probe verdict resolved suffix effective
  probe="$(_uberdev_status_probe_root "$target" "$role")"
  verdict="${probe%% *}"
  resolved="${probe#* }"
  suffix=''
  if [ -n "$resolved" ] && [ "$resolved" != "$target" ]; then suffix=" -> $resolved"; fi
  _UBERDEV_STATUS_ROOT_REPORT="$_UBERDEV_STATUS_ROOT_REPORT$(
    printf '%-22s %-14s %s%s' "$label" "$verdict" "${target:-<unset>}" "$suffix")
"
  case "$verdict" in
    ok) effective='private' ;;
    ok-shared) effective='shared' ;;
    *) return 0 ;;
  esac
  _uberdev_status_list_has "$_UBERDEV_STATUS_ROOT_PATHS" "$resolved" && return 0
  _UBERDEV_STATUS_ROOT_PATHS="$_UBERDEV_STATUS_ROOT_PATHS$resolved
"
  _UBERDEV_STATUS_ROOTS="$_UBERDEV_STATUS_ROOTS$effective $resolved
"
}

# Every root a writer can reach, in the order a reader should trust them.
_uberdev_status_discover_roots() {
  local uid platform_tmp
  _UBERDEV_STATUS_ROOT_REPORT=''
  _UBERDEV_STATUS_ROOTS=''
  _UBERDEV_STATUS_ROOT_PATHS=''
  uid="$(id -u 2>/dev/null)" || uid=''
  _uberdev_status_is_int "$uid" || uid='0'
  platform_tmp="${TMPDIR:-/tmp}"
  # Two spellings of one root must not look like two roots.
  while [ "$platform_tmp" != '/' ] && [ "${platform_tmp%/}" != "$platform_tmp" ]; do
    platform_tmp="${platform_tmp%/}"
  done
  _uberdev_status_consider_root 'env:UBERDEV_TMPDIR' "${UBERDEV_TMPDIR:-}" private
  _uberdev_status_consider_root 'dispatch-hardened' "$platform_tmp/uberdev-$uid" private
  _uberdev_status_consider_root 'goal-fallback:TMPDIR' "$platform_tmp" shared
  _uberdev_status_consider_root 'goal-fallback:/tmp' '/tmp' shared
}

# Gate every artefact read out of a discovered root. Under a `shared` root the
# containing directory proves nothing, so the file itself must be a
# non-symlink regular file owned by the effective uid; under a `private` root
# the 0700 owner-checked directory already established that boundary.
_uberdev_status_readable_file() {
  local role="$1" target="$2"
  [ -L "$target" ] && return 1
  [ -f "$target" ] || return 1
  [ -r "$target" ] || return 1
  [ "$role" = shared ] || return 0
  [ -O "$target" ] || return 1
  return 0
}

_uberdev_status_readable_dir() {
  local role="$1" target="$2"
  [ -L "$target" ] && return 1
  [ -d "$target" ] || return 1
  [ -r "$target" ] && [ -x "$target" ] || return 1
  [ "$role" = shared ] || return 0
  [ -O "$target" ] || return 1
  return 0
}

_uberdev_status_render_roots() {
  local line
  _uberdev_status_rule '0. runtime-root discovery'
  _uberdev_status_note 'The stores below disagree on their root (see the header comment in'
  _uberdev_status_note 'lib/status.sh). Every candidate is probed; each section then names'
  _uberdev_status_note 'the root it ACTUALLY read.'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _uberdev_status_row "$line"
  done <<EOF
$_UBERDEV_STATUS_ROOT_REPORT
EOF
  if [ -z "$_UBERDEV_STATUS_ROOTS" ]; then
    _uberdev_status_note 'readable roots: NONE — every candidate was absent, foreign-owned, or unreadable.'
    _uberdev_status_note 'probe by hand: ls -ld "${TMPDIR:-/tmp}/uberdev-$(id -u)" /tmp'
    return 0
  fi
  _uberdev_status_note 'readable roots (deduped, in probe order; `shared` roots enforce per-file ownership):'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _uberdev_status_row "$line"
  done <<EOF
$_UBERDEV_STATUS_ROOTS
EOF
}

# --- Repository anchors ----------------------------------------------------

# `.uberdev/` lives at the working-tree root; the merge lock lives inside the
# git directory. In a linked worktree those are DIFFERENT places (`.git` is a
# file there and --git-common-dir points at the primary repo), so both are
# probed and both are printed.
_uberdev_status_discover_repo() {
  local candidate
  _UBERDEV_STATUS_REPO_ROOT=''
  _UBERDEV_STATUS_GIT_DIR=''
  _UBERDEV_STATUS_GIT_COMMON_DIR=''
  candidate="$(git rev-parse --show-toplevel 2>/dev/null)" || candidate=''
  if [ -n "$candidate" ]; then
    _UBERDEV_STATUS_REPO_ROOT="$(_uberdev_status_resolve_dir "$candidate")" \
      || _UBERDEV_STATUS_REPO_ROOT=''
  fi
  candidate="$(git rev-parse --git-dir 2>/dev/null)" || candidate=''
  if [ -n "$candidate" ]; then
    _UBERDEV_STATUS_GIT_DIR="$(_uberdev_status_resolve_dir "$candidate")" \
      || _UBERDEV_STATUS_GIT_DIR=''
  fi
  candidate="$(git rev-parse --git-common-dir 2>/dev/null)" || candidate=''
  if [ -n "$candidate" ]; then
    _UBERDEV_STATUS_GIT_COMMON_DIR="$(_uberdev_status_resolve_dir "$candidate")" \
      || _UBERDEV_STATUS_GIT_COMMON_DIR=''
  fi
}

# --- Section 1: /solve + /turbo claims -------------------------------------

_uberdev_status_section_claims() {
  local rc json entry role root file issue backend announced found=0
  _uberdev_status_rule "1. /solve + /turbo claims (label ${_UBERDEV_STATUS_ACTIVE_LABEL})"

  if ! command -v gh >/dev/null 2>&1; then
    _uberdev_status_note 'gh: not on PATH — the label census is unavailable (local artefacts still shown).'
  elif ! _uberdev_status_have_python; then
    _uberdev_status_note 'gh: skipped — no Python 3 interpreter to decode the response.'
  else
    json="$(gh issue list --label "$_UBERDEV_STATUS_ACTIVE_LABEL" --state open \
      --limit "$_UBERDEV_STATUS_GH_QUERY_LIMIT" --json number,title,assignees 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
      _uberdev_status_note "gh: query failed (rc=$rc) — unauthenticated, offline, or no GitHub remote."
      _uberdev_status_note 'check with: gh auth status'
    else
      _uberdev_status_note 'gh: read from the GitHub API (open issues carrying the claim label)'
      printf '%s' "$json" | _uberdev_status_py '
limit = int(ARGS[0])
label = ARGS[1]
try:
    issues = json.load(sys.stdin)
except ValueError:
    issues = []
if not isinstance(issues, list):
    issues = []
if not issues:
    print("    (no open issue holds the claim label)")
for issue in issues[:limit]:
    if not isinstance(issue, dict):
        continue
    number = issue.get("number")
    if not isinstance(number, int):
        continue
    names = []
    if isinstance(issue.get("assignees"), list):
        for entry in issue["assignees"]:
            if isinstance(entry, dict) and entry.get("login"):
                names.append(clean(entry["login"], 40))
    print("    #%d  %s  [%s]" % (
        number, clean(issue.get("title")), ", ".join(names) if names else "unassigned"))
    print("      re-enter: /uberdev:solve %d" % number)
    print("      release:  gh issue edit %d --remove-label %s --remove-assignee @me" % (
        number, label))
if len(issues) > limit:
    print("    ... %d more (bounded at %d)" % (len(issues) - limit, limit))
' "$_UBERDEV_STATUS_MAX_ROWS" "$_UBERDEV_STATUS_ACTIVE_LABEL"
    fi
  fi

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    role="${entry%% *}"; root="${entry#* }"
    announced=0
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      _uberdev_status_readable_file "$role" "$file" || continue
      issue="${file##*-}"; issue="${issue%.json}"
      _uberdev_status_is_int "$issue" || continue
      case "${file##*/}" in
        solve-codex-status-*) backend='codex' ;;
        *) backend='background' ;;
      esac
      if [ "$announced" -eq 0 ]; then
        announced=1
        found=1
        _uberdev_status_note "dispatch status read from: $root"
      fi
      _uberdev_status_render_solve_status "$file" "$issue" "$backend"
    done <<EOF
$(_uberdev_status_list "$root" f 'solve-*-status-*.json')
EOF
  done <<EOF
$_UBERDEV_STATUS_ROOTS
EOF
  [ "$found" -eq 1 ] || _uberdev_status_note 'per-issue dispatch status: none found under any readable root.'
}

_uberdev_status_render_solve_status() {
  local file="$1" issue="$2" backend="$3" age
  age="$(_uberdev_status_age_secs "$file")" || age='?'
  if ! _uberdev_status_have_python; then
    _uberdev_status_row "#$issue  backend=$backend  (age ${age}s; no Python 3 to decode $file)"
    return 0
  fi
  _uberdev_status_py '
issue, backend, age = ARGS[0], ARGS[1], ARGS[2]
try:
    record = json.load(sys.stdin)
except ValueError:
    record = None
if not isinstance(record, dict):
    print("    #%s  %s  (status file is not decodable JSON, age %ss)" % (issue, backend, age))
else:
    print("    #%s  backend=%s  state=%s  exit_code=%s  pid=%s  (age %ss)" % (
        issue, clean(record.get("backend") or backend, 20), clean(record.get("state"), 20),
        clean(record.get("exit_code"), 12), clean(record.get("pid"), 12), age))
    log = clean(record.get("log"), 400)
    result = clean(record.get("result"), 400)
    if log:
        print("      re-enter: tail -f %s" % log)
    if result:
        print("      result:   %s" % result)
' "$issue" "$backend" "$age" < "$file"
}

# --- Section 2: /goal run state --------------------------------------------

_uberdev_status_section_goal() {
  local entry role root pointer goal_id found=0
  _uberdev_status_rule '2. /goal run state'
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    role="${entry%% *}"; root="${entry#* }"
    pointer="$root/$_UBERDEV_STATUS_GOAL_POINTER_BASENAME"
    _uberdev_status_readable_file "$role" "$pointer" || continue
    found=1
    goal_id="$(head -n 1 "$pointer" 2>/dev/null | tr -d '\r\n')"
    if ! _uberdev_status_valid_goal_id "$goal_id"; then
      _uberdev_status_note "read from: $root"
      _uberdev_status_row 'bootstrap pointer holds an unusable GOAL_ID — refusing to build a path from it'
      _uberdev_status_note "inspect by hand: cat $pointer"
      continue
    fi
    _uberdev_status_note "read from: $root  (pointer $_UBERDEV_STATUS_GOAL_POINTER_BASENAME -> $goal_id)"
    _uberdev_status_render_goal "$role" "$root" "$goal_id"
  done <<EOF
$_UBERDEV_STATUS_ROOTS
EOF
  if [ "$found" -eq 0 ]; then
    _uberdev_status_note "no $_UBERDEV_STATUS_GOAL_POINTER_BASENAME under any readable root — no /goal run to resume."
  fi
}

_uberdev_status_render_goal() {
  local role="$1" root="$2" goal_id="$3" sidecar="$root/goal-$goal_id-runstate"
  local key value cycle='?' max_cycles='?' backend='?' max_parallel='?' halt=''
  local queue='' active='' candidates='' candidate_cycle='' line

  if _uberdev_status_readable_file "$role" "$sidecar"; then
    # The sidecar is DATA, never a script: read + per-field validate, never
    # source (goal-state.sh:uberdev_goal_read_run_state holds the same line).
    while IFS='=' read -r key value; do
      case "$key" in
        cycle)        _uberdev_status_is_int "$value" && cycle="$value" ;;
        MAX_CYCLES)   _uberdev_status_is_int "$value" && max_cycles="$value" ;;
        MAX_PARALLEL) _uberdev_status_is_int "$value" && max_parallel="$value" ;;
        UBERDEV_RESOLVED_BACKEND)
          case "$value" in ''|*[!A-Za-z0-9_-]*) ;; *) backend="$value" ;; esac ;;
        CIRCUIT_BREAKER_HALT)
          case "$value" in ''|*[!A-Za-z0-9_-]*) ;; *) halt="$value" ;; esac ;;
      esac
    done < "$sidecar"
    _uberdev_status_row "cycle $cycle/$max_cycles  backend=$backend  max_parallel=$max_parallel"
    [ -z "$halt" ] || _uberdev_status_row "CIRCUIT BREAKER: $halt"
  else
    _uberdev_status_row "runstate sidecar missing or not ours ($sidecar) — the pointer is stale."
  fi

  queue="$(_uberdev_status_int_list "$role" "${sidecar}.queue")"
  active="$(_uberdev_status_int_list "$role" "${sidecar}.active")"
  if _uberdev_status_readable_file "$role" "${sidecar}.candidates"; then
    # First line is the `cycle=<N>` tag written by uberdev_goal_write_run_state.
    # A tag that does not match the scalar cycle means a Phase-3 fence crashed
    # between the gh query and its flush; /goal ignores that file, so /status
    # must not present it as this cycle's candidate set either.
    candidate_cycle="$(head -n 1 "${sidecar}.candidates" 2>/dev/null)"
    candidate_cycle="${candidate_cycle#cycle=}"
    candidates="$(tail -n +2 "${sidecar}.candidates" 2>/dev/null \
      | while IFS= read -r line; do _uberdev_status_is_int "$line" && printf '%s ' "$line"; done)"
    candidates="${candidates% }"
  fi
  _uberdev_status_row "queue:      ${queue:-(empty)}"
  _uberdev_status_row "active:     ${active:-(empty)}"
  if [ -n "$candidate_cycle" ] && [ "$candidate_cycle" != "$cycle" ]; then
    _uberdev_status_row "candidates: (tagged cycle $candidate_cycle != cycle $cycle — stale, ignored by /goal)"
  else
    _uberdev_status_row "candidates: ${candidates:-(empty)}"
  fi

  _uberdev_status_render_goal_tsv "$role" "$root/goal-$goal_id-pr-states.tsv" 'pr-states' '#'
  _uberdev_status_render_goal_tsv "$role" "$root/goal-$goal_id-issue-states.tsv" 'issue-states' '#'
  if [ -n "$queue" ]; then
    _uberdev_status_hint "/uberdev:goal $queue"
  else
    _uberdev_status_hint "/uberdev:goal <issue> [<issue>...]   (state files: $root/goal-$goal_id-*)"
  fi
}

# One int per line -> one bounded, space-separated line.
_uberdev_status_int_list() {
  local role="$1" file="$2" line count=0 out=''
  _uberdev_status_readable_file "$role" "$file" || { printf ''; return 0; }
  while IFS= read -r line; do
    _uberdev_status_is_int "$line" || continue
    count=$(( count + 1 ))
    if [ "$count" -gt "$_UBERDEV_STATUS_MAX_ROWS" ]; then out="$out..."; break; fi
    out="$out$line "
  done < "$file"
  printf '%s' "${out% }"
}

# pr-states.tsv and issue-states.tsv share the `key<TAB>state<TAB>ts` column
# contract documented in goal-state.sh; the latest row per key wins.
_uberdev_status_render_goal_tsv() {
  local role="$1" file="$2" label="$3" sigil="$4" now
  _uberdev_status_readable_file "$role" "$file" \
    || { _uberdev_status_row "$label: (absent or not ours)"; return 0; }
  now="$(_uberdev_status_now_secs)"
  _uberdev_status_row "$label:"
  # The awk field refs are safe here: this file is SOURCED, never Skill-rendered,
  # so the $ARGUMENTS positional substitution that corrupts awk bodies inside
  # SKILL.md (issue #222) cannot reach it.
  awk -F'\t' -v now="$now" -v sigil="$sigil" -v cap="$_UBERDEV_STATUS_MAX_ROWS" '
    $1 ~ /^[0-9]+$/ {
      state[$1] = $2
      ts[$1] = ($3 ~ /^[0-9]+$/) ? $3 : 0
      if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
    }
    END {
      if (n == 0) { print "      (no transitions recorded)"; exit }
      for (i = 1; i <= n && i <= cap; i++) {
        key = order[i]
        age = (ts[key] > 0 && now >= ts[key]) ? (now - ts[key]) "s" : "?"
        label = state[key]
        gsub(/[^A-Za-z0-9._:-]/, "?", label)
        printf("      %s%s %s (age %s)\n", sigil, key, label, age)
      }
      if (n > cap) printf("      ... %d more (bounded at %d)\n", n - cap, cap)
    }
  ' "$file"
}

# --- Section 3: /review-pr reservations ------------------------------------

_uberdev_status_section_review() {
  local runs_root grace reap dir marker age found=0
  grace="$(_uberdev_status_review_grace_secs)"
  reap="$(_uberdev_status_review_reap_secs)"
  _uberdev_status_rule '3. /review-pr reservations'
  if [ -z "${_UBERDEV_STATUS_REPO_ROOT:-}" ]; then
    _uberdev_status_note 'not inside a git working tree — the reservation store is repo-relative.'
    return 0
  fi
  runs_root="$_UBERDEV_STATUS_REPO_ROOT/$_UBERDEV_STATUS_REVIEW_RUNS_RELPATH"
  _uberdev_status_note "read from: $runs_root  (grace ${grace}s, reap ${reap}s)"
  if [ ! -d "$runs_root" ]; then
    _uberdev_status_note 'runs root absent — no /review-pr has reserved a run in this working tree.'
    return 0
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    marker="$dir/locked"
    # The runs root lives inside the working tree, so the `private` rule
    # applies: the checkout itself is the ownership boundary.
    _uberdev_status_readable_file private "$marker" || continue
    _uberdev_status_readable_file private "$dir/pr-context.json" || continue
    found=1
    age="$(_uberdev_status_age_secs "$marker")" || age=''
    _uberdev_status_render_review_reservation "$dir" "$age" "$grace" "$reap"
  done <<EOF
$(_uberdev_status_list "$runs_root" d '*')
EOF
  [ "$found" -eq 1 ] || _uberdev_status_note 'no run directory holds both markers — nothing in flight.'
}

_uberdev_status_render_review_reservation() {
  local dir="$1" age="$2" grace="$3" reap="$4" run_id pr='' verdict
  run_id="${dir##*/}"
  if _uberdev_status_have_python; then
    pr="$(_uberdev_status_py '
try:
    context = json.load(sys.stdin)
except ValueError:
    context = None
value = context.get("pr") if isinstance(context, dict) else None
print(value if isinstance(value, int) else "", end="")
' < "$dir/pr-context.json" 2>/dev/null)" || pr=''
  fi
  _uberdev_status_is_int "$pr" || pr=''
  if [ -z "$age" ]; then
    verdict='age-unknown'
  elif [ "$age" -ge "$reap" ]; then
    verdict='ABANDONED'
  elif [ "$age" -ge "$grace" ]; then
    verdict='STALE'
  else
    verdict='FRESH'
  fi
  _uberdev_status_row "$run_id  pr=${pr:-<unparsed>}  age=${age:-?}s  $verdict"
  if [ "$verdict" = FRESH ]; then
    if [ -n "$pr" ]; then
      _uberdev_status_hint "in flight for PR #$pr — wait for it; watch with: ls -l $dir"
    else
      _uberdev_status_hint "in flight — watch with: ls -l $dir"
    fi
    return 0
  fi
  # Never delete here. /review-pr owns a bounded reaper that verifies ownership
  # and link-safety before removing a marker; a blind `rm` from a status reader
  # would race a live producer.
  if [ -n "$pr" ]; then
    _uberdev_status_hint "/uberdev:review-pr $pr   (its reaper clears this reservation)"
  else
    _uberdev_status_hint '/uberdev:review-pr <pr>   (its reaper clears this reservation)'
  fi
}

# --- Section 4: /merge lock + audit trail ----------------------------------

_uberdev_status_section_merge() {
  local stale probed='' seen='' candidate dir found=0
  stale="$(_uberdev_status_merge_stale_secs)"
  _uberdev_status_rule '4. /merge lock + audit trail'
  for candidate in "${_UBERDEV_STATUS_GIT_DIR:-}" "${_UBERDEV_STATUS_GIT_COMMON_DIR:-}"; do
    [ -n "$candidate" ] || continue
    _uberdev_status_list_has "$seen" "$candidate" && continue
    seen="$seen$candidate
"
    dir="$candidate/$_UBERDEV_STATUS_MERGE_LOCK_BASENAME"
    probed="$probed$dir "
    [ -d "$dir" ] || continue
    found=1
    _uberdev_status_note "read from: $dir  (stale threshold ${stale}s)"
    _uberdev_status_render_merge_lock "$dir" "$stale"
  done
  if [ -z "$probed" ]; then
    _uberdev_status_note 'not inside a git repository — no merge lock to probe.'
  elif [ "$found" -eq 0 ]; then
    _uberdev_status_note "no lock held; probed: ${probed% }"
  fi
  _uberdev_status_render_audit_tail
}

_uberdev_status_render_merge_lock() {
  local dir="$1" stale="$2" heartbeat="$dir/heartbeat" record="$dir/record.json"
  local hb_age='' verdict parsed='' run_id='' started=''
  if _uberdev_status_readable_file private "$heartbeat"; then
    hb_age="$(_uberdev_status_age_secs "$heartbeat")" || hb_age=''
  fi
  # merge-pipeline classifies on HEARTBEAT age ONLY: started_at age would
  # mis-classify a live long run as stale, so /status must not use it either.
  if [ -z "$hb_age" ]; then
    verdict='STALE (heartbeat missing or unreadable — crashed acquisition)'
  elif [ "$hb_age" -ge "$stale" ]; then
    verdict="STALE (heartbeat ${hb_age}s >= ${stale}s)"
  else
    verdict="HELD-LIVE (heartbeat ${hb_age}s ago)"
  fi
  if _uberdev_status_readable_file private "$record" && _uberdev_status_have_python; then
    parsed="$(_uberdev_status_py '
try:
    record = json.load(sys.stdin)
except ValueError:
    record = None
if isinstance(record, dict):
    print("%s %s" % (
        clean(record.get("run_id"), 64) or "<none>",
        clean(record.get("started_at"), 40) or "<none>"))
else:
    print("<none> <none>")
' < "$record" 2>/dev/null)" || parsed=''
    run_id="${parsed%% *}"
    started="${parsed#* }"
  fi
  _uberdev_status_row "run_id=${run_id:-<unreadable>}  started=${started:-<unreadable>}  $verdict"
  case "$verdict" in
    HELD-LIVE*)
      _uberdev_status_hint 'another /merge run owns this lock — wait; do NOT remove the directory.' ;;
    *)
      _uberdev_status_hint '/uberdev:merge   (its Step 1.1 reclaims a stale lock; never rm it by hand)' ;;
  esac
}

_uberdev_status_render_audit_tail() {
  local audit line
  [ -n "${_UBERDEV_STATUS_REPO_ROOT:-}" ] || return 0
  audit="$_UBERDEV_STATUS_REPO_ROOT/$_UBERDEV_STATUS_AUDIT_RELPATH"
  if ! _uberdev_status_readable_file private "$audit"; then
    _uberdev_status_note "audit trail: $audit (absent)"
    return 0
  fi
  _uberdev_status_note "audit trail: $audit (last $_UBERDEV_STATUS_AUDIT_TAIL_ROWS rows)"
  if ! _uberdev_status_have_python; then
    tail -n "$_UBERDEV_STATUS_AUDIT_TAIL_ROWS" "$audit" 2>/dev/null \
      | while IFS= read -r line; do _uberdev_status_row "$line"; done
    return 0
  fi
  tail -n "$_UBERDEV_STATUS_AUDIT_TAIL_ROWS" "$audit" 2>/dev/null | _uberdev_status_py '
for record in rows(sys.stdin):
    data = record.get("data")
    pr = data.get("pr") if isinstance(data, dict) else None
    print("    %s  %s  %s%s" % (
        clean(record.get("ts"), 30) or "<no ts>",
        clean(record.get("event"), 40) or "<no event>",
        clean(record.get("run_id"), 40) or "<no run_id>",
        ("  pr=%s" % pr) if isinstance(pr, int) else ""))
'
}

# --- Section 5: per-run agent lifecycle (the liveness oracle) --------------

_uberdev_status_section_lifecycle() {
  local entry role root state_dir manifest found=0
  _uberdev_status_rule '5. agent lifecycle (liveness)'
  _uberdev_status_note 'Liveness comes from the lifecycle manifest, NOT from `claude agents`: the'
  _uberdev_status_note 'manifest is backend-independent, so this stays correct as the detached'
  _uberdev_status_note 'transports are retired (RFC 0015).'
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    role="${entry%% *}"; root="${entry#* }"
    while IFS= read -r state_dir; do
      [ -n "$state_dir" ] || continue
      _uberdev_status_readable_dir "$role" "$state_dir" || continue
      manifest="$state_dir/$_UBERDEV_STATUS_LIFECYCLE_BASENAME"
      _uberdev_status_readable_file "$role" "$manifest" || continue
      found=1
      _uberdev_status_note "read from: $manifest"
      _uberdev_status_render_lifecycle "$manifest"
    done <<EOF
$(_uberdev_status_list "$root" d "$_UBERDEV_STATUS_AGENT_STATE_PREFIX*")
EOF
  done <<EOF
$_UBERDEV_STATUS_ROOTS
EOF
  [ "$found" -eq 1 ] \
    || _uberdev_status_note 'no lifecycle manifest under any readable root — no dispatched agent to account for.'
}

_uberdev_status_render_lifecycle() {
  if ! _uberdev_status_have_python; then
    _uberdev_status_row '(no Python 3 interpreter — lifecycle events not decoded)'
    return 0
  fi
  tail -n "$_UBERDEV_STATUS_JSONL_TAIL_LINES" "$1" 2>/dev/null | _uberdev_status_py '
TERMINAL = set(ARGS[0].split())
cap = int(ARGS[1])

order, started, terminal, seen = [], {}, {}, set()
for record in rows(sys.stdin):
    run_id = record.get("run_id")
    if not isinstance(run_id, str) or not run_id:
        continue
    if run_id not in seen:
        seen.add(run_id)
        order.append(run_id)
    event = record.get("event")
    if event == "agent_started":
        started[run_id] = record
    elif event in TERMINAL:
        terminal[run_id] = record

if not order:
    print("    (manifest holds no decodable lifecycle event)")

live = [r for r in order if r in started and r not in terminal]
done = [r for r in order if r not in live]
for run_id in (live + done)[:cap]:
    start = started.get(run_id, {})
    end = terminal.get(run_id)
    source = end or start or {}
    if end is not None:
        state = "terminal=" + (clean(end.get("terminal_status") or end.get("event"), 24) or "?")
        error = clean(end.get("error_class"), 40)
        if error:
            state += " (" + error + ")"
    elif run_id in started:
        state = "LIVE"
    else:
        state = "pending (routed, never started)"
    issue = source.get("issue_or_pr")
    print("    %s  %s  backend=%s  issue=%s  %s" % (
        clean(run_id, 60), state, clean(source.get("backend"), 20),
        issue if isinstance(issue, int) else "?", clean(source.get("role"), 30)))
    if run_id in live:
        owner = start.get("owner_pid")
        if isinstance(owner, int):
            print("      owner_pid=%d  timeout_s=%s" % (owner, clean(start.get("timeout_s"), 12)))
        status_path = clean(start.get("status_path"), 400)
        if status_path:
            print("      re-enter: cat %s" % status_path)
if len(order) > cap:
    print("    ... %d more (bounded at %d)" % (len(order) - cap, cap))
print("    summary: %d live, %d finished-or-unstarted" % (len(live), len(done)))
' "$_UBERDEV_STATUS_TERMINAL_EVENTS" "$_UBERDEV_STATUS_MAX_ROWS"
}

# --- Public entry point ----------------------------------------------------

# uberdev_status_render
#   Print the whole read-only census to stdout. Always returns 0: a status
#   reader that aborts on the first unreadable store is useless precisely when
#   it is needed (post-crash). Every degraded probe is reported inline instead.
uberdev_status_render() {
  printf 'uberdev status — read-only run-state census (issue #310)\n'
  printf 'generated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
  _uberdev_status_discover_repo
  printf 'repo_root:    %s\n' "${_UBERDEV_STATUS_REPO_ROOT:-<not a git working tree>}"
  printf 'git_dir:      %s\n' "${_UBERDEV_STATUS_GIT_DIR:-<none>}"
  printf 'git_common:   %s\n' "${_UBERDEV_STATUS_GIT_COMMON_DIR:-<none>}"
  if ! _uberdev_status_have_python; then
    printf 'python3:      NOT FOUND — JSON-backed rows degrade to raw or omitted values\n'
  fi
  _uberdev_status_discover_roots
  _uberdev_status_render_roots
  _uberdev_status_section_claims
  _uberdev_status_section_goal
  _uberdev_status_section_review
  _uberdev_status_section_merge
  _uberdev_status_section_lifecycle
  printf '\nNothing above was created, modified, or deleted. /uberdev:status never writes.\n'
  return 0
}
