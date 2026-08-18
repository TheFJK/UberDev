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
ck "allowed-tools declares Task"   "grep '^allowed-tools:' '$CMD' | grep -q '\"Task\"'"
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

echo "== TX11b: every agent type the skill dispatches actually exists =="
# Agents get renamed. A skill naming a dead agentType fails at dispatch time,
# mid-run, after the claims are already written — so the roster is checked from
# the bytes. Derived from the skill, not restated here, so a NEW agent added to
# a phase is covered without editing this file.
AGENT_DIR="$REPO_ROOT/plugins/uberdev/agents"
named_agents="$(grep -oE '`uberdev:[a-z0-9-]+`' "$SKILL" | tr -d '`' | sed 's/^uberdev://' | sort -u)"
ck "the skill names at least 8 agent types (found: $(printf '%s' "$named_agents" | grep -c .))" \
   "[ \$(printf '%s' \"\$named_agents\" | grep -c .) -ge 8 ]"
missing_agents=""
for a in $named_agents; do
  # turbox-fleet is the SKILL's own namespaced name, not an agent.
  [ "$a" = "turbox-fleet" ] && continue
  [ -r "$AGENT_DIR/$a.md" ] || missing_agents="$missing_agents $a"
done
ck "every named agent resolves in agents/ (missing:${missing_agents:- none})" "[ -z '$missing_agents' ]"

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
ck "lib has a bash shebang"             "head -1 '$LIB' | grep -q '^#!/usr/bin/env bash'"
ck "lib documents the never-source rule" "grep -q 'never a sourced library' '$LIB'"
ck "skill documents the never-source rule" "grep -qi 'executable\*\*, never sourced' '$SKILL'"
# A `. \$LIB` / `source \$LIB` anywhere in the skill would run the body under
# the Bash tool's /bin/zsh, which is the class this project keeps re-hitting.
ck "skill never sources the lib"        "[ \$(grep -cE '(^|[^a-z])(source|\.) +\"?\\\$LIB' '$SKILL') -eq 0 ]"
ck "command never sources the lib"      "[ \$(grep -cE '(^|[^a-z])(source|\.) +\"?\\\$LIB' '$CMD') -eq 0 ]"

echo
echo "== Summary =="
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
