#!/usr/bin/env bash
# lib/solve-launcher.sh — shared /solve + /turbo launcher (RFC 0012 §3.4 / §7.5; issue #304).
#
# Invocation contract (commands/solve.md + commands/turbo.md pass LITERALS;
# embedders that set only PLUGIN_ROOT):
#   bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=0 -- <ARGUMENTS>   # /solve
#   bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=1 --turbo -- <ARGUMENTS>   # /turbo
#
# Runs Phase A (validate-all-first) + Step 4.5 (claim protocol) + Phase B
# (per-issue dispatch) as ONE process, ONE Bash tool call. Bash tool calls
# share no shell state, so the historical multi-fence pipeline silently lost
# functions, arrays, and even a split `for` loop across fence boundaries —
# this file is the root fix (#304: bare-$N renderer substitution, the
# cross-fence :706/:808 loop, `declare -A` on macOS bash 3.2).
#
# Why a lib file: the Skill renderer substitutes positional `$ARGUMENTS` args
# into SKILL.md / command-.md BODIES (bare `$1`/`$2`/`$3` corrupt under
# `/solve 5 6 7`); lib/*.sh is never rendered, so positional parameters and
# plain awk field refs are safe here.
#
# Runtime contract (callers): pass a Bash-tool `timeout` of up to 600000 ms.
# For batches above ~10 issues prefer `run_in_background: true` + Monitor —
# validation is 1 gh round-trip per issue, claim writes add ~2-3 more, and
# serial dispatch costs 2-8 s per issue; the 120 s default timeout can expire
# mid-claim and strand a half-claimed batch (the rollback path below runs
# before any abort, but only while the process is alive).
#
# Shell floor: macOS /bin/bash 3.2 — no `declare -A` (associative arrays),
# no `wait -n`, no `${var^^}`. Tier/title metadata uses parallel indexed
# arrays (TIERS[i]/TITLES[i] aligned with ISSUE_NUMS[i]).
#
# Env ownership: this launcher OWNS the AUTO_MODE / UBERDEV_TURBO /
# SKIP_PERMISSIONS lifecycle (#97/#241). The shell profile re-injects
# UBERDEV_TURBO / SKIP_PERMISSIONS into every fresh fence, so an `unset` in a
# prior Bash call protects nothing — hygiene must run in THIS process, after
# which lib/dispatch.sh and the spawned children inherit a clean set.
#
# Boundary (RFC 0012 §3.4, binding): everything BEFORE uberdev_dispatch_one
# lives here; the spawn line, backend resolver and dispatcher-side monitoring
# live in lib/dispatch.sh and DO NOT move. lib/dispatch.sh is the SSOT for
# MODEL / PERM_FLAG / EFFORT_FLAG / SOLVE_TIMEOUT / TIMEOUT_BIN resolution.

# ---------------------------------------------------------------------------
# Step 0. Launcher options (long options only; everything after `--` is the
# raw user argument string the command file forwarded).
# ---------------------------------------------------------------------------
AUTO_MODE=0
TURBO_OPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auto-mode=*) AUTO_MODE="${1#--auto-mode=}" ;;
    --turbo)       TURBO_OPT=1 ;;
    --)            shift; break ;;
    *)
      echo "error: solve-launcher: unknown launcher option '$1' (only --auto-mode=0|1, --turbo, -- are accepted before the user arguments)" >&2
      exit 64
      ;;
  esac
  shift
done
case "$AUTO_MODE" in
  0|1) ;;
  *) echo "error: solve-launcher: --auto-mode must be 0 or 1 (got '$AUTO_MODE')" >&2; exit 64 ;;
esac
# The residual argv is the user-facing argument string. Variable name kept as
# ARGUMENTS so the parser blocks below read identically to the historical
# fence form (and so runtime fixtures can drive them via `export ARGUMENTS`).
ARGUMENTS="$*"
UBERDEV_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
if [ -z "${UBERDEV_PLUGIN_ROOT:-}" ]; then
  _UBERDEV_LAUNCHER_SOURCE="${BASH_SOURCE[0]:-$0}"
  if [ -f "$_UBERDEV_LAUNCHER_SOURCE" ]; then
    UBERDEV_PLUGIN_ROOT="$(cd "$(dirname "$_UBERDEV_LAUNCHER_SOURCE")/.." && pwd)"
  fi
fi

# Parse the public CLI once through the bounded deterministic parser. This is
# the fail-closed gate for duplicates, conflicts, issue count, aliases, and
# routing field enums. It runs before gh and therefore before every claim or
# stale-label mutation.
_UBERDEV_SOLVE_TRIAGE="$UBERDEV_PLUGIN_ROOT/lib/solve_triage.py"
if [ ! -r "$_UBERDEV_SOLVE_TRIAGE" ]; then
  echo "error: solve routing validator missing: $_UBERDEV_SOLVE_TRIAGE" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi
if ! SOLVE_CLI_JSON="$(python3 -I "$_UBERDEV_SOLVE_TRIAGE" parse-cli "$@" 2>&1)"; then
  echo "error: $SOLVE_CLI_JSON" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi
_uberdev_cli_get() {
  python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else ("1" if v is True else "0" if v is False else v),end="")' "$SOLVE_CLI_JSON" "$1"
}
UBERDEV_DISPATCH_ROUTING_MODE="$(_uberdev_cli_get routing_mode)"
UBERDEV_DISPATCH_ROUTE="$(_uberdev_cli_get route)"
UBERDEV_DISPATCH_MODEL="$(_uberdev_cli_get model)"
UBERDEV_DISPATCH_REASONING_EFFORT="$(_uberdev_cli_get effort)"
UBERDEV_DISPATCH_SERVICE_TIER="$(_uberdev_cli_get service_tier)"
export UBERDEV_DISPATCH_ROUTING_MODE UBERDEV_DISPATCH_ROUTE UBERDEV_DISPATCH_MODEL
export UBERDEV_DISPATCH_REASONING_EFFORT UBERDEV_DISPATCH_SERVICE_TIER

# Env ownership (#97/#241) — see header. AUTO_MODE gates turbo-vs-interactive
# behaviour in Steps 4/5a; UBERDEV_TURBO is the chain-wide unattended-mode
# signal (inherits into claude --bg children via lib/dispatch.sh BG_TURBO_ENV);
# SKIP_PERMISSIONS is /goal's autonomous-loop opt-in and /goal dispatches its
# workers directly via uberdev_dispatch_one (never through this launcher), so
# both /solve and bare /turbo neutralise a stale profile export here.
export AUTO_MODE
if [ "$TURBO_OPT" = "1" ]; then
  export UBERDEV_TURBO=1
else
  unset UBERDEV_TURBO
fi
unset SKIP_PERMISSIONS

# GH_PARALLEL_CAP: chunk size for the parallel gh stages below (validation
# reads, claim writes). Bounded so a 50-issue batch cannot burst-fire 50
# concurrent GitHub mutations into the secondary rate limiter; 8 keeps a
# 6-issue batch fully parallel while staying well under abuse-detection
# thresholds. Dispatch itself stays SERIAL by design (RFC 0012 §3.4 —
# parallel dispatch is out of scope until the per-issue ~/.wezterm.lua
# rewrite is hoisted out of lib/dispatch.sh).
GH_PARALLEL_CAP=8

# ---------------------------------------------------------------------------
# Phase A — helpers + argument parsing (Step 1)
# ---------------------------------------------------------------------------

# Hard-require Claude Code >= min. Two reasons stacked: (1) `claude --bg`
# needs 2.1.139+; (2) `--permission-mode bypassPermissions` needs 2.1.152+
# (#246) — older versions exit-2 unknown-flag with the root cause buried in
# BG_STDOUT_LOG. Fail loudly with an actionable install pointer.
_uberdev_require_claude_version() {
  local min="$1"
  local cur
  cur="$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$cur" ]]; then
    echo "error: \`claude --version\` returned no output; cannot verify version >= $min" >&2
    return 1
  fi
  if [[ "$(printf '%s\n%s\n' "$min" "$cur" | sort -V | head -1)" != "$min" ]]; then
    echo "error: /solve and /turbo require Claude Code >= $min (found: $cur)" >&2
    echo "       install with: npm i -g @anthropic-ai/claude-code@latest" >&2
    return 1
  fi
}

_uberdev_audit_emit() {
  # No-op if SOLVE_AUDIT_LOG is unset; otherwise append a JSON line. Single
  # printf line + O_APPEND keeps concurrent emits from the parallel claim
  # workers below line-atomic in practice.
  [[ -n "${SOLVE_AUDIT_LOG:-}" ]] || return 0
  local event="$1" data="${2-}"
  [[ -z "$data" ]] && data='{}'
  printf '{"ts":"%s","event":"%s","data":%s}\n' \
    "$(date -u +%FT%TZ)" "$event" "$data" >> "$SOLVE_AUDIT_LOG"
}

# Tokenize $ARGUMENTS to numeric issue tokens, deduped preserving first-seen
# order (a same-issue duplicate would collide on the shared worktree path
# `.claude/worktrees/solve-issue-N/`). Array assignment `arr=($(...))`
# word-splits the substitution output on $IFS; this file always runs under
# bash (see shebang), so the historical zsh SH_WORD_SPLIT word-split footgun
# that forced the fence-era pipeline shape no longer applies — the pipeline
# form is kept because it also filters (anchored `^[0-9]+$` rejects flag
# tokens like `--terminal=foo123`) and dedupes in one pass.
ISSUE_NUMS=($(python3 -I -c 'import json,sys; print(" ".join(map(str,json.loads(sys.argv[1])["issues"])))' "$SOLVE_CLI_JSON"))

OVERRIDE=$(echo "$ARGUMENTS" | grep -oE '\-\-(trivial|small|full)' | head -1 | sed 's/--//')
# --- Phase A: --terminal= deprecation shim (v0.22.0) ---
# Parsed without effect; emits TERMINAL_FLAG_DEPRECATED_NOTE once per run and
# records a `deprecated_flag_used` audit event. Keep this assignment at
# column 0 — tests/solve-effort-flag.test.sh anchors `^TERMINAL_FLAG_DEPRECATED_NOTE=`.
TERMINAL_FLAG_DEPRECATED_NOTE='warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.'
TERMINAL_FLAG_USED="$(echo "$ARGUMENTS" | grep -oE '\-\-terminal=[a-z]+' | head -1 || true)"
if [[ -n "$TERMINAL_FLAG_USED" ]]; then
  echo "$TERMINAL_FLAG_DEPRECATED_NOTE" >&2
  _uberdev_audit_emit deprecated_flag_used \
    "{\"flag\":$(printf %s "$TERMINAL_FLAG_USED" | jq -Rs .)}" || true
fi
# Also swallow $SOLVE_TERMINAL env var with the same deprecation note.
if [[ -n "${SOLVE_TERMINAL:-}" ]]; then
  echo "$TERMINAL_FLAG_DEPRECATED_NOTE" >&2
  _uberdev_audit_emit deprecated_flag_used \
    "{\"env\":\"SOLVE_TERMINAL\",\"value\":$(printf %s "$SOLVE_TERMINAL" | jq -Rs .)}" || true
fi
AUTO_FLAG=$(echo "$ARGUMENTS" | grep -oE '\-\-auto' | head -1)
# --- Phase A: --force flag parser (v0.28.0 — claim override) ---
# `--force` / `-f` overrides the per-issue claim protocol (Step 4.5) for
# stale-claim recovery. Anchored token regex — `--force-foo` does NOT match.
# Batch-wide like every other override flag.
FORCE_FLAG="$(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^(--force|-f)$' | head -1)"
if [[ -n "$FORCE_FLAG" ]]; then
  FORCE_CLAIM=1
else
  FORCE_CLAIM=0
fi
# --- Phase A: claim-protocol shell constants (v0.28.0) ---
# Canonical values; the Constants table in solve-pipeline/SKILL.md documents
# them. Keep at column 0 — tests/solve-claim.test.sh anchors
# `^UBERDEV_ACTIVE_LABEL=` and `^CLAIM_COMMENT_MARKER=`.
UBERDEV_ACTIVE_LABEL='uberdev:active'
UBERDEV_ACTIVE_LABEL_COLOR='D93F0B'
UBERDEV_ACTIVE_LABEL_DESCRIPTION='Issue currently being worked on by a /solve or /turbo dispatcher. Auto-managed; do not edit.'
CLAIM_COMMENT_MARKER='<!-- uberdev-claim-comment v1 -->'
# --- Phase A: --effort=<level> parser (v0.22.1) ---
# `claude --bg` does NOT inherit the parent session's /effort setting, so
# every background spawn passes `--effort <level>` explicitly. Precedence:
#   CLI flag (--effort=<level>) > env var (UBERDEV_SOLVE_EFFORT) >
#   per-repo config (solve_effort:) > EFFORT_LEVEL_DEFAULT (`max`).
# Default `max`: /turbo is unattended — quality dominates wall-clock and cost.
UBERDEV_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
EFFORT_FLAG_VALUE="$(echo "$ARGUMENTS" | grep -oE '\-\-effort=[a-z]+' | head -1 | sed 's/--effort=//')"
EFFORT_SOURCE=default
if [[ -n "$EFFORT_FLAG_VALUE" ]]; then
  EFFORT_LEVEL="$EFFORT_FLAG_VALUE"
  EFFORT_SOURCE=cli
elif [[ -n "${UBERDEV_SOLVE_EFFORT:-}" ]]; then
  EFFORT_LEVEL="$UBERDEV_SOLVE_EFFORT"
  EFFORT_SOURCE=env
else
  # Probe the config file directly so explicit `solve_effort: max` attributes
  # to `source=config`; identity-with-default of the resolved value cannot
  # disambiguate config-set-to-default from absent-config.
  if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
  fi
  if command -v _uberdev_read_nested >/dev/null 2>&1 \
    && [ -n "$(_uberdev_read_nested solve_effort "$UBERDEV_CONFIG_FILE")" ]; then
    EFFORT_SOURCE=config
  else
    EFFORT_SOURCE=default
  fi
  if command -v uberdev_read_enum >/dev/null 2>&1; then
    EFFORT_LEVEL="$(uberdev_read_enum solve_effort UBERDEV_SOLVE_EFFORT 'low|medium|high|xhigh|max' 'max')"
  else
    EFFORT_LEVEL=max
  fi
fi
# Explicit validation when the value came from CLI or env (uberdev_read_enum
# validates only the value it reads itself) — reject loudly; a typoed
# `--effort=hgh` would otherwise surface as a far less actionable child error.
case "$EFFORT_LEVEL" in
  low|medium|high|xhigh|max|ultra) ;;
  *) echo "error: --effort='$EFFORT_LEVEL' not in {low,medium,high,xhigh,max,ultra}" >&2; exit 1 ;;
esac
# --- Phase A: --backend=<name> parser (v0.29.0 — RFC 0004) ---
# Precedence: --backend= CLI flag > UBERDEV_DISPATCH_BACKEND env >
# dispatch_backend: config > default `auto` (defers to the platform-aware
# fallback chain in lib/dispatch.sh uberdev_dispatch_preflight).
BACKEND_FLAG_VALUE="$(echo "$ARGUMENTS" | grep -oE '\-\-backend=[a-z-]+' | head -1 | sed 's/--backend=//')"
if [[ -n "$BACKEND_FLAG_VALUE" ]]; then
  DISPATCH_BACKEND="$BACKEND_FLAG_VALUE"
elif [[ -n "${UBERDEV_DISPATCH_BACKEND:-}" ]]; then
  DISPATCH_BACKEND="$UBERDEV_DISPATCH_BACKEND"
else
  if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
  fi
  if command -v uberdev_read_enum >/dev/null 2>&1; then
    # CONTRACT: dispatch-backend
    DISPATCH_BACKEND="$(uberdev_read_enum dispatch_backend UBERDEV_DISPATCH_BACKEND \
      'auto|workflow|wezterm|background' 'auto')"
    # /CONTRACT: dispatch-backend
  else
    DISPATCH_BACKEND=auto
  fi
fi
# CONTRACT: dispatch-backend !case-arm
case "$DISPATCH_BACKEND" in
  auto|workflow|wezterm|background) ;;
  # The operator-facing set is a THIRD copy in this file; #360 shipped
  # because updating only the files that carry markers looks like enough.
  # CONTRACT: dispatch-backend
  *) echo "error: --backend='$DISPATCH_BACKEND' not in {auto,workflow,wezterm,background}" >&2; exit 1 ;;
esac
export UBERDEV_DISPATCH_BACKEND_REQUESTED="$DISPATCH_BACKEND"
if [[ ${#ISSUE_NUMS[@]} -eq 0 ]]; then
  echo "Usage: /uberdev:solve|/uberdev:turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--force]"
  exit 1
fi
# --full is an alias for medium/large (keeps current behavior)
[[ "$OVERRIDE" == "full" ]] && OVERRIDE="medium"

# Unknown tokens are rejected by solve_triage.py; no warn-and-ignore path is
# permitted because a typo could silently change the requested route.

# AUTO_PERMISSIONS precedence (controls the bypass pair on the spawned agent —
# see lib/dispatch.sh:uberdev_dispatch_resolve_env): CLI flag > env var >
# per-repo config > default off. AUTO_PERMISSIONS is distinct from AUTO_MODE:
# AUTO_MODE (set from --auto-mode above) gates turbo-vs-interactive behaviour;
# AUTO_PERMISSIONS gates the permission tier. Naming kept disjoint to prevent
# collision (the historical AUTO_MODE/PERM_FLAG_VAL alias bug).
if [[ -n "$AUTO_FLAG" ]]; then
  AUTO_PERMISSIONS=1
elif [[ "${SOLVE_AUTO:-}" == "1" ]]; then
  AUTO_PERMISSIONS=1
else
  if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
  fi
  if command -v uberdev_read_enum >/dev/null 2>&1 \
     && [ "$(uberdev_read_enum solve_auto UBERDEV_SOLVE_AUTO_CONFIG 'true|false' 'false')" = "true" ]; then
    AUTO_PERMISSIONS=1
  else
    AUTO_PERMISSIONS=0
  fi
fi

# Permission-mode description for operator visibility. Flat-var if/else form
# (NOT a nested-substitution one-liner — the zsh-NOMATCH regression guard in
# tests/audit-fixups.test.sh C8). Both SKIP and AUTO branches resolve to the
# same bypass pair post-#241/#246; the branch split is kept so post-hoc grep
# can attribute the bypass tier (SKIP=/goal, AUTO=/turbo --auto, /solve --auto).
# NOTE: SKIP_PERMISSIONS was unset above for this launcher's modes; the SKIP
# branch is reachable only for direct lib callers that export it themselves.
if [[ "${SKIP_PERMISSIONS:-0}" == "1" ]]; then
  PERM_DESC="bypass (--dangerously-skip-permissions --permission-mode bypassPermissions; SKIP_PERMISSIONS tier — /goal autonomous loop)"
elif [[ "$AUTO_PERMISSIONS" == "1" ]]; then
  PERM_DESC="bypass (--dangerously-skip-permissions --permission-mode bypassPermissions; AUTO_PERMISSIONS tier — /turbo --auto / /solve --auto)"
else
  PERM_DESC="default (manual per-tool gating)"
fi
echo "Permission mode: $PERM_DESC"

# ---------------------------------------------------------------------------
# Phase A — repo guard (Step 2) + batch-invariant probes
# ---------------------------------------------------------------------------

# Repo guard: fail fast (before any GitHub mutation) when gh is unauthenticated
# or the CWD is not a GitHub-resolvable repo. The slug feeds the final summary.
if ! REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1)"; then
  echo "error: gh cannot resolve this repo (auth or remote problem):" >&2
  echo "  ${REPO_SLUG:-<no output>}" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi

# --- Phase A: portable temp dir (v0.29.0 — RFC 0004 §3.8) ---
# Allocate a private per-launch root beneath the caller's temp base. Shared
# roots such as /tmp are commonly root-owned and cannot safely host immutable
# contexts or predictable redirect targets directly.
_UBERDEV_TMP_BASE="${TMPDIR:-/tmp}"
case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
  MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then
      _UBERDEV_TMP_BASE="$(cygpath -m "$_UBERDEV_TMP_BASE")" || {
        echo "error: could not normalize native-Windows temp base: ${TMPDIR:-/tmp}" >&2
        echo "no claims written; no agents dispatched" >&2
        exit 1
      }
    else
      echo "error: cygpath is required to normalize the Git Bash temp directory for native Python" >&2
      echo "no claims written; no agents dispatched" >&2
      exit 1
    fi
    ;;
esac
if ! UBERDEV_TMPDIR="$(python3 -I -B -c '
import os,stat,sys,tempfile
base=os.path.realpath(sys.argv[1])
uid=os.geteuid() if hasattr(os,"geteuid") else None
posix_security=os.name!="nt"
owner_tag=str(uid) if uid is not None else "windows"
entry=os.stat(base,follow_symlinks=False)
if not stat.S_ISDIR(entry.st_mode): raise SystemExit(2)
mode=stat.S_IMODE(entry.st_mode)
if posix_security and mode & 0o022 and not mode & stat.S_ISVTX: raise SystemExit(2)
path=tempfile.mkdtemp(prefix=f"uberdev-solve-{owner_tag}-",dir=base)
if posix_security: os.chmod(path,0o700)
current=os.stat(path,follow_symlinks=False)
if not stat.S_ISDIR(current.st_mode) or (uid is not None and current.st_uid!=uid) or (posix_security and stat.S_IMODE(current.st_mode)!=0o700): raise SystemExit(2)
print(path,end="")
' "$_UBERDEV_TMP_BASE")"; then
  echo "error: could not allocate private solve staging under $_UBERDEV_TMP_BASE" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi
export UBERDEV_TMPDIR
umask 077
UBERDEV_KEEP_TMPDIR=0
_uberdev_cleanup_private_root() {
  [ "${UBERDEV_KEEP_TMPDIR:-0}" = "0" ] || return 0
  python3 -I -B -c '
import os,shutil,stat,sys
path,base=sys.argv[1:]; path=os.path.realpath(path); base=os.path.realpath(base)
uid=os.geteuid() if hasattr(os,"geteuid") else None
posix_security=os.name!="nt"
owner_tag=str(uid) if uid is not None else "windows"
entry=os.stat(path,follow_symlinks=False)
if os.path.dirname(path)!=base or not os.path.basename(path).startswith(f"uberdev-solve-{owner_tag}-"): raise SystemExit(2)
if not stat.S_ISDIR(entry.st_mode) or (uid is not None and entry.st_uid!=uid) or (posix_security and stat.S_IMODE(entry.st_mode)!=0o700): raise SystemExit(2)
shutil.rmtree(path)
' "$UBERDEV_TMPDIR" "$_UBERDEV_TMP_BASE" 2>/dev/null || true
}
trap _uberdev_cleanup_private_root EXIT

# Native-Windows-no-bash fast-fail + WSL2 9P warning (RFC 0004).
if [ -z "${BASH:-}" ] && { [ "${OS:-}" = "Windows_NT" ] || case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) true ;; *) false ;; esac; }; then
  echo "error: /solve and /turbo need a bash shell. On native Windows install" >&2
  echo "       Git for Windows (provides Git Bash), or use WSL2 (recommended)." >&2
  exit 1
fi
if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
  case "$PWD" in
    /mnt/*) echo "warning: repo is under /mnt/ in WSL2 — 9P/DrvFs is 10-50x slower than ext4; move it under ~/ for best /solve performance." >&2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Phase A — validate all issues (Step 4, validate-all-first)
# ---------------------------------------------------------------------------
# For every issue: fetch via `gh issue view --json` (read-only), confirm
# state == OPEN, run the claim-collision check, classify the tier, and echo
# one compact triage-signal line. If ANY issue fails, print all errors and
# abort with `no agents dispatched` — partial dispatches are not allowed.
#
# Speedup (#304): the N gh reads are parallelized in chunks of
# GH_PARALLEL_CAP background subshells (validate-all-before-claim ordering is
# preserved — processing below stays serial and deterministic in input order).
# Stage V1 — parallel fetch. Stdout must stay pure JSON; gh's spinner renders
# raw ESC frames on stderr on slow API calls, so stderr is captured separately
# (the 21ad417 mktemp-stderr-capture canary).
_uberdev_fetch_issue_json() {
  local n="$1"
  local GH_ERR TARGET
  GH_ERR=$(mktemp)
  TARGET="$UBERDEV_TMPDIR/solve-validate-$n.json"
  if ! python3 -I -B -c '
import os,stat,sys
root,target=sys.argv[1:]; root=os.path.realpath(root); target=os.path.abspath(target)
uid=os.geteuid() if hasattr(os,"geteuid") else None
posix_security=os.name!="nt"
root_entry=os.stat(root,follow_symlinks=False)
if not stat.S_ISDIR(root_entry.st_mode) or (uid is not None and root_entry.st_uid!=uid) or (posix_security and stat.S_IMODE(root_entry.st_mode)!=0o700): raise SystemExit(2)
if os.path.islink(root) or os.path.dirname(target)!=root: raise SystemExit(2)
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600)
entry=os.fstat(fd); os.close(fd)
if (uid is not None and entry.st_uid!=uid) or entry.st_nlink!=1 or not stat.S_ISREG(entry.st_mode): raise SystemExit(2)
' "$UBERDEV_TMPDIR" "$TARGET"; then
    printf '%s\n' 'unsafe validation snapshot target' > "$UBERDEV_TMPDIR/solve-validate-$n.err"
    rm -f "$GH_ERR"
    return 0
  fi
  # JSON fields include `assignees,comments` to feed the Step 4 collision
  # check — keeps Phase A to a single round-trip per issue.
  if gh issue view "$n" --json number,title,state,body,labels,assignees,comments \
      > "$TARGET" 2>"$GH_ERR"; then
    rm -f "$GH_ERR" "$UBERDEV_TMPDIR/solve-validate-$n.err" 2>/dev/null
  else
    mv "$GH_ERR" "$UBERDEV_TMPDIR/solve-validate-$n.err"
    rm -f "$TARGET" 2>/dev/null
  fi
}

_vinflight=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  _uberdev_fetch_issue_json "$ISSUE_NUM" &
  _vinflight=$((_vinflight + 1))
  if [[ "$_vinflight" -ge "$GH_PARALLEL_CAP" ]]; then
    wait
    _vinflight=0
  fi
done
wait

# Stage V2 — serial processing in input order. TIERS/TITLES are parallel
# indexed arrays aligned with ISSUE_NUMS (bash-3.2-safe; `declare -A` hard-
# errors on the macOS system bash).
TIERS=()
TITLES=()
RISKS=()
TRIAGE_DECISIONS=()
ERRORS=()
FLOOR=""
CEILING=""
if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
  FLOOR="$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium|large" "")"
  CEILING="$(uberdev_read_enum solve_tier_ceiling SOLVE_TIER_CEILING "trivial|small|medium|large" "")"
fi
FLOOR_RANK="$(uberdev_tier_rank "$FLOOR")"
CEILING_RANK="$(uberdev_tier_rank "$CEILING")"
if [ -n "$FLOOR_RANK" ] && [ -n "$CEILING_RANK" ] && [ "$FLOOR_RANK" -gt "$CEILING_RANK" ]; then
  TIER=medium
  uberdev_clamp_tier "$TIER" "$FLOOR" "$CEILING" >/dev/null
  FLOOR=""; CEILING=""
fi
_vidx=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  TIERS[$_vidx]=""
  TITLES[$_vidx]=""
  RISKS[$_vidx]='[]'
  TRIAGE_DECISIONS[$_vidx]='{}'
  if [[ ! -s "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.json" ]]; then
    ERRORS+=("#$ISSUE_NUM: gh fetch failed: $(cat "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.err" 2>/dev/null || echo '<no stderr captured>')")
    rm -f "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.err"
    _vidx=$((_vidx + 1))
    continue
  fi
  ISSUE_JSON="$(cat "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.json")"
  STATE=$(jq -r .state <<<"$ISSUE_JSON")
  # Closed issues are rejected read-only. Stale-label cleanup must not mutate
  # GitHub before the full routing/context batch is proven enforceable.
  if [[ "$STATE" != "OPEN" ]]; then
    ERRORS+=("#$ISSUE_NUM: state=$STATE (must be OPEN)")
    _vidx=$((_vidx + 1))
    continue
  fi
  # --- Phase A: claim-collision check (v0.28.0) ---
  # Piggybacks on $ISSUE_JSON (no extra round-trip). Refuse when the
  # `uberdev:active` label is live, unless FORCE_CLAIM=1. Latest-claim parse:
  # version-stripped marker prefix (#123 B7 — a v2 dispatcher's marker must
  # stay visible to v1 collision checks across rolling upgrades), then `last`
  # of the marker-matched comments (GitHub returns .comments chronologically).
  HAS_ACTIVE_LABEL=$(jq -r '[.labels[].name] | index("uberdev:active") // empty' <<<"$ISSUE_JSON")
  if [[ -n "$HAS_ACTIVE_LABEL" ]]; then
    CLAIM_COMMENT_MARKER_PREFIX="${CLAIM_COMMENT_MARKER% v* -->}"
    LATEST_CLAIM_BODY=$(jq -r --arg marker "$CLAIM_COMMENT_MARKER_PREFIX" \
      '[.comments[] | select(.body | contains($marker))] | last | .body // empty' \
      <<<"$ISSUE_JSON")
    CLAIM_USER="?"; CLAIM_HOST="?"; CLAIM_BRANCH="?"; CLAIM_TS="?"
    if [[ -n "$LATEST_CLAIM_BODY" ]]; then
      # Field-extraction: capture grep|sed output, conditional-assign only when
      # non-empty so the pre-init "?" defaults survive missing fields. The
      # naive `… | sed … || echo "?"` form is broken — sed exits 0 even when
      # grep matched nothing (Q1; #123 Phase 2 blocker).
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^User: '    | sed 's/^User: //');     [[ -n "$_v" ]] && CLAIM_USER="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Host: '    | sed 's/^Host: //');     [[ -n "$_v" ]] && CLAIM_HOST="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Branch: '  | sed 's/^Branch: //');   [[ -n "$_v" ]] && CLAIM_BRANCH="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Started: ' | sed 's/^Started: //');  [[ -n "$_v" ]] && CLAIM_TS="$_v"
    fi
    # F4: distinguish "label set but no parseable claim comment" (racing
    # dispatcher whose comment has not posted yet, or hand-edited label) from
    # the standard fully-attributed collision.
    if [[ "$CLAIM_USER" == "?" && "$CLAIM_HOST" == "?" && "$CLAIM_BRANCH" == "?" && "$CLAIM_TS" == "?" ]]; then
      ALL_PLACEHOLDER=1
    else
      ALL_PLACEHOLDER=0
    fi
    if [[ "$FORCE_CLAIM" == "1" ]]; then
      echo "warning: #$ISSUE_NUM already claimed (user=$CLAIM_USER host=$CLAIM_HOST branch=$CLAIM_BRANCH at=$CLAIM_TS) — --force override in effect" >&2
      _uberdev_audit_emit claim_force_override \
        "{\"issue\":$ISSUE_NUM,\"prior_user\":\"$CLAIM_USER\",\"prior_host\":\"$CLAIM_HOST\",\"prior_branch\":\"$CLAIM_BRANCH\",\"prior_started\":\"$CLAIM_TS\"}" || true
    else
      if [[ "$ALL_PLACEHOLDER" == "1" ]]; then
        ERRORS+=("#$ISSUE_NUM: uberdev:active label is set but no matching claim comment was found (racing dispatcher whose comment has not posted yet, or hand-edited label) — wait a moment and retry, or pass --force to override")
      else
        ERRORS+=("#$ISSUE_NUM: already claimed by $CLAIM_USER on $CLAIM_HOST (branch $CLAIM_BRANCH, started $CLAIM_TS) — pass --force to override")
      fi
      _uberdev_audit_emit claim_collision \
        "{\"issue\":$ISSUE_NUM,\"prior_user\":\"$CLAIM_USER\",\"prior_host\":\"$CLAIM_HOST\",\"prior_branch\":\"$CLAIM_BRANCH\"}" || true
      _vidx=$((_vidx + 1))
      continue
    fi
  fi
  # Title: truncate to 40 chars (with ellipsis) for the workspace/tab name.
  TITLE_RAW=$(jq -r .title <<<"$ISSUE_JSON")
  if [[ ${#TITLE_RAW} -gt 40 ]]; then
    TITLE="${TITLE_RAW:0:40}…"
  else
    TITLE="$TITLE_RAW"
  fi
  # Pure deterministic classification from the exact bounded snapshot.
  TRIAGE_ARGS=( classify --snapshot "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.json" --secure-root "$UBERDEV_TMPDIR" --expected-issue "$ISSUE_NUM" )
  if ! TRIAGE_RAW_JSON="$(python3 -I "$_UBERDEV_SOLVE_TRIAGE" "${TRIAGE_ARGS[@]}" 2>&1)"; then
    ERRORS+=("#$ISSUE_NUM: $TRIAGE_RAW_JSON")
    _vidx=$((_vidx + 1))
    continue
  fi
  TIER="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["raw_tier"],end="")' "$TRIAGE_RAW_JSON")"
  CLAMPED_TIER="$(uberdev_clamp_tier "$TIER" "$FLOOR" "$CEILING")"
  FINALIZE_ARGS=( finalize --decision "$TRIAGE_RAW_JSON" --clamped "$CLAMPED_TIER" )
  [[ -z "$OVERRIDE" ]] || FINALIZE_ARGS+=( --override "$OVERRIDE" )
  if ! TRIAGE_JSON="$(python3 -I "$_UBERDEV_SOLVE_TRIAGE" "${FINALIZE_ARGS[@]}" 2>&1)"; then
    ERRORS+=("#$ISSUE_NUM: $TRIAGE_JSON")
    _vidx=$((_vidx + 1))
    continue
  fi
  TIER="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["tier"],end="")' "$TRIAGE_JSON")"
  TIER_SOURCE="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["source"],end="")' "$TRIAGE_JSON")"
  RISK_JSON="$(python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["risk_signals"],separators=(",",":")),end="")' "$TRIAGE_JSON")"
  TRIAGE_ISSUE="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["issue"],end="")' "$TRIAGE_JSON")"
  if [ "$TRIAGE_ISSUE" != "$ISSUE_NUM" ]; then
    ERRORS+=("#$ISSUE_NUM: triage_issue_mismatch")
    _vidx=$((_vidx + 1))
    continue
  fi
  TRIAGE_LABELS=$(jq -r '[.labels[].name] | join(",")' <<<"$ISSUE_JSON")
  TRIAGE_BODY_CHARS=$(jq -r '.body // "" | length' <<<"$ISSUE_JSON")
  if jq -r '.body // ""' <<<"$ISSUE_JSON" | grep -qE 'Traceback \(most recent call last\)|^[[:space:]]+at .+\(.+:[0-9]+|^[[:space:]]*File "|panic:|stack trace|Stack trace'; then
    TRIAGE_STACK=yes
  else
    TRIAGE_STACK=no
  fi
  TRIAGE_FILES=$(jq -r '.body // ""' <<<"$ISSUE_JSON" | grep -oE '[A-Za-z0-9_./-]+\.(sh|md|ts|tsx|js|jsx|py|json|yml|yaml|go|rs|java|rb|c|h|cpp|css|html)\b' | sort -u | wc -l | tr -d ' ')
  echo "triage: #$ISSUE_NUM tier=$TIER($TIER_SOURCE) labels=[$TRIAGE_LABELS] body_chars=$TRIAGE_BODY_CHARS stack_trace=$TRIAGE_STACK files_mentioned=$TRIAGE_FILES title=\"$TITLE\""
  TIERS[$_vidx]="$TIER"
  TITLES[$_vidx]="$TITLE"
  RISKS[$_vidx]="$RISK_JSON"
  TRIAGE_DECISIONS[$_vidx]="$TRIAGE_JSON"
  rm -f "$UBERDEV_TMPDIR/solve-validate-$ISSUE_NUM.json"
  _vidx=$((_vidx + 1))
done

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  printf 'error: %s\n' "${ERRORS[@]}" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi

# TURBO MODE banner — print once before the per-issue loop if any tier is
# medium (deduped: a 3-medium batch must not stack three identical banners;
# break after the first medium hit).
if [[ "$AUTO_MODE" == "1" ]]; then
  for n in "${!ISSUE_NUMS[@]}"; do
    if [[ "${TIERS[$n]}" == "medium" ]]; then
      echo "⚠️  TURBO MODE — brainstorm questions auto-answered with lead-agent recommendations." >&2
      echo "    Spec and plan are still written to disk before implementation; review the artifacts to course-correct." >&2
      break
    fi
  done
fi

# --- Phase A: bg dispatch probes + fanout cap (v0.22.0) ---
# Batch-invariant; resolved once, hoisted out of the Phase B per-issue loop.
# (The backend availability gate runs after preflight resolves the backend —
# see the gate just below the dispatch source.)
if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
  MAX_PARALLEL_BG_AGENTS="$(uberdev_read_int_in_range fanout_concurrency.solve_bg UBERDEV_FANOUT_SOLVE_BG 1 50 6)"
else
  MAX_PARALLEL_BG_AGENTS=6
fi

_uberdev_audit_emit effort_resolved \
  "{\"source\":\"$EFFORT_SOURCE\",\"level\":\"$EFFORT_LEVEL\"}" || true

# Source lib/dispatch.sh and resolve the backend ONCE for the whole batch.
# PLUGIN_ROOT is accepted alongside CLAUDE_PLUGIN_ROOT for embedders that set
# only the former.
if [ -r "${UBERDEV_PLUGIN_ROOT:-}/lib/dispatch.sh" ]; then
  # shellcheck source=/dev/null
  . "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh"
  uberdev_dispatch_preflight || { echo "no claims written; no agents dispatched" >&2; exit 1; }
  uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || { echo "no claims written; no agents dispatched" >&2; exit 1; }
else
  echo "error: lib/dispatch.sh not found at ${UBERDEV_PLUGIN_ROOT:-}/lib/" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi

# Backend availability gate. The codex arm that used to sit above this one is
# gone (#381): it was the only backend that did NOT exec `claude`, so the whole
# branch collapsed. Every surviving backend runs `claude` and needs >= 2.1.152
# (--permission-mode bypassPermissions, #246).
#
# `--effort=ultra` is still REFUSED, and this refusal is now unconditional
# rather than "unless the backend is codex". `ultra` was an exact Codex route
# field with no Claude equivalent, and deleting the transport did not make it
# resolvable — it made it unresolvable everywhere. Accepting it silently would
# hand the operator a route nothing honours.
if [ "${UBERDEV_DISPATCH_REASONING_EFFORT:-}" = "ultra" ]; then
  echo "error: --effort=ultra has no provider on any surviving backend; resolved backend is ${UBERDEV_RESOLVED_BACKEND:-unknown}" >&2
  echo "no claims written; no agents dispatched" >&2
  exit 1
fi
# On Claude-backed providers --effort is the legacy child effort flag, not an
# exact route field. Keep EFFORT_LEVEL/EFFORT_FLAG and clear only the
# provider-neutral request carrier before route enforceability checks.
UBERDEV_DISPATCH_REASONING_EFFORT=""
export UBERDEV_DISPATCH_REASONING_EFFORT
_uberdev_require_claude_version "2.1.152" || {
  echo "no claims written; no agents dispatched" >&2
  exit 1
}

# Resolve every lead route and create its immutable context before the first
# GitHub claim write. A single unenforceable route aborts the whole batch.
ROOT_REQUESTS=()
WORKFLOW=solve
[[ "$TURBO_OPT" == "1" ]] && WORKFLOW=turbo
_ridx=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  if ! ROOT_REQUEST="$(uberdev_dispatch_prepare_root "$ISSUE_NUM" "${TIERS[$_ridx]}" "${RISKS[$_ridx]}" "$WORKFLOW" "${TRIAGE_DECISIONS[$_ridx]}")"; then
    echo "error: #$ISSUE_NUM routing/context validation failed" >&2
    echo "no claims written; no agents dispatched" >&2
    exit 1
  fi
  ROOT_REQUESTS[$_ridx]="$ROOT_REQUEST"
  _ridx=$((_ridx + 1))
done

# ---------------------------------------------------------------------------
# Step 4.5 — claim protocol: mark issues ACTIVE (v0.28.0; verification NEW)
# ---------------------------------------------------------------------------
# Three-part claim per issue, in sequence with rollback on partial failure:
# label (queryable) → @me assignee (UI signal) → fingerprinted audit comment
# (the only safe parser surface), then a POST-WRITE VERIFICATION re-read.
# All writes are fail-loud; any failure aborts the batch and rolls back every
# claim acquired in this run.
#
# Post-write verification (#304 — closes the #123 B2 check-then-act TOCTOU):
# after posting our claim comment, re-fetch the latest marker-matched comment.
# If it names a DIFFERENT dispatcher, a racing claim landed after ours —
# newest-wins is deterministic from both sides (the loser sees a foreign
# comment as latest; the winner sees its own), so the loser backs off:
# remove OUR assignee only (the shared label now belongs to the winner),
# emit claim_collision with phase=post_write_verification, fail the batch.
# An inconclusive re-read (gh hiccup / comment not yet indexed) warns and
# proceeds — the write itself already succeeded fail-loud, and aborting a
# whole batch on a read blip would be the worse trade. Residual window:
# both dispatchers verifying before either's comment lands remain mutually
# blind for the sub-second comment-indexing interval.
#
# Speedup (#304 serial-claims): per-issue claim sequences run as background
# subshells in GH_PARALLEL_CAP chunks (~3 serial round-trips per issue
# become ~3 per chunk); validate-all-before-claim and all-or-nothing
# rollback semantics are unchanged. Per-issue status lands in
# $UBERDEV_TMPDIR/solve-claimrc-N ("ok" | "ok-unverified" | "fail <step>" |
# "lost <user>"); CLAIMED is rebuilt by the parent from those files.

# FAIL-LOUD label provisioning: the label MUST exist before the combined
# `--add-label --add-assignee` mutation (gh cannot auto-create from
# --add-label and fails the combined mutation atomically). `--force` makes
# this idempotent, so a non-zero exit is ALWAYS a genuine failure. Runs once,
# before any claim is written, so a clean exit 1 needs no rollback.
if ! LABEL_PROVISION_ERR=$(gh label create --force "$UBERDEV_ACTIVE_LABEL" \
    --color "$UBERDEV_ACTIVE_LABEL_COLOR" \
    --description "$UBERDEV_ACTIVE_LABEL_DESCRIPTION" 2>&1); then
  echo "error: failed to provision the '$UBERDEV_ACTIVE_LABEL' label that the claim protocol requires (gh issue edit --add-label cannot auto-create it). Check gh auth and repo write/triage permission." >&2
  echo "  gh label create said: ${LABEL_PROVISION_ERR:-<no output>}" >&2
  _uberdev_audit_emit claim_write_failed "{\"step\":\"label_create\"}" || true
  exit 1
fi

# Dispatcher identity (matches what `--add-assignee @me` resolves to).
DISPATCHER_USER=$(gh api user --jq .login 2>/dev/null)
if [[ -z "$DISPATCHER_USER" ]]; then
  echo "error: gh api user returned empty login — run \`gh auth login\` first" >&2
  exit 1
fi
DISPATCHER_HOST=$(hostname -s 2>/dev/null || hostname)
DISPATCH_TS=$(date -u +%FT%TZ)

CLAIMED=()
# _uberdev_release_claim ISSUE_NUM REASON [EXTRA_JSON]
#   Releases one issue's claim (single combined gh round-trip:
#   --remove-label + --remove-assignee, atomic on partial error) and emits a
#   canonically-shaped `claim_released` audit event. Single helper for every
#   release site so no rollback path can forget one of the three operations
#   (label-remove, assignee-remove, audit-emit — the #123 B5 regression
#   shape). Fail-soft on the gh call: every caller is already on a failing
#   path; masking the original error with a secondary rollback failure is
#   the wrong trade.
_uberdev_release_claim() {
  local issue="$1" reason="$2" extra="${3:-}"
  gh issue edit "$issue" --remove-label "$UBERDEV_ACTIVE_LABEL" --remove-assignee "@me" >/dev/null 2>&1 || true
  local payload="{\"issue\":$issue,\"reason\":\"$reason\""
  [[ -n "$extra" ]] && payload="${payload},${extra}"
  payload="${payload}}"
  _uberdev_audit_emit claim_released "$payload" || true
}
_uberdev_rollback_claims() {
  # Best-effort rollback — delegates to _uberdev_release_claim. B8: the no-op
  # case (zero prior claims) emits an explicit info line so a partial-state
  # bug cannot hide behind an empty CLAIMED array.
  local c
  if [[ ${#CLAIMED[@]} -eq 0 ]]; then
    echo "info: claim rollback: no prior claims to release (CLAIMED is empty — first-issue failure)" >&2
    return 0
  fi
  for c in "${CLAIMED[@]}"; do
    _uberdev_release_claim "$c" "batch_rollback"
  done
}

# _uberdev_claim_one ISSUE_NUM TIER — full per-issue claim sequence; runs in a
# background subshell. Writes status to $UBERDEV_TMPDIR/solve-claimrc-N and
# operator-facing error text to $UBERDEV_TMPDIR/solve-claimerr-N (replayed
# serially by the parent so output stays deterministic).
_uberdev_claim_one() {
  local ISSUE_NUM="$1" TIER="$2"
  local RC_FILE="$UBERDEV_TMPDIR/solve-claimrc-$ISSUE_NUM"
  local ERR_FILE="$UBERDEV_TMPDIR/solve-claimerr-$ISSUE_NUM"
  : > "$ERR_FILE"
  # CLAIM_BODY: the marker line MUST be first (collision-check jq filters on
  # `.body | contains($marker)`); field lines anchor `^User: ` / `^Host: ` /
  # `^Branch: ` / `^Started: ` for the parser.
  local CLAIM_BODY
  CLAIM_BODY="$(cat <<EOF
$CLAIM_COMMENT_MARKER
uberdev:active — claimed for /solve or /turbo dispatch

User: @$DISPATCHER_USER
Host: $DISPATCHER_HOST
Branch: worktree-solve-issue-$ISSUE_NUM
Tier: $TIER
Started: $DISPATCH_TS

Auto-clears on /merge or issue close. If this claim is stale, override with:
  /turbo $ISSUE_NUM --force    (or /solve $ISSUE_NUM --force)
EOF
)"
  # Combined claim write: label + assignee in one gh round-trip (atomic on
  # partial error — E1).
  if ! gh issue edit "$ISSUE_NUM" --add-label "$UBERDEV_ACTIVE_LABEL" --add-assignee "@me" >/dev/null 2>&1; then
    echo "error: #$ISSUE_NUM: failed to write claim (label or assignee) — check gh auth / repo permissions" >> "$ERR_FILE"
    _uberdev_audit_emit claim_write_failed "{\"issue\":$ISSUE_NUM,\"step\":\"label_or_assignee\"}" || true
    echo "fail label_or_assignee" > "$RC_FILE"
    return 0
  fi
  if ! printf '%s' "$CLAIM_BODY" | gh issue comment "$ISSUE_NUM" --body-file - >/dev/null 2>&1; then
    echo "error: #$ISSUE_NUM: failed to post claim audit comment" >> "$ERR_FILE"
    _uberdev_audit_emit claim_write_failed "{\"issue\":$ISSUE_NUM,\"step\":\"comment\"}" || true
    # Release this issue's partial claim (label+assignee were set above);
    # the parent's batch rollback covers the sibling issues.
    _uberdev_release_claim "$ISSUE_NUM" "claim_write_failed"
    echo "fail comment" > "$RC_FILE"
    return 0
  fi
  # --- Step 4.5: post-write verification (#304 — closes #123 B2) ---
  # One extra gh round-trip per issue: re-fetch the latest marker-matched
  # claim comment and confirm it is OURS (User+Host+Started+Branch).
  local VERIFY_JSON LATEST_BODY V_USER V_HOST V_BRANCH V_TS
  local CLAIM_COMMENT_MARKER_PREFIX="${CLAIM_COMMENT_MARKER% v* -->}"
  VERIFY_JSON=$(gh issue view "$ISSUE_NUM" --json comments 2>/dev/null) || VERIFY_JSON=""
  LATEST_BODY=""
  if [[ -n "$VERIFY_JSON" ]]; then
    LATEST_BODY=$(jq -r --arg marker "$CLAIM_COMMENT_MARKER_PREFIX" \
      '[.comments[] | select(.body | contains($marker))] | last | .body // empty' \
      <<<"$VERIFY_JSON" 2>/dev/null)
  fi
  if [[ -z "$LATEST_BODY" ]]; then
    # Inconclusive (read blip or comment not yet indexed): warn + proceed —
    # the fail-loud writes above succeeded; do not fail a batch on a read.
    echo "warning: #$ISSUE_NUM: post-write claim verification inconclusive (could not re-read the claim comment) — proceeding on the successful write" >> "$ERR_FILE"
    _uberdev_audit_emit claim_acquired \
      "{\"issue\":$ISSUE_NUM,\"user\":\"$DISPATCHER_USER\",\"host\":\"$DISPATCHER_HOST\",\"tier\":\"$TIER\",\"forced\":$([[ "$FORCE_CLAIM" == "1" ]] && echo true || echo false),\"verified\":false}" || true
    echo "ok-unverified" > "$RC_FILE"
  else
    V_USER=$(printf '%s\n' "$LATEST_BODY" | grep -m1 '^User: '    | sed 's/^User: @//; s/^User: //')
    V_HOST=$(printf '%s\n' "$LATEST_BODY" | grep -m1 '^Host: '    | sed 's/^Host: //')
    V_BRANCH=$(printf '%s\n' "$LATEST_BODY" | grep -m1 '^Branch: ' | sed 's/^Branch: //')
    V_TS=$(printf '%s\n' "$LATEST_BODY" | grep -m1 '^Started: '   | sed 's/^Started: //')
    if [[ "$V_USER" == "$DISPATCHER_USER" && "$V_HOST" == "$DISPATCHER_HOST" && "$V_TS" == "$DISPATCH_TS" && "$V_BRANCH" == "worktree-solve-issue-$ISSUE_NUM" ]]; then
      _uberdev_audit_emit claim_acquired \
        "{\"issue\":$ISSUE_NUM,\"user\":\"$DISPATCHER_USER\",\"host\":\"$DISPATCHER_HOST\",\"tier\":\"$TIER\",\"forced\":$([[ "$FORCE_CLAIM" == "1" ]] && echo true || echo false),\"verified\":true}" || true
      echo "ok" > "$RC_FILE"
    else
      # Lost the race: a foreign claim posted after ours. The winner owns the
      # shared label — remove only OUR assignee, leave their claim intact.
      gh issue edit "$ISSUE_NUM" --remove-assignee "@me" >/dev/null 2>&1 || true
      echo "error: #$ISSUE_NUM: lost post-write claim verification to $V_USER on ${V_HOST:-?} (their claim comment is newest) — issue remains claimed by them; retry with --force only if you are sure their dispatcher is stale" >> "$ERR_FILE"
      _uberdev_audit_emit claim_collision \
        "{\"issue\":$ISSUE_NUM,\"prior_user\":\"$V_USER\",\"prior_host\":\"$V_HOST\",\"prior_branch\":\"$V_BRANCH\",\"phase\":\"post_write_verification\"}" || true
      echo "lost $V_USER" > "$RC_FILE"
      return 0
    fi
  fi
  # Per-issue claim metadata for the Phase B dispatch-failure rollback
  # (Step 5b' reads this on $BG_DISPATCH_RC != 0).
  cat > "$UBERDEV_TMPDIR/solve-claim-$ISSUE_NUM.json" <<EOF2
{"issue":$ISSUE_NUM,"user":"$DISPATCHER_USER","host":"$DISPATCHER_HOST","branch":"worktree-solve-issue-$ISSUE_NUM","tier":"$TIER","started":"$DISPATCH_TS","forced":$([[ "$FORCE_CLAIM" == "1" ]] && echo true || echo false)}
EOF2
}

# --- Phase A: claim-write pass (Step 4.5) — parallel chunks, serial collect ---
_cidx=0
_cinflight=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  rm -f "$UBERDEV_TMPDIR/solve-claimrc-$ISSUE_NUM" 2>/dev/null
  _uberdev_claim_one "$ISSUE_NUM" "${TIERS[$_cidx]}" &
  _cidx=$((_cidx + 1))
  _cinflight=$((_cinflight + 1))
  if [[ "$_cinflight" -ge "$GH_PARALLEL_CAP" ]]; then
    wait
    _cinflight=0
  fi
done
wait

CLAIM_FAILED=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  # Replay each worker's operator-facing messages in input order.
  if [[ -s "$UBERDEV_TMPDIR/solve-claimerr-$ISSUE_NUM" ]]; then
    cat "$UBERDEV_TMPDIR/solve-claimerr-$ISSUE_NUM" >&2
  fi
  rm -f "$UBERDEV_TMPDIR/solve-claimerr-$ISSUE_NUM"
  CLAIM_STATUS="$(cat "$UBERDEV_TMPDIR/solve-claimrc-$ISSUE_NUM" 2>/dev/null || echo "fail missing_status")"
  rm -f "$UBERDEV_TMPDIR/solve-claimrc-$ISSUE_NUM"
  case "$CLAIM_STATUS" in
    ok|ok-unverified)
      CLAIMED+=("$ISSUE_NUM")
      ;;
    lost*)
      # Verification loser: our assignee was already removed by the worker;
      # the winner's label/claim stays. Counts as a batch failure.
      CLAIM_FAILED=1
      ;;
    *)
      CLAIM_FAILED=1
      ;;
  esac
done
if [[ "$CLAIM_FAILED" == "1" ]]; then
  _uberdev_rollback_claims
  echo "no agents dispatched" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase B — per-issue dispatch (Step 5)
# ---------------------------------------------------------------------------
# Step 5a writes each issue's tier-appropriate prompt (serial heredocs —
# cheap). Step 5b' dispatches via the backend resolved in Phase A, wrapped in
# the wave-batching outer loop (`ceil(N / cap)` waves with one
# solve_bg_fanout_wave_started audit event per wave). NOTE: the wave cap is
# DISPATCH-BURST CHUNKING, not a live concurrency ceiling — every backend
# returns immediately after spawn, so all dispatched agents run concurrently
# (#304; the docs previously overclaimed this as a parallelism cap).
# Dispatch outcomes land in SPAWNED / DISPATCH_FAILED — no silent
# partial-batch failures.
#
# The trivial/small/medium prompt if/else/fi blocks stay at COLUMN 0:
# tests/turbo-flow.test.sh and tests/post-impl-review.test.sh drive awk state
# machines over `^if \[\[ "\$AUTO_MODE" ... \]\]; then$` / `^else$` / `^fi$`
# anchors. Do not indent these blocks; do not add a third column-0
# `if [[ "$AUTO_MODE" == "1" ]]; then` line (anchor count is locked at 2).
SPAWNED=()
DISPATCH_FAILED=()
_pidx=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
TIER="${TIERS[$_pidx]}"
TITLE="${TITLES[$_pidx]}"

# Step 5a — write tier-appropriate prompt. The trivial/small heredocs commit
# and hand off to uberdev:finish-branch (--turbo forwarded on the auto-mode
# branch) which owns push, PR creation and the canonical
# Skill("uberdev:review-pr") chain. Medium dispatches /uberdev:orchestrator.
case "$TIER" in
trivial)
if [[ "$AUTO_MODE" != "1" ]]; then
# trivial heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your working context. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues whose research was persisted under the previous fanout.
3. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
4. Add/update a test ONLY if the touched code is already tested.
5. Run the relevant test file + lint for that package.
6. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
7. **Hand off to \`uberdev:finish-branch\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
else
# trivial heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
3. Add/update a test ONLY if the touched code is already tested.
4. Run the relevant test file + lint for that package.
5. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
6. **Hand off to \`uberdev:finish-branch --turbo\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr --turbo")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
fi
;;
small)
if [[ "$AUTO_MODE" != "1" ]]; then
# small heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your TodoWrite plan as constraints/considerations. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues.
3. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
4. TDD: write the failing test first, then implement, then green.
5. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
6. **Hand off to \`uberdev:finish-branch\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
else
# small heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
3. TDD: write the failing test first, then implement, then green.
4. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
5. **Hand off to \`uberdev:finish-branch --turbo\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr --turbo")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
fi
;;
*)
# medium (and --full): claude --bg does NOT slash-expand argv-supplied opening
# messages, so wrap the slash invocation in a natural-language imperative the
# child must interpret as an instruction rather than answer conversationally.
if [[ "$AUTO_MODE" == "1" ]]; then
echo "Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM now. Do not respond conversationally — execute it." > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
else
echo "Invoke the slash command /uberdev:orchestrator solve GH issue #$ISSUE_NUM now. Do not respond conversationally — execute it." > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
fi
;;
esac
_pidx=$((_pidx + 1))
done

# Step 5w — Workflow-native fanout (RFC 0015; the `workflow` backend, which is
# what `auto` resolves to on every Claude host). There is NOTHING to dispatch
# from this process: the per-issue solver fleet runs inside the calling
# session's Workflow runtime, so the launcher's job ends at "write the
# manifest, emit the args envelope". commands/solve.md + commands/turbo.md
# mandate the Workflow call on the JSON between the markers (DR-2: relayed
# verbatim, never LLM-composed).
#
# Everything before this point is unchanged and still authoritative: the
# validate-all-first pass, the triage decisions, the prepared root request /
# context files, and the Step 4.5 claim protocol have all already run. Only
# the transport differs.
if [[ "${UBERDEV_RESOLVED_BACKEND:-}" == "workflow" ]]; then
  # The prompt + context files must outlive this process — the fleet agents
  # read them after the launcher has exited.
  UBERDEV_KEEP_TMPDIR=1

  SOLVE_FLEET_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
  SOLVE_FLEET_WORKFLOW_JS="$SOLVE_FLEET_PLUGIN_ROOT/skills/solve-fleet/workflow.js"
  if [ ! -f "$SOLVE_FLEET_WORKFLOW_JS" ]; then
    echo "error: $SOLVE_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin, or re-run with an explicit --backend=<name> to use a detached transport" >&2
    exit 2
  fi
  # uberdev_emit_workflow_args lives in config-read.sh. It is sourced earlier on
  # most paths (the enum readers), but only conditionally — source it here so
  # the emission cannot depend on which flag branches happened to run.
  if ! command -v uberdev_emit_workflow_args >/dev/null 2>&1; then
    if [ -r "$SOLVE_FLEET_PLUGIN_ROOT/lib/config-read.sh" ]; then
      # shellcheck source=/dev/null
      . "$SOLVE_FLEET_PLUGIN_ROOT/lib/config-read.sh"
    fi
  fi
  if ! command -v uberdev_emit_workflow_args >/dev/null 2>&1; then
    echo "error: uberdev_emit_workflow_args unavailable (lib/config-read.sh not loadable from $SOLVE_FLEET_PLUGIN_ROOT); cannot emit the solve-fleet args envelope" >&2
    exit 2
  fi
  if ! REPO_ROOT_ABS="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$REPO_ROOT_ABS" ]; then
    echo "error: unable to resolve the repository root for the solve-fleet args envelope" >&2
    exit 2
  fi

  # --- BEGIN solve-fleet base capture (#439) ---
  # The base branch each solver's PR must target (#439). The launcher is the ONLY
  # process that still sees the real checkout: the fleet's worktrees are cut by
  # the Workflow runtime, so the script never learns what ref they came from.
  # Capture it here or a run launched from a stacked branch opens every PR
  # against the repository default. Empty on detached HEAD — no invented
  # fallback; the fleet omits `--base` entirely in that case.
  SOLVE_FLEET_BASE_BRANCH="$(git branch --show-current 2>/dev/null)" || SOLVE_FLEET_BASE_BRANCH=""
  # `gh pr create --base <branch>` HARD-FAILS when the branch does not exist on
  # the remote, and /solve + /turbo deliberately do NOT read pr_base_branch, so
  # there is no operator override to recover with: launching a fleet from a
  # local-only branch (a worktree, or a feature branch not pushed yet) would fail
  # PR creation for EVERY issue in the run, where before #439 the PR was opened
  # against the repository default. Emit the value only when it is a real remote
  # branch — workflow.js emits no --base instruction for an empty value, so this
  # degrades to exactly the pre-#439 behaviour instead of hard-failing. Mirrors
  # the `git rev-parse --verify` check finish-branch runs on its own base.
  if [ -n "$SOLVE_FLEET_BASE_BRANCH" ] \
     && ! git rev-parse --verify --quiet "refs/remotes/origin/$SOLVE_FLEET_BASE_BRANCH" >/dev/null 2>&1; then
    SOLVE_FLEET_BASE_BRANCH=""
  fi
  # --- END solve-fleet base capture (#439) ---

  # Per-issue manifest (the scan-fleet manifestPathAbs convention): one JSON
  # file the fleet's `intake` relay reads, instead of stuffing per-issue
  # records into envelope scalars. Titles are NOT embedded anywhere in a
  # prompt — the fleet agents re-read them from `gh` inside their own
  # untrusted-input handling.
  SOLVE_FLEET_MANIFEST="$UBERDEV_TMPDIR/solve-fleet-manifest.json"
  {
    _mfirst=1
    printf '{"schema_version":1,"auto_mode":%s,"issues":[' \
      "$([[ "$AUTO_MODE" == "1" ]] && echo true || echo false)"
    _midx=0
    for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
      [ "$_mfirst" = "1" ] || printf ','
      _mfirst=0
      python3 -I -c '
import json,sys
issue,tier,prompt_file,root_request=sys.argv[1:5]
rec={"issue":int(issue),"tier":tier,"prompt_file":prompt_file}
try:
    r=json.loads(root_request) if root_request else {}
except ValueError:
    r={}
for key in ("context_file","context_sha256","run_id"):
    if r.get(key):
        rec[key]=r[key]
print(json.dumps(rec,sort_keys=True,separators=(",",":")),end="")
' "$ISSUE_NUM" "${TIERS[$_midx]}" "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" "${ROOT_REQUESTS[$_midx]:-}" \
        || { echo "error: failed to build the solve-fleet manifest record for #$ISSUE_NUM" >&2; exit 2; }
      _midx=$((_midx + 1))
    done
    printf ']}\n'
  } > "$SOLVE_FLEET_MANIFEST" || { echo "error: failed to write $SOLVE_FLEET_MANIFEST" >&2; exit 2; }
  chmod 600 "$SOLVE_FLEET_MANIFEST" 2>/dev/null || true

  _uberdev_audit_emit solve_workflow_fleet_prepared \
    "{\"issues\":${#ISSUE_NUMS[@]},\"manifest\":\"$SOLVE_FLEET_MANIFEST\",\"concurrency\":$MAX_PARALLEL_BG_AGENTS}"

  SOLVE_FLEET_ISSUES="$(printf '%s,' "${ISSUE_NUMS[@]}")"; SOLVE_FLEET_ISSUES="${SOLVE_FLEET_ISSUES%,}"
  uberdev_emit_workflow_args solve-fleet \
    repo_root="$REPO_ROOT_ABS" \
    pluginRootAbs="${UBERDEV_PLUGIN_ROOT:-$CLAUDE_PLUGIN_ROOT}" \
    repoRootAbs="$REPO_ROOT_ABS" \
    manifestPathAbs="$SOLVE_FLEET_MANIFEST" \
    runDirAbs="$UBERDEV_TMPDIR" \
    issues="$SOLVE_FLEET_ISSUES" \
    issueCount="${#ISSUE_NUMS[@]}" \
    concurrency="$MAX_PARALLEL_BG_AGENTS" \
    autoMode="$([[ "$AUTO_MODE" == "1" ]] && echo true || echo false)" \
    repoSlug="$REPO_SLUG" \
    baseBranch="$SOLVE_FLEET_BASE_BRANCH" \
    branchPrefix="worktree-solve-issue-" \
    solveTimeoutS="${SOLVE_TIMEOUT:-3600}" \
    maxAgents="${UBERDEV_SOLVE_FLEET_MAX_AGENTS:-250}"

  echo "repo: $REPO_SLUG" >&2
  echo "prepared ${#ISSUE_NUMS[@]} issue(s) for the Workflow-native solver fleet (backend=workflow)" >&2
  echo "Relay the JSON between WORKFLOW_ARGS_BEGIN/WORKFLOW_ARGS_END verbatim into Workflow({scriptPath: \"$SOLVE_FLEET_WORKFLOW_JS\"}, <args>)." >&2
  echo "Progress is visible with /workflows — no separate agent surface to poll." >&2
  exit 0
fi

# Step 5b' — dispatch via the backend resolved by uberdev_dispatch_preflight.
# SAFE prompt passthrough only (--prompt-file / stdin / positional argv via
# bash array — see lib/dispatch.sh); never interpolate $PROMPT into a shell
# string and never eval. Dispatch is SERIAL within each wave by design (see
# GH_PARALLEL_CAP note + RFC 0012 §3.4 out-of-scope list).
TOTAL_ISSUES="${#ISSUE_NUMS[@]}"
WAVE_COUNT=$(( (TOTAL_ISSUES + MAX_PARALLEL_BG_AGENTS - 1) / MAX_PARALLEL_BG_AGENTS ))
for (( wave_index = 1; wave_index <= WAVE_COUNT; wave_index++ )); do
wave_start=$(( (wave_index - 1) * MAX_PARALLEL_BG_AGENTS ))
wave_end=$(( wave_start + MAX_PARALLEL_BG_AGENTS - 1 ))
(( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))
wave_size=$(( wave_end - wave_start + 1 ))
_uberdev_audit_emit solve_bg_fanout_wave_started \
  "{\"wave_index\":$wave_index,\"wave_size\":$wave_size}"
_widx="$wave_start"
# Subarray slice (offset:length) — shape shared with the historical fence
# (locked by tests/solve-pipeline-zsh.test.sh R4 fixtures).
for ISSUE_NUM in "${ISSUE_NUMS[@]:$wave_start:$wave_size}"; do
TIER="${TIERS[$_widx]}"
TITLE="${TITLES[$_widx]}"
UBERDEV_AGENT_PREPARED_REQUEST_JSON="${ROOT_REQUESTS[$_widx]}"
UBERDEV_AGENT_RISK_SIGNALS_JSON="${RISKS[$_widx]}"
UBERDEV_AGENT_WORKFLOW="$WORKFLOW"
UBERDEV_AGENT_TRIAGE_DECISION_JSON="${TRIAGE_DECISIONS[$_widx]}"
# Root carrier lineage `solve.lead.<tier>` (legacy catalog alias:
# `solve.issue.lead`). Descendant workflows inherit this closed,
# immutable pointer/hash tuple and use it to construct handoff JSON for
# uberdev_dispatch_child; they never reconstruct routing state from prose.
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B -c '
import json,sys
r=json.loads(sys.argv[1])
print(json.dumps({"schema_version":1,"run_id":r["run_id"],"workflow":r["workflow"],"issue_num":r["issue_num"],"context_file":r["context_file"],"context_sha256":r["context_sha256"]},sort_keys=True,separators=(",",":")),end="")
' "$UBERDEV_AGENT_PREPARED_REQUEST_JSON")" || { echo "error: failed to construct solve.lead.$TIER carrier" >&2; exit 2; }
UBERDEV_ROOT_EDGE_ID="solve.lead.$TIER"
export UBERDEV_AGENT_PREPARED_REQUEST_JSON UBERDEV_AGENT_RISK_SIGNALS_JSON UBERDEV_AGENT_WORKFLOW UBERDEV_AGENT_TRIAGE_DECISION_JSON UBERDEV_RUN_CARRIER_JSON UBERDEV_ROOT_EDGE_ID
_widx=$((_widx + 1))
# DISPATCH_RC + DISPATCH_ID are reset at the top of uberdev_dispatch_one
# (lib/dispatch.sh central SSOT reset) and documented always-set on return.
PROMPT_FILE="$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
uberdev_dispatch_one "$ISSUE_NUM" "$TIER" "$PROMPT_FILE"
unset UBERDEV_AGENT_PREPARED_REQUEST_JSON UBERDEV_RUN_CARRIER_JSON UBERDEV_ROOT_EDGE_ID
BG_DISPATCH_RC="$DISPATCH_RC"
BG_SESSION_ID="${DISPATCH_ID:-}"

if [[ "$BG_DISPATCH_RC" -eq 0 ]]; then
  UBERDEV_KEEP_TMPDIR=1
  # lib/dispatch.sh emitted agent_dispatched with the backend-specific id.
  SPAWNED+=("#$ISSUE_NUM ($TIER, ${UBERDEV_RESOLVED_BACKEND} ${BG_SESSION_ID:-?})")
else
  # lib/dispatch.sh exports DISPATCH_LOG on failure; tail it for the report.
  TAIL_OUTPUT="$(tail -3 "${DISPATCH_LOG:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
  DISPATCH_FAILED+=("#$ISSUE_NUM: ${TAIL_OUTPUT:-(no output captured; check ${DISPATCH_LOG:-the dispatch log})}")
  # --- Phase B: claim rollback on dispatch failure (v0.28.0) ---
  # Release the Step 4.5 claim so a retry (or a teammate) can pick the issue
  # up without --force. Fail-soft on every gh call. B3 ownership check: a
  # teammate may have raced in (most likely via --force) between our claim
  # and this rollback — re-fetch the latest marker-matched claim comment and
  # only roll back if it still names $DISPATCHER_USER; otherwise
  # conservative-skip with a warning (better a stuck label for the next
  # sweeper pass than stripping a live foreign claim).
  CLAIM_COMMENT_MARKER_PREFIX="${CLAIM_COMMENT_MARKER% v* -->}"
  CURRENT_CLAIM_USER="?"
  CURRENT_CLAIM_JSON=$(gh issue view "$ISSUE_NUM" --json comments 2>/dev/null) || CURRENT_CLAIM_JSON=""
  if [[ -n "$CURRENT_CLAIM_JSON" ]]; then
    CURRENT_CLAIM_BODY=$(jq -r --arg marker "$CLAIM_COMMENT_MARKER_PREFIX" \
      '[.comments[] | select(.body | contains($marker))] | last | .body // empty' \
      <<<"$CURRENT_CLAIM_JSON" 2>/dev/null)
    if [[ -n "$CURRENT_CLAIM_BODY" ]]; then
      CURRENT_CLAIM_USER=$(printf '%s\n' "$CURRENT_CLAIM_BODY" | grep -m1 '^User: ' | sed 's/^User: @//; s/^User: //' || echo "?")
    fi
  fi
  if [[ "$CURRENT_CLAIM_USER" != "$DISPATCHER_USER" ]]; then
    echo "warning: #$ISSUE_NUM: dispatch-failure rollback skipped — latest claim is owned by '$CURRENT_CLAIM_USER' (we are '$DISPATCHER_USER'); leaving label/assignee in place to avoid stripping a racing dispatcher's claim" >&2
    _uberdev_audit_emit claim_released \
      "{\"issue\":$ISSUE_NUM,\"reason\":\"dispatch_failure_rollback_skipped\",\"rc\":$BG_DISPATCH_RC,\"current_owner\":\"$CURRENT_CLAIM_USER\"}" || true
  else
    # Combined cleanup + canonical claim_released emit via the shared helper
    # (E3+S1). The release comment carries the CLAIM_COMMENT_MARKER
    # fingerprint so future claim-collision parsers see the release as the
    # latest claim event (missing field lines parse as "?" — semantically
    # correct: the claim is no longer held).
    _uberdev_release_claim "$ISSUE_NUM" "dispatch_failure" "\"rc\":$BG_DISPATCH_RC,\"user\":\"$DISPATCHER_USER\",\"host\":\"$DISPATCHER_HOST\""
    RELEASE_BODY="$(cat <<EOF
$CLAIM_COMMENT_MARKER
uberdev:active claim released — dispatch failed (rc=$BG_DISPATCH_RC)

User: @$DISPATCHER_USER
Host: $DISPATCHER_HOST
Branch: worktree-solve-issue-$ISSUE_NUM
Released: $(date -u +%FT%TZ)

The issue is unclaimed again — retry with /solve $ISSUE_NUM or /turbo $ISSUE_NUM.
EOF
)"
    printf '%s' "$RELEASE_BODY" | gh issue comment "$ISSUE_NUM" --body-file - >/dev/null 2>&1 || true
  fi
  rm -f "$UBERDEV_TMPDIR/solve-claim-$ISSUE_NUM.json"
fi
done
done

# Phase B per-issue dispatch failure summary — loud, never silent.
if [[ ${#DISPATCH_FAILED[@]} -gt 0 ]]; then
  echo "warning: ${#DISPATCH_FAILED[@]} of ${#ISSUE_NUMS[@]} dispatch(es) failed:" >&2
  printf '  - %s\n' "${DISPATCH_FAILED[@]}" >&2
fi

# ---------------------------------------------------------------------------
# Step 6 — final summary (single stderr emission; backend-aware monitoring
# pointer per RFC 0004 §3.10). Agent View status changes are passive UI state
# — never workflow triggers.
# ---------------------------------------------------------------------------
echo "repo: $REPO_SLUG" >&2
echo "dispatched ${#SPAWNED[@]} background session(s)" >&2
if [[ ${#SPAWNED[@]} -gt 0 ]]; then
  printf '  %s\n' "${SPAWNED[@]}" >&2
fi
# No default: an unresolved backend gets no monitoring line rather than a
# guess. The historical default here named the retired detached backend.
case "${UBERDEV_RESOLVED_BACKEND:-}" in
  wezterm)
    echo "The dispatched agents are running in WezTerm panes — switch to the WezTerm window to watch them live." >&2 ;;
  background)
    echo "The dispatched agents are detached background processes. Per-issue logs + status files:" >&2
    for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
      echo "  #$ISSUE_NUM: tail -f $UBERDEV_TMPDIR/solve-bg-stdout-$ISSUE_NUM.log   (exit code in $UBERDEV_TMPDIR/solve-bg-status-$ISSUE_NUM.json)" >&2
    done ;;
esac

exit 0
