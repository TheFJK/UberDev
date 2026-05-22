#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$REPO_ROOT/plugins/uberdev/skills/uberscan-pipeline/report.py"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/chunks"
cat > "$TMP/chunks/chunk-01-findings.yaml" <<'YAML'
chunk_id: 1
files: ["src/a.ts"]
findings:
  - {severity: blocker, location: "src/a.ts:42", agent: code-reviewer, summary: "null deref", detail: "x", confidence: high}
  - {severity: suggestion, location: "src/a.ts:9", agent: comment-analyzer, summary: "stale", detail: "y", confidence: low}
YAML
cat > "$TMP/chunks/chunk-02-findings.yaml" <<'YAML'
chunk_id: 2
files: ["src/b.ts"]
findings:
  - {severity: blocker, location: "src/a.ts:42", agent: silent-failure-hunter, summary: "null deref", detail: "z", confidence: high}
YAML

python3 "$REPORT" --run-id test --chunks-dir "$TMP/chunks" --out "$TMP/report.md"
check "writes report.md" "[ -f \"$TMP/report.md\" ]"
check "report has severity totals" "grep -q 'blocker' \"$TMP/report.md\""
python3 "$REPORT" --run-id test --chunks-dir "$TMP/chunks" --emit-findings-to-issues-aggregate "$TMP/agg.md"
check "aggregate has envelope" "head -1 \"$TMP/agg.md\" | grep -q 'source=\"uberscan-aggregate\"'"
check "dedupes same file:line:summary across chunks (cross-reviewer)" "[ \$(grep -c 'src/a.ts:42' \"$TMP/agg.md\") -eq 1 ]"
check "drops suggestion from aggregate" "! grep -q 'stale' \"$TMP/agg.md\""

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
