#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
HELPER="$ROOT/plugins/uberdev/lib/child-receipts.py"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/child-dispatch-receipts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
umask 077

passes=0
pass() { printf '  PASS %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
assert_fails_cleanly() {
  local name="$1" expected="$2"; shift 2
  : >"$TMP/failure.out"; : >"$TMP/failure.err"
  if "$@" >"$TMP/failure.out" 2>"$TMP/failure.err"; then
    fail "$name" 'unexpected success'
  fi
  [ ! -s "$TMP/failure.out" ] || fail "$name" 'partial stdout escaped'
  grep -Fq "$expected" "$TMP/failure.err" || fail "$name" "missing error <$expected>: $(<"$TMP/failure.err")"
  ! grep -q 'Traceback (most recent call last)' "$TMP/failure.err" || fail "$name" 'Python traceback escaped'
  pass "$name"
}
assert_helper_fails_fixed() {
  local name="$1" expected="$2"; shift 2
  : >"$TMP/failure.out"; : >"$TMP/failure.err"
  if "$@" >"$TMP/failure.out" 2>"$TMP/failure.err"; then
    fail "$name" 'unexpected success'
  fi
  [ ! -s "$TMP/failure.out" ] || fail "$name" 'partial stdout escaped'
  [ "$(wc -l <"$TMP/failure.err" | tr -d ' ')" -eq 1 ] || fail "$name" "diagnostic was not one line: $(<"$TMP/failure.err")"
  [ "$(<"$TMP/failure.err")" = "uberdev child receipts: $expected" ] || \
    fail "$name" "unexpected diagnostic: $(<"$TMP/failure.err")"
  pass "$name"
}
private_file() {
  local directory="$1" file="$2"
  mkdir -p "$directory"
  chmod 700 "$directory"
  : >"$file"
  chmod 600 "$file"
}
append_event() {
  python3 -I -B "$HELPER" append "$@"
}

[ -r "$LIB" ] || fail 'runtime exists' "$LIB missing"
[ -r "$HELPER" ] || fail 'receipt helper exists' 'RED: child-receipts.py missing'
. "$LIB"

SOURCE_PATH='plugins/uberdev/skills/subagent-driven-dev/SKILL.md'
INPUT_FILE="$TMP/run/inputs/SENSITIVE-TASK-PATH.md"
FAILURE_FILE="$TMP/run/inputs/SENSITIVE-FAILURE-PATH.md"
mkdir -p "$(dirname "$INPUT_FILE")"
printf 'PROMPT-PAYLOAD-MUST-NOT-LEAK\n' >"$INPUT_FILE"
printf 'FAILURE-PAYLOAD-MUST-NOT-LEAK\n' >"$FAILURE_FILE"

# Receipt collection is inert unless all explicit receipt-mode variables are
# present. Legacy test-mode-only manifest tests remain valid and silent.
DISABLED_FILE="$TMP/disabled/receipts.jsonl"
private_file "$(dirname "$DISABLED_FILE")" "$DISABLED_FILE"
export UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$DISABLED_FILE"
unset UBERDEV_CHILD_TEST_MODE
uberdev_child_inputs_build sdd.task.implement \
  task_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$INPUT_FILE")" \
  working_dir "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TMP/run")" \
  allowed_paths "$(python3 -c 'import json,sys;print(json.dumps([sys.argv[1]]))' "$INPUT_FILE")" \
  denied_paths '[]' \
  failure_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FAILURE_FILE")" \
  attempt 1 >/dev/null
[ ! -s "$DISABLED_FILE" ] || fail 'disabled receipt mode' 'wrote without explicit test mode'
pass 'receipt mode is disabled without UBERDEV_CHILD_TEST_MODE=1'

unset UBERDEV_CHILD_TEST_SOURCE UBERDEV_CHILD_TEST_RECEIPT_FILE
export UBERDEV_CHILD_TEST_MODE=1
uberdev_child_inputs_build sdd.task.implement \
  task_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$INPUT_FILE")" \
  working_dir "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TMP/run")" \
  allowed_paths "$(python3 -c 'import json,sys;print(json.dumps([sys.argv[1]]))' "$INPUT_FILE")" \
  denied_paths '[]' \
  failure_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FAILURE_FILE")" \
  attempt 1 >/dev/null
pass 'legacy test mode without receipt variables remains silent and successful'

# Canonical input digests are stable across JSON whitespace/key order and the
# record contains identities plus the digest only.
DIRECT_FILE="$TMP/direct/receipts.jsonl"
private_file "$(dirname "$DIRECT_FILE")" "$DIRECT_FILE"
export UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$DIRECT_FILE"
CANONICAL='{"alpha":{"a":1,"b":2},"path":"/tmp/SUPER-SECRET-PATH","prompt":"DO-NOT-LEAK","zeta":[3,2,1]}'
NONCANONICAL='{ "zeta" : [3, 2, 1], "prompt":"DO-NOT-LEAK", "alpha":{"b":2,"a":1}, "path":"/tmp/SUPER-SECRET-PATH" }'
EXPECTED_SHA="$(printf '%s' "$CANONICAL" | shasum -a 256 | awk '{print $1}')"
append_event --event build --edge-id receipt.digest --inputs-json "$NONCANONICAL"
python3 -I -B - "$DIRECT_FILE" "$SOURCE_PATH" "$EXPECTED_SHA" <<'PY'
import json,pathlib,sys
rows=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(rows)==1
value=json.loads(rows[0])
assert value=={
    'schema_version':1,
    'event':'build',
    'source':sys.argv[2],
    'edge_id':'receipt.digest',
    'inputs_sha256':sys.argv[3],
}
PY
! grep -Fq 'DO-NOT-LEAK' "$DIRECT_FILE" || fail 'payload redaction' 'prompt value leaked'
! grep -Fq 'SUPER-SECRET-PATH' "$DIRECT_FILE" || fail 'payload redaction' 'path value leaked'
! grep -Fq '"inputs"' "$DIRECT_FILE" || fail 'payload redaction' 'raw inputs field leaked'
pass 'canonical SHA-256 event contains no raw input, prompt, or payload path'

# Partial or malformed receipt configuration and malformed events fail closed.
assert_fails_cleanly 'missing source fails closed' 'missing UBERDEV_CHILD_TEST_SOURCE' \
  env -u UBERDEV_CHILD_TEST_SOURCE UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_RECEIPT_FILE="$DIRECT_FILE" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.digest --inputs-json '{}'
assert_fails_cleanly 'missing receipt path fails closed' 'missing UBERDEV_CHILD_TEST_RECEIPT_FILE' \
  env -u UBERDEV_CHILD_TEST_RECEIPT_FILE UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.digest --inputs-json '{}'
for bad_source in '/absolute/source.md' '../escape.md' 'plugins/uberdev/skills/../escape.md' 'plugins\uberdev\skills\escape.md'; do
  assert_fails_cleanly "rejects malformed source $bad_source" 'invalid test source' \
    env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$bad_source" UBERDEV_CHILD_TEST_RECEIPT_FILE="$DIRECT_FILE" \
    python3 -I -B "$HELPER" append --event build --edge-id receipt.digest --inputs-json '{}'
done
assert_fails_cleanly 'rejects unknown event' 'invalid receipt event' \
  append_event --event launch --edge-id receipt.digest --inputs-json '{}'
assert_fails_cleanly 'build rejects an instance' 'build event must not include instance_id' \
  append_event --event build --edge-id receipt.digest --instance-id worker-1 --inputs-json '{}'
assert_fails_cleanly 'handoff requires an instance' 'handoff event requires instance_id' \
  append_event --event handoff --edge-id receipt.digest --inputs-json '{}'
assert_fails_cleanly 'rejects malformed edge' 'invalid edge_id' \
  append_event --event build --edge-id 'Bad Edge' --inputs-json '{}'
assert_fails_cleanly 'rejects malformed inputs JSON' 'invalid inputs JSON' \
  append_event --event build --edge-id receipt.digest --inputs-json '{'
assert_fails_cleanly 'rejects non-object inputs' 'inputs must be a JSON object' \
  append_event --event build --edge-id receipt.digest --inputs-json '[]'

# The append boundary accepts only a private, caller-owned, non-linked regular
# file in a private directory.
MISSING_FILE="$TMP/private-missing/receipts.jsonl"
mkdir -p "$(dirname "$MISSING_FILE")"; chmod 700 "$(dirname "$MISSING_FILE")"
assert_fails_cleanly 'rejects missing receipt file' 'unsafe receipt file' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$MISSING_FILE" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'

PUBLIC_DIR_FILE="$TMP/public-dir/receipts.jsonl"
private_file "$(dirname "$PUBLIC_DIR_FILE")" "$PUBLIC_DIR_FILE"; chmod 755 "$(dirname "$PUBLIC_DIR_FILE")"
assert_fails_cleanly 'rejects non-private receipt directory' 'unsafe receipt directory' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$PUBLIC_DIR_FILE" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'

PUBLIC_FILE="$TMP/public-file/receipts.jsonl"
private_file "$(dirname "$PUBLIC_FILE")" "$PUBLIC_FILE"; chmod 644 "$PUBLIC_FILE"
assert_fails_cleanly 'rejects non-private receipt file' 'unsafe receipt file' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$PUBLIC_FILE" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'

SYMLINK_TARGET="$TMP/symlink-target/target.jsonl"
SYMLINK_FILE="$TMP/symlink-file/receipts.jsonl"
private_file "$(dirname "$SYMLINK_TARGET")" "$SYMLINK_TARGET"
mkdir -p "$(dirname "$SYMLINK_FILE")"; chmod 700 "$(dirname "$SYMLINK_FILE")"
ln -s "$SYMLINK_TARGET" "$SYMLINK_FILE"
assert_fails_cleanly 'rejects symlink receipt file' 'unsafe receipt file' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$SYMLINK_FILE" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'
[ ! -s "$SYMLINK_TARGET" ] || fail 'symlink receipt target' 'target was modified'

REAL_PARENT="$TMP/real-parent"
LINK_PARENT="$TMP/link-parent"
private_file "$REAL_PARENT" "$REAL_PARENT/receipts.jsonl"
ln -s "$REAL_PARENT" "$LINK_PARENT"
assert_fails_cleanly 'rejects symlink receipt directory' 'unsafe receipt directory' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$LINK_PARENT/receipts.jsonl" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'

HARDLINK_DIR="$TMP/hardlink"
private_file "$HARDLINK_DIR" "$HARDLINK_DIR/original.jsonl"
ln "$HARDLINK_DIR/original.jsonl" "$HARDLINK_DIR/receipts.jsonl"
assert_fails_cleanly 'rejects hard-linked receipt file' 'unsafe receipt file' \
  env UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_TEST_SOURCE="$SOURCE_PATH" UBERDEV_CHILD_TEST_RECEIPT_FILE="$HARDLINK_DIR/receipts.jsonl" \
  python3 -I -B "$HELPER" append --event build --edge-id receipt.path --inputs-json '{}'

# Handoff-derived receipts accept only private immutable-workspace files. The
# parent is opened without symlink traversal and the handoff is opened relative
# to that descriptor so path replacement cannot swap the checked object.
SAFE_HANDOFF_DIR="$TMP/safe-handoff"
SAFE_HANDOFF="$SAFE_HANDOFF_DIR/handoff.json"
mkdir -p "$SAFE_HANDOFF_DIR"; chmod 700 "$SAFE_HANDOFF_DIR"
printf '%s\n' '{"edge_id":"receipt.security","instance_id":"worker-1","inputs":{"value":1}}' >"$SAFE_HANDOFF"
chmod 600 "$SAFE_HANDOFF"

PUBLIC_HANDOFF_FILE_DIR="$TMP/public-handoff-file"
PUBLIC_HANDOFF_FILE="$PUBLIC_HANDOFF_FILE_DIR/handoff.json"
mkdir -p "$PUBLIC_HANDOFF_FILE_DIR"; chmod 700 "$PUBLIC_HANDOFF_FILE_DIR"
cp "$SAFE_HANDOFF" "$PUBLIC_HANDOFF_FILE"; chmod 666 "$PUBLIC_HANDOFF_FILE"
assert_fails_cleanly 'rejects group/world-writable handoff file' 'unsafe handoff file' \
  python3 -I -B "$HELPER" append-handoff --event dispatch --edge-id receipt.security --handoff-file "$PUBLIC_HANDOFF_FILE"

PUBLIC_HANDOFF_DIR="$TMP/public-handoff-dir"
PUBLIC_DIR_HANDOFF="$PUBLIC_HANDOFF_DIR/handoff.json"
mkdir -p "$PUBLIC_HANDOFF_DIR"; chmod 777 "$PUBLIC_HANDOFF_DIR"
cp "$SAFE_HANDOFF" "$PUBLIC_DIR_HANDOFF"; chmod 600 "$PUBLIC_DIR_HANDOFF"
assert_fails_cleanly 'rejects handoff inside non-private directory' 'unsafe handoff directory' \
  python3 -I -B "$HELPER" append-handoff --event dispatch --edge-id receipt.security --handoff-file "$PUBLIC_DIR_HANDOFF"

REAL_HANDOFF_PARENT="$TMP/real-handoff-parent"
LINK_HANDOFF_PARENT="$TMP/link-handoff-parent"
mkdir -p "$REAL_HANDOFF_PARENT"; chmod 700 "$REAL_HANDOFF_PARENT"
cp "$SAFE_HANDOFF" "$REAL_HANDOFF_PARENT/handoff.json"; chmod 600 "$REAL_HANDOFF_PARENT/handoff.json"
ln -s "$REAL_HANDOFF_PARENT" "$LINK_HANDOFF_PARENT"
assert_fails_cleanly 'rejects handoff through symlink directory' 'unsafe handoff directory' \
  python3 -I -B "$HELPER" append-handoff --event dispatch --edge-id receipt.security --handoff-file "$LINK_HANDOFF_PARENT/handoff.json"

HARDLINK_HANDOFF_DIR="$TMP/hardlink-handoff"
mkdir -p "$HARDLINK_HANDOFF_DIR"; chmod 700 "$HARDLINK_HANDOFF_DIR"
cp "$SAFE_HANDOFF" "$HARDLINK_HANDOFF_DIR/original.json"; chmod 600 "$HARDLINK_HANDOFF_DIR/original.json"
ln "$HARDLINK_HANDOFF_DIR/original.json" "$HARDLINK_HANDOFF_DIR/handoff.json"
assert_fails_cleanly 'rejects hard-linked handoff file' 'unsafe handoff file' \
  python3 -I -B "$HELPER" append-handoff --event dispatch --edge-id receipt.security --handoff-file "$HARDLINK_HANDOFF_DIR/handoff.json"

# JSON and CLI diagnostics are closed single-line messages. Attacker-controlled
# keys or malformed content must never become terminal/log output.
DUPLICATE_INJECTION='{"line\nFORGED-LOG-LINE":1,"line\nFORGED-LOG-LINE":2}'
assert_helper_fails_fixed 'duplicate JSON key cannot inject a diagnostic line' 'duplicate inputs key' \
  append_event --event build --edge-id receipt.digest --inputs-json "$DUPLICATE_INJECTION"
MALFORMED_INJECTION=$'{"safe":1}\nFORGED-MALFORMED-LINE'
assert_helper_fails_fixed 'malformed JSON content is absent from diagnostics' 'invalid inputs JSON' \
  append_event --event build --edge-id receipt.digest --inputs-json "$MALFORMED_INJECTION"
assert_helper_fails_fixed 'malformed CLI arguments are a closed diagnostic' 'invalid receipt arguments' \
  python3 -I -B "$HELPER" $'invalid-command\nFORGED-ARGUMENT-LINE'

# A full real runtime path emits build -> handoff -> dispatch only after each
# production boundary succeeds. The provider stub observes dispatch already
# appended, proving it is immediately above the provider seam.
CHAIN_FILE="$TMP/chain/receipts.jsonl"
private_file "$(dirname "$CHAIN_FILE")" "$CHAIN_FILE"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$CHAIN_FILE"

make_context() {
  local run="$1" run_id="$2" request decision metadata
  mkdir -p "$run"
  request="$(python3 -I -B - "$run" "$run_id" <<'PY'
import json,sys
run,run_id=sys.argv[1:]
print(json.dumps({'schema_version':1,'run_dir':run,'run_id':run_id,'repository_id':'fixture-repository','backend':'codex','workflow':'solve','phase':'lead','role':'lead','task_tier':'medium','risk_signals':[],'issue_or_pr':42,'issue_num':42,'capacity':4,'timeout_s':20,'routing_mode':'adaptive'},separators=(',',':')))
PY
)"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(python3 -I -B - "$run_id" <<'PY'
import json,sys
print(json.dumps({'run_id':sys.argv[1],'repository_id':'fixture-repository','workflow':'solve','backend':'codex','issue_num':42,'task_tier':'medium','risk_signals':[]},separators=(',',':')))
PY
)"
  uberdev_agent_context_create "$run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-11T00:00:00Z'
}

CTX_OUT="$(make_context "$TMP/run" receipt-root)"
CTX="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"],end="")' "$CTX_OUT")"
CTX_SHA="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"],end="")' "$CTX_OUT")"
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B - "$CTX" "$CTX_SHA" <<'PY'
import json,sys
print(json.dumps({'schema_version':1,'run_id':'receipt-root','workflow':'solve','issue_num':42,'context_file':sys.argv[1],'context_sha256':sys.argv[2]},separators=(',',':')))
PY
)"
export UBERDEV_RUN_CARRIER_JSON

# Failed builder and failed handoff operations must not leave a receipt.
assert_fails_cleanly 'failed builder emits no build receipt' 'missing required inputs' \
  uberdev_child_inputs_build sdd.task.implement attempt 1
[ ! -s "$CHAIN_FILE" ] || fail 'failed builder receipt' 'receipt emitted on builder failure'
pass 'failed builder leaves receipt stream empty'

INPUTS_JSON="$(uberdev_child_inputs_build sdd.task.implement \
  task_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$INPUT_FILE")" \
  working_dir "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TMP/run")" \
  allowed_paths "$(python3 -c 'import json,sys;print(json.dumps([sys.argv[1]]))' "$INPUT_FILE")" \
  denied_paths '[]' \
  failure_path "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FAILURE_FILE")" \
  attempt 1)"
[ "$(wc -l <"$CHAIN_FILE" | tr -d ' ')" -eq 1 ] || fail 'successful build receipt' 'expected exactly one event'
assert_fails_cleanly 'failed handoff emits no handoff receipt' 'invalid_identity' \
  uberdev_create_child_handoff sdd.task.implement 'bad instance' "$INPUTS_JSON" '[]'
[ "$(wc -l <"$CHAIN_FILE" | tr -d ' ')" -eq 1 ] || fail 'failed handoff receipt' 'unexpected event appended'
pass 'failed handoff leaves only the successful build event'

INSTANCE_ID='receipt-worker-1'
uberdev_create_child_handoff sdd.task.implement "$INSTANCE_ID" "$INPUTS_JSON" '[]' >/dev/null
[ "$(wc -l <"$CHAIN_FILE" | tr -d ' ')" -eq 2 ] || fail 'successful handoff receipt' 'expected build and handoff events'

PROVIDER_CALLED=0
uberdev_agent_dispatch() {
  PROVIDER_CALLED=1
  python3 -I -B - "$CHAIN_FILE" "$SOURCE_PATH" "$INSTANCE_ID" <<'PY'
import json,pathlib,sys
last=json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
assert last['event']=='dispatch' and last['source']==sys.argv[2] and last['instance_id']==sys.argv[3]
PY
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"receipt-provider"}\n' >"$4"
  chmod 600 "$4"
}

assert_fails_cleanly 'failed prepare emits no dispatch receipt' 'caller_path_mismatch' \
  uberdev_dispatch_child sdd.task.implement "$UBERDEV_CHILD_HANDOFF" "$TMP/outside/result.md" "$UBERDEV_CHILD_STATUS"
[ "$(wc -l <"$CHAIN_FILE" | tr -d ' ')" -eq 2 ] || fail 'failed prepare receipt' 'dispatch emitted before prepare succeeded'
[ "$PROVIDER_CALLED" -eq 0 ] || fail 'failed prepare provider seam' 'provider was called'
pass 'prepare failure stops before dispatch receipt and provider seam'

uberdev_dispatch_child sdd.task.implement "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" >/dev/null
[ "$PROVIDER_CALLED" -eq 1 ] || fail 'provider seam ordering' 'provider was not called'
python3 -I -B - "$CHAIN_FILE" "$SOURCE_PATH" "$INSTANCE_ID" "$INPUTS_JSON" <<'PY'
import hashlib,json,pathlib,sys
path,source,instance,inputs_raw=sys.argv[1:]
rows=[json.loads(line) for line in pathlib.Path(path).read_text().splitlines()]
assert [row['event'] for row in rows]==['build','handoff','dispatch'],rows
canonical=json.dumps(json.loads(inputs_raw),sort_keys=True,separators=(',',':')).encode()
digest=hashlib.sha256(canonical).hexdigest()
for row in rows:
    expected={'schema_version','event','source','edge_id','inputs_sha256'}
    if row['event']!='build': expected.add('instance_id')
    assert set(row)==expected,row
    assert row['source']==source and row['edge_id']=='sdd.task.implement'
    assert row['inputs_sha256']==digest
    if row['event']!='build': assert row['instance_id']==instance
raw=pathlib.Path(path).read_text()
for secret in ('SENSITIVE-TASK-PATH','SENSITIVE-FAILURE-PATH','PROMPT-PAYLOAD','FAILURE-PAYLOAD'):
    assert secret not in raw
PY
pass 'real production boundaries emit one correlated build -> handoff -> dispatch chain in seam order'

# A malformed handoff cannot be converted into a receipt record.
MALFORMED_HANDOFF="$TMP/malformed-handoff.json"
printf '%s' $'{"safe":1}\nFORGED-HANDOFF-LOG-LINE' >"$MALFORMED_HANDOFF"; chmod 600 "$MALFORMED_HANDOFF"
assert_helper_fails_fixed 'malformed handoff event is a closed diagnostic' 'invalid handoff JSON' \
  python3 -I -B "$HELPER" append-handoff --event dispatch --edge-id sdd.task.implement --handoff-file "$MALFORMED_HANDOFF"

# Concurrent writers each issue one bounded O_APPEND write; every resulting
# line must remain a complete, independently parseable JSON object.
CONCURRENT_FILE="$TMP/concurrent/receipts.jsonl"
private_file "$(dirname "$CONCURRENT_FILE")" "$CONCURRENT_FILE"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$CONCURRENT_FILE"
pids=()
for index in {1..64}; do
  append_event --event handoff --edge-id receipt.concurrent --instance-id "worker-$index" --inputs-json "$NONCANONICAL" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
python3 -I -B - "$CONCURRENT_FILE" "$EXPECTED_SHA" <<'PY'
import json,pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_bytes()
assert raw.endswith(b'\n')
lines=raw.splitlines(); assert len(lines)==64,len(lines)
rows=[json.loads(line) for line in lines]
assert {row['instance_id'] for row in rows}=={f'worker-{i}' for i in range(1,65)}
for row in rows:
    assert set(row)=={'schema_version','event','source','edge_id','instance_id','inputs_sha256'}
    assert row['event']=='handoff' and row['edge_id']=='receipt.concurrent'
    assert row['inputs_sha256']==sys.argv[2]
PY
grep -q 'os.O_APPEND' "$HELPER" || fail 'append implementation' 'O_APPEND missing'
grep -q 'os.write' "$HELPER" || fail 'append implementation' 'single os.write append missing'
pass '64 concurrent O_APPEND records remain complete single-write JSONL objects'

printf 'child-dispatch-receipts: %d assertions passed\n' "$passes"
