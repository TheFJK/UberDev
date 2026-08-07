# review-fleet-args.sh -- the caller half of skills/review-fleet/workflow.js.
#
# WHY THIS FILE EXISTS (#381, blocker B). The engine is dispatched by the
# calling session's Workflow tool, so the CONTROLLER owes five things before
# every stage: the RFC 0012 §4.1 existence guard, the per-child directory the
# script derives, one CSPRNG `run_nonce` per child minted in the roster order
# the script consumes, one launch binding per child minted BEFORE the call, and
# the args envelope. Two command files owe exactly the same five, and the roster
# ORDER is a wire format shared with the script -- duplicating that order in two
# markdown fences would let it drift silently, and a drifted order re-binds
# every child to the wrong nonce. So the roster lives here, once, next to the
# nonce mint and the binding producers that consume it.
#
# Same precedent, same reasoning as lib/review-aggregate.sh: every `bash` block
# in a command file is a FRESH shell, so fence text is not reachable from the
# next fence. Anything a later fence must call has to be on disk.
#
# THE SEAM IS NOT MOVED BY THIS FILE. Every digest and every artifact
# validation still happens in lib/code_fixer_contract.py, invoked here as a
# subprocess FROM THE CALLING SESSION. This file computes no digest of its own,
# runs no git, no gh, and no network. It mints nonces, makes directories,
# forwards controller-supplied scalars to the contract, and records what it
# minted.
#
# Callers must have these bound before the first call:
#   UBERDEV_REVIEW_PLUGIN_ROOT   plugin root
#   WORKTREE_ROOT                the caller checkout the children run against
#   RESEARCH_DIR_ABS             .uberdev/research/<RUN_ID> (the script's runDirAbs)
#   REVIEW_ITERATION             the per-iteration artifact key

# review_fleet_roster STAGE -> one "<slug>\t<edge>" row per child, IN ORDER.
#
# THIS ORDER IS THE NONCE-MAPPING CONTRACT. It is byte-for-byte the order of
# REVIEW_ROSTER / LENS_ROSTER in skills/review-fleet/workflow.js and of the
# table in that skill's SKILL.md. Reordering either side silently binds every
# child to another child's nonce: the child then echoes a nonce the controller
# minted for someone else, and _validate_bound_workflow_child_status refuses the
# whole wave. It fails closed, but it wastes a real fanout -- treat these rows
# as a wire format, not as a list.
review_fleet_roster() {
  case "${1:-}" in
    review)
      printf '%s\t%s\n' \
        correctness      review_pr.review.correctness \
        silent-failures  review_pr.review.silent_failures \
        types            review_pr.review.types \
        comments         review_pr.review.comments \
        tests            review_pr.review.tests \
        general          review_pr.review.general
      ;;
    simplify)
      printf '%s\t%s\n' \
        reuse       review_pr.simplify.reuse \
        quality     review_pr.simplify.quality \
        efficiency  review_pr.simplify.efficiency
      ;;
    *)
      echo "error: review_fleet_roster: unknown fanout stage '${1:-}'" >&2
      return 2
      ;;
  esac
}

# review_fleet_expected STAGE -> the exact child count of that roster.
review_fleet_expected() {
  local rows
  rows="$(review_fleet_roster "${1:-}")" || return 2
  printf '%s' "$rows" | grep -c . || return 2
}

# review_fleet_mint_nonce -> one single-use 64-hex run_nonce from a real CSPRNG.
#
# openssl(1) first, python3 `secrets` second; both are CSPRNGs. $RANDOM and any
# timestamp are BANNED here and must stay banned: a nonce a third party can
# predict or replay is not a binding token at all, and the whole workflow-child
# proof rests on the controller being the only party that could have known this
# value before the child echoed it back.
review_fleet_mint_nonce() {
  local nonce=''
  if command -v openssl >/dev/null 2>&1; then
    nonce="$(openssl rand -hex 32 2>/dev/null)" || nonce=''
  fi
  case "$nonce" in
    '' | *[!0-9a-f]*)
      nonce="$(python3 -I -B -c 'import secrets; print(secrets.token_hex(32),end="")' 2>/dev/null)" || nonce=''
      ;;
  esac
  case "$nonce" in
    *[!0-9a-f]*)
      echo "error: review_fleet_mint_nonce: no CSPRNG produced a 64-hex nonce" >&2
      return 2
      ;;
  esac
  [ "${#nonce}" -eq 64 ] || {
    echo "error: review_fleet_mint_nonce: no CSPRNG produced a 64-hex nonce" >&2
    return 2
  }
  printf '%s' "$nonce"
}

# review_fleet_iter_suffix ITER -> iterNN, the script's own zero-padding
# (`"iter" + ("0" + String(reviewIteration)).slice(-2)`).
review_fleet_iter_suffix() {
  case "${1:-}" in
    '' | *[!0-9]*) return 2 ;;
  esac
  printf 'iter%02d' "$((10#$1))"
}

# review_fleet_child_dir RUN_DIR ITER SLUG -> the child directory the SCRIPT
# derives. Computed identically on both sides so no envelope scalar and no
# round-trip is needed to agree on it.
review_fleet_child_dir() {
  local suffix
  [ "$#" -eq 3 ] || return 2
  suffix="$(review_fleet_iter_suffix "$2")" || return 2
  printf '%s/children/%s-%s' "$1" "$3" "$suffix"
}

# review_fleet_ci_slug BASE CI_ITER -> the script's ciSlug() rule (#383).
#
# Phase 3's loop counter advances INSIDE one reviewIteration, so it cannot key
# the child directory: iterSuffix() already owns that suffix on both sides, and
# a second directory formula is exactly the drift review_fleet_child_dir exists
# to prevent. It keys the SLUG instead, which leaves child_dir (and the test
# that pins /run/children/correctness-iter07) byte-identical while still making
# `<runDir>/children/ci-rebase-ci02-iter01` unique in both counters.
review_fleet_ci_slug() {
  [ "$#" -eq 2 ] || return 2
  case "${2:-}" in '' | *[!0-9]*) return 2 ;; esac
  [ -n "${1:-}" ] || return 2
  printf '%s-ci%02d' "$1" "$((10#$2))"
}

# review_fleet_edge_slug EDGE -> the script's fixer/defer slug rule: lowercased,
# every non-alphanumeric run collapsed to '-', no leading or trailing '-'.
review_fleet_edge_slug() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
}

# review_fleet_pool_guard STAGE POOL -> refuse a pool that does not cover the
# roster EXACTLY. A short pool leaves a child unbound; a long one means the
# controller and the script disagree about the roster. The script re-checks the
# same thing (nonceGate) -- this side checks it too so a mis-sized pool never
# reaches a dispatch at all.
review_fleet_pool_guard() {
  local stage="${1:-}" pool="${2:-}" expected total valid
  expected="$(review_fleet_expected "$stage")" || return 2
  total="$(printf '%s' "$pool" | tr ',' '\n' | grep -c '')" || total=0
  valid="$(printf '%s' "$pool" | tr ',' '\n' | grep -c '^[0-9a-f]\{64\}$')" || valid=0
  if [ "$total" != "$expected" ] || [ "$valid" != "$expected" ]; then
    echo "error: review-fleet $stage nonce pool carries $valid valid of $total entries; the roster needs exactly $expected in order" >&2
    return 2
  fi
}

# review_fleet_require_engine -> RFC 0012 §4.1. Exported as a function only for
# reuse; the command files also carry the guard inline, because a preflight that
# can only refuse from inside a helper is one `source` failure away from not
# refusing at all.
review_fleet_require_engine() {
  local script="${UBERDEV_REVIEW_PLUGIN_ROOT:-}/skills/review-fleet/workflow.js"
  [ -f "$script" ] || {
    echo "error: $script missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2
    return 2
  }
  printf '%s' "$script"
}

# review_fleet_bind_roster STAGE RUN_DIR ITER WORKTREE CONTRACT LEDGER
#
# For every roster child, in order: make the directory the script derives, mint
# a nonce, mint the launch binding through the contract, and append the launched
# row. Sets REVIEW_FLEET_NONCE_POOL (the comma-joined scalar the envelope
# carries -- uberdev_emit_workflow_args has no array path, lib/config-read.sh:
# 958-971).
#
# The directory MUST exist before the binding is minted: the contract
# canonicalises result/status with realpath, and every later loader canonicalises
# the same paths again after the child has written them. Binding a path whose
# parent did not exist yet would pin a different string than the one the capture
# verbs resolve, and the wave would fail closed for a reason that names neither
# the child nor the directory.
review_fleet_bind_roster() {
  [ "$#" -eq 6 ] || return 2
  local stage="$1" run_dir="$2" iter="$3" worktree="$4" contract="$5" ledger="$6"
  local slug edge dir instance nonce binding index=0 row
  REVIEW_FLEET_NONCE_POOL=''
  : >"$ledger" || return 2
  while IFS="$(printf '\t')" read -r slug edge; do
    [ -n "$slug" ] || continue
    index=$((index + 1))
    dir="$(review_fleet_child_dir "$run_dir" "$iter" "$slug")" || return 2
    instance="${dir##*/}"
    mkdir -p "$dir" || return 2
    nonce="$(review_fleet_mint_nonce)" || return 2
    binding="$(python3 -I -B "$contract" bind-workflow-launch \
      --edge-id "$edge" --instance-id "$instance" --run-nonce "$nonce" \
      --result-path "$dir/result.md" --status-path "$dir/status.json" \
      --working-dir "$worktree")" || return 2
    row="$(jq -cn --arg edge "$edge" --argjson index "$index" --arg instance "$instance" \
      --arg binding "$binding" --arg result "$dir/result.md" --arg status "$dir/status.json" \
      '{edge:$edge,index:$index,instance:$instance,binding:$binding,result:$result,status:$status}')" || return 2
    printf '%s\n' "$row" >>"$ledger" || return 2
    if [ -z "$REVIEW_FLEET_NONCE_POOL" ]; then
      REVIEW_FLEET_NONCE_POOL="$nonce"
    else
      REVIEW_FLEET_NONCE_POOL="$REVIEW_FLEET_NONCE_POOL,$nonce"
    fi
  done <<EOF_ROSTER
$(review_fleet_roster "$stage")
EOF_ROSTER
  review_fleet_pool_guard "$stage" "$REVIEW_FLEET_NONCE_POOL" || return 2
}

# review_fleet_bind_fixer EDGE RUN_DIR ITER WORKTREE CONTRACT AUTHORITY_PATH
#                         AUTHORITY_SHA256 HEAD_BEFORE SIDECAR
#
# The single mutating child. bind-workflow-fixer-launch, never
# bind-workflow-launch: a fixer owes a disposition and an applied-content
# artifact, and only the fixer producer pins the controller-created authority by
# path and digest.
#
# HEAD_BEFORE is recorded in the sidecar because the mutation gate compares it
# with HEAD after the call, and the fence that runs after the call is a
# different shell. It is read here, before dispatch, so the child cannot be the
# source of the value it is later judged against.
review_fleet_bind_fixer() {
  [ "$#" -eq 9 ] || return 2
  local edge="$1" run_dir="$2" iter="$3" worktree="$4" contract="$5"
  local authority_path="$6" authority_sha256="$7" head_before="$8" sidecar="$9"
  local slug dir instance nonce binding
  case "$head_before" in
    *[!0-9a-f]* | '') return 2 ;;
  esac
  [ "${#head_before}" -eq 40 ] || return 2
  slug="$(review_fleet_edge_slug "$edge")" || return 2
  dir="$(review_fleet_child_dir "$run_dir" "$iter" "$slug")" || return 2
  instance="${dir##*/}"
  mkdir -p "$dir" || return 2
  nonce="$(review_fleet_mint_nonce)" || return 2
  binding="$(python3 -I -B "$contract" bind-workflow-fixer-launch \
    --edge-id "$edge" --instance-id "$instance" --run-nonce "$nonce" \
    --result-path "$dir/result.md" --status-path "$dir/status.json" \
    --working-dir "$worktree" \
    --authority-path "$authority_path" --authority-sha256 "$authority_sha256")" || return 2
  review_fleet_write_sidecar "$sidecar" "$binding" "$dir" "$instance" "$head_before" || return 2
  REVIEW_FLEET_NONCE_POOL="$nonce"
  REVIEW_FLEET_CHILD_DIR="$dir"
  REVIEW_FLEET_INSTANCE="$instance"
}

# review_fleet_bind_persistence RUN_DIR ITER WORKTREE CONTRACT AGGREGATE_PATH
#                               AGGREGATE_SHA256 DISPOSITION_PATH
#                               DISPOSITION_SHA256 EXPECTED_BLOCKERS
#                               REQUIRE_CLEAN SIDECAR
#
# The defer child. bind-workflow-persistence-launch re-counts the deferred
# blockers from the pinned aggregate/disposition bytes, so the count this stage
# halts on is proved, not declared.
review_fleet_bind_persistence() {
  [ "$#" -eq 11 ] || return 2
  local run_dir="$1" iter="$2" worktree="$3" contract="$4"
  local aggregate_path="$5" aggregate_sha256="$6"
  local disposition_path="$7" disposition_sha256="$8"
  local expected_blockers="$9" require_clean="${10}" sidecar="${11}"
  local edge=review_pr.defer.findings slug dir instance nonce binding
  slug="$(review_fleet_edge_slug "$edge")" || return 2
  dir="$(review_fleet_child_dir "$run_dir" "$iter" "$slug")" || return 2
  instance="${dir##*/}"
  mkdir -p "$dir" || return 2
  nonce="$(review_fleet_mint_nonce)" || return 2
  binding="$(python3 -I -B "$contract" bind-workflow-persistence-launch \
    --instance-id "$instance" --run-nonce "$nonce" \
    --result-path "$dir/result.md" --status-path "$dir/status.json" \
    --working-dir "$worktree" \
    --aggregate-path "$aggregate_path" --aggregate-sha256 "$aggregate_sha256" \
    --disposition-path "$disposition_path" --disposition-sha256 "$disposition_sha256" \
    --expected-deferred-blockers "$expected_blockers" \
    --require-clean "$require_clean")" || return 2
  review_fleet_write_sidecar "$sidecar" "$binding" "$dir" "$instance" || return 2
  REVIEW_FLEET_NONCE_POOL="$nonce"
  REVIEW_FLEET_CHILD_DIR="$dir"
  REVIEW_FLEET_INSTANCE="$instance"
}

# review_fleet_bind_ci EDGE RUN_DIR ITER CI_ITER WORKTREE CONTRACT
#                      CI_AUTHORITY_PATH CI_AUTHORITY_SHA256 HEAD_BEFORE SIDECAR
#
# The single-child Phase 3 stages (ci-classify, ci-fix, ci-defer). It uses
# bind-workflow-ci-launch and NOTHING else: a CI child owes the exact bytes of
# the untrusted artifact it was pointed at, and only the CI producer pins that
# input by path and digest. bind-workflow-launch would mint a binding that
# proves the child wrote something and proves nothing about what it read, and
# every downstream equality would still pass.
#
# HEAD_BEFORE crosses the Workflow call in the sidecar for the same reason
# review_fleet_bind_fixer records it: the fence after the call is a different
# shell, and reading it here — before dispatch — is what stops the child from
# being the source of the value it is later judged against. It is empty for the
# two read-only edges.
review_fleet_bind_ci() {
  [ "$#" -eq 10 ] || return 2
  local edge="$1" run_dir="$2" iter="$3" ci_iter="$4" worktree="$5" contract="$6"
  local authority_path="$7" authority_sha256="$8" head_before="$9" sidecar="${10}"
  local base slug dir instance nonce binding
  case "$edge" in
    review_pr.ci.classify)       base=ci-classify ;;
    review_pr.ci.fix_code)       base=ci-fix-code ;;
    review_pr.ci.rebase)         base=ci-rebase ;;
    review_pr.ci.defer_refusal)  base=ci-defer ;;
    *)
      echo "error: review_fleet_bind_ci: unknown single-child CI edge '$edge'" >&2
      return 2
      ;;
  esac
  case "$head_before" in
    '') ;;
    *[!0-9a-f]*) return 2 ;;
    *) [ "${#head_before}" -eq 40 ] || return 2 ;;
  esac
  slug="$(review_fleet_ci_slug "$base" "$ci_iter")" || return 2
  dir="$(review_fleet_child_dir "$run_dir" "$iter" "$slug")" || return 2
  instance="${dir##*/}"
  mkdir -p "$dir" || return 2
  nonce="$(review_fleet_mint_nonce)" || return 2
  binding="$(python3 -I -B "$contract" bind-workflow-ci-launch \
    --edge-id "$edge" --instance-id "$instance" --run-nonce "$nonce" \
    --result-path "$dir/result.md" --status-path "$dir/status.json" \
    --working-dir "$worktree" \
    --ci-authority-path "$authority_path" \
    --ci-authority-sha256 "$authority_sha256")" || return 2
  review_fleet_write_sidecar "$sidecar" "$binding" "$dir" "$instance" "$head_before" || return 2
  REVIEW_FLEET_NONCE_POOL="$nonce"
  REVIEW_FLEET_CHILD_DIR="$dir"
  REVIEW_FLEET_INSTANCE="$instance"
}

# review_fleet_bind_ci_conflicts RUN_DIR ITER CI_ITER WORKTREE CONTRACT
#                                AUTHORITY_LEDGER LEDGER
#
# The N-child conflict fanout. AUTHORITY_LEDGER carries one
# `<ci_authority_path>\t<ci_authority_sha256>` row per conflicted file, in the
# controller's own UU-enumeration order — which IS the nonce wire format for
# this stage, exactly as review_fleet_roster's order is for the reviewers.
#
# One authority per child, not one shared authority: each resolver's pinned
# input names the single path it may touch, and validate-ci-mutation-outcome
# reads that path back out of the authority to judge it. A shared authority
# would make every resolver's scope the union of all of them.
review_fleet_bind_ci_conflicts() {
  [ "$#" -eq 7 ] || return 2
  local run_dir="$1" iter="$2" ci_iter="$3" worktree="$4" contract="$5"
  local authority_ledger="$6" ledger="$7"
  local edge=review_pr.ci.resolve_conflict
  local authority_path authority_sha256 slug dir instance nonce binding index=0 row
  REVIEW_FLEET_NONCE_POOL=''
  : >"$ledger" || return 2
  while IFS="$(printf '\t')" read -r authority_path authority_sha256; do
    [ -n "$authority_path" ] || continue
    index=$((index + 1))
    slug="$(review_fleet_ci_slug "$(printf 'ci-conflict-%02d' "$index")" "$ci_iter")" || return 2
    dir="$(review_fleet_child_dir "$run_dir" "$iter" "$slug")" || return 2
    instance="${dir##*/}"
    mkdir -p "$dir" || return 2
    nonce="$(review_fleet_mint_nonce)" || return 2
    binding="$(python3 -I -B "$contract" bind-workflow-ci-launch \
      --edge-id "$edge" --instance-id "$instance" --run-nonce "$nonce" \
      --result-path "$dir/result.md" --status-path "$dir/status.json" \
      --working-dir "$worktree" \
      --ci-authority-path "$authority_path" \
      --ci-authority-sha256 "$authority_sha256")" || return 2
    row="$(jq -cn --arg edge "$edge" --argjson index "$index" --arg instance "$instance" \
      --arg binding "$binding" --arg result "$dir/result.md" --arg status "$dir/status.json" \
      '{edge:$edge,index:$index,instance:$instance,binding:$binding,result:$result,status:$status}')" || return 2
    printf '%s\n' "$row" >>"$ledger" || return 2
    if [ -z "$REVIEW_FLEET_NONCE_POOL" ]; then
      REVIEW_FLEET_NONCE_POOL="$nonce"
    else
      REVIEW_FLEET_NONCE_POOL="$REVIEW_FLEET_NONCE_POOL,$nonce"
    fi
  done <"$authority_ledger"
  REVIEW_FLEET_CONFLICT_COUNT="$index"
  [ "$index" -gt 0 ] || return 2
}

# The TOTAL number of conflicted files the Phase 3 CONFLICT arm will resolve in
# one wave-batched fanout. NOT `fanout_concurrency.conflict_resolver`: that key
# is a CONCURRENCY knob whose documented behaviour is "split into ceil(N / cap)
# sequential waves" (using-uberdev/references/configuration.md), and forwarding
# it as the total made an 11-conflict PR abort `bad_ci_conflict_count` with zero
# resolvers dispatched — while the wave batching two lines later existed
# precisely to chunk that many. This is the ceiling; the knob is the wave size.
#
# 40, not 50, and the difference is the whole point. `ciConflictCount`'s clamp
# in skills/review-fleet/workflow.js is 50, but the conflict roster is
# dispatched as ONE roster whose length goes straight into that script's
# ceilingGate(), and `maxAgents` — 40 at every review-fleet call site in
# commands/review-pr.md and commands/simplify.md — is a SECOND ceiling sitting
# under the first. At 50 this fence accepted 45 conflicted files that the script
# then killed with `agent_ceiling` and zero resolvers dispatched: the same
# zero-dispatch shape as the 11-conflict bug above, one number further out.
#
# So the number here is the LOWER of the two ceilings, which is what the script
# now enforces too (`Math.min(ciConflictCap, maxAgents)`). A set this fence
# accepts is a set the script dispatches, and a set above it is refused HERE,
# before any Workflow call. Asserted behaviourally — at the cap and at cap+1,
# against the maxAgents the call sites actually emit — by
# tests/review-pr-workflow.test.sh E6.
REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP=40

# review_fleet_write_ci_state PATH CI_ITER REVIEW_ITER FIX_PUSHES_JSON CLASSES_JSON
#
# Phase 3's loop counters CANNOT live in shell variables: every bash block in
# commands/review-pr.md is a FRESH harness shell, so an incremented
# CI_FIX_LOOP_ITER is gone before the next fence reads it and the
# CI_FIX_LOOP_CAP=3 guard degrades to whatever the orchestrator happens to
# remember. That is the fence-scoped-shell-state class, not a detail. On disk it
# is a real counter, and phases.phase3.iterations / .fix_pushes get a real
# accumulator instead of an improvised one.
review_fleet_write_ci_state() {
  [ "$#" -eq 5 ] || return 2
  # `target`, NEVER `path`: zsh TIES the lowercase `path` array to $PATH, so a
  # `local path=` here replaces the command search path for the whole call
  # frame and the `jq` two lines down is command-not-found. Same rule, same
  # reason as lib/status.sh:78-84; asserted repo-wide by
  # tests/crossplatform-shell-wrappers.test.sh.
  local target="$1" ci_iter="$2" review_iter="$3" fix_pushes="$4" classes="$5" payload
  case "$ci_iter$review_iter" in '' | *[!0-9]*) return 2 ;; esac
  payload="$(jq -cn \
    --argjson ci_loop_iter "$ci_iter" \
    --argjson review_iteration "$review_iter" \
    --argjson fix_pushes "${fix_pushes:-[]}" \
    --argjson failure_classes_seen "${classes:-[]}" \
    '{ci_loop_iter:$ci_loop_iter,review_iteration:$review_iteration,fix_pushes:$fix_pushes,failure_classes_seen:$failure_classes_seen}')" || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

# review_fleet_load_ci_counters RUN_DIR
#
# The counter pair, read back in whichever fence needs it. It exists because
# "read them off disk" was implemented in five fences and NOT implemented in
# six others, and the six that skipped it recomputed iteration 1's artifact
# pathnames on iteration 2 -- `prepare-ci-authority` publishes no-clobber, so
# the second CI iteration died on `authority_preexists` with `return 74` and no
# audit event, and CI_FIX_LOOP_CAP=3 was unreachable in practice. Two sources of
# truth for one counter is the defect; this is the one source.
#
# Absent state file = the first fence of the first iteration, which is the only
# time the fresh-shell default is the right answer.
review_fleet_load_ci_counters() {
  [ "$#" -eq 1 ] || return 2
  local state="$1/ci-loop-state.json"
  if [ -r "$state" ]; then
    CI_FIX_LOOP_ITER="$(review_fleet_read_ci_state "$state" ci_loop_iter)" || return 2
    REVIEW_ITERATION="$(review_fleet_read_ci_state "$state" review_iteration)" || return 2
  else
    CI_FIX_LOOP_ITER="${CI_FIX_LOOP_ITER:-1}"
    REVIEW_ITERATION="${REVIEW_ITERATION:-1}"
  fi
  case "$CI_FIX_LOOP_ITER$REVIEW_ITERATION" in '' | *[!0-9]*) return 2 ;; esac
}

# review_fleet_read_ci_state PATH FIELD -> one recorded counter, in a new shell.
review_fleet_read_ci_state() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI loop state missing: ${1:-}" >&2
    return 2
  }
  jq -er --arg field "$2" '.[$field] | if type=="array" then tojson else . end' <"$1"
}

# review_fleet_write_ci_push PATH SHA BY_AGENT
#
# The SINGLE leased push (6c.4w.3) and the Phase 1 re-entry fence that records
# it are two different shells, for exactly the reason review_fleet_write_ci_state
# exists. Passing $NEW_HEAD_SHA between them in a variable recorded an EMPTY sha
# into phases.phase3.fix_pushes -- an audit trail naming no commit, which is
# worse than no entry at all because it reads as a push that happened.
review_fleet_write_ci_push() {
  [ "$#" -eq 3 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state. This one is the
  # sharpest instance: it is called IMMEDIATELY AFTER a successful
  # `git push --force-with-lease`, so a zsh-only rc=2 here lands the remote
  # mutation and then hard-fails the fence before `audit ci_fix_pushed`.
  local target="$1" sha="$2" by_agent="$3" payload
  case "$sha" in
    *[!0-9a-f]*) return 2 ;;
    *) [ "${#sha}" -eq 40 ] || return 2 ;;
  esac
  [ -n "$by_agent" ] || return 2
  payload="$(jq -cn --arg sha "$sha" --arg by_agent "$by_agent" \
    '{sha:$sha,by_agent:$by_agent}')" || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

# review_fleet_read_ci_push PATH FIELD -> one recorded push field, in a new shell.
review_fleet_read_ci_push() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI push record missing: ${1:-}" >&2
    return 2
  }
  jq -er --arg field "$2" '.[$field]' <"$1"
}

# review_fleet_write_conflict_paths PATH [--] PATH...
#
# The conflicted-file set crosses TWO fences (enumerate -> stage) and one
# Workflow call. Held in a shell array it was gone by the time
# `git add -- "${conflicted_files[@]}"` ran, and `git add --` with ZERO
# pathspecs prints "Nothing specified, nothing added." and exits 0 -- so the
# `|| abort` guard never fired, `git rebase --continue` then failed on the still
# unmerged index, and the re-conflict scan sent the orchestrator back to step 1
# forever. NUL-delimited on disk because a repository path may contain a
# newline; the reader is the same `read -r -d ''` loop the enumerator uses.
#
# THE `--` IS OPTIONAL AND IS CONSUMED. This signature is the only one of the
# ~25 in this file that carries a `--`, so it reads as a real separator and the
# callers half two of #383 writes are the ones that will spell it
# `review_fleet_write_conflict_paths "$list" -- "${conflicted[@]}"`. A body that
# only shifted the target wrote a literal `--` as the FIRST NUL entry; the
# consumer's `read -r -d ''` loop then handed it to
# `git add -- "${conflicted_files[@]}"` as a pathspec, git answered
# "pathspec '--' did not match any files", the stage guard fired, and the
# CONFLICT arm aborted a mid-rebase it could have completed. Consuming it is the
# fix rather than deleting it from the comment, because git gives `--` exactly
# this meaning and a file literally NAMED `--` is not a case this stage can
# reach -- git's own porcelain could not enumerate one without the same
# separator.
review_fleet_write_conflict_paths() {
  [ "$#" -ge 1 ] || return 2
  local target="$1"        # NEVER `path` -- see review_fleet_write_ci_state
  shift
  # BEFORE the arity check, never after: `PATH --` names zero conflicted files,
  # which is the empty set the guard below exists to refuse wearing the
  # documented spelling. Shifting it after the check would let it through.
  # `case`, not `[ "${1:-}" = -- ] && shift`: a false `&&` at statement level
  # returns 1, and this file is sourced into fences that may run under `set -e`.
  case "${1:-}" in
    '--') shift ;;
  esac
  [ "$#" -ge 1 ] || return 2
  ( umask 077 && : >"$target" ) || return 2
  local entry
  for entry in "$@"; do
    [ -n "$entry" ] || return 2
    printf '%s\0' "$entry" >>"$target" || return 2
  done
}

# review_fleet_write_sidecar PATH BINDING CHILD_DIR INSTANCE [HEAD_BEFORE]
#
# The binding has to cross a Workflow call, and the fence after that call is a
# different shell. Persisting it is not a downgrade: lib/review-aggregate.sh
# already reads binding-shaped launch rows back off disk, and the binding is a
# PIN, not a secret -- tampering with it can only make the capture verbs refuse,
# because the nonce the child echoes was fixed by the envelope that was already
# emitted.
review_fleet_write_sidecar() {
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" binding="$2" child_dir="$3" instance="$4" head_before="${5:-}"
  local payload
  payload="$(jq -cn --arg binding "$binding" --arg child_dir "$child_dir" \
    --arg instance "$instance" --arg head_before "$head_before" \
    '{binding:$binding,child_dir:$child_dir,instance:$instance,head_before:$head_before}')" || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

# review_fleet_read_sidecar PATH FIELD -> one recorded field, after the call.
review_fleet_read_sidecar() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet launch sidecar missing: ${1:-}" >&2
    return 2
  }
  jq -er --arg field "$2" '.[$field]' <"$1"
}

# review_fleet_write_ci_pointer POINTER TARGET / review_fleet_read_ci_pointer
#
# THE MINT<->PUSH NAMING AGREEMENT, made explicit instead of recomputed.
#
# The ci-fix launch sidecar is named `...-iter<R>-ci<C>.launch.json`, and the
# fence that WRITES it (6c.4w.1) and the fence that READS it (6c.4w.3, the
# single leased push) are different shells that disagreed about C. The
# CONFLICT-RESOLVE arm's restage deliberately advances CI_FIX_LOOP_ITER and
# persists it -- the restage IS a loop iteration -- so after any multi-stage
# rebase the push fence recomputed `...-ci2.launch.json` while only
# `...-ci1.launch.json` had ever been written. `review_fleet_read_sidecar`
# failed, `review_ci_push_abort ci_fixer_binding_unreadable` ran
# `git rebase --abort`, and every resolved conflict was destroyed with nothing
# pushed. Recomputing a filename from a counter whose value legitimately moves
# between the two fences cannot be made correct; the writer therefore publishes
# WHERE it wrote, at a fixed name, and every reader follows the pointer.
review_fleet_write_ci_pointer() {
  [ "$#" -eq 2 ] || return 2
  local pointer="$1" target="$2"
  [ -n "$pointer" ] && [ -n "$target" ] || return 2
  # A newline in the recorded path would make the single-line reader below
  # return a truncated pathname, which is the failure this file exists to stop.
  # A LITERAL newline in the pattern, never `*"$(printf '\n')"*`: command
  # substitution strips trailing newlines, so that spelling degrades to `*""*`
  # and matches every path.
  case "$target" in
    *'
'*) return 2 ;;
  esac
  ( umask 077 && printf '%s\n' "$target" >"$pointer" ) || return 2
}

review_fleet_read_ci_pointer() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI launch pointer missing: ${1:-}" >&2
    return 2
  }
  local recorded
  IFS= read -r recorded <"$1" || return 2
  [ -n "$recorded" ] || return 2
  [ -r "$recorded" ] || {
    echo "error: review-fleet CI launch pointer names an unreadable sidecar: $recorded" >&2
    return 2
  }
  printf '%s' "$recorded"
}

# review_fleet_rebase_dir WORKTREE -> the live rebase state dir, or "" if none.
#
# `git -C <dir> rev-parse --git-path rebase-merge` prints `.git/rebase-merge` --
# a path RELATIVE TO <dir>, not to the caller. `[ -d "$(git -C "$W" rev-parse
# --git-path rebase-merge)" ]` therefore asked the question of whatever
# directory the harness shell happened to be in: from a plain subdirectory of
# the SAME repository it answers "no rebase" mid-rebase. That silently bypassed
# the `rebase_still_in_progress` refusal guarding the force-push and made three
# `git rebase --abort` cleanups no-ops. The Python twin
# (code_fixer_contract.py::_ci_rebase_dir) has always joined the relative result
# with working_dir; this is the shell side of the same ONE definition.
#
# BOTH backends, in the same order as the Python twin's CI_REBASE_STATE_DIRS:
# `git rebase` has defaulted to the merge backend since 2.26, but
# `rebase.backend=apply` and an explicit `git rebase --apply` use `rebase-apply`
# instead, and a probe that knows only one of them answers "no rebase" for the
# other.
#
# Exit codes are THREE-valued on purpose: 0 = a rebase is live (path printed),
# 1 = no rebase (probe succeeded), 2 = the probe itself failed. A two-valued
# probe maps "git could not answer" onto "no rebase", which is the direction
# that force-pushes an interior mid-rebase HEAD.
review_fleet_rebase_dir() {
  [ "$#" -eq 1 ] || return 2
  local worktree="$1" relative absolute component
  for component in rebase-merge rebase-apply; do
    relative="$(git -C "$worktree" rev-parse --git-path "$component" 2>/dev/null)" || return 2
    [ -n "$relative" ] || return 2
    case "$relative" in
      /* | [A-Za-z]:/* | [A-Za-z]:\\*) absolute="$relative" ;;
      *) absolute="$worktree/$relative" ;;
    esac
    if [ -d "$absolute" ]; then
      printf '%s' "$absolute"
      return 0
    fi
  done
  return 1
}
