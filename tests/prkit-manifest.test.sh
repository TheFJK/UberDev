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
  line="${line%$'\r'}"   # strip CR — Git-Bash checks out with autocrlf on Windows
  case "$line" in ''|\#*) continue;; esac
  [ -e "$SRC/$line" ] || { echo "    missing: $line"; missing=$((missing+1)); }
done < "$MANIFEST"
[ "$missing" -eq 0 ] && ok "M1 every manifest path exists in plugins/uberdev/" \
  || no "M1 $missing manifest path(s) do not exist"

# M2 — count of real (non-comment, non-blank) entries is 34
count=$(grep -cvE '^\s*(#|$)' "$MANIFEST")
[ "$count" -eq 34 ] && ok "M2 manifest lists exactly 34 files" \
  || no "M2 manifest lists $count files (expected 34)"

# M3 — excluded files are NOT listed (goal-state, hooks, aliases)
for bad in lib/goal-state.sh lib/aliases-sync.sh \
           hooks/session-start commands/install-aliases.md commands/solve.md \
           commands/goal.md; do
  if grep -qxF "$bad" "$MANIFEST"; then no "M3 excluded file present: $bad"; fi
done
[ "$FAIL" -eq 0 ] && ok "M3 no excluded files in manifest"

# M4 — the three entry commands are present
for c in commands/review-pr.md commands/simplify.md commands/merge.md; do
  grep -qxF "$c" "$MANIFEST" || no "M4 missing entry command: $c"
done
grep -qxF commands/review-pr.md "$MANIFEST" && grep -qxF commands/merge.md "$MANIFEST" \
  && ok "M4 all three entry commands present"

# M5 — the canonical policy projection source and routed review validation
# data are part of the standalone package.
for req in policy/solve-run-tree-v1.json shared/phase1-reviewer-output-v1.md; do
  grep -qxF "$req" "$MANIFEST" || no "M5 missing runtime contract: $req"
done
grep -qxF policy/solve-run-tree-v1.json "$MANIFEST" \
  && grep -qxF shared/phase1-reviewer-output-v1.md "$MANIFEST" \
  && ok "M5 canonical policy projection source + reviewer output contract present"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
