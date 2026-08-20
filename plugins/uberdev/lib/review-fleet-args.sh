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
#
# "Run-invariant, so a fresh fence re-deriving them lands on the same value" was
# PROSE for two releases and nothing re-derived them (#427): 47 of the file's 60
# bash fences read at least one carrier they never bind. Since #427 the prose is
# a CALLABLE -- review_fleet_rehydrate, at the bottom of this file -- and every
# executed fence opens with it.

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
        general          review_pr.review.general \
        convention       review_pr.review.convention
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

# The upper bound on the rule-source allowlist. A convention reviewer that is
# handed an unbounded file list stops reading rules and starts skimming, and the
# citation gate downstream opens every cited path -- so the list is capped here,
# once, rather than trusted to be small.
UBERDEV_REVIEW_RULE_SOURCE_LIMIT=200

# uberdev_review_rule_sources REPO_ROOT -> the convention lens's rule-source
# ALLOWLIST: repo-relative POSIX paths, one per line, LC_ALL=C sorted, capped.
#
# WHY AN ALLOWLIST AND NOT A HINT. `review_pr.review.convention` is the one lens
# whose claim ("the project says X") is authoritative-sounding and trivially
# hallucinable, so every finding it emits is gated against the exact bytes of
# the file it cites. That gate needs a closed set of files it is willing to
# open; this is that set, and it is discovered ONCE per run by the controller
# and persisted, never re-derived per reader (two derivations can disagree).
#
# `find`, not `git ls-files`: this repo's own root CLAUDE.md is gitignored, and
# a rule document that governs the reviewed change governs it whether or not it
# is tracked.
#
# The prune list is load-bearing, not cosmetic. A checkout with sibling
# worktrees under `.worktrees/` or `.claude/worktrees/` carries a full second
# copy of every AGENTS.md; without the prune a citation could scope itself to
# another branch's rule file and read as verified.
#
# `.claude/worktrees` is pruned BY PATH and `.claude` itself is not: `.claude/`
# is a documented Claude Code location for project rule documents, so pruning
# the whole tree to reach one nested directory drops real conventions from the
# allowlist -- and the lens is told that a rule document not on the list does
# not exist for this review, so it would cull the citation of one as
# `citation-not-in-allowlist`. A repo that keeps its rules there would read as
# a repo that wrote none down.
#
# No bashisms: this file is sourced by command/skill `bash` fences that run
# under /bin/zsh on macOS. `awk`, not `head`, bounds the list -- an early-exiting
# reader on the end of a pipe is the EPIPE class tests/epipe-guard.test.sh
# exists to keep out.
uberdev_review_rule_sources() {
  [ "$#" -eq 1 ] || {
    echo "error: uberdev_review_rule_sources: usage: uberdev_review_rule_sources REPO_ROOT" >&2
    return 2
  }
  local rule_root rule_hit rule_raw rule_rc
  rule_root="$(cd "$1" 2>/dev/null && pwd -P)" || {
    echo "error: uberdev_review_rule_sources: unreadable repository root: $1" >&2
    return 2
  }
  # find's stderr is NOT discarded and its status IS inspected. An empty
  # allowlist is a legitimate answer -- it means the repo wrote no conventions
  # down -- but a BROKEN walk produces the byte-identical answer, and the
  # difference is the whole lens: one is "nothing to enforce", the other is a
  # review that silently enforced nothing. Errored AND empty is refused by name;
  # errored but partial still reports what it read, with the errors on the
  # operator's terminal.
  rule_raw="$(find "$rule_root" \
      -maxdepth 4 \
      \( -name .git -o -name .worktrees -o -path '*/.claude/worktrees' \
         -o -name node_modules -o -name vendor -o -name dist -o -name build \) -prune -o \
      -type f \
      \( -name AGENTS.md -o -name CLAUDE.md -o -name .editorconfig \
         -o -name '.eslintrc*' -o -name 'eslint.config.*' -o -name '.prettierrc*' \
         -o -name ruff.toml -o -name .ruff.toml -o -name pyproject.toml \
         -o -name setup.cfg -o -name '.markdownlint*' -o -name .shellcheckrc \
         -o -name '.commitlintrc*' \) -print)"
  rule_rc=$?
  if [ "$rule_rc" -ne 0 ] && [ -z "$rule_raw" ]; then
    echo "error: uberdev_review_rule_sources: discovery under $rule_root failed (find rc=$rule_rc) and found nothing; refusing to report that as 'this repository has no written conventions'" >&2
    return 2
  fi
  printf '%s\n' "$rule_raw" \
    | while IFS= read -r rule_hit; do
        case "$rule_hit" in
          "$rule_root"/*) printf '%s\n' "${rule_hit#"$rule_root"/}" ;;
        esac
      done \
    | LC_ALL=C sort \
    | awk -v limit="$UBERDEV_REVIEW_RULE_SOURCE_LIMIT" 'NR<=limit'
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
# output_contracts[<id>] and attaches it to the seven review_pr.review.* edges;
# lib/child-dispatch.sh resolves that same declaration for the ROUTED path and
# appends the file's bytes to the child prompt. The Workflow composer has no
# filesystem, so the controller resolves it HERE and the path travels across the
# args envelope -- the diffPathAbs pattern. Both composers then read ONE
# declaration instead of one reading it and the other re-declaring it as prose,
# which is exactly the drift #403 filed.
#
# Refuses rather than defaults: an unresolvable contract must stop the wave at
# the controller, not produce a whole wave of children improvising a
# serialization the validator's re.fullmatch can never accept.
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
  # here means a bad PLUGIN_ROOT names itself instead of aborting under
  # `bad_contract_path` only once the full reviewer roster has already been
  # dispatched.
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
  # lib/child-dispatch.sh resolves THIS contract id for THE SAME
  # `review_pr.review.*` edges, and its `invalid_output_contract` arm refuses
  # more than `-f`/`-r`/`! -L`: a file not owned by the running euid, one with
  # st_nlink != 1, and one whose size falls outside 1..65536 bytes. Two
  # transports reading one declaration must also agree on what the declaration
  # resolves TO. Without these three, a file the routed path calls
  # `invalid_output_contract` was ACCEPTED here and its path handed to seven
  # reviewer subagents told to obey it -- the drift #403 filed, one layer down
  # from the path itself.
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

# review_fleet_write_verify_dispatch TARGET 0|1
# review_fleet_read_verify_dispatch  TARGET -> `0` | `1`
#
# Did the Phase 1 verification gate dispatch a verifier wave, or did one of its
# two no-dispatch short-circuits already publish the sidecar? That answer is
# produced in the fence that projects the claims and consumed by the fence that
# republishes the sidecar afterwards -- a different process, where the scalar it
# used to live in is gone (#427). Every other decision those fences hand
# forward is already on disk for exactly this reason: ci-loop-state.json,
# rule-sources.txt, changed-paths.json.
#
# Keyed per iteration by the caller, because the decision is per iteration: a
# Phase 3 CI-fix loop re-enters Phase 1, and iteration 1's answer must not be
# able to speak for iteration 2.
#
# The domain is CLOSED to `0`/`1` on both sides, so neither half can record or
# return a value the other would refuse; an absent or malformed record is rc 2
# and NOT a default, because "the gate cannot say what it did" and "the gate
# dispatched nothing" are different answers and only one of them means the
# sidecar is already published.
review_fleet_write_verify_dispatch() {
  [ "$#" -eq 2 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state: zsh ties the
  # lowercase `path` array to $PATH, and these fences run under /bin/zsh.
  local target="$1" dispatched="$2"
  case "$dispatched" in
    0 | 1) ;;
    *) return 2 ;;
  esac
  ( umask 077 && printf '%s\n' "$dispatched" >"$target" ) || return 2
}

review_fleet_read_verify_dispatch() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet verification dispatch decision missing: ${1:-}" >&2
    return 2
  }
  local recorded
  IFS= read -r recorded <"$1" || return 2
  case "$recorded" in
    0 | 1) ;;
    *)
      echo "error: review-fleet verification dispatch decision is not 0 or 1: ${recorded:-<empty>}" >&2
      return 2
      ;;
  esac
  printf '%s' "$recorded"
}

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

# review_fleet_write_ci_route TARGET EDGE_ID SLUG_BASE RUN_ID HEAD_SHA \
#                             BASE_SHA BASE_TIP_SHA BASE_BRANCH PR_BRANCH LEASE_SHA
# review_fleet_read_ci_route  PATH FIELD
#
# Phase 3 ROUTE's decision, made durable for the fence that acts on it.
#
# Same defect as the loop counters above, one step further along. ROUTE (the
# "Phase 3 ROUTE" fence) selects the failing check and computes the fixer edge,
# the lease SHA, the base identity and the branch pair; the fence that DISPATCHES
# that fixer is a different harness shell and read all nine back as the empty
# string. Its own comment says they are "re-checked by prepare-ci-authority
# below", but prepare-ci-authority RECEIVES them as argv -- it cannot re-derive
# what it was handed empty, so the receipt was minted over blanks.
#
# Field-addressed like review_fleet_read_ci_state rather than a positional TSV:
# nine columns is where a positional record stops being readable, and a consumer
# that wants one field should not have to know the order of the other eight.
#
# jq -er makes a missing or null field a non-zero exit, so a truncated record is
# a refusal at the reader instead of an empty string in an authority receipt.
review_fleet_write_ci_route() {
  [ "$#" -eq 10 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" edge_id="$2" slug_base="$3" ci_run_id="$4" head_sha="$5" \
        base_sha="$6" base_tip_sha="$7" base_branch="$8" pr_branch="$9" lease_sha="${10}" payload
  # Every member is required. An empty one here is the defect this record
  # exists to end, so it must not be writable in the first place.
  for _review_ci_route_member in "$edge_id" "$slug_base" "$ci_run_id" "$head_sha" \
      "$base_sha" "$base_tip_sha" "$base_branch" "$pr_branch" "$lease_sha"; do
    [ -n "$_review_ci_route_member" ] || {
      unset _review_ci_route_member 2>/dev/null || true
      return 2
    }
  done
  unset _review_ci_route_member 2>/dev/null || true
  payload="$(jq -cn \
    --arg edge_id "$edge_id" --arg slug_base "$slug_base" --arg ci_run_id "$ci_run_id" \
    --arg head_sha "$head_sha" --arg base_sha "$base_sha" --arg base_tip_sha "$base_tip_sha" \
    --arg base_branch "$base_branch" --arg pr_branch "$pr_branch" --arg lease_sha "$lease_sha" \
    '{edge_id:$edge_id,slug_base:$slug_base,ci_run_id:$ci_run_id,head_sha:$head_sha,base_sha:$base_sha,base_tip_sha:$base_tip_sha,base_branch:$base_branch,pr_branch:$pr_branch,lease_sha:$lease_sha}')" || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

review_fleet_read_ci_route() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI route decision missing: ${1:-}" >&2
    return 2
  }
  jq -er --arg field "$2" '.[$field] | select(. != null and . != "")' <"$1" || {
    echo "error: review-fleet CI route decision has no usable '${2:-}': ${1}" >&2
    return 2
  }
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

# review_fleet_write_reviewed_head TARGET SHA
# review_fleet_read_reviewed_head  PATH -> "<40-hex>"
#
# The head the review currently stands on, updated as fixers commit.
#
# `REVIEWED_HEAD_SHA` and `VALIDATED_FIXER_HEAD_SHA` are the same fact at
# different moments: the head Phase 1 reviewed, then that head advanced by each
# validated fixer commit. Both lived only in shell variables, and both are read
# by fences that are separate processes -- the post-fixer publication gate and
# the two trust fences.
#
# THIS ONE CANNOT BE RE-DERIVED, and the distinction matters more here than
# anywhere else in this file. `git rev-parse HEAD` at the consuming fence would
# always agree with itself, which is precisely the comparison the anti-race gate
# exists to fail: its whole job is to notice that HEAD moved since the review.
# Recomputing it does not restore the check, it deletes it while leaving the
# code that looks like a check in place. So the value is written down at each
# point it legitimately changes, and read back -- never recomputed.
#
# Absent is therefore distinguishable from changed, which the callers rely on to
# stop reporting "HEAD changed outside the validated review fixers" at a run
# whose head never moved and whose record simply had not travelled.
#
# TWO WRITERS, and the pair is deliberate (#479). The SEED is written by the
# Phase 1 scope fence, at the one moment the reviewed head is established from
# the live PR; the ADVANCE is written by review_track_validated_fixer_head, at
# the one point a validated fixer commit legitimately moves it. Only the second
# existed at first, so a FIRST Phase 1 entry -- the common case -- reached the
# promote fence with nothing to recover, and `[ "$before" =
# "${VALIDATED_FIXER_HEAD_SHA:-}" ]` compared a real head against the empty
# string and returned 76 (MUTATED_BLOCKED) on a fixer that had done everything
# right. A seed that is not written down is not a seed: the fence that binds it
# is dead by the time anything reads it.
# review_fleet_write_ci_probe_json TARGET JSON
# review_fleet_read_ci_probe_json  PATH -> the recorded probe payload
#
# The `gh pr checks` payload PROBE selected from, kept for the fences that read
# it back.
#
# The VERDICT distilled from this payload already had a record
# (ci-probe-verdict.txt, added for #418 when `${PROBE_VERDICT:-unknown}` answered
# "unknown" on every probe-only run). The payload it was distilled FROM did not,
# and two later fences still need it: the settle/re-probe arm, and CLASSIFY,
# which passes it to review_select_failed_ci_run to choose the failing check.
# With it empty the selector had no rows to choose from and the run halted
# `classification_run_selection_invalid` -- a message about a malformed
# selection, on a probe that was never handed anything to select.
#
# Re-running `gh pr checks` at the consuming fence is NOT a fix: checks move.
# The selection has to be made from the same bytes the verdict was distilled
# from, or the verdict and the chosen check can disagree about what CI said.
review_fleet_write_ci_probe_json() {
  [ "$#" -eq 2 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" payload="$2"
  [ -n "$payload" ] || return 2
  printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  ( umask 077 && printf '%s\n' "$payload" >"$target" ) || return 2
}

review_fleet_read_ci_probe_json() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet CI probe payload missing: ${1:-}" >&2
    return 2
  }
  jq -e 'type == "array"' <"$1" >/dev/null 2>&1 || {
    echo "error: review-fleet CI probe payload is not a checks array: ${1}" >&2
    return 2
  }
  cat -- "$1"
}

review_fleet_write_reviewed_head() {
  [ "$#" -eq 2 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" sha="$2"
  case "$sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) return 2 ;;
  esac
  [ "${#sha}" -eq 40 ] || return 2
  case "$sha" in *[!0-9a-f]*) return 2 ;; esac
  ( umask 077 && printf '%s\n' "$sha" >"$target" ) || return 2
}

# review_fleet_write_published_head TARGET SHA
# review_fleet_read_published_head  PATH -> "<40-hex>"
#
# The head that is ON THE REMOTE -- a different fact from the head the review
# stands on, and deliberately a different symbol so neither writer can be
# mistaken for the other by a reader or by the scope-fence scanner that counts
# them. Same validation as the reviewed-head pair; only the noun differs.
#
# ONE WRITER OF RECORD FOR EACH EVENT: the Phase 1 scope fence seeds this from
# the live PR head, and Step 6a advances it only after
# review_publish_same_repo_pr_head has proven a push landed. A fixer commit
# advances the REVIEWED head and must never touch this one.
review_fleet_write_published_head() {
  [ "$#" -eq 2 ] || return 2
  review_fleet_write_reviewed_head "$1" "$2"
}

review_fleet_read_published_head() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet published head missing: ${1:-}" >&2
    return 2
  }
  review_fleet_read_reviewed_head "$1"
}

review_fleet_read_reviewed_head() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet reviewed head missing: ${1:-}" >&2
    return 2
  }
  local recorded=""
  # NOT `|| return 2`. `read` reports failure for BOTH a zero-byte file and a
  # final line with no trailing newline, and returning on its status made those
  # two -- the exact corruption modes the published-head refusal branch names --
  # the only ones that failed in COMPLETE SILENCE, while a full line that merely
  # failed the 40-hex check got a diagnostic. Judge the CONTENT instead: an
  # unterminated "abc" still lands in `recorded` and falls through to the
  # shape check below, which names it.
  IFS= read -r recorded <"$1" || :
  [ -n "$recorded" ] || {
    echo "error: review-fleet reviewed head is empty or holds no readable line: $1" >&2
    return 2
  }
  [ "${#recorded}" -eq 40 ] || {
    echo "error: review-fleet reviewed head is not a 40-hex SHA: ${recorded:-<empty>}" >&2
    return 2
  }
  case "$recorded" in
    *[!0-9a-f]*)
      echo "error: review-fleet reviewed head is not a 40-hex SHA: $recorded" >&2
      return 2
      ;;
  esac
  printf '%s' "$recorded"
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

# review_fleet_write_trust_state PATH STATE CRITICAL_COUNT
# review_fleet_read_trust_state  PATH -> "<STATE>TAB<critical count>"
#
# The trust verdict, made durable at the ONE fence that computes it.
#
# `TRUST_TRAIL_STATE` was assigned in the state-assignment fence and then read by
# three LATER fences -- the trailer-suffix case, the label-selection case, and
# the label-apply case -- each a separate harness process. It expanded empty in
# all three, and the failures were not symmetrical:
#
#   * the label fences ran `gh label create --force "" --color ""` and exited 2
#     blaming `gh` auth, which is a loud lie but at least a stop;
#   * the trailer-suffix `case` matched NO arm, so TRAILER_SUFFIX was never
#     assigned at all -- not set to the empty string, unset. The anchor message
#     then interpolated it as "" under zsh with no error, and a YELLOW run
#     emitted a byte-identical GREEN-shaped `Reviewed-by:` trailer. That one
#     fails silently and ships a WRONG artifact, which is worse than the stop.
#
# So the state travels, and the two values DERIVED from it -- the trailer suffix
# and the label triple -- are recomputed by each consumer from the state it just
# read, rather than making three more scalars cross the same gap. The critical
# count rides along because the YELLOW suffix embeds it and it is meaningless
# apart from the state it qualifies.
#
# RED is a legal recorded value even though RED emits no anchor and no label:
# the consumers must be able to tell "the run was RED" from "the carrier was
# never written", and only an explicit record does that.

# review_fleet_write_phase2_5_outcome TARGET STATUS HALTED BLOCKER CRITICAL
# review_fleet_read_phase2_5_outcome  PATH -> "<STATUS>TAB<halted>TAB<blocker>TAB<critical>"
#
# The INPUTS to the trust verdict, made durable at the fence that learns them.
#
# review_fleet_write_trust_state above makes the trust verdict durable. That is
# the OUTPUT. Its inputs were still crossing the same gap the wrong way: Phase
# 2.5's counts are captured by the CONTROLLER out of the findings-to-issues
# child's return YAML (see commands/review-pr.md, "Capture the return YAML into
# shell variables"), and the verdict fence that consumes them is a different
# process. Nothing in the file wrote them down.
#
# The failure is not symmetric, and that asymmetry is why it survived:
#
#   * lose EVERYTHING and the predicate fails closed. `PHASE1_VERDICT` empty
#     never equals APPROVE, so `would_be_green_without_phase2_5` stays false and
#     the run goes RED. Safe, and the case anyone would test.
#   * lose ONLY the Phase 2.5 counts -- exactly what happens when the controller
#     re-emits the three phase verdicts it holds in its own context but not the
#     counts that came back inside a child's YAML -- and `${BY_SEVERITY_BLOCKER:-0}`
#     reads 0, `${PHASE2_5_HALTED:-false}` reads false, and a run that filed
#     BLOCKER issues emits GREEN. Measured: APPROVE + ran/APPROVE + green with
#     three blockers carried is NOT-GREEN; the same run with the carry lost is
#     GREEN.
#
# GREEN is the `uberdev-approved` label and the `Reviewed-by:` trailer that
# /merge Phase 1.4 accepts as authorisation to land. A defaulted absence must
# therefore never be readable as "clean" -- so every one of these defaults is
# gone from the predicate and its absence is a refusal instead.
#
# `skipped` is a first-class recorded STATUS, not an absent file, for the same
# reason RED is a legal trust state above: a run that never dispatched Phase 2.5
# (--no-defer-issues) and a run whose record was lost must not look alike.
review_fleet_write_phase2_5_outcome() {
  [ "$#" -eq 5 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" recorded_status="$2" halted="$3" blocker="$4" critical="$5"
  case "$recorded_status" in
    ran | skipped | blocked) ;;
    *) return 2 ;;
  esac
  case "$halted" in true | false) ;; *) return 2 ;; esac
  case "$blocker" in '' | *[!0-9]*) return 2 ;; esac
  case "$critical" in '' | *[!0-9]*) return 2 ;; esac
  ( umask 077 && printf '%s\t%s\t%s\t%s\n' \
      "$recorded_status" "$halted" "$blocker" "$critical" >"$target" ) || return 2
}

review_fleet_read_phase2_5_outcome() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet phase 2.5 outcome missing: ${1:-}" >&2
    return 2
  }
  local recorded recorded_status halted blocker critical extra
  IFS= read -r recorded <"$1" || return 2
  recorded_status=""; halted=""; blocker=""; critical=""; extra=""
  # Herestring, never an unquoted heredoc -- same reason as
  # review_fleet_read_review_base above.
  IFS=$'\t' read -r recorded_status halted blocker critical extra <<<"$recorded"
  case "$recorded_status" in ran | skipped | blocked) ;; *) recorded_status='' ;; esac
  case "$halted" in true | false) ;; *) recorded_status='' ;; esac
  case "$blocker" in '' | *[!0-9]*) recorded_status='' ;; esac
  case "$critical" in '' | *[!0-9]*) recorded_status='' ;; esac
  if [ -z "$recorded_status" ] || [ -n "$extra" ]; then
    echo "error: review-fleet phase 2.5 outcome is not <ran|skipped|blocked>TAB<true|false>TAB<blocker>TAB<critical>: ${recorded:-<empty>}" >&2
    return 2
  fi
  printf '%s\t%s\t%s\t%s' "$recorded_status" "$halted" "$blocker" "$critical"
}

review_fleet_write_trust_state() {
  [ "$#" -eq 3 ] || return 2
  # `target`, never `path` -- see review_fleet_write_ci_state.
  local target="$1" state="$2" critical="$3"
  case "$state" in
    GREEN | YELLOW | RED) ;;
    *) return 2 ;;
  esac
  case "$critical" in '' | *[!0-9]*) return 2 ;; esac
  ( umask 077 && printf '%s\t%s\n' "$state" "$critical" >"$target" ) || return 2
}

review_fleet_read_trust_state() {
  [ -r "${1:-}" ] || {
    echo "error: review-fleet trust state missing: ${1:-}" >&2
    return 2
  }
  local recorded state critical extra
  IFS= read -r recorded <"$1" || return 2
  state=""; critical=""; extra=""
  # Herestring, never an unquoted heredoc -- same reason as
  # review_fleet_read_review_base above.
  IFS=$'\t' read -r state critical extra <<<"$recorded"
  case "$state" in
    GREEN | YELLOW | RED) ;;
    *) state='' ;;
  esac
  case "$critical" in '' | *[!0-9]*) state='' ;; esac
  if [ -z "$state" ] || [ -n "$extra" ]; then
    echo "error: review-fleet trust state is not <GREEN|YELLOW|RED>TAB<critical count>: ${recorded:-<empty>}" >&2
    return 2
  fi
  printf '%s\t%s' "$state" "$critical"
}

# review_fleet_trailer_suffix STATE CRITICAL -> the `Reviewed-by:` suffix.
#
# GREEN adds nothing; YELLOW appends the deferred-critical count that /merge
# reads to decide whether --accept-critical-deferred is required. Defined ONCE,
# here, because two fences need it (the trailer-suffix step and the anchor
# message that interpolates it) and the second one previously trusted the first
# one's shell variable to survive a process boundary. Deriving it twice from the
# same durable state is safe; carrying it once was not.
#
# RED returns rc 1 with no output: RED emits no anchor at all, so asking for its
# trailer is a caller bug, and answering "" would let a RED run build a
# GREEN-shaped message.
review_fleet_trailer_suffix() {
  [ "$#" -eq 2 ] || return 2
  case "$2" in '' | *[!0-9]*) return 2 ;; esac
  case "$1" in
    GREEN) printf '' ;;
    YELLOW) printf ' severity=critical-deferred count=%s' "$2" ;;
    RED) return 1 ;;
    *) return 2 ;;
  esac
}

# review_fleet_trust_label STATE -> "<name>TAB<color>TAB<description>"
#
# The label triple, single-sourced for the same reason as the suffix above: the
# fence that selected it and the fence that applied it were different processes,
# so the apply fence ran `gh label create --force "" --color "" --description ""`
# and reported a permissions problem.
#
# Descriptions stay under GitHub's 100-character ceiling -- `gh label create`
# 422s above it, on update as well as create, and that limit has already broken
# three labels in this repo.
review_fleet_trust_label() {
  [ "$#" -eq 1 ] || return 2
  case "$1" in
    GREEN)
      printf '%s\t%s\t%s' uberdev-approved 0E8A16 \
        'Trust trail: /review-pr verified GREEN. Set by /review-pr, read by /merge.'
      ;;
    YELLOW)
      printf '%s\t%s\t%s' uberdev-approved-with-concerns FBCA04 \
        'Trust trail: /review-pr YELLOW: deferred CRITICAL; /merge needs --accept-critical-deferred.'
      ;;
    RED) return 1 ;;
    *) return 2 ;;
  esac
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

# ---------------------------------------------------------------------------
# THE FRESH-SHELL ENTRY CONTRACT (#427)
# ---------------------------------------------------------------------------
#
# Every `bash` block in commands/review-pr.md is a FRESH SHELL, and 47 of the
# file's 60 blocks read at least one of UBERDEV_REVIEW_PLUGIN_ROOT /
# CODE_FIXER_CONTRACT / WORKTREE_ROOT / RUN_ID / MARKER_DIR / RESEARCH_DIR_ABS /
# the seven artifact paths without ever binding them. Only the setup fence
# binds them, and it exits before the next fence starts.
#
# The failure is SILENT, not loud: `set -u` is in force in the setup fence only,
# so in every other fence an unbound carrier expands to the EMPTY STRING. An
# empty RESEARCH_DIR_ABS resolves the CI ledger under a path that does not
# exist, and "does not exist" is the answer `green` -- a review that never ran
# reports a clean CI probe. That is the hazard commands/review-pr.md names in
# its own prose and never closed.
#
# review_fleet_rehydrate closes it. It is the FIRST call of every executed
# review-pr fence, and it re-derives the run-invariant half from the filesystem
# rather than from a dead shell:
#
#   plugin root   <- UBERDEV_REVIEW_PLUGIN_ROOT / PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT
#                    / CURSOR_PLUGIN_ROOT, the same chain the setup fence uses
#   repo root     <- `git rev-parse --show-toplevel`
#   run identity  <- $RUN_ID when the orchestrator carried it (always the first
#                    choice), else the guarded active-run pointer below
#   everything    <- the run's own command-workspace.json descriptor, so
#   else             lib/command-workspace.py stays the SINGLE implementation of
#                    the artifact path algebra. Nothing here templates
#                    "<run>/pr-diff.md"; a second copy of that table is exactly
#                    the #370 "one contract, N uncompared copies" class.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * it never reserves, prepares or mutates a run -- rehydration is read-only,
#     so a fence that runs twice cannot mint a second reservation;
#   * it never binds REVIEW_ITERATION or CI_FIX_LOOP_ITER. Those are counters,
#     not run invariants; they move mid-run and belong to
#     review_fleet_load_ci_counters, which the fence calls right after;
#   * it never reads REVIEW_RUN_RESERVATION_RECEIPT off disk, and no sidecar
#     ever holds one. The receipt is the capability token that authorises
#     retiring the run markers, and what it actually asserts is that the runs
#     root, the run directory and both markers still have the SAME
#     (st_dev, st_ino) and sha256 they had at reservation. A copy stored inside
#     the run directory would be swapped along with the directory it is meant to
#     vouch for, so the token would faithfully certify the attacker's tree. That
#     is the downgrade this refuses, and it is the whole of the refusal.
#
#     It is NOT a claim that the receipt needs no channel. It has exactly one:
#     the setup fence prints it on the `REVIEW_CARRY` line beside RUN_ID, and
#     commands/review-pr.md requires the orchestrator to carry both onto every
#     later fence. That channel lives OUTSIDE the tree the token guards, which
#     is precisely what a sidecar cannot do. Disclosure on it costs nothing --
#     redemption re-stats the live filesystem, so a carried receipt can only ever
#     authorise the one directory it already described.
#
#     An earlier version of this comment ended "its only consumer is the terminal
#     verdict fence, which already carries it explicitly." Nothing carried it.
#     The receipt was minted in the setup fence and read nine Workflow relays
#     later, so the terminal fence got the empty string and every real run died
#     on `review_reservation_receipt_invalid` after the full reviewer fleet had
#     already been spent. A true premise (do not persist it) reached a false
#     conclusion (therefore nothing more is owed).
#
#     Integrity of a RECOVERED run -- one whose RUN_ID came from the pointer
#     rather than the carry line -- is established by the pointer guards. Those
#     guards do not mint a receipt and are not a substitute for one; a run that
#     lost the receipt cannot publish its verdict and must be re-run.

# review_fleet_active_run_pointer_path TOPLEVEL -> the active-run pointer path.
#
# ONE definition, shared by the writer (the setup fence, via
# review_fleet_write_active_run_pointer) and the reader (review_fleet_rehydrate).
#
# It lives INSIDE .uberdev/runs/ and not next to it. `/review-pr` exists to run
# against repositories that do not ignore `.uberdev/`, so setup publishes
# `<runs_root>/.gitignore` containing `*`; a pointer one level up is outside
# that ignore and becomes untracked residue in the reviewed working tree, which
# the reservation's own cleanliness guard then fails. It is invisible to
# review_reap_stale_run_reservations by construction: that loop skips every
# entry whose name is not a full RUN_ID match.
review_fleet_active_run_pointer_path() {
  [ "$#" -eq 1 ] || return 2
  [ -n "$1" ] || return 2
  printf '%s' "$1/.uberdev/runs/.review-active-run.json"
}

# _review_fleet_run_id_ok VALUE -> 0 when VALUE is a well-formed RUN_ID.
#
# Deliberately `case` globs and not a regex: `[[ =~ ]]` populates BASH_REMATCH
# in bash and `$match` in zsh, and these fences run under /bin/zsh. The shape is
# the same one lib/command-workspace.py and the reservation triple-guard pin:
# YYYYMMDD-HHMMSS-<lowercase hex>. It is also the path-traversal guard -- no
# `..`, no `/`, no separator of any kind can satisfy it.
_review_fleet_run_id_ok() {
  local value="${1:-}" suffix
  case "$value" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*) ;;
    *) return 1 ;;
  esac
  suffix="${value#*-}"
  suffix="${suffix#*-}"
  [ -n "$suffix" ] || return 1
  case "$suffix" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

# review_fleet_write_active_run_pointer TOPLEVEL RUN_ID PR HEAD_SHA
#
# Called once, by the setup fence, after the reservation and the backend
# preflight have both succeeded -- so a setup that abandons its reservation
# never leaves a pointer behind.
#
# NOT secure_publish_exact_no_clobber: that publisher is no-clobber by design,
# and this pointer must be REWRITTEN once per run. umask 077 + a pid-unique temp
# + `mv -f` gives the same "a reader never sees a half-written file" property
# for a file that is legitimately replaced.
review_fleet_write_active_run_pointer() {
  [ "$#" -eq 4 ] || return 2
  local toplevel="$1" run_id="$2" pr="$3" head_sha="$4" pointer staging payload
  _review_fleet_run_id_ok "$run_id" || {
    echo "error: review-pr active-run pointer refused a malformed RUN_ID: $run_id" >&2
    return 2
  }
  case "$pr" in
    '' | *[!0-9]*)
      echo "error: review-pr active-run pointer refused a non-numeric PR: $pr" >&2
      return 2
      ;;
  esac
  pointer="$(review_fleet_active_run_pointer_path "$toplevel")" || return 2
  payload="$(python3 -I -B -c 'import json,sys,time; print(json.dumps({"schema_version":1,"run_id":sys.argv[1],"pr":int(sys.argv[2]),"head_sha":sys.argv[3],"started_at":int(time.time())},sort_keys=True,separators=(",",":")),end="")' "$run_id" "$pr" "$head_sha")" || return 2
  staging="$pointer.tmp.$$"
  ( umask 077 && printf '%s\n' "$payload" >"$staging" ) || return 2
  mv -f "$staging" "$pointer" || {
    rm -f "$staging" 2>/dev/null || true
    return 2
  }
}

# _review_fleet_pointer_run_id TOPLEVEL EXPECTED_PR REAP_SECS -> RUN_ID
#
# The recovery path, and the ONLY place a run identity is inferred rather than
# carried. Five guards, each with its own message, and never a fallback to a
# different run: the answer is this run or rc 2.
_review_fleet_pointer_run_id() {
  [ "$#" -eq 3 ] || return 2
  local toplevel="$1" expected_pr="$2" reap_secs="$3" pointer
  pointer="$(review_fleet_active_run_pointer_path "$toplevel")" || return 2
  python3 -I -B - "$pointer" "$toplevel/.uberdev/runs" "$expected_pr" "$reap_secs" <<'PY'
import json
import os
import re
import sys
import time

pointer, runs_root, expected_pr, reap_text = sys.argv[1:]
RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")


def refuse(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(2)


if not os.path.isfile(pointer):
    refuse(
        "review-pr fence entered without RUN_ID and no recoverable active-run "
        "pointer at " + pointer
    )
try:
    with open(pointer, "r", encoding="utf-8") as handle:
        record = json.loads(handle.read(65536))
except Exception as error:
    refuse("review-pr active-run pointer is unreadable or malformed: %s: %s" % (pointer, error))
if not isinstance(record, dict) or record.get("schema_version") != 1:
    refuse("review-pr active-run pointer carries an unknown schema: " + pointer)
run_id = record.get("run_id")
if not isinstance(run_id, str) or RUN_ID.fullmatch(run_id) is None:
    refuse("review-pr active-run pointer carries a malformed run_id: " + pointer)
run_dir = os.path.join(runs_root, run_id)
if not os.path.isdir(run_dir):
    refuse("review-pr active-run pointer names a run directory that is gone: " + run_dir)
for marker in ("locked", "pr-context.json"):
    if not os.path.isfile(os.path.join(run_dir, marker)):
        refuse(
            "review-pr active-run pointer names a run whose '%s' reservation marker is "
            "gone (abandoned or reaped): %s" % (marker, run_dir)
        )
if os.path.exists(os.path.join(run_dir, "review-pr-verdict.json")):
    refuse("review-pr active-run pointer names a run that already published its verdict: " + run_dir)
recorded_pr = record.get("pr")
if expected_pr:
    try:
        wanted = int(expected_pr)
    except (TypeError, ValueError):
        refuse("review-pr fence supplied a non-numeric PR_NUMBER: " + str(expected_pr))
    if recorded_pr != wanted:
        refuse(
            "review-pr active-run pointer is for PR #%s but this fence is reviewing PR #%s"
            % (recorded_pr, wanted)
        )
started_at = record.get("started_at")
if type(started_at) is not int or isinstance(started_at, bool):
    refuse("review-pr active-run pointer carries a malformed started_at: " + pointer)
try:
    reap_secs = int(reap_text)
except (TypeError, ValueError):
    reap_secs = 7200
age = int(time.time()) - started_at
if age > reap_secs:
    refuse(
        "review-pr active-run pointer is %ss old, past the %ss reservation policy: %s"
        % (age, reap_secs, pointer)
    )
print(run_id, end="")
PY
}

# _review_fleet_run_dir_pr RUN_DIR -> the PR number the reservation recorded.
#
# `pr-context.json` is written by review_reserve_run_directory in the setup
# fence and is one of the two markers the pointer guard above already requires,
# so it is the run's OWN record of which PR is under review -- and the only
# on-disk one that is present whether the fence carried a RUN_ID or recovered
# through the pointer.
#
# rc 1 with no output when the marker is absent or carries no positive integer.
# This is a recovery source, not a guard: rehydration must not start failing for
# runs whose marker predates this reader, so the fences that actually put the
# number in a prompt or an audit row refuse for themselves.
_review_fleet_run_dir_pr() {
  [ "$#" -eq 1 ] || return 1
  [ -n "$1" ] || return 1
  python3 -I -B -c 'import json,sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        record = json.loads(handle.read(65536))
except (OSError, ValueError):
    raise SystemExit(1)
pr = record.get("pr") if isinstance(record, dict) else None
if type(pr) is not int or pr <= 0:
    raise SystemExit(1)
print(pr, end="")' "$1/pr-context.json" 2>/dev/null
}

# _review_fleet_bind_pr RUN_DIR -- fill an EMPTY PR_NUMBER from that marker.
#
# Never overrides a carried value: a fence that already knows its PR is the run
# talking, and the pointer guard refuses a carried PR that disagrees with the
# run anyway. Assigns only on success, because binding it to the empty string is
# the #427 defect itself -- `PR #` in a verifier prompt and `pr:""` in the audit
# row that has to make a suppressed blocker traceable.
_review_fleet_bind_pr() {
  local recovered
  [ -z "${PR_NUMBER:-}" ] || return 0
  recovered="$(_review_fleet_run_dir_pr "${1:-}")" || return 0
  PR_NUMBER="$recovered"
}

# _review_fleet_bind_repo_slug RESEARCH_DIR -- recover REVIEW_REPO_SLUG for this fence.
#
# The slug is minted ONCE, in the Phase 0 metadata fence, and then read by about
# twenty later fences: every child envelope's `repoSlug`, both
# review_assert_selected_pr_head gates, both review_publish_same_repo_pr_head
# calls, and every Phase 3 `gh run`/`gh api` call. All of them are separate
# processes, so all of them read the empty string.
#
# Two sites had already noticed and grown their own
# `${REVIEW_REPO_SLUG:-$(gh repo view ...)}`. Copying that to the other eighteen
# is the #370 "one contract, N uncompared copies" shape, and it also means up to
# twenty `gh` round-trips per run. This binds it once, next to PR_NUMBER, which
# is the same kind of value recovered the same way.
#
# CACHED IN THE RESEARCH DIRECTORY, so `gh` is consulted at most once per run --
# and NOT in the run/marker directory, which is where it does not belong. The
# reservation reaper refuses to reap any run directory holding an entry outside
# `{locked, pr-context.json, review-pr-verdict.json}`, so a cache file dropped
# there would make every abandoned reservation permanently un-reapable and stall
# `/uberdev:goal` on exactly the runs #344 added the reaper to rescue. The
# research dir is where every other run-scoped carrier already lives
# (review-base-identity.tsv, trust-state.tsv, ci-fix-phase.txt).
#
# FAIL-SOFT: if gh is absent or offline the slug stays empty and the fence that
# needs it fails at its OWN shape guard with its own message. Making rehydrate
# itself hard-fail here would turn "no network" into "every fence is broken",
# and would put a gh round-trip in the path of harnesses that never touch a
# remote.
# _review_fleet_bind_carrier_backend DESCRIPTOR
#
# The dispatch backend this run's children were launched on.
#
# `uberdev_prepare_run_carrier` derives it once, in the SETUP fence, from the
# validated route context's `root_decision.backend`. Every later fence is a
# separate process, so `UBERDEV_CARRIER_BACKEND` was the empty string there --
# and the Phase 1 evidence builder passes it straight into
# `post_review_validated_evidence_complete` as `expected_backend`, which refuses
# anything outside {workflow, wezterm, background}.
#
# The empty string is outside that set, so a complete, healthy 7-reviewer fanout
# died `roster-mismatch` with `edge=unknown index=unknown` and the aggregate was
# suppressed -- a message about the ROSTER, on a run whose roster was perfect and
# whose backend simply had not travelled. Found by running /review-pr for real:
# no static scan sees it, because the name is bound in lib/child-dispatch.sh
# rather than in any fence, so a "assigned in fence X, read in fence Y" search
# never pairs them.
#
# Re-derived, not carried: the descriptor already names the context file, the
# context file is identity-checked when it is written, and the backend is a
# property of the launch decision that cannot change mid-run.
_review_fleet_bind_carrier_backend() {
  # The argument is the descriptor's CONTENTS, not its path -- the same bytes
  # UBERDEV_COMMAND_WORKSPACE_JSON carries. Reading it as a filename is the
  # mistake that made the first cut of this binder a silent no-op.
  local descriptor="${1:-}" context_file backend
  [ -z "${UBERDEV_CARRIER_BACKEND:-}" ] || return 0
  [ -n "$descriptor" ] || return 0
  context_file="$(python3 -I -B -c 'import json,sys
try:
    value=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
if not isinstance(value,dict):
    raise SystemExit(0)
print(value.get("context_file") or "",end="")' "$descriptor" 2>/dev/null)" || return 0
  [ -n "$context_file" ] || return 0
  [ -r "$context_file" ] || return 0
  backend="$(python3 -I -B -c 'import json,sys
try:
    value=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
decision=value.get("root_decision")
if not isinstance(decision,dict):
    raise SystemExit(0)
print(decision.get("backend") or "",end="")' "$context_file" 2>/dev/null)" || return 0
  # Shape-checked against the same enum the evidence builder allows. Binding an
  # unrecognised token here would trade one misleading refusal for another.
  #
  # Byte-aligned with the dispatch enum minus `auto`, for the same reason
  # goal-state.sh's resolved-backend arm is: `auto` is a REQUEST, never a
  # resolution, so a run can never have been dispatched on it.
  # CONTRACT: dispatch-backend -auto !case-arm
  case "$backend" in workflow|wezterm|background) UBERDEV_CARRIER_BACKEND="$backend" ;; esac
}

_review_fleet_bind_repo_slug() {
  local research_dir="${1:-}" cache slug=''
  [ -z "${REVIEW_REPO_SLUG:-}" ] || return 0
  [ -n "$research_dir" ] || return 0
  [ -d "$research_dir" ] || return 0
  cache="$research_dir/repo-slug.txt"
  if [ -r "$cache" ]; then
    IFS= read -r slug <"$cache" || slug=''
  fi
  if [ -z "$slug" ]; then
    command -v gh >/dev/null 2>&1 || return 0
    slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || slug=''
    case "$slug" in
      [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*)
        ( umask 077 && printf '%s\n' "$slug" >"$cache" ) 2>/dev/null || true
        ;;
    esac
  fi
  # Shape-checked before it is bound: a partial or error value assigned here
  # would be handed straight to `gh --repo`, and an empty-but-present binding is
  # the #427 defect itself.
  case "$slug" in
    *' '* | *'/'*'/'*) return 0 ;;
    [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) REVIEW_REPO_SLUG="$slug" ;;
    *) return 0 ;;
  esac
}

# _review_fleet_bind_reviewed_head RESEARCH_DIR -- recover the head this review
# stands on, READ BACK and never recomputed (see review_fleet_write_reviewed_head
# for why recomputing deletes the anti-race check it looks like).
#
# A FUNCTION, and called from BOTH rehydration entry paths, because the recovery
# used to be written inline at the bottom of the resolved path only. The fast
# path returns as soon as the eleven scalars are bound -- which is exactly the
# state a child dispatched with its parent's exported environment is in -- so it
# never reached the recovery and never exported either head name. That made
# WHICH fence a child came from decide whether it inherited the head of the
# review, the same divergence L5 in tests/review-pr-workflow.test.sh exists to
# refuse for STANDALONE_SNAPSHOT_PATH (#479).
#
# Gap-filling like every other binder here: a value already established in THIS
# process wins, so the fence that ADVANCES the head is not overwritten by the
# record it is about to update.
_review_fleet_bind_reviewed_head() {
  local research_dir="${1:-}"
  [ -z "${VALIDATED_FIXER_HEAD_SHA:-}" ] || return 0
  [ -n "$research_dir" ] || return 0
  [ -r "$research_dir/reviewed-head.txt" ] || return 0
  # A malformed record leaves BOTH names empty rather than half-bound: absent is
  # a state the promote gate is written for, a 39-hex head is not.
  VALIDATED_FIXER_HEAD_SHA="$(review_fleet_read_reviewed_head \
    "$research_dir/reviewed-head.txt" 2>/dev/null)" || VALIDATED_FIXER_HEAD_SHA=
  # THE PUBLISHED head is a DIFFERENT fact from the validated one, and the
  # difference is the whole of what the post-fixer publication gate checks.
  #
  # `reviewed-head.txt` advances the moment a fixer commit is validated, which
  # is LOCAL. Nothing has pushed at that point, so the remote still stands where
  # it did. Step 6a is a fresh shell: it rehydrated REVIEWED_HEAD_SHA off the
  # advanced record and handed it to review_publish_same_repo_pr_head as
  # `expected_remote_head_sha`, a value the remote cannot hold -- so
  # `[ "$live_head" = "$expected_remote_head_sha" ]` failed on EVERY run whose
  # Phase 1 fixer APPLIED, the fix commit never reached the PR, and Phase 3 went
  # on to probe the stale SHA that 6a's own error text warns about.
  #
  # So the published head gets its own record, written only where a push really
  # happened, and it is what REVIEWED_HEAD_SHA rehydrates from. The old fallback
  # survives ONLY for a run that predates the seed: absent the record, behaviour
  # is exactly what it was.
  if [ -z "${REVIEWED_HEAD_SHA:-}" ] && [ -r "$research_dir/published-head.txt" ]; then
    # PRESENT-BUT-UNREADABLE IS NOT ABSENT, and the difference is the whole
    # value of this carrier. The readability guard above means the only way to
    # reach this failure branch is a record that EXISTS and does not validate --
    # a zero-byte or truncated file from an interrupted session or a full disk,
    # which is exactly the fresh-shell world the record was added for. Falling
    # through to the validated head there would hand Step 6a the fixer-advanced
    # LOCAL head again and reinstate the very gate failure this record prevents,
    # silently and on the corrupt path only. So the name is left EMPTY and the
    # consumer refuses with its own message; the reader's diagnostic is NOT
    # redirected away, because a carrier that cannot be read has to say so.
    if ! REVIEWED_HEAD_SHA="$(review_fleet_read_published_head \
        "$research_dir/published-head.txt")"; then
      # The reader names WHAT is wrong with the bytes; this names what the run
      # loses because of it, which is the half an operator needs: the publish
      # gate is about to refuse on an empty expected-remote head, and the reason
      # is this record rather than anything about the PR.
      echo "error: review-fleet could not read the published head from $research_dir/published-head.txt; leaving REVIEWED_HEAD_SHA empty so the publication gate refuses rather than falling back to the fixer-advanced local head" >&2
      REVIEWED_HEAD_SHA=
      return 0
    fi
  fi
  REVIEWED_HEAD_SHA="${REVIEWED_HEAD_SHA:-$VALIDATED_FIXER_HEAD_SHA}"
  return 0
}

# ---------------------------------------------------------------------------
# THE SECOND HALF OF #427: functions do not survive a process boundary either.
#
# Rehydration closed the VARIABLE half -- a scalar minted in the setup fence and
# read nine Workflow relays later expanded empty. It did nothing for the
# FUNCTION half. commands/review-pr.md DEFINED twenty `review_*` helpers
# inside markdown fences and called them from OTHER fences:
# review_refresh_phase1_scope (Phase 2), review_assert_selected_pr_head and
# review_publish_same_repo_pr_head (the trust trail), review_json_string and the
# review_child_* builders (Phase 2.5), review_promote_validated_fixer_outcome,
# review_select_failed_ci_run (Phase 3). Every one of those call sites was
# `command not found` in a real run.
#
# That is worse than a crash at three of them, because the call sits in front of
# a `||` arm written for a DIFFERENT failure. A missing
# review_assert_selected_pr_head prints "PR head changed after review;
# suppressing trust emission"; a missing review_promote_validated_fixer_outcome
# path prints "HEAD changed outside the validated review fixers". The run does
# not just fail, it accuses the repository of something that never happened --
# which is why this went unchased for so long.
#
# WHERE THE DEFINITIONS LIVE. lib/review-fences.sh, and nowhere else --
# commands/review-pr.md keeps no copy, and tests/review-pr.test.sh R47.4 refuses
# one, because two copies of one contract is the #370 "one contract, N
# uncompared copies" class. The first cut of this loader kept the markdown as
# the definition and awk-carved the slices back out at run time; that held the
# single-copy property but shipped helpers that could not be syntax-checked or
# read as code, and re-read a 7,000-line markdown file on every fence. They are
# code, so they live in a file that is code. This loader still carves (#471, see
# below) -- but out of a real shell file that shellcheck and `bash -n` can read,
# and only for the names the calling shell is actually missing.

# review_fleet_fence_library_path -> the library, named once.
#
# A function rather than a constant so this loader, the guard below and
# tests/review-pr.test.sh all read the same bytes instead of three string
# literals that can drift apart.
review_fleet_fence_library_path() {
  printf '%s/lib/review-fences.sh' "$UBERDEV_REVIEW_PLUGIN_ROOT"
}

# review_fleet_load_fence_library -- define commands/review-pr.md's helpers here.
#
# rc 0 with every cross-fence helper defined in THIS shell, or rc 2 with a
# message on stderr. Called from review_fleet_rehydrate, so every fence that
# carries the prologue gains the functions with no call-site edit.
review_fleet_load_fence_library() {
  [ "$#" -eq 0 ] || {
    echo "error: review_fleet_load_fence_library takes no arguments" >&2
    return 2
  }
  local library_file defined_names wanted fence_fn slice
  library_file="$(review_fleet_fence_library_path)"
  # A plugin root with no commands/ directory at all is a SYNTHETIC root: the
  # behavioural harnesses build one that holds a shim lib/ and nothing else,
  # purely to exercise identity handling. Those callers never reach a fence
  # helper, so loading nothing is correct for them. A root that HAS commands/ but
  # is missing the library is a broken install and gets rc 2 -- the distinction
  # keeps the fail-soft arm from swallowing the real defect it would otherwise
  # look identical to.
  if [ ! -d "$UBERDEV_REVIEW_PLUGIN_ROOT/commands" ] && [ ! -r "$library_file" ]; then
    return 0
  fi
  [ -r "$library_file" ] || {
    echo "error: review-pr fence library is unreadable: $library_file" >&2
    return 2
  }
  # GAP-FILLING, the same doctrine review_fleet_rehydrate applies to scalars: a
  # definition this process already holds is the caller talking, and it wins.
  #
  # This is not defensive politeness, it is required. The behavioural harnesses
  # install their own `review_refresh_phase1_scope`, `review_child_single` and
  # friends before entering a fence, precisely so the fence exercises a
  # controlled stub instead of reaching for git and gh. A loader that sourced
  # over them would silently re-point those tests at the real implementation --
  # which is exactly what happened on the first cut here: two suites started
  # running `git merge-base --is-ancestor` against fixture SHAs that do not
  # exist and failed with `MUTATED_BLOCKED`.
  #
  # HOW that gap-filling is done is #471. The previous cut sourced the library
  # OVER the caller and then put the caller's definitions back, by capturing
  # `typeset -f` output and `eval`ing it -- on the stated premise that typeset -f
  # "prints it back in re-evaluable form, in zsh and in bash 3.2 alike".
  #
  # That premise is FALSE, in both directions and non-monotonically. `typeset -f`
  # reconstructs a function from the shell's parse tree rather than echoing the
  # bytes it was defined from, and every bash reflows heredocs differently. Two
  # helpers in THIS library are re-emitted unparseably, on disjoint shells:
  #
  #   bash 3.2.57 (stock macOS)  review_fixer_child_bound -- `cmd <<'PY' || {`
  #     comes back with the `|| {` on its own line AFTER the PY terminator, i.e.
  #     a list operator with no left operand: "syntax error near `||'".
  #   bash 5.0-5.2 (ubuntu-latest, the CI runner)  review_child_fanout -- the
  #     `if cmd <<'PY' ... PY then :` shape comes back as `if cmd <<'PY'; then`
  #     with the then-body hoisted ABOVE the heredoc body, so it is swallowed as
  #     heredoc text and the then-clause is left empty: "syntax error near `else'".
  #
  # bash 4.x, bash 5.3 and zsh 5.9 happen to re-emit both cleanly, which is
  # exactly why this shipped: the two shells the comment named are the two the
  # bug does not reach on the same helper. There is no version predicate to
  # test and no "safe heredoc" rule to enforce -- 4.x and 5.3 accept both shapes,
  # so a lint for them would be un-writable on the shells that pass. The defect
  # is not the two helpers; it is that a lossy serializer sits on the restore
  # path at all.
  #
  # So do not clobber, and there is nothing to restore. `typeset -f` is used
  # ONLY as a predicate ("is this a shell function"), which is sound everywhere
  # and is already how review_fleet_define_audit probes below; the names the
  # caller does not already hold are carved out of the library's OWN BYTES and
  # eval'd. Original source bytes re-parse by construction -- that is the one
  # property typeset -f output lacks.
  #
  # Read the names off the LIBRARY FILE, never off a hardcoded roster: a helper
  # added there but forgotten here would be silently un-loadable, which is
  # the same completeness-guard-disjoint-from-the-drift trap as #371.
  #
  # `^[[:space:]]*`, not `^`: tests/review-pr.test.sh R47.4 builds its roster
  # with the same leading-space-tolerant pattern, and a stricter one here would
  # let an indented definition be a helper R47.4 polices but this loader cannot
  # carve -- two readers of one roster that can disagree. The awk below keys off
  # the same tolerance and closes each block on a `}` at the DEFINITION's own
  # indent, so the two readers stay in agreement by construction.
  defined_names="$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)()[[:space:]]*{.*$/\1/p' "$library_file")"
  # Non-emptiness is a real assertion, not a formality: sourcing an empty file
  # succeeds, so without this a truncated or renamed library would leave every
  # helper undefined and this function would still report success -- the same
  # silent-empty shape #427 was.
  [ -n "$defined_names" ] || {
    echo "error: review-pr fence library defines no helpers: $library_file" >&2
    return 2
  }
  wanted=''
  # Herestring, never `printf | while read`: a pipeline puts the loop body in a
  # SUBSHELL under bash, so every name appended to `wanted` would be discarded
  # at the end of the pipe.
  #
  # `typeset -f` as a PREDICATE only -- its rc is trustworthy on every shell,
  # its stdout is not (see #471 above). A name the caller already holds is
  # simply never carved, so it is never overwritten and never needs restoring.
  while IFS= read -r fence_fn; do
    [ -n "$fence_fn" ] || continue
    typeset -f "$fence_fn" >/dev/null 2>&1 && continue
    wanted="$wanted $fence_fn"
  done <<<"$defined_names"
  # ENVIRON, not `-v`: BSD awk (stock macOS) applies backslash-escape processing
  # to a `-v` value and hard-errors on a newline inside one ("awk: newline in
  # string"). Reading the list out of the environment sidesteps both. Space
  # separated is safe -- a shell function name cannot contain a space.
  #
  # The carve rule is the file's own convention and is not new machinery:
  # tests/review-pr.test.sh:31 (`review_fence_fn`) and
  # tests/review-child-inputs.test.sh:120 (`library_definition`) already slice
  # this same library the same way. Loss-free because review-fences.sh holds no
  # top-level executable statements -- policed by R47.8 so it stays that way.
  slice="$(UBERDEV_REVIEW_FENCE_WANTED="$wanted" awk '
    BEGIN {
      n = split(ENVIRON["UBERDEV_REVIEW_FENCE_WANTED"], names, " ")
      for (i = 1; i <= n; i++) if (names[i] != "") want[names[i]] = 1
    }
    active { print; if ($0 == closer) active = 0; next }
    /^[ \t]*[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*$/ {
      indent = $0; sub(/[^ \t].*$/, "", indent)
      name = $0; sub(/^[ \t]*/, "", name); sub(/\(\)[ \t]*\{.*$/, "", name)
      if (name in want) { closer = indent "}"; active = 1; print }
    }
  ' "$library_file")" || {
    echo "error: review-pr fence library could not carve its load slice: $library_file" >&2
    return 2
  }
  # `eval`, not a temp file: the bytes are already in hand, and a scratch file
  # here would need a TMPDIR that is writable in every fence and would have to
  # be cleaned on all four return paths -- R47.6 pins the run directory to
  # exactly three entries, so the cheapest scratch file is the one never made.
  # Unlike the typeset -f output this replaces, these bytes parsed once already.
  [ -z "$slice" ] || eval "$slice" || {
    echo "error: review-pr fence library failed to load from $library_file" >&2
    return 2
  }
  # POSTCONDITION, not paranoia. Everything above is a gap-filling contract, and
  # a carve that silently dropped a helper would look exactly like a successful
  # load until a fence called the missing name and got command-not-found 40
  # fences later. Assert the property the caller actually depends on -- every
  # helper the library declares is callable in THIS shell, whoever defined it --
  # so a roster/carve disagreement fails here, loudly, naming the helper.
  while IFS= read -r fence_fn; do
    [ -n "$fence_fn" ] || continue
    typeset -f "$fence_fn" >/dev/null 2>&1 || {
      echo "error: review-pr fence library left $fence_fn undefined: $library_file" >&2
      return 2
    }
  done <<<"$defined_names"
  # uberdev_child_inputs_build / uberdev_child_instance_id live in
  # lib/child-dispatch.sh, which ONLY the setup fence sourced. Phase 2.5's
  # findings-to-issues dispatch calls both and sourced neither. The file carries
  # its own `_UBERDEV_CHILD_DISPATCH_LOADED` guard, so this is idempotent.
  . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || {
    echo "error: review-pr fence library could not load lib/child-dispatch.sh" >&2
    return 2
  }
  review_fleet_define_audit
}

# review_fleet_define_audit -- give the `audit` call sites a real implementation.
#
# `audit <event> [key=value ...]` is called 65 times across commands/review-pr.md
# and was defined NOWHERE in the shipped plugin -- only the test harnesses ever
# stubbed it. In a real fence the bare word resolved to /usr/sbin/audit on macOS
# (rc 255, "Usage: audit -e | -i | ...") and to command-not-found on the Linux CI
# runners (rc 127). All 65 rows were lost, and because thirteen of the calls sit
# in TAIL position their status became the enclosing block's: two fences END with
# an `audit` call, so a fully successful path still exited non-zero.
#
# `command -v audit` is NOT the availability probe here -- it finds
# /usr/sbin/audit and would conclude the helper already exists. `typeset -f` asks
# the only question that matters, "is this a shell function", and answers it the
# same way in zsh and in bash 3.2.
#
# GAP-FILLING, exactly like review_fleet_rehydrate: a harness that installed its
# own `audit` stub before sourcing a fence slice keeps it. Rows are fail-soft by
# contract (review_fleet_audit_append's own comment: a missing audit row must not
# fail a review that otherwise passed), so this always returns 0 -- which is also
# what makes the thirteen tail-position call sites safe.
review_fleet_define_audit() {
  typeset -f audit >/dev/null 2>&1 && return 0
  audit() {
    local event="${1:-}" run_root row
    [ -n "$event" ] || return 0
    shift 2>/dev/null || true
    run_root="${WORKTREE_ROOT:-}"
    [ -n "$run_root" ] || return 0
    row="$(python3 -I -B - "$event" "$@" <<'PY' 2>/dev/null
import json, sys
event = sys.argv[1]
row = {"event": event}
for pair in sys.argv[2:]:
    key, sep, value = pair.partition("=")
    if not sep:
        continue
    # `data.outcome=halted` and `outcome=halted` are both live spellings at the
    # call sites; flatten the prefix so one event never lands under two keys.
    if key.startswith("data."):
        key = key[len("data."):]
    row[key] = value
print(json.dumps(row, sort_keys=True, separators=(",", ":")), end="")
PY
)" || return 0
    [ -n "$row" ] || return 0
    review_fleet_audit_append "$run_root" "$row"
    return 0
  }
  return 0
}

# review_fleet_rehydrate -- bind every run-invariant carrier in THIS shell.
#
# rc 0 with the carriers bound and exported, or rc 2 with a message on stderr
# and NOTHING half-bound. Fences call it as `review_fleet_rehydrate || return 2`
# so a fence that cannot establish its run never proceeds to read an empty path.
#
# IT FILLS GAPS; IT DOES NOT OVERRIDE AN ESTABLISHED RUN. When every carrier is
# already non-empty the run is already established in THIS process and the
# function returns immediately. That is not a courtesy to callers, it is the
# correct reading of the defect: #427 is that an unbound carrier expands to the
# EMPTY STRING and an empty path answers "does not exist", which downstream
# reads as `green`. Empty is the hazard, and empty is what this closes. A
# non-empty value cannot have come from a dead shell -- there is no inheritance
# across harness Bash calls -- so it came from the current process, which is the
# setup fence itself or a caller that sourced it.
#
# The guarantee that this is not a loophole comes from the tests, not from
# clobbering: the fresh-shell rows run each fence under `env -i` with nothing
# bound at all, which is the only environment a real fence ever sees.
review_fleet_rehydrate() {
  [ "$#" -eq 0 ] || {
    echo "error: review_fleet_rehydrate takes no arguments" >&2
    return 2
  }
  local toplevel resolved_run_dir resolved_research_dir descriptor_fields reap_secs carrier
  local _review_fleet_diff _review_fleet_criteria _review_fleet_range _review_fleet_snapshot
  local _review_fleet_phase1 _review_fleet_phase2 _review_fleet_agg _review_fleet_carrier_dir
  local _review_fleet_repo _review_fleet_research _review_fleet_descriptor
  UBERDEV_REVIEW_PLUGIN_ROOT="${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}"
  [ -n "$UBERDEV_REVIEW_PLUGIN_ROOT" ] || {
    echo "error: review-pr fence entered with no plugin root: none of UBERDEV_REVIEW_PLUGIN_ROOT, PLUGIN_ROOT, CLAUDE_PLUGIN_ROOT, CURSOR_PLUGIN_ROOT is set" >&2
    return 2
  }
  # #387: CODE_FIXER_CONTRACT was bound in the setup fence and never exported,
  # so every later fence passed an EMPTY --contract. It is a pure function of
  # the plugin root, so it is re-derived here rather than carried.
  CODE_FIXER_CONTRACT="${CODE_FIXER_CONTRACT:-$UBERDEV_REVIEW_PLUGIN_ROOT/lib/code_fixer_contract.py}"
  [ -f "$CODE_FIXER_CONTRACT" ] || {
    echo "error: review-pr fence resolved a plugin root with no code fixer contract: $CODE_FIXER_CONTRACT" >&2
    return 2
  }
  # Above the carrier fast path, not below it. The fast path returns as soon as
  # every scalar is already bound -- which is exactly the state a fence that
  # exported its carriers to a child is in -- and a loader placed after it would
  # be skipped in precisely the runs that still need the functions.
  review_fleet_load_fence_library || return 2
  # STANDALONE_SNAPSHOT_PATH is deliberately absent from this list: it belongs to
  # /simplify, and for a /review-pr run the descriptor's own value is the empty
  # string. Requiring it would make every complete run look incomplete.
  for carrier in "${RUN_ID:-}" "${WORKTREE_ROOT:-}" "${RESEARCH_DIR_ABS:-}" "${MARKER_DIR:-}" \
    "${DIFF_ARTIFACT_PATH:-}" "${CRITERIA_PATH:-}" "${COMMIT_RANGE_PATH:-}" \
    "${PHASE1_DISPOSITION_PATH:-}" "${PHASE2_DISPOSITION_PATH:-}" "${AGG_PATH:-}" \
    "${UBERDEV_COMMAND_WORKSPACE_JSON:-}"; do
    [ -n "$carrier" ] || { carrier=''; break; }
    carrier=complete
  done
  if [ "$carrier" = complete ]; then
    # PR identity is a run invariant too, and the marker it comes off is inside
    # the run directory MARKER_DIR already names.
    _review_fleet_bind_pr "$MARKER_DIR"
    _review_fleet_bind_repo_slug "${RESEARCH_DIR_ABS:-}"
    _review_fleet_bind_reviewed_head "${RESEARCH_DIR_ABS:-}"
    # Same export set as the resolved path below, minus the two names that are
    # legitimately absent for a /review-pr run: exporting an unset variable would
    # hand children an empty-but-present value they cannot distinguish from a
    # real one.
    export UBERDEV_REVIEW_PLUGIN_ROOT CODE_FIXER_CONTRACT RUN_ID MARKER_DIR WORKTREE_ROOT
    export RESEARCH_DIR_ABS UBERDEV_COMMAND_WORKSPACE_JSON
    export DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH
    export PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH
    [ -z "${UBERDEV_CARRIER_RUN_DIR:-}" ] || export UBERDEV_CARRIER_RUN_DIR
    [ -z "${STANDALONE_SNAPSHOT_PATH:-}" ] || export STANDALONE_SNAPSHOT_PATH
    [ -z "${PR_NUMBER:-}" ] || export PR_NUMBER
    [ -z "${REVIEW_REPO_SLUG:-}" ] || export REVIEW_REPO_SLUG
    [ -z "${VALIDATED_FIXER_HEAD_SHA:-}" ] || export VALIDATED_FIXER_HEAD_SHA
    [ -z "${REVIEWED_HEAD_SHA:-}" ] || export REVIEWED_HEAD_SHA
    return 0
  fi
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=''
  [ -n "$toplevel" ] || {
    echo "error: review-pr fence is not inside a git working tree; cannot resolve the review run root" >&2
    return 2
  }
  toplevel="$(cd "$toplevel" && pwd -P)" || return 2
  reap_secs="${REVIEW_RESERVATION_REAP_SECS:-7200}"
  if [ -n "${RUN_ID:-}" ]; then
    # An explicitly carried RUN_ID always wins over the pointer -- the pointer
    # is a recovery path, never an override.
    _review_fleet_run_id_ok "$RUN_ID" || {
      echo "error: review-pr fence carried a malformed RUN_ID: $RUN_ID" >&2
      return 2
    }
  else
    RUN_ID="$(_review_fleet_pointer_run_id "$toplevel" "${PR_NUMBER:-}" "$reap_secs")" || {
      unset RUN_ID 2>/dev/null || RUN_ID=''
      return 2
    }
    [ -n "$RUN_ID" ] || {
      unset RUN_ID 2>/dev/null || RUN_ID=''
      echo "error: review-pr active-run pointer resolved to an empty run id" >&2
      return 2
    }
  fi
  resolved_run_dir="$(cd "$toplevel/.uberdev/runs/$RUN_ID" 2>/dev/null && pwd -P)" || resolved_run_dir=''
  [ -n "$resolved_run_dir" ] || {
    echo "error: review-pr run $RUN_ID has no reservation directory under $toplevel/.uberdev/runs" >&2
    return 2
  }
  resolved_research_dir="$(cd "$toplevel/.uberdev/research/$RUN_ID" 2>/dev/null && pwd -P)" || resolved_research_dir=''
  [ -n "$resolved_research_dir" ] || {
    echo "error: review-pr run $RUN_ID has no research directory under $toplevel/.uberdev/research" >&2
    return 2
  }
  # The descriptor is the ONLY source of the artifact pathnames. Cross-checking
  # its repository_root and research_dir against the two paths resolved above is
  # what makes reading it safe: a descriptor belonging to another checkout, or
  # left over from a moved worktree, is refused rather than silently adopted.
  descriptor_fields="$(python3 -I -B - "$resolved_research_dir/command-workspace.json" "$toplevel" "$resolved_research_dir" <<'PY'
import json
import os
import sys

descriptor_path, expected_repo, expected_research = sys.argv[1:]
ORDER = (
    "diff",
    "criteria",
    "commit_range",
    "standalone_snapshot",
    "phase1_disposition",
    "phase2_disposition",
    "aggregate",
)
# standalone_snapshot belongs to /simplify, not to /review-pr, so an EMPTY value
# is correct here and only here -- exactly what uberdev_command_workspace_prepare
# binds. Every other name must be a real path under the research dir of the run.
# NOTE: no apostrophe may appear anywhere in this heredoc body -- it sits inside
# a $( ) and bash 3.2 (macOS /bin/bash) scans the body for quotes, so an odd
# apostrophe count makes the command substitution unterminated (#427/PR450).
OPTIONAL = {"standalone_snapshot"}


def refuse(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(2)


try:
    with open(descriptor_path, "r", encoding="utf-8") as handle:
        descriptor = json.loads(handle.read(1048576))
except OSError as error:
    refuse(
        "review-pr run workspace descriptor is unreadable: %s: %s -- the run was reserved "
        "by an older /review-pr, or its setup fence never completed" % (descriptor_path, error)
    )
except Exception as error:
    refuse("review-pr run workspace descriptor is not valid JSON: %s: %s" % (descriptor_path, error))
if not isinstance(descriptor, dict) or descriptor.get("schema_version") != 1:
    refuse("review-pr run workspace descriptor carries an unknown schema: " + descriptor_path)
if descriptor.get("caller") != "review-pr":
    refuse(
        "review-pr run workspace descriptor was written by caller %r, not review-pr: %s"
        % (descriptor.get("caller"), descriptor_path)
    )
recorded_repo = descriptor.get("repository_root")
recorded_research = descriptor.get("research_dir")
if not isinstance(recorded_repo, str) or os.path.realpath(recorded_repo) != os.path.realpath(expected_repo):
    refuse(
        "review-pr run workspace descriptor names repository_root %r but this fence resolved %r"
        % (recorded_repo, expected_repo)
    )
if not isinstance(recorded_research, str) or os.path.realpath(recorded_research) != os.path.realpath(expected_research):
    refuse(
        "review-pr run workspace descriptor names research_dir %r but this fence resolved %r"
        % (recorded_research, expected_research)
    )
artifacts = descriptor.get("artifacts")
if not isinstance(artifacts, dict):
    refuse("review-pr run workspace descriptor carries no artifacts map: " + descriptor_path)
values = []
for key in ORDER:
    value = artifacts.get(key, "")
    if not isinstance(value, str):
        refuse("review-pr run workspace descriptor artifact %r is not a string" % (key,))
    if value == "":
        if key not in OPTIONAL:
            refuse("review-pr run workspace descriptor artifact %r is empty" % (key,))
    elif os.path.dirname(value) != recorded_research:
        refuse(
            "review-pr run workspace descriptor artifact %r escapes the run research dir: %r"
            % (key, value)
        )
    values.append(value)
carrier_run_dir = descriptor.get("carrier_run_dir")
if not isinstance(carrier_run_dir, str) or not carrier_run_dir:
    refuse("review-pr run workspace descriptor carries no carrier_run_dir: " + descriptor_path)
values.append(carrier_run_dir)
values.append(recorded_repo)
values.append(recorded_research)
values.append(json.dumps(descriptor, sort_keys=True, separators=(",", ":")))
for value in values:
    if "\n" in value or "\r" in value:
        refuse("review-pr run workspace descriptor carries an embedded newline; refusing to rehydrate")
# Byte-level write: on Windows, text-mode stdout translates EVERY "\n" -- the
# embedded separators too, not just a trailing one -- into "\r\n", and the
# `IFS= read -r` reader below strips the "\n" but keeps the "\r", poisoning
# every rehydrated carrier with a trailing CR. `end=""` does NOT fix that.
sys.stdout.buffer.write(("\n".join(values) + "\n").encode("utf-8"))
PY
  )" || return 2
  # Sequential `IFS= read -r` out of a HERESTRING, never a pipeline: a `... |
  # while read` loop runs in a subshell and loses every assignment, and a pipe
  # into an early-exiting reader is the EPIPE class this repo has been bitten by.
  {
    IFS= read -r _review_fleet_diff
    IFS= read -r _review_fleet_criteria
    IFS= read -r _review_fleet_range
    IFS= read -r _review_fleet_snapshot
    IFS= read -r _review_fleet_phase1
    IFS= read -r _review_fleet_phase2
    IFS= read -r _review_fleet_agg
    IFS= read -r _review_fleet_carrier_dir
    IFS= read -r _review_fleet_repo
    IFS= read -r _review_fleet_research
    IFS= read -r _review_fleet_descriptor
  } <<REVIEW_FLEET_REHYDRATE_EOF
$descriptor_fields
REVIEW_FLEET_REHYDRATE_EOF
  [ -n "$_review_fleet_repo" ] && [ -n "$_review_fleet_research" ] && [ -n "$_review_fleet_descriptor" ] || {
    echo "error: review-pr run workspace descriptor did not yield a complete carrier set for $RUN_ID" >&2
    return 2
  }
  # `${VAR:-<resolved>}` per carrier, not a blanket overwrite. An EMPTY carrier
  # is the #427 defect and gets the run's own value; a carrier this process
  # already bound is the run itself talking and is left alone.
  DIFF_ARTIFACT_PATH="${DIFF_ARTIFACT_PATH:-$_review_fleet_diff}"
  CRITERIA_PATH="${CRITERIA_PATH:-$_review_fleet_criteria}"
  COMMIT_RANGE_PATH="${COMMIT_RANGE_PATH:-$_review_fleet_range}"
  STANDALONE_SNAPSHOT_PATH="${STANDALONE_SNAPSHOT_PATH:-$_review_fleet_snapshot}"
  PHASE1_DISPOSITION_PATH="${PHASE1_DISPOSITION_PATH:-$_review_fleet_phase1}"
  PHASE2_DISPOSITION_PATH="${PHASE2_DISPOSITION_PATH:-$_review_fleet_phase2}"
  AGG_PATH="${AGG_PATH:-$_review_fleet_agg}"
  UBERDEV_CARRIER_RUN_DIR="${UBERDEV_CARRIER_RUN_DIR:-$_review_fleet_carrier_dir}"
  WORKTREE_ROOT="${WORKTREE_ROOT:-$_review_fleet_repo}"
  RESEARCH_DIR_ABS="${RESEARCH_DIR_ABS:-$_review_fleet_research}"
  UBERDEV_COMMAND_WORKSPACE_JSON="${UBERDEV_COMMAND_WORKSPACE_JSON:-$_review_fleet_descriptor}"
  MARKER_DIR="${MARKER_DIR:-$resolved_run_dir}"
  _review_fleet_bind_pr "$resolved_run_dir"
  _review_fleet_bind_repo_slug "$resolved_research_dir"
  _review_fleet_bind_carrier_backend "$_review_fleet_descriptor"
  # The reviewed head, READ BACK -- see _review_fleet_bind_reviewed_head, which
  # both entry paths call so neither can hand a child a head the other would not.
  _review_fleet_bind_reviewed_head "$resolved_research_dir"
  # The child timeout, re-derived rather than carried.
  #
  # The setup fence writes `REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT:-600}"` and
  # five LATER fences pass it to review_fixer_child_bound / review_child_fanout
  # / review_child_wait_all without establishing it. In those fences it expanded
  # empty and the timeout argument went to the dispatcher blank.
  #
  # Re-derivation is exact here, not a default standing in for lost state: the
  # expression is the setup fence's own, so an operator override in the
  # environment still wins and 600 is reached only when nobody set one. That is
  # the whole difference between this and the Phase 2.5 counters, which are
  # measurements of a run and can only be read back, never recomputed.
  REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT:-600}"
  unset _review_fleet_diff _review_fleet_criteria _review_fleet_range _review_fleet_snapshot \
    _review_fleet_phase1 _review_fleet_phase2 _review_fleet_agg _review_fleet_carrier_dir \
    _review_fleet_repo _review_fleet_research _review_fleet_descriptor 2>/dev/null || true
  # Exported for the CHILDREN this fence dispatches. It cannot help the NEXT
  # fence -- that is a different process -- which is precisely why the next
  # fence calls this function too.
  #
  # The three guarded names are guarded HERE for the same reason the fast path
  # guards them: two entries into this function must not hand children two
  # different environments. STANDALONE_SNAPSHOT_PATH is the live case -- for a
  # /review-pr run the descriptor's own standalone_snapshot is deliberately the
  # empty string, so an unconditional export would put an empty-but-present
  # value in every dispatched child's environment on this path and nothing at
  # all on the other one.
  export UBERDEV_REVIEW_PLUGIN_ROOT CODE_FIXER_CONTRACT RUN_ID MARKER_DIR WORKTREE_ROOT
  export RESEARCH_DIR_ABS UBERDEV_COMMAND_WORKSPACE_JSON
  export DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH
  export PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH
  export REVIEW_PR_TIMEOUT
  [ -z "${UBERDEV_CARRIER_BACKEND:-}" ] || export UBERDEV_CARRIER_BACKEND
  [ -z "${VALIDATED_FIXER_HEAD_SHA:-}" ] || export VALIDATED_FIXER_HEAD_SHA
  [ -z "${REVIEWED_HEAD_SHA:-}" ] || export REVIEWED_HEAD_SHA
  [ -z "${UBERDEV_CARRIER_RUN_DIR:-}" ] || export UBERDEV_CARRIER_RUN_DIR
  [ -z "${STANDALONE_SNAPSHOT_PATH:-}" ] || export STANDALONE_SNAPSHOT_PATH
  [ -z "${PR_NUMBER:-}" ] || export PR_NUMBER
  [ -z "${REVIEW_REPO_SLUG:-}" ] || export REVIEW_REPO_SLUG
}
