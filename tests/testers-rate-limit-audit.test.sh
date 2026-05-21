#!/usr/bin/env bash
# Tests: lib/rate-cap-audit.sh — post-hoc audit of wave-N.yaml RPS.
# Cases: 8 (breach synthesises critical), 9 (clean run), 10 (per-host scoping).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILS=0
pass() { printf '  ok %s\n' "$1"; }
fail() { printf '  FAIL %s: %s\n' "$1" "${2:-}"; FAILS=$((FAILS+1)); }

test_audit_synthesises_critical_on_breach() {
  WAVE="$TEST_TMPDIR/wave-breach.yaml"
  # 20 requests to api.example.test within a 1-second window; cap=10
  python3 - "$WAVE" <<'EOF'
import yaml, sys
base = 1763729400000  # epoch-ms
findings = []
for i in range(20):
    findings.append({
        "id": f"f{i}",
        "severity": "high",
        "persona": "adversarial_security",
        "evidence": {
            "network_request": {
                "url": "https://api.example.test/probe",
                "method": "GET",
                "status": 200,
                "timestamp": base + i * 40  # 25 rps actual
            }
        }
    })
with open(sys.argv[1], "w") as fh:
    yaml.safe_dump({"findings": findings}, fh)
EOF
  OUT="$TEST_TMPDIR/wave-breach.audited.yaml"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-cap-audit.sh"
  uberdev_rate_cap_audit "$WAVE" 10 "$OUT" && { fail "$FUNCNAME" "expected exit 1"; return; }
  rc=$?
  [ "$rc" -eq 1 ] || { fail "$FUNCNAME" "expected exit 1, got $rc"; return; }
  grep -q "invariant_violated: polite_rate_cap" "$OUT" || { fail "$FUNCNAME" "no polite_rate_cap in output"; return; }
  grep -q "severity: critical" "$OUT" || { fail "$FUNCNAME" "no critical severity"; return; }
  grep -q "api.example.test" "$OUT" || { fail "$FUNCNAME" "host missing"; return; }
  pass "$FUNCNAME"
}
test_audit_synthesises_critical_on_breach

test_audit_clean_run_emits_no_finding() {
  WAVE="$TEST_TMPDIR/wave-clean.yaml"
  # 5 requests at 200ms intervals = 5 rps; cap=10 → no breach
  python3 - "$WAVE" <<'EOF'
import yaml, sys
base = 1763729400000
findings = [{
    "id": f"f{i}",
    "severity": "low",
    "persona": "power_user",
    "evidence": {"network_request": {
        "url": "https://api.example.test/x",
        "method": "GET", "status": 200,
        "timestamp": base + i * 200
    }}
} for i in range(5)]
with open(sys.argv[1], "w") as fh:
    yaml.safe_dump({"findings": findings}, fh)
EOF
  OUT="$TEST_TMPDIR/wave-clean.audited.yaml"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-cap-audit.sh"
  uberdev_rate_cap_audit "$WAVE" 10 "$OUT"
  rc=$?
  [ "$rc" -eq 0 ] || { fail "$FUNCNAME" "expected exit 0, got $rc"; return; }
  grep -q "polite_rate_cap" "$OUT" && { fail "$FUNCNAME" "unexpected polite_rate_cap finding"; return; }
  pass "$FUNCNAME"
}
test_audit_clean_run_emits_no_finding

test_audit_per_host_scoping_no_breach() {
  WAVE="$TEST_TMPDIR/wave-scoping.yaml"
  # 10 requests to host-a + 10 to host-b within 1s; cap=15. Each host = 10, below cap.
  python3 - "$WAVE" <<'EOF'
import yaml, sys
base = 1763729400000
findings = []
for i in range(10):
    findings.append({"id": f"a{i}", "severity": "low", "persona": "a11y",
                     "evidence": {"network_request": {
                         "url": "https://host-a.test/x", "method": "GET", "status": 200,
                         "timestamp": base + i * 50}}})
for i in range(10):
    findings.append({"id": f"b{i}", "severity": "low", "persona": "chaos",
                     "evidence": {"network_request": {
                         "url": "https://host-b.test/y", "method": "GET", "status": 200,
                         "timestamp": base + i * 50}}})
with open(sys.argv[1], "w") as fh:
    yaml.safe_dump({"findings": findings}, fh)
EOF
  OUT="$TEST_TMPDIR/wave-scoping.audited.yaml"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-cap-audit.sh"
  uberdev_rate_cap_audit "$WAVE" 15 "$OUT"
  rc=$?
  [ "$rc" -eq 0 ] || { fail "$FUNCNAME" "expected exit 0 (per-host scoping), got $rc"; return; }
  grep -q "polite_rate_cap" "$OUT" && { fail "$FUNCNAME" "unexpected breach finding"; return; }
  pass "$FUNCNAME"
}
test_audit_per_host_scoping_no_breach

exit "$FAILS"
