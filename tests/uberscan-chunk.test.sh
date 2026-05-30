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

# ============================================================================
# AREA MODE (--areas N): fixed-fleet packing for /uberscan + /ubersimplify.
# Replaces the per-byte-budget × 6-reviewer blow-up (~422 agents whole-repo)
# with a bounded fleet of N area agents. Invariants the fleet-cost AND the
# "no silent under-coverage" guarantee both depend on:
#   1. ≤ N areas (never more — that is the agent-count ceiling).
#   2. Every kept file lands in EXACTLY one area (no drops, no dups) — the
#      whole-repo audit must actually cover the whole repo (no overflow-truncate).
#   3. overflow is ALWAYS false in area mode (nothing is ever dropped).
#   4. Deterministic: same scope → byte-identical manifest.
#   5. Byte-balanced: no area is pathologically larger than the fair share.
# Fixture kept set (post dirA/dirB adds, huge.ts/node_modules/dist/lock skipped):
#   src/a.ts, src/b.ts, dirA/a1.ts, dirA/a2.ts, dirB/b1.ts, dirB/b2.ts  = 6 files
# ============================================================================
AREA3="$(python3 "$CHUNK" --scope . --areas 3)"
check "area mode emits valid JSON" "printf '%s' \"\$AREA3\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
check "area mode tags mode=area" "printf '%s' \"\$AREA3\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get(\"mode\")==\"area\" else 1)'"
check "--areas 3 emits exactly 3 areas (6 files >= 3)" "printf '%s' \"\$AREA3\" | python3 -c 'import json,sys; sys.exit(0 if len(json.load(sys.stdin)[\"chunks\"])==3 else 1)'"
check "area mode overflow is always false" "printf '%s' \"\$AREA3\" | python3 -c 'import json,sys; sys.exit(1 if json.load(sys.stdin)[\"overflow\"] else 0)'"
# Invariant 2 — total coverage: union of all area files == every kept file, once.
check "every kept file covered exactly once (no drop, no dup)" "printf '%s' \"\$AREA3\" | python3 -c '
import json,sys
d=json.load(sys.stdin)
allf=[f for c in d[\"chunks\"] for f in c[\"files\"]]
expected={\"src/a.ts\",\"src/b.ts\",\"dirA/a1.ts\",\"dirA/a2.ts\",\"dirB/b1.ts\",\"dirB/b2.ts\"}
sys.exit(0 if len(allf)==len(set(allf))==len(expected) and set(allf)==expected else 1)'"
# Invariant 4 — determinism.
AREA3B="$(python3 "$CHUNK" --scope . --areas 3)"
check "area mode is deterministic" "[ \"\$AREA3\" = \"\$AREA3B\" ]"
# Invariant 1 — fewer-than-N for tiny repos: 6 files, --areas 8 -> at most 6 areas.
check "--areas 8 with 6 files yields <= 6 areas (never empty areas)" "python3 \"$CHUNK\" --scope . --areas 8 | python3 -c 'import json,sys; ch=json.load(sys.stdin)[\"chunks\"]; sys.exit(0 if len(ch)<=6 and all(c[\"files\"] for c in ch) else 1)'"
# --areas 1 -> single area with all files.
check "--areas 1 packs all files into one area" "python3 \"$CHUNK\" --scope . --areas 1 | python3 -c 'import json,sys; ch=json.load(sys.stdin)[\"chunks\"]; sys.exit(0 if len(ch)==1 and len(ch[0][\"files\"])==6 else 1)'"
# Invariant 5 — byte balance: max area bytes <= 2x the mean (loose bound; the
# linear partition guarantees max-area <= optimal min-max, comfortably under 2x).
check "area mode is byte-balanced (max area <= 2x mean)" "printf '%s' \"\$AREA3\" | python3 -c '
import json,sys
ch=json.load(sys.stdin)[\"chunks\"]
b=[c[\"bytes\"] for c in ch]
mean=sum(b)/len(b)
sys.exit(0 if max(b)<=2*mean else 1)'"
# Fail-loud: --areas 0 is rejected (matches --budget-bytes/--max-chunks validation).
check "rejects --areas 0 (fail-loud, non-zero exit)" "! python3 \"$CHUNK\" --scope . --areas 0 >/dev/null 2>&1"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
