#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/child-inputs.XXXXXX")"
FIXTURE="$TMP/manifest.json"
MALFORMED_FIXTURE="$TMP/malformed.json"
INVALID_UTF8_FIXTURE="$TMP/invalid-encoding.json"
SYMLINK_FIXTURE="$FIXTURE.link"
trap 'rm -rf "$TMP"' EXIT

MAX_SERIALIZED_BYTES="$(python3 -I -B - "$TREE" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as stream:
    manifest=json.load(stream)
limits=manifest.get("input_limits")
limit=limits.get("max_serialized_bytes") if isinstance(limits,dict) else None
if type(limit) is not int or not 0 < limit < 65_536:
    raise SystemExit("child-inputs: invalid canonical input limit contract")
print(limit,end="")
PY
)"

cat >"$FIXTURE" <<JSON
{"input_limits":{"max_serialized_bytes":${MAX_SERIALIZED_BYTES}},"edges":{"all.types":{"kind":"provider","retry":{"format":1},"required_inputs":{"attempt":"integer","enabled":"boolean","name":"string","file":"path","workdir":"directory","tags":"string_array","files":"path_array"},"optional_inputs":{"note":"optional_string","maybe_file":"optional_path","maybe_files":"optional_path_array","format_retry":"boolean","format_example_path":"path"}},"no.retry":{"kind":"provider","required_inputs":{},"optional_inputs":{"format_retry":"boolean","format_example_path":"path"}},"bad.retry.keys":{"kind":"provider","retry":{"format":1},"required_inputs":{},"optional_inputs":{"format_retry":"boolean"}},"skill.edge":{"kind":"skill","required_inputs":{},"optional_inputs":{}}}}
JSON

export UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$FIXTURE"
. "$LIB"

passes=0
pass() { printf '  PASS %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
assert_eq() { [ "$2" = "$3" ] || fail "$1" "expected <$3>, got <$2>"; pass "$1"; }
assert_fails_cleanly() {
  local name="$1" expected_error="$2"; shift 2
  : >"$TMP/out"; : >"$TMP/err"
  if "$@" >"$TMP/out" 2>"$TMP/err"; then fail "$name" 'unexpected success'; fi
  [ ! -s "$TMP/out" ] || fail "$name" 'partial stdout escaped on failure'
  [ -s "$TMP/err" ] || fail "$name" 'stderr was empty'
  ! grep -q 'Traceback (most recent call last)' "$TMP/err" || fail "$name" 'Python traceback escaped'
  grep -Fq "$expected_error" "$TMP/err" || fail "$name" "stderr missed <$expected_error>: $(<"$TMP/err")"
  pass "$name"
}

valid_args=(
  attempt 7 enabled true name '"alpha"' file '"/tmp/input"'
  workdir '"/tmp/work"' tags '["one","two"]' files '[]'
  note '""' maybe_file '""' maybe_files '[]'
)
expected='{"attempt":7,"enabled":true,"file":"/tmp/input","files":[],"maybe_file":"","maybe_files":[],"name":"alpha","note":"","tags":["one","two"],"workdir":"/tmp/work"}'
extra_inputs="$(python3 -I -B - "$expected" <<'PY'
import json,sys
value=json.loads(sys.argv[1]); value['extra']=1
print(json.dumps(value,sort_keys=True,separators=(',',':')))
PY
)"
duplicate_inputs='{"attempt":7,"enabled":true,"file":"/tmp/input","files":[],"maybe_file":"","maybe_files":[],"name":"alpha","name":"second","note":"","tags":["one","two"],"workdir":"/tmp/work"}'

actual="$(uberdev_child_inputs_build all.types "${valid_args[@]}")"
assert_eq 'build parses values and emits compact canonical JSON' "$actual" "$expected"
actual="$(uberdev_child_inputs_validate all.types "$expected")"
assert_eq 'validate returns the canonical object' "$actual" "$expected"

assert_fails_cleanly 'build rejects duplicate keys' 'duplicate input key: name' uberdev_child_inputs_build all.types "${valid_args[@]}" name '"second"'
assert_fails_cleanly 'build rejects malformed JSON values' 'invalid value for attempt JSON' uberdev_child_inputs_build all.types attempt nope
assert_fails_cleanly 'build rejects an incomplete key/value pair' 'input arguments must be KEY JSON_VALUE pairs' uberdev_child_inputs_build all.types attempt
assert_fails_cleanly 'build validates required keys before output' 'missing required inputs:' uberdev_child_inputs_build all.types attempt 7
assert_fails_cleanly 'validate rejects non-object JSON' 'child inputs must be a JSON object' uberdev_child_inputs_validate all.types '[]'
assert_fails_cleanly 'validate rejects missing keys' 'missing required inputs:' uberdev_child_inputs_validate all.types '{"attempt":7}'
assert_fails_cleanly 'validate rejects extra keys' 'undeclared inputs: extra' uberdev_child_inputs_validate all.types "$extra_inputs"
assert_fails_cleanly 'validate rejects duplicate keys in raw JSON' 'duplicate JSON key: name' uberdev_child_inputs_validate all.types "$duplicate_inputs"
assert_fails_cleanly 'validate rejects undeclared edges' 'undeclared provider edge: absent.edge' uberdev_child_inputs_validate absent.edge '{}'
assert_fails_cleanly 'validate rejects non-provider edges' 'undeclared provider edge: skill.edge' uberdev_child_inputs_validate skill.edge '{}'

for spec in \
  'attempt|true' \
  'enabled|1' \
  'name|""' \
  'file|""' \
  'workdir|""' \
  'tags|[""]' \
  'tags|[1]' \
  'files|[""]' \
  'files|[1]' \
  'note|1' \
  'maybe_file|1' \
  'maybe_files|[""]'; do
  key="${spec%%|*}"; value="${spec#*|}"
  invalid="$(python3 -I -B - "$expected" "$key" "$value" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); obj[sys.argv[2]]=json.loads(sys.argv[3])
print(json.dumps(obj,separators=(',',':')))
PY
)"
  case "$key" in
    attempt) expected_error='input attempt must be an integer' ;;
    enabled) expected_error='input enabled must be a boolean' ;;
    name) expected_error='input name must be a non-empty string' ;;
    file) expected_error='input file must be a non-empty path' ;;
    workdir) expected_error='input workdir must be a non-empty directory' ;;
    tags) expected_error='input tags must be an array of non-empty strings' ;;
    files) expected_error='input files must be an array of non-empty strings' ;;
    note) expected_error='input note must be a string' ;;
    maybe_file) expected_error='input maybe_file must be a string' ;;
    maybe_files) expected_error='input maybe_files must be an array of non-empty strings' ;;
  esac
  assert_fails_cleanly "type validation rejects $key=$value" "$expected_error" uberdev_child_inputs_validate all.types "$invalid"
done

retry="$(uberdev_child_inputs_format_retry all.types "$expected" /tmp/example.md)"
expected_retry="$(python3 -I -B - "$expected" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); obj.update(format_retry=True,format_example_path='/tmp/example.md')
print(json.dumps(obj,sort_keys=True,separators=(',',':')))
PY
)"
preexisting_retry="$(python3 -I -B - "$expected" <<'PY'
import json,sys
value=json.loads(sys.argv[1]); value['format_retry']=False
print(json.dumps(value,sort_keys=True,separators=(',',':')))
PY
)"
preexisting_example="$(python3 -I -B - "$expected" <<'PY'
import json,sys
value=json.loads(sys.argv[1]); value['format_example_path']='/tmp/old'
print(json.dumps(value,sort_keys=True,separators=(',',':')))
PY
)"
assert_eq 'format retry adds exactly the declared boolean and path' "$retry" "$expected_retry"
assert_fails_cleanly 'format retry rejects preexisting format_retry' 'base inputs already contain format retry keys' uberdev_child_inputs_format_retry all.types "$preexisting_retry" /tmp/example.md
assert_fails_cleanly 'format retry rejects preexisting format_example_path' 'base inputs already contain format retry keys' uberdev_child_inputs_format_retry all.types "$preexisting_example" /tmp/example.md
assert_fails_cleanly 'format retry requires retry.format=1' 'edge does not declare one format retry: no.retry' uberdev_child_inputs_format_retry no.retry '{}' /tmp/example.md
assert_fails_cleanly 'format retry requires both optional keys' 'edge has invalid format retry inputs: bad.retry.keys' uberdev_child_inputs_format_retry bad.retry.keys '{}' /tmp/example.md
assert_fails_cleanly 'format retry revalidates its non-empty example path' 'input format_example_path must be a non-empty path' uberdev_child_inputs_format_retry all.types "$expected" ''

printf '%s' '{"edges":{"bad.schema":{"kind":"provider","required_inputs":{"value":[]},"optional_inputs":{}}}}' >"$MALFORMED_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$MALFORMED_FIXTURE"
assert_fails_cleanly 'array-valued manifest types fail without a traceback' 'unsupported input schema for edge: bad.schema' uberdev_child_inputs_validate bad.schema '{"value":"x"}'

printf '\377' >"$INVALID_UTF8_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$INVALID_UTF8_FIXTURE"
assert_fails_cleanly 'invalid manifest encoding fails without a traceback' 'cannot read child manifest:' uberdev_child_inputs_validate bad.schema '{}'

ln -s "$FIXTURE" "$SYMLINK_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$SYMLINK_FIXTURE"
assert_fails_cleanly 'test manifest override rejects a symlink candidate' 'unsafe child manifest override' uberdev_child_inputs_validate all.types "$expected"

canonical_manifest="$_UBERDEV_CHILD_ROOT/policy/solve-run-tree-v1.json"
unset UBERDEV_CHILD_MANIFEST_PATH
canonical="$(uberdev_child_inputs_build brainstorm.research.codebase \
  working_dir '"/tmp/work"' summary_path '"/tmp/summary"' question '"why"')"
assert_eq 'canonical manifest is resolved internally' "$canonical" '{"question":"why","summary_path":"/tmp/summary","working_dir":"/tmp/work"}'
export UBERDEV_CHILD_MANIFEST_PATH="$FIXTURE"
[ -f "$canonical_manifest" ] || fail 'canonical manifest exists' "$canonical_manifest missing"
pass 'canonical manifest exists'

printf 'child-inputs: %d assertions passed\n' "$passes"
