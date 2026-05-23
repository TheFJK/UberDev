#!/opt/homebrew/bin/bash
# Snapshot a /goal run after sleeping $1 seconds (default 600). Portable: reads
# the goal-run log from $GOAL_LOG (default ./.goal-run.log in $GOAL_REPO/cwd).
sleep "${1:-600}"
REPO="${GOAL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO" 2>/dev/null || true
LOG="${GOAL_LOG:-.goal-run.log}"
echo "===================== GOAL MONITOR $(date -u +%H:%M:%S) ($REPO) ====================="
echo "--- ${LOG} (last 30) ---"; tail -n 30 "$LOG" 2>&1
echo "--- live agent sessions ---"
claude agents --json 2>/dev/null | python3 -c "
import sys,json
arr=json.load(sys.stdin)
print('background sessions:', sum(1 for a in arr if a.get('kind')=='background'))
for a in arr: print(f\"  {a['sessionId'][:8]} {a['kind']:11} {a['status']:8} {(a.get('cwd','') or '').split('/')[-1]}\")" 2>&1
echo "--- PRs (feat/* heads) ---"
gh pr list --state all --limit 20 --json number,state,headRefName --jq '.[] | select(.headRefName|startswith("feat/")) | "#\(.number) \(.state) \(.headRefName)"' 2>&1 | head -20
echo "--- review-pr-finding issues (open) ---"
gh issue list --label review-pr-finding --state open --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>&1 | head
echo "--- driver alive? ---"
pgrep -f 'goal-driver' >/dev/null && echo "RUNNING ($(pgrep -f goal-driver | tr '\n' ' '))" || echo "NOT RUNNING (exited)"
echo "============================================================================"
