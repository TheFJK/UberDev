# _lib_review_run_fixture.sh -- build a REAL /review-pr run on disk.
#
# WHY THIS FILE EXISTS (#427). Three behavioural harnesses used to hand-bind the
# cross-fence carriers -- UBERDEV_REVIEW_PLUGIN_ROOT, WORKTREE_ROOT,
# RESEARCH_DIR_ABS, CODE_FIXER_CONTRACT, RUN_ID -- before executing a fence
# extracted from commands/review-pr.md. Every one of those seeds was a MASK: the
# fence read a value the harness had supplied and that no real harness ever
# would, so a green suite proved nothing about a fence entered from a fresh
# shell. That is exactly how #427 shipped.
#
# The fix is not to seed more variables, it is to seed FEWER: build the run the
# way the setup fence builds it -- a real git repository, a real carrier, a real
# `uberdev_command_workspace_prepare`, the persisted `command-workspace.json`
# descriptor and the active-run pointer -- and then hand the fence nothing but
# CLAUDE_PLUGIN_ROOT, PR_NUMBER and (optionally) RUN_ID, which is precisely what
# the orchestrator can carry. Whatever the fence needs beyond that it must
# rehydrate for itself, or fail.
#
# Requires: `. plugins/uberdev/lib/child-dispatch.sh` already sourced by the
# caller (for uberdev_command_workspace_prepare and the agent-context helpers).

# review_fixture_make_run ROOT PLUGIN_ROOT PR_NUMBER RUN_ID
#
# Creates <ROOT>/repo as a git repository holding a complete review run and
# exports the same names the setup fence exports:
#
#   RF_REPO RF_RUN_ID RF_RUN_DIR RF_RESEARCH_DIR RF_DESCRIPTOR
#   WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH
#   COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH
#   PHASE2_DISPOSITION_PATH AGG_PATH UBERDEV_COMMAND_WORKSPACE_JSON
review_fixture_make_run() {
  [ "$#" -eq 4 ] || return 2
  local fixture_root="$1" plugin_root="$2" pr_number="$3" run_id="$4"
  local carrier_run request decision metadata context_out context_file context_sha carrier

  RF_REPO="$fixture_root/repo"
  mkdir -p "$RF_REPO" || return 2
  RF_REPO="$(cd "$RF_REPO" && pwd -P)" || return 2
  if [ ! -d "$RF_REPO/.git" ]; then
    git -C "$RF_REPO" init -q || return 2
    git -C "$RF_REPO" config user.email fixture@example.com || return 2
    git -C "$RF_REPO" config user.name Fixture || return 2
    printf 'fixture\n' >"$RF_REPO/README.md" || return 2
    git -C "$RF_REPO" add README.md || return 2
    git -C "$RF_REPO" commit -qm 'fixture' || return 2
  fi

  carrier_run="$fixture_root/carrier"
  mkdir -p "$carrier_run" || return 2
  # The carrier shape a real /review-pr run has: backend `workflow`, no
  # routing_mode. Built with python3 rather than jq so the fixture runs on both
  # CI jobs without an extra dependency.
  request="$(python3 -I -B -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"review-fixture","repository_id":sys.argv[2],"backend":"workflow","workflow":"review-pr","phase":"review","role":"lead","task_tier":"medium","risk_signals":[],"issue_or_pr":int(sys.argv[3]),"issue_num":int(sys.argv[3]),"capacity":6,"timeout_s":600},separators=(",",":")),end="")' "$carrier_run" "$RF_REPO" "$pr_number")" || return 2
  decision="$(uberdev_agent_resolve_request "$request")" || return 2
  metadata="$(python3 -I -B -c 'import json,sys; print(json.dumps({"run_id":"review-fixture","repository_id":sys.argv[1],"workflow":"review-pr","backend":"workflow","issue_num":int(sys.argv[2]),"task_tier":"medium","risk_signals":[]},separators=(",",":")),end="")' "$RF_REPO" "$pr_number")" || return 2
  context_out="$(uberdev_agent_context_create "$carrier_run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-10T00:00:00Z')" || return 2
  context_file="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_file"],end="")' "$context_out")" || return 2
  context_sha="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_sha256"],end="")' "$context_out")" || return 2
  carrier="$(python3 -I -B -c 'import json,sys; print(json.dumps({"schema_version":1,"run_id":"review-fixture","workflow":"review-pr","issue_num":int(sys.argv[1]),"context_file":sys.argv[2],"context_sha256":sys.argv[3]},separators=(",",":")),end="")' "$pr_number" "$context_file" "$context_sha")" || return 2

  UBERDEV_RUN_CARRIER_JSON="$carrier"
  export UBERDEV_RUN_CARRIER_JSON
  unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH \
    CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH \
    PHASE2_DISPOSITION_PATH AGG_PATH 2>/dev/null || true
  uberdev_command_workspace_prepare review-pr "$pr_number" medium '[]' "$run_id" "$RF_REPO" >/dev/null || return 2

  RF_RUN_ID="$run_id"
  RF_RESEARCH_DIR="$RESEARCH_DIR_ABS"
  RF_RUN_DIR="$RF_REPO/.uberdev/runs/$run_id"
  mkdir -p "$RF_RUN_DIR" || return 2
  # The reservation markers the pointer guards check for. Real setup writes
  # these through review_reserve_run_directory; the fixture only needs their
  # presence, and writing them by hand keeps the fixture independent of the
  # reservation's single-shot semantics.
  printf '%s\n' "$run_id" >"$RF_RUN_DIR/locked" || return 2
  printf '{"pr":%s}\n' "$pr_number" >"$RF_RUN_DIR/pr-context.json" || return 2
  printf '*\n' >"$RF_REPO/.uberdev/runs/.gitignore" || return 2

  # The two artifacts the setup fence publishes for later fences (#427).
  RF_DESCRIPTOR="$RF_RESEARCH_DIR/command-workspace.json"
  ( umask 077 && printf '%s\n' "$UBERDEV_COMMAND_WORKSPACE_JSON" >"$RF_DESCRIPTOR" ) || return 2
  . "$plugin_root/lib/review-fleet-args.sh" || return 2
  review_fleet_write_active_run_pointer "$RF_REPO" "$run_id" "$pr_number" \
    "$(git -C "$RF_REPO" rev-parse HEAD)" || return 2
}

# Executable mode:
#   bash tests/_lib_review_run_fixture.sh --make-run ROOT PLUGIN_ROOT PR RUN_ID
# builds the run in its own process and prints four lines --
#   repo / run id / research dir / run (marker) dir
# -- so a harness can seed a real run without sourcing child-dispatch.sh into
# its own global scope. The `--make-run` sentinel and not an argument count: a
# harness that sources this file is itself often running with arguments, and
# `[ "$#" -eq 4 ]` would then fire on the CALLER's argv.
if [ "${1:-}" = "--make-run" ]; then
  shift
  [ "$#" -eq 4 ] || {
    echo "usage: _lib_review_run_fixture.sh --make-run ROOT PLUGIN_ROOT PR RUN_ID" >&2
    exit 2
  }
  . "$2/lib/child-dispatch.sh" || exit 2
  review_fixture_make_run "$1" "$2" "$3" "$4" >&2 || exit 2
  printf '%s\n' "$RF_REPO" "$RF_RUN_ID" "$RF_RESEARCH_DIR" "$RF_RUN_DIR"
fi
