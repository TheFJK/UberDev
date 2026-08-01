#!/usr/bin/env bash
# tests/prkit-rewrite.test.sh — rewrite ruleset: neutralize out-of-set refs,
# then blanket uberdev->prkit with zero surviving uberdev token.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/tools/prkit/rewrite.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit rewrite ruleset (RFC 0014 §5.4)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$REPO_ROOT/tests/fixtures/prkit/sample-in.md" "$TMP/f.md"

prkit_neutralize "$TMP/f.md"
prkit_apply_rewrites "$TMP/f.md"
OUT="$(cat "$TMP/f.md")"

# R1 — no surviving uberdev (case-insensitive)
grep -iq 'uberdev' <<<"$OUT" && no "R1 uberdev token survived" \
  || ok "R1 zero surviving uberdev token"
# R2 — namespace rewritten
grep -q 'subagent_type: prkit:code-fixer' <<<"$OUT" \
  && grep -q 'Skill(prkit:post-impl-review)' <<<"$OUT" \
  && ok "R2 namespace refs rewritten to prkit:" || no "R2 namespace not rewritten"
# R3 — env var + fn prefix rewritten
grep -q 'PRKIT_MODEL' <<<"$OUT" && grep -q '_prkit_config_read_load' <<<"$OUT" \
  && ok "R3 env var + fn prefix rewritten" || no "R3 env/fn prefix not rewritten"
# R4 — config filename + path rewritten
grep -q '.claude/prkit.local.md' <<<"$OUT" \
  && grep -q 'plugins/prkit/policy/x.json' <<<"$OUT" \
  && ok "R4 config filename + path rewritten" || no "R4 config/path not rewritten"
# R5 — label rewritten
grep -q 'prkit-approved' <<<"$OUT" && ok "R5 label rewritten" || no "R5 label not rewritten"
# R6 — NO dangling out-of-set command refs survive
grep -Eq '(prkit|uberdev):(goal|solve)|/(prkit|uberdev):(goal|solve)' <<<"$OUT" \
  && no "R6 out-of-set goal/solve command ref survived" \
  || ok "R6 no goal/solve command ref survives"
# R7 — idempotent: second pass changes nothing
cp "$TMP/f.md" "$TMP/g.md"; prkit_neutralize "$TMP/g.md"; prkit_apply_rewrites "$TMP/g.md"
diff -q "$TMP/f.md" "$TMP/g.md" >/dev/null && ok "R7 rewrite is idempotent" || no "R7 not idempotent"
# R8 — repo slug stays LOWERCASE prkit (not the CamelCase-mangled TheFJK/Prkit)
grep -q 'TheFJK/prkit' <<<"$OUT" && ! grep -q 'TheFJK/Prkit' <<<"$OUT" \
  && ok "R8 repo slug -> TheFJK/prkit (lowercase)" || no "R8 slug wrong-cased or missing"
# R9 — OUT-OF-SET skills de-namespaced to bare prose (no dangling prkit:<name>);
# in-set (code-fixer, post-impl-review) keep their prefix
grep -Eq 'prkit:(brainstorm|write-plan)' <<<"$OUT" && no "R9 dangling out-of-set prkit:<skill> survived" \
  || { grep -q 'prkit:code-fixer' <<<"$OUT" && grep -q 'prkit:post-impl-review' <<<"$OUT" \
       && ok "R9 out-of-set de-namespaced, in-set kept" || no "R9 in-set ref lost"; }
# R10 — the inline `next: /uberdev:solve <URL>` fragment keeps BALANCED backticks
# (the site-494 mangling class: the neutralizer must not eat the trailing backtick)
bt=$(echo "$OUT" | grep 'inline: run' | tr -cd '`' | wc -c | tr -d ' ')
[ "$((bt % 2))" -eq 0 ] && [ "$bt" -gt 0 ] && ok "R10 inline-code backticks stay balanced ($bt)" \
  || no "R10 backtick imbalance ($bt) — arg/backtick eaten"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
