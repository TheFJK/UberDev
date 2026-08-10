#!/usr/bin/env bash
# tests/prkit-verify.test.sh — the verify gate PASSES a real generated tree and
# FAILS each injected defect. Unix-only (perl+python3+jq via generate); declared
# in the test.yml windows-skip marker. Uses a real generated baseline (not a
# hand-built stub) so the stricter non-vacuity / ref-integrity / syntax-count /
# out-of-set / scaffold / placeholder checks are exercised against realistic input
# (issue #334 review, test-analyzer P1). The codex fail-path went with the Codex
# port stage (issue #381).
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/prkit/generate.sh"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit verify gate (RFC 0014 §5.6)"
[ -r "$VERIFY" ] || { echo "  ABORT — verify.sh missing"; exit 99; }

BASEP="$(mktemp -d)"; BASE="$BASEP/clean"; BASE_EMPTY_TEMPLATE="$BASEP/empty-template"
BASE_EMPTY_CONFIG="$BASEP/empty.gitconfig"
mkdir -p "$BASE" "$BASE_EMPTY_TEMPLATE"
: > "$BASE_EMPTY_CONFIG"
git -C "$BASE" init -q --template="$BASE_EMPTY_TEMPLATE"
trap 'rm -rf "$BASEP"' EXIT
bash "$GEN" --target "$BASE" --version 0.1.0 >/dev/null 2>&1 || { echo "  ABORT — baseline generation failed"; exit 99; }

# V1 — the clean generated tree passes and reports the managed ignore contract
V1_OUTPUT=""
if V1_OUTPUT="$(bash "$VERIFY" "$BASE" 2>&1)" \
   && grep -qF \
     'artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock' \
     <<<"$V1_OUTPUT"; then
  ok "V1 clean generated tree passes with the managed artifact-ignore contract"
else
  no "V1 clean generated tree rejected or artifact-ignore diagnostic missing"
fi

# V1b — verifier scratch metadata must not inherit user init templates. The
# injected template ignores the root generation lock; target .gitignore must
# remain the effective source for the managed artifact rule.
V1B_INIT_TEMPLATE="$BASEP/init-template"
V1B_GLOBAL_CONFIG="$BASEP/global.gitconfig"
mkdir -p "$V1B_INIT_TEMPLATE/info"
printf '.prkit-generate.lock\n' > "$V1B_INIT_TEMPLATE/info/exclude"
git config --file "$V1B_GLOBAL_CONFIG" init.templateDir "$V1B_INIT_TEMPLATE"
V1B_OUTPUT=""
V1B_ARTIFACT_SOURCE="$(
  GIT_CONFIG_GLOBAL="$V1B_GLOBAL_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$BASE" -c core.excludesFile=/dev/null \
      check-ignore -v --no-index -- .prkit/audit.jsonl 2>/dev/null
)"
if V1B_OUTPUT="$(
     GIT_CONFIG_GLOBAL="$V1B_GLOBAL_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
       bash "$VERIFY" "$BASE" 2>&1
   )" \
   && grep -qF \
     'artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock' \
     <<<"$V1B_OUTPUT" \
   && case "$V1B_ARTIFACT_SOURCE" in
        .gitignore:*:.prkit/$'\t'.prkit/audit.jsonl) true ;;
        *) false ;;
      esac
then
  ok "V1b verifier ignores hostile init template and uses target .gitignore"
else
  no "V1b verifier inherited hostile init template or lost target .gitignore source"
fi

# V1c — a user-global excludes file is not verifier evidence. Even if it ignores
# both probe paths, only the generated target's .gitignore may decide the contract.
V1C_GLOBAL_EXCLUDES="$BASEP/global-excludes"
V1C_GLOBAL_CONFIG="$BASEP/global-excludes.gitconfig"
printf '.prkit*\n' > "$V1C_GLOBAL_EXCLUDES"
git config --file "$V1C_GLOBAL_CONFIG" core.excludesFile "$V1C_GLOBAL_EXCLUDES"
V1C_OUTPUT=""
if V1C_OUTPUT="$(
     GIT_CONFIG_GLOBAL="$V1C_GLOBAL_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
       bash "$VERIFY" "$BASE" 2>&1
   )" \
   && grep -qF \
     'artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock' \
     <<<"$V1C_OUTPUT"
then
  ok "V1c verifier ignores hostile global excludes"
else
  no "V1c verifier inherited hostile global excludes"
fi

# V1d — command-scope Git configuration outranks system/global files. Both
# transport forms are hostile here, including stale indexed variables beyond
# GIT_CONFIG_COUNT; verifier-owned Git calls must neutralize all of them.
V1D_COMMAND_EXCLUDES="$BASEP/command-excludes"
V1D_COMMAND_TEMPLATE="$BASEP/command-template"
mkdir -p "$V1D_COMMAND_TEMPLATE/info"
printf '.prkit*\n' > "$V1D_COMMAND_EXCLUDES"
printf '.prkit-generate.lock\n' > "$V1D_COMMAND_TEMPLATE/info/exclude"
V1D_CONFIG_PARAMETERS="'core.excludesFile'='$V1D_COMMAND_EXCLUDES' 'init.templateDir'='$V1D_COMMAND_TEMPLATE'"
V1D_OUTPUT=""
if V1D_OUTPUT="$(
     GIT_CONFIG_COUNT=2 \
     GIT_CONFIG_KEY_0=core.excludesFile \
     GIT_CONFIG_VALUE_0="$V1D_COMMAND_EXCLUDES" \
     GIT_CONFIG_KEY_1=init.templateDir \
     GIT_CONFIG_VALUE_1="$V1D_COMMAND_TEMPLATE" \
     GIT_CONFIG_KEY_7=core.excludesFile \
     GIT_CONFIG_VALUE_7="$V1D_COMMAND_EXCLUDES" \
     GIT_CONFIG_PARAMETERS="$V1D_CONFIG_PARAMETERS" \
       bash "$VERIFY" "$BASE" 2>&1
   )" \
   && grep -qF \
     'artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock' \
     <<<"$V1D_OUTPUT"
then
  ok "V1d verifier ignores hostile command-scope Git configuration"
else
  no "V1d verifier inherited hostile command-scope Git configuration"
fi

# V1e — verify.sh supports a generated tree that has not been git init'd yet.
V1E_NONGIT="$BASEP/non-git"
cp -R "$BASE" "$V1E_NONGIT"
rm -rf "$V1E_NONGIT/.git"
if bash "$VERIFY" "$V1E_NONGIT" >/dev/null 2>&1; then
  ok "V1e clean non-Git generated tree passes"
else
  no "V1e clean non-Git generated tree rejected"
fi

# V1f — Git treats CRLF rules as valid. Comments and blank lines are inert and
# remain allowed around the canonical generated rules.
V1F_CRLF="$BASEP/crlf"
cp -R "$BASE" "$V1F_CRLF"
python3 - "$V1F_CRLF/.gitignore" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
raw=p.read_bytes()
p.write_bytes(
    b"# generated rules\r\n"
    b"   \r\n"
    + raw.replace(b"\n",b"\r\n")
)
PY
if bash "$VERIFY" "$V1F_CRLF" >/dev/null 2>&1; then
  ok "V1f CRLF gitignore with comments and whitespace-only blanks passes"
else
  no "V1f CRLF gitignore with comments or whitespace-only blanks rejected"
fi

# expect_fail <desc> <mutate-cmd> : copy baseline, apply mutation on $d, assert verify FAILS
expect_fail(){
  local desc="$1" mutate="$2" dp d
  dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"
  eval "$mutate"
  if bash "$VERIFY" "$d" >/dev/null 2>&1; then no "$desc (verify wrongly PASSED)"; else ok "$desc"; fi
  rm -rf "$dp"
}

# expect_fail_diag <desc> <mutate-cmd> <diagnostic> : as above, but also require
# the verifier to identify the exact failed contract instead of failing elsewhere.
expect_fail_diag(){
  local desc="$1" mutate="$2" diagnostic="$3" dp d output
  dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"
  eval "$mutate"
  if output="$(bash "$VERIFY" "$d" 2>&1)"; then
    no "$desc (verify wrongly PASSED)"
  elif ! grep -qF "$diagnostic" <<<"$output"; then
    no "$desc (expected diagnostic missing)"
  else
    ok "$desc"
  fi
  rm -rf "$dp"
}

# assembled at runtime so this test file's own bytes never contain the token
UB="UBERDEV""_INJECTED_LEAK=1"

expect_fail "V2 uberdev token in plugins/prkit fails"       'printf "%s\n" "$UB" >> "$d/plugins/prkit/lib/dispatch.sh"'
expect_fail "V4 dangling dispatched agent ref fails"        'printf "subagent_type: prkit:ghost-agent\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V5 residual prkit:goal fails"                  'printf "chain to /prkit:goal here\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V6 dangling out-of-set prkit:brainstorm fails" 'printf "see prkit:brainstorm for ideation\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V7 unrendered {{VERSION}} placeholder fails"   'printf "version {{VERSION}} here\n" >> "$d/README.md"'
expect_fail "V8 empty marketplace.json fails"               ': > "$d/.claude-plugin/marketplace.json"'
expect_fail "V8k root scaffold directory fails"               'rm -f "$d/README.md"; mkdir "$d/README.md"; printf "sentinel\n" > "$d/README.md/sentinel.txt"'
expect_fail "V8l root scaffold symlink fails"                 'rm -f "$d/NOTICE"; ln -s "$d/LICENSE" "$d/NOTICE"'
expect_fail "V8n generated-tree ancestor symlink fails"       'mv "$d/plugins" "$dp/outside-plugins"; ln -s "$dp/outside-plugins" "$d/plugins"'
# V8o/V8p RETARGETED, not dropped: they proved the sealed-tree walk rejects a
# nested link/special file. Their old victim was codex/; the same walk covers
# plugins/prkit, so the class is exercised there instead of retired.
expect_fail "V8o nested generated-tree symlink fails"         'printf "outside\n" > "$dp/outside-file"; ln -s "$dp/outside-file" "$d/plugins/prkit/nested-link"'
expect_fail "V8p nested generated-tree special file fails"    'mkfifo "$d/plugins/prkit/nested-pipe"'
ARTIFACT_IGNORE_DIAGNOSTIC='artifact-ignore: .gitignore must contain an effective .prkit/ rule and leave .prkit-generate.lock unignored'
expect_fail_diag "V8q altered .prkit/** rule fails" 'python3 - "$d/.gitignore" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace(".prkit/\n", ".prkit/**\n"))
PY' "$ARTIFACT_IGNORE_DIAGNOSTIC"
expect_fail_diag "V8r broad .prkit* rule cannot hide generation lock" 'python3 - "$d/.gitignore" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace(".prkit/\n", ".prkit*\n"))
PY' "$ARTIFACT_IGNORE_DIAGNOSTIC"
expect_fail_diag "V8s additive overbroad rules cannot bypass canonical rule" 'python3 - "$d/.gitignore" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace(".prkit/\n", ".prkit*\n!.prkit-generate.lock\n.prkit/\n"))
PY' "$ARTIFACT_IGNORE_DIAGNOSTIC"
expect_fail_diag "V8t missing canonical .prkit/ rule fails" 'python3 - "$d/.gitignore" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace(".prkit/\n", ""))
PY' "$ARTIFACT_IGNORE_DIAGNOSTIC"
expect_fail_diag "V8u duplicate canonical .prkit/ rule fails" 'printf ".prkit/\n" >> "$d/.gitignore"' "$ARTIFACT_IGNORE_DIAGNOSTIC"
expect_fail_diag "V8v leading-space pseudo-comment remains an active rule" 'printf " #not-a-comment\n" >> "$d/.gitignore"' "$ARTIFACT_IGNORE_DIAGNOSTIC"

# Git ignores an ASCII-space-only line, but a tab remains a literal pattern
# byte. Prove the fixture through Git itself before requiring verifier rejection.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"
V8W_TAB_PATTERN=$'\t \t'
printf '%s\n' "$V8W_TAB_PATTERN" >> "$d/.gitignore"
if (
     unset GIT_CONFIG_PARAMETERS
     GIT_CONFIG_COUNT=0 \
     GIT_CONFIG_NOSYSTEM=1 \
     GIT_CONFIG_GLOBAL="$BASE_EMPTY_CONFIG" \
       git -C "$d" -c core.excludesFile=/dev/null \
         check-ignore -q --no-index -- "$V8W_TAB_PATTERN"
   ) \
   && ! V8W_OUTPUT="$(bash "$VERIFY" "$d" 2>&1)" \
   && grep -qF "$ARTIFACT_IGNORE_DIAGNOSTIC" <<<"$V8W_OUTPUT"; then
  ok "V8w Git-active tab rule is rejected"
else
  no "V8w tab rule semantics or verifier rejection regressed"
fi
rm -rf "$dp"

expect_fail "V9 removed all agents (non-vacuity/ref-int) fails" 'rm -rf "$d/plugins/prkit/agents"'
expect_fail "V10 removed Claude reviewer contract fails" 'rm -f "$d/plugins/prkit/shared/phase1-reviewer-output-v1.md"'
expect_fail "V10b removed Claude authority helper fails" 'rm -f "$d/plugins/prkit/lib/code_fixer_contract.py"'
expect_fail "V13 out-of-scope policy edge fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["edges"]["solve.issue.lead"]={"kind":"skill"}; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V14 unshipped provider role fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); next(edge for edge in tree["edges"].values() if edge.get("kind")=="provider")["role"]="ghost-agent"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V15 unknown workflow in policy fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); next(edge for edge in tree["edges"].values() if edge.get("kind")=="provider")["allowed_workflows"].append("unknown"); p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V17 duplicate policy JSON key fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(); p.write_text(text.replace("{", "{\n  \"schema_version\": 1,", 1))
PY'
expect_fail "V18 non-finite policy JSON constant fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(); p.write_text(text.replace("{", "{\n  \"non_finite\": NaN,", 1))
PY'
expect_fail "V19 unknown policy root key fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["unknown_root"]="must-not-survive"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V20 unexpected review provider edge fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); source=tree["edges"]["review_pr.review.correctness"].copy(); source["allowed_workflows"]=["review-pr"]; tree["edges"]["review_pr.review.unexpected"]=source; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V21 incomplete generated role fleet fails" 'rm -f "$d/plugins/prkit/agents/merge-strategy-decider.md"'
expect_fail "V22 reviewer-role swap fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); left=tree["edges"]["review_pr.review.correctness"]; right=tree["edges"]["review_pr.review.comments"]; left["role"],right["role"]=right["role"],left["role"]; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V23 workflow swap fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); left=tree["edges"]["review_pr.fix.phase2"]; right=tree["edges"]["simplify.fix.phase2"]; left["allowed_workflows"],right["allowed_workflows"]=right["allowed_workflows"],left["allowed_workflows"]; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V24 unexpected edge contract fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["edges"]["review_pr.fix.phase1"]["output_contract"]="phase1-reviewer-v1"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V24b fixer optional-input drift fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["edges"]["simplify.fix.phase2"]["optional_inputs"]={"unexpected":"string"}; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V24c fixer route-posture drift fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["edges"]["simplify.fix.phase2"]["phase"]="review_fix"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'

# V25 — a placeholder scan error is unavailable evidence, never proof that the
# generated output is clean. The wrapper passes every earlier grep through and
# fails only the final placeholder-pattern invocation.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/grep" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *A-Z0-9_*) exit 2 ;;
esac
exec "$PRKIT_REAL_GREP" "$@"
SH
chmod +x "$dp/bin/grep"
real_grep="$(command -v grep)"
V25_OUTPUT=""
if V25_OUTPUT="$(PATH="$dp/bin:$PATH" PRKIT_REAL_GREP="$real_grep" \
     bash "$VERIFY" "$d" 2>&1)"; then
  no "V25 placeholder scan error fails closed (verify wrongly PASSED)"
elif ! grep -qF 'placeholders: scan errored' <<<"$V25_OUTPUT"; then
  no "V25 placeholder scan error fails closed (expected diagnostic missing)"
else
  ok "V25 placeholder scan error fails closed"
fi
rm -rf "$dp"

# V26 — Git execution errors are infrastructure failures, not evidence that the
# generated target's managed rule is invalid. Preserve the exact failing rc.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" check-ignore "*) exit 73 ;;
esac
exec "$PRKIT_REAL_GIT" "$@"
SH
chmod +x "$dp/bin/git"
real_git="$(command -v git)"
V26_OUTPUT=""
if V26_OUTPUT="$(PATH="$dp/bin:$PATH" PRKIT_REAL_GIT="$real_git" \
     bash "$VERIFY" "$d" 2>&1)"; then
  no "V26 Git check-ignore error fails closed (verify wrongly PASSED)"
elif ! grep -qF \
  'artifact-ignore: infrastructure error: git check-ignore for .prkit/audit.jsonl failed (rc=73)' \
  <<<"$V26_OUTPUT"; then
  no "V26 Git check-ignore error fails closed (exact infrastructure diagnostic missing)"
elif grep -qF "$ARTIFACT_IGNORE_DIAGNOSTIC" <<<"$V26_OUTPUT"; then
  no "V26 Git check-ignore error was misclassified as invalid target rule"
else
  ok "V26 Git check-ignore error preserves rc and infrastructure classification"
fi
rm -rf "$dp"

# V27 — a forged verbose match from an outside .gitignore must never satisfy the
# managed-source proof. The wrapper supports both the legacy text form (to prove
# the regression goes RED) and the NUL-delimited stdin form required by the fix.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" check-ignore -v "*)
    case " $* " in
      *" -z "*)
        printf '%s\0%s\0%s\0%s\0' \
          "$PRKIT_WRONG_SOURCE" 6 '.prkit/' '.prkit/audit.jsonl'
        ;;
      *)
        printf '%s:%s:%s\t%s\n' \
          "$PRKIT_WRONG_SOURCE" 6 '.prkit/' '.prkit/audit.jsonl'
        ;;
    esac
    exit 0
    ;;
  *" check-ignore "*) exit 1 ;;
esac
exec "$PRKIT_REAL_GIT" "$@"
SH
chmod +x "$dp/bin/git"
real_git="$(command -v git)"
V27_OUTPUT=""
if V27_OUTPUT="$(
     PATH="$dp/bin:$PATH" \
     PRKIT_REAL_GIT="$real_git" \
     PRKIT_WRONG_SOURCE="$dp/outside/.gitignore" \
       bash "$VERIFY" "$d" 2>&1
   )"; then
  no "V27 forged outside .gitignore source fails (verify wrongly PASSED)"
elif ! grep -qF "$ARTIFACT_IGNORE_DIAGNOSTIC" <<<"$V27_OUTPUT"; then
  no "V27 forged outside .gitignore source fails (expected diagnostic missing)"
else
  ok "V27 forged outside .gitignore source cannot satisfy managed-source proof"
fi
rm -rf "$dp"

# V28 — POSIX source identity is case-sensitive even when forged paths resemble
# MSYS drive spelling. Caller-controlled OS/MSYSTEM variables cannot opt in to
# Windows normalization. The python wrapper changes only the modeled expected
# argument so this can be tested without creating root-level /a and /A fixtures.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" check-ignore -v "*)
    printf '%s\0%s\0%s\0%s\0' \
      "$PRKIT_FORGED_SOURCE" 6 '.prkit/' '.prkit/audit.jsonl'
    exit 0
    ;;
  *" check-ignore "*) exit 1 ;;
esac
exec "$PRKIT_REAL_GIT" "$@"
SH
cat > "$dp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-I" ] && [ "${2:-}" = "-B" ] && [ "${3:-}" = "-" ]; then
  case "${4:-}" in
    */check-ignore.output)
      exec "$PRKIT_REAL_PYTHON" -I -B - "$4" "$PRKIT_MODELED_EXPECTED"
      ;;
  esac
fi
exec "$PRKIT_REAL_PYTHON" "$@"
SH
chmod +x "$dp/bin/git" "$dp/bin/python3"
real_git="$(command -v git)"
real_python="$(command -v python3)"
V28_OUTPUT=""
if V28_OUTPUT="$(
     PATH="$dp/bin:$PATH" \
     PRKIT_REAL_GIT="$real_git" \
     PRKIT_REAL_PYTHON="$real_python" \
     PRKIT_FORGED_SOURCE="/A/project/.gitignore" \
     PRKIT_MODELED_EXPECTED="/a/project/.gitignore" \
     OS=Windows_NT \
     MSYSTEM=MINGW64 \
       bash "$VERIFY" "$d" 2>&1
   )"; then
  no "V28 POSIX wrong-case source fails (verify wrongly PASSED)"
elif ! grep -qF "$ARTIFACT_IGNORE_DIAGNOSTIC" <<<"$V28_OUTPUT"; then
  no "V28 POSIX wrong-case source fails (expected diagnostic missing)"
else
  ok "V28 POSIX source identity stays case-sensitive despite caller environment"
fi
rm -rf "$dp"

# V29 — retain the modeled MSYS/Windows equivalence intentionally: only a
# runtime platform probe, simulated inside the parser process, enables it.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" check-ignore -v "*)
    printf '%s\0%s\0%s\0%s\0' \
      "$PRKIT_FORGED_SOURCE" 6 '.prkit/' '.prkit/audit.jsonl'
    exit 0
    ;;
  *" check-ignore "*) exit 1 ;;
esac
exec "$PRKIT_REAL_GIT" "$@"
SH
cat > "$dp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-I" ] && [ "${2:-}" = "-B" ] && [ "${3:-}" = "-" ]; then
  case "${4:-}" in
    */check-ignore.output)
      {
        printf '%s\n' \
          'import platform as _prkit_platform' \
          '_prkit_platform.system = lambda: "MSYS_NT-10.0"'
        cat
      } > "$PRKIT_MODELED_SCRIPT"
      exec "$PRKIT_REAL_PYTHON" -I -B "$PRKIT_MODELED_SCRIPT" \
        "$4" "$PRKIT_MODELED_EXPECTED"
      ;;
  esac
fi
exec "$PRKIT_REAL_PYTHON" "$@"
SH
chmod +x "$dp/bin/git" "$dp/bin/python3"
real_git="$(command -v git)"
real_python="$(command -v python3)"
V29_OUTPUT=""
if V29_OUTPUT="$(
     PATH="$dp/bin:$PATH" \
     PRKIT_REAL_GIT="$real_git" \
     PRKIT_REAL_PYTHON="$real_python" \
     PRKIT_FORGED_SOURCE="/C/project/.gitignore" \
     PRKIT_MODELED_EXPECTED='c:\project\.gitignore' \
     PRKIT_MODELED_SCRIPT="$dp/modeled-parser.py" \
       bash "$VERIFY" "$d" 2>&1
   )" \
   && grep -qF \
     'artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock' \
     <<<"$V29_OUTPUT"; then
  ok "V29 modeled MSYS runtime accepts equivalent drive spelling"
else
  no "V29 modeled MSYS runtime rejected equivalent drive spelling"
fi
rm -rf "$dp"

# V30 — the Codex tree stays RETIRED in the generated target (#381, and the
# drift it hid, #410). The generator stopped emitting codex/ and no MANAGED_PATH
# covers it, so a pre-#381 target keeps its stale tree forever while every gate
# scoped to plugins/prkit stays green over it; the published prkit repo was
# carrying 54 such files. The anti-false-positive side is V1 above — a freshly
# generated tree has no codex/ and must keep passing — so no new clean row.
CODEX_RETIRED_DIAGNOSTIC='codex-retired: generated target still carries a codex/ tree (UberDev #381)'
expect_fail_diag "V30 codex directory fails" \
  'mkdir -p "$d/codex" && printf "stale\n" > "$d/codex/AGENTS.md"' "$CODEX_RETIRED_DIAGNOSTIC"
# V30b proves the check is `-e`, not `-d`: a stray regular file is still residue.
expect_fail_diag "V30b codex regular file fails" \
  'printf "stale\n" > "$d/codex"' "$CODEX_RETIRED_DIAGNOSTIC"
# V30c proves it is `-e || -L`, not `-e` alone: `-e` FOLLOWS symlinks, so a
# DANGLING link named codex — the plausible leftover of a hand-cleanup — would
# slip straight through a bare `-e` test.
expect_fail_diag "V30c dangling codex symlink fails" \
  'ln -s "$dp/gone" "$d/codex"' "$CODEX_RETIRED_DIAGNOSTIC"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
