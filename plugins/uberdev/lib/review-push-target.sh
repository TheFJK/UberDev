# review-push-target.sh -- the same-repository push-target resolver for
# /uberdev:review-pr Phase 3, on disk.
#
# WHY THIS FILE EXISTS (#395). Phase 3's CI-fix arm used to bind its push target
# with a bare `gh pr view --json headRefName,baseRefName` and then `git fetch
# origin <headRefName>`, `git rev-parse origin/<headRefName>` for the lease, and
# a leased `git push origin <headRefName>`. `origin` is the repository the PR
# was opened AGAINST; for a FORK PR `headRefName` names a branch in the
# CONTRIBUTOR's repository. So the push either fails with a raw git error, or --
# when the base repo happens to carry a branch of the same name, which is
# exactly what `main`, `dev` and `release` guarantee -- addresses an unrelated
# ref. Phase 1 and Phase 2 have always refused that shape before publishing
# (`review_publish_same_repo_pr_head` in commands/review-pr.md); Phase 3's push
# path never checked. This resolver is that assertion, positioned BEFORE the
# lease is captured: a lease over a ref the run could not identify proves
# nothing, and by lease time the fetch has already failed.
#
# WHY ON DISK AND NOT IN THE FENCE (#404). The skill templater substitutes every
# positional parameter of a rendered command fence -- `local repo_slug="$1"`
# arrives as `local repo_slug="--no-simplify"` -- so a helper that takes
# arguments cannot live in commands/review-pr.md and keep working. lib/*.sh is
# read at runtime and is not templated. It is also the only way a LATER fence
# can call this at all: every `bash` block in a command file is a FRESH shell,
# so fence text is not reachable from the next fence. Same precedent, same
# reasoning as lib/review-aggregate.sh and lib/review-fleet-args.sh.
#
# NO push, NO fetch, NO rebase, NO commit, NO write of any kind. This file
# answers one question -- "may Phase 3 push this PR's head to `origin`, and
# under which branch names?" -- and the CALLER performs the push. Keeping the
# answer and the action apart is what lets the refusal be a named audit event
# instead of a git error nobody classified.
#
# `origin` is assumed to address the repository the caller resolved as
# REPO_SLUG. That is the same assumption every other same-repo gate in
# /review-pr makes (the run reads the PR through `--repo <slug>` and pushes to
# `origin`), and it is why the head-repository equality below is the whole
# check: with head == REPO_SLUG == origin, `origin <head_branch>` is the PR's
# own branch by construction.

# review_resolve_same_repo_push_target REPO_SLUG PR_NUMBER WORKTREE_ROOT
#
# Prints "<head_branch>\t<base_branch>" on stdout when REPO_SLUG owns the PR's
# head. Prints nothing otherwise.
#
#   rc 0   same-repository PR; both names passed `git check-ref-format --branch`
#   rc 78  CROSS-REPOSITORY refusal -- the head lives in a fork, or in a
#          repository that is not REPO_SLUG. Named on purpose: the caller emits
#          a typed `data.subreason` for it rather than letting `git push` fail
#          with an error no audit consumer can route.
#   rc 79  the identity could not be established -- `gh` failed or is
#          unreachable, the projection was short or over-long, a branch name is
#          empty, or a name git itself will not route. Unlike the 6c.1 PROBE's
#          `ci_probe_unreachable` carve-out (a `gh` outage must not block a
#          release), this one HALTS: the alternative is pushing to a ref the run
#          could not name.
#   rc 2   the caller passed a malformed argument; `gh` is never invoked
#
# The head-repository identity is read as `headRepositoryOwner.login` +
# `headRepository.name`, NOT as `headRepository.nameWithOwner`. `gh pr view`
# declares that last field and never populates it -- measured against gh 2.83.1:
#
#     gh pr view 390 --repo TheFJK/UberDev --json headRepository
#     {"headRepository":{"id":"R_kgDOSOF5tw","name":"UberDev","nameWithOwner":""}}
#
# A gate keyed on the empty string can never pass, which turns "refuse forks"
# into "refuse everything". The owner/name composite is populated for every PR,
# fork and same-repo alike, so it is the field pair this resolver compares.
review_resolve_same_repo_push_target() {
  [ "$#" -eq 3 ] || return 2
  local repo_slug="$1" pr_number="$2" worktree_root="$3"
  local identity head_branch base_branch cross_repository head_repo extra
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$worktree_root" = /* ]] || return 2

  # One field per LINE, not one tab-separated line. Tab is IFS whitespace, so a
  # tab-joined projection with an empty field COLLAPSES under `read`: the fields
  # shift left and a malformed identity parses as a well-formed different one.
  # Line-per-field cannot shift -- a ref name may not contain a newline (git
  # refuses it), so a stray newline can only ever make the projection over-long,
  # which is refused below.
  identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
    --json headRefName,baseRefName,isCrossRepository,headRepository,headRepositoryOwner \
    --jq '.headRefName, .baseRefName, (.isCrossRepository | tostring),
          ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
    2>/dev/null)" || return 79
  {
    IFS= read -r head_branch || return 79
    IFS= read -r base_branch || return 79
    IFS= read -r cross_repository || return 79
    IFS= read -r head_repo || return 79
    if IFS= read -r extra; then return 79; fi
  } <<<"$identity"

  [ -n "$head_branch" ] && [ -n "$base_branch" ] || return 79
  [ "$cross_repository" = false ] && [ "$head_repo" = "$repo_slug" ] || return 78
  git -C "$worktree_root" check-ref-format --branch "$head_branch" >/dev/null 2>&1 || return 79
  git -C "$worktree_root" check-ref-format --branch "$base_branch" >/dev/null 2>&1 || return 79
  printf '%s\t%s\n' "$head_branch" "$base_branch"
}
