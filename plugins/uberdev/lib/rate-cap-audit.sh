#!/usr/bin/env bash
# Post-hoc audit of observed RPS in a wave-N.yaml. Reads findings[].evidence
# .network_request.timestamp + .url; groups by host; computes the max rolling
# 1-second observed RPS per host; emits a critical finding if cap is exceeded.
#
# Invoked by aggregate.py after the per-wave merge, before write.

set -eu

uberdev_rate_cap_audit() {
  local WAVE_YAML="$1" CAP="$2" OUT_YAML="$3"
  # Absolute dir of this lib so the embedded python can import the shared host normalizer
  # (normalize_host.py — the same single source of truth the runtime wrapper uses).
  local LIBDIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # Fail loud if the shared normalizer can't be located — an empty LIBDIR would otherwise
  # `sys.path.insert(0, "")` (cwd) and silently import the wrong module or raise a cryptic
  # ImportError inside the heredoc.
  if [ -z "$LIBDIR" ] || [ ! -f "$LIBDIR/normalize_host.py" ]; then
    echo "error: rate-cap-audit: normalize_host.py not found (lib dir: ${LIBDIR:-unset})" >&2
    return 2
  fi
  python3 - "$WAVE_YAML" "$CAP" "$OUT_YAML" "$LIBDIR" <<'PY'
import sys, yaml, hashlib
from collections import defaultdict
wave_path, cap_str, out_path, libdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Import the canonical host normalizer (the same one lib/rate-limit-curl.sh calls) so the
# audit groups observed requests by the SAME bare host the runtime cap buckets on — else a
# host split across userinfo/case/port/trailing-dot variants evades the audit too (#186).
sys.path.insert(0, libdir)
from normalize_host import normalize_host
# Validate the cap to [1, 1000] like the runtime wrapper (rate-limit-curl.sh:44-45). The
# caller (aggregate.py) only enforces type=int, so cap<=0 would flag every request (1 > 0)
# and a non-numeric cap would raise an uncaught ValueError -> cryptic traceback (#187).
# Fail loud with a clear message and a non-zero exit instead.
try:
    cap = int(cap_str)
except (TypeError, ValueError):
    print(f"error: rate-cap-audit: --rps-cap must be an integer; got {cap_str!r}", file=sys.stderr)
    sys.exit(2)
if cap < 1 or cap > 1000:
    print(f"error: rate-cap-audit: --rps-cap must be in [1, 1000]; got {cap}", file=sys.stderr)
    sys.exit(2)
with open(wave_path) as fh:
    doc = yaml.safe_load(fh) or {}
findings = doc.get("findings") or []
# (host, ts_ms) tuples grouped by host
by_host = defaultdict(list)  # host -> [(ts_ms, persona, url), ...]
for f in findings:
    ev = (f.get("evidence") or {})
    nr = (ev.get("network_request") or {})
    url = nr.get("url"); ts = nr.get("timestamp")
    if not url or not ts:
        continue
    # Parse timestamp: epoch-seconds float, epoch-ms int, or ISO 8601 string
    try:
        if isinstance(ts, (int, float)):
            ts_ms = int(ts * 1000) if ts < 1e12 else int(ts)
        else:
            from datetime import datetime
            ts_ms = int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception as e:
        print(f"warning: rate-cap-audit skipping finding {f.get('id', '?')!r} with unparseable timestamp {ts!r}: {e}", file=sys.stderr)
        continue
    host = normalize_host(url)  # shared canonical normalizer (see import above) — #186
    if host is None:
        continue
    by_host[host].append((ts_ms, f.get("persona") or "unknown", url))
# For each host, compute the max rolling 1-second window count
breaches = []
for host, events in by_host.items():
    events.sort(key=lambda x: x[0])
    max_in_window = 0
    breach_start = 0
    breach_end = 0
    window_start = 0
    for i, (ts, _, _) in enumerate(events):
        # Advance window_start while events[window_start] < ts - 1000
        while window_start < i and events[window_start][0] < ts - 1000:
            window_start += 1
        count = i - window_start + 1
        if count > max_in_window:
            max_in_window = count
            breach_start = window_start
            breach_end = i
    if max_in_window > cap:
        # Slice the actual breach window — events[-max_in_window:] is wrong
        # when the breach is not at the tail of the events list.
        window_events = events[breach_start:breach_end + 1]
        offenders = [e[1] for e in window_events]
        breaches.append((host, max_in_window, offenders, window_events))
for host, observed, offenders, window_events in breaches:
    fid_seed = f"polite_rate_cap::{host}::{observed}"
    fid = hashlib.sha256(fid_seed.encode()).hexdigest()[:16]
    findings.append({
        "id": fid,
        "severity": "critical",
        "persona": "monitor_primary",
        "location": host,
        "invariant_violated": "polite_rate_cap",
        "summary": f"--rps-cap={cap} exceeded (observed {observed} rps)",
        "detail": (
            f"Per-host rolling 1-second RPS for {host} reached {observed}, "
            f"exceeding configured cap of {cap}. Offending personas: "
            f"{', '.join(sorted(set(offenders)))}."
        ),
        "evidence": {
            "repro_steps": [
                f"{e[0]} ms: {e[1]} -> {e[2]}" for e in window_events
            ],
            "observed": f"{observed} req/s for host {host}",
            "expected": f"≤ {cap} req/s per host",
        },
        "confidence": "high",
    })
doc["findings"] = findings
with open(out_path, "w") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
# Exit 1 if any breach was synthesised so the caller can fail the run
sys.exit(1 if breaches else 0)
PY
}
