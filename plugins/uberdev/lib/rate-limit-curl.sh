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
  # bypassed by varying the authority (#184). A non-zero rc (incl. python3 absent) or an
  # empty host means the URL has no usable host.
  local HOST
  if ! HOST="$(python3 "$_UBERDEV_RATE_LIMIT_LIBDIR/normalize_host.py" "$URL" 2>/dev/null)" || [ -z "$HOST" ]; then
    echo "rate-limit-curl: cannot parse host from URL: $URL" >&2
    return 2
  fi

  local HOST_DIR="$RATE_STATE_DIR/$HOST"
  mkdir -p "$HOST_DIR"
  local LOCK="$HOST_DIR/.lock"
  local STATE="$HOST_DIR/last_release"

  # mkdir-as-mutex (atomic across POSIX FS; no flock dependency).
  until mkdir "$LOCK" 2>/dev/null; do sleep 0.01; done
  trap 'rmdir "$LOCK" 2>/dev/null || true' RETURN

  local NOW_MS LAST_MS DELAY_S
  # GNU date supports %3N (ms); BSD date (macOS) silently emits literal "3N".
  # Fall back to python3 when output is not purely numeric (handles both EXIT-fail and quiet-misformat).
  NOW_MS="$(date +%s%3N 2>/dev/null || true)"
  if ! [[ "$NOW_MS" =~ ^[0-9]+$ ]]; then
    NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  fi
  LAST_MS="$(cat "$STATE" 2>/dev/null || echo 0)"
  # Defensive: corruption in state file -> re-pace from zero rather than crash on arithmetic.
  [[ "$LAST_MS" =~ ^[0-9]+$ ]] || LAST_MS=0
  # Per-call interval is 1000/RPS_CAP ms. Compute the delay in FLOAT (fold the division
  # into the awk math) so a non-integral 1000/RPS_CAP is not truncated before subtracting
  # the elapsed time. Integer truncation under-delays and exceeds the cap (#185, e.g.
  # cap=600 -> 1.667ms, not 1ms ~= 67% over). Sleep only when the float delay is > 0.
  DELAY_S="$(awk -v cap="$RPS_CAP" -v now="$NOW_MS" -v last="$LAST_MS" \
    'BEGIN{ d = (1000.0 / cap) - (now - last); if (d < 0) d = 0; printf "%.6f", d / 1000.0 }')"
  if awk -v s="$DELAY_S" 'BEGIN{ exit !(s > 0) }'; then
    sleep "$DELAY_S"
    # Advance the virtual release clock by the (float) interval so cumulative pacing stays
    # exact under back-to-back calls: release = max(now, last + interval). Round to integer
    # ms for the state file (a half-ms-conservative round only ever over-delays, staying
    # under the cap — the safe direction for a rate gate).
    NOW_MS="$(awk -v cap="$RPS_CAP" -v now="$NOW_MS" -v last="$LAST_MS" \
      'BEGIN{ rel = last + (1000.0 / cap); if (now > rel) rel = now; printf "%.0f", rel }')"
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
