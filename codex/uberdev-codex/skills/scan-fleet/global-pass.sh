#!/usr/bin/env bash
# skills/scan-fleet/global-pass.sh — the repo-global Semgrep SAST + test-coverage
# pass for /uberscan (scan mode). Extracted verbatim from the legacy
# uberscan-pipeline Phase 1b so it can be (a) invoked by the scan-fleet.js
# global-pass relay agent — workflow.js cannot embed Python `import` tokens (the
# T1 self-contained-script grep forbids them) — and (b) reused by the
# uberscan-pipeline No-Workflow fallback. Writes the two artifacts report.py
# read_global() consumes BY NAME (global-security.md / global-coverage.md).
#
# Usage:  global-pass.sh <scope> <run_dir>
# Fail-soft: a missing/erroring semgrep or python3 degrades to a skip note and
# this script still exits 0 (the advisory global pass must NEVER abort the audit).
set -u

SCOPE="${1:-.}"
RUN_DIR="${2:?global-pass.sh: run_dir (arg 2) is required}"

SEC_OUT="$RUN_DIR/global-security.md"
SEC_JSON="$RUN_DIR/.semgrep.json"
COV_OUT="$RUN_DIR/global-coverage.md"

# --- Semgrep SAST (fail-soft). Decouple semgrep's EXIT CODE from the parse
# decision: it may exit non-zero while still having written valid populated JSON. ---
if command -v semgrep >/dev/null 2>&1; then
  semgrep scan --config auto --json --quiet --timeout 0 --output "$SEC_JSON" "$SCOPE" >/dev/null 2>&1 || true
  if [ -s "$SEC_JSON" ]; then
    python3 - "$SEC_JSON" > "$SEC_OUT" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"_(Semgrep output unparseable: {exc})_"); raise SystemExit(0)
results = data.get("results") or []
rank = {"ERROR": 0, "WARNING": 1, "INFO": 2}
results.sort(key=lambda r: rank.get((r.get("extra") or {}).get("severity", "INFO"), 3))
if not results:
    print("_(Semgrep ran clean — no findings.)_"); raise SystemExit(0)
print(f"Semgrep flagged {len(results)} finding(s) (top 100 by severity):\n")
for r in results[:100]:
    extra = r.get("extra") or {}
    lines = (extra.get("message") or "").strip().splitlines()
    msg = lines[0][:200] if lines else ""
    start = r.get("start") or {}
    print(f"- **{extra.get('severity','INFO')}** `{r.get('check_id','?')}` "
          f"{r.get('path','?')}:{start.get('line','?')} — {msg}")
PY
  else
    echo "_(Semgrep produced no parseable output for scope \`$SCOPE\` — SAST pass skipped this run.)_" > "$SEC_OUT"
  fi
else
  echo "_(Semgrep not installed — SAST pass skipped. Install semgrep to enable.)_" > "$SEC_OUT"
fi
rm -f "$SEC_JSON" 2>/dev/null || true

# --- Test-coverage heuristic (fail-soft). The whole computation is buffered into
# one string and the try/except wraps it, so the artifact is EITHER the full
# report OR a single skip note — never a partial write capped by a traceback. ---
python3 - "$SCOPE" > "$COV_OUT" 2>/dev/null <<'PY' || printf '_(Test-coverage heuristic skipped — python3 unavailable or crashed.)_\n' > "$COV_OUT"
import os, subprocess, sys

def build(scope):
    out = subprocess.run(["git", "ls-files", "--", scope], capture_output=True, text=True)
    files = [f for f in out.stdout.splitlines() if f]
    SRC_EXT = (".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".rb", ".java", ".sh", ".php")
    TEST_MARK = (".test.", ".spec.", "_test.", "test_", "/tests/", "/test/", "/__tests__/")
    src, tests = [], []
    for f in files:
        if not f.endswith(SRC_EXT):
            continue
        (tests if any(m in f for m in TEST_MARK) else src).append(f)
    stems = set()
    for t in tests:
        base = os.path.basename(t)
        for tok in (".test", ".spec", "test_", "_test"):
            base = base.replace(tok, "")
        stems.add(base.split(".")[0])
    untested = []
    for s in src:
        if os.path.basename(s).split(".")[0] in stems:
            continue
        try:
            n = sum(1 for _ in open(s, errors="ignore"))
        except OSError:
            n = 0
        if n > 200:
            untested.append((s, n))
    untested.sort(key=lambda kv: -kv[1])
    ratio = len(tests) / max(1, len(src))
    lines = [f"Source files: {len(src)} · Test files: {len(tests)} · test:source ratio {ratio:.2f}\n",
             f"Large (>200-line) source files with no matching test file: {len(untested)}\n"]
    lines += [f"- {s} ({n} lines)" for s, n in untested[:30]]
    if not untested:
        lines.append("_(No large untested source files detected.)_")
    return "\n".join(lines)

scope = sys.argv[1] if len(sys.argv) > 1 else "."
try:
    sys.stdout.write(build(scope) + "\n")
except Exception as exc:
    sys.stdout.write(f"_(Test-coverage heuristic skipped — {type(exc).__name__}: {exc})_\n")
PY

exit 0
