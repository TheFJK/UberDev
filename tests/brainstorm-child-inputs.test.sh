#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRAINSTORM="$ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -I -B - "$BRAINSTORM" "$TMP/setup.sh" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])

setup = re.search(
    r"```bash uberdev-executable\n(set -euo pipefail\n.*?BRAINSTORM_LIBRARY_INPUTS=.*?\n)```",
    source,
    re.DOTALL,
)
if setup is None:
    raise SystemExit("FAIL: missing executable brainstorm setup fence")
output.write_text(setup.group(1), encoding="utf-8")

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

printf 'brainstorm-child-inputs: builder migration and quoting passed\n'
