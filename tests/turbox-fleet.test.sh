#!/usr/bin/env bash
# tests/turbox-fleet.test.sh — shape-check suite for the /turbox standard-mode
# solver fleet (RFC 0020).
#
# TX1..TX16 assert over SOURCE BYTES only: the command file, the pipeline
# skill, the launcher's --standard seam, the lib's subcommand surface, and the
# RFC. Those sections are portable (grep/awk only — no mktemp, no git, no
# python) and run on both CI jobs. The lib's RUNTIME behaviour — the
# disjointness refusal, the staging refusals, the caps — is tested by
# tests/turbox-fleet-runtime.test.sh, which is declared Unix-only.
#
# TX17 is the one EXECUTED section here, and it is deliberate: the defect it
# pins (#670) is invisible to a grep, because the broken and the fixed parser
# carry the SAME words. It runs the real `plan-tasks` over real plans. It is
# self-gated off Git Bash — loudly, never silently — for the reason test.yml's
# windows-skip-list already records for the runtime twin; see the section
# preamble. Keep new rows in TX1..TX16 grep-only.
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
#   TX15 — the issue-body channel is locked end to end
#   TX16 — the design path is two rungs, and no spec artifact survives (#656)
#   TX17 — EXECUTED: a REFUSED Owns value never adopts the list below it (#670)
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
ck "research phase batches every gated issue" \
   "grep -q 'ALL risk-gated issues in ONE message' '$SKILL'"
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
# skipped there for any skill, not just this one).
#
# What stays is the half L10 cannot express: a FLOOR on how many agent types
# THIS skill names, and membership in both directions. L10 answers "does every
# name resolve"; it cannot notice a phase quietly LOSING its agent, because a
# shorter roster still resolves perfectly, and it cannot notice a phase GAINING
# one it should not have, because `spec-writer` resolves perfectly too. Derived
# from the skill, so a new agent needs no edit here.
#
# RETARGETED by #656, which collapsed the design path. The roster went from 12
# names to 6 when the three always-on research lenses and the three spec rungs
# left this lane, so the floor moved 8 -> 6 with it. A lowered floor on its own
# is a weaker guard, and lowering one in the same commit that changes what it
# guards is how a register quietly stops registering. So the floor is now paired
# with membership rows in BOTH directions: six names that must be there, seven
# that must not. Together they pin the roster exactly, where the count alone
# could not tell a lost agent from a swapped one.
#
# That pairing only holds if the extractor can SEE a dispatch, and until this
# round it could not: it required BACKTICK delimiters and was blind to the
# operative `subagent_type: uberdev:<agent>` spelling, which left every
# membership row below ornamental. MEASURED, not argued: with the backtick-only
# extractor, rewriting the Phase 3 design rung to dispatch
# `subagent_type: uberdev:plan-writer`, and separately resurrecting the whole
# four-rung spec chain in that same spelling, each left this suite at PASS=155
# FAIL=0. L10.1 does not close it either — it asks only whether a DISPATCHED
# name resolves in agents/, and `spec-writer` resolves fine. So the extractor
# reads both shapes now.
#
# The two shapes are deliberately the same two tests/epipe-guard.test.sh L10
# uses (`L10_CITE_RE` / `L10_DISPATCH_RE`), down to matching `subagent_type`
# with either `:` or `=` after it, because the corpus uses both spellings.
# Placeholder names (`uberdev:<agent>`) are matched and then dropped rather than
# counted — the same call L10 makes in `_l10_unresolved`.
tx_cite_re='`uberdev:[a-z0-9<>_-]+`'
tx_dispatch_re='subagent_type[[:space:]]*[:=][[:space:]]*["'"'"']?uberdev:[a-z0-9<>_-]+'
# ONE extractor, TWO readers: the live skill here, and the polarity fixture at
# the end of this section. A fixture that re-typed this pipeline would be a COPY
# of it, permanently green through a revert to backticks-only — which is the
# defect being closed, not a way to re-ship it. Corpus on stdin, one name a line.
tx_roster() {
  grep -oE -e "$tx_cite_re" -e "$tx_dispatch_re" \
    | sed -e 's/.*uberdev://' -e 's/`$//' -e '/[<>]/d' | sort -u
}
named_agents="$(tx_roster < "$SKILL")"
ck "the skill names at least 6 agent types (found: $(printf '%s' "$named_agents" | grep -c .))" \
   "[ \$(printf '%s' \"\$named_agents\" | grep -c .) -ge 6 ]"
# Membership, positive: the post-collapse roster, one row per name.
#
# A HERESTRING, never `printf ... | grep -q`. This file sets pipefail (:29), and
# piping into a reader that can exit before its writer's last write is the EPIPE
# class tests/epipe-guard.test.sh E1 reds on BOTH CI jobs. TX11b's own
# `printf ... | grep -c .` above is safe because `grep -c` reads to EOF; `-q`
# beside it would not be, and it is the obvious thing to copy.
for agent in code-reviewer design-planner implementation-worker \
             plan-reviewer research-security spec-compliance-reviewer; do
  ck "the roster names '$agent'"        "grep -qxF '$agent' <<<\"\$named_agents\""
done
# Membership, negative: the seven #656 took off THIS lane. Each remains a live,
# shipped card for /solve, /turbo and the orchestrator -- only their absence
# from this controller is asserted, never their absence from the repo.
for agent in plan-writer research-codebase research-constraints \
             research-test-coverage spec-reviewer spec-reviser spec-writer; do
  ck "the lane no longer dispatches '$agent'" \
     "! grep -qxF '$agent' <<<\"\$named_agents\""
done
# Polarity fixture. Every row in this section is worth exactly what the
# extractor can see, so that is MEASURED here rather than asserted in the prose
# above — through `tx_roster` itself, never a re-typed copy of it. Revert the
# extractor to backticks-only and the first row reds; widen it to a bare
# `uberdev:<name>` and the third does. Herestrings, never `printf ... | grep -q`:
# this file sets pipefail (:29) and that pipe is the EPIPE class
# tests/epipe-guard.test.sh E1 reds on BOTH CI jobs.
tx_fixture='rung one dispatches subagent_type: uberdev:plan-writer
rung two cites `uberdev:design-planner`
the report prints `gh issue edit 7 --remove-label uberdev:active`'
tx_fixture_roster="$(tx_roster <<<"$tx_fixture")"
ck "the extractor sees a subagent_type: dispatch" \
   "grep -qxF 'plan-writer' <<<\"\$tx_fixture_roster\""
ck "the extractor still sees a backticked citation" \
   "grep -qxF 'design-planner' <<<\"\$tx_fixture_roster\""
# The other polarity, and not a hypothetical: the skill names the `uberdev:active`
# LABEL three times, inside longer backticked command spans. It has to stay out
# of the roster. A needle loose enough to sweep it in would put a non-agent into
# the floor's count and leave all seven negative rows measuring noise.
ck "a bare label mention is not counted as an agent" \
   "! grep -qxF 'active' <<<\"\$tx_fixture_roster\""

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
ck "not-dispatched-here note names spec-reviewer" "grep -q 'agents/spec-reviewer.md' '$SKILL'"
ck "not-dispatched-here note names spec-writer"   "grep -q 'agents/spec-writer.md' '$SKILL'"
ck "research phase names the inputs it passes"  "grep -q 'The security lens gets the same three inputs' '$SKILL'"
# #623 renamed the six research-* cards onto the wire keys the orchestrator was
# already sending. This controller is the SECOND dispatcher of those same cards
# and nothing else in the suite compares it against them, so the rename could --
# and on its first draft did -- leave Phase 2 handing every lens a `summary_dir`
# DIRECTORY that the card no longer accepts, while all 120 CI tests stayed green.
# The cross-dispatcher comparator lives in orchestrator-plan-flatten.test.sh
# (F2h); these rows are the turbox-side half, in the file that owns this prose.
ck "phase 2 passes the summary_path wire key"   "grep -q 'summary_path' '$SKILL'"
ck "phase 2 never passes a summary DIRECTORY"   "[ \$(grep -c 'summary_dir' '$SKILL') -eq 0 ]"
ck "the one surviving lens names its artifact"  "grep -q 'research/security.md' '$SKILL'"
# The spec-card note is operative instruction, not commentary. It used to say
# both cards were STALE; after #656 they are simply not dispatched here, and
# they stay correct for the lanes that do dispatch them. A controller told a
# live card is wrong will override a card that is now right, so the note has to
# say not-here rather than not-valid -- and this row is what holds it to that.
ck "the two spec cards are marked not-dispatched-here" \
   "grep -q 'Neither card is dispatched on this lane' '$SKILL'"
ck "research cards are NOT called stale"        "[ \$(grep -c 'cards declare' '$SKILL') -eq 0 ]"
ck "no deferral pointer to the closed #623"     "[ \$(grep -c '#623' '$SKILL') -eq 0 ]"

echo "== TX16: the design path is two rungs, and no spec artifact survives =="
# #656 collapsed Phase 2's fan-out and Phase 3's five rungs into
# research-security -> design-planner -> plan-reviewer. Four rows, because the
# collapse has to be self-proving: TX11b's roster rows say design-planner is
# NAMED, the first three here say it is WIRED -- to a rung, to an output path,
# and to a requirements document -- and the fourth is the negative control that
# says the thing it replaced is actually gone.
ck "the design rung dispatches design-planner"  "grep -q 'uberdev:design-planner' '$SKILL'"
# Scoped to the Phase 3 section on purpose. The same token appears in Phase 4's
# `plan-tasks --plan` line, which predates the collapse -- so a whole-file grep
# is vacuous: it stays green on a skill whose design rung binds no `plan_path`
# at all, and it passes unchanged against the pre-collapse skill. Only the
# section-scoped form proves the RUNG is pointed at that path. The awk range
# reads to EOF, so it is E1-safe, and the needle carries no `$` (ck() evals).
#
# The range's END pattern is load-bearing, and it is NOT independent of TX3: it
# is TX3's `has '## Phase 4 '` row that keeps `/^## Phase 4 /` matchable. If TX3
# ever reds and someone repairs it by LOOSENING the pattern instead of restoring
# the heading, this range stops terminating, runs to EOF, swallows Phase 4's own
# `plan-tasks --plan <runDirAbs>/issue-<N>/plan.md` line, and this row goes
# silently vacuous again — green while asserting nothing. Repair a red TX3 by
# restoring the heading, never by relaxing either pattern.
ck "the design rung writes plan.md in the run dir" \
   "[ \$(awk '/^## Phase 3 /,/^## Phase 4 /' '$SKILL' | grep -c '<runDirAbs>/issue-<N>/plan.md') -ge 1 ]"
# Both reviewer rungs read the issue body as their requirements document on this
# lane -- Phase 3's plan-reviewer and Phase 5's spec-compliance-reviewer. The
# count is >= 2 because ONE of them stating it is the half-migration that would
# leave the other reviewer measuring a plan against a document that does not
# exist. The `.` in the pattern spans the backticks and the apostrophe: needles
# here carry no `$`, because ck() evals them (see the TX15 preamble).
ck "spec_path is bound to the issue body at BOTH reviewer rungs" \
   "[ \$(grep -cE 'spec_path. is that issue.s .issue_body_file. path' '$SKILL') -ge 2 ]"
# The negative control. Without it the collapse is asserted, not proven: every
# row above would still pass on a skill that ALSO kept the spec rungs. This is
# the row that reds until the last mention in Phase 3, Phase 4b' and Phase 5 is
# gone, which is why it cannot land before them.
ck "no spec artifact is written or read on this lane" \
   "[ \$(grep -c 'spec.md' '$SKILL') -eq 0 ]"

echo "== TX17: a REFUSED Owns value never adopts the list below it (#670) =="
# `split_paths` used to return `[]` for TWO different facts: "the label carried
# no value" and "the label carried a value this gate REFUSED". The caller's
# `if not owns: owns, i = read_bullet_list(...)` could not tell them apart, so a
# REFUSED inline declaration fell through and ADOPTED whatever bullet list
# happened to follow it — an allowlist the plan never gave that task, its own
# declaration dropped, `unowned` empty, and nothing in the output naming the
# substitution. The shape gate's own comment calls that outcome "fail-safe"; it
# was fail-OPEN, and vendor.json records the wave-disjoint guard as the
# precondition that makes the parallel-implementer policy safe.
#
# These rows EXECUTE because source bytes cannot separate the two parsers: both
# contain the same comment, the same regexes and the same fall-through line, and
# every grep that passes on the fix passes on the defect. Only running a plan
# through them tells them apart.
#
# NOT run on Git Bash, and the stand-down is PRINTED rather than silent:
# lib/turbox-fleet.sh hands python3 the `--plan` path on argv, and test.yml's
# windows-skip-list records that a mktemp -d `/tmp/...` argv path is precisely
# what python.exe cannot translate on that runner — the same class that keeps
# tests/turbox-fleet-runtime.test.sh off the Windows job. The ubuntu
# shape-checks job runs this same file, so every row below is executed on every
# CI set; only the second, redundant Windows execution stands down.
TX17_SKIP=""
if [ -n "${MSYSTEM:-}" ]; then
  TX17_SKIP="Git Bash (MSYSTEM=$MSYSTEM) — python3 cannot open the /tmp argv path the lib passes"
elif ! command -v python3 >/dev/null 2>&1; then
  TX17_SKIP="no python3 on PATH, and lib/turbox-fleet.sh hardcodes python3"
fi

if [ -n "$TX17_SKIP" ]; then
  echo "  SKIP  TX17 executed rows: $TX17_SKIP"
  echo "        (the same rows run on the ubuntu shape-checks job, which runs this file)"
else
  TX17_DIR="$(mktemp -d)" || { echo "FATAL: TX17 could not mktemp -d" >&2; exit 2; }
  trap 'rm -rf "$TX17_DIR"' EXIT

  # rc is asserted by its own row for every parse. A parser that DIED would
  # otherwise leave an empty JSON file and every grep row below would red with
  # no explanation of which failure it was looking at.
  tx17_rc_is() {
    local want="$1" got
    shift
    "$@" >/dev/null 2>&1
    got=$?
    [ "$got" -eq "$want" ]
  }

  # --- Fixture A: the adoption, with the adopted list COLLIDING -------------
  cat > "$TX17_DIR/adopt.md" <<'PLAN'
### Task 1: annotated inline path, unrelated bullet list below
**Wave:** wave 1
**Owns:** lib/alpha.sh (the fast path)

- lib/victim.sh
- lib/other.sh

### Task 2: plainly declares the victim
**Wave:** wave 1
**Owns:** lib/victim.sh
PLAN
  bash "$LIB" plan-tasks --plan "$TX17_DIR/adopt.md" > "$TX17_DIR/adopt.json" 2>/dev/null
  ck "A: the adoption fixture parses (rc 0)" \
     "tx17_rc_is 0 bash '$LIB' plan-tasks --plan '$TX17_DIR/adopt.md'"
  # The row the blocker is about. Before the fix Task 1 came back owning
  # ["lib/victim.sh","lib/other.sh"] — two files the plan never gave it.
  ck "A: the refusal is VISIBLE in the counter (unowned names task 1)" \
     "grep -qF '\"unowned\":[1]' '$TX17_DIR/adopt.json'"
  ck "A: task 1 owns NOTHING, not the list below its label" \
     "grep -qF '\"id\":1,\"owns\":[],' '$TX17_DIR/adopt.json'"
  # Named separately from the array assert: `lib/other.sh` appears NOWHERE in
  # the plan except that bullet list, so its absence from the whole output is
  # the direct statement that no adoption happened.
  ck "A: the bullet list below the label was never read" \
     "! grep -qF 'lib/other.sh' '$TX17_DIR/adopt.json'"
  ck "A: the refused value did not sneak through either" \
     "! grep -qF 'lib/alpha.sh' '$TX17_DIR/adopt.json'"
  # The positive control. Without it every row above would still pass on a
  # parser that simply returned no ownership for anything.
  ck "A: the sibling's plain declaration still parses" \
     "grep -qF '\"id\":2,\"owns\":[\"lib/victim.sh\"]' '$TX17_DIR/adopt.json'"
  # Downstream: TB3 now names the real fault (task 1 declared nothing this gate
  # accepts) instead of an overlap on a path task 1 never wrote. rc 3 -> rc 2.
  ck "A: TB3 reports missing ownership, not a fabricated overlap" \
     "tx17_rc_is 2 bash '$LIB' wave-disjoint --tasks-file '$TX17_DIR/adopt.json' --wave 1"

  # --- Fixture B: the legitimate bullet-list form, unchanged ----------------
  # agents/plan-writer.md teaches exactly two emissions and this is the second.
  # Making refusal distinguishable from absence must not cost the form that
  # DEPENDS on absence falling through.
  #
  # The SECOND bullet block is in the fixture to keep the boundary row honest.
  # `read_bullet_list` closes the list at the first blank line after it opens,
  # and `lib/not-the-allowlist.sh` is a bare path — shaped exactly like a real
  # allowlist entry — so nothing but that boundary keeps it out. A fixture whose
  # later bullets were all annotated prose would be refused by the shape gate
  # instead, and the row would pass with the boundary deleted.
  cat > "$TX17_DIR/bullet.md" <<'PLAN'
### Task 1: Bullet-list ownership
**Depends on:** none
**Wave:** wave-1
**Owns (file allowlist):**
- `lib/writer.sh`
- `tests/writer.test.sh`

- lib/not-the-allowlist.sh

**Files:**
- Create: `lib/writer.sh`

- [ ] **Step 1: do it**
PLAN
  bash "$LIB" plan-tasks --plan "$TX17_DIR/bullet.md" > "$TX17_DIR/bullet.json" 2>/dev/null
  ck "B: the bullet-list fixture parses (rc 0)" \
     "tx17_rc_is 0 bash '$LIB' plan-tasks --plan '$TX17_DIR/bullet.md'"
  ck "B: a BARE Owns label still reads the list below it" \
     "grep -qF '\"id\":1,\"owns\":[\"lib/writer.sh\",\"tests/writer.test.sh\"]' '$TX17_DIR/bullet.json'"
  ck "B: nothing is left unowned by the bullet-list form" \
     "grep -qF '\"unowned\":[]' '$TX17_DIR/bullet.json'"
  # The boundary row. Deliberately NOT a `! grep 'Create'` over the **Files:**
  # block below: that needle cannot red under any mutation of this parser —
  # delete BOTH list boundaries and `Create: \`lib/writer.sh\`` is still refused
  # by the shape gate, so the string never reaches the output and the row is
  # green by construction. `lib/not-the-allowlist.sh` is a bare path the gate
  # WOULD accept, so only the blank-line close keeps it out.
  ck "B: the list CLOSES at the blank line — later bullets are not harvested" \
     "! grep -qF 'lib/not-the-allowlist.sh' '$TX17_DIR/bullet.json'"

  # --- Fixture C: the SAME adoption, colliding with nothing -----------------
  # Fixture A's refusal could be credited to TB3 catching the collision. This
  # one cannot: before the fix the adopted allowlist collided with no sibling,
  # TB3 returned rc 0, and an implementer received an allowlist the plan never
  # wrote, unchallenged. That is the fail-OPEN in its pure form.
  cat > "$TX17_DIR/nocollide.md" <<'PLAN'
### Task 1: annotated inline path, adopted list collides with nothing
**Wave:** wave 1
**Owns:** lib/alpha.sh (the fast path)

- lib/ghost.sh
- lib/other.sh

### Task 2: unrelated, collides with nothing
**Wave:** wave 1
**Owns:** lib/beta.sh
PLAN
  bash "$LIB" plan-tasks --plan "$TX17_DIR/nocollide.md" > "$TX17_DIR/nocollide.json" 2>/dev/null
  ck "C: the non-colliding fixture parses (rc 0)" \
     "tx17_rc_is 0 bash '$LIB' plan-tasks --plan '$TX17_DIR/nocollide.md'"
  ck "C: refused WITHOUT leaning on a downstream collision" \
     "grep -qF '\"unowned\":[1]' '$TX17_DIR/nocollide.json'"
  ck "C: task 1 owns nothing here either" \
     "grep -qF '\"id\":1,\"owns\":[],' '$TX17_DIR/nocollide.json'"
  ck "C: the non-colliding bullet list was never adopted" \
     "! grep -qF 'lib/ghost.sh' '$TX17_DIR/nocollide.json'"
  # The row that proves fail-SAFE rather than fail-open: this exact input used
  # to sail through TB3 with rc 0.
  ck "C: TB3 REFUSES (rc 2) where it used to certify DISJOINT (rc 0)" \
     "tx17_rc_is 2 bash '$LIB' wave-disjoint --tasks-file '$TX17_DIR/nocollide.json' --wave 1"
fi

echo
echo "== Summary =="
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
