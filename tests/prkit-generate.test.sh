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

# G3 — EXACTLY 34 source files landed under plugins/prkit (manifest count-lock;
# -eq not -ge so a silently-dropped copy OR a stray extra file both fail)
n=$(find "$T1/plugins/prkit/commands" "$T1/plugins/prkit/agents" "$T1/plugins/prkit/skills" "$T1/plugins/prkit/lib" "$T1/plugins/prkit/policy" "$T1/plugins/prkit/shared" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 34 ] && ok "G3 exactly 34 copied files present" || no "G3 copied $n files (expected 34)"

# G4 — scaffold files exist with interpolated version
grep -q '0.1.0' "$T1/plugins/prkit/.claude-plugin/plugin.json" && ok "G4 plugin.json version interpolated" || no "G4 plugin.json version missing"
[ -f "$T1/README.md" ] && [ -f "$T1/.claude-plugin/marketplace.json" ] && ok "G4b README + marketplace scaffolded" || no "G4b scaffold files missing"

# G5 — determinism: second generation into a fresh target is byte-identical
bash "$GEN" --target "$T2" --version 0.1.0 >/dev/null 2>&1
if diff -r "$T1/plugins/prkit" "$T2/plugins/prkit" >/dev/null 2>&1; then ok "G5 deterministic (diff -r empty)"; else no "G5 non-deterministic output"; fi

# G6 — Codex port generated: prkit-cmd-* skills, renamed TOML, installer, manifest,
# and prkit-PREFIXED support skills (flat ~/.agents/skills/ coexistence) with NO
# un-prefixed post-impl-review/merge-pipeline dir that would collide with UberDev-codex
if [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-post-impl-review/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-merge-pipeline/SKILL.md" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/post-impl-review" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/merge-pipeline" ] \
   && [ -f "$T1/codex/agents/prkit-code-reviewer.toml" ] \
   && [ -f "$T1/codex/install-codex.sh" ] \
   && grep -q '"name": "prkit-codex"' "$T1/codex/prkit-codex/.codex-plugin/plugin.json"; then
  ok "G6 codex port generated (prkit-cmd-* + prkit-prefixed support skills, no flat collision)"
else no "G6 codex port incomplete or has un-prefixed support skill"; fi

# G6a — the copied full-UberDev installer is rewritten to the standalone
# manifest's actual fleet size. These hints are user-facing verification, so a
# successful install must not claim the full 39/44 fleet.
if grep -qF '# 5 prkit skills' "$T1/codex/install-codex.sh" \
   && grep -qF '# 14 prkit-*.toml subagents' "$T1/codex/install-codex.sh" \
   && grep -qF 'NOT the 14 agents' "$T1/codex/install-codex.sh" \
   && ! grep -Eq '(^|[^0-9])(39|44)([^0-9]|$)' "$T1/codex/install-codex.sh"; then
  ok "G6a standalone installer reports the manifest-true 5 skills / 14 agents"
else no "G6a standalone installer retains full-UberDev fleet counts"; fi

# G6aa — exercise the rewrite transaction itself against synthetic drift. A
# traversal/count mismatch and a missing substitution anchor must both fail
# before touching the installer.
if python3 -I -B - "$GEN" <<'PY'
import pathlib,subprocess,sys,tempfile
source=pathlib.Path(sys.argv[1]).read_text()
marker='  python3 -I -B - "$TARGET" <<\'PY\' || {'
snippet=source.split(marker,1)[1].split('\nPY\n',1)[0]
anchors='NOT the 44 agents\n# ~39 Prkit skills incl. command-skills\n# 44 prkit-*.toml subagents\n'
def fixture(skills,installer_text):
 root=pathlib.Path(tempfile.mkdtemp()); (root/'codex/prkit-codex/skills').mkdir(parents=True); (root/'codex/agents').mkdir()
 for index in range(skills): (root/f'codex/prkit-codex/skills/s{index}').mkdir()
 for index in range(14): (root/f'codex/agents/prkit-a{index}.toml').write_text('x')
 target=root/'codex/install-codex.sh'; target.write_text(installer_text)
 return root,target
for root,target in (fixture(6,anchors),fixture(5,anchors.replace('NOT the 44 agents','anchor drift'))):
 before=target.read_bytes()
 result=subprocess.run([sys.executable,'-I','-B','-',str(root)],input=snippet,text=True,capture_output=True)
 assert result.returncode!=0,result
 assert target.read_bytes()==before
PY
then ok "G6aa count discovery and anchor drift fail closed without mutation"
else no "G6aa generator count/anchor transaction accepted drift"; fi

# G6b — both standalone runtimes ship the manifest-declared reviewer contract,
# while native Codex role TOMLs remain edge-agnostic.
if [ -f "$T1/plugins/prkit/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/plugins/prkit/shared/phase1-reviewer-output-v1.md" ] \
   && [ -f "$T1/codex/prkit-codex/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/codex/prkit-codex/shared/phase1-reviewer-output-v1.md" ] \
   && python3 - "$T1" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); contract=(root/'codex/prkit-codex/shared/phase1-reviewer-output-v1.md').read_text()
roles=('code-reviewer','silent-failure-hunter','type-design-analyzer','comment-analyzer','pr-test-analyzer')
assert all(contract not in (root/f'codex/agents/prkit-{role}.toml').read_text() for role in roles)
PY
then ok "G6b routed reviewer contract packaged and absent from native roles"
else no "G6b reviewer contract scope is incorrect"; fi

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
