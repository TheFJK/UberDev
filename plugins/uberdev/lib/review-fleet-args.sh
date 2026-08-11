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
#
# The first three are run-invariant, so a fresh fence re-deriving them lands on
# the same value. REVIEW_ITERATION is NOT: Phase 3's re-entry fence advances it,
# so a fence that binds it from its own `${REVIEW_ITERATION:-1}` default is
# reading a counter that moved. Get it -- and CI_FIX_LOOP_ITER -- from
# review_fleet_load_ci_counters below, in the same fence that keys on it.

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

# review_fleet_contract_path PLUGIN_ROOT CONTRACT_ID -> absolute path on stdout.
#
# THE BINDING IS DATA, NOT PROSE. policy/solve-run-tree-v1.json declares
# output_contracts[<id>] and attaches it to the six review_pr.review.* edges;
# lib/child-dispatch.sh resolves that same declaration for the ROUTED path and
# appends the file's bytes to the child prompt. The Workflow composer has no
# filesystem, so the controller resolves it HERE and the path travels across the
# args envelope -- the diffPathAbs pattern. Both composers then read ONE
# declaration instead of one reading it and the other re-declaring it as prose,
# which is exactly the drift #403 filed.
#
# Refuses rather than defaults: an unresolvable contract must stop the wave at
# the controller, not produce six children improvising a serialization the
# validator's re.fullmatch can never accept.
#
# `contract_rel` / `contract_abs`, NEVER `path` or `status`: zsh ties both, and
# tests/crossplatform-shell-wrappers.test.sh scans this file for exactly that.
review_fleet_contract_path() {
  [ "$#" -eq 2 ] || {
    echo "error: review_fleet_contract_path: usage: review_fleet_contract_path PLUGIN_ROOT CONTRACT_ID" >&2
    return 2
  }
  local plugin_root="$1" contract_id="$2" manifest contract_rel contract_abs root_real dir_real
  local contract_probe contract_verdict contract_detail
  case "$plugin_root" in
    /*) ;;
    *) echo "error: review_fleet_contract_path: PLUGIN_ROOT must be absolute: '$plugin_root'" >&2; return 2 ;;
  esac
  manifest="$plugin_root/policy/solve-run-tree-v1.json"
  [ -r "$manifest" ] || {
    echo "error: review_fleet_contract_path: unreadable policy manifest $manifest" >&2
    return 2
  }
  # `// empty` rather than `-e`: an absent key must reach the named refusal
  # below, not turn into a jq exit status the caller has to re-interpret.
  contract_rel="$(jq -r --arg id "$contract_id" '.output_contracts[$id] // empty' <"$manifest" 2>/dev/null)" \
    || contract_rel=''
  [ -n "$contract_rel" ] || {
    echo "error: review_fleet_contract_path: no output contract declared for id '$contract_id' in $manifest" >&2
    return 2
  }
  # posixpath.normpath(rel) == rel, expressed as globs: no absolute spelling, no
  # backslash, no empty / '.' / '..' component, no trailing slash. Plus the '"'
  # that skills/review-fleet/workflow.js isSafeAbsPath() also refuses.
  case "$contract_rel" in
    /* | *\\* | *'"'* | . | .. | ./* | ../* | */. | */.. | */./* | */../* | *//* | */)
      echo "error: review_fleet_contract_path: unsafe contract path '$contract_rel' for id '$contract_id'" >&2
      return 2 ;;
  esac
  # A LITERAL newline, never "$(printf '\n')" -- command substitution strips the
  # trailing newline and the pattern would match nothing (the same trap
  # review_fleet_write_ci_pointer documents).
  case "$contract_rel" in
    *'
'*)
      echo "error: review_fleet_contract_path: newline in contract path for id '$contract_id'" >&2
      return 2 ;;
  esac
  contract_abs="$plugin_root/$contract_rel"
  # The value the caller emits is gated downstream by isSafeAbsPath(); refusing
  # here means a bad PLUGIN_ROOT names itself instead of aborting a whole wave
  # under `bad_contract_path` six dispatches later.
  case "$contract_abs" in
    *..* | *'"'*)
      echo "error: review_fleet_contract_path: resolved path '$contract_abs' is not envelope-safe" >&2
      return 2 ;;
  esac
  [ -f "$contract_abs" ] && [ -r "$contract_abs" ] || {
    echo "error: review_fleet_contract_path: '$contract_abs' is not a readable regular file" >&2
    return 2
  }
  [ ! -L "$contract_abs" ] || {
    echo "error: review_fleet_contract_path: '$contract_abs' is a symlink; the contract must be the shipped file" >&2
    return 2
  }
  # beneath(realpath(root), realpath(target)) -- the globs above cannot see a
  # symlinked directory component, and a contract read from outside the plugin
  # root is not the manifest's contract.
  root_real="$(cd "$plugin_root" 2>/dev/null && pwd -P)" || return 2
  dir_real="$(cd "$(dirname "$contract_abs")" 2>/dev/null && pwd -P)" || return 2
  case "$dir_real/" in
    "$root_real"/*) ;;
    *) echo "error: review_fleet_contract_path: '$contract_abs' escapes the plugin root $root_real" >&2; return 2 ;;
  esac
  # THE SAME ACCEPTANCE TEST AS THE ROUTED TRANSPORT, not a looser one.
  #
  # lib/child-dispatch.sh resolves THIS contract id for THE SAME six edges, and
  # its `invalid_output_contract` arm refuses more than `-f`/`-r`/`! -L`: a file
  # not owned by the running euid, one with st_nlink != 1, and one whose size
  # falls outside 1..65536 bytes. Two transports reading one declaration must
  # also agree on what the declaration resolves TO. Without these three, a file
  # the routed path calls `invalid_output_contract` was ACCEPTED here and its
  # path handed to six reviewer subagents told to obey it -- the drift #403
  # filed, one layer down from the path itself.
  #
  # python3, not `stat`: st_uid / st_nlink / st_size have no portable shell
  # spelling (`stat -c` is GNU, `stat -f` is BSD and means --file-system on
  # GNU), and python3 is ALREADY a hard dependency of this file --
  # review_fleet_bind_roster shells every binding out to it. Mirroring the twin
  # in the twin's own language is what keeps the two predicates comparable.
  #
  # os.lstat, never os.stat: a stat that follows a link would read the far end's
  # metadata and answer for a file the `-L` guard above already refused.
  contract_probe="$(python3 -I -B -c '
import os,stat,sys
try:
    entry=os.lstat(sys.argv[1])
except OSError:
    print("unstattable 0");raise SystemExit(0)
reparse=getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0x400)
euid=os.geteuid() if callable(getattr(os,"geteuid",None)) else None
if stat.S_ISLNK(entry.st_mode) or bool(getattr(entry,"st_file_attributes",0)&reparse):
    print("symlink 0")
elif not stat.S_ISREG(entry.st_mode):
    print("not_regular 0")
elif euid is not None and hasattr(entry,"st_uid") and entry.st_uid!=euid:
    print("not_owned %d"%entry.st_uid)
elif entry.st_nlink!=1:
    print("hardlinked %d"%entry.st_nlink)
elif entry.st_size<1 or entry.st_size>65536:
    print("bad_size %d"%entry.st_size)
else:
    print("ok 0")
' "$contract_abs" 2>/dev/null)" || contract_probe='probe_failed 0'
  contract_verdict="${contract_probe%% *}"
  contract_detail="${contract_probe#* }"
  case "$contract_verdict" in
    ok) ;;
    not_owned)
      echo "error: review_fleet_contract_path: '$contract_abs' is owned by uid $contract_detail, not the running user; the contract must be the shipped file" >&2
      return 2 ;;
    hardlinked)
      echo "error: review_fleet_contract_path: '$contract_abs' has $contract_detail hard links; the contract must be the shipped file, not an alias to it" >&2
      return 2 ;;
    bad_size)
      echo "error: review_fleet_contract_path: '$contract_abs' is $contract_detail bytes; the contract must be 1..65536 bytes like the routed resolver requires" >&2
      return 2 ;;
    symlink)
      echo "error: review_fleet_contract_path: '$contract_abs' is a symlink or reparse point; the contract must be the shipped file" >&2
      return 2 ;;
    not_regular)
      echo "error: review_fleet_contract_path: '$contract_abs' is not a regular file" >&2
      return 2 ;;
    *)
      # unstattable / probe_failed / anything unrecognised. Fails CLOSED: a
      # predicate that cannot be evaluated is not a predicate that passed.
      echo "error: review_fleet_contract_path: could not verify '$contract_abs' against the routed resolver's file predicate" >&2
      return 2 ;;
  esac
  printf '%s' "$contract_abs"
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
# controller's own unmerged-path enumeration order — which IS the nonce wire
# format for this stage, exactly as review_fleet_roster's order is for the
# reviewers.
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

# review_fleet_bind_verify RUN_DIR ITER WORKTREE CONTRACT CLAIM_LEDGER LEDGER
#
# The Phase 1 verification fanout (#431). CLAIM_LEDGER carries one
# `<claim_path>` row per eligible finding, in the order
# `project-verification-claims` wrote them — which IS the nonce wire order for
# this stage, exactly as review_fleet_roster's order is for the reviewers.
#
# One claim per child, not one shared claim card: each verifier's pinned input
# names the single finding it adjudicates, and a shared card would make every
# verifier's scope the union of all of them — which is also how the reviewer's
# reasoning would leak back in.
review_fleet_bind_verify() {
  [ "$#" -eq 6 ] || return 2
  local run_dir="$1" iter="$2" worktree="$3" contract="$4"
  local claim_ledger="$5" ledger="$6"
  local edge=review_pr.verify.finding
  local claim_path slug dir instance nonce binding index=0 row
  REVIEW_FLEET_NONCE_POOL=''
  : >"$ledger" || return 2
  while IFS= read -r claim_path; do
    [ -n "$claim_path" ] || continue
    index=$((index + 1))
    slug="$(printf 'verify-%02d' "$index")" || return 2
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
      --arg claim "$claim_path" \
      '{edge:$edge,index:$index,instance:$instance,binding:$binding,result:$result,status:$status,claim:$claim}')" || return 2
    printf '%s\n' "$row" >>"$ledger" || return 2
    if [ -z "$REVIEW_FLEET_NONCE_POOL" ]; then
      REVIEW_FLEET_NONCE_POOL="$nonce"
    else
      REVIEW_FLEET_NONCE_POOL="$REVIEW_FLEET_NONCE_POOL,$nonce"
    fi
  done <"$claim_ledger"
  REVIEW_FLEET_VERIFY_COUNT="$index"
  [ "$index" -gt 0 ] || return 2
}

# The TOTAL number of eligible Phase 1 findings one verification wave will
# adjudicate. Carried across from REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP above for
# the same reason and by the same arithmetic: `verifyCap`'s clamp in
# skills/review-fleet/workflow.js is 50, but the verify roster is dispatched as
# ONE roster whose length goes straight into that script's ceilingGate(), and
# `maxAgents` — 40 at every review-fleet call site in commands/review-pr.md —
# is a SECOND ceiling sitting under the first. So the effective total is the
# LOWER of the two: a set THIS fence accepts is a set the script dispatches,
# and a set above it is handled here, before any Workflow call.
#
# Above the cap the surplus rows are NOT refused and NOT silently dropped: they
# are recorded `SURVIVES` / `over-cap-unverified` in the sidecar. A gate that
# aborted on a large finding set would make a bad review un-reviewable, and one
# that dropped rows would cull without saying so. Asserted behaviourally — at
# the cap and at cap+1, against the maxAgents the call sites actually emit — by
# tests/review-pr-workflow.test.sh.
REVIEW_FLEET_VERIFY_TOTAL_CAP=40

# review_fleet_audit_append RUN_ROOT JSON_LINE
#
# Fail-soft append of one JSON line to the repo-root `.uberdev/audit.jsonl`
# (merge-pipeline/SKILL.md D15 names that path as the audit stream). Modeled on
# _uberdev_config_audit in lib/config-read.sh: write only when the directory
# already exists (creating it would plant an audit trail in a repo that never
# opted into one), warn on failure, and NEVER abort the run — a missing audit
# row must not be able to fail a review that otherwise passed.
review_fleet_audit_append() {
  [ "$#" -eq 2 ] || return 0
  local run_root="$1" line="$2"
  [ -d "$run_root/.uberdev" ] || return 0
  if ! printf '%s\n' "$line" >>"$run_root/.uberdev/audit.jsonl" 2>/dev/null; then
    printf 'warning: could not append to %s/.uberdev/audit.jsonl\n' "$run_root" >&2
  fi
  return 0
}

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

# review_fleet_ci_green_outcome RUN_DIR CI_FIX_PHASE -> `green` | `green_after_fix`
#
# WHICH green this is. `green` and `green_after_fix` are two CI_OUTCOME_ENUM
# members separated by exactly ONE fact -- whether an autopilot rewrote the head
# the CI just passed on -- and that fact does not live in the fence that
# OBSERVES the green. It lives in ci-loop-state.json's `fix_pushes`, written by
# review_fleet_write_ci_push from a different shell entirely.
#
# So every green terminal a fixer can reach calls THIS, and none of them restate
# the decision locally. Two spellings of "which green" IS the defect (#400): the
# member had seven readers and zero producers, so `phases.phase3.outcome`
# serialised a force-pushed autopilot head and a human-pushed one identically,
# and a /merge trust-trail reader could not tell them apart.
review_fleet_ci_green_outcome() {
  [ "$#" -eq 2 ] || return 2
  # `target`, NEVER `path`: zsh TIES the lowercase `path` array to $PATH, so a
  # `local path=` here would replace the command search path for the whole call
  # frame and the `jq` below would be command-not-found. Same rule, same reason
  # as review_fleet_write_ci_state -- and this instance fails on a GREEN CI run,
  # where nothing else is going wrong to prompt a second look.
  local target="$1/ci-loop-state.json" fix_phase="$2" pushes count
  # Probe-only (`--no-ci-fix`, CI_FIX_PHASE=0): 6c.4 ROUTE skips the fixer arms
  # entirely, so by construction no fixer ran and the head under test is the one
  # the author pushed. Answer WITHOUT reading the ledger -- a file some earlier
  # non-probe-only run left behind is not evidence about THIS head.
  case "$fix_phase" in
    0) printf '%s\n' green; return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  # An absent ledger is the FIRST probe of the run, not an error: no fix loop has
  # run yet, so the head is exactly what the author pushed. Same precedent and
  # same reason as review_fleet_load_ci_counters -- and, as there, the ONLY state
  # that gets a fresh-shell default.
  [ -e "$target" ] || { printf '%s\n' green; return 0; }
  # Present-but-broken is NOT "no fixes". A truncated, empty or crashed producer
  # folded to 0 is the recorded `jq length … || echo 0` masking class (#263,
  # #265); HERE it would launder a rewritten head into a clean one -- the exact
  # inverse of the signal this function carries. Fail, and let the caller audit
  # the halt rather than emit a silently-wrong outcome.
  [ -r "$target" ] && [ -s "$target" ] || return 2
  pushes="$(review_fleet_read_ci_state "$target" fix_pushes)" || return 2
  # review_fleet_read_ci_state `tojson`s array fields, so `pushes` is a JSON
  # STRING that must be re-parsed. And its rc is NOT the detector: a
  # `"fix_pushes": 3` ledger comes back rc 0 printing `3`, which an rc check
  # alone waves straight through to `[ 3 -gt 0 ]`. The `type == "array"` /
  # error() pair is what rejects a non-array. `jq -e` alone is not it either --
  # 0 is truthy in jq, so a length of 0 also exits 0.
  count="$(jq -e 'if type == "array" then length else error("fix_pushes is not an array") end' <<<"$pushes")" || return 2
  case "$count" in '' | *[!0-9]*) return 2 ;; esac
  if [ "$count" -gt 0 ]; then printf '%s\n' green_after_fix; else printf '%s\n' green; fi
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

# ---------------------------------------------------------------------------
# The three carriers #418 added, for the four Phase 3 values that were still
# read across a fence boundary they could not cross.
#
# THE CLASS. Every `bash` block in commands/review-pr.md is its own harness
# shell, so a name bound in one fence is GONE in the next. Written
# `${name:-<default>}`, that is not a defensive spelling of the same value: it
# is the default, on every run, forever. #399 moved three such scalars onto
# run-dir carriers; these are the remaining four:
#
#   failure_class / signal_anchor  bound in 6c.3w.2 CLASSIFY, read by 6c.4 ROUTE
#                                  and by the REFUSED arm's aggregate writer
#   check_name                     consumed by that aggregate and bound NOWHERE
#   PROBE_VERDICT                  bound in 6c.1 PROBE, read by ROUTE's
#                                  probe-only (`--no-ci-fix`) arm
#
# WHY EACH ONE VALIDATES ON BOTH SIDES. The issue's rule is that "absent, use
# the documented default" and "this shell cannot tell" are different answers,
# and only the first may reach a routing decision. None of these four HAS a
# documented default -- `unknown` and `unknown:1` are placeholders invented at
# the read site -- so both halves refuse rather than invent: the writer never
# records a value outside its vocabulary, and the reader never returns one.
# A caller that gets rc=2 is being told "cannot tell", which is the only honest
# input to a typed halt.
#
# NOT one combined record: each value is bound in a different fence, and a
# single JSON document would need read-modify-write from three writers running
# minutes apart. Three single-writer files cannot half-update each other.
# ---------------------------------------------------------------------------

# review_fleet_write_ci_probe_verdict PATH VERDICT
# review_fleet_read_ci_probe_verdict  PATH -> the recorded verdict
#
# The four tokens are 6c.1's own jq vocabulary (empty / green / pending / red).
# ROUTE's probe-only arm compares the verdict to `green` to decide between
# OUTCOME=green and OUTCOME=halted, so a reader that accepted anything else
# would answer "not green" for a probe that never ran -- and `--no-ci-fix` would
# report a halt on green CI, which is exactly what it did.
review_fleet_write_ci_probe_verdict() {
  [ "$#" -eq 2 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state: zsh ties the
  # lowercase `path` array to $PATH, and these fences run under /bin/zsh.
  local target="$1" verdict="$2"
  case "$verdict" in
    empty | green | pending | red) ;;
    *) return 2 ;;
  esac
  ( umask 077 && printf '%s\n' "$verdict" >"$target" ) || return 2
}

review_fleet_read_ci_probe_verdict() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI probe verdict missing: ${1:-}" >&2
    return 2
  }
  local recorded
  IFS= read -r recorded <"$1" || return 2
  case "$recorded" in
    empty | green | pending | red) printf '%s' "$recorded" ;;
    *)
      echo "error: review-fleet CI probe verdict is not one of empty/green/pending/red: ${recorded:-<empty>}" >&2
      return 2
      ;;
  esac
}

# review_fleet_write_review_base TARGET BASE_SHA BASE_REF_NAME
# review_fleet_read_review_base  TARGET -> "<base_sha>\t<base_ref_name>"
#
# The identity of the base the review was actually computed against (#440).
# Phase 1 resolves it once -- the merge-base of the PR head and the live
# `baseRefOid`, plus the base ref's NAME -- and every later consumer needs it:
# the Phase 2 scope refresh, the trust-trail anchor's `Reviewed-base:` trailer,
# and the audit JSON's top-level `base` member. Those consumers are 48 and 52
# bash fences downstream of the bind, so the value cannot travel in a variable:
# a fence that merely READS `$BASE_SHA` sees the empty string and every
# `${BASE_SHA:-...}` around it turns "this shell cannot tell" into a confident
# wrong answer. That is exactly how #418 and #419 shipped.
#
# Both halves validate the SAME domain, so neither can launder a value the other
# would refuse: 40 lowercase hex for the SHA, and a non-empty control-character
# free ref name. A TAB or newline inside the ref name is refused rather than
# escaped -- the record is one TAB-separated line, so an embedded TAB would
# split the reader's own columns and an embedded newline would truncate the
# record to its first segment. Both are "the value did not survive", spelled as
# success.
#
# A THIRD field is refused rather than ignored: a reader that silently drops
# trailing columns cannot tell a two-field record from a corrupted one, and this
# record gates a trust signal.
_review_fleet_base_sha_ok() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

_review_fleet_base_ref_ok() {
  [ -n "$1" ] || return 1
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

review_fleet_write_review_base() {
  [ "$#" -eq 3 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state: zsh ties the
  # lowercase `path` array to $PATH, and these fences run under /bin/zsh.
  local target="$1" base_sha="$2" base_ref="$3"
  _review_fleet_base_sha_ok "$base_sha" || return 2
  _review_fleet_base_ref_ok "$base_ref" || return 2
  ( umask 077 && printf '%s\t%s\n' "$base_sha" "$base_ref" >"$target" ) || return 2
}

review_fleet_read_review_base() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet reviewed-base identity missing: ${1:-}" >&2
    return 2
  }
  local recorded base_sha base_ref extra
  IFS= read -r recorded <"$1" || return 2
  base_sha=""; base_ref=""; extra=""
  # Herestring, never an unquoted `<<EOF` heredoc: a heredoc re-expands its body,
  # so a ref name containing `$` -- which git permits -- would be substituted
  # away before the validator ever saw it.
  IFS=$'\t' read -r base_sha base_ref extra <<<"$recorded"
  if ! _review_fleet_base_sha_ok "$base_sha" \
    || ! _review_fleet_base_ref_ok "$base_ref" \
    || [ -n "$extra" ]; then
    echo "error: review-fleet reviewed-base identity is not <40-hex>TAB<ref-name>: ${recorded:-<empty>}" >&2
    return 2
  fi
  printf '%s\t%s' "$base_sha" "$base_ref"
}

# review_fleet_write_ci_check_name PATH NAME
# review_fleet_read_ci_check_name  PATH -> the recorded check name
#
# The NAME of the check that failed, as selected by review_select_failed_ci_run
# from the same row it took the run id from. This is the value the REFUSED arm
# files into a CRITICAL issue so a human knows WHICH check refused; it had no
# producer at all, so that issue always named `unknown`.
#
# A control character is refused rather than escaped: the record is one line and
# the reader takes one line, so an embedded newline would silently truncate the
# name to its first segment, and a TAB would split the selector's own TSV column
# upstream. Both are "the value did not survive", spelled as success.
review_fleet_write_ci_check_name() {
  [ "$#" -eq 2 ] || return 2
  local target="$1" check_name="$2"
  [ -n "$check_name" ] || return 2
  [ "${#check_name}" -le 512 ] || return 2
  case "$check_name" in
    *[[:cntrl:]]*) return 2 ;;
  esac
  ( umask 077 && printf '%s\n' "$check_name" >"$target" ) || return 2
}

review_fleet_read_ci_check_name() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI check name missing: ${1:-}" >&2
    return 2
  }
  local recorded
  IFS= read -r recorded <"$1" || return 2
  [ -n "$recorded" ] || return 2
  case "$recorded" in
    *[[:cntrl:]]*) return 2 ;;
  esac
  printf '%s' "$recorded"
}

# review_fleet_write_ci_classification PATH FAILURE_CLASS SIGNAL_ANCHOR
# review_fleet_read_ci_classification  PATH FIELD -> failure_class | signal_anchor
#
# The classifier's whole routing output, from the fence that VALIDATED it
# (6c.3w.2, via `validate-ci-classification`) to the two fences that consume it.
# Recording it here rather than re-reading the child's result bytes downstream
# keeps one judge: `validate-ci-classification` is the only site allowed to turn
# child bytes into a routing scalar.
#
# THE EMPTY ANCHOR IS LEGAL, and only for the AMBIGUOUS shape: the contract
# reports `failure_class: flaky` with `signal_anchor: ""` so the caller can emit
# ci_classify_ambiguous_routing_as_flaky and re-run once. A writer that demanded
# a non-empty anchor would halt every AMBIGUOUS run -- a new outage on the
# commonest red path, introduced by the fix for the old one. The CLASS is what
# is closed here, and it is closed against the same six-member enum
# code_fixer_contract.py validates.
review_fleet_write_ci_classification() {
  [ "$#" -eq 3 ] || return 2
  local target="$1" failure_class="$2" signal_anchor="$3" payload
  case "$failure_class" in
    code_bug | billing_quota | platform_outage | flaky | env_drift | stale_base) ;;
    *) return 2 ;;
  esac
  case "$signal_anchor" in
    *[[:cntrl:]]*) return 2 ;;
  esac
  payload="$(jq -cn --arg failure_class "$failure_class" \
    --arg signal_anchor "$signal_anchor" \
    '{failure_class:$failure_class,signal_anchor:$signal_anchor}')" || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

review_fleet_read_ci_classification() {
  [ "$#" -eq 2 ] || return 2
  [ -r "$1" ] || {
    echo "error: review-fleet CI classification record missing: $1" >&2
    return 2
  }
  local recorded
  # The membership test is INSIDE jq, not a `-e` truthiness check: `-e` alone
  # reports failure for `null` and `false` but success for a MISSING member of a
  # document that happens to be an object, and a missing member is precisely the
  # "cannot tell" this carrier exists to distinguish. An empty-string member
  # (the AMBIGUOUS anchor) must stay rc 0, which rules out `[ -n ]` here too.
  recorded="$(jq -er --arg field "$2" '
    if type == "object" and has($field) and ((.[$field] | type) == "string")
    then .[$field]
    else error("ci_classification_member_invalid")
    end' <"$1")" || return 2
  case "$recorded" in
    *[[:cntrl:]]*) return 2 ;;
  esac
  printf '%s' "$recorded"
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
# ~25 in this file that carries a `--`, so it reads as a real separator: the
# CONFLICT-arm caller half two of #383 landed (commands/review-pr.md step 1)
# spells it WITHOUT one, but the neighbouring `git add -- "$@"` lines make
# `review_fleet_write_conflict_paths "$list" -- "${conflicted[@]}"` the spelling
# a later caller reaches for, and that spelling must not silently corrupt the
# list. A body that only shifted the target wrote a literal `--` as the FIRST
# NUL entry; the consumer's `read -r -d ''` loop then handed it to
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
  # `case`, not `[ "${1:-}" = -- ] && shift`: with no separator the `&&` is
  # false, so that statement's status is 1. Harmless only because four more
  # statements follow it -- errexit ignores every command of an AND-OR list but
  # the last, and a non-final statement does not set the function's own status.
  # Both of those are positional luck. `case` is 0 either way, so the guard
  # stays correct if it is ever moved to the end of the body.
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

# review_fleet_unmerged_paths WORKTREE CONTRACT TARGET
#
# THE enumerator. review_fleet_write_conflict_paths above is the WRITER of this
# set and review_fleet_bind_ci_conflicts is its BINDER; until #398 there was no
# PRODUCER, so the Step-4 re-bind in commands/review-pr.md inlined its own
# porcelain parse, matching the two exact bytes `UU` against
# code_fixer_contract.py's seven-pair membership test. An add/add rebase
# conflict (porcelain `AA`) was therefore CONFLICT to the judge and the EMPTY
# set to the enumerator: zero resolvers dispatched, "all RESOLVED" vacuously
# true, and the arm aborted a mid-rebase it could have finished.
#
# There is no pair vocabulary here. The answer comes from the ONE definition,
# `_ci_is_unmerged_pair`, through the `list-ci-unmerged-paths` verb -- which
# also carries `_ci_porcelain_entries`' rename/copy-origin skipping and its
# offset-2 space requirement, the two rules that stopped a `UU`-prefixed
# FILENAME from being read as a status pair. A shell re-implementation would
# have to reproduce all three and would be free to drift from any of them. So
# NOTHING in this file parses porcelain itself, deliberately: a whole-file grep
# for a status invocation must stay empty, or a second vocabulary has grown
# back.
#
# A FILE, not a command substitution: `$( … )` cannot carry NUL bytes and strips
# trailing newlines, and a conflicted path may contain a space or a newline.
# `-z` porcelain is unquoted where the plain form C-quotes a spaced path, so the
# transport is byte-identical to review_fleet_write_conflict_paths' and the
# reader is the same `read -r -d ''` loop.
#
# Exit codes are THREE-valued for the same reason review_fleet_rebase_dir's are:
#   0 = >=1 conflicted path, written NUL-delimited to TARGET
#   1 = the probe succeeded and there are no unmerged paths (TARGET, zero bytes)
#   2 = the probe itself failed
# A two-valued probe maps "python3 missing / git unreadable" onto "no conflicts
# to resolve" -- which is exactly the silent-empty collapse this issue is about.
review_fleet_unmerged_paths() {
  [ "$#" -eq 3 ] || return 2
  # `target`, NEVER `path` -- see review_fleet_write_ci_state: zsh ties the
  # lowercase `path` array to $PATH, and these fences run under /bin/zsh.
  local worktree="$1" contract="$2" target="$3"
  [ -d "$worktree" ] && [ -r "$contract" ] || return 2
  ( umask 077 && python3 -I -B "$contract" list-ci-unmerged-paths \
      --working-dir "$worktree" >"$target" ) || return 2
  [ -s "$target" ] || return 1
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
