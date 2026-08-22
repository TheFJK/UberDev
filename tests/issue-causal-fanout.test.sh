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
CODEBASE_SCOUT="$REPO_ROOT/plugins/uberdev/agents/codebase-scout.md"
TRIAGE_SCOUT="$REPO_ROOT/plugins/uberdev/agents/triage-scout.md"
SOLVE_LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
SPEC_WRITER="$REPO_ROOT/plugins/uberdev/agents/spec-writer.md"
SOLVE_SKILL="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
# #723: /issue autopilot. README_MD carries an assert_no_grep row below, so it
# MUST join the pre-flight loop — assert_no_grep passes trivially against a
# missing file, which is exactly how a moved path goes vacuously green. RFC12
# joins it so a moved RFC reports the real cause, not a bare pattern miss.
README_MD="$REPO_ROOT/README.md"
RFC12="$REPO_ROOT/docs/rfc/0012-ultracode-workflow-orchestration.md"

# Pre-flight: refuse to run if the files we're asserting against are missing
# or unreadable — without this, every assertion fails with a confusing
# "pattern not found" instead of the real cause. Every path an assert_no_grep
# below names MUST be in this loop: assert_no_grep passes trivially against a
# missing or emptied file, so a moved path would go vacuously green.
for f in "$ISSUE_CMD" "$BRAINSTORM" "$CODEBASE_SCOUT" "$TRIAGE_SCOUT" \
         "$SOLVE_LAUNCHER" "$SPEC_WRITER" "$SOLVE_SKILL" \
         "$README_MD" "$RFC12"; do
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

echo "== Phase 1.5 SUMMARY_DIR setup is removed =="
assert_no_grep "$ISSUE_CMD" \
  'RUN_ID="\$\(date \+%Y%m%d-%H%M%S\)' \
  "Phase 1.5 RUN_ID stamping removed"
assert_no_grep "$ISSUE_CMD" \
  'SUMMARY_DIR="\.uberdev/research/run-' \
  "Phase 1.5 SUMMARY_DIR removed"
assert_no_grep "$ISSUE_CMD" \
  'mkdir -p "\$SUMMARY_DIR"' \
  "Phase 1.5 mkdir removed"

echo
echo "== Phase 2 dispatches the two scouts =="
assert_grep "$ISSUE_CMD" \
  'two Task agents|2 Task agents' \
  "/issue prose mentions 2-agent count"
assert_grep "$ISSUE_CMD" \
  'uberdev:codebase-scout' \
  "/issue dispatches uberdev:codebase-scout"
assert_grep "$ISSUE_CMD" \
  'uberdev:triage-scout' \
  "/issue dispatches uberdev:triage-scout"
assert_grep "$ISSUE_CMD" \
  'single message|one message|same single message|single assistant turn' \
  "Phase 2 keeps the single-message-fanout invariant"
assert_grep "$ISSUE_CMD" \
  'issue_type' \
  "Phase 2 dispatch payload includes issue_type (so triage-scout picks base label without re-classifying)"

echo
echo "== 8-agent fanout removed from /issue =="
assert_no_grep "$ISSUE_CMD" 'research-codebase' "research-codebase no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'research-patterns' "research-patterns no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'research-prior-art' "research-prior-art no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'research-constraints' "research-constraints no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'research-security' "research-security no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'research-test-coverage' "research-test-coverage no longer dispatched by /issue"
assert_no_grep "$ISSUE_CMD" 'eight Task agents|8 Task agents' "8-agent count prose removed"
assert_no_grep "$ISSUE_CMD" 'security\.md' "security.md aggregation removed from /issue"
assert_no_grep "$ISSUE_CMD" 'test-coverage\.md' "test-coverage.md aggregation removed from /issue"

echo
echo "== --no-explore is soft-deprecated =="
assert_no_grep "$ISSUE_CMD" \
  'NO_EXPLORE=1.*codebase.*patterns.*constraints.*test-coverage|in-repo agents only' \
  "/issue --no-explore 4-agent subset prose removed"
assert_grep "$ISSUE_CMD" \
  'notice: --no-explore is deprecated' \
  "/issue emits soft-deprecation notice for --no-explore"
assert_grep "$ISSUE_CMD" \
  'Removal target: v1\.0\.0' \
  "/issue --no-explore deprecation cites removal target v1.0.0"

echo
echo "== --no-explore placeholder string removed =="
assert_no_grep "$ISSUE_CMD" \
  'shallow mode — no fanout run; root cause to be confirmed in /brainstorm' \
  "shallow-mode placeholder string removed (no longer reachable)"

echo
echo "== Phase 0/6 injection hardening (RFC 0012 §3.12 light-R7) =="
# Phase 0: the raw-arguments splice into a double-quoted shell fence is gone.
# The renderer substitutes the user's description into the fence text BEFORE
# the model runs it, so a description carrying $(...) or backticks executed.
# Flag parsing is model-side now; only the gh repo probe stays in bash.
assert_no_grep "$ISSUE_CMD" \
  'echo "\$ARGUMENTS"' \
  "Phase 0 no longer echoes raw arguments through a shell fence"
assert_no_grep "$ISSUE_CMD" \
  'NO_EXPLORE=\$\(echo' \
  "Phase 0 NO_EXPLORE shell derivation removed"
assert_grep "$ISSUE_CMD" \
  'MODEL-SIDE' \
  "Phase 0 mandates the model-side token parse"
assert_grep "$ISSUE_CMD" \
  'gh repo view --json nameWithOwner' \
  "Phase 0 keeps the gh repo view probe as the only bash"
# Phase 6: body delivery is --body-file - with the heredoc on stdin — never
# --body "$(cat …)" (the dev-pipeline hard rule for user-derived bodies).
assert_no_grep "$ISSUE_CMD" \
  '\-\-body "\$\(cat' \
  "Phase 6 no longer uses --body \"\$(cat ...)\""
assert_grep "$ISSUE_CMD" \
  '\-\-body-file -' \
  "Phase 6 delivers the body via --body-file - on stdin"
assert_grep "$ISSUE_CMD" \
  "<<'EOF'" \
  "Phase 6 heredoc delimiter is single-quoted (expansion disabled)"

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
echo "== Phase 7 cache-binding step removed =="
assert_no_grep "$ISSUE_CMD" \
  'mv "\$SUMMARY_DIR"' \
  "Phase 7 mv \$SUMMARY_DIR removed"
assert_no_grep "$ISSUE_CMD" \
  'warning: SUMMARY_DIR rename used cp\+rm fallback' \
  "Phase 7 cp+rm fallback warning removed"
assert_no_grep "$ISSUE_CMD" \
  'error: both mv and cp failed' \
  "Phase 7 mv/cp escalation removed"

echo
echo "== Body authoring rules subsection present =="
assert_grep "$ISSUE_CMD" \
  'Body authoring rules' \
  "Body authoring rules subsection heading present ahead of templates"
assert_grep "$ISSUE_CMD" \
  'WHAT/HOW boundary enforced' \
  "Rules subsection has WHAT/HOW boundary bullet"

echo
echo "== Brainstorm short-circuit subsection removed =="
assert_no_grep "$BRAINSTORM" \
  '\.uberdev/research/issue-' \
  "brainstorm no longer references .uberdev/research/issue- path"
assert_no_grep "$BRAINSTORM" \
  'Issue-research short-circuit' \
  "brainstorm Issue-research short-circuit subsection removed"
assert_no_grep "$BRAINSTORM" \
  'gh issue view.*updatedAt|updatedAt.*gh issue view' \
  "brainstorm no longer uses gh issue view updatedAt stale check"
assert_no_grep "$BRAINSTORM" \
  '_MTIME_EPOCH.*-lt.*ISSUE_UPDATED_EPOCH' \
  "brainstorm no longer uses mtime stale comparison"
assert_no_grep "$BRAINSTORM" \
  'Per-topic skip|per-topic, not all-or-nothing' \
  "brainstorm no longer documents per-topic skip"

echo
echo "== Scout agents run on inherit — the session model =="
assert_grep "$CODEBASE_SCOUT" \
  '^model: inherit$' \
  "codebase-scout YAML frontmatter pins model: inherit"
assert_grep "$CODEBASE_SCOUT" \
  'runs on inherit' \
  "codebase-scout description names inherit (audit trail)"
assert_grep "$TRIAGE_SCOUT" \
  '^model: inherit$' \
  "triage-scout YAML frontmatter pins model: inherit"
assert_grep "$TRIAGE_SCOUT" \
  'runs on inherit' \
  "triage-scout description names inherit (audit trail)"
assert_grep "$ISSUE_CMD" \
  'CLAUDE_CODE_SUBAGENT_MODEL' \
  "/issue documents CLAUDE_CODE_SUBAGENT_MODEL escape hatch"

echo
echo "== Surviving bug-template sections =="
assert_grep "$ISSUE_CMD" \
  '## Likely area' \
  "## Likely area heading survives in bug template"
assert_grep "$ISSUE_CMD" \
  '## Likely root cause' \
  "## Likely root cause heading survives in bug template"
assert_no_grep "$ISSUE_CMD" \
  '## Security signals' \
  "## Security signals heading removed from bug template"
assert_no_grep "$ISSUE_CMD" \
  '## Current ecosystem' \
  "## Current ecosystem heading removed from feat template"
assert_no_grep "$ISSUE_CMD" \
  '## Constraints' \
  "## Constraints heading removed from feat template"

echo
echo "== Legacy research-cache readers retired (#518) =="
# This roster is DELIBERATELY not repo-wide. The `.uberdev/research/issue-`
# literal legitimately survives in four places, and a repo-wide sweep would
# red on all of them:
#   1. skills/orchestrator/SKILL.md:16   — the retained trust rule (kept
#      verbatim for any future reintroduction of artifact reuse).
#   2. skills/orchestrator/SKILL.md:373  — the deletion decision record.
#   3. skills/finish-branch/SKILL.md:185 — the deleted-glob comment, itself
#      positively pinned by finish-branch-auto-chain.test.sh G2.
#   4. CHANGELOG.md                      — append-only release history; six
#      hits that describe the cache as it was, and must never be rewritten.
# What must NOT survive is a live *reader*: an instruction that tells an agent
# or a solver to go read that path today.
assert_no_grep "$SOLVE_LAUNCHER" \
  '\.uberdev/research/issue-' \
  "solve-launcher heredocs no longer read .uberdev/research/issue- (#518)"
assert_no_grep "$SOLVE_LAUNCHER" \
  'Read pre-collected research' \
  "solve-launcher has no 'Read pre-collected research' prompt step (#518)"
assert_no_grep "$SOLVE_LAUNCHER" \
  'pre-collected-research' \
  "solve-launcher branch comments drop the pre-collected-research claim (#518)"
assert_no_grep "$SOLVE_SKILL" \
  'Read pre-collected research' \
  "solve-pipeline triage table drops the retired research-read step (#518)"
assert_no_grep "$SPEC_WRITER" \
  '\.uberdev/research/issue-' \
  "spec-writer trust rule no longer names the retired cache path (#518)"
assert_no_grep "$SPEC_WRITER" \
  'cached short-circuit' \
  "spec-writer no longer cites the deleted Phase-1 cached short-circuit (#518)"
# Positive locks. Each negative above is paired with one of these on the same
# file, so "reworded" is distinguishable from "deleted" or "emptied".
assert_grep "$SPEC_WRITER" \
  'cached-research-issue-' \
  "spec-writer keeps the untrusted-input envelope source tag"
assert_grep "$SPEC_WRITER" \
  'research_paths' \
  "spec-writer trust rule keeps its live subject (research_paths entries)"
assert_grep "$SOLVE_LAUNCHER" \
  'gh issue view' \
  "solve-launcher trivial/small prompt heredocs still exist"
assert_grep "$SOLVE_SKILL" \
  'lightweight TodoWrite plan' \
  "solve-pipeline small row still describes a workflow"

echo
echo "== /issue is autopilot: the confirm gate is gone (#723) =="
# NEGATIVES. Each names one of the five sentences that carried the gate. A
# repo-wide sweep outside CHANGELOG.md found exactly these five, so the set
# is closed: a sixth copy cannot hide in a skill.
assert_no_grep "$ISSUE_CMD" \
  '^## Phase 5: Confirm$' \
  "Phase 5 is no longer a bare Confirm section"
assert_no_grep "$ISSUE_CMD" \
  'STOP and show the draft to the user' \
  "the draft-confirm stop instruction is removed"
assert_no_grep "$ISSUE_CMD" \
  '\*\*Always confirm\*\*' \
  "the Always confirm rule is removed"
# Scoped to the create call, not to the bare phrase: this row's subject is the
# create gate, but the file also carries the SURVIVING '/solve is never
# auto-run' rule phrased "always wait for the user". A whole-file negative on
# 'wait for explicit approval' would red if that surviving sentence were ever
# reworded — a false red on prose this same change protects.
assert_no_grep "$ISSUE_CMD" \
  'wait for explicit approval before `gh issue create`' \
  "no rule still demands explicit approval before gh issue create"
assert_no_grep "$ISSUE_CMD" \
  'confirms with the user' \
  "the header pipeline summary no longer claims a user-confirm step"
assert_no_grep "$ISSUE_CMD" \
  'Show the user a complete draft BEFORE creating' \
  "Phase 4 no longer frames the draft as a pre-create prompt"

# POSITIVES, half of them on SURVIVING behaviour. A negative grep alone cannot
# distinguish "gate removed" from "file emptied or renamed"; these rows can.
assert_grep "$ISSUE_CMD" \
  '\*\*Autopilot \(always ON\)\.\*\*' \
  "issue.md declares unconditional autopilot"
assert_grep "$ISSUE_CMD" \
  'no config key and no `--confirm` flag' \
  "autopilot is declared unconditional — no knob, no inverse flag"
assert_grep "$ISSUE_CMD" \
  '^## Phase 5: Open-duplicate gate \(the only halt\)$' \
  "Phase 5 is now the open-duplicate gate"
# The prose is sentence-initial "Proceed", so the class is required: assert_grep
# is case-sensitive grep -qE. Do NOT lowercase this to match plan.md's literal.
assert_grep "$ISSUE_CMD" \
  '[Pp]roceed \*\*straight to Phase 6\*\*' \
  "the no-duplicate path goes straight to create, in one turn"
assert_grep "$ISSUE_CMD" \
  'Do not run `gh issue create` until the user answers' \
  "an OPEN duplicate still halts before the mutation"
assert_grep "$ISSUE_CMD" \
  '\*\*Closed\*\* duplicates never halt' \
  "closed duplicates stay regression evidence, not a gate"
assert_grep "$ISSUE_CMD" \
  '\*\*Autopilot: never confirm\*\*' \
  "the Rules list carries the autopilot rule in place of Always confirm"

# Degradations are REPORTED, never gates (AC 3), and the Phase 7 follow-up
# block survives intact (AC 4).
assert_grep "$ISSUE_CMD" \
  'never promoted to gates' \
  "scout degradations are reported, not turned into gates"
assert_grep "$ISSUE_CMD" \
  '^degradation: ' \
  "the Phase 7 result block carries a degradation line"
assert_grep "$ISSUE_CMD" \
  'Next step: /solve \$ISSUE_NUM' \
  "the Phase 7 follow-up block still prints"
assert_grep "$ISSUE_CMD" \
  '\*\*Do not run `/solve` automatically\*\*' \
  "/solve is still never auto-run"

echo
echo "== README and RFC 0012 match the autopilot behaviour (#723) =="
# Scoped to the /issue pipeline arrow (the removed literal was
# 'draft -> user-confirm -> create'), not to the bare word: README.md documents
# fifteen commands and already discusses confirm-gate semantics for /merge, so
# a whole-file negative would red on prose that has nothing to do with /issue.
# ASCII-only per the plan's D7 — '.*' spans the non-ASCII arrows.
assert_no_grep "$README_MD" \
  'draft.*user-confirm.*create' \
  "README /issue pipeline no longer claims a user-confirm step"
assert_grep "$README_MD" \
  'investigation-first issue creation' \
  "README /issue section still exists (anti-vacuity anchor for the row above)"
assert_grep "$README_MD" \
  'one turn, no approval prompt' \
  "README /issue section describes the autopilot default"
assert_grep "$README_MD" \
  'no opt-out key and no `--confirm` flag' \
  "README records that no knob and no inverse flag landed"
assert_grep "$RFC12" \
  'deliberate draft-confirm gate protecting a GitHub mutation' \
  "RFC 0012 keeps its original light-R1 verdict verbatim (no re-baseline)"
assert_grep "$RFC12" \
  '\*\*SUPERSEDED IN PART \(#723\)\.\*\*' \
  "RFC 0012 records the supersession alongside the retained verdict"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
