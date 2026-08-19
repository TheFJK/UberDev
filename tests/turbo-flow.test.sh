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
# After the orchestrator landed (PR #8), medium-tier /turbo enters via
# /uberdev:orchestrator --turbo; small/trivial tiers skip brainstorm entirely.
# Either entry-point name + --turbo proves the dispatch contract.
assert_grep "$SOLVE_PIPELINE" \
  'orchestrator --turbo|brainstorm --turbo|--turbo.*orchestrator|--turbo.*brainstorm' \
  "solve-pipeline skill (medium tier) dispatches --turbo into the pipeline"

echo
# The ordering fixture below used to key off `_uberdev_dispatch_claude_bg`. That
# arm was deleted with its backend (RFC 0015 section 7 as amended), so it is
# RETARGETED at `_uberdev_dispatch_background` rather than dropped: the
# invariant is the env(1)-prefix ordering (base -> length-gated BG_TURBO_ENV ->
# provider argv), which is still live there and still the thing #97 fixed.
echo "== lib/dispatch.sh inline-prefix UBERDEV_TURBO=1 on the detached provider argv (AUTO_MODE=1 only, #97) =="
assert_grep "$DISPATCH_LIB" \
  'BG_TURBO_ENV=\( UBERDEV_TURBO=1 \)' \
  "lib/dispatch.sh declares BG_TURBO_ENV array under AUTO_MODE=1 (#97)"
if python3 -I -B - "$DISPATCH_LIB" <<'PY'
import sys
source=open(sys.argv[1],encoding="utf-8").read()
body=source.split("_uberdev_dispatch_background() {",1)[1].split("\n}",1)[0]
base='local PROVIDER_CMD=( env )'
turbo='[ "${#BG_TURBO_ENV[@]}" -eq 0 ] || PROVIDER_CMD+=( "${BG_TURBO_ENV[@]}" )'
provider='PROVIDER_CMD+=( claude -p "$PROMPT_BODY" --model "$MODEL" )'
assert body.index(base) < body.index(turbo) < body.index(provider),body
PY
then
  echo "  PASS  lib/dispatch.sh appends BG_TURBO_ENV before the provider argv with a nounset-safe length guard"
  PASS=$((PASS + 1))
else
  echo "  FAIL  lib/dispatch.sh must append BG_TURBO_ENV before the provider argv with a nounset-safe length guard"
  FAIL=$((FAIL + 1))
fi

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
# ...and the literal it checks must COVER EVERY TIER THE ORCHESTRATOR RUNS ON.
# The two rows above pin the banner's shape; neither can see the bug that shape
# had. `case "$TIER"` writes the orchestrator prompt from its `*)` catch-all, so
# the set of tiers that reach the design pipeline is `TIERS` minus the arms
# spelled out above it — and while that set was {medium, large}, a /turbo batch
# of nothing but `large` issues ran the full unattended orchestrator and printed
# NO banner at all, because no tier in it was spelled `medium`. #619 collapsed
# the rung and closed it; this row is what keeps it closed, by comparing the two
# sets rather than asserting either one's contents.
if python3 -I - "$SOLVE_PIPELINE" "$REPO_ROOT/plugins/uberdev/lib/solve_triage.py" <<'PY_BANNER'
import importlib.util, pathlib, re, sys

launcher = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
spec = importlib.util.spec_from_file_location("solve_triage_under_test", sys.argv[2])
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

block = re.search(r'(?ms)^case "\$TIER" in$(.*?)^esac$', launcher)
if not block:
    raise SystemExit('could not find the launcher tier `case "$TIER" in` block')
arms = set(re.findall(r"(?m)^([a-z*]+)\)$", block.group(1)))
if "*" not in arms:
    raise SystemExit(f"the tier case has no catch-all arm: {sorted(arms)!r}")
catch_all = set(st.TIERS) - (arms - {"*"})
banner = set(re.findall(r'TIERS\[\$n\]\}"\s*==\s*"([a-z]+)"', launcher))
if not banner:
    raise SystemExit("could not read the TURBO banner's tier literal")
if banner != catch_all:
    raise SystemExit(
        f"the TURBO banner scans {sorted(banner)!r} but the orchestrator "
        f"catch-all runs on {sorted(catch_all)!r} — a batch made only of "
        f"{sorted(catch_all - banner)!r} runs the design pipeline unannounced")
PY_BANNER
then
  echo "  PASS  TURBO MODE banner scans EVERY tier the orchestrator catch-all runs on"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TURBO MODE banner does not cover every orchestrator-bound tier"
  FAIL=$((FAIL + 1))
fi
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
  "skill description does NOT call spec-reviewer 'optional' (it is always-on for medium)"

echo
echo "== orchestrator wires always-on reviewers =="
assert_grep "$ORCHESTRATOR" 'questions\.md' \
  "orchestrator writes questions.md under --turbo"
assert_grep "$ORCHESTRATOR" 'spec-reviewer' \
  "spec-reviewer wired in orchestrator"
# Old --paranoid gate REMOVED — assert the new always-on prose is present and the gate prose is absent.
assert_grep "$ORCHESTRATOR" 'always runs for medium|always-on for medium' \
  "spec-reviewer documented as always-on for the medium design rung"
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
# #619 collapsed `large` into `medium`, and the gate moved with it rather than
# being left pointing at a rung triage can no longer produce. A gate on a
# deleted tier is not a skipped test here -- it is a step that silently never
# runs, which is the exact #92 failure mode this row exists to catch.
assert_grep "$SUBAGENT_DRIVEN" 'tier == .medium' \
  "Step 4.5 gated on the medium design rung (post-#92 AC9, re-pointed by #619)"
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
# Step 4.5 can gate the design-rung dispatch. A future refactor that dropped
# this would silently skip Step 4.5 on medium tier — same observable failure
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
  "orchestrator Phase 6 design-rung note names SDD Step 4.5 (post-#92 AC7b)"

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
echo "== turbo medium parity: post-push post-impl-review documented in turbo.md =="
assert_grep "$TURBO_CMD" 'post-PR-push.*(/review-pr|review-pr).*Phase 1|(/review-pr|review-pr).*Phase 1.*post-PR-push' \
  "turbo.md documents post-push /review-pr Phase 1 post-impl-review for medium tier"
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
# Negative lock — the retired `.uberdev/research/issue-<N>/` cache (zero writers
# since #14; short-circuit deleted in #308 / RFC 0012 §3.5) must not be read back
# by any prompt the launcher renders. Both interactive heredocs carried a
# "Read pre-collected research (legacy cache)" step that could only ever no-op,
# and it shipped as step 2 of every trivial/small /solve prompt (#518).
# NOTE — this guard deliberately does NOT use the `|| echo "0"` idiom that
# DIRECTIVE_COUNT / INVOKE_COUNT / TURBO_FORWARD_COUNT above use. That idiom is
# only safe when the PASSING count is non-zero: `grep -c` already prints `0` on
# no-match AND exits 1, so on the passing path the fallback fires and appends a
# SECOND line, making the variable the two-line string "0\n0" — which is not
# `-eq 0`, so the guard fails while reporting "actual count: 0". (Observed live
# while writing this case.) Capture the rc explicitly instead, so a real grep
# error (rc>1: unreadable file, malformed regex) is reported as a broken probe
# rather than being laundered into a passing zero.
LEGACY_CACHE_COUNT="$(grep -cE 'Read pre-collected research' "$SOLVE_PIPELINE" 2>/dev/null)"
LEGACY_CACHE_RC=$?
if [[ "$LEGACY_CACHE_RC" -gt 1 ]] || ! [[ "$LEGACY_CACHE_COUNT" =~ ^[0-9]+$ ]]; then
  echo "  FAIL  the #518 legacy-cache probe could not run — treating this as broken, not as a zero"
  echo "        file:  $SOLVE_PIPELINE"
  echo "        grep rc: $LEGACY_CACHE_RC   captured count: '$LEGACY_CACHE_COUNT'"
  FAIL=$((FAIL + 1))
elif [[ "$LEGACY_CACHE_COUNT" -eq 0 ]]; then
  echo "  PASS  no heredoc reads the retired legacy research cache (count=0, #518)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  the retired legacy research-cache read step must not appear in any heredoc (#518)"
  echo "        file: $SOLVE_PIPELINE"
  echo "        expected count: 0"
  echo "        actual count:   $LEGACY_CACHE_COUNT"
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
echo "== Numbered steps in the trivial/small heredocs are gapless =="
# Deleting a step from a rendered prompt means renumbering every step after it.
# Nothing else in the repo covers that: the /simplify guard above is
# deliberately number-agnostic, and no test ever renders these heredocs — a
# `1. 3. 4.` run ships a visibly broken prompt with a fully green suite.
#
# Anchors: `<< EOF$` (with the space) and `^EOF$` are the exact pair
# tests/post-impl-review.test.sh already drives against this same file on the
# green windows job, so they are proven CR-safe here. The launcher's four
# trivial/small prompt heredocs open with `<< EOF`; its other heredocs use
# `<<EOF` / `<<EOF2` (no space) and are correctly not matched.
#
# `hn != 4` is reported as a setup error rather than silently passing: without
# it, a heredoc reshape empties the scan and this case goes vacuously green —
# which is the exact defect class #518 closes. `steps < 5` catches the
# "renumbered by deleting the rest" failure mode (current minimum is 5, the
# small-turbo heredoc). All iteration happens inside awk — no `for n in $var`,
# which zsh would run once over the whole string.
NUMBERING_REPORT="$(awk '
  /<< EOF$/            { in_h=1; hn++; expected=1; steps=0; bad=""; next }
  in_h && /^EOF$/      { in_h=0
                         if (steps < 5) bad = bad " only " steps " numbered steps"
                         if (bad != "") printf "heredoc#%d:%s\n", hn, bad
                         next }
  in_h && /^[0-9]+\./  { n = $0; sub(/\..*$/, "", n); n = n + 0
                         steps++
                         if (n != expected) bad = bad " expected " expected " got " n
                         expected = n + 1 }
  END                  { if (hn != 4) printf "setup error: expected 4 heredocs, saw %d\n", hn }
' "$SOLVE_PIPELINE")"
if [[ -z "$NUMBERING_REPORT" ]]; then
  echo "  PASS  all 4 trivial/small heredocs number their steps 1..N with no gap, restart or duplicate"
  PASS=$((PASS + 1))
else
  echo "  FAIL  a trivial/small heredoc has broken step numbering (#518)"
  echo "        file: $SOLVE_PIPELINE"
  echo "$NUMBERING_REPORT"
  FAIL=$((FAIL + 1))
fi

echo
echo "== #470: the unattended forward gains no consolidation prompt =="
# /review-pr Phase 0 asks whether to consolidate several open PRs into one
# review. /turbo's whole contract is unattended end-to-end, and it dispatches N
# solvers that each push a PR — precisely the >1-open-PR state that makes the
# offer fire. Phase 0 must therefore resolve `never` on this path, from the
# environment alone, BEFORE any gh round-trip.
TURBO_REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
assert_grep "$TURBO_REVIEW_PR" 'REVIEW_CONSOLIDATE OFFER=no REASON=%s' \
  "#470.turbo1 — Phase 0 has a no-offer arm that reports a typed reason on stderr"
assert_grep "$TURBO_REVIEW_PR" 'CONSOLIDATE=never; CONSOLIDATE_REASON=turbo' \
  "#470.turbo2 — UBERDEV_TURBO / --turbo resolves CONSOLIDATE=never before anything is asked"
# ORDERING is the load-bearing half: the decision must be reachable without gh.
# A gate that ran after discovery would still not prompt, but every unattended
# run would pay a rate-limited round-trip for an answer nobody consumes.
TURBO_GATE_LINE="$(awk '/CONSOLIDATE=never; CONSOLIDATE_REASON=turbo/ {print NR; exit}' "$TURBO_REVIEW_PR")"
TURBO_DISCOVER_LINE="$(awk '/discover_open_prs .review-pr\.0a./ {print NR; exit}' "$TURBO_REVIEW_PR")"
if [ -n "$TURBO_GATE_LINE" ] && [ -n "$TURBO_DISCOVER_LINE" ] \
   && [ "$TURBO_GATE_LINE" -lt "$TURBO_DISCOVER_LINE" ]; then
  echo "  PASS  #470.turbo3 — the turbo gate resolves BEFORE the open-PR discovery call (no gh round-trip on the unattended path)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #470.turbo3 — the turbo gate does not precede discovery; an unattended run would pay a gh call for an answer it discards"
  echo "        gate: ${TURBO_GATE_LINE:-<none>}  discovery: ${TURBO_DISCOVER_LINE:-<none>}"
  FAIL=$((FAIL + 1))
fi

echo
echo "== #532: the one-way tier ratchet is stated in every trivial/small heredoc =="
# WHAT THESE THREE CASES ARE — and, more importantly, what they are NOT.
# TF-R2 and TF-R3 are SHAPE CHECKS ON PROSE. They prove that the four rendered
# briefs carry the ratchet wording and no longer carry the retired sentence.
# They are NOT the behavioural proof of the escalation feature. That proof lives
# in tests/solve-fleet-workflow.test.sh (W1-W8 — the escalatedTier return
# channel, the upgrade-only gate, the three rejection verdicts and the
# no-extra-agents invariant) and in tests/solve-triage.test.sh /
# tests/solve-routing.test.sh (E1-E6, X1 — the uberdev:tier-<to> label raising
# raw_tier on the NEXT dispatch). A green grep here says the prompt asks for the
# escalation; it says nothing about what happens when a solver reports one. Do
# not let a later reader mistake one for the other.
#
# WHY TF-R1 EXISTS. TF-R2 and TF-R3 are only as trustworthy as the extraction
# underneath them: a heredoc reshape that empties the scan makes the presence
# checks vacuously true AND the absence check trivially true, in the same edit.
# That is the completeness-guard-with-a-disjoint-predicate failure this repo
# tracks as #370, and it is the same guard tests/post-impl-review.test.sh puts
# in front of its own extraction of this file. An unfound body is a FAILURE
# reported as `setup error`, never a pass.
#
# Anchors: the `<< EOF$` / `^EOF$` pair — the same one the numbering scan above
# drives against this same file on the green windows job. CR is stripped inside
# awk (`gsub`) rather than by piping through `tr`: .gitattributes pins only
# plugins/uberdev/hooks/** to eol=lf, so a Git-for-Windows clone may hold this
# file CRLF, and `^EOF$` would then match nothing. Doing it in awk also keeps
# this out of the `<writer> | <early-exiting reader>` shape that
# tests/epipe-guard.test.sh forbids — there is no pipeline here at all.
RATCHET_SETUP="$(awk '
  { gsub(/\r/, "") }
  /<< EOF$/       { in_h = 1; hn++; lines = 0; next }
  in_h && /^EOF$/ { in_h = 0
                    if (lines == 0) printf "heredoc#%d: body extracted empty\n", hn
                    next }
  in_h            { lines++ }
  END             { if (hn != 4) printf "expected 4 heredocs, saw %d\n", hn }
' "$SOLVE_PIPELINE")"
if [[ -z "$RATCHET_SETUP" ]]; then
  echo "  PASS  TF-R1 — all 4 trivial/small heredoc bodies extract non-empty (TF-R2/TF-R3 below are not vacuous)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TF-R1 setup error: the heredoc extraction is broken — TF-R2/TF-R3 below cannot be trusted"
  echo "        file: $SOLVE_PIPELINE"
  echo "$RATCHET_SETUP"
  FAIL=$((FAIL + 1))
fi

# TF-R2 — every one of the four briefs states the ratchet AND both halves of the
# record it must leave behind. Per-heredoc, not file-wide: a file-wide grep goes
# green when one brief keeps the wording and three lose it, which is exactly the
# regression DIRECTIVE_COUNT/INVOKE_COUNT above exist to catch on their own
# lines. `index()` is a literal substring test — no regex metacharacter in the
# searched text can change what is matched.
RATCHET_MISSING="$(awk '
  { gsub(/\r/, "") }
  /<< EOF$/ { in_h = 1; hn++; oneway = 0; nodown = 0; prline = 0; label = 0; next }
  in_h && /^EOF$/ {
      in_h = 0
      miss = ""
      if (!oneway) miss = miss " \"The ratchet is one-way\""
      if (!nodown) miss = miss " \"Nothing downgrades mid-task\""
      if (!prline) miss = miss " \"Tier escalated:\" (the PR-body line)"
      if (!label)  miss = miss " \"uberdev:tier-\" (the issue label)"
      if (miss != "") printf "heredoc#%d missing:%s\n", hn, miss
      next }
  in_h && index($0, "The ratchet is one-way")      { oneway = 1 }
  in_h && index($0, "Nothing downgrades mid-task") { nodown = 1 }
  in_h && index($0, "Tier escalated:")             { prline = 1 }
  in_h && index($0, "uberdev:tier-")               { label = 1 }
  END { if (hn != 4) printf "setup error: expected 4 heredocs, saw %d\n", hn }
' "$SOLVE_PIPELINE")"
if [[ -z "$RATCHET_MISSING" ]]; then
  echo "  PASS  TF-R2 — all 4 trivial/small heredocs state the one-way ratchet, the PR-body line and the uberdev:tier- label"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TF-R2 — a trivial/small heredoc no longer states the one-way ratchet (#532)"
  echo "        file: $SOLVE_PIPELINE"
  echo "$RATCHET_MISSING"
  FAIL=$((FAIL + 1))
fi

# TF-R3 — the load-bearing guard of the three. The retired sentence told the
# solver to "Escalate to /uberdev:brainstorm", an action the solver on this path
# CANNOT take: it is a leaf agent with no ability to dispatch a subagent, so the
# instruction resolved to nothing and the mis-triage went unrecorded. This reds
# the instant that sentence comes back in any of the four briefs.
RATCHET_RETIRED="$(awk '
  { gsub(/\r/, "") }
  /<< EOF$/       { in_h = 1; hn++; next }
  in_h && /^EOF$/ { in_h = 0; next }
  in_h && index($0, "Escalate to /uberdev:brainstorm") { printf "heredoc#%d: %s\n", hn, $0 }
  END { if (hn != 4) printf "setup error: expected 4 heredocs, saw %d\n", hn }
' "$SOLVE_PIPELINE")"
if [[ -z "$RATCHET_RETIRED" ]]; then
  echo "  PASS  TF-R3 — no trivial/small heredoc tells the leaf solver to escalate to /uberdev:brainstorm (an action it cannot take)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TF-R3 — the retired 'Escalate to /uberdev:brainstorm' instruction is back in a heredoc (#532)"
  echo "        file: $SOLVE_PIPELINE"
  echo "$RATCHET_RETIRED"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
