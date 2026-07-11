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
request="$(jq -cn --arg run "$TMP/run" --arg repo "$ROOT" '{schema_version:1,run_dir:$run,run_id:"review-contract",repository_id:$repo,backend:"codex",workflow:"review-pr",phase:"review",role:"lead",task_tier:"medium",risk_signals:["security"],issue_or_pr:1,issue_num:1,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
decision="$(uberdev_agent_resolve_request "$request")"
metadata="$(jq -cn --arg repo "$ROOT" '{run_id:"review-contract",repository_id:$repo,workflow:"review-pr",backend:"codex",issue_num:1,task_tier:"medium",risk_signals:["security"]}')"
context_out="$(uberdev_agent_context_create "$TMP/run" "$request" "$decision" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$metadata" '2026-07-10T00:00:00Z')"
ctx="$(jq -r .context_file <<<"$context_out")"; sha="$(jq -r .context_sha256 <<<"$context_out")"
UBERDEV_RUN_CARRIER_JSON="$(jq -cn --arg ctx "$ctx" --arg sha "$sha" '{schema_version:1,run_id:"review-contract",workflow:"review-pr",issue_num:1,context_file:$ctx,context_sha256:$sha}')"
export UBERDEV_RUN_CARRIER_JSON

path="$ROOT/README.md"; dir="$ROOT"
declare -a edges inputs risks
for lens in correctness silent_failures types comments tests; do
  edges+=("review_pr.review.$lens")
  inputs+=("$(jq -cn --arg p "$path" '{changed_paths:[$p],diff_path:$p,criteria_path:$p,emphasis:[]}')")
  risks+=('[]')
done
edges+=(review_pr.review.general)
inputs+=("$(jq -cn --arg p "$path" '{changed_paths:[$p],diff_path:$p,criteria_path:$p,emphasis:[],lens:"general"}')")
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

# Every required reviewer supports one unique, exact-input format repair retry.
for i in 0 1 2 3 4 5; do
  retry="$(jq -c '. + {format_repair:true}' <<<"${inputs[$i]}")"
  uberdev_create_child_handoff "${edges[$i]}" "review-contract-${i}-iter1-attempt02" "$retry" '[]' >/dev/null
  jq -e '.inputs.format_repair == true' "$UBERDEV_CHILD_HANDOFF" >/dev/null
done

# Source/init precedes the builders, and all executable snippets are nounset-safe.
for doc in "$REVIEW" "$SIMPLIFY"; do
  setup_line="$(grep -n 'uberdev-executable setup=' "$doc" | head -1 | cut -d: -f1)"
  builder_line="$(grep -n 'review_child_record()' "$doc" | head -1 | cut -d: -f1)"
  [ "$setup_line" -lt "$builder_line" ]
done
# Execute each setup fence in isolation under `set -u`; inherited carriers avoid
# external preparation while still proving source/init ordering and defaults.
for spec in "$REVIEW:review-pr" "$SIMPLIFY:simplify" "$POST:post-impl-review"; do
  doc="${spec%:*}"; name="${spec##*:}"; setup="$TMP/setup-$name.sh"
  awk -v marker="uberdev-executable setup=$name" '
    index($0,marker){active=1; next}
    active && /^```/{exit}
    active{print}
  ' "$doc" >"$setup"
  [ -s "$setup" ]
  env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$ROOT" \
    RUN_ID="20260710-000000-abcdef0" PR_NUMBER=1 ARGUMENTS='' \
    RESEARCH_DIR_ABS="$TMP/setup-$name" UBERDEV_RUN_CARRIER_JSON="$UBERDEV_RUN_CARRIER_JSON" \
    bash "$setup"
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

grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$REVIEW"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$SIMPLIFY"
grep -q 'uberdev_preflight_child_batch "${handoffs\[@\]}"' "$POST"
! rg -n "wait_child .* 0|IFS='\\|'|additional_focus|brief_path|lens_index" "$REVIEW" "$SIMPLIFY" "$POST"

echo 'review-child-handoff: PASS'
