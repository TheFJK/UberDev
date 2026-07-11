#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
HELPER="$ROOT/plugins/uberdev/lib/command-workspace.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$LIB"

make_carrier() {
  local workflow="$1" issue="$2" repo="$3" run="$4" request decision metadata context_out context sha
  mkdir -p "$run"
  request="$(jq -cn --arg run "$run" --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{schema_version:1,run_dir:$run,run_id:$run_id,repository_id:$repo,backend:"codex",workflow:$workflow,phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:$issue,issue_num:$issue,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(jq -cn --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{run_id:$run_id,repository_id:$repo,workflow:$workflow,backend:"codex",issue_num:$issue,task_tier:"medium",risk_signals:[]}')"
  context_out="$(uberdev_agent_context_create "$run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-10T00:00:00Z')"
  context="$(jq -r .context_file <<<"$context_out")"; sha="$(jq -r .context_sha256 <<<"$context_out")"
  jq -cn --arg workflow "$workflow" --arg run_id "root-$workflow" --arg context "$context" --arg sha "$sha" --argjson issue "$issue" \
    '{schema_version:1,run_id:$run_id,workflow:$workflow,issue_num:$issue,context_file:$context,context_sha256:$sha}'
}

REPO="$TMP/repo"
mkdir -p "$REPO"
REPO="$(cd "$REPO" && pwd -P)"
git -C "$REPO" init -q
RUNROOT="$TMP/run"
mkdir -p "$RUNROOT"
RUNROOT="$(cd "$RUNROOT" && pwd -P)"
SOLVE_CARRIER="$(make_carrier solve 41 "$REPO" "$RUNROOT/solve")"
TURBO_CARRIER="$(make_carrier turbo 42 "$REPO" "$RUNROOT/turbo")"
SIMPLIFY_CARRIER="$(make_carrier simplify 0 "$REPO" "$RUNROOT/simplify")"

# Repository identity is accepted only when already canonical and exactly a Git toplevel.
SECURITY_FAILURES=0
NON_GIT_REPO="$TMP/non-git-repo"
mkdir -p "$NON_GIT_REPO"
NON_GIT_REPO="$(cd "$NON_GIT_REPO" && pwd -P)"
NON_GIT_CARRIER="$(make_carrier solve 43 "$NON_GIT_REPO" "$RUNROOT/non-git")"
UBERDEV_RUN_CARRIER_JSON="$NON_GIT_CARRIER"
export UBERDEV_RUN_CARRIER_JSON
NON_GIT_RUN=20260710-010200-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$NON_GIT_CARRIER" --run-id "$NON_GIT_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-Git repository accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$NON_GIT_REPO/.uberdev/research/$NON_GIT_RUN" ]; then
  echo 'non-Git repository workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# Inherited Git environment cannot make a canonical non-Git directory appear
# to be the verified worktree.
MASQUERADE_RUN=20260710-010200-abcdeff
if GIT_DIR="$REPO/.git" GIT_WORK_TREE="$NON_GIT_REPO" \
  python3 "$HELPER" --caller review-pr --carrier-json "$NON_GIT_CARRIER" --run-id "$MASQUERADE_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'inherited Git environment masqueraded a non-Git repository' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$NON_GIT_REPO/.uberdev/research/$MASQUERADE_RUN" ]; then
  echo 'Git-environment masquerade wrote a workspace' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

REPO_LINK="$TMP/repo-link"
ln -s "$REPO" "$REPO_LINK"
SYMLINK_REPO_CARRIER="$(make_carrier solve 44 "$REPO_LINK" "$RUNROOT/symlink-repo")"
UBERDEV_RUN_CARRIER_JSON="$SYMLINK_REPO_CARRIER"
SYMLINK_REPO_RUN=20260710-010201-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$SYMLINK_REPO_CARRIER" --run-id "$SYMLINK_REPO_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-canonical symlink repository_id accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$REPO/.uberdev/research/$SYMLINK_REPO_RUN" ]; then
  echo 'symlink repository workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# The carrier context state directory itself must remain private.
WRONG_MODE_CARRIER="$(make_carrier solve 45 "$REPO" "$RUNROOT/wrong-mode")"
WRONG_MODE_CONTEXT="$(jq -r .context_file <<<"$WRONG_MODE_CARRIER")"
chmod 755 "$(dirname "$WRONG_MODE_CONTEXT")"
UBERDEV_RUN_CARRIER_JSON="$WRONG_MODE_CARRIER"
WRONG_MODE_RUN=20260710-010202-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$WRONG_MODE_CARRIER" --run-id "$WRONG_MODE_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-private context state directory accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$REPO/.uberdev/research/$WRONG_MODE_RUN" ]; then
  echo 'wrong-mode context workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# Allocation remains bound to the exact repository inode verified by
# load_carrier, even if that pathname is replaced before the first mkdir.
RACE_REPO="$TMP/race-repo"
mkdir -p "$RACE_REPO"
RACE_REPO="$(cd "$RACE_REPO" && pwd -P)"
git -C "$RACE_REPO" init -q
RACE_CARRIER="$(make_carrier solve 46 "$RACE_REPO" "$RUNROOT/race-repo")"
RACE_RUN=20260710-010202-abcdeff
if ! python3 - "$HELPER" "$RACE_CARRIER" "$RACE_RUN" <<'PY'
import importlib.util
import json
import os
import sys

helper_path, carrier_raw, run_id = sys.argv[1:]
spec = importlib.util.spec_from_file_location("command_workspace", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
loaded = module.load_carrier(carrier_raw, "review-pr")
repo = loaded[2]
verified_identity = loaded[4]
current = os.stat(repo, follow_symlinks=False)
assert verified_identity == (current.st_dev, current.st_ino)
os.rename(repo, repo + ".verified")
os.mkdir(repo, 0o700)
rejected = False
try:
    module.allocate_workspace(
        repo,
        run_id,
        module.CALLERS["review-pr"]["artifacts"],
        expected_repo_identity=verified_identity,
    )
except module.Failure:
    rejected = True
workspace = os.path.join(repo, ".uberdev", "research", run_id)
if not rejected or os.path.lexists(workspace):
    raise SystemExit(1)
PY
then
  echo 'repository inode replacement was not rejected before writes' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
[ "$SECURITY_FAILURES" -eq 0 ]

# Every failure after a successful mkdir is locally transactional: the helper
# removes only the directory it created and leaves no workspace or artifacts.
if ! python3 - "$HELPER" "$TMP/transaction-cases" <<'PY'
import importlib.util
import os
import sys

helper_path, cases_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("command_workspace_transaction", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
os.mkdir(cases_root, 0o700)
failures = []

real_open = module.os.open
real_stat = module.os.stat
real_fchmod = module.os.fchmod

def run_case(stage):
    repo = os.path.join(cases_root, stage)
    os.mkdir(repo, 0o700)
    entry = os.stat(repo, follow_symlinks=False)
    identity = (entry.st_dev, entry.st_ino)

    def fault_open(path, flags, *args, **kwargs):
        if stage == "open" and path == ".uberdev" and kwargs.get("dir_fd") is not None:
            raise OSError("injected post-mkdir open failure")
        return real_open(path, flags, *args, **kwargs)

    def fault_stat(path, *args, **kwargs):
        if stage == "validation" and path == ".uberdev" and kwargs.get("dir_fd") is not None:
            raise OSError("injected post-mkdir validation failure")
        return real_stat(path, *args, **kwargs)

    def fault_fchmod(fd, mode):
        if stage == "chmod":
            raise OSError("injected post-mkdir chmod failure")
        return real_fchmod(fd, mode)

    module.os.open = fault_open
    module.os.stat = fault_stat
    module.os.fchmod = fault_fchmod
    rejected = False
    try:
        module.allocate_workspace(
            repo,
            "20260710-010202-acdeef0",
            module.CALLERS["review-pr"]["artifacts"],
            identity,
        )
    except OSError:
        rejected = True
    finally:
        module.os.open = real_open
        module.os.stat = real_stat
        module.os.fchmod = real_fchmod
    if not rejected or os.path.lexists(os.path.join(repo, ".uberdev")):
        failures.append(f"{stage} failure left residual workspace state")

for fault_stage in ("open", "validation", "chmod"):
    run_case(fault_stage)

# A failing open of an existing directory must never remove that directory.
repo = os.path.join(cases_root, "preexisting")
os.mkdir(repo, 0o700)
existing = os.path.join(repo, ".uberdev")
os.mkdir(existing, 0o700)
repo_entry = os.stat(repo, follow_symlinks=False)

def fail_existing_open(path, flags, *args, **kwargs):
    if path == ".uberdev" and kwargs.get("dir_fd") is not None:
        raise OSError("injected existing-directory open failure")
    return real_open(path, flags, *args, **kwargs)

module.os.open = fail_existing_open
try:
    module.allocate_workspace(
        repo,
        "20260710-010202-acdeef1",
        module.CALLERS["review-pr"]["artifacts"],
        (repo_entry.st_dev, repo_entry.st_ino),
    )
except OSError:
    pass
else:
    raise SystemExit("existing-directory failure was unexpectedly accepted")
finally:
    module.os.open = real_open
if not os.path.isdir(existing):
    failures.append("pre-existing directory was removed")
if failures:
    raise SystemExit("; ".join(failures))
PY
then
  echo 'post-mkdir transaction rollback failed' >&2
  exit 1
fi

RUN_ID=20260710-010203-abcdef0
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
export UBERDEV_RUN_CARRIER_JSON
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true

# Inherited solve review creates the exact runtime-owned workspace and artifacts.
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" '' >/dev/null
EXPECTED="$REPO/.uberdev/research/$RUN_ID"
[ "$WORKTREE_ROOT" = "$REPO" ]
[ "$RESEARCH_DIR_ABS" = "$EXPECTED" ]
[ "$(stat -f '%Lp' "$RESEARCH_DIR_ABS")" = 700 ]
[ "$DIFF_ARTIFACT_PATH" = "$EXPECTED/pr-diff.md" ]
[ "$CRITERIA_PATH" = "$EXPECTED/review-criteria.md" ]
[ "$COMMIT_RANGE_PATH" = "$EXPECTED/commit-range.txt" ]
[ "$PHASE1_DISPOSITION_PATH" = "$EXPECTED/phase1-disposition.json" ]
[ "$PHASE2_DISPOSITION_PATH" = "$EXPECTED/phase2-disposition.json" ]
for path in "$DIFF_ARTIFACT_PATH" "$CRITERIA_PATH" "$COMMIT_RANGE_PATH" "$PHASE1_DISPOSITION_PATH" "$PHASE2_DISPOSITION_PATH"; do
  [ "$(stat -f '%Lp' "$path")" = 600 ]
  [ "$(stat -f '%l' "$path")" = 1 ]
done
grep -q '^<external-untrusted-input source="pr-diff">$' "$DIFF_ARTIFACT_PATH"
jq -e '.caller=="review-pr" and .carrier_workflow=="solve" and .repository_root==$repo and .research_dir==$research and (.artifacts|keys)==["commit_range","criteria","diff","phase1_disposition","phase2_disposition"]' \
  --arg repo "$REPO" --arg research "$EXPECTED" <<<"$UBERDEV_COMMAND_WORKSPACE_JSON" >/dev/null

# Re-entry preserves safe existing bytes.
printf 'preserve-me\n' >"$CRITERIA_PATH"; chmod 600 "$CRITERIA_PATH"
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null
grep -qx 'preserve-me' "$CRITERIA_PATH"

# Artifact globals are output-only; a mismatched preset fails without touching it.
OUTSIDE="$TMP/outside-sentinel"
printf 'sentinel\n' >"$OUTSIDE"
DIFF_ARTIFACT_PATH="$OUTSIDE"
if uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null 2>&1; then
  echo 'mismatched artifact override accepted' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"
DIFF_ARTIFACT_PATH="$EXPECTED/pr-diff.md"

# Review rejects an inherited simplify carrier before allocating its workspace.
BAD_RUN_ID=20260710-010204-abcdef0
UBERDEV_RUN_CARRIER_JSON="$SIMPLIFY_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare review-pr 77 medium '[]' "$BAD_RUN_ID" "$REPO" >/dev/null 2>&1; then
  echo 'review accepted simplify carrier' >&2; exit 1
fi
[ ! -e "$REPO/.uberdev/research/$BAD_RUN_ID" ]

# Review preserves inherited turbo lineage; simplify rejects solve/turbo carriers.
UBERDEV_RUN_CARRIER_JSON="$TURBO_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
TURBO_RUN=20260710-010204-abcdeff
uberdev_command_workspace_prepare review-pr 78 medium '[]' "$TURBO_RUN" '' >/dev/null
[ "$(jq -r .carrier_workflow <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = turbo ]
uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$TURBO_RUN" "$REPO" >/dev/null
[ "$(jq -r .carrier_workflow <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = turbo ]
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare simplify 0 medium '[]' 20260710-010204-acdeeff '' >/dev/null 2>&1; then
  echo 'simplify accepted inherited solve carrier' >&2; exit 1
fi

# Carrier mint failure is terminal and happens before any workspace write.
uberdev_prepare_run_carrier() { return 17; }
unset UBERDEV_RUN_CARRIER_JSON UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
MINT_FAIL_RUN=20260710-010204-acdeefa
rc=0
uberdev_command_workspace_prepare review-pr 79 medium '[]' "$MINT_FAIL_RUN" '' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 17 ]
[ ! -e "$REPO/.uberdev/research/$MINT_FAIL_RUN" ]

# Standalone simplify mints its carrier before allocation and owns exact artifacts.
STANDALONE_CARRIER="$SIMPLIFY_CARRIER"
mint_calls=0
uberdev_prepare_run_carrier() {
  mint_calls=$((mint_calls + 1))
  UBERDEV_RUN_CARRIER_JSON="$STANDALONE_CARRIER"
  export UBERDEV_RUN_CARRIER_JSON
}
unset UBERDEV_RUN_CARRIER_JSON UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
SIMPLIFY_RUN=20260710-010205-abcdef0
uberdev_command_workspace_prepare simplify 0 medium '[]' "$SIMPLIFY_RUN" '' >/dev/null
[ "$mint_calls" -eq 1 ]
[ "$AGG_PATH" = "$REPO/.uberdev/research/$SIMPLIFY_RUN/simplify-final.md" ]
[ "$(stat -f '%Lp' "$AGG_PATH")" = 600 ]

# Post-review requires the inherited descriptor, attaches exactly, and preserves bytes.
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
POST_RUN=20260710-010206-abcdef0
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$POST_RUN" '' >/dev/null
printf 'parent-diff\n' >"$DIFF_ARTIFACT_PATH"; chmod 600 "$DIFF_ARTIFACT_PATH"
PARENT_DESCRIPTOR="$UBERDEV_COMMAND_WORKSPACE_JSON"
uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null
[ "$(jq -r .caller <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = post-impl-review ]
grep -qx parent-diff "$DIFF_ARTIFACT_PATH"

unset UBERDEV_COMMAND_WORKSPACE_JSON
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review minted or attached without parent descriptor' >&2; exit 1
fi

# Existing symlink artifacts fail closed without mutating their target.
UBERDEV_COMMAND_WORKSPACE_JSON="$PARENT_DESCRIPTOR"
rm "$DIFF_ARTIFACT_PATH"
ln -s "$OUTSIDE" "$DIFF_ARTIFACT_PATH"
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review accepted symlink artifact' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"

rm "$DIFF_ARTIFACT_PATH"
ln "$OUTSIDE" "$DIFF_ARTIFACT_PATH"
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review accepted hardlink artifact' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"

# A pre-existing symlink at the exact run directory is never followed.
SYMLINK_RUN=20260710-010207-abcdef0
OUTSIDE_DIR="$TMP/outside-dir"; mkdir -p "$OUTSIDE_DIR"
ln -s "$OUTSIDE_DIR" "$REPO/.uberdev/research/$SYMLINK_RUN"
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare review-pr 80 medium '[]' "$SYMLINK_RUN" '' >/dev/null 2>&1; then
  echo 'workspace followed a symlink run directory' >&2; exit 1
fi
[ -z "$(find "$OUTSIDE_DIR" -mindepth 1 -print -quit)" ]

# Markdown setups are thin runtime clients with no duplicate validator or writes.
for doc in "$ROOT/plugins/uberdev/commands/review-pr.md" "$ROOT/plugins/uberdev/commands/simplify.md" "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"; do
  rg -q 'uberdev_command_workspace_prepare' "$doc"
  ! rg -n 'UBERDEV_SETUP_BOUNDARY_JSON|mkdir -p "\$RESEARCH_DIR_ABS"|DIFF_ARTIFACT_PATH="\$\{DIFF_ARTIFACT_PATH|CRITERIA_PATH="\$\{CRITERIA_PATH' "$doc"
done

# The Codex package is a checked-in runtime mirror, not an independent helper.
cmp "$HELPER" "$ROOT/codex/uberdev-codex/lib/command-workspace.py"

echo 'command-workspace: PASS'
