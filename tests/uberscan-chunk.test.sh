#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHUNK="$REPO_ROOT/plugins/uberdev/skills/uberscan-pipeline/chunk.py"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

# Fixture tree
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; git init -q
mkdir -p src node_modules dist
printf 'a\n%.0s' {1..100} > src/a.ts
printf 'b\n%.0s' {1..100} > src/b.ts
printf 'x\n%.0s' {1..100} > node_modules/skip.js
printf 'y\n%.0s' {1..100} > dist/skip.js
printf '{}' > package-lock.json
head -c 300000 /dev/zero | tr '\0' 'z' > src/huge.ts   # >256KB MAX_FILE_BYTES cap
git add -A 2>/dev/null

OUT="$(python3 "$CHUNK" --scope . --budget-bytes 4096)"
check "emits valid JSON" "printf '%s' \"\$OUT\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
check "skips node_modules" "! printf '%s' \"\$OUT\" | grep -q node_modules"
check "skips dist" "! printf '%s' \"\$OUT\" | grep -q 'dist/'"
check "skips lockfile" "! printf '%s' \"\$OUT\" | grep -q package-lock.json"
check "includes src files" "printf '%s' \"\$OUT\" | grep -q 'src/a.ts'"
check "honors MAX_CHUNKS overflow flag" "python3 \"$CHUNK\" --scope . --budget-bytes 1 --max-chunks 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"overflow\"] else 1)'"
check "skips oversized file (>256KB MAX_FILE_BYTES)" "! printf '%s' \"\$OUT\" | grep -q 'src/huge.ts'"
check "rejects --budget-bytes=0 (fail-loud, non-zero exit)" "! python3 \"$CHUNK\" --scope . --budget-bytes 0 >/dev/null 2>&1"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
