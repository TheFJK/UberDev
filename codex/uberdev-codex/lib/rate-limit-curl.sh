#!/usr/bin/env bash
# SOURCED, never executed. Source-time idempotent (mirrors dispatch.sh:20-23).
# DUAL-SHELL: persona agents (and the lib/rl-curl shim) source this under bash
# OR zsh — the Claude Code Bash tool runs /bin/zsh on macOS. Two zsh traps are
# handled explicitly below (#306 / RFC 0012 §3.10 testers-R2):
#   - BASH_SOURCE is unset in zsh -> ${(%):-%x} prompt-escape fallback;
#   - `trap ... RETURN` is an "undefined signal" error in zsh (the trap never
#     installs) -> the mkdir-mutex is released EXPLICITLY on every return path.
if [ "${_UBERDEV_RATE_LIMIT_LOADED:-0}" = "1" ]; then return 0 2>/dev/null || true; fi
_UBERDEV_RATE_LIMIT_LOADED=1

# Absolute dir of this lib so the wrapper can find its sibling normalize_host.py — the
# SINGLE SOURCE OF TRUTH for per-host bucket keys, shared with lib/rate-cap-audit.sh.
# ${BASH_SOURCE[0]:-${(%):-%x}} resolves the sourced-file path in BOTH shells:
# bash leaves the default unevaluated (BASH_SOURCE[0] is set when sourced, and
# bash 3.2/5.x only expand `:-` defaults lazily); zsh has no BASH_SOURCE and
# falls through to the %x prompt escape (file containing the executing code).
_UBERDEV_RATE_LIMIT_SELF="${BASH_SOURCE[0]:-${(%):-%x}}"
_UBERDEV_RATE_LIMIT_LIBDIR="$(CDPATH= cd -- "$(dirname -- "$_UBERDEV_RATE_LIMIT_SELF")" 2>/dev/null && pwd)"

# uberdev_rate_limit_curl URL [curl-args...]
#
# Enforces $RPS_CAP (already validated by the caller in SKILL.md before export) for the host extracted
# from URL. State and lock live under $RATE_STATE_DIR/<host>/ (per-run, per-host).
#
# Algorithm: serial gate with per-host bucket (mutex held during sleep — trades
# concurrency for simplicity; under N-agent contention real RPS is bounded but
# tail latency rises). Each call:
#   1. Normalizes <host> from URL via the shared normalize_host.py (lowercases; strips
#      userinfo + :port; drops a trailing dot) so a@host / Host / host:443 / host. all
#      share ONE bucket — the per-host cap can't be bypassed by varying the authority.
#   2. Acquires mkdir-mutex on $RATE_STATE_DIR/<host>/.lock (bounded retry; released
#      explicitly on every return path — never via `trap RETURN`, which zsh rejects).
#   3. Reads $RATE_STATE_DIR/<host>/last_release (epoch-ms, default 0).
#   4. Computes inter-call delay (FLOAT) = max(0, (1000 / $RPS_CAP) - (now_ms - last_ms)).
#   5. If delay > 0, sleeps (`sleep "$delay_s"` where delay_s is delay/1000 via awk).
#   6. Writes now_ms to last_release atomically (tmp + mv), failing loud if the write fails.
#   7. Releases mutex.
#   8. Execs `command curl --fail-with-body --silent --show-error <args> -- "$URL"`.
#
# Failure modes:
#   - $RATE_STATE_DIR unset or not writable -> error to stderr, exit 2.
#   - $RPS_CAP unset, non-integer, or out of [1, 1000] -> defensive re-validation;
#     wrapper does NOT trust the env var since it could be re-injected mid-session.
#     On bad value, exit 2.
#   - mkdir-mutex contention -> retry every 10ms, BOUNDED at UBERDEV_RATE_MUTEX_MAX_TRIES
#     (default 6000 ~= 60s). Legit contention is small (max 6 agents per host, each
#     holding the lock for at most one ~1s pacing sleep); a leaked/stale .lock from a
#     killed caller therefore fails LOUD with exit 2 instead of spinning forever.
#   - URL parse fails (no host, or scope-escape host) -> exit 2 with stderr.
#   - state-file write fails (full disk / RO fs) -> exit 2 with stderr (never silent).

uberdev_rate_limit_curl() {
  local URL="$1"; shift
  [ -n "$URL" ] || { echo "rate-limit-curl: URL required" >&2; return 2; }
  [ -n "${RATE_STATE_DIR:-}" ] || { echo "rate-limit-curl: RATE_STATE_DIR unset" >&2; return 2; }
  [ -d "$RATE_STATE_DIR" ] || { echo "rate-limit-curl: $RATE_STATE_DIR missing" >&2; return 2; }
  [[ "${RPS_CAP:-}" =~ ^[1-9][0-9]*$ ]] || { echo "rate-limit-curl: RPS_CAP malformed" >&2; return 2; }
  [ "$RPS_CAP" -le 1000 ] || { echo "rate-limit-curl: RPS_CAP out of range" >&2; return 2; }

  # Normalize the host via the shared single-source-of-truth parser (sibling
  # normalize_host.py, also imported by rate-cap-audit.sh). It lowercases, strips
  # userinfo + :port, drops a trailing dot, and rejects scope-escape hosts (`..`/`/`) —
  # so a@host / Host / host:443 / host. all map to ONE bucket and the cap can't be
  # bypassed by varying the authority (#184).
  [ -n "$_UBERDEV_RATE_LIMIT_LIBDIR" ] && [ -f "$_UBERDEV_RATE_LIMIT_LIBDIR/normalize_host.py" ] || {
    echo "rate-limit-curl: normalize_host.py not found (lib dir: ${_UBERDEV_RATE_LIMIT_LIBDIR:-unset})" >&2; return 2; }
  local HOST HOST_RC=0
  HOST="$(python3 "$_UBERDEV_RATE_LIMIT_LIBDIR/normalize_host.py" "$URL" 2>/dev/null)" || HOST_RC=$?
  # normalize_host.py contract: rc 0 + nonempty host = ok; rc 3 = URL has no usable host.
  # Any OTHER rc (python3 absent, import/runtime error) is a TOOL failure — surface it
  # distinctly so it is never silently mistaken for a bad URL (fail loud, mirrors #188).
  if [ "$HOST_RC" -ne 0 ] && [ "$HOST_RC" -ne 3 ]; then
    echo "rate-limit-curl: host normalizer failed (python3 rc=$HOST_RC) for URL: $URL" >&2; return 2
  fi
  [ "$HOST_RC" -eq 0 ] && [ -n "$HOST" ] || { echo "rate-limit-curl: cannot parse host from URL: $URL" >&2; return 2; }

  local HOST_DIR="$RATE_STATE_DIR/$HOST"
  mkdir -p "$HOST_DIR"
  local LOCK="$HOST_DIR/.lock"
  local STATE="$HOST_DIR/last_release"

  # mkdir-as-mutex (atomic across POSIX FS; no flock dependency). BOUNDED retry:
  # a stale .lock left by a killed holder must fail loud, not spin forever. The
  # default 6000 tries x 10ms ~= 60s sits far above worst-case legit contention
  # (<=6 personas serialised behind a <=1s pacing sleep each); tests lower it
  # via UBERDEV_RATE_MUTEX_MAX_TRIES (positive integer; malformed -> default).
  local MUTEX_TRIES=0 MUTEX_MAX="${UBERDEV_RATE_MUTEX_MAX_TRIES:-6000}"
  [[ "$MUTEX_MAX" =~ ^[1-9][0-9]*$ ]] || MUTEX_MAX=6000
  until mkdir "$LOCK" 2>/dev/null; do
    MUTEX_TRIES=$((MUTEX_TRIES + 1))
    if [ "$MUTEX_TRIES" -ge "$MUTEX_MAX" ]; then
      echo "rate-limit-curl: could not acquire mutex $LOCK after $MUTEX_MAX attempts — stale lock from a killed caller? rmdir it to recover" >&2
      return 2
    fi
    sleep 0.01
  done
  # NO `trap ... RETURN` here: zsh rejects RETURN as an undefined signal, so the
  # trap never installs and the mutex would leak on any early return — making
  # the next caller's mutex loop spin until its retry bound. Every return path
  # past this point MUST `rmdir "$LOCK"` explicitly first.

  local NOW_MS LAST_MS DELAY_S RELEASE_MS SLEPT
  # GNU date supports %3N (ms); BSD date (macOS) silently emits literal "3N".
  # Fall back to python3 when output is not purely numeric (handles both EXIT-fail and quiet-misformat).
  NOW_MS="$(date +%s%3N 2>/dev/null || true)"
  if ! [[ "$NOW_MS" =~ ^[0-9]+$ ]]; then
    NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  fi
  LAST_MS="$(cat "$STATE" 2>/dev/null || echo 0)"
  # Defensive: corruption in state file -> re-pace from zero rather than crash on arithmetic.
  [[ "$LAST_MS" =~ ^[0-9]+$ ]] || LAST_MS=0
  # Per-call interval is 1000/RPS_CAP ms. ONE awk pass computes everything in FLOAT (the division
  # folded in) so a non-integral 1000/RPS_CAP is not truncated before subtracting the elapsed time —
  # integer truncation under-delays and exceeds the cap (#185, e.g. cap=600 -> 1.667ms not 1ms,
  # ~67% over). It emits three fields: sleep seconds, the rounded release timestamp, and a 0/1 sleep
  # flag (awk owns the float `> 0` test, so the shell never mis-reads "0.000000" as truthy).
  # release = max(now, last + interval) keeps cumulative pacing exact under back-to-back calls; %.0f
  # is round-half-to-even (can land ~0.5ms either side) but the max(now, ...) re-syncs to the real
  # clock next call, so sub-ms rounding never accumulates into a cap violation.
  read -r DELAY_S RELEASE_MS SLEPT <<EOF
$(awk -v cap="$RPS_CAP" -v now="$NOW_MS" -v last="$LAST_MS" 'BEGIN{
  interval = 1000.0 / cap
  d = interval - (now - last); if (d < 0) d = 0
  rel = last + interval; if (now > rel) rel = now
  printf "%.6f %.0f %d", d / 1000.0, rel, (d > 0)
}')
EOF
  if [ "$SLEPT" -eq 1 ]; then
    sleep "$DELAY_S"
    NOW_MS="$RELEASE_MS"
  fi
  # Persist the release timestamp atomically. Check the write rc and fail LOUD: a swallowed
  # failure (full disk / RO fs / lost permission) leaves a stale timestamp that the next call
  # re-paces from, silently corrupting the rate gate while the caller keeps requesting (#188).
  if ! { printf '%s' "$NOW_MS" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"; }; then
    rm -f "$STATE.tmp" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true  # explicit release — no RETURN trap (dead in zsh)
    echo "rate-limit-curl: failed to persist rate state to $STATE (refusing to proceed with stale pacing)" >&2
    return 2
  fi

  rmdir "$LOCK" 2>/dev/null || true

  # `--` before URL neutralises -fOJ / -X-prefixed URL smuggling (security IMPORTANT-1).
  command curl --fail-with-body --silent --show-error "$@" -- "$URL"
}
