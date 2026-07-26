#!/usr/bin/env bash
# tests/prkit-codex-manifest.test.sh — the prkit CODEX-port copy manifest is
# complete and correct. Every listed source exists at the repo root; count is
# locked; excluded files are absent. Pure bash+grep (windows-safe).
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/tools/prkit/manifest-codex.txt"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit codex manifest (RFC 0014 Codex addendum)"

[ -r "$MANIFEST" ] || { echo "  ABORT — manifest-codex missing: $MANIFEST"; exit 99; }

# C1 — every listed path exists under the repo root
missing=0
while IFS= read -r line; do
  line="${line%$'\r'}"   # strip CR — Git-Bash checks out with autocrlf on Windows
  case "$line" in ''|\#*) continue;; esac
  [ -e "$REPO_ROOT/$line" ] || { echo "    missing: $line"; missing=$((missing+1)); }
done < "$MANIFEST"
[ "$missing" -eq 0 ] && ok "C1 every codex-manifest path exists at repo root" \
  || no "C1 $missing codex-manifest path(s) do not exist"

# C2 — count of real entries is 53
count=$(grep -cvE '^\s*(#|$)' "$MANIFEST")
[ "$count" -eq 53 ] && ok "C2 codex manifest lists exactly 53 files" \
  || no "C2 codex manifest lists $count files (expected 53)"

# C3 — excluded files are NOT listed
for bad in codex/uberdev-codex/skills/uberdev-cmd-solve/SKILL.md \
           codex/uberdev-codex/skills/uberdev-cmd-goal/SKILL.md \
           codex/tools/convert-commands.py codex/tools/port-skill.sh; do
  if grep -qxF "$bad" "$MANIFEST"; then no "C3 excluded file present: $bad"; fi
done
[ "$FAIL" -eq 0 ] && ok "C3 no excluded files in codex manifest"

# C4 — the three PR command-skills + installer + converter are present
for req in codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md \
           codex/uberdev-codex/skills/uberdev-cmd-simplify/SKILL.md \
           codex/uberdev-codex/skills/uberdev-cmd-merge/SKILL.md \
           codex/install-codex.sh codex/tools/convert-agents.py; do
  grep -qxF "$req" "$MANIFEST" || no "C4 missing required codex entry: $req"
done
grep -qxF codex/install-codex.sh "$MANIFEST" && ok "C4 command-skills + installer + converter present"

# C5 — native Codex packaging includes the canonical policy projection source
# and its output schema.
for req in codex/uberdev-codex/policy/solve-run-tree-v1.json \
           codex/uberdev-codex/shared/phase1-reviewer-output-v1.md; do
  grep -qxF "$req" "$MANIFEST" || no "C5 missing runtime contract: $req"
done
grep -qxF codex/uberdev-codex/policy/solve-run-tree-v1.json "$MANIFEST" \
  && grep -qxF codex/uberdev-codex/shared/phase1-reviewer-output-v1.md "$MANIFEST" \
  && ok "C5 canonical policy projection source + reviewer output contract present"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
