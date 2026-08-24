# shellcheck shell=bash
# review-consolidate.sh -- the combine half of /uberdev:review-pr Phase 0 (#470).
#
# WHY THIS FILE EXISTS. `/review-pr` reviews exactly one PR per invocation, so N
# open PRs cost N full pipeline runs -- N x (7-reviewer Phase 1 fanout +
# 3-lens Phase 2 + Phase 3 CI health) -- even when the PRs land together anyway.
# Phase 0 offers, once, to combine every open PR onto one branch and review the
# combined result. The offer is a PROMPT and never a default: consolidating N
# PRs into one loses per-PR revert granularity and per-PR finding attribution,
# and that cost is real enough that only the operator may accept it.
#
# WHY ON DISK AND NOT IN THE FENCE (#404, same precedent as
# lib/review-push-target.sh and lib/review-fleet-args.sh). Two independent
# reasons, either of which is sufficient:
#
#   1. The skill templater substitutes every positional parameter into the
#      rendered command body, fence text included -- `local number="$1"` in a
#      fence arrives as `local number="--no-simplify"`. A helper that takes
#      arguments cannot live in commands/review-pr.md and keep working.
#   2. Every `bash` block in a command file is a FRESH shell. Phase 0's merge
#      loop hands control back to the orchestrator on every conflict (so the
#      Read/Edit/Write tools can resolve it) and resumes in a LATER fence.
#      Nothing defined in fence text is reachable from the next fence.
#
# NARROWING, DECLARED. /merge's Step 2.1 orders its merge queue by hard
# dependency AND by minimising file overlap. This file implements the hard
# dependency half only. Overlap minimisation optimises WHICH candidate hits a
# conflict, not whether the combined result is correct -- Phase 0 resolves the
# conflict either way and the ancestry gate proves nothing was lost. Saying so
# here keeps it a decision rather than an omission somebody later "fixes" by
# copying half of Step 2.1 in.
#
# NO trust-trail emission of any kind. The combined PR is the sole carrier of
# the label + trailer + audit JSON that /merge reads; the originals get one
# supersession comment and nothing else -- no label, no close, no merge. An
# original that also carried a trail could be landed on its own, outside the
# review that actually covered it.

if [ "${_UBERDEV_REVIEW_CONSOLIDATE_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_REVIEW_CONSOLIDATE_LOADED=1

# Resolve this sourced library's plugin root without assuming Bash. zsh exposes
# the current sourced pathname through its prompt-expansion `%x`; Bash exposes
# BASH_SOURCE. The eval keeps zsh-only syntax out of Bash's parser. (Verbatim
# shape from skills/merge-pipeline/lib/discover.sh -- these fences run under
# /bin/zsh in production.)
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_UBERDEV_CONSOLIDATE_SOURCE=${(%):-%x}'
else
  _UBERDEV_CONSOLIDATE_SOURCE="${BASH_SOURCE[0]}"
fi
_UBERDEV_CONSOLIDATE_PLUGIN_ROOT="$(
  cd "$(dirname "$_UBERDEV_CONSOLIDATE_SOURCE")/.." 2>/dev/null && pwd -P
)"

# The closed set of reasons a candidate (or the whole combine) can be reported
# as excluded. Every exclusion is written BY NUMBER into excluded.jsonl and
# rendered into the combined PR body, because "a PR that cannot be combined is
# reported by number and excluded -- never dropped silently" is the acceptance
# criterion this vocabulary exists to make checkable.
#
# DELIBERATELY NOT registered as a #370 contract marker. The marker machinery
# compares N textually-comparable COPIES of one vocabulary and refuses a
# registration with fewer than two sites -- correctly, since a one-site
# "contract" needs no comparator. This vocabulary has exactly one declaration
# and one validator (review_consolidate_reason_valid, below, which reads THIS
# variable rather than restating it), so there is nothing to compare. The
# command file documents the reasons by pointing here instead of listing them,
# which keeps that true. If a second copy ever becomes necessary, register the
# contract then -- do not pre-register a set with one site.
_UBERDEV_CONSOLIDATE_EXCLUSION_REASONS="cross_repo closed_mid_run base_deleted fetch_failed conflict_unresolved ancestry_lost push_refused"

# The closing-keyword ERE. BYTE-IDENTICAL to the one inside
# `# BEGIN merge-issue-cleanup-fence-v4` in skills/merge-pipeline/SKILL.md, and
# tests/review-pr-consolidate.test.sh RCX14 asserts that byte for byte. Two
# copies that drift give two different answers to "which issues does this PR
# close", and the drift stays invisible until an issue silently fails to close
# on merge. The left anchor is the whole subtlety: without it `preclose #99`
# harvests as `close #99`.
UBERDEV_CONSOLIDATE_CLOSING_KEYWORD_ERE='(^|[^[:alnum:]_-])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+'

_uberdev_consolidate_warn() {
  printf 'warning: /uberdev:review-pr Phase 0 — %s\n' "$1" >&2
}

_uberdev_consolidate_error() {
  printf 'error: /uberdev:review-pr Phase 0 — %s\n' "$1" >&2
}

# _uberdev_consolidate_reason_valid REASON -> 0 when REASON is in the enum.
# A typo'd reason would render as an exclusion nobody can route, so it is a
# hard refusal rather than a passthrough.
# Membership WITHOUT word-splitting an unquoted scalar. `for known in $VAR` is a
# bashism: bash splits the scalar on IFS, zsh does not (SH_WORD_SPLIT is off by
# default), so under zsh the loop ran ONCE with the whole reason list as a single
# word and rejected every valid reason -- and these fences run under zsh. The
# padded-haystack `case` behaves identically in both shells and keeps ONE copy of
# the vocabulary, which a hand-written alternation would not.
_uberdev_consolidate_reason_valid() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  case " $_UBERDEV_CONSOLIDATE_EXCLUSION_REASONS " in
    *" $candidate "*) return 0 ;;
  esac
  return 1
}

# review_consolidate_exclude SCAN_DIR NUMBER REASON
# Append one typed exclusion. Idempotent per (number, reason).
review_consolidate_exclude() {
  [ "$#" -eq 3 ] || return 2
  local scan_dir="$1" number="$2" reason="$3"
  [ -d "$scan_dir" ] || return 2
  _uberdev_consolidate_reason_valid "$reason" || {
    _uberdev_consolidate_error "refusing to record an unknown exclusion reason: $reason"
    return 2
  }
  case "$number" in ''|*[!0-9]*) return 2 ;; esac
  local row
  row="$(jq -cn --argjson number "$number" --arg reason "$reason" \
    '{number:$number,reason:$reason}')" || return 2
  if [ -f "$scan_dir/excluded.jsonl" ] \
     && grep -Fqx -- "$row" "$scan_dir/excluded.jsonl" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$row" >>"$scan_dir/excluded.jsonl" || return 2
  _uberdev_consolidate_warn "#$number excluded from the combine: $reason"
  return 0
}

# review_consolidate_excluded_numbers SCAN_DIR -> one excluded PR number per line.
#
# NOT `jq ... | sort -un`. A command substitution around that pipeline takes the
# status of `sort`, which succeeds on empty input, so a `jq` that CRASHED on a
# truncated or half-written excluded.jsonl reported rc 0 and the empty set --
# and the empty set is "nothing was excluded", which puts every excluded
# candidate straight back into the combine. That is the same fail-OPEN shape as
# the staged-set guard in review_consolidate_continue and it is fixed the same
# way: a producer whose own status is checked into a variable, then a `sort`
# whose own status is checked. rc 2 means UNKNOWN and never "none".
#
# The absent/empty file keeps returning 0 with no output, because there it is
# not an unknown: nothing has been excluded yet.
review_consolidate_excluded_numbers() {
  local scan_dir="${1:-}" raw
  [ -s "$scan_dir/excluded.jsonl" ] || return 0
  raw="$(jq -r '.number' <"$scan_dir/excluded.jsonl")" || {
    _uberdev_consolidate_error "the exclusion record at $scan_dir/excluded.jsonl is unreadable; refusing to report it as an empty exclusion set"
    return 2
  }
  [ -n "$raw" ] || return 0
  sort -un <<<"$raw" || return 2
}

# review_consolidate_survivors SCAN_DIR -> the candidate array minus exclusions.
review_consolidate_survivors() {
  local scan_dir="${1:-}"
  [ -s "$scan_dir/candidates.json" ] || { printf '[]\n'; return 0; }
  # Same rule as the producer above, one level out: the old
  # `"$(excluded_numbers | jq | jq -sc '.')" || dropped='[]'` bound its `||` to
  # the LAST jq, which emits `[]` and exits 0 on empty input -- so a producer
  # that failed and a repo with no exclusions arrived here as the same value,
  # and the fallback then wrote that fail-open answer down as if it were a
  # decision. Each stage is checked on its own, and an unreadable exclusion
  # record refuses instead of silently widening the survivor set.
  local dropped excluded_numbers numeric
  excluded_numbers="$(review_consolidate_excluded_numbers "$scan_dir")" || return 2
  numeric="$(jq -R 'tonumber?' <<<"$excluded_numbers")" || return 2
  dropped="$(jq -sc '.' <<<"$numeric")" || return 2
  # No empty-string fallback for $dropped: the line above returns 2 on any
  # non-zero jq, and `jq -sc '.'` writes an array -- `[]` at minimum -- on every
  # zero exit, so the empty case a fallback would cover cannot occur.
  jq -c --argjson dropped "$dropped" \
    '[ .[] | select((.number as $n | $dropped | index($n)) == null) ]' \
    <"$scan_dir/candidates.json" 2>/dev/null || printf '[]\n'
}

# review_consolidate_included SCAN_DIR -> the numbers that are in the combine.
# `included.txt` is the ordered list the merge loop actually merged; before the
# loop has run, every survivor is still a candidate for inclusion. Reading the
# recorded list FIRST matters: after the loop, a survivor that was never reached
# (the loop aborted) must not be reported as included.
review_consolidate_included() {
  local scan_dir="${1:-}"
  if [ -s "$scan_dir/included.txt" ]; then
    sort -un <"$scan_dir/included.txt"
    return 0
  fi
  review_consolidate_survivors "$scan_dir" | jq -r '.[].number' 2>/dev/null | sort -un
}

# _uberdev_consolidate_field SCAN_DIR NUMBER FIELD -> one candidate field.
_uberdev_consolidate_field() {
  local scan_dir="$1" number="$2" field="$3"
  [ -s "$scan_dir/candidates.json" ] || return 1
  jq -r --argjson number "$number" --arg field "$field" \
    'map(select(.number == $number)) | .[0][$field] // empty' \
    <"$scan_dir/candidates.json" 2>/dev/null
}

# --------------------------------------------------------------------------
# review_consolidate_preflight WORKTREE SCAN_DIR
#
# rc 0  the checkout may be combined in; the ORIGINAL BRANCH NAME is recorded.
# rc 2  refused, nothing mutated.
#
# The combine happens in the operator's live checkout on purpose: the run's own
# `review_assert_selected_pr_head` gate compares the selected PR's head to LOCAL
# HEAD later, so a combine built anywhere else would fail that gate. That makes
# this the one place where /review-pr mutates a tree the operator is standing
# in, and it must refuse rather than steamroll.
#
# The recorded artefact is the BRANCH NAME, never `git checkout -`. `-` names
# the previous checkout, which the combine's own intermediate checkouts have
# already overwritten by the time a restore is needed.
# --------------------------------------------------------------------------
review_consolidate_preflight() {
  [ "$#" -eq 2 ] || return 2
  local worktree="$1" scan_dir="$2"
  [ -d "$worktree" ] || { _uberdev_consolidate_error "worktree does not exist: $worktree"; return 2; }
  mkdir -p "$scan_dir" || return 2

  local git_dir
  git_dir="$(git -C "$worktree" rev-parse --git-dir 2>/dev/null)" || {
    _uberdev_consolidate_error "not a git checkout: $worktree"
    return 2
  }
  case "$git_dir" in
    /*) : ;;
    *) git_dir="$worktree/$git_dir" ;;
  esac

  local porcelain
  porcelain="$(git -C "$worktree" status --porcelain 2>/dev/null)" || {
    _uberdev_consolidate_error "could not read the working-tree status of $worktree"
    return 2
  }
  if [ -n "$porcelain" ]; then
    _uberdev_consolidate_error "the working tree is not clean; refusing to build a combine branch over uncommitted work"
    return 2
  fi

  local marker
  for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do
    if [ -e "$git_dir/$marker" ]; then
      _uberdev_consolidate_error "an operation is already in progress ($marker present); refusing to start a combine"
      return 2
    fi
  done
  if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    _uberdev_consolidate_error "a rebase is already in progress; refusing to start a combine"
    return 2
  fi

  local branch
  branch="$(git -C "$worktree" symbolic-ref -q --short HEAD 2>/dev/null)" || branch=""
  if [ -z "$branch" ]; then
    _uberdev_consolidate_error "HEAD is detached; there is no branch to restore to if the combine aborts"
    return 2
  fi

  # FIRST entry only. `## 0c — COMBINE` is re-entered after every resolved
  # conflict, and by then HEAD is legitimately the combine branch — recording it
  # again would overwrite the operator's real branch with the branch the abort
  # path is about to delete, leaving nothing to restore to. The first recorded
  # value is the true one; a later entry must not be able to move it.
  if [ ! -s "$scan_dir/origin-branch.txt" ]; then
    printf '%s\n' "$branch" >"$scan_dir/origin-branch.txt" || return 2
  fi
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_current_pr SCAN_DIR
#
# The number of the PR whose branch the operator invoked /review-pr on, which
# `review_consolidate_assert_current` needs to prove the combine contains it.
#
# It cannot be re-derived from HEAD on re-entry: 0c is re-entered after every
# resolved conflict and HEAD is the combine branch by then, which has no PR. A
# bare `gh pr view` there returns empty, and an empty number reaches
# assert_current as "not in the combine" — aborting a sound combine and blaming
# `current_pr_excluded` for what was really a failed probe. So it is resolved
# once, while HEAD is still the invoking branch, and carried on disk like every
# other value that has to cross a fence boundary.
#
# Fails CLOSED: rc 2 and no output rather than an empty string, because the
# empty string is exactly the value that produced the misleading abort.
# --------------------------------------------------------------------------
review_consolidate_current_pr() {
  [ "$#" -eq 1 ] || return 2
  local scan_dir="$1" recorded="" number=""
  if [ -s "$scan_dir/current-pr.txt" ]; then
    recorded="$(cat "$scan_dir/current-pr.txt" 2>/dev/null)" || recorded=""
    case "$recorded" in
      ''|*[!0-9]*)
        _uberdev_consolidate_error "the recorded invoking PR '$recorded' is not a number; refusing to guess which PR is being reviewed"
        return 2
        ;;
      *) printf '%s\n' "$recorded"; return 0 ;;
    esac
  fi
  number="$(gh pr view --json number -q .number 2>/dev/null)" || number=""
  case "$number" in
    ''|*[!0-9]*)
      _uberdev_consolidate_error "could not resolve the pull request for the current branch; the combine cannot prove it contains the PR being reviewed"
      return 2
      ;;
  esac
  printf '%s\n' "$number" >"$scan_dir/current-pr.txt" || return 2
  printf '%s\n' "$number"
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_refresh SCAN_DIR REPO_OWNER
#
# Re-read every candidate's LIVE state immediately before the combine. The scan
# that produced candidates.json may be many turns old (the operator was asked a
# question in between), and a PR that closed, lost its base branch, or turns out
# to live in a fork must be excluded BY NUMBER rather than discovered as a git
# error halfway through the merge loop.
# --------------------------------------------------------------------------
review_consolidate_refresh() {
  [ "$#" -eq 2 ] || return 2
  local scan_dir="$1" repo_owner="$2"
  [ -s "$scan_dir/candidates.json" ] || return 2

  local numbers number live
  numbers="$(jq -r '.[].number' <"$scan_dir/candidates.json" 2>/dev/null)" || return 2
  local refreshed="$scan_dir/candidates.refreshed.json"
  printf '[]\n' >"$refreshed" || return 2

  # `while IFS= read -r` and not `for n in $numbers`: the producer emits one
  # number per LINE, and splitting an unquoted scalar on IFS is a bashism --
  # zsh leaves it as a single word, so the loop ran once over the whole list.
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    live="$(gh pr view "$number" \
      --json number,title,headRefOid,headRefName,baseRefName,state,body,headRepositoryOwner \
      --jq '.' 2>/dev/null)" || live=""
    if [ -z "$live" ]; then
      # Unreadable is NOT "closed": it is unknown. Excluding it keeps the
      # combine honest, and the reason names the observation rather than a
      # guess about the cause.
      review_consolidate_exclude "$scan_dir" "$number" "closed_mid_run"
      continue
    fi
    local owner state base
    owner="$(jq -r '.headRepositoryOwner.login // empty' <<<"$live" 2>/dev/null)"
    state="$(jq -r '.state // empty' <<<"$live" 2>/dev/null)"
    base="$(jq -r '.baseRefName // empty' <<<"$live" 2>/dev/null)"
    if [ -n "$owner" ] && [ "$owner" != "$repo_owner" ]; then
      review_consolidate_exclude "$scan_dir" "$number" "cross_repo"
      continue
    fi
    if [ "$state" != "OPEN" ]; then
      review_consolidate_exclude "$scan_dir" "$number" "closed_mid_run"
      continue
    fi
    if [ -z "$base" ]; then
      review_consolidate_exclude "$scan_dir" "$number" "base_deleted"
      continue
    fi
    local merged
    merged="$(jq -sc --argjson live "$live" '.[0] + [$live]' "$refreshed" 2>/dev/null)" || return 2
    printf '%s\n' "$merged" >"$refreshed" || return 2
  done <<EOF_CONSOLIDATE_NUMBERS
$numbers
EOF_CONSOLIDATE_NUMBERS

  mv "$refreshed" "$scan_dir/candidates.json" || return 2
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_base SCAN_DIR DEFAULT_BRANCH -> the combine's base branch.
#
# The MODAL base among survivors, ties broken by the repository default. A
# candidate on some other base is NOT excluded for that: git's per-pair
# merge-base handles it, and excluding it would hide from the operator exactly
# the cross-base set the offer exists to make visible.
# --------------------------------------------------------------------------
review_consolidate_base() {
  [ "$#" -eq 2 ] || return 2
  local scan_dir="$1" default_branch="$2"
  local survivors modal
  survivors="$(review_consolidate_survivors "$scan_dir")" || return 2
  modal="$(jq -r --arg fallback "$default_branch" '
      [ .[] | .baseRefName | select(. != null and . != "") ]
      | if length == 0 then $fallback
        else
          ( group_by(.) | map({base: .[0], n: length}) ) as $tally
          | ($tally | map(.n) | max) as $top
          | ($tally | map(select(.n == $top))) as $winners
          | if ($winners | length) == 1 then $winners[0].base else $fallback end
        end
    ' <<<"$survivors" 2>/dev/null)" || return 2
  [ -n "$modal" ] || modal="$default_branch"
  printf '%s\n' "$modal" >"$scan_dir/base.txt" || return 2
  printf '%s\n' "$modal"
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_order SCAN_DIR -> the merge order, one number per line.
#
# Hard-dependency edges first (a candidate whose baseRefName is another
# candidate's headRefName, plus `Depends on #N` in the body), topologically
# sorted, then createdAt ascending. A cycle is broken deterministically and
# named on stderr -- it is a malformed graph, not a run-ending failure, exactly
# as merge-pipeline Step 2.1 treats it.
# --------------------------------------------------------------------------
review_consolidate_order() {
  [ "$#" -eq 1 ] || return 2
  local scan_dir="$1"
  local survivors
  survivors="$(review_consolidate_survivors "$scan_dir")" || return 2
  local ordered
  ordered="$(python3 -I -B -c '
import json
import re
import sys

candidates = json.loads(sys.argv[1])
by_number = {}
for candidate in candidates:
    number = candidate.get("number")
    if isinstance(number, int):
        by_number[number] = candidate

heads = {}
for number, candidate in by_number.items():
    head = candidate.get("headRefName")
    if isinstance(head, str) and head:
        heads.setdefault(head, number)

DEPENDS = re.compile(r"depends on\s+#([0-9]+)", re.I)

edges = {number: set() for number in by_number}
for number, candidate in by_number.items():
    base = candidate.get("baseRefName")
    parent = heads.get(base) if isinstance(base, str) else None
    if parent is not None and parent != number:
        edges[number].add(parent)
    body = candidate.get("body") or ""
    for match in DEPENDS.finditer(body):
        parent = int(match.group(1))
        if parent in by_number and parent != number:
            edges[number].add(parent)


def sort_key(number):
    created = by_number[number].get("createdAt") or ""
    return (created, number)


pending = sorted(by_number, key=sort_key)
emitted = []
done = set()
while pending:
    ready = [n for n in pending if edges[n] <= done]
    if not ready:
        # Deterministic cycle break: the oldest member of the stuck set goes
        # first, and the cycle is NAMED rather than silently linearised.
        ready = [pending[0]]
        print(
            "warning: /uberdev:review-pr Phase 0 - dependency cycle among "
            + " ".join("#%d" % n for n in pending)
            + "; breaking it at #%d" % ready[0],
            file=sys.stderr,
        )
    for number in ready:
        emitted.append(number)
        done.add(number)
        pending.remove(number)

for number in emitted:
    print(number)
' "$survivors")" || return 2
  printf '%s\n' "$ordered" >"$scan_dir/order.txt" || return 2
  printf '%s\n' "$ordered"
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_fetch WORKTREE SCAN_DIR
#
# The merge loop merges OIDs. In a checkout that only tracks the integration
# branch those objects are simply absent, and `git merge <oid>` fails with "not
# something we can merge" -- a git error nobody classified, on a candidate that
# was never even reported. One explicit fetch per candidate, and an unfetchable
# candidate is a typed exclusion, not an abort.
# --------------------------------------------------------------------------
review_consolidate_fetch() {
  [ "$#" -eq 2 ] || return 2
  local worktree="$1" scan_dir="$2"
  local survivors numbers number head oid
  survivors="$(review_consolidate_survivors "$scan_dir")" || return 2
  numbers="$(jq -r '.[].number' <<<"$survivors" 2>/dev/null)" || return 2
  # `while IFS= read -r` and not `for n in $numbers`: the producer emits one
  # number per LINE, and splitting an unquoted scalar on IFS is a bashism --
  # zsh leaves it as a single word, so the loop ran once over the whole list.
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    head="$(_uberdev_consolidate_field "$scan_dir" "$number" headRefName)"
    oid="$(_uberdev_consolidate_field "$scan_dir" "$number" headRefOid)"
    if [ -z "$head" ]; then
      review_consolidate_exclude "$scan_dir" "$number" "fetch_failed"
      continue
    fi
    if ! git -C "$worktree" fetch --no-tags --quiet origin "$head" 2>/dev/null; then
      review_consolidate_exclude "$scan_dir" "$number" "fetch_failed"
      continue
    fi
    # The fetch succeeding is not proof the RECORDED oid arrived: the branch may
    # have moved since the scan. Verify the exact object the combine will merge.
    if [ -n "$oid" ] && ! git -C "$worktree" cat-file -e "$oid^{commit}" 2>/dev/null; then
      review_consolidate_exclude "$scan_dir" "$number" "fetch_failed"
      continue
    fi
  done <<EOF_CONSOLIDATE_NUMBERS
$numbers
EOF_CONSOLIDATE_NUMBERS
  return 0
}

# _uberdev_consolidate_unmerged WORKTREE TARGET
# THE enumerator, reached through review_fleet_unmerged_paths -> the
# `list-ci-unmerged-paths` verb, which covers every porcelain unmerged pair
# (DD AU UD UA DU AA UU). A hand-rolled `UU` match is the #398 defect: an
# add/add conflict records `AA`, enumerated as the empty set, which makes
# "everything is resolved" vacuously true.
#   rc 0 = >=1 conflicted path written NUL-delimited to TARGET
#   rc 1 = the probe succeeded and there are none
#   rc 2 = the probe itself FAILED -- which must abort, never map to "none".
_uberdev_consolidate_unmerged() {
  local worktree="$1" target="$2"
  if ! command -v review_fleet_unmerged_paths >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_UBERDEV_CONSOLIDATE_PLUGIN_ROOT/lib/review-fleet-args.sh" 2>/dev/null || return 2
  fi
  command -v review_fleet_unmerged_paths >/dev/null 2>&1 || return 2
  review_fleet_unmerged_paths "$worktree" \
    "$_UBERDEV_CONSOLIDATE_PLUGIN_ROOT/lib/code_fixer_contract.py" "$target"
}

# --------------------------------------------------------------------------
# review_consolidate_merge_one WORKTREE SCAN_DIR NUMBER
#
# rc 0   merged cleanly and recorded as included
# rc 75  CONFLICT. The conflicted paths are in <scan_dir>/conflicts-<number>.txt
#        (NUL-delimited) and the merge is left IN PROGRESS for the orchestrator
#        to resolve with Read/Edit/Write, then finish via
#        review_consolidate_continue. 75 is a typed code so a conflict cannot be
#        confused with a tooling failure.
# rc 2   the merge could not even be attempted, or the conflict enumeration
#        itself failed. The merge is aborted before returning.
# --------------------------------------------------------------------------
review_consolidate_merge_one() {
  [ "$#" -eq 3 ] || return 2
  local worktree="$1" scan_dir="$2" number="$3"
  case "$number" in ''|*[!0-9]*) return 2 ;; esac
  local oid
  oid="$(_uberdev_consolidate_field "$scan_dir" "$number" headRefOid)"
  if [ -z "$oid" ]; then
    _uberdev_consolidate_error "#$number has no recorded head OID; refusing to merge an unidentified commit"
    return 2
  fi

  if git -C "$worktree" merge --no-ff --no-edit "$oid" >/dev/null 2>&1; then
    printf '%s\n' "$number" >>"$scan_dir/included.txt"
    return 0
  fi

  local conflicts="$scan_dir/conflicts-$number.txt"
  _uberdev_consolidate_unmerged "$worktree" "$conflicts"
  local probe_rc=$?
  case "$probe_rc" in
    0)
      # Record what the merge had ALREADY staged when it stopped. The CONTINUE
      # boundary needs it: an auto-merged file is legitimately staged and is not
      # in the conflict list, so "staged set must equal the conflict list" would
      # be wrong while "staged set must not GROW beyond it" is exactly right.
      git -C "$worktree" diff --cached --name-only \
        >"$scan_dir/staged-at-conflict-$number.txt" 2>/dev/null || :
      return 75
      ;;
    1)
      # The merge failed but nothing is unmerged: not a content conflict (an
      # unrelated-histories refusal, an unreadable object, a hook). Leaving a
      # half-started merge behind would poison every later candidate.
      git -C "$worktree" merge --abort >/dev/null 2>&1 || :
      _uberdev_consolidate_error "#$number could not be merged and reported no conflicted paths"
      review_consolidate_exclude "$scan_dir" "$number" "conflict_unresolved"
      return 2
      ;;
    *)
      git -C "$worktree" merge --abort >/dev/null 2>&1 || :
      _uberdev_consolidate_error "#$number: the conflicted-path enumeration itself failed; refusing to treat that as 'no conflicts'"
      return 2
      ;;
  esac
}

# _uberdev_consolidate_path_allowed CONFLICTS_FILE CANDIDATE_PATH
_uberdev_consolidate_path_allowed() {
  local conflicts="$1" candidate="$2" entry
  [ -s "$conflicts" ] || return 1
  while IFS= read -r -d '' entry; do
    [ "$entry" = "$candidate" ] && return 0
  done <"$conflicts"
  return 1
}

# --------------------------------------------------------------------------
# review_consolidate_continue WORKTREE SCAN_DIR NUMBER PATH...
#
# THE SAFETY BOUNDARY of the whole feature. Conflict resolution is done by an
# agent with Edit/Write; this function is what keeps that agent inside the set
# the ENUMERATOR produced.
#
#   * refuses to stage any path that is not in conflicts-<number>.txt
#   * refuses to stage a file that still carries conflict markers -- `git add`
#     RESOLVES a conflict as far as git is concerned, so staging a
#     marker-laden file would let `git merge --continue` commit the markers and
#     report success
#   * refuses to continue while the enumerator still reports unmerged paths, and
#     treats an enumeration FAILURE as a refusal rather than as "none left"
#   * refuses if the staged set grew beyond (what the merge staged by itself) +
#     (the conflicted paths)
#
# rc 0 merge completed; rc 2 refused (the merge stays in progress, unchanged).
# --------------------------------------------------------------------------
review_consolidate_continue() {
  [ "$#" -ge 3 ] || return 2
  local worktree="$1" scan_dir="$2" number="$3"
  shift 3
  case "$number" in ''|*[!0-9]*) return 2 ;; esac
  local conflicts="$scan_dir/conflicts-$number.txt"
  if [ ! -s "$conflicts" ]; then
    _uberdev_consolidate_error "#$number: no recorded conflict set; refusing to stage anything"
    return 2
  fi

  local candidate
  for candidate in "$@"; do
    if ! _uberdev_consolidate_path_allowed "$conflicts" "$candidate"; then
      _uberdev_consolidate_error "#$number: '$candidate' is not one of the enumerated conflicted paths; refusing to stage it"
      return 2
    fi
    if [ ! -f "$worktree/$candidate" ]; then
      _uberdev_consolidate_error "#$number: '$candidate' does not exist in the worktree"
      return 2
    fi
    if grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$worktree/$candidate" 2>/dev/null; then
      _uberdev_consolidate_error "#$number: '$candidate' still carries conflict markers; staging it would commit them as resolved"
      return 2
    fi
  done

  for candidate in "$@"; do
    git -C "$worktree" add -- "$candidate" || return 2
  done

  local probe="$scan_dir/unmerged-after-$number.txt"
  _uberdev_consolidate_unmerged "$worktree" "$probe"
  local probe_rc=$?
  case "$probe_rc" in
    1) : ;;
    0)
      _uberdev_consolidate_error "#$number: unmerged paths remain; refusing to complete the merge"
      return 2
      ;;
    *)
      _uberdev_consolidate_error "#$number: the unmerged-path probe failed; refusing to complete a merge whose state is unknown"
      return 2
      ;;
  esac

  # The staged set may not have grown past what the merge itself staged plus the
  # conflicted paths.
  local allowed_raw allowed staged_raw staged extra
  # NEITHER LIST MAY BE PRODUCED BY A PIPELINE. `X="$(<producer> | LC_ALL=C
  # sort -u)"` hands the ASSIGNMENT the status of `sort`, and `sort` succeeds on
  # empty input -- so a producer that FAILED is indistinguishable from one that
  # had nothing to say. On the staged half that is the fail-OPEN direction and it
  # disarms this guard completely: under index.lock contention from a concurrent
  # agent, a corrupt index, or a `$worktree` that moved under the function, the
  # `git diff --cached` fails, `staged` is empty, the comparison finds nothing,
  # `extra` is empty, and `git merge --continue` commits a staged set NOTHING
  # examined -- the exact fail-open this guard exists to prevent, inside the
  # guard itself. Worse, the two halves fail in OPPOSITE directions under the
  # identical shape: an empty `allowed` makes every staged path extra (loud,
  # closed) while an empty `staged` makes none (silent, open), so the half that
  # matters is the half that looks fine. Both are therefore written the same
  # way, and so is the comparison: a producer whose OWN status is checked into a
  # variable, THEN a `sort` (and then a `comm`) whose OWN status is checked.
  # Stderr is not discarded on the producers either -- a guard that refuses has
  # to be able to say what it could not read.
  #
  # The one deliberate tolerance is `cat` on staged-at-conflict-<number>.txt:
  # review_consolidate_merge_one writes it best-effort, and an absent or short
  # file can only SHRINK `allowed`, which can only turn a path into an extra and
  # refuse. That direction is the closed one, so it stays a `|| :` rather than
  # becoming a refusal on a record that was never load-bearing.
  #
  # LC_ALL=C ON EVERY MEMBER OF THE sort/comm TRIO, INCLUDING `comm` ITSELF.
  # This guard compares PATHS AS BYTES. `sort` orders by the ambient collation
  # and `comm`'s merge walk assumes the order its own collation would produce;
  # when the two disagree the walk desynchronises and reports a path present in
  # BOTH lists as extra -- refusing a merge whose staged set was correct. That
  # consequence is not theoretical: feed `comm -13` two lists holding the SAME
  # three paths in two different orders and it names one of them as extra.
  # The two sorts share a shell today and so agree by accident; pinning makes
  # the guard's correctness a property of the code rather than of whatever
  # LC_ALL / LC_COLLATE / LANG the operator's shell happened to inherit, which
  # varies by platform -- and this guard runs on every platform UberDev does.
  allowed_raw="$(
    { cat "$scan_dir/staged-at-conflict-$number.txt" 2>/dev/null || :; tr '\0' '\n' <"$conflicts"; }
  )" || {
    _uberdev_consolidate_error "#$number: could not read the enumerated conflict set; refusing to complete a merge whose allowed set is unknown"
    return 2
  }
  allowed="$(LC_ALL=C sort -u <<<"$allowed_raw")" || {
    _uberdev_consolidate_error "#$number: could not order the allowed set; refusing to complete a merge whose allowed set is unknown"
    return 2
  }
  staged_raw="$(git -C "$worktree" diff --cached --name-only)" || {
    _uberdev_consolidate_error "#$number: could not read the staged set; refusing to complete a merge whose staged set is unknown"
    return 2
  }
  staged="$(LC_ALL=C sort -u <<<"$staged_raw")" || {
    _uberdev_consolidate_error "#$number: could not order the staged set; refusing to complete a merge whose staged set is unknown"
    return 2
  }
  extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$allowed") <(printf '%s\n' "$staged"))" || {
    _uberdev_consolidate_error "#$number: the staged-set comparison itself failed; refusing to complete a merge whose staged set is unverified"
    return 2
  }
  if [ -n "$extra" ]; then
    _uberdev_consolidate_error "#$number: the staged set grew beyond the merge's own set plus the conflicted paths: $(tr '\n' ' ' <<<"$extra")"
    return 2
  fi

  GIT_EDITOR=true git -C "$worktree" merge --continue >/dev/null 2>&1 || {
    _uberdev_consolidate_error "#$number: git merge --continue failed"
    return 2
  }
  printf '%s\n' "$number" >>"$scan_dir/included.txt"
  return 0
}

# review_consolidate_abandon WORKTREE SCAN_DIR NUMBER
# The other half of CONTINUE: give up on this candidate without giving up on the
# combine. `git merge --abort` restores the pre-merge state, and the candidate is
# reported by number.
review_consolidate_abandon() {
  [ "$#" -eq 3 ] || return 2
  local worktree="$1" scan_dir="$2" number="$3"
  git -C "$worktree" merge --abort >/dev/null 2>&1 || :
  review_consolidate_exclude "$scan_dir" "$number" "conflict_unresolved"
}

# review_consolidate_start_branch WORKTREE SCAN_DIR BASE BRANCH
# Fetch the combine's base and cut the combine branch from it. The fetch lives
# HERE rather than in fence text for the same first-match-scan reason
# review_consolidate_push_branch documents: commands/review-pr.md's Phase 3
# ordering assertions are located by scanning the whole file for the FIRST
# `git … fetch origin` line, and a Phase 0 fence carrying one would re-point
# them above the gate they exist to sit below.
review_consolidate_start_branch() {
  [ "$#" -eq 4 ] || return 2
  local worktree="$1" scan_dir="$2" base="$3" branch="$4"
  git -C "$worktree" check-ref-format --branch "$branch" >/dev/null 2>&1 || {
    _uberdev_consolidate_error "refusing to create a branch with an unusable name: $branch"
    return 2
  }
  # RESUME, not re-create. 0c is re-entered after every resolved conflict, so on
  # the second and later entries the combine branch already exists and carries
  # the merges made so far — `checkout -b` would fail 'already exists' and take
  # the whole combine down with it. The arm is keyed to combine-branch.txt, this
  # scan's OWN record that it created this branch, so a collision with a branch
  # somebody else owns still hits the refusal below. Checkout only: re-cutting
  # it from the base here would silently discard every resolved merge.
  if [ -s "$scan_dir/combine-branch.txt" ] \
     && [ "$(cat "$scan_dir/combine-branch.txt" 2>/dev/null)" = "$branch" ] \
     && git -C "$worktree" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$worktree" checkout -q "$branch" || {
      _uberdev_consolidate_error "could not resume the combine branch $branch"
      return 2
    }
    return 0
  fi
  git -C "$worktree" fetch --no-tags --quiet origin "$base" 2>/dev/null || {
    _uberdev_consolidate_error "could not fetch the combine base '$base' from origin"
    return 2
  }
  git -C "$worktree" checkout -q -b "$branch" FETCH_HEAD || {
    _uberdev_consolidate_error "could not create the combine branch $branch"
    return 2
  }
  printf '%s\n' "$branch" >"$scan_dir/combine-branch.txt" || return 2
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_drive WORKTREE SCAN_DIR
#
# The merge loop, resumable. It walks order.txt, skipping anything already
# included or already excluded, and stops at the FIRST conflict — recording the
# number in pending-conflict.txt and returning 75 so the orchestrator can hand
# the conflicted files to Read/Edit/Write and then re-enter through
# review_consolidate_continue. Re-entry calls this function again; the
# already-done skip is what makes that safe.
#
# rc 0 every candidate is in; rc 75 stopped at a conflict; rc 2 fatal.
# --------------------------------------------------------------------------
review_consolidate_drive() {
  [ "$#" -eq 2 ] || return 2
  local worktree="$1" scan_dir="$2"
  [ -s "$scan_dir/order.txt" ] || {
    _uberdev_consolidate_error "no merge order recorded; review_consolidate_order must run first"
    return 2
  }
  local number done_numbers dropped
  # included.txt is legitimately ABSENT on the first entry -- that is the "no
  # candidate is done yet" answer and not a failure -- so the absence is tested
  # for rather than inferred from a swallowed `sort` status. Once the file does
  # exist, a `sort` that fails is an unknown skip-set, and an unknown skip-set
  # silently re-merges candidates the loop already placed.
  done_numbers=""
  if [ -s "$scan_dir/included.txt" ]; then
    done_numbers="$(sort -un <"$scan_dir/included.txt")" || {
      _uberdev_consolidate_error "could not read the already-included set; refusing to walk the merge order without it"
      return 2
    }
  fi
  dropped="$(review_consolidate_excluded_numbers "$scan_dir")" || return 2
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    case "
$done_numbers
$dropped
" in
      *"
$number
"*) continue ;;
    esac
    review_consolidate_merge_one "$worktree" "$scan_dir" "$number"
    case "$?" in
      0) : ;;
      75)
        printf '%s\n' "$number" >"$scan_dir/pending-conflict.txt"
        return 75
        ;;
      *) return 2 ;;
    esac
  done <"$scan_dir/order.txt"
  rm -f "$scan_dir/pending-conflict.txt"
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_finish WORKTREE SCAN_DIR REPO_SLUG PR_NUMBER BRANCH BASE SCAN_ID
#
# The tail, in the one order the invariants allow: prove nothing was lost, prove
# the invoking PR survived, only then publish. Any refusal restores the recorded
# branch, deletes the combine branch and pushes NOTHING — a combined PR that
# does not contain the PR the operator invoked /review-pr on is worse than no
# combined PR at all.
#
# Stdout: the combined PR number. rc 0 published; rc 2 refused/failed.
# --------------------------------------------------------------------------
review_consolidate_finish() {
  [ "$#" -eq 7 ] || return 2
  local worktree="$1" scan_dir="$2" repo_slug="$3" pr_number="$4"
  local branch="$5" base="$6" scan_id="$7"

  if ! review_consolidate_assert_ancestry "$worktree" "$scan_dir"; then
    printf '%s\n' "ancestry_lost" >"$scan_dir/failure-reason.txt"
    review_consolidate_abort "$worktree" "$scan_dir" || :
    return 2
  fi
  if ! review_consolidate_assert_current "$scan_dir" "$pr_number"; then
    printf '%s\n' "current_pr_excluded" >"$scan_dir/failure-reason.txt"
    review_consolidate_abort "$worktree" "$scan_dir" || :
    return 2
  fi
  review_consolidate_push_branch "$worktree" "$scan_dir" "$repo_slug" "$pr_number" "$branch"
  case "$?" in
    0) : ;;
    *)
      review_consolidate_abort "$worktree" "$scan_dir" || :
      return 2
      ;;
  esac
  local combined
  combined="$(review_consolidate_open_pr "$worktree" "$scan_dir" "$base" "$branch")" || return 2
  review_consolidate_comment_originals "$scan_dir" "$combined" || :
  review_consolidate_manifest "$scan_dir" "$scan_id" "$branch" "$combined" "$base" || return 2
  printf '%s\n' "$combined"
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_assert_ancestry WORKTREE SCAN_DIR
#
# THE gate that catches a lossy resolution, and the only one. The run's existing
# `review_assert_selected_pr_head` proves "the PR's head equals local HEAD" --
# which a combine that quietly dropped a candidate's commit satisfies just as
# well, because the branch it pushed IS the branch it built. Ancestry is the
# question that distinguishes them: every included candidate's head must be
# reachable from the combined HEAD.
# --------------------------------------------------------------------------
review_consolidate_assert_ancestry() {
  [ "$#" -eq 2 ] || return 2
  local worktree="$1" scan_dir="$2"
  local numbers number oid lost=0
  numbers="$(review_consolidate_included "$scan_dir")"
  if [ -z "$numbers" ]; then
    _uberdev_consolidate_error "the combine included no candidates; there is nothing to review as a consolidation"
    return 2
  fi
  # `while IFS= read -r` and not `for n in $numbers`: the producer emits one
  # number per LINE, and splitting an unquoted scalar on IFS is a bashism --
  # zsh leaves it as a single word, so the loop ran once over the whole list.
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    oid="$(_uberdev_consolidate_field "$scan_dir" "$number" headRefOid)"
    if [ -z "$oid" ]; then
      _uberdev_consolidate_error "#$number has no recorded head OID; its presence in the combine cannot be proven"
      review_consolidate_exclude "$scan_dir" "$number" "ancestry_lost"
      lost=1
      continue
    fi
    if ! git -C "$worktree" merge-base --is-ancestor "$oid" HEAD 2>/dev/null; then
      _uberdev_consolidate_error "#$number's head is NOT an ancestor of the combined HEAD — its change is not in the combine"
      review_consolidate_exclude "$scan_dir" "$number" "ancestry_lost"
      lost=1
    fi
  done <<EOF_CONSOLIDATE_NUMBERS
$numbers
EOF_CONSOLIDATE_NUMBERS
  [ "$lost" -eq 0 ] || return 2
  return 0
}

# review_consolidate_assert_current SCAN_DIR PR_NUMBER
# The current branch's own PR must survive into the combine. If it did not, the
# run has no honest way to continue: reviewing the combined branch would report
# a trust signal for a change set that does not contain the PR the operator
# invoked /review-pr on. Never downgrade to a single-PR review -- the operator
# accepted a consolidation, and silently doing something else is worse than
# stopping.
review_consolidate_assert_current() {
  [ "$#" -eq 2 ] || return 2
  local scan_dir="$1" pr_number="$2"
  case "$pr_number" in ''|*[!0-9]*) return 2 ;; esac
  local number
  for number in $(review_consolidate_included "$scan_dir"); do
    [ "$number" = "$pr_number" ] && return 0
  done
  _uberdev_consolidate_error "the current branch's PR #$pr_number is not in the combine; refusing to review a change set that excludes it"
  return 2
}

# review_consolidate_abort WORKTREE SCAN_DIR
# Restore the RECORDED branch and delete the half-built combine branch. Leaving
# a partial combine behind would leave the operator standing on a branch nobody
# reviewed, whose name suggests otherwise.
review_consolidate_abort() {
  [ "$#" -eq 2 ] || return 2
  local worktree="$1" scan_dir="$2"
  local original current
  original="$(cat "$scan_dir/origin-branch.txt" 2>/dev/null)"
  if [ -z "$original" ]; then
    _uberdev_consolidate_error "no recorded original branch; refusing to guess where to restore the checkout to"
    return 2
  fi
  git -C "$worktree" merge --abort >/dev/null 2>&1 || :
  current="$(git -C "$worktree" symbolic-ref -q --short HEAD 2>/dev/null)" || current=""
  git -C "$worktree" checkout -q "$original" || {
    _uberdev_consolidate_error "could not restore the checkout to $original"
    return 2
  }
  if [ -n "$current" ] && [ "$current" != "$original" ]; then
    git -C "$worktree" branch -D "$current" >/dev/null 2>&1 || :
  fi
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_push_branch WORKTREE SCAN_DIR REPO_SLUG PR_NUMBER BRANCH
#
# rc 0   pushed
# rc 78  refused: the invoking PR's head lives in another repository, so this
#        run cannot publish a branch to `origin` on its behalf
# rc 79  the identity could not be established -- halt rather than guess
# rc 2   the push itself failed
#
# The same-repository question is asked INSIDE this library, never in fence
# text: commands/review-pr.md's Phase 3 assertions are located by first-match
# scans over the whole file, and a Phase 0 fence naming the resolver would
# silently re-point them at the wrong fence.
#
# Plain `git push -u origin <branch>`: the combine branch is new, so there is
# nothing to lease against. `--force-with-lease` is the ci-rebase-handler's
# sanctioned exception and belongs nowhere else.
# --------------------------------------------------------------------------
review_consolidate_push_branch() {
  [ "$#" -eq 5 ] || return 2
  local worktree="$1" scan_dir="$2" repo_slug="$3" pr_number="$4" branch="$5"
  # shellcheck source=/dev/null
  . "$_UBERDEV_CONSOLIDATE_PLUGIN_ROOT/lib/review-push-target.sh" 2>/dev/null || return 79
  command -v review_resolve_same_repo_push_target >/dev/null 2>&1 || {
    _uberdev_consolidate_error "the same-repository push-target resolver is unavailable"
    return 79
  }
  review_resolve_same_repo_push_target "$repo_slug" "$pr_number" "$worktree" >/dev/null 2>&1
  local resolve_rc=$?
  case "$resolve_rc" in
    0) : ;;
    78)
      printf '%s\n' "push_refused" >"$scan_dir/failure-reason.txt"
      _uberdev_consolidate_error "the invoking PR's head lives in another repository; refusing to push a combine branch to origin"
      return 78
      ;;
    *)
      _uberdev_consolidate_error "could not establish the push target's repository identity; halting rather than guessing"
      return 79
      ;;
  esac
  # git's own words are CAPTURED, not discarded. `>/dev/null 2>&1 || return 2`
  # sent the explanation of a non-fast-forward, an expired token or a
  # protected-branch rule to the same place as the progress output, and this is
  # the push the rest of Phase 0 depends on: it aborts the run mid-loop with the
  # cause already thrown away. The five push sites in
  # skills/premerge-pipeline/SKILL.md are the model; this one lives in the
  # library, outside the fence corpus tests/premerge.test.sh P18 scans.
  local push_err
  push_err="$(git -C "$worktree" push -u origin "$branch" 2>&1 1>/dev/null)" || {
    # Bounded and defused BEFORE anything reads it, because a pre-receive hook
    # chooses the length and the content of every `remote:` line. The same three
    # jobs the fences' one-liner does -- references/phase-contracts.md, `### What
    # a failed push is allowed to say`: 200 chars, one line, no live token.
    #
    # BOTH scraped markers are broken, because this library's stderr is the
    # stream BOTH callers scrape positionally: commands/review-pr.md prints
    # `REVIEW_CONSOLIDATE PR_NUMBER=... SCAN_ID=...` from the very fence that
    # calls this function, and the premerge fences that source this file print
    # `PREMERGE ...`. Either spelling arriving on a `remote:` line is a
    # well-formed result no matter where it sits. `tr` and `cut` read to EOF, so
    # this pipeline is not the early-exiting shape tests/epipe-guard.test.sh bans.
    push_err="${push_err//PREMERGE/PRE-MERGE}"
    push_err="${push_err//REVIEW_CONSOLIDATE/REVIEW-CONSOLIDATE}"
    push_err="$(printf '%s' "$push_err" | tr -s '\n\r\t' ' ' | cut -c1-200)"
    _uberdev_consolidate_error "pushing $branch to origin failed: $push_err"
    return 2
  }
  return 0
}

# --------------------------------------------------------------------------
# review_consolidate_closes SCAN_DIR -> the deduped union of issue numbers the
# included originals close, one per line.
#
# The originals are SUPERSEDED, not merged individually, so their `Closes #N`
# references have to travel to the combined PR or the underlying issues never
# close on merge.
# --------------------------------------------------------------------------
review_consolidate_closes() {
  [ "$#" -eq 1 ] || return 2
  local scan_dir="$1"
  local numbers number body
  numbers="$(review_consolidate_included "$scan_dir")"
  # `while IFS= read -r` and not `for n in $numbers`: the producer emits one
  # number per LINE, and splitting an unquoted scalar on IFS is a bashism --
  # zsh leaves it as a single word, so the loop ran once over the whole list.
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    body="$(_uberdev_consolidate_field "$scan_dir" "$number" body)"
    [ -n "$body" ] || continue
    grep -oiE "$UBERDEV_CONSOLIDATE_CLOSING_KEYWORD_ERE" <<<"$body" 2>/dev/null \
      | grep -oE '#[0-9]+' \
      | tr -d '#'
  done <<<"$numbers" | sort -un
}

# review_consolidate_body SCAN_DIR COMBINE_BRANCH -> the combined PR body.
review_consolidate_body() {
  [ "$#" -eq 2 ] || return 2
  local scan_dir="$1" branch="$2"
  local number title issue
  printf '## Consolidated PRs\n\n'
  printf 'These PRs are superseded by this one. They are NOT merged individually and receive no trust trail; the review that covers them is the one run against this branch (`%s`).\n\n' "$branch"
  for number in $(review_consolidate_included "$scan_dir"); do
    title="$(_uberdev_consolidate_field "$scan_dir" "$number" title)"
    printf -- '- #%s — %s — superseded by this PR\n' "$number" "${title:-(untitled)}"
  done
  if [ -s "$scan_dir/excluded.jsonl" ]; then
    printf '\n## Excluded\n\n'
    printf 'Reported by number rather than dropped silently:\n\n'
    jq -r '"- #\(.number) — \(.reason)"' <"$scan_dir/excluded.jsonl" 2>/dev/null | sort -u
  fi
  local closes
  closes="$(review_consolidate_closes "$scan_dir")"
  if [ -n "$closes" ]; then
    printf '\n'
    while IFS= read -r issue; do
      [ -n "$issue" ] || continue
      printf 'Closes #%s\n' "$issue"
    done <<EOF_CONSOLIDATE_CLOSES
$closes
EOF_CONSOLIDATE_CLOSES
  fi
}

# review_consolidate_title SCAN_DIR -> `chore(stack): land #A #B …`
# The shape AGENTS.md blesses for a fleet PR. The `(vX.Y.Z)` suffix and the
# version bump belong to the LANDING commit, once per stack -- not here.
review_consolidate_title() {
  [ "$#" -eq 1 ] || return 2
  local scan_dir="$1" number rendered=""
  for number in $(review_consolidate_included "$scan_dir"); do
    rendered="$rendered #$number"
  done
  [ -n "$rendered" ] || return 2
  printf 'chore(stack): land%s\n' "$rendered"
}

# review_consolidate_open_pr WORKTREE SCAN_DIR BASE BRANCH -> the new PR number.
review_consolidate_open_pr() {
  [ "$#" -eq 4 ] || return 2
  local worktree="$1" scan_dir="$2" base="$3" branch="$4"
  local title body_file url number
  title="$(review_consolidate_title "$scan_dir")" || return 2
  body_file="$scan_dir/combined-pr-body.md"
  review_consolidate_body "$scan_dir" "$branch" >"$body_file" || return 2
  # `gh` resolves the repository from its own cwd and takes no -C, so the cd is
  # how the call is bound to the checkout the combine was built in rather than
  # to wherever the fence happens to be standing.
  url="$(cd "$worktree" && gh pr create \
    --base "$base" --head "$branch" \
    --title "$title" --body-file "$body_file" 2>/dev/null)" || return 2
  number="$(sed -n 's|.*/pull/\([0-9][0-9]*\).*|\1|p' <<<"$url" | sort -un | tail -n 1)"
  case "$number" in
    ''|*[!0-9]*)
      _uberdev_consolidate_error "could not parse a PR number out of: $url"
      return 2
      ;;
  esac
  printf '%s\n' "$number" >"$scan_dir/combined-pr.txt" || return 2
  printf '%s\n' "$number"
}

# review_consolidate_comment_originals SCAN_DIR COMBINED_PR
# EXACTLY one comment per included original, and nothing else: no label, no
# close, no merge, no assignee change. The originals keep `review-pr:pending`,
# which is what correctly stops /merge from landing them on their own.
review_consolidate_comment_originals() {
  [ "$#" -eq 2 ] || return 2
  local scan_dir="$1" combined="$2" number
  case "$combined" in ''|*[!0-9]*) return 2 ;; esac
  for number in $(review_consolidate_included "$scan_dir"); do
    gh pr comment "$number" \
      --body "Superseded for review by #$combined; the trust trail will be emitted there." \
      >/dev/null 2>&1 || _uberdev_consolidate_warn "could not comment on #$number"
  done
  return 0
}

# review_consolidate_manifest SCAN_DIR SCAN_ID BRANCH COMBINED_PR BASE
# The on-disk carrier. Step 7's Final Aggregation runs in a different shell many
# fences later, so a shell variable would already be gone by then -- the repo's
# own lost-carrier class (#399 / #418).
review_consolidate_manifest() {
  [ "$#" -eq 5 ] || return 2
  local scan_dir="$1" scan_id="$2" branch="$3" combined="$4" base="$5"
  local included excluded closes
  included="$(review_consolidate_included "$scan_dir" | jq -R 'tonumber?' | jq -sc '.')" || return 2
  if [ -s "$scan_dir/excluded.jsonl" ]; then
    excluded="$(jq -sc '.' <"$scan_dir/excluded.jsonl")" || return 2
  else
    excluded='[]'
  fi
  closes="$(review_consolidate_closes "$scan_dir" | jq -R 'tonumber?' | jq -sc '.')" || return 2
  jq -n \
    --arg scan_id "$scan_id" \
    --arg combine_branch "$branch" \
    --arg base "$base" \
    --argjson combined_pr "${combined:-null}" \
    --argjson included "${included:-[]}" \
    --argjson excluded "${excluded:-[]}" \
    --argjson closes "${closes:-[]}" \
    '{schema_version:1,scan_id:$scan_id,combine_branch:$combine_branch,combined_pr:$combined_pr,base:$base,included:$included,excluded:$excluded,closes:$closes}' \
    >"$scan_dir/manifest.json" || return 2
  return 0
}
