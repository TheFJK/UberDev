#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
REVIEW="$ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY="$ROOT/plugins/uberdev/commands/simplify.md"
POST="$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

. "$LIB"
mkdir -p "$TMP/run"
TEST_REPO="$TMP/repo"; mkdir -p "$TEST_REPO"; TEST_REPO="$(cd "$TEST_REPO" && pwd -P)"
git -C "$TEST_REPO" init -q
printf 'fixture\n' >"$TEST_REPO/README.md"
request="$(jq -cn --arg run "$TMP/run" --arg repo "$TEST_REPO" '{schema_version:1,run_dir:$run,run_id:"review-contract",repository_id:$repo,backend:"codex",workflow:"review-pr",phase:"review",role:"lead",task_tier:"medium",risk_signals:["security"],issue_or_pr:1,issue_num:1,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
decision="$(uberdev_agent_resolve_request "$request")"
metadata="$(jq -cn --arg repo "$TEST_REPO" '{run_id:"review-contract",repository_id:$repo,workflow:"review-pr",backend:"codex",issue_num:1,task_tier:"medium",risk_signals:["security"]}')"
context_out="$(uberdev_agent_context_create "$TMP/run" "$request" "$decision" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$metadata" '2026-07-10T00:00:00Z')"
ctx="$(jq -r .context_file <<<"$context_out")"; sha="$(jq -r .context_sha256 <<<"$context_out")"
UBERDEV_RUN_CARRIER_JSON="$(jq -cn --arg ctx "$ctx" --arg sha "$sha" '{schema_version:1,run_id:"review-contract",workflow:"review-pr",issue_num:1,context_file:$ctx,context_sha256:$sha}')"
export UBERDEV_RUN_CARRIER_JSON

mkdir -p "$TMP/simplify-run"
simplify_request="$(jq -cn --arg run "$TMP/simplify-run" --arg repo "$TEST_REPO" '{schema_version:1,run_dir:$run,run_id:"simplify-contract",repository_id:$repo,backend:"codex",workflow:"simplify",phase:"simplify",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:0,issue_num:0,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
simplify_decision="$(uberdev_agent_resolve_request "$simplify_request")"
simplify_metadata="$(jq -cn --arg repo "$TEST_REPO" '{run_id:"simplify-contract",repository_id:$repo,workflow:"simplify",backend:"codex",issue_num:0,task_tier:"medium",risk_signals:[]}')"
simplify_context_out="$(uberdev_agent_context_create "$TMP/simplify-run" "$simplify_request" "$simplify_decision" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$simplify_metadata" '2026-07-10T00:00:00Z')"
simplify_ctx="$(jq -r .context_file <<<"$simplify_context_out")"; simplify_sha="$(jq -r .context_sha256 <<<"$simplify_context_out")"
SIMPLIFY_CARRIER_JSON="$(jq -cn --arg ctx "$simplify_ctx" --arg sha "$simplify_sha" '{schema_version:1,run_id:"simplify-contract",workflow:"simplify",issue_num:0,context_file:$ctx,context_sha256:$sha}')"

path="$TEST_REPO/README.md"; changed_path="README.md"; deleted_path="src/deleted-in-pr.ts"; dir="$TEST_REPO"
declare -a edges inputs risks
for lens in correctness silent_failures types comments tests; do
  edges+=("review_pr.review.$lens")
  inputs+=("$(jq -cn --arg changed "$changed_path" --arg deleted "$deleted_path" --arg p "$path" '{changed_paths:[$changed,$deleted],diff_path:$p,criteria_path:$p,emphasis:[]}')")
  risks+=('[]')
done
edges+=(review_pr.review.general)
inputs+=("$(jq -cn --arg changed "$changed_path" --arg deleted "$deleted_path" --arg p "$path" '{changed_paths:[$changed,$deleted],diff_path:$p,criteria_path:$p,emphasis:[],lens:"general"}')")
risks+=('[]')
for edge in review_pr.fix.phase1 review_pr.fix.phase2; do
  edges+=("$edge")
  inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')")
  risks+=(null)
done
for lens in reuse quality efficiency; do
  edges+=("review_pr.simplify.$lens")
  inputs+=("$(jq -cn --arg p "$path" --arg lens "$lens" '{diff_path:$p,lens:$lens,focus:"review"}')")
  risks+=('[]')
done
edges+=(review_pr.defer.findings)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{phase1_path:$p,phase2_path:$p,phase1_disposition_path:$p,phase2_disposition_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.classify)
inputs+=("$(jq -cn --arg p "$path" '{pr_number:1,run_id:"1",log_path:$p}')")
risks+=('[]')
edges+=(review_pr.ci.fix_code)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{classification_path:$p,log_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.rebase)
inputs+=("$(jq -cn --arg d "$dir" '{working_dir:$d,pr_number:1,head_sha:"0123456789012345678901234567890123456789",base_sha:"abcdefabcdefabcdefabcdefabcdefabcdefabcd"}')")
risks+=(null)
edges+=(review_pr.ci.defer_refusal)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{phase1_path:$p,working_dir:$d,pr_number:1}')")
risks+=(null)
edges+=(review_pr.ci.resolve_conflict)
inputs+=("$(jq -cn --arg p "$path" --arg d "$dir" '{file_path:$p,working_dir:$d,pr_branch:"feature",integration_branch:"main",base_sha:"abcdefabcdefabcdefabcdefabcdefabcdefabcd"}')")
risks+=(null)

for i in "${!edges[@]}"; do
  instance="review-contract-${i}-iter1-attempt01"
  uberdev_create_child_handoff "${edges[$i]}" "$instance" "${inputs[$i]}" "${risks[$i]}" >/dev/null
  jq -e --arg edge "${edges[$i]}" '.edge_id==$edge and (.inputs|type)=="object"' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# Every required reviewer supports one unique, exact-input format retry.
for i in 0 1 2 3 4 5; do
  retry="$(jq -c '. + {format_retry:true}' <<<"${inputs[$i]}")"
  uberdev_create_child_handoff "${edges[$i]}" "review-contract-${i}-iter1-attempt02" "$retry" '[]' >/dev/null
  jq -e '.inputs.format_retry == true' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# changed_paths is Git diff metadata, not an existing-file capability. Accept
# normalized repo-relative entries (including deleted files), and reject every
# spelling that could escape or ambiguously reinterpret the repository scope.
base_review_input="$(jq -cn --arg p "$path" '{changed_paths:["src/deleted-in-pr.ts"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.correctness review-relative-deleted-iter1-attempt01 "$base_review_input" '[]' >/dev/null
jq -e '.inputs.changed_paths==["src/deleted-in-pr.ts"]' "$UBERDEV_CHILD_HANDOFF" >/dev/null
empty_review_input="$(jq -cn --arg p "$path" '{changed_paths:[],diff_path:$p,criteria_path:$p,emphasis:[]}')"
if uberdev_create_child_handoff review_pr.review.correctness review-empty-scope-iter1-attempt01 "$empty_review_input" '[]' >/dev/null 2>&1; then
  echo "empty changed_paths review scope accepted" >&2
  exit 1
fi
for unsafe in "$path" '../outside.ts' 'src/../outside.ts' './src/file.ts' 'src//file.ts' 'src\file.ts' 'C:\repo\file.ts' 'C:/repo/file.ts' $'src/tab\tfile.ts'; do
  unsafe_input="$(jq -cn --arg unsafe "$unsafe" --arg p "$path" '{changed_paths:[$unsafe],diff_path:$p,criteria_path:$p,emphasis:[]}')"
  if uberdev_create_child_handoff review_pr.review.correctness "review-unsafe-$RANDOM-iter1-attempt01" "$unsafe_input" '[]' >/dev/null 2>&1; then
    echo "unsafe changed_paths entry accepted: $unsafe" >&2
    exit 1
  fi
done

# Routed child prompt composition appends the exact shared contract immediately
# before the immutable execution directive.
contract="$ROOT/plugins/uberdev/shared/phase1-reviewer-output-v1.md"
contract_input="$(jq -cn --arg p "$path" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.correctness review-contract-prompt-iter1-attempt01 "$contract_input" '[]' >/dev/null
_uberdev_child_prepare review_pr.review.correctness "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch >/dev/null
prompt="$(dirname "$UBERDEV_CHILD_RESULT")/prompt.txt"
python3 -I -B - "$prompt" "$contract" <<'PY'
import pathlib,sys
prompt=pathlib.Path(sys.argv[1]).read_bytes(); contract=pathlib.Path(sys.argv[2]).read_bytes()
needle=b'\n\n'+contract+b'\n\n## Immutable routed execution directive\n'
assert prompt.count(contract)==1
assert needle in prompt
PY

# Mutating review edges execute against the carrier-selected caller repository
# identity and workspace binding. Reviewers remain isolated, and a different
# working_dir is rejected before dispatch.
caller_input="$(jq -cn --arg p "$path" --arg d "$TEST_REPO" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')"
uberdev_create_child_handoff review_pr.fix.phase1 review-caller-mode-iter1-attempt01 "$caller_input" null >/dev/null
caller_prepared="$(_uberdev_child_prepare review_pr.fix.phase1 "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch)"
jq -e --arg repo "$TEST_REPO" '.request.workspace_mode=="caller" and .request.workspace_dir==$repo' <<<"$caller_prepared" >/dev/null
reviewer_input="$(jq -cn --arg p "$path" '{changed_paths:["README.md"],diff_path:$p,criteria_path:$p,emphasis:[]}')"
uberdev_create_child_handoff review_pr.review.types review-isolated-mode-iter1-attempt01 "$reviewer_input" '[]' >/dev/null
reviewer_prepared="$(_uberdev_child_prepare review_pr.review.types "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" dispatch)"
jq -e '.request.workspace_mode=="isolated" and (.request|has("workspace_dir")|not)' <<<"$reviewer_prepared" >/dev/null
OTHER_REPO="$TMP/other-repo"; mkdir -p "$OTHER_REPO"
mismatch_input="$(jq -cn --arg p "$path" --arg d "$OTHER_REPO" '{findings_path:$p,commit_range_path:$p,working_dir:$d,pr_number:1,disposition_path:$p}')"
if uberdev_create_child_handoff review_pr.fix.phase1 review-mismatch-mode-iter1-attempt01 "$mismatch_input" null >/dev/null 2>&1; then
  echo 'caller workspace mismatch accepted' >&2
  exit 1
fi

# A standalone simplify run may omit an additional focus hint.
for lens in reuse quality efficiency; do
  edge="review_pr.simplify.$lens"
  input="$(jq -cn --arg p "$path" --arg lens "$lens" '{diff_path:$p,lens:$lens}')"
  uberdev_create_child_handoff "$edge" "simplify-no-focus-$lens-iter1-attempt01" "$input" '[]' >/dev/null
  jq -e '(.inputs | has("focus") | not)' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# Source/init precedes the builders, and all executable snippets are nounset-safe.
for doc in "$REVIEW" "$SIMPLIFY"; do
  setup_line="$(grep -n 'uberdev-executable setup=' "$doc" | head -1 | cut -d: -f1)"
  builder_line="$(grep -n 'review_child_record()' "$doc" | head -1 | cut -d: -f1)"
  [ "$setup_line" -lt "$builder_line" ]
done
# Extract each production setup fence.
for spec in "$REVIEW:review-pr" "$SIMPLIFY:simplify" "$POST:post-impl-review"; do
  doc="${spec%:*}"; name="${spec##*:}"; setup="$TMP/setup-$name.sh"
  awk -v marker="uberdev-executable setup=$name" '
    index($0,marker){active=1; next}
    active && /^```/{exit}
    active{print}
  ' "$doc" >"$setup"
  [ -s "$setup" ]
done

# Review and simplify execute with inherited carriers. Post-review attaches to
# the exact descriptor exported by its parent review setup.
REVIEW_RUN_ID=20260710-000000-abcdef0
REVIEW_DESCRIPTOR="$(env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID="$REVIEW_RUN_ID" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
  bash -c '. "$1"; printf "%s" "$UBERDEV_COMMAND_WORKSPACE_JSON"' _ "$TMP/setup-review-pr.sh")"
env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID=20260710-000001-abcdef0 PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$SIMPLIFY_CARRIER_JSON" \
  bash "$TMP/setup-simplify.sh"
env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
  RUN_ID="$REVIEW_RUN_ID" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
  UBERDEV_COMMAND_WORKSPACE_JSON="$REVIEW_DESCRIPTOR" bash "$TMP/setup-post-impl-review.sh"

# Setup is a fail-closed validation boundary. Neither a standalone carrier
# preparation failure nor an invalid/spoofed inherited carrier may create the
# command-owned research directory or any artifact beneath it.
FAKE_PLUGIN="$TMP/failing-plugin"
mkdir -p "$FAKE_PLUGIN/lib"
cat >"$FAKE_PLUGIN/lib/child-dispatch.sh" <<'SH'
uberdev_prepare_run_carrier() { return 17; }
SH
setup_index=0
for spec in "$REVIEW:review-pr" "$SIMPLIFY:simplify"; do
  setup_index=$((setup_index + 1))
  doc="${spec%:*}"; name="${spec##*:}"; setup="$TMP/setup-$name.sh"

  failed_run="$(printf '20260710-0001%02d-abcdef0' "$setup_index")"
  failed_target="$TEST_REPO/.uberdev/research/$failed_run"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="$failed_run" PR_NUMBER=1 ARGUMENTS='' bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly survived carrier preparation failure: $name" >&2
    exit 1
  fi
  [ ! -e "$failed_target" ]

  invalid_run="$(printf '20260710-0002%02d-abcdef0' "$setup_index")"
  invalid_target="$TEST_REPO/.uberdev/research/$invalid_run"
  invalid_carrier="$(jq -c '.context_sha256 = ("0" * 64)' <<<"$UBERDEV_RUN_CARRIER_JSON")"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="$invalid_run" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$invalid_carrier" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted invalid inherited carrier: $name" >&2
    exit 1
  fi
  [ ! -e "$invalid_target" ]

  spoof_root="$TMP/spoof-root-$name"; mkdir -p "$spoof_root"
  spoof_target="$TEST_REPO/.uberdev/research/20260710-000030-abcdef0"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$spoof_root" \
    RUN_ID="20260710-000030-abcdef0" PR_NUMBER=1 ARGUMENTS='' UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted spoofed inherited repository: $name" >&2
    exit 1
  fi
  [ ! -e "$spoof_target" ]

  escaped_target="$TMP/escaped-research-$name"
  if env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TEST_REPO" \
    RUN_ID="20260710-000040-abcdef0" PR_NUMBER=1 ARGUMENTS='' \
    RESEARCH_DIR_ABS="$escaped_target" UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
    bash "$setup" >/dev/null 2>&1; then
    echo "setup unexpectedly accepted research path outside verified roots: $name" >&2
    exit 1
  fi
  [ ! -e "$escaped_target" ]
done

# The executable builder preflights the complete immutable batch before the
# first launch and boundedly unwinds an earlier child when a later launch fails.
sed -n '/BEGIN review-child-builder-v1/,/END review-child-builder-v1/p' "$REVIEW" \
  | sed '/BEGIN review-child-builder-v1/d;/END review-child-builder-v1/d;/^```/d' >"$TMP/builder.sh"
cat >"$TMP/lifecycle.sh" <<'SH'
set -euo pipefail
. "$1"
log="$2"; run="$3"; mkdir -p "$run"
uberdev_create_child_handoff() {
  printf 'create %s\n' "$1" >>"$log"
  UBERDEV_CHILD_HANDOFF="$run/$2.handoff"; UBERDEV_CHILD_RESULT="$run/$2.result"; UBERDEV_CHILD_STATUS="$run/$2.status"
  : >"$UBERDEV_CHILD_HANDOFF"
}
uberdev_preflight_child_batch() { printf 'preflight %s\n' "$#" >>"$log"; [ "$#" -eq 2 ]; }
uberdev_dispatch_child() { printf 'dispatch %s\n' "$1" >>"$log"; [ "$1" != second.edge ] || return 9; printf 'receipt'; }
uberdev_unwind_child() { printf 'unwind %s %s %s\n' "$1" "$2" "$3" >>"$log"; [ "$3" -gt 0 ]; }
uberdev_wait_child() { return 0; }
records="$run/records"; : >"$records"
review_child_record first.edge first-iter1-attempt01 '{}' '[]' "$records"
review_child_record second.edge second-iter1-attempt01 '{}' '[]' "$records"
if review_child_fanout "$records" "$run/descriptors" "$run/launched" 17; then exit 20; fi
SH
bash "$TMP/lifecycle.sh" "$TMP/builder.sh" "$TMP/lifecycle.log" "$TMP/lifecycle"
[ "$(grep -n '^preflight ' "$TMP/lifecycle.log" | cut -d: -f1)" -lt "$(grep -n '^dispatch ' "$TMP/lifecycle.log" | head -1 | cut -d: -f1)" ]
[ "$(grep -c '^create ' "$TMP/lifecycle.log")" -eq 2 ]
grep -q '^preflight 2$' "$TMP/lifecycle.log"
grep -Eq '^unwind .+ .+ 17$' "$TMP/lifecycle.log"

# If receipt-ledger serialization fails after dispatch returns success, the
# controller must unwind the current child first, then every prior ledgered
# child, and preserve the serialization rc even when current cleanup fails.
sed -n '/BEGIN review-child-builder-v1/,/END review-child-builder-v1/p' "$SIMPLIFY" \
  | sed '/BEGIN review-child-builder-v1/d;/END review-child-builder-v1/d;/^```/d' >"$TMP/simplify-builder.sh"
awk '/^post_review_fanout\(\) \{/{active=1} active{print} active && /^\}/{exit}' "$POST" >"$TMP/post-builder.sh"
awk '/^post_review_fanout\(\) \{/{active=1} active{print} /^post_review_wait_all\(\) \{/{wait_fn=1} active && wait_fn && /^\}/{exit}' "$POST" >"$TMP/post-runtime.sh"
cat >"$TMP/ledger-failure.sh" <<'SH'
set -u
runtime="$1"; fanout="$2"; flavor="$3"; run="$4"; mkdir -p "$run"
log="$run/unwind.log"; marker="$run/fail-next-ledger"; dispatches="$run/dispatches"
: >"$log"; : >"$dispatches"
REAL_PYTHON="$(command -v python3)"; REAL_JQ="$(command -v jq)"
. "$runtime"
python3() {
  local arg
  for arg in "$@"; do
    if [ -e "$marker" ] && [ "$arg" = "$run/launched" ]; then rm -f "$marker"; return 73; fi
  done
  command "$REAL_PYTHON" "$@"
}
jq() {
  if [ -e "$marker" ] && [ "${1:-}" = -cn ]; then rm -f "$marker"; return 73; fi
  command "$REAL_JQ" "$@"
}
uberdev_create_child_handoff() {
  UBERDEV_CHILD_HANDOFF="$run/$2.handoff"; UBERDEV_CHILD_RESULT="$run/$2.result"; UBERDEV_CHILD_STATUS="$run/$2.status"
  : >"$UBERDEV_CHILD_HANDOFF"
}
uberdev_preflight_child_batch() { [ "$#" -eq 2 ]; }
uberdev_dispatch_child() {
  printf '%s\n' "$1" >>"$dispatches"
  if [ "$(wc -l <"$dispatches" | tr -d ' ')" -eq 2 ]; then : >"$marker"; fi
  printf 'receipt-%s' "$1"
}
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$log"
  case "$1" in *second.status) return 9 ;; *) return 0 ;; esac
}
printf '%s\n' \
  '{"edge":"first.edge","instance":"first","inputs":{},"risks":[]}' \
  '{"edge":"second.edge","instance":"second","inputs":{},"risks":[]}' >"$run/records"
set +e
"$fanout" "$run/records" "$run/descriptors" "$run/launched" 29 >"$run/stdout" 2>"$run/stderr"
rc=$?
set -e
[ "$rc" -eq 73 ]
[ "$(wc -l <"$log" | tr -d ' ')" -eq 2 ]
[ "$(sed -n '1p' "$log")" = "$run/second.status	$run/second.result	29" ]
[ "$(sed -n '2p' "$log")" = "$run/first.status	$run/first.result	29" ]
grep -q 'current child cleanup failed' "$run/stderr"
SH
bash "$TMP/ledger-failure.sh" "$TMP/builder.sh" review_child_fanout review "$TMP/ledger-review"
bash "$TMP/ledger-failure.sh" "$TMP/simplify-builder.sh" review_child_fanout simplify "$TMP/ledger-simplify"
bash "$TMP/ledger-failure.sh" "$TMP/post-builder.sh" post_review_fanout post "$TMP/ledger-post"

# Wait failures are drained current-by-current without abandoning later
# receipts. Preserve the first wait rc even when a cleanup fails.
cat >"$TMP/wait-ledger-failure.sh" <<'SH'
set -u
runtime="$1"; wait_all="$2"; run="$3"; flavor="$4"; mkdir -p "$run"
wait_log="$run/wait.log"; unwind_log="$run/unwind.log"; : >"$wait_log"; : >"$unwind_log"
. "$runtime"
uberdev_wait_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$wait_log"
  case "$1" in *wait-fail-first.status) return 7 ;; *wait-fail-second.status) return 8 ;; *) return 0 ;; esac
}
# This fixture exercises wait-drain ordering only; reviewer-result validation
# has its own behavioral coverage in the six-child integration test.
uberdev_child_validate_phase1_review_result() { return 0; }
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$unwind_log"
  case "$1" in *wait-fail-first.status) return 9 ;; *) return 0 ;; esac
}
printf '%s\n' \
  "{\"edge\":\"first.edge\",\"status\":\"$run/ok.status\",\"result\":\"$run/ok.result\"}" \
  "{\"edge\":\"second.edge\",\"status\":\"$run/wait-fail-first.status\",\"result\":\"$run/wait-fail-first.result\"}" \
  "{\"edge\":\"third.edge\",\"status\":\"$run/wait-fail-second.status\",\"result\":\"$run/wait-fail-second.result\"}" >"$run/launched"
unset FAILED_REVIEW_EDGE FAILED_REVIEW_INDEX
set +e
if [ "$flavor" = post ]; then
  "$wait_all" "$run/launched" 31 "$run/failed" >"$run/stdout" 2>"$run/stderr"
else
  "$wait_all" "$run/launched" 31 >"$run/stdout" 2>"$run/stderr"
fi
rc=$?
set -e
[ "$rc" -eq 7 ]
[ "$(wc -l <"$wait_log" | tr -d ' ')" -eq 3 ]
[ "$(wc -l <"$unwind_log" | tr -d ' ')" -eq 2 ]
[ "$(sed -n '1p' "$unwind_log")" = "$run/wait-fail-first.status	$run/wait-fail-first.result	31" ]
[ "$(sed -n '2p' "$unwind_log")" = "$run/wait-fail-second.status	$run/wait-fail-second.result	31" ]
grep -q 'cleanup failed after child wait' "$run/stderr"
if [ "$flavor" = post ]; then
  python3 -I -B - "$run/failed" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8') if line.strip()]
assert [(row['edge'],row['index']) for row in rows]==[('second.edge',2),('third.edge',3)],rows
PY
fi
SH
bash "$TMP/wait-ledger-failure.sh" "$TMP/builder.sh" review_child_wait_all "$TMP/wait-review" review
bash "$TMP/wait-ledger-failure.sh" "$TMP/simplify-builder.sh" review_child_wait_all "$TMP/wait-simplify" simplify
bash "$TMP/wait-ledger-failure.sh" "$TMP/post-runtime.sh" post_review_wait_all "$TMP/wait-post" post

grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$REVIEW"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$SIMPLIFY"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$POST"
! grep -En "wait_child .* 0|IFS='\\|'|additional_focus|brief_path|lens_index" "$REVIEW" "$SIMPLIFY" "$POST"
! grep -En 'format_repair' "$POST"
grep -Eq 'format_retry' "$POST"

echo 'review-child-handoff: PASS'
