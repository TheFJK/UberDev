#!/usr/bin/env bash
# port-agent-prompts.sh — copy UberDev Markdown agent prompts into the Codex
# runtime package with the same safe text substitutions used for TOML agents.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <src_agents_dir> <dst_agents_dir>" >&2
  exit 1
fi

SRC="$1"
DST="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="${SCRIPT_DIR}/convert-agents.py"

if [ ! -d "$SRC" ]; then
  echo "error: source agents dir not found: $SRC" >&2
  exit 1
fi
if [ ! -f "$CONVERTER" ]; then
  echo "error: converter not found: $CONVERTER" >&2
  exit 1
fi

echo "Porting runtime agent prompts: $SRC → $DST"

mkdir -p "$DST"
rsync -a --delete \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '*.bak' \
  --exclude '*.bak2' \
  --exclude '*.fix' \
  --exclude '.DS_Store' \
  "$SRC"/ "$DST"/

python3 - "$DST" "$CONVERTER" <<'PY'
import importlib.util
import sys
from pathlib import Path

dst = Path(sys.argv[1])
converter = Path(sys.argv[2])

spec = importlib.util.spec_from_file_location("convert_agents", converter)
if spec is None or spec.loader is None:
    print(f"error: unable to load converter: {converter}", file=sys.stderr)
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

count = 0
for path in sorted(dst.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    ported = module.codex_port_text(text)
    path.write_text(ported, encoding="utf-8")
    count += 1

if count == 0:
    print(f"error: no *.md agents found in {dst}", file=sys.stderr)
    raise SystemExit(2)

print(f"Done: {count} runtime Markdown prompts ported.")
PY
