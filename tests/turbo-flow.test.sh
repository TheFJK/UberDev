#!/usr/bin/env bash
# Asserts that the --turbo flag survives the full unattended pipeline:
#   /turbo → brainstorm → write-plan → subagent-driven-dev → finish-branch
# without any skill prompting the user.
#
# Skills are prompts — these tests assert the prompt contract that keeps
# `/uberdev:turbo` unattended. If a contributor edits one of these skills
# and removes turbo-awareness, the user-facing /turbo flow regresses to
# attended mode. These assertions lock that contract in.

set -u

# Resolve repo root regardless of where the test is invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRAINSTORM="$REPO_ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
WRITE_PLAN="$REPO_ROOT/plugins/uberdev/skills/write-plan/SKILL.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
FINISH_BRANCH="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
TURBO_CMD="$REPO_ROOT/plugins/uberdev/commands/turbo.md"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
# #304 / RFC 0012 §3.4: the executable pipeline (Phase A + Step 4.5 + Phase B)
# was hoisted out of solve-pipeline/SKILL.md into lib/solve-launcher.sh — one
# bash file run as ONE Bash tool call. All launcher-shape asserts below grep
# the lib file; solve-pipeline/SKILL.md is contract/triage prose only.
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

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

assert_not_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern (should NOT match)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== brainstorm propagates --turbo to write-plan =="
assert_grep "$BRAINSTORM" \
  'write-plan.*--turbo|--turbo.*write-plan' \
  "brainstorm names write-plan and --turbo together (propagation site)"

echo
echo "== write-plan has turbo-aware Execution Handoff =="
assert_grep "$WRITE_PLAN" \
  '--turbo.*subagent-driven-dev|subagent-driven-dev.*--turbo' \
  "write-plan auto-dispatches subagent-driven-dev with --turbo (no user prompt)"

echo
echo "== subagent-driven-dev no longer arg-forwards --turbo to finish-branch (#97) =="
assert_grep "$SUBAGENT_DRIVEN" \
  'UBERDEV_TURBO' \
  "subagent-driven-dev names UBERDEV_TURBO env var (chain-internal env-var-only signal)"
assert_not_grep "$SUBAGENT_DRIVEN" \
  'finish-branch.*--turbo|--turbo.*finish-branch' \
  "subagent-driven-dev does NOT arg-forward --turbo to finish-branch (#97)"

echo
echo "== finish-branch auto-selects PR option under UBERDEV_TURBO=1 (#97) =="
assert_grep "$FINISH_BRANCH" \
  'UBERDEV_TURBO.*(Option 2|Push and [Cc]reate)|(Option 2|Push and [Cc]reate).*UBERDEV_TURBO|UBERDEV_TURBO=1.*Push and create' \
  "finish-branch auto-selects Push and Create PR under UBERDEV_TURBO=1"

echo
echo "== /turbo command entry point dispatches --turbo into the pipeline =="
# After the orchestrator landed (PR #8), medium/large /turbo enters via
# /uberdev:orchestrator --turbo; small/trivial tiers skip brainstorm entirely.
# Either entry-point name + --turbo proves the dispatch contract.
assert_grep "$SOLVE_PIPELINE" \
  'orchestrator --turbo|brainstorm --turbo|--turbo.*orchestrator|--turbo.*brainstorm' \
  "solve-pipeline skill (medium tier) dispatches --turbo into the pipeline"

echo
echo "== lib/dispatch.sh inline-prefix UBERDEV_TURBO=1 on claude --bg (AUTO_MODE=1 only, #97) =="
assert_grep "$DISPATCH_LIB" \
  'BG_TURBO_ENV=\( UBERDEV_TURBO=1 \)' \
  "lib/dispatch.sh declares BG_TURBO_ENV array under AUTO_MODE=1 (#97)"
assert_grep "$DISPATCH_LIB" \
  'env "\$\{BG_TURBO_ENV\[@\]\}" claude --bg' \
  "lib/dispatch.sh expands BG_TURBO_ENV[@] left of claude --bg via env(1)-mediated inline-prefix exec (#97 — timeout(1) eats raw KEY=value as argv, env(1) consumes them as env)"

echo
echo "== Anchor pre-check: solve-pipeline must contain exactly 2 'if AUTO_MODE==1' anchors (#97 simplify-lens E2 forward-guard) =="
# The two differential-guard awk passes below key off the bare anchor
# `^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$` and rely on its state machine
# (in_turbo → in_solve on the very next `^else$`). The skill's design contract
# is two such blocks: line 285 (TURBO MODE banner gate, no else arm — but the
# awk only enters in_turbo on a match and exits via the FIRST `^else$` it sees,
# which today belongs to the line-505 medium dispatch block, not 285's banner)
# and line 505 (medium-tier orchestrator dispatch, with else arm). A third
# block was briefly introduced at line 575 by #97 Phase 1 (BG_TURBO_ENV
# pre-declare in if/then/fi form) and immediately collapsed in #97 Phase 2 to
# `[[ ... ]] && ...` form precisely because adding a third anchor would
# silently corrupt this awk's region scan. Lock the count at 2 so any future
# edit that reintroduces the pattern fails loudly here, BEFORE the differential
# guards below produce confusing pass/fail behavior.
ANCHOR_COUNT="$(grep -c '^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$' "$SOLVE_PIPELINE")"
if [[ "$ANCHOR_COUNT" -ne 2 ]]; then
  echo "  FAIL  solve-pipeline anchor count expected 2, got $ANCHOR_COUNT — differential-guard awk relies on exactly two if/else/fi blocks"
  echo "        file: $SOLVE_PIPELINE"
  echo "        if a new AUTO_MODE-conditional block was added, prefer the [[ ... ]] && ... single-line form to avoid the anchor"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  solve-pipeline contains exactly 2 'if AUTO_MODE==1' anchors (differential-guard region-scan invariant holds)"
  PASS=$((PASS + 1))
fi

echo
echo "== Differential guard: AUTO_MODE!=1 medium dispatch dispatches WITHOUT --turbo (#15) =="
# pr-test-analyzer Gap #2: the positive --turbo assertion above asserts --turbo
# appears somewhere in the skill; this asserts the interactive (/solve) medium
# branch dispatches the orchestrator WITHOUT --turbo, so a future edit that
# accidentally hardcoded --turbo would break this test.
SOLVE_MEDIUM_DISPATCH=$(awk '
  /^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$/ { in_turbo=1; next }
  in_turbo && /^else$/ { in_turbo=0; in_solve=1; next }
  in_solve && /^fi$/ { in_solve=0; next }
  in_solve && /orchestrator.*solve GH issue/ { print }
' "$SOLVE_PIPELINE")
if grep -qE -- '--turbo' <<<"$SOLVE_MEDIUM_DISPATCH"; then
  echo "  FAIL  AUTO_MODE!=1 medium dispatch MUST NOT contain --turbo (interactive /solve regression)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  AUTO_MODE!=1 medium dispatch correctly omits --turbo (interactive /solve preserved)"
  PASS=$((PASS + 1))
fi

echo
echo "== Differential guard: AUTO_MODE!=1 medium dispatch must NOT contain UBERDEV_TURBO=1 (#97) =="
# Companion to the --turbo differential guard above. Locks the env-var contract:
# `UBERDEV_TURBO=1` is the inline-prefix exec env on the bg dispatch line, but
# ONLY inside the AUTO_MODE=1 (turbo) branch. Leaking it into the AUTO_MODE!=1
# (interactive /solve) else-branch would silently propagate turbo into every
# /solve invocation — exactly the regression #97's symmetric inverse defends
# against. Same awk anchor as above; inner pattern flipped from `--turbo` to
# `UBERDEV_TURBO=1`.
SOLVE_MEDIUM_NO_TURBO=$(awk '
  /^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$/ { in_turbo=1; next }
  in_turbo && /^else$/ { in_turbo=0; in_solve=1; next }
  in_solve && /^fi$/ { in_solve=0; next }
  in_solve && /UBERDEV_TURBO=1/ { print }
' "$SOLVE_PIPELINE")
if [[ -n "$SOLVE_MEDIUM_NO_TURBO" ]]; then
  echo "  FAIL  AUTO_MODE!=1 (interactive /solve) branch must NOT contain UBERDEV_TURBO=1"
  echo "        offending lines: $SOLVE_MEDIUM_NO_TURBO"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  AUTO_MODE!=1 branch correctly omits UBERDEV_TURBO=1 (interactive /solve preserved)"
  PASS=$((PASS + 1))
fi

echo
echo "== thin /solve and /turbo wrappers run lib/solve-launcher.sh with literal mode flags (#304 / RFC 0012 §3.4) =="
# The command files pass LITERALS into ONE Bash call — no cross-fence env
# reads anywhere (Bash tool calls share no shell state; the historical
# `export AUTO_MODE=…` fence followed by a Skill() invocation was dead).
# The renderer substitutes $ARGUMENTS into real argv words, which IS the
# #304 renderer fix.
assert_grep "$SOLVE_CMD" \
  'bash "\$CLAUDE_PLUGIN_ROOT/lib/solve-launcher\.sh" --auto-mode=0 -- \$ARGUMENTS' \
  "/solve thin wrapper runs solve-launcher.sh with literal --auto-mode=0 (ONE Bash call)"
assert_grep "$TURBO_CMD" \
  'bash "\$CLAUDE_PLUGIN_ROOT/lib/solve-launcher\.sh" --auto-mode=1 --turbo -- \$ARGUMENTS' \
  "/turbo thin wrapper runs solve-launcher.sh with literal --auto-mode=1 --turbo (ONE Bash call)"
assert_not_grep "$SOLVE_CMD" 'export AUTO_MODE|export UBERDEV_TURBO' \
  "/solve thin wrapper carries NO cross-fence env exports (the launcher owns the lifecycle in-process)"
assert_not_grep "$TURBO_CMD" 'export AUTO_MODE|export UBERDEV_TURBO' \
  "/turbo thin wrapper carries NO cross-fence env exports (the launcher owns the lifecycle in-process)"
SOLVE_PIPELINE_REF='uberdev:solve-pipeline|solve-pipeline skill'
assert_grep "$SOLVE_CMD" "$SOLVE_PIPELINE_REF" \
  "/solve thin wrapper names the solve-pipeline skill as the contract/triage reference"
assert_grep "$TURBO_CMD" "$SOLVE_PIPELINE_REF" \
  "/turbo thin wrapper names the solve-pipeline skill as the contract/triage reference"
# #97/#241 env hygiene moved INSIDE the launcher process: the shell profile
# re-injects UBERDEV_TURBO/SKIP_PERMISSIONS into every fresh fence, so only
# an in-process export/unset protects the spawned children.
assert_grep "$SOLVE_PIPELINE" '^export AUTO_MODE$' \
  "launcher exports AUTO_MODE for its children (set from the literal --auto-mode flag)"
assert_grep "$SOLVE_PIPELINE" 'export UBERDEV_TURBO=1' \
  "launcher exports UBERDEV_TURBO=1 under --turbo (#97 — chain-wide unattended-mode signal)"
assert_grep "$SOLVE_PIPELINE" 'unset UBERDEV_TURBO' \
  "launcher unsets UBERDEV_TURBO when --turbo is absent (#97 — defends against shell-profile pollution)"
assert_grep "$SOLVE_PIPELINE" 'unset SKIP_PERMISSIONS' \
  "T-no-skip (#241 — launcher unsets SKIP_PERMISSIONS in-process; a stale /goal export cannot elevate /solve or bare /turbo)"
assert_grep "$TURBO_CMD" \
  'argument-hint:.*<issue-number>.*\[<issue-number>' \
  "/turbo argument-hint documents multi-issue syntax"
assert_grep "$SOLVE_CMD" \
  'argument-hint:.*<issue-number>.*\[<issue-number>' \
  "/solve argument-hint documents multi-issue syntax"

echo
echo "== solve-pipeline accepts multiple issue numbers (multi-issue dispatch) =="
# /turbo 5 6 7 must spawn one agent per issue in parallel. The skill tokenizes
# $ARGUMENTS via a portable bash-and-zsh-safe pipeline (`tr ' ' '\n' | grep -E
# '^[0-9]+$' | awk -v c0=0 '!seen[$c0]++'`), validates every issue up front (Phase A),
# and only then spawns (Phase B). If any issue fails validation, the entire
# batch aborts with no agents dispatched.
#
# zsh footgun: a naive `for token in $ARGUMENTS; do …` does NOT word-split
# scalar parameters in zsh (SH_WORD_SPLIT off by default), so `/turbo 5 6 7`
# would die at the usage check. The pipeline avoids this — `arr=($(cmd))`
# word-splits the substitution output on $IFS in BOTH bash and zsh.
assert_grep "$SOLVE_PIPELINE" \
  'solve_triage.py' \
  "solve-pipeline uses the deterministic bounded triage/parser helper"
assert_grep "$SOLVE_PIPELINE" \
  "tr ' ' '\\\\n'" \
  "solve-pipeline tokenizes \$ARGUMENTS via tr (portable across bash/zsh)"
assert_grep "$SOLVE_PIPELINE" \
  'json.loads\(sys.argv\[1\]\)\["issues"\]' \
  "solve-pipeline consumes the parser's validated positive issue list"
assert_grep "$SOLVE_PIPELINE" \
  'TERMINAL_FLAG_USED=.*grep -oE .\\-\\-terminal=' \
  "Phase A captures --terminal= flag for deprecation emission (v0.22.0 deprecation shim)"
assert_grep "$SOLVE_PIPELINE" \
  'echo "\$TERMINAL_FLAG_DEPRECATED_NOTE" >&2' \
  "Phase A emits TERMINAL_FLAG_DEPRECATED_NOTE to stderr on --terminal= encounter"
assert_grep "$REPO_ROOT/plugins/uberdev/lib/solve_triage.py" \
  'routing_cli_duplicate' \
  "solve-pipeline's parser contract rejects duplicate singleton routing flags"
assert_grep "$SOLVE_PIPELINE" \
  'SH_WORD_SPLIT|word-split|word split' \
  "solve-pipeline comment explains the zsh word-split footgun (regression-prevention)"
assert_grep "$SOLVE_PIPELINE" \
  'no agents dispatched' \
  "solve-pipeline aborts before spawning if any issue fails Phase A validation"
assert_grep "$SOLVE_PIPELINE" \
  'printf .error: %s.*ERRORS\[@\]' \
  "Phase A prints ALL accumulated errors before abort (not just the last one)"
assert_grep "$SOLVE_PIPELINE" \
  'Phase A|validate.*all issues|validate-all-first' \
  "solve-pipeline names the Phase A validate-all-first contract"
assert_grep "$SOLVE_PIPELINE" \
  'for ISSUE_NUM in "\$\{ISSUE_NUMS\[@\]\}"' \
  "solve-pipeline loops Phase B over validated issues"
# TURBO MODE banner must be hoisted out of the per-issue loop and printed
# at most once per /turbo invocation. Locking both the dedup loop AND the
# `break` after the first medium-tier hit keeps it from regressing to
# per-spawn (which would stack N identical banners on a 3-medium batch).
assert_grep "$SOLVE_PIPELINE" \
  'TURBO MODE.*banner.*once|print once.*medium|once before.*loop' \
  "TURBO MODE banner documented as printed-once (not per-spawn)"
# Two single-line assertions (grep -E without -z does not match across newlines —
# a multi-line `.*\n.*` alternation half is dead code). Lock the dedup loop and
# the break-on-first-medium guard separately.
assert_grep "$SOLVE_PIPELINE" \
  'for n in "\$\{!ISSUE_NUMS\[@\]\}"' \
  "TURBO MODE banner loops over ISSUE_NUMS indices to scan tiers (dedup mechanic; parallel indexed arrays — declare -A is unavailable on macOS bash 3.2)"
assert_grep "$SOLVE_PIPELINE" \
  'TIERS\[\$n\].*medium' \
  "TURBO MODE banner checks TIERS[\$n] == medium (with break after first hit)"
assert_grep "$SOLVE_PIPELINE" \
  'SPAWNED\[@\]|\$\{#SPAWNED\[@\]\}' \
  "solve-pipeline emits a single summary notification (not per-spawn) using SPAWNED array"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCH_FAILED' \
  "Phase B tracks per-issue dispatch failures (no silent partial-batch failures)"
assert_grep "$SOLVE_PIPELINE" \
  'BG_DISPATCH_RC="\$DISPATCH_RC"' \
  "Phase B reads DISPATCH_RC post-condition from lib/dispatch.sh (uberdev_dispatch_one sets DISPATCH_RC + DISPATCH_ID as a documented SSOT contract — see uberdev_dispatch_one's header contract and its central SSOT reset in lib/dispatch.sh)"
# Phase A hoist check: the version gate + BG_PROMPT_MODE assignment must
# precede the Phase B per-issue loop (resolved once; identical for every spawn).
# The version gate is backend-conditional (RFC 0012 §3.4 codex-port: codex
# backend skips the claude check, see the if/else around it), so it lives in an
# indented else-branch — no ^ anchor. BG_PROMPT_MODE stays column-0 in
# dispatch.sh's resolve_env. Ordering is the real invariant.
SP_PHASE_A_LINE=$(grep -nE '_uberdev_require_claude_version "2.1.152"|^BG_PROMPT_MODE=argv' "$SOLVE_PIPELINE" | head -1 | cut -d: -f1)
SP_PHASE_B_LINE=$(grep -nE 'for ISSUE_NUM in "\$\{ISSUE_NUMS\[@\]\}"|for ISSUE_NUM in "\$\{ISSUE_NUMS\[@\]:' "$SOLVE_PIPELINE" | tail -1 | cut -d: -f1)
if [[ -n "$SP_PHASE_A_LINE" && -n "$SP_PHASE_B_LINE" && "$SP_PHASE_A_LINE" -lt "$SP_PHASE_B_LINE" ]]; then
  echo "  PASS  Phase A hoisted before Phase B loop (line $SP_PHASE_A_LINE before $SP_PHASE_B_LINE)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  Phase A (claude version gate + BG_PROMPT_MODE) must be hoisted before the per-issue loop"
  echo "        Phase A line:  ${SP_PHASE_A_LINE:-not found}"
  echo "        Phase B line:  ${SP_PHASE_B_LINE:-not found}"
  FAIL=$((FAIL + 1))
fi
assert_grep "$SOLVE_PIPELINE" \
  'MAX_PARALLEL_BG_AGENTS' \
  "Phase A binds MAX_PARALLEL_BG_AGENTS (cap for /turbo parallel bg dispatch)"
assert_grep "$SOLVE_PIPELINE" \
  'uberdev_read_int_in_range fanout_concurrency.solve_bg' \
  "Phase A reads fanout_concurrency.solve_bg via uberdev_read_int_in_range"
assert_grep "$SOLVE_PIPELINE" \
  'solve_bg_fanout_wave_started' \
  "Phase B emits solve_bg_fanout_wave_started audit event per wave (mirrors merge-pipeline:421)"
assert_grep "$SOLVE_PIPELINE" \
  '_uberdev_require_claude_version "2.1.152"' \
  "Phase A version-gates --permission-mode bypassPermissions minimum (2.1.152; bumped from 2.1.139 for #246)"

echo
echo "== orchestrator no longer arg-forwards --turbo to SDD (#97 — env-var inheritance) =="
# Pre-#97 the orchestrator pasted --turbo into the SDD invocation. Post-#97
# the chain-internal turbo signal is the inherited `UBERDEV_TURBO=1` env var
# (set by commands/turbo.md → solve-pipeline → claude --bg inline-prefix exec)
# and SDD/finish-branch detect it directly. Phase 5 prose must NOT instruct
# the agent to pass --turbo to SDD anymore.
#
# IMPORTANT — the negative pattern is intentionally precise (anchored on the
# imperative-form "pass --turbo to" / "with `--turbo` to" with the explicit
# prepositional phrase). The broad `subagent-driven-dev.*--turbo` regex would
# false-positive on the new prose's negation phrasing
# ("no per-call `--turbo` arg-forwarding needed (#97)") which intentionally
# names the old contract to make the change explicit to readers.
assert_not_grep "$ORCHESTRATOR" \
  'pass --turbo to .*subagent-driven-dev|with `--turbo` to .*subagent-driven-dev' \
  "orchestrator Phase 5 does NOT arg-forward --turbo to subagent-driven-dev (chain inherits via UBERDEV_TURBO env)"
assert_grep "$ORCHESTRATOR" \
  'UBERDEV_TURBO' \
  "orchestrator Phase 5 names UBERDEV_TURBO as the chain unattended-mode signal"
# Orchestrator turbo detector is hybrid per Decision Q3: ON when EITHER
# $ARGUMENTS contains --turbo (standalone-invocation path) OR
# UBERDEV_TURBO=1 (set by commands/turbo.md, propagated through claude --bg).
assert_grep "$ORCHESTRATOR" \
  '\$ARGUMENTS.*--turbo.*UBERDEV_TURBO|UBERDEV_TURBO.*\$ARGUMENTS.*--turbo' \
  "orchestrator turbo detector is hybrid (\$ARGUMENTS OR UBERDEV_TURBO env, per Decision Q3)"

echo
echo "== Default-mode paths preserved (regression canaries) =="
assert_grep "$WRITE_PLAN" \
  'Default path \(subagent-driven\)|Inline override' \
  "write-plan default-mode handoff still names both subagent-driven (default) and inline override paths"
# Q11 (issue #20): default mode no longer presents the menu — it auto-pushes.
# The 4-option menu is gated under --interactive only.
assert_grep "$FINISH_BRANCH" \
  '[Dd]efault.*[Aa]uto.*Option 2|[Dd]efault mode.*Option 2|always-PR' \
  "finish-branch default mode auto-pushes PR (no menu)"
assert_grep "$FINISH_BRANCH" \
  '--interactive.*Merge back to|--interactive.*4-option|--interactive.*4 option|interactive.*Push and create a Pull Request|interactive.*Keep the branch as-is' \
  "finish-branch --interactive restores 4-option menu"
assert_grep "$BRAINSTORM" \
  'clarifying questions.*one at a time|[Aa]sk clarifying questions' \
  "brainstorm still describes the default clarifying-questions loop"

echo
echo "== finish-branch chains into review-pr after PR creation (Q1) =="
assert_grep "$FINISH_BRANCH" \
  'Skill.*review-pr|Skill\("uberdev:review-pr"\)|uberdev:review-pr.*Skill' \
  "finish-branch invokes uberdev:review-pr via Skill tool after PR creation"

echo
echo "== orchestrator Phase 2 imperative gate (interactive /solve must NOT collapse into /turbo) =="
# These assertions defend against the prose-drift regression that made /solve
# behave like /turbo: a freshly-spawned LLM read "optional Q&A" + soft Phase 2
# wording and skipped the only step that distinguishes the two modes.
assert_grep "$ORCHESTRATOR" \
  'You MUST ask 3-5 clarifying questions' \
  "Phase 2 non-turbo prose uses imperative MUST (not 'unchanged — ask')"
assert_grep "$ORCHESTRATOR" \
  'Do NOT proceed to Phase 3 until the user has answered' \
  "Phase 2 non-turbo includes explicit gate to Phase 3"
assert_grep "$ORCHESTRATOR" \
  'only signal that distinguishes .*/solve.* from .*/turbo' \
  "Phase 2 documents itself as the sole /solve-vs-/turbo signal (anti-skip prose)"
assert_grep "$ORCHESTRATOR" \
  'select:AskUserQuestion' \
  "Phase 2 instructs ToolSearch select:AskUserQuestion (deferred-tool caveat)"
assert_grep "$ORCHESTRATOR" \
  'Do NOT silently auto-pick on tool-load failure' \
  "Phase 2 forbids silent auto-pick fallback (turns /solve into /turbo invisibly)"
assert_not_grep "$ORCHESTRATOR" \
  'optional Q&A' \
  "skill description does NOT call Q&A 'optional' (mis-signals to spawned agents)"
assert_not_grep "$ORCHESTRATOR" \
  'optional spec-reviewer' \
  "skill description does NOT call spec-reviewer 'optional' (it is always-on for medium/large)"

echo
echo "== orchestrator wires always-on reviewers =="
assert_grep "$ORCHESTRATOR" 'questions\.md' \
  "orchestrator writes questions.md under --turbo"
assert_grep "$ORCHESTRATOR" 'spec-reviewer' \
  "spec-reviewer wired in orchestrator"
# Old --paranoid gate REMOVED — assert the new always-on prose is present and the gate prose is absent.
assert_grep "$ORCHESTRATOR" 'always run for medium AND large|always-on for medium and large' \
  "spec-reviewer documented as always-on for medium+large"
if grep -qE 'tier == .?medium.? AND .?--paranoid' "$ORCHESTRATOR"; then
  echo "  FAIL  old --paranoid gate prose still present"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  old --paranoid gate prose removed"
  PASS=$((PASS + 1))
fi
assert_grep "$ORCHESTRATOR" 'plan-reviewer' \
  "plan-reviewer wired in orchestrator (Phase 4.5)"
assert_grep "$ORCHESTRATOR" 'post-impl-review' \
  "post-impl-review skill referenced from orchestrator"
# Post-#92 (issue #92): the assertions below verify pr-test-analyzer dispatch
# moved from orchestrator Phase 5.5 into subagent-driven-dev Step 4.5. AC*
# identifiers reference docs/uberdev/specs/2026-05-13-phase-5-5-vs-sdd-ordering-fix-design.md.
# Assert SDD owns the dispatch site.
assert_grep "$SUBAGENT_DRIVEN" 'pr-test-analyzer' \
  "pr-test-analyzer wired in subagent-driven-dev (Step 4.5, post-#92)"
assert_grep "$SUBAGENT_DRIVEN" 'tier == .large' \
  "Step 4.5 gated on large tier (post-#92 AC9)"
assert_grep "$SUBAGENT_DRIVEN" 'summary_dir' \
  "Step 4.5 takes summary_dir input (post-#92 AC8)"
# Negative anchors: orchestrator must no longer carry Phase 5.5 nor own
# the pr-test-analyzer Task() dispatch (this regression check fires if
# someone re-adds the section to orchestrator/SKILL.md).
assert_not_grep "$ORCHESTRATOR" '^### Phase 5\.5' \
  "orchestrator no longer carries Phase 5.5 section (post-#92 AC2)"
# Post-#92: orchestrator Phase 5 dispatch passes summary_dir to SDD so SDD's
# Step 4.5 has the canonical $RESEARCH_DIR_ABS path. Asserts AC8 of the design
# spec — explicit parameter pass (vs re-derivation in SDD).
assert_grep "$ORCHESTRATOR" 'summary_dir.*RESEARCH_DIR_ABS|summary_dir: \$RESEARCH_DIR_ABS' \
  "orchestrator Phase 5 dispatch passes summary_dir to SDD (post-#92 AC8)"
# Post-#92 AC8b: orchestrator Phase 5 dispatch must also pass tier so SDD's
# Step 4.5 can gate the large-tier dispatch. A future refactor that dropped
# this would silently skip Step 4.5 on large tier — same observable failure
# mode as the original #92 bug.
assert_grep "$ORCHESTRATOR" '\btier\b' \
  "orchestrator Phase 5 dispatch passes tier to SDD (post-#92 AC8b)"
# Post-#92 AC10 negative anchor: Step 4.5 is a direct single-agent Task(),
# NOT routed via uberdev:post-impl-review (which is reserved for the
# post-PR-push fanout owned by /uberdev:review-pr Phase 1). The pattern is
# intentionally precise — it anchors on the imperative-form regression
# ("Step 4.5 dispatches via uberdev:post-impl-review", "route Step 4.5
# through uberdev:post-impl-review") rather than mere co-occurrence; the
# negation prose elsewhere in SDD ("Step 4.5 … is therefore NOT routed via
# uberdev:post-impl-review") and the orthogonal finish-branch glob mention
# must not false-positive. Mirrors the orchestrator --turbo negative-pattern
# precedent at lines 299-301 of this file.
assert_not_grep "$SUBAGENT_DRIVEN" \
  'Step 4\.5 (dispatch|dispatches|routes|invokes) (via|through) (`)?uberdev:post-impl-review|(dispatch|route|invoke) Step 4\.5 (via|through) (`)?uberdev:post-impl-review' \
  "AC10: Step 4.5 is direct Task(), not routed via uberdev:post-impl-review (post-#92)"
assert_grep "$ORCHESTRATOR" 'subagent-driven-dev.*Step 4\.5|SDD Step 4\.5' \
  "orchestrator Phase 6 large-tier note names SDD Step 4.5 (post-#92 AC7b)"

echo
echo "== subagent-driven-dev: post-impl-review hosted by /review-pr Phase 1 (#67) =="
# Cross-references in SDD prose still point readers to the new location.
assert_grep "$SUBAGENT_DRIVEN" 'post-impl-review' \
  "post-impl-review cross-referenced from subagent-driven-dev (points to /review-pr Phase 1 host)"
# Anti-regression: SDD no longer codifies the end-of-issue invocation it used to dispatch
# (the load-bearing call site moved to /review-pr Phase 1 per #67).
assert_not_grep "$SUBAGENT_DRIVEN" 'End-of-issue post-impl-review' \
  "subagent-driven-dev no longer codifies end-of-issue invocation (#67 moved fanout to /review-pr Phase 1)"
assert_not_grep "$SUBAGENT_DRIVEN" 'WAVE.*final|WAVE: .final.' \
  "subagent-driven-dev no longer passes WAVE=final (no in-skill post-impl-review dispatch post-#67)"

echo
echo "== turbo medium/large parity: post-push post-impl-review documented in turbo.md =="
assert_grep "$TURBO_CMD" 'post-PR-push.*(/review-pr|review-pr).*Phase 1|(/review-pr|review-pr).*Phase 1.*post-PR-push' \
  "turbo.md documents post-push /review-pr Phase 1 post-impl-review for medium/large"
assert_grep "$TURBO_CMD" 'against the pushed diff' \
  "turbo.md names the pushed-diff review target"
assert_not_grep "$TURBO_CMD" 'post-impl-review.*once at end-of-issue|consolidated across all waves|uberdev:post-impl-review. per wave' \
  "turbo.md drops retired end-of-issue/per-wave post-impl-review wording"

echo
echo "== finish-branch composes new PR-body sections =="
assert_grep "$FINISH_BRANCH" 'Open questions answered by /turbo' \
  "finish-branch PR body has Open questions answered by /turbo section"
assert_grep "$FINISH_BRANCH" 'Reviewer findings summary' \
  "finish-branch PR body has Reviewer findings summary section"

echo
echo "== /simplify runs ONCE in the chain — at /review-pr Phase 2, not pre-push =="
# Chain-level invariant: trivial/small heredocs MUST NOT call /simplify standalone
# before push. The canonical simplify pass is Phase 2 of /uberdev:review-pr,
# which sees the post-Phase-1 diff (full PR + review-fix commits) and is
# strictly more complete than any pre-push call. This guard fails loud if a
# future edit re-introduces the duplication. Anchored on the numbered-step form
# (`^[0-9]+\.\s+/simplify before push`) so the regression-prevention prose
# elsewhere in the same file (and the directive added to each heredoc) is not
# matched.
assert_not_grep "$SOLVE_PIPELINE" \
  '^[[:space:]]*[0-9]+\.[[:space:]]+/(uberdev:)?simplify[[:space:]]+before[[:space:]]+push' \
  "no /simplify-before-push numbered step in solve-pipeline heredocs"
# Positive lock: each of the 4 trivial/small heredocs (trivial-solve, trivial-turbo,
# small-solve, small-turbo) must explicitly tell the spawned agent NOT to run
# /simplify standalone. Anchoring the count at 4 catches both deletion and the
# subtler regression where one heredoc loses the directive while three keep it.
# `|| echo "0"` (not `|| true`) — `grep -c` exits 1 when count=0 (expected) but
# exits 2 on real errors (unreadable file, malformed regex); the echo fallback
# keeps the no-match path numeric while letting genuine errors surface via the
# stderr-redirected grep.
DIRECTIVE_COUNT=$(grep -cE 'Do NOT run /uberdev:simplify standalone before push' "$SOLVE_PIPELINE" 2>/dev/null || echo "0")
if [[ "$DIRECTIVE_COUNT" -eq 4 ]]; then
  echo "  PASS  all 4 trivial/small heredocs include the no-pre-push-simplify directive (count=4)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  all 4 trivial/small heredocs include the no-pre-push-simplify directive"
  echo "        file: $SOLVE_PIPELINE"
  echo "        expected count: 4 (trivial-solve, trivial-turbo, small-solve, small-turbo)"
  echo "        actual count:   $DIRECTIVE_COUNT"
  FAIL=$((FAIL + 1))
fi
# Positive lock — the negative no-pre-push-simplify directive only makes sense
# if /uberdev:review-pr is actually invoked post-push (its Phase 2 is where
# simplify lives). The new single-path-convergence design routes trivial/small
# through `uberdev:finish-branch`, which owns the canonical Skill("uberdev:review-pr")
# hand-off. Without an explicit hand-off step in
# each heredoc, the spawned trivial/small agent commits and stops — the chain
# into /review-pr never fires and the simplify ceremony silently no-ops on
# every trivial/small PR. Anchor the count at 4 so a future edit cannot delete
# the hand-off line from one heredoc while leaving three intact.
INVOKE_COUNT=$(grep -cE 'Hand off to .*uberdev:finish-branch' "$SOLVE_PIPELINE" 2>/dev/null || echo "0")
if [[ "$INVOKE_COUNT" -eq 4 ]]; then
  echo "  PASS  all 4 trivial/small heredocs hand off to uberdev:finish-branch (count=4)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  all 4 trivial/small heredocs must hand off to uberdev:finish-branch (which owns the canonical review-pr chain)"
  echo "        file: $SOLVE_PIPELINE"
  echo "        expected count: 4 (trivial-solve, trivial-turbo, small-solve, small-turbo)"
  echo "        actual count:   $INVOKE_COUNT"
  FAIL=$((FAIL + 1))
fi
# Turbo heredocs must forward --turbo into finish-branch so the chain stays
# unattended end-to-end (finish-branch then forwards --turbo into /review-pr
# per its own contract). Two turbo heredocs (trivial-turbo, small-turbo) → count=2.
TURBO_FORWARD_COUNT=$(grep -cF 'uberdev:finish-branch --turbo' "$SOLVE_PIPELINE" 2>/dev/null || echo "0")
if [[ "$TURBO_FORWARD_COUNT" -eq 2 ]]; then
  echo "  PASS  both turbo heredocs (trivial-turbo, small-turbo) forward --turbo into finish-branch (count=2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  both turbo heredocs must hand off to 'uberdev:finish-branch --turbo' to keep the chain unattended"
  echo "        file: $SOLVE_PIPELINE"
  echo "        expected count: 2 (trivial-turbo, small-turbo)"
  echo "        actual count:   $TURBO_FORWARD_COUNT"
  FAIL=$((FAIL + 1))
fi
# Negative lock — no inline `gh pr create` may appear inside the trivial/small
# slice. After this design (#91) all four heredocs commit and hand off to
# finish-branch; finish-branch owns the only `gh pr create` call. The awk
# range starts at the **trivial:** header and stops at the **medium** header,
# so finish-branch's own `gh pr create` reference (elsewhere in the repo) and
# the medium dispatch are excluded. Anchor at 0 so a future regression that
# reintroduces an inline `gh pr create` in any trivial/small heredoc is
# caught immediately.
# Launcher form: the tier prompts live in a `case "$TIER" in` with column-0
# arms — the trivial/small slice runs from the `trivial)` arm opener to the
# `*)` (medium) arm opener.
TRIVIAL_SMALL_GHPR_COUNT=$(awk '/^trivial\)$/,/^\*\)$/' "$SOLVE_PIPELINE" 2>/dev/null | grep -cF 'gh pr create')
if [[ "$TRIVIAL_SMALL_GHPR_COUNT" -eq 0 ]]; then
  echo "  PASS  no inline 'gh pr create' inside the trivial/small slice (count=0)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  inline 'gh pr create' must NOT appear inside the trivial/small slice — finish-branch owns PR creation"
  echo "        file: $SOLVE_PIPELINE"
  echo "        slice: **trivial:** through **medium**"
  echo "        expected count: 0"
  echo "        actual count:   $TRIVIAL_SMALL_GHPR_COUNT"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REPO_ROOT/plugins/uberdev/commands/simplify.md" \
  'canonical place.*/simplify.*runs.*Phase 2|Phase 2 of .*review-pr' \
  "simplify.md names /review-pr Phase 2 as the canonical simplify run site"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
