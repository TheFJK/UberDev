#!/usr/bin/env bash
# Post-hoc audit of observed RPS in a wave-N.yaml. Reads findings[].evidence
# .network_request.timestamp + .url; groups by host; computes the max rolling
# 1-second observed RPS per host; emits a critical finding if cap is exceeded.
#
# Invoked by aggregate.py after the per-wave merge, before write.

set -eu

uberdev_rate_cap_audit() {
  local WAVE_YAML="$1" CAP="$2" OUT_YAML="$3"
  python3 - "$WAVE_YAML" "$CAP" "$OUT_YAML" <<'PY'
import sys, yaml, hashlib
from collections import defaultdict
wave_path, cap_str, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
cap = int(cap_str)
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
    except Exception:
        continue
    # Extract host
    import re
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/?#]+)", url)
    if not m:
        continue
    host = m.group(1)
    by_host[host].append((ts_ms, f.get("persona") or "unknown", url))
# For each host, compute the max rolling 1-second window count
breaches = []
for host, events in by_host.items():
    events.sort(key=lambda x: x[0])
    max_in_window = 0
    window_start = 0
    for i, (ts, _, _) in enumerate(events):
        # Advance window_start while events[window_start] < ts - 1000
        while window_start < i and events[window_start][0] < ts - 1000:
            window_start += 1
        count = i - window_start + 1
        if count > max_in_window:
            max_in_window = count
    if max_in_window > cap:
        # Find the persona breakdown in the offending window
        offenders = [e[1] for e in events[-max_in_window:]]
        breaches.append((host, max_in_window, offenders))
# Synthesise critical findings for each breach
for host, observed, offenders in breaches:
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
                f"{e[0]} ms: {e[1]} -> {e[2]}" for e in events[-observed:]
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
