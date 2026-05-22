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
# Extended fixtures: a major finding whose summary contains a pipe (escaping test),
# plus a Phase-1b global-security.md artifact (report-inclusion test).
cat > "$TMP/chunks/chunk-03-findings.yaml" <<'YAML'
chunk_id: 3
files: ["src/c.ts"]
findings:
  - {severity: major, location: "src/c.ts:5", agent: type-design-analyzer, summary: "weak invariant a | b", detail: "prefer x || y", confidence: medium}
YAML
printf 'Semgrep SAST: 1 high finding in src/c.ts (rule: dangerous-eval)\n' > "$TMP/chunks/global-security.md"
# A blocker at LOW confidence: the false-positive guard keeps it out of issue filing (report-only).
cat > "$TMP/chunks/chunk-04-findings.yaml" <<'YAML'
chunk_id: 4
files: ["src/d.ts"]
findings:
  - {severity: blocker, location: "src/d.ts:7", agent: code-reviewer, summary: "maybe-bug low conf", detail: "uncertain", confidence: low}
YAML

python3 "$REPORT" --run-id test --chunks-dir "$TMP/chunks" --out "$TMP/report.md"
check "writes report.md" "[ -f \"$TMP/report.md\" ]"
check "report has severity totals" "grep -q 'blocker' \"$TMP/report.md\""
check "report includes Global passes section (Phase 1b wired)" "grep -q 'Global passes' \"$TMP/report.md\""
check "report includes semgrep global content" "grep -q 'dangerous-eval' \"$TMP/report.md\""

python3 "$REPORT" --run-id test --chunks-dir "$TMP/chunks" --emit-findings-to-issues-aggregate "$TMP/agg.md"
check "aggregate has envelope" "head -1 \"$TMP/agg.md\" | grep -q 'source=\"uberscan-aggregate\"'"
check "dedupes same file:line:summary across chunks (cross-reviewer)" "[ \$(grep -c 'src/a.ts:42' \"$TMP/agg.md\") -eq 1 ]"
check "drops suggestion from aggregate" "! grep -q 'stale' \"$TMP/agg.md\""
check "default keeps major finding in aggregate" "grep -q 'src/c.ts:5' \"$TMP/agg.md\""
check "pipe in summary is escaped" "grep -qF '\|' \"$TMP/agg.md\""
check "default min-confidence drops low-confidence finding from aggregate" "! grep -q 'src/d.ts:7' \"$TMP/agg.md\""
check "report still shows the low-confidence finding" "grep -q 'src/d.ts:7' \"$TMP/report.md\""

# --min-severity=critical must drop the major finding but keep the blocker
python3 "$REPORT" --run-id test --chunks-dir "$TMP/chunks" --min-severity critical --emit-findings-to-issues-aggregate "$TMP/agg-crit.md"
check "min-severity=critical drops major finding" "! grep -q 'src/c.ts:5' \"$TMP/agg-crit.md\""
check "min-severity=critical keeps blocker finding" "grep -q 'src/a.ts:42' \"$TMP/agg-crit.md\""

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
