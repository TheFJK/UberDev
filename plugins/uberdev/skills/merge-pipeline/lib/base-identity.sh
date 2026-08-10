#!/usr/bin/env bash
# plugins/uberdev/skills/merge-pipeline/lib/base-identity.sh
#
# Landed-delta equivalence for /merge Phase 1.4 PATH_2 sub-condition (c) — the
# base half of the trust trail (#440).
#
# WHY THIS IS NOT "the merge-base moved, therefore STALE"
# ------------------------------------------------------
# The naive predicate is the one the issue title invites, it passes a casual
# review, and it is WRONG. Three ordinary, honest situations move the recorded
# base without changing a single reviewed byte:
#
#   * the parent PR landed as a MERGE COMMIT and GitHub retargeted this PR to
#     the integration branch;
#   * the parent PR landed as a SQUASH — UberDev's own default strategy — so the
#     integration branch does not contain the parent's commit at all and the
#     recomputed merge-base collapses all the way back to the root;
#   * the integration branch simply moved forward with unrelated work.
#
# Under "merge-base differs => STALE" every child PR of every squash-merged
# parent goes STALE — i.e. every stacked `/goal` run. An operator who sees STALE
# on every ordinary post-merge retarget learns to ignore STALE, which is a worse
# outcome than the base-blind trust trail this file exists to fix.
#
# WHAT IS ACTUALLY BEING ASKED
# ----------------------------
# "Are the bytes that would land on the CURRENT base the same bytes that were
# reviewed against the RECORDED base?" That is a question about deltas — but it
# is answered by comparing TREES, never by comparing two `git diff` TEXTS:
#
#   landed   = merge-tree(current_base_oid, trust_head)
#   expected = merge-tree(--merge-base=reviewed_base_sha, current_base_oid, trailer_sha)
#              i.e. "the reviewed delta, and nothing else, applied to the current base"
#   match   <=>  landed tree OID == expected tree OID
#
# COMPARING DIFF TEXT IS THE TRAP, AND IT FAILS ON THE COMMON PATH
# ----------------------------------------------------------------
# `git diff` output is a rendering, not a value, and three of its renderings move
# without any reviewed byte moving. All three occur on the AUTOMATIC post-merge
# retarget — the path whose GREEN is still honest and which therefore must never
# go STALE:
#
#   * the `index <old-blob>..<new-blob>` header changes whenever the base touches
#     a file the PR also touches, because the pre-image blob OID changed;
#   * CONTEXT lines change when the base edits a line within three lines of a
#     reviewed hunk;
#   * `@@` hunk headers change when the base inserts or deletes ANY line earlier
#     in a file the PR also touches — which no amount of `-U0` or `^index`
#     stripping can normalise away.
#
# In this repo children are routinely retargeted to main while main accumulates
# PRs touching the same hot files (review-pr.md, merge-pipeline/SKILL.md), so
# text comparison false-mismatches on the ordinary case, not an edge. Tree OIDs
# have none of these degrees of freedom: they are the content itself.
#
# `git merge-tree --write-tree` is the canonical non-destructive merge probe —
# already the primitive /merge Phase 3.1 uses (D9), already pinned by
# tests/merge.test.sh. It writes loose objects, never a ref, never the worktree,
# never the network. `--merge-base=` pins the third leg explicitly, which is what
# lets the second probe mean "the reviewed delta" rather than "whatever git
# infers today".
#
# VERSION FLOOR. `--write-tree` needs git >= 2.38 and `--merge-base=` is newer
# still (2.40). Neither is probed for: a git that lacks either exits non-zero
# with a usage error, which is neither 0 nor 1, so the `*)` arms below return
# `unavailable` -> STALE. Fail-closed on an old git is correct — "this git
# cannot answer the question" must never be spelled as "the bytes match".
#
# WHY THE CALLER COMPUTES THIS AND NOT THE AGENT
# ----------------------------------------------
# `agents/trust-trail-evaluator.md` restricts Bash to `git merge-base`,
# `git diff --shortstat`, `git log --oneline`, `git rev-parse`, and forbids `gh`
# outright. That allowlist is a deliberate security boundary, so the answer is
# threaded IN as a dispatch input exactly the way `status_check_rollup` and
# `commit_shas` already are — one projection, one instant, one verdict (#303).
#
# Bash 3.2 compatible; also sourced under the zsh Bash tool, so: no `type -t`,
# no BASH_REMATCH, no `local path` / `local status`.

# merge_resolve_base_delta_equivalence WORKING_DIR REVIEWED_BASE_SHA TRAILER_SHA CURRENT_BASE_OID TRUST_HEAD
#
# Prints exactly one of:
#   match       — the bytes that would land equal the bytes that were reviewed
#   mismatch    — they differ (deliberate retarget, or a conflicting merge)
#   unavailable — the probe could not run or could not be trusted ("cannot tell")
#
# Returns 2 without printing only on an arity error. Every other failure is a
# printed `unavailable`, because a caller that gets no answer at all is far more
# likely to default than a caller handed the token for "I do not know".
merge_resolve_base_delta_equivalence() {
  [ "$#" -eq 5 ] || return 2
  local working_dir="$1" reviewed_base="$2" reviewed_head="$3"
  local current_base="$4" current_head="$5"
  local candidate landed_tree expected_tree merge_rc
  local newline='
'

  for candidate in "$reviewed_base" "$reviewed_head" "$current_base" "$current_head"; do
    if [ "${#candidate}" -ne 40 ]; then printf 'unavailable\n'; return 0; fi
    case "$candidate" in
      *[!0-9a-f]*) printf 'unavailable\n'; return 0 ;;
    esac
  done

  [ -d "$working_dir" ] || { printf 'unavailable\n'; return 0; }
  git -C "$working_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'unavailable\n'; return 0; }

  # Prove every commit is present in THIS clone before probing. `git merge-tree`
  # exits 1 both for "the merge conflicts" and for "that is not something we can
  # merge", so without this pre-check a SHA that is simply absent from the local
  # clone -- a fresh clone, a GC'd trailer -- would be reported as a conflicting
  # merge and therefore as a base MISMATCH. "Cannot tell" and "the bytes differ"
  # are different answers and only one of them is allowed to look like evidence.
  for candidate in "$reviewed_base" "$reviewed_head" "$current_base" "$current_head"; do
    git -C "$working_dir" cat-file -e "${candidate}^{commit}" 2>/dev/null \
      || { printf 'unavailable\n'; return 0; }
  done

  # LANDED — what the three-way merge onto the current base actually produces.
  # git infers the merge base here on purpose: this leg must model the real
  # landing, whatever git would really do.
  landed_tree="$(git -C "$working_dir" merge-tree --write-tree \
                   "$current_base" "$current_head" 2>/dev/null)"
  merge_rc=$?
  case "$merge_rc" in
    0) ;;
    1)
      # Exit 1 is CONFLICTS. A merge that cannot be performed cleanly is by
      # definition not the delta anybody reviewed, so this is a mismatch and NOT
      # a probe failure -- classifying it as `unavailable` would be honest but
      # would bury the loudest possible signal that the base moved somewhere
      # incompatible.
      printf 'mismatch\n'; return 0 ;;
    *)
      # Includes git older than 2.38 (no `--write-tree`) and missing objects.
      printf 'unavailable\n'; return 0 ;;
  esac

  # EXPECTED — the REVIEWED delta and nothing else, replayed onto the current
  # base. `--merge-base=<reviewed_base>` is what makes this leg mean exactly
  # "reviewed_base -> trailer_sha, applied here": git is told the third leg
  # rather than inferring it, so a base that moved cannot silently redefine what
  # "the reviewed delta" was.
  expected_tree="$(git -C "$working_dir" merge-tree --write-tree \
                     --merge-base="$reviewed_base" \
                     "$current_base" "$reviewed_head" 2>/dev/null)"
  merge_rc=$?
  case "$merge_rc" in
    0) ;;
    1)
      # The reviewed delta does not even apply cleanly to the current base, so
      # the bytes that would land cannot be the bytes that were reviewed.
      printf 'mismatch\n'; return 0 ;;
    *)
      printf 'unavailable\n'; return 0 ;;
  esac

  # `merge-tree --write-tree` prints the tree OID on its own first line.
  # A literal newline, never `$(printf '\n')` -- command substitution strips
  # trailing newlines, so that idiom expands to the EMPTY string and `%%*`
  # then eats the whole value.
  landed_tree="${landed_tree%%${newline}*}"
  expected_tree="${expected_tree%%${newline}*}"
  for candidate in "$landed_tree" "$expected_tree"; do
    if [ "${#candidate}" -ne 40 ]; then printf 'unavailable\n'; return 0; fi
    case "$candidate" in
      *[!0-9a-f]*) printf 'unavailable\n'; return 0 ;;
    esac
  done

  if [ "$landed_tree" = "$expected_tree" ]; then
    printf 'match\n'
  else
    printf 'mismatch\n'
  fi
  return 0
}
