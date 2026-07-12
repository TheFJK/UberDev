#!/usr/bin/env bash
# tests/prkit-manifest.test.sh — the prkit copy manifest is complete and correct.
# Every listed source exists under plugins/uberdev/; excluded files are absent;
# count matches the RFC 0014 copy set.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/plugins/uberdev"
MANIFEST="$REPO_ROOT/tools/prkit/manifest.txt"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit manifest (RFC 0014)"

[ -r "$MANIFEST" ] || { echo "  ABORT — manifest missing: $MANIFEST"; exit 99; }

# M1 — every listed path exists under plugins/uberdev/
missing=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  [ -e "$SRC/$line" ] || { echo "    missing: $line"; missing=$((missing+1)); }
done < "$MANIFEST"
[ "$missing" -eq 0 ] && ok "M1 every manifest path exists in plugins/uberdev/" \
  || no "M1 $missing manifest path(s) do not exist"

# M2 — count of real (non-comment, non-blank) entries is 32
count=$(grep -cvE '^\s*(#|$)' "$MANIFEST")
[ "$count" -eq 32 ] && ok "M2 manifest lists exactly 32 files" \
  || no "M2 manifest lists $count files (expected 32)"

# M3 — excluded files are NOT listed (goal-state, solve-run-tree, hooks, aliases)
for bad in lib/goal-state.sh policy/solve-run-tree-v1.json lib/aliases-sync.sh \
           hooks/session-start commands/install-aliases.md commands/solve.md \
           commands/goal.md; do
  if grep -qxF "$bad" "$MANIFEST"; then no "M3 excluded file present: $bad"; FAIL=$((FAIL+1)); fi
done
[ "$FAIL" -eq 0 ] && ok "M3 no excluded files in manifest"

# M4 — the three entry commands are present
for c in commands/review-pr.md commands/simplify.md commands/merge.md; do
  grep -qxF "$c" "$MANIFEST" || no "M4 missing entry command: $c"
done
grep -qxF commands/review-pr.md "$MANIFEST" && grep -qxF commands/merge.md "$MANIFEST" \
  && ok "M4 all three entry commands present"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
