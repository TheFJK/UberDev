#!/usr/bin/env bash
# tests/prkit-generate.test.sh — end-to-end: generate a prkit tree into a scratch
# target, assert the verify gate passes, and assert determinism (two runs identical).
# Unix-only (perl + python3 + jq); declared in the test.yml windows-skip marker.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/prkit/generate.sh"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit generate e2e (RFC 0014)"
[ -r "$GEN" ] || { echo "  ABORT — generate.sh missing"; exit 99; }

# T1's path deliberately CONTAINS A SPACE ("prkit tgt") — the real target lives at
# "/Volumes/FJK SSD/Cursor/prkit", and an earlier verify.sh regression word-split on
# that space. Keeping a spaced target here locks the fix in. T2 is space-free so G5
# also proves the generated output is independent of the target path.
_B1="$(mktemp -d)"; _B2="$(mktemp -d)"; T1="$_B1/prkit tgt"; T2="$_B2/out"
mkdir -p "$T1" "$T2"; trap 'rm -rf "$_B1" "$_B2"' EXIT
git -C "$T1" init -q; git -C "$T2" init -q

# G1 — generate into a clean target succeeds and self-verifies
if bash "$GEN" --target "$T1" --version 0.1.0 >/dev/null 2>&1; then ok "G1 generate exits 0 (verify passed)"; else no "G1 generate failed"; fi

# G2 — verify gate independently passes on the produced tree
if bash "$VERIFY" "$T1" >/dev/null 2>&1; then ok "G2 verify passes on generated tree"; else no "G2 verify failed on generated tree"; fi

# G3 — EXACTLY 32 source files landed under plugins/prkit (manifest count-lock;
# -eq not -ge so a silently-dropped copy OR a stray extra file both fail)
n=$(find "$T1/plugins/prkit/commands" "$T1/plugins/prkit/agents" "$T1/plugins/prkit/skills" "$T1/plugins/prkit/lib" "$T1/plugins/prkit/policy" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 32 ] && ok "G3 exactly 32 copied files present" || no "G3 copied $n files (expected 32)"

# G4 — scaffold files exist with interpolated version
grep -q '0.1.0' "$T1/plugins/prkit/.claude-plugin/plugin.json" && ok "G4 plugin.json version interpolated" || no "G4 plugin.json version missing"
[ -f "$T1/README.md" ] && [ -f "$T1/.claude-plugin/marketplace.json" ] && ok "G4b README + marketplace scaffolded" || no "G4b scaffold files missing"

# G5 — determinism: second generation into a fresh target is byte-identical
bash "$GEN" --target "$T2" --version 0.1.0 >/dev/null 2>&1
if diff -r "$T1/plugins/prkit" "$T2/plugins/prkit" >/dev/null 2>&1; then ok "G5 deterministic (diff -r empty)"; else no "G5 non-deterministic output"; fi

# G6 — Codex port generated: prkit-cmd-* skills, renamed TOML, installer, manifest
if [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" ] \
   && [ -f "$T1/codex/agents/prkit-code-reviewer.toml" ] \
   && [ -f "$T1/codex/install-codex.sh" ] \
   && grep -q '"name": "prkit-codex"' "$T1/codex/prkit-codex/.codex-plugin/plugin.json"; then
  ok "G6 codex port generated (prkit-cmd-* skills, prkit-*.toml, installer, manifest)"
else no "G6 codex port incomplete"; fi

# G7 — no uberdev token survives anywhere under codex/
if grep -rilE 'uberdev' "$T1/codex" >/dev/null 2>&1; then no "G7 uberdev token survives under codex/"; else ok "G7 codex tree is uberdev-free"; fi

# G8 — codex tree deterministic across the two generations (spaced vs plain path)
if diff -r "$T1/codex" "$T2/codex" >/dev/null 2>&1; then ok "G8 codex deterministic (diff -r empty)"; else no "G8 codex non-deterministic"; fi

# G9 — regeneration CLEANS stale files (the rm -rf clean stage). Plant strays in
# both trees, regenerate into the SAME target, assert they are gone.
printf 'stale\n' > "$T1/plugins/prkit/STALE_CLAUDE.txt"
printf 'stale\n' > "$T1/codex/STALE_CODEX.txt"
bash "$GEN" --target "$T1" --version 0.1.0 --force >/dev/null 2>&1
if [ ! -e "$T1/plugins/prkit/STALE_CLAUDE.txt" ] && [ ! -e "$T1/codex/STALE_CODEX.txt" ]; then
  ok "G9 regeneration removes stale files from both trees"
else no "G9 stale files survived regeneration"; fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
