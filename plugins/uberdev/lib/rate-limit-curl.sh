#!/usr/bin/env bash
# SOURCED, never executed. Source-time idempotent (mirrors dispatch.sh:20-23).
if [ "${_UBERDEV_RATE_LIMIT_LOADED:-0}" = "1" ]; then return 0 2>/dev/null || true; fi
_UBERDEV_RATE_LIMIT_LOADED=1

# uberdev_rate_limit_curl URL [curl-args...]
#
# Enforces $RPS_CAP (already validated at SKILL.md:104) for the host extracted
# from URL. State and lock live under $RATE_STATE_DIR/<host>/ (per-run, per-host).
#
# Algorithm: leaky-bucket with one bucket per host. Each call:
#   1. Extracts <host> from URL (scheme://host[:port]/path).
#   2. Acquires mkdir-mutex on $RATE_STATE_DIR/<host>/.lock (trap on RETURN releases).
#   3. Reads $RATE_STATE_DIR/<host>/last_release (epoch-ms, default 0).
#   4. Computes inter-call delay = max(0, (1000 / $RPS_CAP) - (now_ms - last_release_ms)).
#   5. If delay > 0, sleeps (`sleep "$delay_s"` where delay_s is delay/1000 with bc).
#   6. Writes now_ms to last_release atomically (mktemp + mv).
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
#   - URL parse fails (no scheme://host) -> exit 2 with stderr.

uberdev_rate_limit_curl() {
  local URL="$1"; shift
  [ -n "$URL" ] || { echo "rate-limit-curl: URL required" >&2; return 2; }
  [ -n "${RATE_STATE_DIR:-}" ] || { echo "rate-limit-curl: RATE_STATE_DIR unset" >&2; return 2; }
  [ -d "$RATE_STATE_DIR" ] || { echo "rate-limit-curl: $RATE_STATE_DIR missing" >&2; return 2; }
  [[ "${RPS_CAP:-}" =~ ^[1-9][0-9]*$ ]] || { echo "rate-limit-curl: RPS_CAP malformed" >&2; return 2; }
  [ "$RPS_CAP" -ge 1 ] && [ "$RPS_CAP" -le 1000 ] || { echo "rate-limit-curl: RPS_CAP out of range" >&2; return 2; }

  # Extract host (scheme://host[:port]/path -> host[:port]).
  local HOST
  HOST="$(printf '%s' "$URL" | sed -nE 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+).*$#\1#p')"
  [ -n "$HOST" ] || { echo "rate-limit-curl: cannot parse host from URL: $URL" >&2; return 2; }
  # Reject hosts that could escape per-host scoping via path traversal or
  # slash injection (the regex above filters `/?#` but allows `..`).
  case "$HOST" in
    *..* | */*) echo "rate-limit-curl: host contains path-escape characters: $HOST" >&2; return 2 ;;
  esac

  local HOST_DIR="$RATE_STATE_DIR/$HOST"
  mkdir -p "$HOST_DIR"
  local LOCK="$HOST_DIR/.lock"
  local STATE="$HOST_DIR/last_release"

  # mkdir-as-mutex (atomic across POSIX FS; no flock dependency).
  until mkdir "$LOCK" 2>/dev/null; do sleep 0.01; done
  trap 'rmdir "$LOCK" 2>/dev/null || true' RETURN

  local NOW_MS LAST_MS DELAY_MS DELAY_S
  # GNU date supports %3N (ms); BSD date (macOS) silently emits literal "3N".
  # Fall back to python3 when output is not purely numeric (handles both EXIT-fail and quiet-misformat).
  NOW_MS="$(date +%s%3N 2>/dev/null || true)"
  if ! [[ "$NOW_MS" =~ ^[0-9]+$ ]]; then
    NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  fi
  LAST_MS="$(cat "$STATE" 2>/dev/null || echo 0)"
  DELAY_MS=$(( (1000 / RPS_CAP) - (NOW_MS - LAST_MS) ))
  if [ "$DELAY_MS" -gt 0 ]; then
    DELAY_S="$(awk -v ms="$DELAY_MS" 'BEGIN{ printf "%.3f", ms/1000 }')"
    sleep "$DELAY_S"
    NOW_MS=$(( NOW_MS + DELAY_MS ))
  fi
  printf '%s' "$NOW_MS" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"

  rmdir "$LOCK" 2>/dev/null || true
  trap - RETURN

  # `--` before URL neutralises -fOJ / -X-prefixed URL smuggling (security IMPORTANT-1).
  command curl --fail-with-body --silent --show-error "$@" -- "$URL"
}
