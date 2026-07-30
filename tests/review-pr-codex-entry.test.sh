#!/usr/bin/env bash
# Issue #335: the generated Codex review entrypoint must preserve its provider
# provenance even when CODEX_HOME is absent, while rejecting explicit
# providers that cannot satisfy the governed result contract. The canonical
# Claude command remains provider-neutral.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONVERTER="$ROOT/codex/tools/convert-commands.py"
SOURCE="$ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY_SOURCE="$ROOT/plugins/uberdev/commands/simplify.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

python3 "$CONVERTER" "$ROOT/plugins/uberdev/commands" "$TMP/skills" >/dev/null
GENERATED="$TMP/skills/uberdev-cmd-review-pr/SKILL.md"
CHECKED_IN="$ROOT/codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md"

for skill in "$GENERATED" "$CHECKED_IN"; do
  # shellcheck disable=SC2016 # The generated shell expression is matched literally.
  grep -q 'UBERDEV_DISPATCH_BACKEND_REQUESTED="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-codex}"' "$skill"
  grep -q 'export UBERDEV_DISPATCH_BACKEND_REQUESTED' "$skill"
  grep -q 'uberdev_dispatch_preflight_backend "$UBERDEV_CARRIER_BACKEND"' "$skill"
done
if grep -q 'UBERDEV_DISPATCH_BACKEND_REQUESTED=.*codex' "$SOURCE"; then
  echo "canonical Claude review command must remain provider-neutral" >&2
  exit 1
fi

for doc in "$SOURCE" "$GENERATED" "$CHECKED_IN"; do
  grep -q 'normalized, non-empty POSIX repository-relative paths' "$doc"
  grep -q 'absolute paths, traversal, dot components, backslashes, control characters, and unsafe names are rejected' "$doc"
done

awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$GENERATED" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"
awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$SOURCE" >"$TMP/source-setup.sh"
test -s "$TMP/source-setup.sh"
awk '
  /uberdev-executable setup=simplify/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$SIMPLIFY_SOURCE" >"$TMP/simplify-setup.sh"
test -s "$TMP/simplify-setup.sh"

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name Test
printf 'fixture\n' >"$TMP/repo/README.md"
git -C "$TMP/repo" add README.md
git -C "$TMP/repo" commit -qm init

for provider in codex claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/$provider"
  chmod +x "$TMP/bin/$provider"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/wezterm"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/wezterm-mux-server"
chmod +x "$TMP/bin/wezterm" "$TMP/bin/wezterm-mux-server"

run_setup() {
  local runtime="$1" requested="${2-}"
  mkdir -p "$runtime"
  if [ -n "$requested" ]; then
    # shellcheck disable=SC2016 # Positional parameters expand in the isolated child shell.
    env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
      UBERDEV_TMPDIR="$runtime" UBERDEV_DISPATCH_BACKEND_REQUESTED="$requested" \
      AUTO_PERMISSIONS=1 \
      RUN_ID=20260716-000000-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
      bash -c 'cd "$2"; . "$1"; python3 -I -B -c "import json,os,sys; request=json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"]); print(json.dumps({\"requested\":os.environ[\"UBERDEV_DISPATCH_BACKEND_REQUESTED\"],\"backend\":request[\"backend\"],\"run_dir\":request[\"run_dir\"],\"model\":sys.argv[1],\"timeout\":sys.argv[2],\"permissions\":sys.argv[3],\"effort\":sys.argv[4]},sort_keys=True))" "${MODEL:-}" "${TIMEOUT_BIN:-}" "${PERM_FLAG[*]-}" "${EFFORT_FLAG[*]-}"' _ "$TMP/setup.sh" "$TMP/repo"
  else
    # shellcheck disable=SC2016 # Positional parameters expand in the isolated child shell.
    env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
      UBERDEV_TMPDIR="$runtime" RUN_ID=20260716-000001-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
      bash -c 'cd "$2"; . "$1"; python3 -I -B -c "import json,os,sys; request=json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"]); print(json.dumps({\"requested\":os.environ[\"UBERDEV_DISPATCH_BACKEND_REQUESTED\"],\"backend\":request[\"backend\"],\"run_dir\":request[\"run_dir\"],\"model\":sys.argv[1],\"timeout\":sys.argv[2],\"permissions\":sys.argv[3],\"effort\":sys.argv[4]},sort_keys=True))" "${MODEL:-}" "${TIMEOUT_BIN:-}" "${PERM_FLAG[*]-}" "${EFFORT_FLAG[*]-}"' _ "$TMP/setup.sh" "$TMP/repo"
  fi
}

# CODEX_HOME is intentionally absent in both clean environments. The generated
# Codex skill supplies the provenance signal before standalone carrier setup.
default_result="$(run_setup "$TMP/runtime-default")"
python3 -I -B - "$default_result" "$TMP/runtime-default" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
run_dir=value.pop("run_dir")
assert run_dir==sys.argv[2],(run_dir,sys.argv[2])
assert value == {"requested": "codex", "backend": "codex", "model": "", "timeout": "", "permissions": "", "effort": ""}, value
PY

# claude-bg cannot publish the required result.md artifact for governed review
# children, so explicit selection now fails during workflow preflight.
if run_setup "$TMP/runtime-override" claude-bg >"$TMP/claude-override.out" 2>"$TMP/claude-override.err"; then
  echo "standalone review accepted claude-bg without a result artifact" >&2
  exit 1
fi
grep -q 'does not export a supervised result artifact' "$TMP/claude-override.err"

# Canonical standalone review is provider-neutral, but auto resolution is
# workflow-aware before carrier creation. A usable macOS WezTerm or ambient
# Claude install must not displace the result-producing Codex backend.
source_auto_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    UBERDEV_TMPDIR="$TMP/runtime-source-auto" AUTO_PERMISSIONS=1 \
    UBERDEV_DISPATCH_BACKEND_REQUESTED=auto \
    RUN_ID=20260716-000003-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
    bash -c 'mkdir -p "$3"; cd "$2"; . "$1"; python3 -I -B -c "import json,os; request=json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"]); print(request[\"backend\"])"' \
      _ "$TMP/source-setup.sh" "$TMP/repo" "$TMP/runtime-source-auto"
)"
[ "$source_auto_result" = codex ] || {
  echo "standalone review auto-selected unsupported backend: $source_auto_result" >&2
  exit 1
}

# A new standalone carrier re-resolves from the requested provider even when a
# reused shell exports a conflicting backend from an earlier invocation.
stale_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    UBERDEV_TMPDIR="$TMP/runtime-stale" UBERDEV_DISPATCH_BACKEND_REQUESTED=codex \
    UBERDEV_RESOLVED_BACKEND=claude-bg \
    RUN_ID=20260716-000004-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
    bash -c 'mkdir -p "$3"; cd "$2"; . "$1"; python3 -I -B -c "import json,os; print(json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"])[\"backend\"])"' \
      _ "$TMP/source-setup.sh" "$TMP/repo" "$TMP/runtime-stale"
)"
[ "$stale_result" = codex ]

# Standalone simplify uses the same workflow-aware boundary. This covers the
# complete setup-to-fixer handoff contract: auto/stale routing resolves Codex,
# and the phase-two fixer is prepared in the caller workspace.
simplify_fixer_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    UBERDEV_TMPDIR="$TMP/runtime-simplify" UBERDEV_DISPATCH_BACKEND_REQUESTED=auto \
    UBERDEV_RESOLVED_BACKEND=background \
    RUN_ID=20260716-000005-abcdef0 PR_NUMBER=0 ARGUMENTS='' \
    bash -c '
      mkdir -p "$3"; cd "$2"; . "$1"
      printf "%s" '\''{"contributors":[{"confidence":"n/a","id":"review_pr.simplify.reuse","verdict":"COMPLETE"},{"confidence":"n/a","id":"review_pr.simplify.quality","verdict":"COMPLETE"},{"confidence":"n/a","id":"review_pr.simplify.efficiency","verdict":"COMPLETE"}],"findings":[],"phase":"phase2","schema_version":2}'\'' \
        | python3 -I -B "$CODE_FIXER_CONTRACT" encode-aggregate --phase phase2 >"$AGG_PATH"
      snapshot_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" snapshot-standalone \
        --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS" \
        --diff-path "$DIFF_ARTIFACT_PATH" --snapshot-path "$STANDALONE_SNAPSHOT_PATH")"
      snapshot_sha256="$(python3 -I -B -c '\''import json,sys; print(json.loads(sys.argv[1])["snapshot_sha256"],end="")'\'' "$snapshot_receipt")"
      findings_sha256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$AGG_PATH" --minimum 1 --maximum 16777216)"
      : >"$PHASE2_DISPOSITION_PATH"
      authority_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-standalone-authority \
        --edge-id simplify.fix.phase2 --policy-phase simplify_fix \
        --findings-path "$AGG_PATH" --findings-sha256 "$findings_sha256" \
        --snapshot-path "$STANDALONE_SNAPSHOT_PATH" --snapshot-sha256 "$snapshot_sha256" \
        --working-dir "$WORKTREE_ROOT" --disposition-path "$PHASE2_DISPOSITION_PATH")"
      authority_path="$(python3 -I -B -c '\''import json,sys; print(json.loads(sys.argv[1])["authority_path"],end="")'\'' "$authority_receipt")"
      authority_sha256="$(python3 -I -B -c '\''import json,sys; print(json.loads(sys.argv[1])["authority_sha256"],end="")'\'' "$authority_receipt")"
      json_string() { python3 -I -B -c '\''import json,sys; print(json.dumps(sys.argv[1]),end="")'\'' "$1"; }
      inputs="$(uberdev_child_inputs_build simplify.fix.phase2 \
        findings_path "$(json_string "$AGG_PATH")" \
        findings_sha256 "$(json_string "$findings_sha256")" \
        standalone_snapshot_path "$(json_string "$STANDALONE_SNAPSHOT_PATH")" \
        standalone_snapshot_sha256 "$(json_string "$snapshot_sha256")" \
        working_dir "$(json_string "$WORKTREE_ROOT")" \
        pr_number 0 \
        disposition_path "$(json_string "$PHASE2_DISPOSITION_PATH")" \
        authority_path "$(json_string "$authority_path")" \
        authority_sha256 "$(json_string "$authority_sha256")")"
      uberdev_create_child_handoff simplify.fix.phase2 simplify-fixer-iter1-attempt01 "$inputs" null >/dev/null
      prepared="$(_uberdev_child_prepare simplify.fix.phase2 "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch)"
      python3 -I -B -c '\''import json,sys; v=json.loads(sys.argv[1]); print(v["request"]["backend"]+":"+v["request"]["workspace_mode"]+":"+v["request"]["workspace_dir"],end="")'\'' "$prepared"
    ' _ "$TMP/simplify-setup.sh" "$TMP/repo" "$TMP/runtime-simplify"
)"
[ "$simplify_fixer_result" = "codex:caller:$TMP/repo" ]

# With UBERDEV_TMPDIR absent, standalone review must select the secure runtime
# helper default beneath TMPDIR instead of falling back to an ambient /tmp path.
PRIVATE_TMP="$TMP/private-tmp"
mkdir -p "$PRIVATE_TMP"
chmod 700 "$PRIVATE_TMP"
private_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" TMPDIR="$PRIVATE_TMP" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    RUN_ID=20260716-000002-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
    bash -c 'cd "$2"; . "$1"; python3 -I -B -c "import json,os; request=json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"]); print(json.dumps({\"run_dir\":request[\"run_dir\"],\"backend\":request[\"backend\"]},sort_keys=True))"' \
      _ "$TMP/setup.sh" "$TMP/repo"
)"
python3 -I -B - "$private_result" "$PRIVATE_TMP" <<'PY'
import json,os,stat,sys
value=json.loads(sys.argv[1]); expected=os.path.join(sys.argv[2],f'uberdev-{os.geteuid()}')
assert value=={'backend':'codex','run_dir':expected},value
entry=os.lstat(expected)
assert stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode)
assert entry.st_uid==os.geteuid() and stat.S_IMODE(entry.st_mode)==0o700
PY

echo "review-pr Codex entrypoint tests passed"
