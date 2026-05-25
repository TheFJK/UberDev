#!/usr/bin/env bash
# SOURCED, never executed. Source-time idempotent (mirrors dispatch.sh:20-23).
if [ "${_UBERDEV_RATE_LIMIT_LOADED:-0}" = "1" ]; then return 0 2>/dev/null || true; fi
_UBERDEV_RATE_LIMIT_LOADED=1

# Absolute dir of this lib so the wrapper can find its sibling normalize_host.py — the
# SINGLE SOURCE OF TRUTH for per-host bucket keys, shared with lib/rate-cap-audit.sh.
_UBERDEV_RATE_LIMIT_LIBDIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

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
#   2. Acquires mkdir-mutex on $RATE_STATE_DIR/<host>/.lock (trap on RETURN releases).
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
#   - mkdir-mutex contention -> retry every 10ms with no upper bound (per-host buckets
#     mean contention is bounded by the number of agents hitting the same host, max 6).
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

  # mkdir-as-mutex (atomic across POSIX FS; no flock dependency).
  until mkdir "$LOCK" 2>/dev/null; do sleep 0.01; done
  trap 'rmdir "$LOCK" 2>/dev/null || true' RETURN

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
    echo "rate-limit-curl: failed to persist rate state to $STATE (refusing to proceed with stale pacing)" >&2
    return 2  # RETURN trap releases the mutex
  fi

  rmdir "$LOCK" 2>/dev/null || true
  trap - RETURN

  # `--` before URL neutralises -fOJ / -X-prefixed URL smuggling (security IMPORTANT-1).
  command curl --fail-with-body --silent --show-error "$@" -- "$URL"
}
