#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
FIXTURE="$(mktemp "$ROOT/tests/_fixtures/child-inputs-manifest.XXXXXX.json")"
MALFORMED_FIXTURE="$(mktemp "$ROOT/tests/_fixtures/child-inputs-malformed.XXXXXX.json")"
INVALID_UTF8_FIXTURE="$(mktemp "$ROOT/tests/_fixtures/child-inputs-encoding.XXXXXX.json")"
SYMLINK_FIXTURE="$FIXTURE.link"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$FIXTURE" "$MALFORMED_FIXTURE" "$INVALID_UTF8_FIXTURE" "$SYMLINK_FIXTURE"' EXIT

cat >"$FIXTURE" <<'JSON'
{"edges":{"all.types":{"kind":"provider","retry":{"format":1},"required_inputs":{"attempt":"integer","enabled":"boolean","name":"string","file":"path","workdir":"directory","tags":"string_array","files":"path_array"},"optional_inputs":{"note":"optional_string","maybe_file":"optional_path","maybe_files":"optional_path_array","format_retry":"boolean","format_example_path":"path"}},"no.retry":{"kind":"provider","required_inputs":{},"optional_inputs":{"format_retry":"boolean","format_example_path":"path"}},"bad.retry.keys":{"kind":"provider","retry":{"format":1},"required_inputs":{},"optional_inputs":{"format_retry":"boolean"}},"skill.edge":{"kind":"skill","required_inputs":{},"optional_inputs":{}}}}
JSON

export UBERDEV_CHILD_TEST_MODE=1 UBERDEV_CHILD_MANIFEST_PATH="$FIXTURE"
. "$LIB"

passes=0
pass() { printf '  PASS %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
assert_eq() { [ "$2" = "$3" ] || fail "$1" "expected <$3>, got <$2>"; pass "$1"; }
assert_fails_cleanly() {
  local name="$1"; shift
  : >"$TMP/out"; : >"$TMP/err"
  if "$@" >"$TMP/out" 2>"$TMP/err"; then fail "$name" 'unexpected success'; fi
  [ ! -s "$TMP/out" ] || fail "$name" 'partial stdout escaped on failure'
  [ -s "$TMP/err" ] || fail "$name" 'stderr was empty'
  ! grep -q 'Traceback (most recent call last)' "$TMP/err" || fail "$name" 'Python traceback escaped'
  pass "$name"
}

valid_args=(
  attempt 7 enabled true name '"alpha"' file '"/tmp/input"'
  workdir '"/tmp/work"' tags '["one","two"]' files '[]'
  note '""' maybe_file '""' maybe_files '[]'
)
expected='{"attempt":7,"enabled":true,"file":"/tmp/input","files":[],"maybe_file":"","maybe_files":[],"name":"alpha","note":"","tags":["one","two"],"workdir":"/tmp/work"}'

actual="$(uberdev_child_inputs_build all.types "${valid_args[@]}")"
assert_eq 'build parses values and emits compact canonical JSON' "$actual" "$expected"
actual="$(uberdev_child_inputs_validate all.types "$expected")"
assert_eq 'validate returns the canonical object' "$actual" "$expected"

assert_fails_cleanly 'build rejects duplicate keys' uberdev_child_inputs_build all.types "${valid_args[@]}" name '"second"'
assert_fails_cleanly 'build rejects malformed JSON values' uberdev_child_inputs_build all.types attempt nope
assert_fails_cleanly 'build rejects an incomplete key/value pair' uberdev_child_inputs_build all.types attempt
assert_fails_cleanly 'build validates required keys before output' uberdev_child_inputs_build all.types attempt 7
assert_fails_cleanly 'validate rejects non-object JSON' uberdev_child_inputs_validate all.types '[]'
assert_fails_cleanly 'validate rejects missing keys' uberdev_child_inputs_validate all.types '{"attempt":7}'
assert_fails_cleanly 'validate rejects extra keys' uberdev_child_inputs_validate all.types "${expected%\}}\,"extra":1}"
assert_fails_cleanly 'validate rejects duplicate keys in raw JSON' uberdev_child_inputs_validate all.types "${expected%\}}\,"name":"second"}"
assert_fails_cleanly 'validate rejects undeclared edges' uberdev_child_inputs_validate absent.edge '{}'
assert_fails_cleanly 'validate rejects non-provider edges' uberdev_child_inputs_validate skill.edge '{}'

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
  assert_fails_cleanly "type validation rejects $key=$value" uberdev_child_inputs_validate all.types "$invalid"
done

retry="$(uberdev_child_inputs_format_retry all.types "$expected" /tmp/example.md)"
expected_retry="$(python3 -I -B - "$expected" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); obj.update(format_retry=True,format_example_path='/tmp/example.md')
print(json.dumps(obj,sort_keys=True,separators=(',',':')))
PY
)"
assert_eq 'format retry adds exactly the declared boolean and path' "$retry" "$expected_retry"
assert_fails_cleanly 'format retry rejects preexisting format_retry' uberdev_child_inputs_format_retry all.types "${expected%\}}\,"format_retry":false}" /tmp/example.md
assert_fails_cleanly 'format retry rejects preexisting format_example_path' uberdev_child_inputs_format_retry all.types "${expected%\}}\,"format_example_path":"/tmp/old"}" /tmp/example.md
assert_fails_cleanly 'format retry requires retry.format=1' uberdev_child_inputs_format_retry no.retry '{}' /tmp/example.md
assert_fails_cleanly 'format retry requires both optional keys' uberdev_child_inputs_format_retry bad.retry.keys '{}' /tmp/example.md
assert_fails_cleanly 'format retry revalidates its non-empty example path' uberdev_child_inputs_format_retry all.types "$expected" ''

printf '%s' '{"edges":{"bad.schema":{"kind":"provider","required_inputs":{"value":[]},"optional_inputs":{}}}}' >"$MALFORMED_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$MALFORMED_FIXTURE"
assert_fails_cleanly 'array-valued manifest types fail without a traceback' uberdev_child_inputs_validate bad.schema '{"value":"x"}'

printf '\377' >"$INVALID_UTF8_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$INVALID_UTF8_FIXTURE"
assert_fails_cleanly 'invalid manifest encoding fails without a traceback' uberdev_child_inputs_validate bad.schema '{}'

ln -s "$FIXTURE" "$SYMLINK_FIXTURE"
export UBERDEV_CHILD_MANIFEST_PATH="$SYMLINK_FIXTURE"
assert_fails_cleanly 'test manifest override rejects a symlink candidate' uberdev_child_inputs_validate all.types "$expected"

canonical_manifest="$_UBERDEV_CHILD_ROOT/policy/solve-run-tree-v1.json"
unset UBERDEV_CHILD_MANIFEST_PATH
canonical="$(uberdev_child_inputs_build brainstorm.research.codebase \
  working_dir '"/tmp/work"' summary_path '"/tmp/summary"' question '"why"')"
assert_eq 'canonical manifest is resolved internally' "$canonical" '{"question":"why","summary_path":"/tmp/summary","working_dir":"/tmp/work"}'
export UBERDEV_CHILD_MANIFEST_PATH="$FIXTURE"
[ -f "$canonical_manifest" ] || fail 'canonical manifest exists' "$canonical_manifest missing"
pass 'canonical manifest exists'

printf 'child-inputs: %d assertions passed\n' "$passes"
