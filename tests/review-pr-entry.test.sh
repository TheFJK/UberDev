#!/usr/bin/env bash
# Issue #335: the review entrypoint must reject explicit providers that cannot
# satisfy the governed result contract, and the canonical Claude command must
# remain provider-neutral while auto resolution lands on the transport the
# command files actually wire.
#
# #381 renamed this file from review-pr-codex-entry.test.sh. The Codex half went
# in two steps: first the GENERATED Codex entrypoint (the distribution that
# produced it), then the `codex` dispatch backend itself. Nothing here was about
# Codex by the end — the file's own header always called this half
# provider-NEUTRAL — so the assertions were kept and the name was corrected.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY_SOURCE="$ROOT/plugins/uberdev/commands/simplify.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# The canonical command must not pin ANY transport into
# UBERDEV_DISPATCH_BACKEND_REQUESTED: resolution belongs to preflight, and a pin
# in the command file is how a retired transport survives its own deletion.
# (This used to name `codex` specifically, because a generated Codex entrypoint
# did carry such a pin. The canonical command never has — which is what this
# still proves, now against the whole flag rather than one value.)
if grep -qE 'UBERDEV_DISPATCH_BACKEND_REQUESTED=[^"$]' "$SOURCE"; then
  echo "canonical Claude review command must remain provider-neutral" >&2
  exit 1
fi

for doc in "$SOURCE"; do
  grep -q 'normalized, non-empty POSIX repository-relative paths' "$doc"
  grep -q 'absolute paths, traversal, dot components, backslashes, control characters, and unsafe names are rejected' "$doc"
done

awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$SOURCE" >"$TMP/source-setup.sh"
test -s "$TMP/source-setup.sh"
# One setup block now, not two: run_setup below used to source the generated
# Codex copy, which differed from the canonical one only by the retired pin.
cp "$TMP/source-setup.sh" "$TMP/setup.sh"
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

printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
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

# The default_result block that used to sit here asserted the GENERATED Codex
# skill supplied its own backend provenance before standalone carrier setup.
# That provenance came from a pin in a file #381 deleted; the canonical command
# is provider-neutral by design, so there is no provenance signal left to
# assert. Auto resolution from the canonical entry is covered below.

# wezterm cannot publish the required result.md artifact for governed review
# children, so explicit selection fails during workflow preflight. (This used to
# name the detached `claude --bg` backend, which had its own bespoke refusal
# message; that backend is gone, so the assertion moved to a backend that is
# still selectable and still below the bar.)
if run_setup "$TMP/runtime-override" wezterm >"$TMP/wezterm-override.out" 2>"$TMP/wezterm-override.err"; then
  echo "standalone review accepted wezterm without a result artifact" >&2
  exit 1
fi
grep -q 'needs a backend that publishes a governed child result artifact' \
  "$TMP/wezterm-override.err"

# Canonical standalone review is provider-neutral, but auto resolution is
# workflow-aware before carrier creation. A usable macOS WezTerm or an ambient
# Claude install must not displace the result-producing backend.
#
# #381: that backend is now `workflow`. `claude` is on this fixture's PATH and
# the environment is scrubbed (env -i), so the resolver's own ladder is what
# decides — and it must land on the transport the command files actually wire,
# never on wezterm/background, neither of which can publish a governed child's
# result artifact.
source_auto_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    UBERDEV_TMPDIR="$TMP/runtime-source-auto" AUTO_PERMISSIONS=1 \
    UBERDEV_DISPATCH_BACKEND_REQUESTED=auto \
    RUN_ID=20260716-000003-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
    bash -c 'mkdir -p "$3"; cd "$2"; . "$1"; python3 -I -B -c "import json,os; request=json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"]); print(request[\"backend\"])"' \
      _ "$TMP/source-setup.sh" "$TMP/repo" "$TMP/runtime-source-auto"
)"
[ "$source_auto_result" = workflow ] || {
  echo "standalone review auto-selected unsupported backend: $source_auto_result" >&2
  exit 1
}

# A new standalone carrier re-resolves from the requested provider even when a
# reused shell exports a conflicting backend from an earlier invocation. The
# requested value used to be `codex`; #381 deleted that backend, so the case now
# requests the wired transport explicitly. The claim is unchanged: the stale
# UBERDEV_RESOLVED_BACKEND export must not survive a new carrier.
stale_result="$(
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
    UBERDEV_TMPDIR="$TMP/runtime-stale" UBERDEV_DISPATCH_BACKEND_REQUESTED=workflow \
    UBERDEV_RESOLVED_BACKEND=wezterm \
    RUN_ID=20260716-000004-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
    bash -c 'mkdir -p "$3"; cd "$2"; . "$1"; python3 -I -B -c "import json,os; print(json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"])[\"backend\"])"' \
      _ "$TMP/source-setup.sh" "$TMP/repo" "$TMP/runtime-stale"
)"
[ "$stale_result" = workflow ]

# Standalone simplify uses the same workflow-aware boundary. This covers the
# complete setup-to-fixer handoff contract: auto/stale routing resolves the
# wired transport (#381: `workflow`) even though the shell exports a stale
# `background`, and the phase-two fixer is prepared in the CALLER workspace —
# the caller-workspace half is the part that is backend-independent, and it is
# what the fixer's commit authority depends on.
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
[ "$simplify_fixer_result" = "workflow:caller:$TMP/repo" ]

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
      _ "$TMP/source-setup.sh" "$TMP/repo"
)"
python3 -I -B - "$private_result" "$PRIVATE_TMP" <<'PY'
import json,os,stat,sys
value=json.loads(sys.argv[1]); expected=os.path.join(sys.argv[2],f'uberdev-{os.geteuid()}')
# 'workflow' after #381: the canonical provider-neutral Claude entry is the only
# entry left, and `auto` resolves the transport the command files actually wire.
assert value=={'backend':'workflow','run_dir':expected},value
entry=os.lstat(expected)
assert stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode)
assert entry.st_uid==os.geteuid() and stat.S_IMODE(entry.st_mode)==0o700
PY

echo "review-pr canonical entrypoint tests passed"
