#!/usr/bin/env bash
# tests/turbox-fleet.test.sh — shape-check suite for the /turbox standard-mode
# solver fleet (RFC 0020).
#
# This file asserts over SOURCE BYTES only: the command file, the pipeline
# skill, the launcher's --standard seam, the lib's subcommand surface, and the
# RFC. It is portable (grep/awk only — no mktemp, no git, no python) and runs
# on both CI jobs. The lib's RUNTIME behaviour — the disjointness refusal, the
# staging refusals, the caps — is tested by tests/turbox-fleet-runtime.test.sh,
# which is declared Unix-only.
#
# Sections:
#   TX1  — command file structure + the no-Workflow invariant
#   TX2  — the command mandates the launcher call and the skill, not Workflow()
#   TX3  — pipeline skill structure: frontmatter, every phase, the invariants
#   TX4  — the lane's REASON is stated: wave-parallel over disjoint Owns sets
#   TX5  — controller-only git + explicit-path staging are stated as rules
#   TX6  — one-message dispatch (dispatch-before-wait) is stated per phase
#   TX7  — return contracts: the three fenced blocks and their keys
#   TX8  — circuit breakers TB1..TB4 are named in skill AND lib
#   TX9  — launcher: --standard is parsed, refuses --backend, pins workflow
#   TX10 — launcher: Step 5s emits TURBOX_PLAN markers, never WORKFLOW_ARGS
#   TX11 — lib: every subcommand the skill calls exists in the dispatcher
#   TX12 — the parallel-issue cap of 3 has ONE definition (anti-drift)
#   TX13 — RFC 0020 exists, is numbered uniquely, and states the decision
#   TX14 — the lib is invoked as an executable, never sourced (zsh trap)
set -u; set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/turbox.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/turbox-fleet/SKILL.md"
LIB="$REPO_ROOT/plugins/uberdev/lib/turbox-fleet.sh"
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
RFC="$REPO_ROOT/docs/rfc/0020-turbox-standard-mode-fleet.md"

for f in "$CMD" "$SKILL" "$LIB" "$LAUNCHER" "$RFC"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

echo "== TX1: command file structure + the no-Workflow invariant =="
ck "has description frontmatter"   "grep -q '^description:' '$CMD'"
ck "has argument-hint"             "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools"             "grep -q '^allowed-tools:' '$CMD'"
ck "allowed-tools declares Task"   "[ \$(grep '^allowed-tools:' '$CMD' | grep -c '\"Task\"') -ge 1 ]"
# The lane's defining negative: /turbox must not be able to call Workflow.
# A turbox plan relayed into Workflow() is a category error, and the cheapest
# place to make that impossible is the tool list.
ck "allowed-tools OMITS Workflow"  "[ \$(grep '^allowed-tools:' '$CMD' | grep -c 'Workflow') -eq 0 ]"

echo "== TX2: the command mandates the launcher call and the skill =="
ck "runs lib/solve-launcher.sh"        "grep -q 'lib/solve-launcher.sh' '$CMD'"
ck "passes --auto-mode=1 --turbo"      "grep -q '\-\-auto-mode=1 --turbo' '$CMD'"
ck "passes --standard"                 "grep -q '\-\-standard' '$CMD'"
ck "forwards \$ARGUMENTS after --"     "grep -q '\-\- \$ARGUMENTS' '$CMD'"
ck "names the turbox-fleet skill"      "grep -q 'uberdev:turbox-fleet' '$CMD'"
ck "names TURBOX_PLAN_BEGIN"           "grep -q 'TURBOX_PLAN_BEGIN' '$CMD'"
ck "names TURBOX_PLAN_END"             "grep -q 'TURBOX_PLAN_END' '$CMD'"
ck "says relay verbatim (DR-2)"        "grep -qi 'verbatim' '$CMD'"
ck "forbids calling Workflow in prose" "grep -q 'Do not call \`Workflow\`' '$CMD'"
ck "documents that --backend is refused" "grep -q '\`--backend=<name>\` is REFUSED' '$CMD'"

echo "== TX3: pipeline skill structure =="
ck "skill has name frontmatter"     "grep -q '^name: turbox-fleet' '$SKILL'"
ck "skill has description"          "grep -q '^description:' '$SKILL'"
for phase in 0 1 2 3 4 5 6 7; do
  ck "has '## Phase $phase'"        "grep -q '^## Phase $phase ' '$SKILL'"
done
ck "has an Inputs section"          "grep -q '^## Inputs' '$SKILL'"
ck "has an Invariants section"      "grep -q '^## Invariants' '$SKILL'"
ck "has Return contracts"           "grep -q '^## Return contracts' '$SKILL'"
ck "has Circuit breakers"           "grep -q '^## Circuit breakers' '$SKILL'"

echo "== TX4: the lane's REASON is stated, not assumed =="
ck "states Workflow agents have no Task tool" "grep -q 'no \`Task\` tool' '$SKILL'"
ck "states the Workflow lane is sequential"   "grep -qi 'sequential per-task loop' '$SKILL'"
ck "names wave-parallel implementation"       "grep -qi 'wave-parallel' '$SKILL'"
ck "names the Owns file allowlist"            "grep -q 'Owns (file allowlist)' '$SKILL'"
ck "warns against silently reverting to /turbo" \
   "grep -qi 'silently reverted to' '$SKILL'"

echo "== TX5: controller-only git + explicit-path staging =="
ck "states the two-writers rule"        "grep -qi 'two or more concurrent writers' '$SKILL'"
ck "implementers never run git"         "grep -qi 'implementers never run git' '$SKILL'"
ck "routes every commit via stage-commit" "grep -q 'stage-commit' '$SKILL'"
ck "names the refused stage-everything forms" \
   "grep -q 'refuses \`-A\`, \`--all\`' '$SKILL'"
# Fragment chosen to sit inside one line: the sentence wraps in the skill, and
# grep is line-oriented, so a longer needle would assert the line breaks rather
# than the rule.
ck "forbids prose-reconstructed staging lists" \
   "grep -qi 'reconstructed from its prose' '$SKILL'"
# The negative control: a skill that told the controller to stage everything
# would defeat the lib's refusal by never reaching it.
ck "skill never instructs a bare 'git add -A'" \
   "[ \$(grep -c 'git add -A' '$SKILL') -eq 0 ]"

echo "== TX6: dispatch-before-wait is stated where it matters =="
ck "invariant names ONE message"        "grep -q 'in \*\*ONE message\*\*' '$SKILL'"
ck "research phase says ALL x ALL"      "grep -q 'ALL issues × ALL lenses in ONE message' '$SKILL'"
ck "impl phase dispatches a whole wave" "grep -q 'Every task of wave \*k\*, for every issue, in ONE message' '$SKILL'"
ck "delivery dispatches all issues"     "grep -q 'all issues in one message' '$SKILL'"

echo "== TX7: return contracts =="
ck "implementer fence has status:"      "grep -q '^status: DONE' '$SKILL'"
ck "implementer fence has paths:"       "grep -q '^paths:' '$SKILL'"
ck "implementer fence has tests:"       "grep -q '^tests:' '$SKILL'"
ck "implementer fence has blocker:"     "grep -q '^blocker: null' '$SKILL'"
ck "reviewer fence has verdict:"        "grep -q '^verdict: APPROVE' '$SKILL'"
ck "reviewer fence has report_path:"    "grep -q '^report_path:' '$SKILL'"
ck "delivery fence has pr_number:"      "grep -q '^pr_number:' '$SKILL'"
ck "an unparseable fence is a blocker"  "grep -qi 'unparseable block is a blocker' '$SKILL'"
ck "names NOT_APPLICABLE sentinel"      "grep -q 'NOT_APPLICABLE' '$SKILL'"
ck "names UNREVIEWED and counts it"     "grep -q 'UNREVIEWED' '$SKILL'"

echo "== TX8: circuit breakers are named in BOTH the skill and the lib =="
for cb in TB1 TB2 TB3 TB4; do
  ck "skill names $cb"                  "grep -q '$cb' '$SKILL'"
done
ck "lib names TB1 (project-agents)"     "grep -q 'TB1' '$LIB'"
ck "lib names TB2 (budget-spend)"       "grep -q 'TB2' '$LIB'"
ck "skill reads caps from loop-cap"     "grep -q 'loop-cap' '$SKILL'"
ck "skill forbids restating a cap"      "grep -qi 'Never restate a cap' '$SKILL'"
# Every cap the lib defines must have a CONSUMER in the skill. A cap nothing
# reads is a dead contract — the class this project audits for by counting read
# sites per schema property, not by reading the declaration.
for loop in fix_rounds retest_rounds context_rounds; do
  ck "the '$loop' cap is actually consumed by a phase" \
     "grep -q -- '--loop $loop' '$SKILL'"
done
ck "NEEDS_CONTEXT is in the implementer status vocabulary" \
   "grep -q 'NEEDS_CONTEXT' '$SKILL'"
ck "NEEDS_CONTEXT and BLOCKED are kept distinct" \
   "grep -qi 'must not be collapsed' '$SKILL'"

echo "== TX9: launcher parses --standard and refuses --backend =="
ck "STANDARD_MODE initialised"          "grep -q '^STANDARD_MODE=0' '$LAUNCHER'"
ck "--standard is a launcher option"    "grep -q -- '--standard)    STANDARD_MODE=1' '$LAUNCHER'"
ck "usage error names --standard"       "grep -q 'only --auto-mode=0|1, --turbo, --standard, --' '$LAUNCHER'"
ck "refuses --standard + --backend flag" \
   "grep -q 'and --backend=\$BACKEND_FLAG_VALUE are mutually exclusive' '$LAUNCHER'"
ck "refuses --standard + env backend" \
   "grep -q 'and UBERDEV_DISPATCH_BACKEND=\$UBERDEV_DISPATCH_BACKEND are mutually exclusive' '$LAUNCHER'"
ck "both refusals precede any claim write" \
   "[ \$(grep -c 'no claims written; no agents dispatched' '$LAUNCHER') -ge 2 ]"
ck "pins the resolver to workflow"      "grep -q 'DISPATCH_BACKEND=workflow' '$LAUNCHER'"
ck "audits the pin"                     "grep -q 'standard_mode_backend_pinned' '$LAUNCHER'"
# The pin must not smuggle a new member into the dispatch-backend enum: RFC
# 0020 §2 rejects that design and nine copies of the enum depend on it.
ck "'standard' is NOT added to the backend enum" \
   "[ \$(grep -c 'auto|workflow|wezterm|background|standard' '$LAUNCHER') -eq 0 ]"

echo "== TX10: launcher Step 5s emits a turbox plan, not Workflow args =="
ck "Step 5s block exists"               "grep -q 'Step 5s — the /turbox standard-mode plan' '$LAUNCHER'"
ck "emits TURBOX_PLAN_BEGIN"            "grep -q 'echo \"TURBOX_PLAN_BEGIN\"' '$LAUNCHER'"
ck "emits TURBOX_PLAN_END"              "grep -q 'echo \"TURBOX_PLAN_END\"' '$LAUNCHER'"
ck "validates lib/turbox-fleet.sh at preflight" "grep -q 'TURBOX_FLEET_LIB=' '$LAUNCHER'"
ck "validates the skill at preflight"   "grep -q 'TURBOX_FLEET_SKILL=' '$LAUNCHER'"
ck "resolves fanout_concurrency.turbox" "grep -q 'fanout_concurrency.turbox' '$LAUNCHER'"
ck "standard branch exits before Step 5w emit" \
   "awk '/Step 5s — the \\/turbox standard-mode plan/{s=NR} /uberdev_emit_workflow_args solve-fleet/{w=NR} END{exit !(s && w && s < w)}' '$LAUNCHER'"
ck "plan carries worktreeRootAbs"       "grep -q 'worktreeRootAbs' '$LAUNCHER'"
ck "plan carries implementBudget"       "grep -q 'implementBudget' '$LAUNCHER'"
ck "plan carries fixRounds"             "grep -q 'fixRounds' '$LAUNCHER'"

echo "== TX11: every lib subcommand the skill calls is dispatchable =="
for sub in loop-cap round-permitted issue-concurrency project-agents \
           budget-spend plan-tasks wave-disjoint stage-commit worktree-add audit; do
  ck "lib dispatches '$sub'"            "grep -qE '^[[:space:]]+$sub\)' '$LIB'"
done
# Anti-drift in the other direction: the skill must not invoke a subcommand the
# lib does not have. Every `bash \"\$LIB\" <sub>` in the skill is checked.
missing_subs="$(grep -oE 'bash "\$LIB" [a-z-]+' "$SKILL" | awk '{print $3}' | sort -u | while read -r s; do
  grep -qE "^[[:space:]]+$s\)" "$LIB" || echo "$s"
done)"
ck "skill invokes no unknown subcommand (found: '${missing_subs:-none}')" "[ -z '$missing_subs' ]"

echo "== TX11b: the skill still names a full agent roster =="
# NARROWED by #628. The RESOLUTION half — does every named agentType exist in
# agents/ — moved to tests/epipe-guard.test.sh L10, together with the
# `turbox-fleet` special case (a name resolving to skills/<name>/SKILL.md is
# skipped there for any skill, not just this one). The extractor below required
# BACKTICK delimiters and so was blind to the operative
# `subagent_type: uberdev:<agent>` spelling; L10 reads both shapes across the
# whole shipped corpus and measured 21 of 21 dispatch sites that this extractor
# cannot see.
#
# What stays is the half L10 cannot express: a FLOOR on how many agent types
# THIS skill names. L10 answers "does every name resolve"; it cannot notice a
# phase quietly losing its agent, because a shorter roster still resolves
# perfectly. Derived from the skill, so a new agent needs no edit here.
named_agents="$(grep -oE '`uberdev:[a-z0-9-]+`' "$SKILL" | tr -d '`' | sed 's/^uberdev://' | sort -u)"
ck "the skill names at least 8 agent types (found: $(printf '%s' "$named_agents" | grep -c .))" \
   "[ \$(printf '%s' \"\$named_agents\" | grep -c .) -ge 8 ]"

echo "== TX12: the parallel-issue cap of 3 has ONE definition =="
ck "lib defines TURBOX_ISSUE_CAP=3"     "grep -q '^TURBOX_ISSUE_CAP=3' '$LIB'"
ck "lib clamps against that constant"   "grep -q 'gt \"\$TURBOX_ISSUE_CAP\"' '$LIB'"
ck "launcher does NOT restate the cap numerically" \
   "[ \$(grep -c 'issue-concurrency --configured' '$LAUNCHER') -eq 1 ]"
ck "launcher reads the cap from the lib for its notice" \
   "grep -q 'loop-cap issue_cap' '$LAUNCHER'"
ck "command file states the cap of 3"   "grep -q 'cap: 3' '$CMD'"
ck "RFC states the cap of 3"            "grep -q 'parallel-issue cap is 3' '$RFC'"

echo "== TX13: RFC 0020 =="
ck "RFC title names /turbox"            "grep -q '^# RFC 0020' '$RFC'"
ck "RFC status is Accepted"             "grep -q '| \*\*Status\*\* | Accepted |' '$RFC'"
ck "RFC states the decision"            "grep -q '^## 1. Decision' '$RFC'"
ck "RFC justifies not-a-backend"        "grep -q 'NOT a \`dispatch_backend\` value' '$RFC'"
ck "RFC lists what the lane gives up"   "grep -qi 'What \`/turbox\` gives up' '$RFC'"
ck "RFC records rejected alternatives"  "grep -q '^## 5. Alternatives considered' '$RFC'"
ck "RFC has acceptance criteria"        "grep -q '^## 6. Acceptance criteria' '$RFC'"
ck "RFC number 0020 is unique"          "[ \$(ls '$REPO_ROOT/docs/rfc/' | grep -c '^0020-') -eq 1 ]"

echo "== TX14: the lib is an executable, never sourced (the zsh trap) =="
ck "lib has a bash shebang"             "[ \$(head -1 '$LIB' | grep -c '^#!/usr/bin/env bash') -ge 1 ]"
ck "lib documents the never-source rule" "grep -q 'never a sourced library' '$LIB'"
ck "skill documents the never-source rule" "grep -qi 'executable\*\*, never sourced' '$SKILL'"
# A `. \$LIB` / `source \$LIB` anywhere in the skill would run the body under
# the Bash tool's /bin/zsh, which is the class this project keeps re-hitting.
ck "skill never sources the lib"        "[ \$(grep -cE '(^|[^a-z])(source|\.) +\"?\\\$LIB' '$SKILL') -eq 0 ]"
ck "command never sources the lib"      "[ \$(grep -cE '(^|[^a-z])(source|\.) +\"?\\\$LIB' '$CMD') -eq 0 ]"

echo "== TX15: the issue-body channel is locked end to end =="
# The step this locks was MISSING on the first live run: invariant 2 demanded a
# path to an artifact nothing created, and the tempting repair was to paste the
# body into the prompt -- the exact thing the invariant forbids. The suite has
# to ratchet it for the same reason it ratchets agent names: a gap here fails at
# Phase 2, mid-run, after the claims are already written.
#
# Needles deliberately avoid a `$` so the eval in ck() cannot expand one under
# `set -u` -- the bug this very section shipped on its first draft.
ck "launcher persists an issue-body artifact"   "[ \$(grep -c 'issue-body-' '$LAUNCHER') -ge 1 ]"
ck "launcher caps the persisted body"           "[ \$(grep -c 'UBERDEV_ISSUE_BODY_CAP' '$LAUNCHER') -ge 2 ]"
ck "the cap defaults to 64 KiB in ONE place"    "[ \$(grep -c 'UBERDEV_ISSUE_BODY_CAP:=65536' '$LAUNCHER') -eq 1 ]"
ck "launcher writes it O_EXCL"                  "[ \$(grep -c 'O_EXCL' '$LAUNCHER') -ge 1 ]"
ck "launcher writes it at 0600"                 "[ \$(grep -c '0o600' '$LAUNCHER') -ge 1 ]"
ck "manifest carries issue_body_file"           "[ \$(grep -c 'issue_body_file' '$LAUNCHER') -ge 2 ]"
ck "skill names issue_body_file"                "[ \$(grep -c 'issue_body_file' '$SKILL') -ge 3 ]"
ck "skill states context_file is NOT the body"  "grep -q 'NOT the issue body' '$SKILL'"
# The regression that shipped: three sites told the controller to read the issue
# body out of context_file. None may come back.
ck "no site reads the body from context_file"   "[ \$(grep -c 'issue body from its .context_file' '$SKILL') -eq 0 ]"
ck "controller is told not to re-fetch it"      "[ \$(grep -c 're-fetch the body' '$SKILL') -ge 1 ]"
ck "controller is told not to open it itself"   "[ \$(grep -c 'never open the file' '$SKILL') -ge 1 ]"
ck "an absent issue_body_file is audited"       "grep -q 'issue_body_missing' '$SKILL'"
ck "stale-card warning names spec-reviewer"     "grep -q 'agents/spec-reviewer.md' '$SKILL'"
ck "stale-card warning names spec-writer"       "grep -q 'agents/spec-writer.md' '$SKILL'"
ck "research phase names the inputs it passes"  "grep -q 'Every lens gets the same three inputs' '$SKILL'"
# #623 renamed the six research-* cards onto the wire keys the orchestrator was
# already sending. This controller is the SECOND dispatcher of those same cards
# and nothing else in the suite compares it against them, so the rename could --
# and on its first draft did -- leave Phase 2 handing every lens a `summary_dir`
# DIRECTORY that the card no longer accepts, while all 120 CI tests stayed green.
# The cross-dispatcher comparator lives in orchestrator-plan-flatten.test.sh
# (F2h); these rows are the turbox-side half, in the file that owns this prose.
ck "phase 2 passes the summary_path wire key"   "grep -q 'summary_path' '$SKILL'"
ck "phase 2 never passes a summary DIRECTORY"   "[ \$(grep -c 'summary_dir' '$SKILL') -eq 0 ]"
ck "each issue x lens gets its own artifact"    "grep -q 'research/<lens>.md' '$SKILL'"
# The stale-card warning is operative instruction, not commentary: a controller
# told the research cards are wrong will override cards that are now right.
ck "stale-card warning is scoped to two cards"  "grep -q 'Both cards are stale' '$SKILL'"
ck "research cards are NOT called stale"        "[ \$(grep -c 'cards declare' '$SKILL') -eq 0 ]"
ck "no deferral pointer to the closed #623"     "[ \$(grep -c '#623' '$SKILL') -eq 0 ]"

echo
echo "== Summary =="
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
