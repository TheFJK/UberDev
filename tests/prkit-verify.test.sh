#!/usr/bin/env bash
# tests/prkit-verify.test.sh — the verify gate FAILS a broken tree and PASSES a clean one.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit verify gate (RFC 0014 §5.6)"
[ -x "$VERIFY" ] || [ -r "$VERIFY" ] || { echo "  ABORT — verify.sh missing"; exit 99; }

mk_clean() {
  local d="$1"
  mkdir -p "$d/plugins/prkit/agents" "$d/plugins/prkit/skills/post-impl-review" \
           "$d/plugins/prkit/skills/merge-pipeline" "$d/plugins/prkit/lib" \
           "$d/plugins/prkit/policy" "$d/plugins/prkit/commands" \
           "$d/plugins/prkit/.claude-plugin"
  printf 'dispatch subagent_type: prkit:code-reviewer\nSkill(prkit:post-impl-review)\n' > "$d/plugins/prkit/commands/review-pr.md"
  printf 'x\n' > "$d/plugins/prkit/commands/simplify.md"
  printf 'x\n' > "$d/plugins/prkit/commands/merge.md"
  printf '# code-reviewer\n' > "$d/plugins/prkit/agents/code-reviewer.md"
  printf 'name: post-impl-review\n' > "$d/plugins/prkit/skills/post-impl-review/SKILL.md"
  printf 'name: merge-pipeline\n' > "$d/plugins/prkit/skills/merge-pipeline/SKILL.md"
  printf 'echo ok\n' > "$d/plugins/prkit/lib/x.sh"
  printf '{}\n' > "$d/plugins/prkit/policy/model-routing-v1.json"
  printf '{"name":"prkit"}\n' > "$d/plugins/prkit/.claude-plugin/plugin.json"
  printf 'prkit\nUberDev attribution only\n' > "$d/NOTICE"
}

# V1 — clean tree passes
C="$(mktemp -d)"; mk_clean "$C"
if bash "$VERIFY" "$C" >/dev/null 2>&1; then ok "V1 clean tree passes"; else no "V1 clean tree rejected"; fi

# V2 — surviving uberdev token fails
B1="$(mktemp -d)"; mk_clean "$B1"; printf 'export UBERDEV_MODEL=x\n' >> "$B1/plugins/prkit/lib/x.sh"
if bash "$VERIFY" "$B1" >/dev/null 2>&1; then no "V2 surviving uberdev token accepted"; else ok "V2 surviving uberdev token fails"; fi

# V3 — dangling namespace ref (prkit:ghost with no agent) fails
B2="$(mktemp -d)"; mk_clean "$B2"; printf 'subagent_type: prkit:ghost-agent\n' >> "$B2/plugins/prkit/commands/review-pr.md"
if bash "$VERIFY" "$B2" >/dev/null 2>&1; then no "V3 dangling prkit ref accepted"; else ok "V3 dangling prkit ref fails"; fi

# V4 — residual out-of-set ref (prkit:goal) fails
B3="$(mktemp -d)"; mk_clean "$B3"; printf 'chain to /prkit:goal here\n' >> "$B3/plugins/prkit/commands/review-pr.md"
if bash "$VERIFY" "$B3" >/dev/null 2>&1; then no "V4 residual prkit:goal accepted"; else ok "V4 residual out-of-set ref fails"; fi

# V5 — NOTICE allowlist: 'UberDev' in NOTICE alone does NOT fail
C2="$(mktemp -d)"; mk_clean "$C2"
if bash "$VERIFY" "$C2" >/dev/null 2>&1; then ok "V5 NOTICE-only uberdev is allowlisted"; else no "V5 NOTICE allowlist broken"; fi

rm -rf "$C" "$B1" "$B2" "$B3" "$C2"
echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
