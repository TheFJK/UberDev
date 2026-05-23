#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHUNK="$REPO_ROOT/plugins/uberdev/lib/chunk.py"
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

# AC5 (issue #166): assert chunk CONTENTS under budget pressure, not just overflow.
# Each file is ~100 bytes ("a\n" or "b\n" repeated 50 times = 2 bytes * 50 = 100 bytes).
# Budget 250 >= 2*100 (fits 2 files) but < 3*100 (cannot fit a 3rd file).
# chunk_files() groups by sorted directory first, so dirA's 2 files pack together into one
# chunk (~200 bytes), then dirB's 2 files pack into the next chunk — never mixed.
mkdir -p "$TMP/dirA" "$TMP/dirB"
printf 'a\n%.0s' {1..50} > "$TMP/dirA/a1.ts"   # ~100 bytes
printf 'a\n%.0s' {1..50} > "$TMP/dirA/a2.ts"    # ~100 bytes
printf 'b\n%.0s' {1..50} > "$TMP/dirB/b1.ts"    # ~100 bytes
printf 'b\n%.0s' {1..50} > "$TMP/dirB/b2.ts"    # ~100 bytes
git add -A 2>/dev/null

# Budget 250: 2 files fit (200 bytes), 3 files do not (300 bytes > 250), forcing a split
# between dirA and dirB. JSON schema: d["chunks"] is a list of objects with a "files" key
# (list of git-relative paths, e.g. "dirA/a1.ts") and a "bytes" key.
GROUP_OUT="$(python3 "$CHUNK" --scope . --budget-bytes 250)"
check "AC5: dirA files grouped in one chunk" "printf '%s' \"\$GROUP_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); chunks=[set(c[\"files\"]) for c in d[\"chunks\"]]; sys.exit(0 if any({\"dirA/a1.ts\",\"dirA/a2.ts\"} <= c for c in chunks) else 1)'"
check "AC5: dirB files grouped in one chunk" "printf '%s' \"\$GROUP_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); chunks=[set(c[\"files\"]) for c in d[\"chunks\"]]; sys.exit(0 if any({\"dirB/b1.ts\",\"dirB/b2.ts\"} <= c for c in chunks) else 1)'"
check "AC5: dirA and dirB never share a chunk (directory cohesion)" "printf '%s' \"\$GROUP_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); bad=any(any(f.startswith(\"dirA/\") for f in c[\"files\"]) and any(f.startswith(\"dirB/\") for f in c[\"files\"]) for c in d[\"chunks\"]); sys.exit(1 if bad else 0)'"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
