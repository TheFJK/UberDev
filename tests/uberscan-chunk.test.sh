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

# ============================================================================
# Base filter invariants (IGNORE rules / lockfiles / oversize), asserted in AREA
# MODE — the only packer since the dead --budget-bytes mode was deleted
# (RFC 0012 scan-R4). Kept set at this point: src/a.ts, src/b.ts (huge.ts is
# oversize; node_modules/dist/package-lock.json are rule-ignored).
# ============================================================================
OUT="$(python3 "$CHUNK" --scope . --areas 3)"
check "emits valid JSON" "printf '%s' \"\$OUT\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
check "skips node_modules" "! grep -q node_modules <<<\"\$OUT\""
check "skips dist" "! grep -q 'dist/' <<<\"\$OUT\""
check "skips lockfile" "! grep -q package-lock.json <<<\"\$OUT\""
check "includes src files" "grep -q 'src/a.ts' <<<\"\$OUT\""
# Oversize handling (scan-R4): the >256KB file must be excluded from every area
# AND surfaced BY NAME in skipped_oversize — a "whole-repo" audit's coverage gap
# must be visible in the manifest, never a silent count.
check "oversized file (>256KB MAX_FILE_BYTES) excluded from every area" "printf '%s' \"\$OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); allf=[f for c in d[\"chunks\"] for f in c[\"files\"]]; sys.exit(1 if \"src/huge.ts\" in allf else 0)'"
check "skipped-oversize file NAME surfaced in manifest (exactly src/huge.ts)" "printf '%s' \"\$OUT\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"skipped_oversize\"]==[\"src/huge.ts\"] else 1)'"
check "skipped_files still counts ALL skips (3 rule-ignored + 1 oversize = 4)" "printf '%s' \"\$OUT\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"skipped_files\"]==4 else 1)'"
# Dead-mode locks (scan-R4): the budget flags are GONE, and --areas is required.
check "budget mode deleted: --budget-bytes is rejected" "! python3 \"$CHUNK\" --scope . --areas 3 --budget-bytes 4096 >/dev/null 2>&1"
check "budget mode deleted: --max-chunks is rejected" "! python3 \"$CHUNK\" --scope . --areas 3 --max-chunks 25 >/dev/null 2>&1"
check "--areas is required (fail-loud when omitted)" "! python3 \"$CHUNK\" --scope . >/dev/null 2>&1"

# ============================================================================
# Directory-cohesion invariants (ported from the deleted budget-mode AC5 block,
# issue #166): pack_areas partitions over a directory-cohesive layout, so
#   (1) when the byte balance ALLOWS a split at a directory boundary, sibling
#       dirs land in separate areas (never mixed), and
#   (2) even when balance forces a mid-directory split, each directory's files
#       remain CONTIGUOUS across the flattened area order (cohesion proper).
# dirA/dirB are added to the MAIN fixture first — the area-mode block below
# depends on the resulting 6-file kept set.
# ============================================================================
mkdir -p "$TMP/dirA" "$TMP/dirB"
printf 'a\n%.0s' {1..50} > "$TMP/dirA/a1.ts"   # ~100 bytes
printf 'a\n%.0s' {1..50} > "$TMP/dirA/a2.ts"    # ~100 bytes
printf 'b\n%.0s' {1..50} > "$TMP/dirB/b1.ts"    # ~100 bytes
printf 'b\n%.0s' {1..50} > "$TMP/dirB/b2.ts"    # ~100 bytes
git add -A 2>/dev/null

# (1) Clean-split fixture in an ISOLATED repo: two dirs x two ~100B files,
# --areas 2 -> optimal min-max cap is 200 bytes, which lands the split exactly
# on the dirA/dirB boundary: {dirA/*}, {dirB/*} — never mixed.
TMP2="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2"' EXIT
(
  cd "$TMP2" && git init -q && mkdir -p dirA dirB
  printf 'a\n%.0s' {1..50} > dirA/a1.ts
  printf 'a\n%.0s' {1..50} > dirA/a2.ts
  printf 'b\n%.0s' {1..50} > dirB/b1.ts
  printf 'b\n%.0s' {1..50} > dirB/b2.ts
  git add -A 2>/dev/null
)
COH_OUT="$(cd "$TMP2" && python3 "$CHUNK" --scope . --areas 2)"
check "cohesion: dirA files grouped in one area" "printf '%s' \"\$COH_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); areas=[set(c[\"files\"]) for c in d[\"chunks\"]]; sys.exit(0 if any({\"dirA/a1.ts\",\"dirA/a2.ts\"} <= a for a in areas) else 1)'"
check "cohesion: dirB files grouped in one area" "printf '%s' \"\$COH_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); areas=[set(c[\"files\"]) for c in d[\"chunks\"]]; sys.exit(0 if any({\"dirB/b1.ts\",\"dirB/b2.ts\"} <= a for a in areas) else 1)'"
check "cohesion: dirs never mixed when balance allows a boundary split" "printf '%s' \"\$COH_OUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); bad=any(any(f.startswith(\"dirA/\") for f in c[\"files\"]) and any(f.startswith(\"dirB/\") for f in c[\"files\"]) for c in d[\"chunks\"]); sys.exit(1 if bad else 0)'"

# (2) Adjacency invariant on the MAIN fixture: with src/ (2x200B) dominating,
# --areas 3 byte-balance forces a mid-directory split — but each directory's
# files must still occupy one CONTIGUOUS run of the flattened area order (a
# directory may span an area boundary, yet never re-appears after another
# directory interrupts it).
ADJ_OUT="$(python3 "$CHUNK" --scope . --areas 3)"
check "cohesion: each dir's files contiguous across the flattened area order" "printf '%s' \"\$ADJ_OUT\" | python3 -c '
import json,sys,os
d=json.load(sys.stdin)
flat=[f for c in d[\"chunks\"] for f in c[\"files\"]]
seen=set(); prev=None
for dd in (os.path.dirname(f) for f in flat):
    if dd!=prev and dd in seen: sys.exit(1)
    if dd!=prev: seen.add(dd)
    prev=dd
sys.exit(0)'"

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
# Fail-loud: --areas 0 is rejected (non-positive fleet size is meaningless).
check "rejects --areas 0 (fail-loud, non-zero exit)" "! python3 \"$CHUNK\" --scope . --areas 0 >/dev/null 2>&1"

# Large-file invariant (pins the pack_areas binary-search LOWER bound
# lo = max(max_file, ceil(total/N))): a single file bigger than the naive
# fair-share (total/N) must still be PLACED in its own area and everything stays
# covered — a wrong lower bound would under-size an area and drop the big file.
# The fixture's huge.ts is >256KB (skipped by MAX_FILE_BYTES), so add a 150KB file
# UNDER the cap. Added after the 6-file assertions above (their captures already ran).
mkdir -p "$TMP/big"
head -c 150000 /dev/zero | tr '\0' 'B' > "$TMP/big/big.ts"   # 150KB, < 256KB cap → kept
git add -A 2>/dev/null
BIGOUT="$(python3 "$CHUNK" --scope . --areas 3)"   # fair share ~50KB; big file 150KB >> that
check "large-file run yields <= 3 areas" "printf '%s' \"\$BIGOUT\" | python3 -c 'import json,sys; sys.exit(0 if len(json.load(sys.stdin)[\"chunks\"])<=3 else 1)'"
check "large-file (>fair-share) is placed, not dropped" "printf '%s' \"\$BIGOUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); allf=[f for c in d[\"chunks\"] for f in c[\"files\"]]; sys.exit(0 if \"big/big.ts\" in allf else 1)'"
check "large-file run keeps total coverage (7 files, each once)" "printf '%s' \"\$BIGOUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); allf=[f for c in d[\"chunks\"] for f in c[\"files\"]]; sys.exit(0 if len(allf)==len(set(allf))==d[\"total_files\"]==7 else 1)'"
# Cap boundary: the 150KB UNDER-cap file must NOT be flagged skipped_oversize —
# only the >256KB huge.ts belongs there (and still does on this later run).
check "under-cap large file not flagged skipped_oversize (only huge.ts is)" "printf '%s' \"\$BIGOUT\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"skipped_oversize\"]==[\"src/huge.ts\"] else 1)'"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
