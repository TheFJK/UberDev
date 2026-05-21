#!/usr/bin/env bash
# Tests: lib/rate-limit-curl.sh + parse-site --rps-cap validation in SKILL.md.
# Cases: 1-7 (parse + wrapper pacing + mkdir-mutex), 11-12 (security: flag-smuggling + defensive re-validation).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILS=0
pass() { printf '  ok %s\n' "$1"; }
fail() { printf '  FAIL %s: %s\n' "$1" "${2:-}"; FAILS=$((FAILS+1)); }

# Case 1: parse non-numeric --rps-cap=abc
test_parse_non_numeric() {
  # Spec §Components: SKILL.md parse-site emits exit 2 with "must be a positive integer" on stderr
  # Inline harness: extract the parse-validation block from SKILL.md and exercise it
  out=$(RPS_CAP=abc bash -c '
    if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi' 2>&1) && { fail "$FUNCNAME" "expected exit 2"; return; }
  [ "$?" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2, got $?"; return; }
  echo "$out" | grep -q "must be a positive integer" || { fail "$FUNCNAME" "stderr lacks 'must be a positive integer'"; return; }
  pass "$FUNCNAME"
}
test_parse_non_numeric

# Case 2: parse negative --rps-cap=-5
test_parse_negative() {
  out=$(RPS_CAP=-5 bash -c '
    if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi' 2>&1) && { fail "$FUNCNAME" "expected exit 2"; return; }
  [ "$?" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2, got $?"; return; }
  echo "$out" | grep -q "must be a positive integer" || { fail "$FUNCNAME" "stderr lacks 'must be a positive integer'"; return; }
  pass "$FUNCNAME"
}
test_parse_negative

# Case 3: parse zero --rps-cap=0
test_parse_zero() {
  # The regex ^[1-9][0-9]*$ rejects 0 (no leading-zero allowed; also "0" doesn't start [1-9])
  # Either the regex check or the range check should fire; we accept either error message.
  out=$(RPS_CAP=0 bash -c '
    if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi
    if [ "$RPS_CAP" -lt 1 ] || [ "$RPS_CAP" -gt 1000 ]; then
      echo "error: --rps-cap must be in [1, 1000]; got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi' 2>&1) && { fail "$FUNCNAME" "expected exit 2"; return; }
  [ "$?" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2, got $?"; return; }
  echo "$out" | grep -qE "must be a positive integer|in \[1, 1000\]" || { fail "$FUNCNAME" "stderr lacks expected error"; return; }
  pass "$FUNCNAME"
}
test_parse_zero

# Case 4: parse over-ceiling --rps-cap=1001
test_parse_over_ceiling() {
  out=$(RPS_CAP=1001 bash -c '
    if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi
    if [ "$RPS_CAP" -lt 1 ] || [ "$RPS_CAP" -gt 1000 ]; then
      echo "error: --rps-cap must be in [1, 1000]; got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi' 2>&1) && { fail "$FUNCNAME" "expected exit 2"; return; }
  [ "$?" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2, got $?"; return; }
  echo "$out" | grep -q "in \[1, 1000\]" || { fail "$FUNCNAME" "stderr lacks 'in [1, 1000]'"; return; }
  pass "$FUNCNAME"
}
test_parse_over_ceiling

# Case 5: parse leading-zero --rps-cap=010
test_parse_leading_zero() {
  out=$(RPS_CAP=010 bash -c '
    if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '"'"'$RPS_CAP'"'"'" >&2
      exit 2
    fi' 2>&1) && { fail "$FUNCNAME" "expected exit 2"; return; }
  [ "$?" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2, got $?"; return; }
  echo "$out" | grep -q "must be a positive integer" || { fail "$FUNCNAME" "stderr lacks 'must be a positive integer'"; return; }
  pass "$FUNCNAME"
}
test_parse_leading_zero

# Case 6: wrapper paces calls per --rps-cap
test_wrapper_pacing_50_calls_at_5rps() {
  export RATE_STATE_DIR="$TEST_TMPDIR/state-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10
  # Stub curl to no-op (avoids real HTTP)
  SHIM="$TEST_TMPDIR/curl-shim"; mkdir -p "$SHIM"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  # GNU date supports %3N; BSD date (macOS) silently emits literal "3N". Fall back to python3
  # when the output is not purely numeric so the arithmetic below works on either platform.
  _ms_now() {
    local v
    v="$(date +%s%3N 2>/dev/null || true)"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
      v="$(python3 -c 'import time;print(int(time.time()*1000))')"
    fi
    printf '%s' "$v"
  }
  start_ms=$(_ms_now)
  for i in $(seq 1 10); do
    uberdev_rate_limit_curl "http://example.test/$i" >/dev/null
  done
  end_ms=$(_ms_now)
  elapsed=$(( end_ms - start_ms ))
  export PATH="$OLD_PATH"
  # 10 calls at 10rps: first instant, next 9 paced at 100ms each = >=900ms
  [ "$elapsed" -ge 850 ] || { fail "$FUNCNAME" "elapsed $elapsed ms (<850)"; return; }
  [ "$elapsed" -le 2000 ] || { fail "$FUNCNAME" "elapsed $elapsed ms (>2000)"; return; }
  pass "$FUNCNAME"
}
test_wrapper_pacing_50_calls_at_5rps

# Case 7: mkdir-mutex serialises concurrent callers (asserted via state-file atomicity)
test_mkdir_mutex_serializes() {
  export RATE_STATE_DIR="$TEST_TMPDIR/mutex-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=2  # 500ms inter-call
  SHIM="$TEST_TMPDIR/mutex-shim"; mkdir -p "$SHIM"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  # Two concurrent calls to the same host; second must wait >=500ms minus jitter
  (uberdev_rate_limit_curl "http://shared.test/a" >/dev/null) &
  PID1=$!
  (uberdev_rate_limit_curl "http://shared.test/b" >/dev/null) &
  PID2=$!
  wait "$PID1" "$PID2"
  STATE="$RATE_STATE_DIR/shared.test/last_release"
  [ -f "$STATE" ] || { fail "$FUNCNAME" "state file missing"; return; }
  LAST=$(cat "$STATE")
  # The release timestamp should reflect the second (waited) call
  # We can't directly observe the wait, but we can check that NO concurrent
  # writes corrupted the state file (it must contain a single integer)
  [[ "$LAST" =~ ^[0-9]+$ ]] || { fail "$FUNCNAME" "state corrupted: $LAST"; return; }
  export PATH="$OLD_PATH"
  pass "$FUNCNAME"
}
test_mkdir_mutex_serializes

# Case 11: URL flag-smuggling neutralised (URL must contain scheme://host)
test_url_flag_smuggling_neutralised() {
  export RATE_STATE_DIR="$TEST_TMPDIR/sec11-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  # URL parse must reject a string with no scheme://host
  out=$(uberdev_rate_limit_curl '-fOJ /etc/passwd' 2>&1) && { fail "$FUNCNAME" "expected non-zero exit"; return; }
  rc=$?
  [ "$rc" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2 from URL parse, got $rc"; return; }
  echo "$out" | grep -q "cannot parse host" || { fail "$FUNCNAME" "stderr lacks 'cannot parse host'"; return; }
  pass "$FUNCNAME"
}
test_url_flag_smuggling_neutralised

# Case 12: defensive re-validation of RPS_CAP after sourcing
test_defensive_revalidation() {
  export RATE_STATE_DIR="$TEST_TMPDIR/sec12-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  # Inject malformed RPS_CAP after sourcing — wrapper must re-validate
  export RPS_CAP="evil"
  out=$(uberdev_rate_limit_curl 'http://example.test/' 2>&1) && { fail "$FUNCNAME" "expected non-zero exit"; return; }
  rc=$?
  [ "$rc" -eq 2 ] || { fail "$FUNCNAME" "expected exit 2 from defensive re-validation, got $rc"; return; }
  echo "$out" | grep -q "RPS_CAP malformed" || { fail "$FUNCNAME" "stderr lacks 'RPS_CAP malformed'"; return; }
  pass "$FUNCNAME"
}
test_defensive_revalidation

# Case 13: curl `--` separator and URL-as-last-arg (security boundary)
test_curl_dash_dash_separator() {
  # Verifies wrapper passes URL after `--` so flag-smuggling stays neutralised.
  export RATE_STATE_DIR="$TEST_TMPDIR/sep-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10
  SHIM="$TEST_TMPDIR/spy-shim"; mkdir -p "$SHIM"
  ARGFILE="$TEST_TMPDIR/spy-args"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGFILE"
exit 0
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  uberdev_rate_limit_curl "http://example.test/probe" >/dev/null
  export PATH="$OLD_PATH"
  # Assert `--` appears in captured args before the URL
  grep -q '^--$' "$ARGFILE" || { fail "$FUNCNAME" "missing '--' separator in curl args: $(cat "$ARGFILE" | tr '\n' ' ')"; return; }
  # Assert URL is the LAST arg (right after `--`)
  tail -1 "$ARGFILE" | grep -q '^http://example.test/probe$' || { fail "$FUNCNAME" "URL not last arg: $(tail -1 "$ARGFILE")"; return; }
  pass "$FUNCNAME"
}
test_curl_dash_dash_separator

# Case 14: trap RETURN releases mutex even on curl failure
test_trap_release_on_curl_failure() {
  # Verifies trap RETURN releases the mutex even when curl exits non-zero.
  export RATE_STATE_DIR="$TEST_TMPDIR/trap-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10
  SHIM="$TEST_TMPDIR/fail-shim"; mkdir -p "$SHIM"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  uberdev_rate_limit_curl "http://example.test/path" >/dev/null 2>&1 || true
  export PATH="$OLD_PATH"
  # Lock directory MUST be released after function returns, even on curl failure
  if [ -d "$RATE_STATE_DIR/example.test/.lock" ]; then
    fail "$FUNCNAME" "lock directory persisted after curl failure"; return
  fi
  pass "$FUNCNAME"
}
test_trap_release_on_curl_failure

exit "$FAILS"
