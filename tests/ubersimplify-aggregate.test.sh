#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGG="$REPO_ROOT/plugins/uberdev/skills/ubersimplify-pipeline/aggregate.py"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

if ! python3 -c "import yaml" 2>/dev/null; then echo "SKIP: PyYAML not installed"; exit 0; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# One chunk's lens findings: same location flagged by Reuse + Quality; one suggestion elsewhere.
cat > "$TMP/chunk-001-lens.yaml" <<'YAML'
schema_version: 1
chunk_id: 1
files: [src/a.ts]
findings:
  - location: src/a.ts:10
    severity: blocker
    lens: Reuse
    summary: duplicates existing helper formatDate
    detail: a hand-rolled date format duplicates utils/date.ts
  - location: src/a.ts:10
    severity: suggestion
    lens: Quality
    summary: nested ternary reduces readability
    detail: flatten with a lookup table
  - location: src/a.ts:55
    severity: suggestion
    lens: Efficiency
    summary: redundant file read in a loop
    detail: hoist the read out of the loop
YAML

echo "== fixer aggregate (per-chunk, code-fixer envelope) =="
python3 "$AGG" fixer --lens-file "$TMP/chunk-001-lens.yaml" --out "$TMP/chunk-001-fixer.md"
check "wrapped in post-impl-review-aggregate envelope" "head -1 '$TMP/chunk-001-fixer.md' | grep -q 'source=\"post-impl-review-aggregate\"'"
check "merges same file:line across lenses into one row" "[ \$(grep -c '^- location: src/a.ts:10' '$TMP/chunk-001-fixer.md') -eq 1 ]"
check "merged lens label is Reuse+Quality" "grep -q '^  lens: Reuse+Quality' '$TMP/chunk-001-fixer.md'"
check "merged severity is max (blocker)" "grep -A1 '^- location: src/a.ts:10' '$TMP/chunk-001-fixer.md' | grep -q 'severity: blocker'"
check "merged summary keeps both lens parts" "grep -q 'Reuse: duplicates existing helper' '$TMP/chunk-001-fixer.md' && grep -q 'Quality: nested ternary' '$TMP/chunk-001-fixer.md'"

echo "== issues aggregate --audit-only (ubersimplify envelope, blocker-only) =="
python3 "$AGG" issues --chunks-dir "$TMP" --out "$TMP/f2i.md" --audit-only
check "wrapped in ubersimplify-aggregate envelope" "head -1 '$TMP/f2i.md' | grep -q 'source=\"ubersimplify-aggregate\"'"
check "files the blocker location" "grep -q 'src/a.ts:10' '$TMP/f2i.md'"
check "excludes suggestion-only location" "! grep -q 'src/a.ts:55' '$TMP/f2i.md'"
check "rows marked DEFERRED" "grep -q '| DEFERRED |' '$TMP/f2i.md'"

echo "== issues aggregate respects code-fixer dispositions (leftover only) =="
cat > "$TMP/chunk-001-fixer-disposition.yaml" <<'YAML'
status: APPLIED
phase: phase2
findings_disposition:
  - location: src/a.ts:10
    disposition: APPLIED
    behavior_tag: preserve
    reason: applied
YAML
python3 "$AGG" issues --chunks-dir "$TMP" --out "$TMP/f2i2.md"
check "APPLIED location is NOT filed" "! grep -q 'src/a.ts:10' '$TMP/f2i2.md'"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
