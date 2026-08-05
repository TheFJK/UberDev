#!/usr/bin/env bash
# tools/prkit/rewrite.sh — prkit namespace-rewrite ruleset (RFC 0014 §5.4).
# SOURCE this file; do not execute. Uses perl for portable in-place edits
# (BSD/GNU sed differ; perl is uniform on macOS, Linux, Git-Bash).
#
#   prkit_neutralize <file>       # strip uberdev: prefix from OUT-OF-SET refs
#   prkit_apply_rewrites <file>   # slug + blanket case-preserving rewrite
#
# ORDER MATTERS: neutralize BEFORE apply_rewrites, so the blanket
# uberdev->prkit never manufactures a dangling prkit:<out-of-set-name>.

# prkit_neutralize — strip the `uberdev:` / `/uberdev:` namespace PREFIX from every
# OUT-OF-SET command/skill/agent reference BEFORE the blanket uberdev->prkit
# rewrite, so it can never mint a dangling prkit:<name> pointing at something
# prkit does not ship. It reduces the ref to its bare name (readable prose) and,
# crucially, never consumes a trailing inline-code backtick or an argument — that
# is the /solve <URL> backtick-mangling class this replaced. The KEEP set is
# prkit's shipped PR-phase surface (3 commands + 14 agents + 2 skills) plus the
# label allowlist (`active`, `*-finding`); those keep their prefix so they become
# prkit:<name>. verify.sh's out-of-set gate backstops this: any surviving
# prkit:<name> resolving to neither a shipped item nor an allowlisted label fails
# generation. Non-matching files are untouched (no-op).
prkit_neutralize() {
  local f="$1"
  perl -0pi -e '
    my $keep = qr/(?:review-pr|simplify|merge|code-reviewer|silent-failure-hunter|type-design-analyzer|comment-analyzer|pr-test-analyzer|code-fixer|code-simplifier|ci-failure-classifier|ci-code-fixer|ci-rebase-handler|trust-trail-evaluator|merge-strategy-decider|conflict-resolver|findings-to-issues|post-impl-review|merge-pipeline|active)(?![a-z0-9-])|[a-z0-9-]+-finding(?![a-z0-9-])/;
    s{/?uberdev:(?!$keep)([a-z][a-z0-9-]*)}{$1}g;
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
    s/uberdev/prkit/g;   # everything else: uberdev:, _uberdev_, uberdev-cmd-, paths, labels, files
  ' "$f"
}
