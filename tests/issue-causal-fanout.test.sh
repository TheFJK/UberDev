#!/usr/bin/env bash
# Asserts the contract invariants for the deep root-cause research fanout
# added to /uberdev:issue and the corresponding brainstorm short-circuit.
#
# Modelled on tests/turbo-flow.test.sh (PR #7): grep-based structural
# assertions against the rendered command/skill files. No live gh CLI
# invocation. Tests run in CI before merge.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISSUE_CMD="$REPO_ROOT/plugins/uberdev/commands/issue.md"
BRAINSTORM="$REPO_ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"

# Pre-flight: refuse to run if the files we're asserting against are missing
# or unreadable — without this, every assertion fails with a confusing
# "pattern not found" instead of the real cause.
for f in "$ISSUE_CMD" "$BRAINSTORM"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
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
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== Phase 1.5 resolves RUN_ID and SUMMARY_DIR =="
assert_grep "$ISSUE_CMD" \
  'RUN_ID="\$\(date \+%Y%m%d-%H%M%S\)-\$\(git rev-parse --short HEAD' \
  "Phase 1.5 sets RUN_ID with date+git-sha"
assert_grep "$ISSUE_CMD" \
  'git rev-parse --short HEAD 2>/dev/null \|\| echo nohead' \
  "Phase 1.5 RUN_ID has defensive nohead fallback (mirrors orchestrator)"
assert_grep "$ISSUE_CMD" \
  'SUMMARY_DIR="\.uberdev/research/run-\$RUN_ID"' \
  "Phase 1.5 sets SUMMARY_DIR under .uberdev/research/run-"
assert_grep "$ISSUE_CMD" \
  'mkdir -p "\$SUMMARY_DIR"' \
  "Phase 1.5 mkdir -p \$SUMMARY_DIR"

echo
echo "== Phase 2 dispatches research-codebase + research-patterns =="
assert_grep "$ISSUE_CMD" \
  'research-codebase' \
  "Phase 2 names research-codebase agent"
assert_grep "$ISSUE_CMD" \
  'research-patterns' \
  "Phase 2 names research-patterns agent"
assert_grep "$ISSUE_CMD" \
  'single message|one message|same single message|single assistant turn' \
  "Phase 2 keeps the single-message-fanout invariant"

echo
echo "== --no-explore placeholder verbatim =="
assert_grep "$ISSUE_CMD" \
  'shallow mode — no fanout run; root cause to be confirmed in /brainstorm' \
  "--no-explore placeholder string appears verbatim"

echo
echo "== Bug template: causal triple labels =="
assert_grep "$ISSUE_CMD" \
  '\*\*Symptom:\*\*' \
  "bug template has Symptom label"
assert_grep "$ISSUE_CMD" \
  '\*\*Mechanism:\*\*' \
  "bug template has Mechanism label"
assert_grep "$ISSUE_CMD" \
  '\*\*Owning code:\*\*' \
  "bug template has Owning code label"

echo
echo "== Feat template: rename invariant =="
assert_grep "$ISSUE_CMD" \
  '## What changes' \
  "feat template uses ## What changes"
assert_no_grep "$ISSUE_CMD" \
  '## Proposed approach' \
  "feat template no longer contains ## Proposed approach (renamed)"

echo
echo "== Downstream-parseable contract preserved =="
assert_grep "$ISSUE_CMD" \
  '\*\*Triage hint:\*\* <trivial\|small\|medium>' \
  "Triage hint line preserved verbatim in templates"
assert_grep "$ISSUE_CMD" \
  '\[x\] P2 — normal bug' \
  "bug template severity checkbox block default-P2 preserved"

echo
echo "== Phase 7 binds artifacts to issue number =="
assert_grep "$ISSUE_CMD" \
  'mv "\$SUMMARY_DIR" "\.uberdev/research/issue-\$ISSUE_NUM"' \
  "Phase 7 renames SUMMARY_DIR to .uberdev/research/issue-\$ISSUE_NUM"
assert_grep "$ISSUE_CMD" \
  'warning: SUMMARY_DIR rename used cp\+rm fallback' \
  "Phase 7 cp+rm fallback emits a stderr warning"
assert_grep "$ISSUE_CMD" \
  'error: gh issue create did not return a parseable URL' \
  "Phase 7 guards against empty ISSUE_NUM with explicit error"
assert_grep "$ISSUE_CMD" \
  'error: both mv and cp failed' \
  "Phase 7 escalates when both mv and cp fail (no silent loss)"

echo
echo "== Body authoring rules subsection present =="
assert_grep "$ISSUE_CMD" \
  'Body authoring rules' \
  "Body authoring rules subsection heading present ahead of templates"
assert_grep "$ISSUE_CMD" \
  'WHAT/HOW boundary enforced' \
  "Rules subsection has WHAT/HOW boundary bullet"

echo
echo "== Brainstorm short-circuit reads .uberdev/research/issue-N =="
assert_grep "$BRAINSTORM" \
  '\.uberdev/research/issue-' \
  "brainstorm references .uberdev/research/issue- path"
assert_grep "$BRAINSTORM" \
  'Issue-research short-circuit' \
  "brainstorm has Issue-research short-circuit subsection"
assert_grep "$BRAINSTORM" \
  'gh issue view.*updatedAt|updatedAt.*gh issue view' \
  "brainstorm stale check uses gh issue view updatedAt"
assert_grep "$BRAINSTORM" \
  'CODEBASE_MTIME_EPOCH.*-lt.*ISSUE_UPDATED_EPOCH' \
  "brainstorm stale check uses -lt operator (summary older than issue update = stale)"
assert_grep "$BRAINSTORM" \
  'missing.*summary:.*field|summary:.*missing' \
  "brainstorm implements the malformed-summary fallback the prose claims"
assert_grep "$BRAINSTORM" \
  'failed to fetch.*updatedAt|gh auth/network' \
  "brainstorm warns and falls through when gh issue view returns empty"
assert_grep "$BRAINSTORM" \
  'Per-topic skip|per-topic, not all-or-nothing' \
  "brainstorm short-circuit is documented as per-topic, not all-or-nothing"
assert_grep "$BRAINSTORM" \
  'Backwards compatibility|Backward compatibility' \
  "brainstorm documents backwards-compat fallthrough"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
