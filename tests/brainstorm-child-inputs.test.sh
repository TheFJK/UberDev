#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRAINSTORM="$ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

export UBERDEV_CHILD_TEST_MODE=1
unset UBERDEV_CHILD_TEST_SOURCE UBERDEV_CHILD_TEST_RECEIPT_FILE

python3 -I -B - "$BRAINSTORM" "$TMP/setup.sh" "$TMP/research-callsites.sh" <<'PY'
import re
import sys
from pathlib import Path

source_path, setup_path, callsites_path = map(Path, sys.argv[1:])
source = source_path.read_text(encoding="utf-8")

setup = re.search(
    r"```bash uberdev-executable\n(set -euo pipefail\n.*?BRAINSTORM_LIBRARY_INPUTS=.*?\n)```",
    source,
    re.DOTALL,
)
if setup is None:
    raise SystemExit("FAIL: missing executable brainstorm setup fence")
setup_path.write_text(setup.group(1), encoding="utf-8")

builders = {
    "BRAINSTORM_CODEBASE_INPUTS": "brainstorm.research.codebase",
    "BRAINSTORM_PRIOR_ART_INPUTS": "brainstorm.research.prior_art",
    "BRAINSTORM_LIBRARY_INPUTS": "brainstorm.research.library",
}
failures = []
for variable, edge in builders.items():
    pattern = rf'{variable}="\$\(uberdev_child_inputs_build {re.escape(edge)}(?:\s|\\)'
    if re.search(pattern, setup.group(1)) is None:
        failures.append(f"{variable} does not use uberdev_child_inputs_build for {edge}")

retry = re.search(
    r"```bash uberdev-executable retry=format\n(.*?)```",
    source,
    re.DOTALL,
)
if retry is None:
    failures.append("missing executable brainstorm format-retry fence")
elif re.search(
    r'BRAINSTORM_FORMAT_INPUTS="\$\(uberdev_child_inputs_format_retry '
    r'"\$failed_edge" "\$failed_inputs_json" "\$format_example_path"\)"',
    retry.group(1),
) is None:
    failures.append("BRAINSTORM_FORMAT_INPUTS does not use uberdev_child_inputs_format_retry")

if failures:
    raise SystemExit("FAIL: " + "; ".join(failures))

callsites = []
for edge in (
    "brainstorm.research.codebase",
    "brainstorm.research.prior_art",
    "brainstorm.research.library",
):
    match = re.search(
        rf"```bash uberdev-executable edge={re.escape(edge)}\n(.*?)\n```",
        source,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit(f"FAIL: missing executable production callsite for {edge}")
    callsites.append(match.group(1))
callsites_path.write_text("\n".join(callsites) + "\n", encoding="utf-8")
PY

# Execute the documented constructor setup with hostile shell strings. This
# proves the callsite passes JSON literals to the manifest-derived builder
# without losing newlines, quotes, backslashes, or glob characters.
export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{}'
export PLUGIN_ROOT="$ROOT/plugins/uberdev"
working_dir=$'/tmp/work dir\nwith "quotes" and \\slashes/*'
codebase_summary_path=$'/tmp/codebase summary\n.json'
patterns_summary_path=$'/tmp/prior-art "summary".json'
library_summary_path=$'/tmp/library\\summary?.json'
codebase_question=$'where is "state"?\nsecond line'
prior_art_question=$'compare \\ prior art * safely'
library_question=$'which library handles [arrays]?'
# shellcheck source=/dev/null
. "$TMP/setup.sh"

python3 -I -B - \
  "$BRAINSTORM_CODEBASE_INPUTS" "$BRAINSTORM_PRIOR_ART_INPUTS" "$BRAINSTORM_LIBRARY_INPUTS" \
  "$working_dir" "$codebase_summary_path" "$patterns_summary_path" "$library_summary_path" \
  "$codebase_question" "$prior_art_question" "$library_question" <<'PY'
import json
import sys

codebase, prior_art, library = map(json.loads, sys.argv[1:4])
working_dir, codebase_path, prior_art_path, library_path = sys.argv[4:8]
codebase_question, prior_art_question, library_question = sys.argv[8:11]
assert codebase == {
    "working_dir": working_dir,
    "summary_path": codebase_path,
    "question": codebase_question,
}
assert prior_art == {
    "working_dir": working_dir,
    "summary_path": prior_art_path,
    "question": prior_art_question,
}
assert library == {
    "working_dir": working_dir,
    "summary_path": library_path,
    "question": library_question,
}
PY

# Receipt-mode closure test: source the production setup again with
# schema-valid hostile paths, execute the three actual research callsite
# fences, and launch the real production batch. Only the final provider seam
# is replaced; child input, handoff, preflight, dispatch, and receipt paths are
# production implementations from child-dispatch.sh.
RECEIPT_DIR="$TMP/receipts"
RECEIPT_FILE="$RECEIPT_DIR/brainstorm.jsonl"
mkdir -p "$RECEIPT_DIR"
chmod 700 "$RECEIPT_DIR"
: >"$RECEIPT_FILE"
chmod 600 "$RECEIPT_FILE"
export UBERDEV_CHILD_TEST_SOURCE='plugins/uberdev/skills/brainstorm/SKILL.md'
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$RECEIPT_FILE"

CHAIN_RUN="$TMP/brainstorm run"
working_dir="$CHAIN_RUN/work dir with \"quotes\" and \\slashes *?[x]"
codebase_summary_path="$CHAIN_RUN/codebase summary \"quoted\" \\one?.md"
patterns_summary_path="$CHAIN_RUN/prior-art summary \"quoted\" \\two*.md"
library_summary_path="$CHAIN_RUN/library summary \"quoted\" \\three[x].md"
mkdir -p "$working_dir"
printf 'codebase summary\n' >"$codebase_summary_path"
printf 'prior art summary\n' >"$patterns_summary_path"
printf 'library summary\n' >"$library_summary_path"
codebase_question=$'where is "state" and \\path *?[x]?\t'
prior_art_question=$'compare "prior art" against \\patterns *?[x]\t'
library_question=$'which "library" handles \\arrays *?[x]\t'
# shellcheck source=/dev/null
. "$TMP/setup.sh"

make_context() {
  local run="$1" run_id="$2" request decision metadata
  mkdir -p "$run"
  request="$(python3 -I -B - "$run" "$run_id" "$ROOT" <<'PY'
import json
import sys

run, run_id, repository = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "run_dir": run,
    "run_id": run_id,
    "repository_id": repository,
    "backend": "codex",
    "workflow": "solve",
    "phase": "lead",
    "role": "lead",
    "task_tier": "medium",
    "risk_signals": [],
    "issue_or_pr": 42,
    "issue_num": 42,
    "capacity": 4,
    "timeout_s": 20,
    "routing_mode": "adaptive",
}, separators=(",", ":")))
PY
)"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(python3 -I -B - "$run_id" "$ROOT" <<'PY'
import json
import sys

run_id, repository = sys.argv[1:]
print(json.dumps({
    "run_id": run_id,
    "repository_id": repository,
    "workflow": "solve",
    "backend": "codex",
    "issue_num": 42,
    "task_tier": "medium",
    "risk_signals": [],
}, separators=(",", ":")))
PY
)"
  uberdev_agent_context_create "$run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-11T00:00:00Z'
}

CONTEXT_OUT="$(make_context "$CHAIN_RUN" brainstorm-receipt-root)"
CONTEXT_FILE="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_file"],end="")' "$CONTEXT_OUT")"
CONTEXT_SHA="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_sha256"],end="")' "$CONTEXT_OUT")"
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B - "$CONTEXT_FILE" "$CONTEXT_SHA" <<'PY'
import json
import sys

print(json.dumps({
    "schema_version": 1,
    "run_id": "brainstorm-receipt-root",
    "workflow": "solve",
    "issue_num": 42,
    "context_file": sys.argv[1],
    "context_sha256": sys.argv[2],
}, separators=(",", ":")))
PY
)"
export UBERDEV_RUN_CARRIER_JSON

# These are the verbatim production callsites; uberdev_brainstorm_dispatch is
# intentionally not replaced, so its real handoff-recording path executes.
# shellcheck source=/dev/null
. "$TMP/research-callsites.sh" >/dev/null

PROVIDER_LOG="$TMP/provider-instances.log"
: >"$PROVIDER_LOG"
uberdev_agent_dispatch() {
  local request="$1" prompt="$2" result="$3" status="$4" instance
  : "$prompt"
  instance="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["run_id"],end="")' "$request")"
  python3 -I -B - "$RECEIPT_FILE" "$UBERDEV_CHILD_TEST_SOURCE" "$instance" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert rows[-1]["event"] == "dispatch", rows[-1]
assert rows[-1]["source"] == sys.argv[2], rows[-1]
assert rows[-1]["instance_id"] == sys.argv[3], rows[-1]
PY
  printf '%s\n' "$instance" >>"$PROVIDER_LOG"
  printf 'completed by receipt provider seam\n' >"$result"
  chmod 600 "$result"
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"receipt-%s"}\n' "$instance" >"$status"
  chmod 600 "$status"
}

uberdev_brainstorm_launch_batch

python3 -I -B - \
  "$RECEIPT_FILE" "$PROVIDER_LOG" "$UBERDEV_CHILD_TEST_SOURCE" \
  "$BRAINSTORM_CODEBASE_INPUTS" "$BRAINSTORM_PRIOR_ART_INPUTS" "$BRAINSTORM_LIBRARY_INPUTS" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

receipt_path, provider_path, source, *inputs_raw = sys.argv[1:]
rows = [json.loads(line) for line in Path(receipt_path).read_text().splitlines()]
edges = (
    ("brainstorm.research.codebase", "brainstorm-research-codebase-a1"),
    ("brainstorm.research.prior_art", "brainstorm-research-prior-art-a1"),
    ("brainstorm.research.library", "brainstorm-research-library-a1"),
)
expected_order = [
    *(('build', edge) for edge, _ in edges),
    *(('handoff', edge) for edge, _ in edges),
    *(('dispatch', edge) for edge, _ in edges),
]
assert len(rows) == 9, rows
assert [(row.get('event'), row.get('edge_id')) for row in rows] == expected_order, rows
assert set(row.get('edge_id') for row in rows) == {edge for edge, _ in edges}
assert set(row.get('event') for row in rows) == {'build', 'handoff', 'dispatch'}

for (edge, instance), inputs in zip(edges, inputs_raw, strict=True):
    canonical = json.dumps(
        json.loads(inputs), sort_keys=True, separators=(',', ':'), ensure_ascii=True
    ).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    edge_rows = [row for row in rows if row['edge_id'] == edge]
    assert [row['event'] for row in edge_rows] == ['build', 'handoff', 'dispatch']
    assert {row['inputs_sha256'] for row in edge_rows} == {digest}
    for row in edge_rows:
        expected_keys = {'schema_version', 'event', 'source', 'edge_id', 'inputs_sha256'}
        if row['event'] != 'build':
            expected_keys.add('instance_id')
            assert row['instance_id'] == instance
        assert set(row) == expected_keys, row
        assert row['schema_version'] == 1 and row['source'] == source

provider_instances = Path(provider_path).read_text().splitlines()
assert provider_instances == [instance for _, instance in edges], provider_instances
PY

printf 'brainstorm-child-inputs: production build -> handoff -> dispatch chains and hostile quoting passed\n'
