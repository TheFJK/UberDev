#!/usr/bin/env bash
# tools/prkit/rewrite.sh — prkit namespace-rewrite ruleset (RFC 0014 §5.4).
# SOURCE this file; do not execute. Uses perl for portable in-place edits
# (BSD/GNU sed differ; perl is uniform on macOS, Linux, Git-Bash).
#
#   prkit_neutralize <file>       # rule 2: remove out-of-set goal/solve refs
#   prkit_apply_rewrites <file>   # rules 1,3-6: blanket case-preserving rewrite
#
# ORDER MATTERS: neutralize BEFORE apply_rewrites, so the blanket
# uberdev->prkit never manufactures a dangling prkit:goal / prkit:solve.

# Rule 2 — out-of-set goal/solve references. The named sentence rules produce
# graceful prose at the censused review-pr.md sites (226/250/472/494/767); the
# catch-all block after them GUARANTEES completeness — any remaining
# /uberdev:goal|solve (or bare uberdev:goal|solve), from an uncensused file such
# as ci-code-fixer.md or a future edit, is reduced to generic prose so the blanket
# rewrite can never manufacture a dangling prkit:goal / prkit:solve.
# Non-matching files are untouched (no-op).
prkit_neutralize() {
  local f="$1"
  perl -0pi -e '
    s{next:\s*/uberdev:solve\s+\S+}{next: address the filed issue(s) manually}g;
    s{/uberdev:solve\s+\$CI_REFUSED_ISSUE_URL\s*\(or fix manually\)}{fix the filed issue manually}g;
    s{Render '\''/uberdev:solve <highest-priority issue URL>'\'' suggestion to stderr; emit RED trail; exit 1\. User runs /solve in a follow-up turn\.}{Emit RED trail with the filed issue URL(s) to stderr; exit 1. Address them manually.}g;
    s{emit one stderr line per filed BLOCKER URL: `next: /uberdev:solve <URL>`\. The user runs the suggested command in a follow-up turn; `/review-pr` itself does not background-dispatch `/solve` \(sub-process dispatch from inside a halted review run is out of scope per RFC 0002 §7\.1 — defaults to hard-stop to avoid cascading agent loops\)\.}{emit one stderr line per filed BLOCKER URL pointing at the issue to fix manually. `/review-pr` never background-dispatches a solver.}g;
    s{so a concurrent `/uberdev:goal` Phase 2b knows this PR'\''s `/review-pr` is in-flight \(avoids re-dispatching ours while the leaf solver'\''s own is still running\)}{recording that this PR'\''s `/review-pr` is in-flight (an advisory concurrency marker)}g;
    s{The locked marker is read by `/uberdev:goal` Phase 2b via `_uberdev_goal_locked_marker_for_pr_fresh[^`]*` \(lib/goal-state.sh\)\. }{The locked marker is advisory and self-expiring. }g;
    # Catch-all backstop (runs after the graceful sentence rules): reduce any
    # surviving out-of-set command reference to generic prose. Order: slash+arg,
    # slash, then bare token — so no stray "/" prefix is left behind.
    s{/uberdev:solve\s+\S+}{the filed issue}g;
    s{/uberdev:solve}{the issue tracker}g;
    s{/uberdev:goal}{the goal workflow}g;
    s{uberdev:solve}{the issue tracker}g;
    s{uberdev:goal}{the goal workflow}g;
  ' "$f"
}

# Rules 1,3,4,5,6 — blanket case-preserving uberdev->prkit. The verify-gate
# token guard (verify.sh) is the completeness backstop: if any uberdev token
# survives, generation fails and a rule is added here.
prkit_apply_rewrites() {
  local f="$1"
  perl -0pi -e '
    s{TheFJK/UberDev}{TheFJK/prkit}g;  # repo slug: MUST stay lowercase "prkit"
    s{TheFJK/uberdev}{TheFJK/prkit}g;  # (clone/marketplace URLs) — run before CamelCase
    s/UBERDEV/PRKIT/g;   # env vars, macros
    s/UberDev/Prkit/g;   # CamelCase product name in prose
    s/Uberdev/Prkit/g;   # sentence-case
    s/uberdev/prkit/g;   # everything else: uberdev:, _uberdev_, uberdev-codex, uberdev-cmd-, paths, labels, files
  ' "$f"
}
