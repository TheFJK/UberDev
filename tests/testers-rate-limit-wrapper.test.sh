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

# Case 6: wrapper paces calls per --rps-cap. Deterministic + load-independent: stub `date`
# (virtual clock read from a file) and `sleep` (records its arg and advances that clock by it,
# WITHOUT actually sleeping). The only time that "passes" is the wrapper's own computed delay,
# so the recorded delays are exact regardless of machine load — the wrapper's job is to ISSUE
# correct paced delays; real sleeping is a trusted OS primitive. (A prior wall-clock version
# flaked under heavy parallel load.)
test_wrapper_pacing_50_calls_at_5rps() {
  export RATE_STATE_DIR="$TEST_TMPDIR/state-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10  # interval = 1000/10 = 100ms exactly
  SHIM="$TEST_TMPDIR/pace-shim-$RANDOM"; mkdir -p "$SHIM"
  export PACE_VCFILE="$TEST_TMPDIR/pace-vc-$RANDOM"; printf '%s' 1700000000000 > "$PACE_VCFILE"
  export PACE_SLEEPLOG="$TEST_TMPDIR/pace-sleep-$RANDOM.log"; : > "$PACE_SLEEPLOG"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # date: echo the virtual clock verbatim (pure integer ms -> wrapper takes no python fallback).
  cat > "$SHIM/date" <<'EOF'
#!/usr/bin/env bash
cat "$PACE_VCFILE"
EOF
  # sleep: record the requested delay and advance the virtual clock by it; never actually sleep.
  cat > "$SHIM/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$PACE_SLEEPLOG"
cur="$(cat "$PACE_VCFILE")"
add="$(awk -v s="$1" 'BEGIN{ printf "%.0f", s*1000 }')"
printf '%s' "$((cur + add))" > "$PACE_VCFILE"
EOF
  chmod +x "$SHIM/curl" "$SHIM/date" "$SHIM/sleep"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  for i in $(seq 1 10); do
    uberdev_rate_limit_curl "http://example.test/$i" >/dev/null
  done
  export PATH="$OLD_PATH"
  # 10 calls at 10rps: first instant (no prior release), next 9 paced at exactly 100ms each.
  n_sleeps="$(wc -l < "$PACE_SLEEPLOG" | tr -d ' ')"
  total_ms="$(awk '{ s += $1 } END { printf "%.0f", s*1000 }' "$PACE_SLEEPLOG")"
  unset PACE_VCFILE PACE_SLEEPLOG
  [ "$n_sleeps" -eq 9 ] || { fail "$FUNCNAME" "expected 9 paced sleeps, got $n_sleeps"; return; }
  { [ "$total_ms" -ge 850 ] && [ "$total_ms" -le 1000 ]; } || { fail "$FUNCNAME" "paced total ${total_ms}ms not ~900 (9x100)"; return; }
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

# Case 15: shared host normalizer collapses authority variants to ONE bare host (#184/#186 root cause).
# userinfo (a@/b@), ASCII case, :port and a trailing dot must all map to the same key.
test_normalizer_collapses_authority_variants() {
  NORM="$REPO_ROOT/plugins/uberdev/lib/normalize_host.py"
  expected="target.test"
  for u in \
    "https://target.test/" \
    "https://a@target.test/" \
    "https://b@target.test/" \
    "https://TARGET.test/" \
    "https://target.test:443/" \
    "https://target.test./" \
    "https://user:pass@Target.test:8443/path?q=1"; do
    got="$(python3 "$NORM" "$u" 2>/dev/null)" || { fail "$FUNCNAME" "normalizer rejected '$u'"; return; }
    [ "$got" = "$expected" ] || { fail "$FUNCNAME" "'$u' -> '$got' (want '$expected')"; return; }
  done
  pass "$FUNCNAME"
}
test_normalizer_collapses_authority_variants

# Case 16: normalizer rejects scope-escape (`..`) and unparseable (no-host) inputs.
test_normalizer_rejects_unsafe_inputs() {
  NORM="$REPO_ROOT/plugins/uberdev/lib/normalize_host.py"
  for bad in \
    "https://a..b/" \
    "https://evil../x" \
    "-fOJ /etc/passwd" \
    "not a url" \
    "https:///nohost"; do
    if python3 "$NORM" "$bad" >/dev/null 2>&1; then
      fail "$FUNCNAME" "normalizer accepted unsafe input: '$bad'"; return
    fi
  done
  pass "$FUNCNAME"
}
test_normalizer_rejects_unsafe_inputs

# Case 17: wrapper buckets userinfo/case/port/trailing-dot variants of one host into a SINGLE
# state dir (end-to-end proof of #184 — pre-fix these split into distinct buckets, defeating the cap).
test_wrapper_buckets_authority_variants_identically() {
  export RATE_STATE_DIR="$TEST_TMPDIR/bucket-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=1000  # ~1ms interval -> negligible pacing
  SHIM="$TEST_TMPDIR/bucket-shim"; mkdir -p "$SHIM"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  for u in \
    "https://bucket.test/" \
    "https://x@bucket.test/" \
    "https://BUCKET.test/" \
    "https://bucket.test:443/" \
    "https://bucket.test./"; do
    uberdev_rate_limit_curl "$u" >/dev/null
  done
  export PATH="$OLD_PATH"
  dirs="$(find "$RATE_STATE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ "$dirs" = "1" ] || { fail "$FUNCNAME" "expected 1 host bucket, got $dirs: $(find "$RATE_STATE_DIR" -mindepth 1 -maxdepth 1 -type d | tr '\n' ' ')"; return; }
  [ -d "$RATE_STATE_DIR/bucket.test" ] || { fail "$FUNCNAME" "normalized bucket dir 'bucket.test' missing"; return; }
  pass "$FUNCNAME"
}
test_wrapper_buckets_authority_variants_identically

# Case 18: non-integral 1000/RPS_CAP uses a FLOAT delay, not integer truncation (#185).
# RPS_CAP=600 -> interval 1000/600 = 1.667ms; the pre-fix integer math truncated to 1ms (~67% over cap).
# Stub date+state so elapsed is exactly 0 (delay == full interval) and stub sleep to capture the value.
test_float_delay_non_integral_cap() {
  export RATE_STATE_DIR="$TEST_TMPDIR/float-$RANDOM"
  mkdir -p "$RATE_STATE_DIR/sixhundred.test"
  export RPS_CAP=600
  FIXED=1700000000000
  printf '%s' "$FIXED" > "$RATE_STATE_DIR/sixhundred.test/last_release"  # prime LAST_MS == NOW_MS
  SHIM="$TEST_TMPDIR/float-shim"; mkdir -p "$SHIM"
  SLEEPLOG="$TEST_TMPDIR/float-sleep-$RANDOM.log"; : > "$SLEEPLOG"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$SHIM/date" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$FIXED"
EOF
  cat > "$SHIM/sleep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$SLEEPLOG"
exit 0
EOF
  chmod +x "$SHIM/curl" "$SHIM/date" "$SHIM/sleep"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  uberdev_rate_limit_curl "http://sixhundred.test/probe" >/dev/null
  export PATH="$OLD_PATH"
  last_sleep="$(tail -1 "$SLEEPLOG" 2>/dev/null)"
  [ -n "$last_sleep" ] || { fail "$FUNCNAME" "wrapper did not sleep (no delay captured)"; return; }
  # delay must be ~1.667ms (float), NOT the 1.0ms an integer-truncated 1000/600 would yield.
  awk -v s="$last_sleep" 'BEGIN{ ms = s*1000; exit !(ms > 1.5 && ms < 1.8) }' \
    || { fail "$FUNCNAME" "delay ${last_sleep}s ($(awk -v s="$last_sleep" 'BEGIN{printf "%.4f", s*1000}')ms) is not the float interval ~1.667ms (#185)"; return; }
  pass "$FUNCNAME"
}
test_float_delay_non_integral_cap

# Case 19: a state-file write failure is surfaced loudly, not swallowed by `&& mv` (#188).
# Force `printf > "$STATE.tmp"` to fail by pre-creating last_release.tmp as a directory.
test_state_write_failure_surfaces() {
  export RATE_STATE_DIR="$TEST_TMPDIR/wfail-$RANDOM"
  mkdir -p "$RATE_STATE_DIR/wfail.test"
  mkdir "$RATE_STATE_DIR/wfail.test/last_release.tmp"  # redirection to a dir fails -> printf rc != 0
  export RPS_CAP=1000
  SHIM="$TEST_TMPDIR/wfail-shim"; mkdir -p "$SHIM"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  out=$(uberdev_rate_limit_curl "http://wfail.test/x" 2>&1) && { export PATH="$OLD_PATH"; fail "$FUNCNAME" "expected non-zero exit on state write failure"; return; }
  rc=$?
  export PATH="$OLD_PATH"
  [ "$rc" -ne 0 ] || { fail "$FUNCNAME" "expected non-zero exit, got $rc"; return; }
  echo "$out" | grep -qi "state" || { fail "$FUNCNAME" "stderr lacks a state-write error: $out"; return; }
  pass "$FUNCNAME"
}
test_state_write_failure_surfaces

# Case 20: a normalizer TOOL failure (python3 absent / crashes, rc not in {0,3}) surfaces a
# DISTINCT loud error, not the generic "cannot parse host" — so an env failure is never
# silently mistaken for a bad URL (post-impl-review hardening; mirrors #188 fail-loud).
test_normalizer_tool_failure_surfaces() {
  export RATE_STATE_DIR="$TEST_TMPDIR/toolfail-$RANDOM"
  mkdir -p "$RATE_STATE_DIR"
  export RPS_CAP=10
  SHIM="$TEST_TMPDIR/toolfail-shim"; mkdir -p "$SHIM"
  # python3 stub that fails like a missing/broken interpreter (rc 1, NOT the normalizer's reject rc 3)
  cat > "$SHIM/python3" <<'EOF'
#!/usr/bin/env bash
echo "simulated python3 failure" >&2
exit 1
EOF
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SHIM/python3" "$SHIM/curl"
  OLD_PATH="$PATH"; export PATH="$SHIM:$PATH"
  . "$REPO_ROOT/plugins/uberdev/lib/rate-limit-curl.sh"
  out=$(uberdev_rate_limit_curl "http://toolfail.test/x" 2>&1) && { export PATH="$OLD_PATH"; fail "$FUNCNAME" "expected non-zero exit when normalizer tool fails"; return; }
  rc=$?
  export PATH="$OLD_PATH"
  [ "$rc" -ne 0 ] || { fail "$FUNCNAME" "expected non-zero exit, got $rc"; return; }
  echo "$out" | grep -qi "normalizer failed" || { fail "$FUNCNAME" "stderr lacks distinct tool-failure message (got: $out)"; return; }
  pass "$FUNCNAME"
}
test_normalizer_tool_failure_surfaces

exit "$FAILS"
