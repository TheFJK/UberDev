#!/usr/bin/env bash
# tests/cluster.test.sh — shape gates for /uberdev:cluster (issue #247, RFC 0010)
# C1-C10: 17 gates over command + skill + agent + alias + label + RFC.
# Pure grep + structural assertions. Runs on ubuntu + windows + macOS CI shape-check
# matrix. No external deps beyond grep / sed / wc / printf / sha-style /
# byte-counting (POSIX-portable).
#
# Sections:
#   C1    — commands/cluster.md frontmatter (description, argument-hint, allowed-tools)
#   C1.b  — commands/cluster.md allowed-tools omits "Edit" / "MultiEdit" (Write is OK)
#   C2    — skills/cluster-pipeline/SKILL.md name + Phase 0..5 markers + agent ref
#   C2.b  — SKILL.md bashism-free: no "type -t", no "BASH_REMATCH", no awk $N col refs
#   C2.c  — SKILL.md uses --body-file form, never --body "$VAR" (security.md §Q2)
#   C3    — agents/issue-similarity-analyzer.md frontmatter (name, description, model, tools)
#   C3.b  — agent tools whitelist omits Edit / MultiEdit / Write (read-only invariant)
#   C3.c  — agent return YAML schema cites clusters / lead / members / rationale / confidence
#   C4    — gh label create description literal <=100 chars (memory project_uberdev_label_desc_100char_limit)
#   C5    — HTML-comment fingerprint marker present (<!-- uberdev:cluster-fold lead= ... fingerprint= ...)
#   C5.b  — fingerprint computed via sha256sum + cut -c1-16, NOT awk substr $1 (renderer collision)
#   C6    — alias-sync SSOT row present + byte-match against cluster.md allowed-tools
#   C7    — refuse-list literals present: uberdev:active / review-pr:pending / folded
#   C7.b  — TOCTOU re-check: closingIssuesReferences + gh issue view present in SKILL.md
#   C8    — --repo regex ([A-Za-z0-9._-]) + viewerPermission preflight present
#   C9    — --execute floor 0.85 + error message "requires --min-confidence >= 0.85"
#   C10   — RFC docs/rfc/0010-uberdev-cluster-command.md exists and is non-empty

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

CMD="$REPO_ROOT/plugins/uberdev/commands/cluster.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/cluster-pipeline/SKILL.md"
AGENT="$REPO_ROOT/plugins/uberdev/agents/issue-similarity-analyzer.md"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
RFC="$REPO_ROOT/docs/rfc/0010-uberdev-cluster-command.md"

# Pre-flight: refuse to run if any asserted-against file is missing.
for f in "$CMD" "$SKILL" "$AGENT" "$SYNC" "$RFC"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

# Lightweight pattern-match helpers (paired with the shared assert_grep /
# assert_no_grep harness in _lib_assert_structural.sh, which provides
# assert_count / assert_subagent_type / assert_in_section).
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc (pattern unexpectedly present)"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

echo "## /uberdev:cluster shape gates"

echo "== C1: commands/cluster.md frontmatter =="
assert_grep "$CMD" '^description:'   "C1.description"
assert_grep "$CMD" '^argument-hint:' "C1.argument-hint"
assert_grep "$CMD" '^allowed-tools:' "C1.allowed-tools"
# allowed-tools must include "Bash(git*)", "Bash(gh*)", "Task"
if grep '^allowed-tools:' "$CMD" | grep -q '"Bash(git\*)"'; then
  echo "  PASS  C1.allowed-tools.bash-git"; PASS=$((PASS+1))
else
  echo "  FAIL  C1.allowed-tools.bash-git"; FAIL=$((FAIL+1))
fi
if grep '^allowed-tools:' "$CMD" | grep -q '"Bash(gh\*)"'; then
  echo "  PASS  C1.allowed-tools.bash-gh"; PASS=$((PASS+1))
else
  echo "  FAIL  C1.allowed-tools.bash-gh"; FAIL=$((FAIL+1))
fi
if grep '^allowed-tools:' "$CMD" | grep -q '"Task"'; then
  echo "  PASS  C1.allowed-tools.task"; PASS=$((PASS+1))
else
  echo "  FAIL  C1.allowed-tools.task"; FAIL=$((FAIL+1))
fi

echo "== C1.b: commands/cluster.md allowed-tools omits Edit / MultiEdit =="
# Write IS permitted (the alias surface ships with Write in its tools list);
# only Edit / MultiEdit are banned because they imply destructive in-place
# edits of repo files that /uberdev:cluster has no business doing.
if grep '^allowed-tools:' "$CMD" | grep -qE '"Edit"|"MultiEdit"'; then
  echo "  FAIL  C1.b.no-edit-multiedit"; FAIL=$((FAIL+1))
else
  echo "  PASS  C1.b.no-edit-multiedit"; PASS=$((PASS+1))
fi

echo "== C2: skills/cluster-pipeline/SKILL.md structure =="
assert_grep "$SKILL" '^name: cluster-pipeline'                   "C2.name"
assert_grep "$SKILL" 'Phase 0'                                   "C2.phase-0"
assert_grep "$SKILL" 'Phase 1'                                   "C2.phase-1"
assert_grep "$SKILL" 'Phase 2'                                   "C2.phase-2"
assert_grep "$SKILL" 'Phase 3'                                   "C2.phase-3"
assert_grep "$SKILL" 'Phase 4'                                   "C2.phase-4"
assert_grep "$SKILL" 'Phase 5'                                   "C2.phase-5"
assert_grep "$SKILL" 'issue-similarity-analyzer'                 "C2.agent-ref"

echo "== C2.b: SKILL.md bashism-free (zsh-compat) =="
assert_no_grep "$SKILL" 'type -t'      "C2.b.no-type-t"
assert_no_grep "$SKILL" 'BASH_REMATCH' "C2.b.no-bash-rematch"
# awk $N column-ref guard. Skill-renderer substitutes positional $ARGUMENTS
# into the entire SKILL.md body, including inside single-quoted awk one-liners
# (memory project_uberdev_skill_renderer_dollar_arg_collision). The forbidden
# shape is: awk SPACE '...$<digit>...'  — match literal awk + single-quoted
# body + a $ followed by a digit.
if grep -E "awk[[:space:]]+'[^']*\\\$[0-9]" "$SKILL" >/dev/null; then
  echo "  FAIL  C2.b.no-awk-col-ref"; FAIL=$((FAIL+1))
else
  echo "  PASS  C2.b.no-awk-col-ref"; PASS=$((PASS+1))
fi

echo "== C2.c: SKILL.md uses --body-file only (security.md Q2) =="
# Forbidden form (gh-issue writes via unsafe --body "$VAR" variable expansion):
#   gh issue (close|edit|comment) ... --body "$<var>...
# Allowed forms: --body-file -  /  --body-file <path>  /  --comment "$(cat …)"
if grep -E 'gh issue (close|edit|comment)[^|]*--body "\$' "$SKILL" >/dev/null; then
  echo "  FAIL  C2.c.no-unsafe-body-var"; FAIL=$((FAIL+1))
else
  echo "  PASS  C2.c.no-unsafe-body-var"; PASS=$((PASS+1))
fi

echo "== C3: agents/issue-similarity-analyzer.md frontmatter =="
assert_grep "$AGENT" '^name: issue-similarity-analyzer' "C3.name"
assert_grep "$AGENT" '^description:'                    "C3.description"
assert_grep "$AGENT" '^model: sonnet'                   "C3.model-sonnet"
assert_grep "$AGENT" '^tools:'                          "C3.tools"

echo "== C3.b: agent tools whitelist omits Edit / MultiEdit / Write =="
# Read-only invariant — different from C1.b (the alias surface CAN Write; the
# subagent that classifies clusters CANNOT). Tool-dropping enforced by
# frontmatter (RFC 0007 §2.3).
if grep '^tools:' "$AGENT" | grep -qE '"Edit"|"MultiEdit"|"Write"'; then
  echo "  FAIL  C3.b.no-edit-multiedit-write"; FAIL=$((FAIL+1))
else
  echo "  PASS  C3.b.no-edit-multiedit-write"; PASS=$((PASS+1))
fi

echo "== C3.c: agent return YAML schema cited =="
assert_grep "$AGENT" 'clusters:'   "C3.c.clusters"
assert_grep "$AGENT" 'lead:'       "C3.c.lead"
assert_grep "$AGENT" 'members:'    "C3.c.members"
assert_grep "$AGENT" 'rationale:'  "C3.c.rationale"
assert_grep "$AGENT" 'confidence:' "C3.c.confidence"

echo "== C4: gh label create description <=100 chars (memory project_uberdev_label_desc_100char_limit) =="
# Extract the quoted "Closed as semantic duplicate by /uberdev:cluster..."
# string from SKILL.md and assert its byte-length is in (0, 100].
LABEL_DESC="$(grep -oE '"Closed as semantic duplicate by /uberdev:cluster[^"]*"' "$SKILL" | head -1 | sed -e 's/^"//' -e 's/"$//')"
LEN="$(printf '%s' "$LABEL_DESC" | wc -c | tr -d '[:space:]')"
if [ "${LEN:-0}" -le 100 ] && [ "${LEN:-0}" -gt 0 ]; then
  echo "  PASS  C4.label-desc-len (len=$LEN)"; PASS=$((PASS+1))
else
  echo "  FAIL  C4.label-desc-len (len=$LEN)"; FAIL=$((FAIL+1))
fi

echo "== C5: HTML-comment fingerprint marker =="
assert_grep "$SKILL" '<!-- uberdev:cluster-fold lead=' "C5.marker-lead"
assert_grep "$SKILL" 'fingerprint='                    "C5.marker-fingerprint"

echo "== C5.b: fingerprint via sha256 + cut -c1-16, NOT awk substr =="
assert_grep    "$SKILL" 'sha256sum'   "C5.b.sha256sum"
assert_grep    "$SKILL" 'cut -c1-16'  "C5.b.cut-c1-16"
# Old/forbidden form would be:  awk '{print substr($1,1,16)}' or similar.
# Renderer $N collision means any awk substr that touches $1 silently corrupts.
assert_no_grep "$SKILL" 'awk.*substr.*\$1' "C5.b.no-awk-substr"

echo "== C6: alias-sync SSOT row + byte-match against cluster.md =="
assert_grep "$SYNC" '^ubercluster\|cluster\|' "C6.ssot-row"
# Byte-match the JSON tools list on both sides. The SSOT row is
#   ubercluster|cluster|["Bash(git*)", ...]
# and the cluster.md allowed-tools frontmatter is
#   allowed-tools: ["Bash(git*)", ...]
# Both should produce IDENTICAL JSON arrays once the prefix is stripped.
CMD_TOOLS="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //')"
SSOT_TOOLS="$(grep -F 'ubercluster|cluster|' "$SYNC" | sed 's/.*|//')"
if [ "$CMD_TOOLS" = "$SSOT_TOOLS" ]; then
  echo "  PASS  C6.byte-match"; PASS=$((PASS+1))
else
  echo "  FAIL  C6.byte-match: cmd='$CMD_TOOLS' vs ssot='$SSOT_TOOLS'"; FAIL=$((FAIL+1))
fi

echo "== C7: refuse-list literals present in SKILL.md =="
assert_grep "$SKILL" 'uberdev:active'    "C7.uberdev-active"
assert_grep "$SKILL" 'review-pr:pending' "C7.review-pr-pending"
assert_grep "$SKILL" 'folded'            "C7.folded"

echo "== C7.b: TOCTOU re-check uses closingIssuesReferences + gh issue view =="
assert_grep "$SKILL" 'closingIssuesReferences' "C7.b.closing-issues-references"
assert_grep "$SKILL" 'gh issue view'           "C7.b.gh-issue-view"

echo "== C8: --repo regex + viewerPermission preflight =="
# Regex shape: [A-Za-z0-9._-] character class for OWNER/NAME validation.
assert_grep "$SKILL" '\[A-Za-z0-9\._-\]'  "C8.repo-regex"
assert_grep "$SKILL" 'viewerPermission'    "C8.viewer-permission"

echo "== C9: --execute floor 0.85 + error message =="
assert_grep "$SKILL" '0\.85'                            "C9.floor-value"
assert_grep "$SKILL" 'requires --min-confidence >= 0\.85' "C9.floor-error-msg"

echo "== C10: RFC docs/rfc/0010-uberdev-cluster-command.md present =="
if [ -s "$RFC" ]; then
  echo "  PASS  C10.rfc-present"; PASS=$((PASS+1))
else
  echo "  FAIL  C10.rfc-present"; FAIL=$((FAIL+1))
fi

echo
echo "## cluster shape gates: $PASS pass, $FAIL fail"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
