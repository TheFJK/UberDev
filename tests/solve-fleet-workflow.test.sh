#!/usr/bin/env bash
# tests/solve-fleet-workflow.test.sh — RFC 0015 (the detached-session retirement):
# the Workflow-native /solve + /turbo transport.
#
# Covers three surfaces that must move together, because a half-migrated
# transport is worse than either end state:
#   S — the shell seam: lib/dispatch.sh's backend enum + `auto` resolution +
#       the deprecation notice + the no-provider-arm refusal, and
#       lib/solve-launcher.sh's Step 5w args emission.
#   G — shape greps over skills/solve-fleet/workflow.js and its SKILL.md.
#   B — T3 BEHAVIORAL fixtures driving the script under the harness stubs with
#       canned returns, asserting the orchestration semantics the generic
#       carrier dry-run cannot see (tier routing, wave barriers, CB1/CB2,
#       null-agent handling, claim/manifest cross-check, model policy).
#
# GIT-BASH PORTABLE: grep + node only (no python3/PyYAML/mktemp). Runs on BOTH
# the ubuntu and windows shape-check jobs.
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/solve-fleet/SKILL.md"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/solve-fleet/workflow.js"
DISPATCH="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
TURBO_CMD="$REPO_ROOT/plugins/uberdev/commands/turbo.md"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"

for f in "$SKILL" "$WORKFLOW" "$DISPATCH" "$LAUNCHER" "$SOLVE_CMD" "$TURBO_CMD" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the solve-fleet behavioral fixture (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## solve-fleet-workflow (RFC 0015) — shell seam + shape greps + T3 behavioral fixtures"

# ---------------------------------------------------------------------------
# S — the shell seam
# ---------------------------------------------------------------------------
echo "== S: lib/dispatch.sh backend enum + auto resolution =="

# #381: `codex` is OUT of the enum. The assertion is pinned to the exact
# alternation, so it doubles as the retired-surface check -- re-adding a
# `|codex` member fails this line rather than passing a looser substring match.
grep -q "^_UBERDEV_DISPATCH_BACKEND_ENUM='auto|workflow|wezterm|background'$" "$DISPATCH" \
  && pass "S1 enum includes workflow ordered right after auto, and no longer declares codex" \
  || fail "S1 backend enum does not declare exactly {auto,workflow,wezterm,background}"

# S2 — `auto` must resolve to workflow, and must NEVER resolve to a deprecated
# detached backend. This is the whole point of the RFC: the old per-OS matrix
# (macos->wezterm/detached, wsl2/linux->detached) is GONE from the auto arm.
if grep -q 'resolved="workflow"; reason="auto-workflow"' "$DISPATCH"; then
  pass "S2a auto resolves to workflow"
else
  fail "S2a no auto-workflow resolution found"
fi
for dead in 'reason="auto-macos-wezterm"' 'reason="auto-macos-fallback"' 'reason="auto-wsl2"' 'reason="auto-linux"' 'reason="auto-windows-wezterm"'; do
  if grep -qF "$dead" "$DISPATCH"; then
    fail "S2b the retired auto arm $dead still exists — auto can still pick a detached backend"
  fi
done
grep -qF 'reason="auto-macos-wezterm"' "$DISPATCH" || grep -qF 'reason="auto-wsl2"' "$DISPATCH" \
  || pass "S2b every per-OS auto arm is retired (auto never selects a detached backend)"

# S3 — the native-Windows hard error is gone: workflow needs no process tree.
grep -q 'error: native Windows requires WezTerm' "$DISPATCH" \
  && fail "S3 the native-Windows WezTerm hard error survives in the auto arm" \
  || pass "S3 native Windows no longer hard-errors in auto (workflow needs no supervisor)"
grep -q 'workflow) return 0 ;;' "$DISPATCH" \
  && pass "S3b workflow is exempt from the numeric-supervision gate" \
  || fail "S3b workflow is not exempt from _uberdev_dispatch_numeric_supervision_supported"

# S4 — TOMBSTONE. This block used to assert the OPPOSITE: that the detached
# `claude --bg` backend was deprecated-but-present, and S4c called its removal
# "a breaking change, not a deprecation". That guard did its job — it held the
# line until the deprecation had actually paid out. RFC 0015 §7 (as amended)
# records the payout: `workflow` shipped across /solve, /turbo, /goal and — as
# of #381 — /review-pr and /simplify, which were the only two workflows that
# structurally required a supervised detached transport. With nothing selecting
# it and nothing requiring it, the backend is DELETED, so the assertions are
# INVERTED rather than deleted (the retired-surface pattern in
# tests/ghostty-dispatch-no-instance-leak.test.sh): the surface must stay gone.
#
# Deliberately NO deprecation shim survives — a dormant alias is exactly how a
# retired transport drifts back onto a default path.
grep -q '_UBERDEV_DISPATCH_DEPRECATED_BACKENDS=' "$DISPATCH" \
  && fail "S4a the deprecated-backends list is back — the retired transport has a re-entry point" \
  || pass "S4a no deprecated-backends list survives the deletion"
grep -q '_uberdev_dispatch_deprecation_notice()' "$DISPATCH" \
  && fail "S4b a deprecation-notice emitter survives with nothing left to deprecate" \
  || pass "S4b the deprecation-notice emitter is gone with its only subject"
grep -q '_uberdev_dispatch_claude_bg()' "$DISPATCH" \
  && fail "S4c the retired detached provider arm is back in lib/dispatch.sh" \
  || pass "S4c the retired detached provider arm stays deleted"
grep -Fq 'claude-bg' "$DISPATCH" \
  && fail "S4d lib/dispatch.sh still names the retired backend somewhere" \
  || pass "S4d lib/dispatch.sh carries no reference to the retired backend"

# S5 — workflow has NO provider arm, and reaching one fails loud.
if grep -qE '^\s+workflow\)\s*$' "$DISPATCH" && grep -q "is dispatched by the session's Workflow tool" "$DISPATCH"; then
  pass "S5 _uberdev_agent_dispatch_backend refuses loudly for workflow (no silent fallthrough)"
else
  fail "S5 no loud refusal for a workflow-backend dispatch attempt"
fi

echo "== S: lib/solve-launcher.sh Step 5w =="

grep -q 'if \[\[ "\${UBERDEV_RESOLVED_BACKEND:-}" == "workflow" \]\]; then' "$LAUNCHER" \
  && pass "S6 Step 5w branches on the resolved workflow backend" \
  || fail "S6 no Step 5w workflow branch in the launcher"

# S7 — the branch must sit BEFORE the detached dispatch loop, or a workflow run
# would also spawn detached sessions (double dispatch, double claims).
S5W_LINE="$(grep -n 'UBERDEV_RESOLVED_BACKEND:-}" == "workflow"' "$LAUNCHER" | head -1 | cut -d: -f1)"
S5B_LINE="$(grep -n "^# Step 5b' — dispatch via the backend resolved" "$LAUNCHER" | head -1 | cut -d: -f1)"
if [ -n "$S5W_LINE" ] && [ -n "$S5B_LINE" ] && [ "$S5W_LINE" -lt "$S5B_LINE" ]; then
  pass "S7 Step 5w precedes Step 5b' (no double dispatch)"
else
  fail "S7 Step 5w is not ordered before the detached dispatch loop (5w=$S5W_LINE 5b=$S5B_LINE)"
fi

grep -q 'uberdev_emit_workflow_args solve-fleet' "$LAUNCHER" \
  && pass "S8 the launcher emits a solve-fleet args envelope" \
  || fail "S8 no solve-fleet args emission"

# S9 — RFC 0012 §4.1: refuse at preflight when the on-disk script is missing.
grep -q 'skills/solve-fleet/workflow.js' "$LAUNCHER" && grep -q 'missing (RFC 0012 §4.1)' "$LAUNCHER" \
  && pass "S9 the launcher validates workflow.js exists before mandating the call" \
  || fail "S9 no on-disk workflow.js preflight guard"

# S10 — prompts/contexts must outlive the launcher process.
grep -q 'UBERDEV_KEEP_TMPDIR=1' "$LAUNCHER" \
  && pass "S10 the run dir is kept (fleet agents read prompts after the launcher exits)" \
  || fail "S10 the launcher does not keep its tmpdir for the fleet"

# S21 (#439) — the launcher is the ONLY process that still sees the real
# checkout; the fleet's worktrees are cut by the runtime and the script never
# learns what ref they came from. Capture the branch here and thread it, or a
# solver launched from a stacked branch opens its PR against the repo default.
grep -q 'git branch --show-current' "$LAUNCHER" \
  && pass "S21a the launcher captures the base branch from the real checkout" \
  || fail "S21a no 'git branch --show-current' capture in the launcher"
grep -q 'baseBranch=' "$LAUNCHER" \
  && pass "S21b the base branch is carried in the solve-fleet args envelope" \
  || fail "S21b the envelope does not carry baseBranch"
# S21c — the captured branch is only forwarded when it EXISTS ON THE REMOTE.
# `gh pr create --base <branch>` hard-fails on a base GitHub does not have, and
# /solve + /turbo deliberately do not read pr_base_branch, so there is no
# operator override to recover with: launching from a local-only branch would
# fail PR creation for EVERY issue in the fleet, where pre-#439 the PR was opened
# against the repo default. workflow.js emits no --base for an empty value, so
# blanking it degrades to the old behaviour instead of hard-failing.
# Mutation guard: delete the rev-parse arm => S21c RED.
SOLVE_BASE_BLOCK="$(sed -n '/# --- BEGIN solve-fleet base capture (#439) ---/,/# --- END solve-fleet base capture (#439) ---/p' "$LAUNCHER")"
if [ -z "$SOLVE_BASE_BLOCK" ]; then
  fail "S21c the base-capture block is not delimited by its #439 markers"
elif grep -q 'rev-parse --verify --quiet "refs/remotes/origin/\$SOLVE_FLEET_BASE_BRANCH"' <<<"$SOLVE_BASE_BLOCK" \
  && grep -q 'SOLVE_FLEET_BASE_BRANCH=""' <<<"$SOLVE_BASE_BLOCK"; then
  pass "S21c a base branch missing from origin is blanked, not forwarded into gh pr create --base"
else
  fail "S21c the captured base is forwarded without checking it exists on origin"
fi

# S11 — the parser accepts exactly the live enum. #381 removed `codex`, so the
# parser alternation and _UBERDEV_DISPATCH_BACKEND_ENUM must agree member for
# member; a `--backend=codex` that parsed here but died in the resolver would be
# a worse failure than one refused at the flag.
grep -q 'auto|workflow|wezterm|background) ;;' "$LAUNCHER" \
  && pass "S11 --backend=workflow parses, and the retired codex backend does not" \
  || fail "S11 the --backend parser does not accept exactly {auto,workflow,wezterm,background}"
grep -qE '^[^#]*\bcodex\b' "$LAUNCHER" \
  && fail "S11b the launcher still names the retired codex backend outside a comment" \
  || pass "S11b the launcher names codex nowhere outside a comment"

echo "== S: command files mandate the Workflow call =="
for f in "$SOLVE_CMD" "$TURBO_CMD"; do
  base="$(basename "$f")"
  grep -q 'Workflow({scriptPath: "\$CLAUDE_PLUGIN_ROOT/skills/solve-fleet/workflow.js"}' "$f" \
    && pass "S12 $base mandates the solve-fleet Workflow call" \
    || fail "S12 $base has no Workflow mandate"
  grep -q 'WORKFLOW_ARGS_BEGIN' "$f" \
    && pass "S13 $base names the args markers (verbatim relay, DR-2)" \
    || fail "S13 $base does not reference the args markers"
  grep -q '## No-Workflow fallback\|No-Workflow fallback:' "$f" \
    && pass "S14 $base documents the No-Workflow fallback" \
    || fail "S14 $base has no No-Workflow fallback"
  grep -q '"Workflow"' "$f" \
    && pass "S15 $base allows the Workflow tool" \
    || fail "S15 $base does not list Workflow in allowed-tools"
done

# ---------------------------------------------------------------------------
# G — shape greps over workflow.js / SKILL.md
# ---------------------------------------------------------------------------
echo "== G: workflow.js shape =="

META_JSON="$(node "$HARNESS" meta "$WORKFLOW" 2>/dev/null)"
if [ -n "$META_JSON" ] && printf '%s' "$META_JSON" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit((m.name==="solve-fleet" && Array.isArray(m.phases) && m.phases.join(",")==="intake,research,design,implement,deliver")?0:1);})'; then
  pass "G1 meta literal parses: name=solve-fleet, phases=[intake,research,design,implement,deliver]"
else
  fail "G1 meta literal wrong; got: $META_JSON"
fi

# G2 — model policy: the solver/research/design agents are JUDGMENT paths and
# must NOT be pinned to a cheap model; only the manifest relay pins haiku.
grep -q 'model: "haiku"' "$WORKFLOW" \
  && pass "G2a the mechanical intake relay pins haiku" \
  || fail "G2a no haiku pin on the mechanical relay"
if grep -qE 'model:[[:space:]]*"(fable|sonnet|opus)"' "$WORKFLOW"; then
  fail "G2b a judgment agent is model-pinned — the session flagship must flow through"
else
  pass "G2b no judgment agent is model-pinned"
fi

# G3 — only the solver is worktree-isolated. An isolated researcher would write
# its artifact into a throwaway worktree (the artifact path-leak class).
ISO_COUNT="$(grep -c 'isolation: "worktree"' "$WORKFLOW" || true)"
[ "$ISO_COUNT" = "1" ] \
  && pass "G3 exactly one isolation:\"worktree\" site (the solver)" \
  || fail "G3 expected exactly 1 isolation:\"worktree\" site, found $ISO_COUNT"

if grep -A6 'agent(solvePrompt(' "$WORKFLOW" | grep -q 'isolation: "worktree"'; then
  pass "G3b the isolation site is the solver agent() call"
else
  fail "G3b isolation:\"worktree\" is not on the solver agent() call"
fi

# G4 — the leaf constraint is honoured: the solver prompt must tell the agent it
# cannot dispatch and must do the work itself, or medium-tier issues silently
# no-op on the old "invoke /uberdev:orchestrator" brief.
grep -q 'leaf agent with no ability to dispatch subagents' "$WORKFLOW" \
  && pass "G4 the solver prompt states the leaf constraint" \
  || fail "G4 the solver prompt does not address the leaf constraint"

# G5 — house rules that MUST reach the solver prompt (they are the project's
# non-negotiables and there is no human in the loop on /turbo).
grep -q 'Co-Authored-By' "$WORKFLOW" \
  && pass "G5a the solver is told not to add attribution trailers" \
  || fail "G5a no attribution-trailer prohibition in the solver prompt"
grep -q 'NOT bump the project version' "$WORKFLOW" \
  && pass "G5b the solver is told not to bump the version (parallel-batch collision guard)" \
  || fail "G5b no version-bump prohibition — parallel solvers would collide on the release surfaces"
grep -q 'Closes #' "$WORKFLOW" \
  && pass "G5c the PR body must carry Closes #N" \
  || fail "G5c no Closes #N requirement in the delivery brief"
grep -q 'body-file' "$WORKFLOW" \
  && pass "G5d the PR body goes through --body-file (2nd-order injection guard)" \
  || fail "G5d the solver may pass an inline --body"

# G6 — the solver must stop at PR open; auto-merge/auto-review is /goal's call.
grep -q 'do NOT chain into a review command' "$WORKFLOW" \
  && pass "G6 the solver does not auto-chain into review/merge" \
  || fail "G6 no explicit stop-at-PR instruction"

# G7 — untrusted-input discipline: issue text is never interpolated into a
# prompt by the script; each agent reads it itself.
grep -q 'UNTRUSTED INPUT' "$WORKFLOW" \
  && pass "G7 agents are told to treat issue text as untrusted input" \
  || fail "G7 no untrusted-input framing"

# --- #515: the solver's self-report must stop reading as fact -----------------
# Row ids continue at G11: G8/G9/G10 are the SKILL.md seam below, and a `G8a`
# wedged next to `G8` is the row-id-collision class this repo has already been
# bitten by.

# G11 — `testsRun` is a boolean the SOLVER composes about its own diligence.
# Nothing in this repo can falsify it (no junit artifact, no receipt), so the
# only honest fix is to stop naming it as though it were established: the field
# is `testsRunClaimed`. The old bare token must be GONE, or both names coexist
# and a reader picks whichever they saw first. `testsRunClaimed:` does not
# contain `testsRun:`, so the second grep is a real absence check.
if grep -qE '^[[:space:]]*testsRunClaimed: \{ type: "boolean"' "$WORKFLOW" \
  && ! grep -q 'testsRun:' "$WORKFLOW"; then
  pass "G11 the solver's tests self-report is declared as testsRunClaimed (the bare testsRun is gone)"
else
  fail "G11 workflow.js still declares a bare testsRun: property (or never declares testsRunClaimed)"
fi

# G12 — and it must stay UNREAD. A claim nothing consumes is honest; the moment
# a count or a status expression keys off it, the fleet is back to treating a
# self-report as evidence. finalize() is where every published number is built,
# so the field must not appear inside it. Non-vacuous: the declaration must
# exist for the absence to mean anything.
FINALIZE_BLOCK="$(sed -n '/^function finalize() {/,/^}/p' "$WORKFLOW")"
if [ -z "$FINALIZE_BLOCK" ]; then
  fail "G12 could not locate finalize() in workflow.js — the assertion cannot be evaluated"
elif grep -q 'testsRunClaimed' "$WORKFLOW" && ! grep -q 'testsRunClaimed' <<<"$FINALIZE_BLOCK"; then
  pass "G12 testsRunClaimed feeds no count, status or PR expression (it is recorded, never believed)"
else
  fail "G12 finalize() reads testsRunClaimed — an unverifiable self-report is driving a published number"
fi

# G13 — the proof edge is a MECHANICAL relay, so it pins haiku exactly like the
# manifest intake. Two haiku sites, no more: a third would mean a judgment agent
# got pinned to a cheap model (G2b already forbids the flagship names, but it
# cannot see a haiku pin on a reviewer).
HAIKU_COUNT="$(grep -c 'model: "haiku"' "$WORKFLOW" || true)"
[ "$HAIKU_COUNT" = "2" ] \
  && pass "G13 exactly two haiku pins (manifest intake + the PR-proof relay); every judgment agent inherits" \
  || fail "G13 expected exactly 2 model:\"haiku\" sites (intake + verify-prs), found $HAIKU_COUNT"

# G14 — the discriminator must be the HTTP STATUS INTEGER, from `gh api -i`.
# `gh pr view <n>` exits non-zero for 404, 403, 429 and a dropped connection
# alike, so a claim-vs-proof rule built on its exit code downgrades a REAL PR
# out of /goal's queue the first time GitHub rate-limits the fleet. 404 has to
# be distinguishable from "GitHub would not answer", and only the status line is.
if grep -q 'gh api -i' "$WORKFLOW" && grep -q '/pulls/' "$WORKFLOW"; then
  pass "G14 the proof relay reads the HTTP status line via \`gh api -i .../pulls/<N>\` (404 != unreachable)"
else
  fail "G14 the proof relay does not pin \`gh api -i\` on /pulls/ — a bare exit code conflates 404 with 403/429"
fi

# G15 — re-affirms G3 under the new agent. A worktree-isolated verifier would be
# probing GitHub from a throwaway checkout for no reason; more importantly the
# count must not drift as agents are added. This one PASSES before the relay
# exists: it is a guard, not a new claim.
ISO_COUNT_AFTER="$(grep -c 'isolation: "worktree"' "$WORKFLOW" || true)"
[ "$ISO_COUNT_AFTER" = "1" ] \
  && pass "G15 the PR-proof relay is NOT worktree-isolated (still exactly one isolation site: the solver)" \
  || fail "G15 isolation:\"worktree\" site count drifted to $ISO_COUNT_AFTER"

# G16 — the proof relay is READ-ONLY against GitHub. It runs unattended on
# /turbo, so "verify this PR" must never become "tidy this PR up".
grep -q 'do not open, close, comment on, or modify' "$WORKFLOW" \
  && pass "G16 the proof relay carries an explicit read-only prohibition" \
  || fail "G16 the proof relay may mutate GitHub state"

# G17 — DR-5, the invariant recorded in this file's header: no agent-derived
# string is ever interpolated into a downstream prompt. The solver's `branch` is
# agent-composed text, so the relay must DISCOVER the head ref itself and the
# comparison must happen in JS. A `.branch` inside the prompt builder would be
# exactly the envelope breach this script is designed to avoid.
VERIFY_PROMPT_BLOCK="$(sed -n '/^function verifyPrsPrompt(/,/^}/p' "$WORKFLOW")"
if [ -z "$VERIFY_PROMPT_BLOCK" ]; then
  fail "G17 verifyPrsPrompt() not found — the proof relay has no prompt builder"
elif grep -q '\.branch' <<<"$VERIFY_PROMPT_BLOCK"; then
  fail "G17 verifyPrsPrompt() interpolates the solver-composed .branch (DR-5 envelope breach)"
else
  pass "G17 verifyPrsPrompt() interpolates no agent-derived string (the relay discovers headRefName itself)"
fi

# G18 — CB1 accounting must move WITH the agent. The proof relay is a real
# dispatch; a ceiling that does not count it under-projects by one on every run
# and the "abort before dispatch" guarantee stops being exact. Both doc copies
# of the formula move too, or the next reader trusts the stale one.
RFC0015="$REPO_ROOT/docs/rfc/0015-workflow-native-dispatch.md"
if [ ! -r "$RFC0015" ]; then
  # Never let a missing file read as "the stale formula is absent" — that is a
  # vacuous green, and this repo has shipped one before.
  fail "G18 cannot read $RFC0015 — the doc half of the assertion is unevaluable"
elif grep -q 'const projected = 2 + intakeIssues.length' "$WORKFLOW" \
  && grep -q '2 + issues + 6' "$SKILL" \
  && ! grep -q '1 + issues + 6' "$SKILL" \
  && ! grep -q '1 + issues + 6' "$RFC0015"; then
  pass "G18 the CB1 projection counts both relays (2 + issues + 6x design), in code and in both docs"
else
  fail "G18 the CB1 projection or one of its doc copies still says 1 + issues + 6x design"
fi

echo "== G: SKILL.md seam =="
grep -q 'skills/solve-fleet/workflow.js' "$SKILL" \
  && pass "G8 SKILL.md names its workflow script" || fail "G8 SKILL.md does not name workflow.js"
grep -q '## No-Workflow fallback' "$SKILL" \
  && pass "G9 SKILL.md carries the No-Workflow fallback section" || fail "G9 no fallback section"
grep -q 'RFC 0015' "$SKILL" && ! grep -Fq 'claude-bg' "$SKILL" \
  && pass "G10 SKILL.md cites RFC 0015 and no longer offers the retired backend" \
  || fail "G10 SKILL.md still names the retired backend (or lost its RFC 0015 citation)"

# G19 — the return contract has to be DOCUMENTED and RENDERED, or it is the
# dead-contract class this repo has been filing issues about: a key nothing
# reads. SKILL.md describes the fields; both command files print the counts.
if grep -q 'provenCommitCount' "$SKILL" && grep -q 'prProof' "$SKILL" \
  && grep -q 'verification' "$SKILL" \
  && grep -q 'return.verification.confirmed' "$SOLVE_CMD" \
  && grep -q 'return.verification.confirmed' "$TURBO_CMD"; then
  pass "G19 the verification contract is documented in SKILL.md and rendered by both command files"
else
  fail "G19 the verification contract is undocumented or unrendered (a key nothing reads)"
fi

# ---------------------------------------------------------------------------
# B — T3 behavioral fixtures
# ---------------------------------------------------------------------------
echo "== B: T3 behavioral fixtures (harness stubs) =="

FIXTURE_OUT="$(node -e '
const h = require(process.argv[1]);
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8");
const meta = h.extractMeta(src).meta;
const RD = "/r/.uberdev/run/RID";

function buildArgs(extra, cfgExtra) {
  const cfg = Object.assign({
    runId: "RID", runDirAbs: RD, pluginRootAbs: "/p", repoRootAbs: "/r",
    manifestPathAbs: RD + "/solve-fleet-manifest.json",
    issues: "11,12", issueCount: 2, concurrency: 6, autoMode: false,
    repoSlug: "acme/widget", branchPrefix: "worktree-solve-issue-",
    solveTimeoutS: 3600, maxAgents: 250, timestampIso: "2026-01-01T00:00:00Z",
  }, cfgExtra || {});
  return Object.assign({ v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "solve-fleet", config: cfg }, extra || {});
}
function intake(issues) { return { rc: 0, issues: issues }; }
function rec(issue, tier) {
  return { issue: issue, tier: tier, promptFile: RD + "/solve-prompt-" + issue + ".txt" };
}
function solved(issue, pr) {
  return { issue: issue, status: "PR_OPENED", branch: "fix/" + issue + "-x", prNumber: pr,
    prUrl: "https://example/pull/" + pr, commitCount: 1, testsRunClaimed: true, summary: "done", blocker: "" };
}
// #515 fixture helpers. They sit BESIDE solved() and never edit it — B6/B7/
// B29-B32/B41 all key off the canonical shape.
//   claimed()  — a solver return with one field bent, to model a claim that
//                disagrees with reality.
//   proofRow() — one raw observation from the verify-prs relay. Deliberately
//                carries no verdict field, mirroring S.prProof.
//   proof()    — the relay envelope.
function claimed(issue, pr, over) { return Object.assign(solved(issue, pr), over || {}); }
function proofRow(pr, headRef, over) {
  return Object.assign(
    { pr: pr, httpStatus: 200, number: pr, url: "https://example/pull/" + pr,
      headRefName: headRef, state: "OPEN", commitCount: 1, attempts: 1 }, over || {});
}
function proof(rows) { return { rc: 0, rows: rows }; }
function trivialReturns() {
  return {
    "manifest-intake": intake([rec(11, "trivial"), rec(12, "small")]),
    "solve:#11 (trivial)": solved(11, 901),
    "solve:#12 (small)": solved(12, 902),
    "verify-prs": proof([proofRow(901, "fix/11-x"), proofRow(902, "fix/12-x")]),
  };
}
function mediumReturns() {
  return {
    "manifest-intake": intake([rec(11, "medium"), rec(12, "trivial")]),
    "research:#11:codebase": { artifactPath: RD + "/issue-11/research-codebase.md", rc: 0, headline: "h" },
    "research:#11:constraints": { artifactPath: RD + "/issue-11/research-constraints.md", rc: 0, headline: "h" },
    "research:#11:test-coverage": { artifactPath: RD + "/issue-11/research-test-coverage.md", rc: 0, headline: "h" },
    "spec:#11": { path: RD + "/issue-11/spec.md", rc: 0, headline: "h" },
    "spec-review:#11": { verdict: "APPROVE", rc: 0, headline: "h", blockingFindings: [] },
    "plan:#11": { path: RD + "/issue-11/plan.md", rc: 0, headline: "h" },
    "solve:#11 (medium)": solved(11, 901),
    "solve:#12 (trivial)": solved(12, 902),
    "verify-prs": proof([proofRow(901, "fix/11-x"), proofRow(902, "fix/12-x")]),
  };
}
function run(args, fixture) {
  const pre = h.preprocess(src);
  const record = h.makeRecord();
  const sb = h.makeSandbox(Object.assign({ args }, fixture), meta, record).sandbox;
  const pending = vm.runInNewContext(pre.wrapped, sb, { filename: "solve-fleet", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function resultOf(record) {
  const line = record.logs.find(function (l) { return l.indexOf("WORKFLOW_RESULT ") === 0; });
  return line ? JSON.parse(line.slice("WORKFLOW_RESULT ".length)) : null;
}
function labels(record) { return record.agentCalls.map(function (c) { return c.label; }); }
// The PR numbers the verify-prs relay was actually asked about, read back off
// the prompt itself — "" when the relay ran with an empty list, null when no
// relay was dispatched at all. Those two are different facts and the tests
// distinguish them.
function probedNums(record) {
  const c = record.agentCalls.find(function (x) { return x.label === "verify-prs"; });
  if (!c) return null;
  const m = c.prompt.match(/\n[ ]+- [0-9]+/g);
  return m ? m.map(function (s) { return s.replace(/[^0-9]/g, ""); }).join(",") : "";
}

(async function () {
  const out = {};

  // Run A — trivial/small tiers: solver only, NO research/design agents.
  const recA = await run(buildArgs(), { agentReturns: trivialReturns() });
  const resA = resultOf(recA);
  const cA = h.countAgentsByPhase(recA);
  out.aViolations = recA.violations.length;
  out.aPhases = recA.phases.join(",");
  out.aResearch = cA.research || 0;
  out.aDesign = cA.design || 0;
  out.aImplement = cA.implement || 0;
  out.aPrs = resA ? resA.counts.prOpened : null;
  out.aPrNums = resA ? resA.prsOpened.join(",") : null;
  out.aDesigned = resA ? resA.designedIssues : null;
  // the intake relay pins haiku; every solver inherits (model null)
  const intakeCall = recA.agentCalls.find(function (c) { return c.label === "manifest-intake"; });
  out.aIntakeHaiku = !!(intakeCall && intakeCall.model === "haiku");
  out.aSolversInherit = recA.agentCalls.filter(function (c) { return /^solve:#/.test(c.label || ""); })
    .every(function (c) { return c.model === null; });

  // Run B — medium tier gets the full design chain; trivial in the same batch does not.
  const recB = await run(buildArgs(), { agentReturns: mediumReturns() });
  const resB = resultOf(recB);
  const cB = h.countAgentsByPhase(recB);
  out.bResearch = cB.research || 0;
  out.bDesign = cB.design || 0;
  out.bImplement = cB.implement || 0;
  out.bDesigned = resB ? resB.designedIssues : null;
  out.bResearchArtifacts = resB ? resB.researchArtifacts : null;
  // the medium solver prompt must carry the plan path
  const solverB = recB.agentCalls.find(function (c) { return c.label === "solve:#11 (medium)"; });
  out.bPlanInPrompt = !!(solverB && solverB.prompt.indexOf("/issue-11/plan.md") >= 0);
  const solverB12 = recB.agentCalls.find(function (c) { return c.label === "solve:#12 (trivial)"; });
  out.bTrivialNoPlan = !!(solverB12 && solverB12.prompt.indexOf("plan.md") < 0);

  // Run C — the spec review loop is BOUNDED: REVISIONS_REQUIRED does not re-run
  // the writer (the #308 unbounded-loop class).
  const cReturns = Object.assign({}, mediumReturns(),
    { "spec-review:#11": { verdict: "REVISIONS_REQUIRED", rc: 0, headline: "h", blockingFindings: ["gap"] } });
  const recC = await run(buildArgs(), { agentReturns: cReturns });
  const resC = resultOf(recC);
  out.cSpecCalls = labels(recC).filter(function (l) { return l === "spec:#11"; }).length;
  out.cReviewCalls = labels(recC).filter(function (l) { return l === "spec-review:#11"; }).length;
  out.cStillPlanned = labels(recC).indexOf("plan:#11") >= 0;
  out.cAudit = !!(resC && resC.auditEvents.some(function (e) { return e.event === "spec_review_not_approved"; }));

  // Run D — intake null: no solver is dispatched, result still observable.
  const dReturns = Object.assign({}, trivialReturns()); dReturns["manifest-intake"] = null;
  const recD = await run(buildArgs(), { agentReturns: dReturns });
  const resD = resultOf(recD);
  out.dObservable = !!resD;
  out.dNoSolvers = !recD.agentCalls.some(function (c) { return /^solve:#/.test(c.label || ""); });
  out.dNullAudit = !!(resD && resD.auditEvents.some(function (e) { return e.event === "intake_null"; }));

  // Run E — manifest/envelope mismatch: only the cross-checked set is solved.
  // The launcher claimed 11 and 12; the manifest also lists 99 (never claimed).
  const eReturns = Object.assign({}, trivialReturns(),
    { "manifest-intake": intake([rec(11, "trivial"), rec(12, "small"), rec(99, "trivial")]) });
  const recE = await run(buildArgs(), { agentReturns: eReturns });
  const resE = resultOf(recE);
  out.eSolved = resE ? resE.issueCount : null;
  out.eNo99 = !recE.agentCalls.some(function (c) { return (c.label || "").indexOf("solve:#99") === 0; });
  out.eMismatchAudit = !!(resE && resE.auditEvents.some(function (e) { return e.event === "intake_manifest_mismatch"; }));

  // Run F — a solver returning null becomes a FAILED record for THAT issue only.
  const fReturns = Object.assign({}, trivialReturns()); fReturns["solve:#11 (trivial)"] = null;
  const recF = await run(buildArgs(), { agentReturns: fReturns });
  const resF = resultOf(recF);
  out.fFailed = resF ? resF.counts.failed : null;
  out.fOpened = resF ? resF.counts.prOpened : null;
  out.fFailedIssue = resF ? (resF.results.filter(function (r) { return r.status === "FAILED"; })[0] || {}).issue : null;
  out.fNullAudit = !!(resF && resF.auditEvents.some(function (e) { return e.event === "solver_null"; }));

  // Run G — CB1: a maxAgents ceiling below the projection aborts BEFORE dispatch.
  const recG = await run(buildArgs(null, { maxAgents: 2 }), { agentReturns: mediumReturns() });
  const resG = resultOf(recG);
  out.gTripped = !!(resG && resG.cb1Tripped);
  out.gNoSolvers = !recG.agentCalls.some(function (c) { return /^solve:#/.test(c.label || ""); });
  out.gAudit = !!(resG && resG.auditEvents.some(function (e) { return e.event === "agent_ceiling_cb1"; }));

  // Run H — waves: concurrency=1 over 2 issues means the second solver is not
  // dispatched until the first wave settles (a real live ceiling, not chunking).
  const recH = await run(buildArgs(null, { concurrency: 1 }), { agentReturns: trivialReturns() });
  const resH = resultOf(recH);
  out.hIssues = resH ? resH.issueCount : null;
  out.hConcurrency = resH ? resH.concurrency : null;
  out.hSolverOrder = labels(recH).filter(function (l) { return /^solve:#/.test(l || ""); }).join(",");
  out.hMaxConcurrent = recH.maxConcurrentAgents === undefined ? null : recH.maxConcurrentAgents;

  // Run I — a research lens returning null degrades to fewer artifacts, never a throw.
  const iReturns = Object.assign({}, mediumReturns()); iReturns["research:#11:constraints"] = null;
  const recI = await run(buildArgs(), { agentReturns: iReturns });
  const resI = resultOf(recI);
  out.iObservable = !!resI;
  out.iArtifacts = resI ? resI.researchArtifacts : null;
  out.iStillSolved = resI ? resI.counts.prOpened : null;
  out.iNullCounted = !!(resI && resI.nullsByPhase && resI.nullsByPhase.research >= 1);

  // Run J — a design artifact path OUTSIDE the run dir is rejected (§4.5 C-7).
  const jReturns = Object.assign({}, mediumReturns(),
    { "plan:#11": { path: "/etc/passwd", rc: 0, headline: "h" } });
  const recJ = await run(buildArgs(), { agentReturns: jReturns });
  const resJ = resultOf(recJ);
  out.jDesigned = resJ ? resJ.designedIssues : null;
  const solverJ = recJ.agentCalls.find(function (c) { return c.label === "solve:#11 (medium)"; });
  out.jNoLeak = !!(solverJ && solverJ.prompt.indexOf("/etc/passwd") < 0);

  // Run K (#439) — a known base branch reaches the solver prompt as a literal
  // `--base "<branch>"` instruction; an unknown base emits NO --base at all
  // (detached HEAD must not produce a bogus flag). Mirrors the conditional
  // baseArg in scan-fleet/workflow.js, the reference implementation.
  const recK = await run(buildArgs(null, { baseBranch: "feat/parent" }), { agentReturns: trivialReturns() });
  const solverK = recK.agentCalls.find(function (c) { return c.label === "solve:#11 (trivial)"; });
  out.kBaseInPrompt = !!(solverK && solverK.prompt.indexOf("--base \"feat/parent\"") >= 0);
  const solverA = recA.agentCalls.find(function (c) { return c.label === "solve:#11 (trivial)"; });
  out.kNoBaseWhenUnknown = !!(solverA && solverA.prompt.indexOf("--base") < 0);

  // ------------------------------------------------------------------ #515
  // Claim verification. Every run below is ultimately about ONE rule: the proof
  // wins in the field that drives behaviour, the claim is never erased, and the
  // disagreement is an audit event.

  // Run S — the INCOHERENT claim: status PR_OPENED with prNumber 0. No probe
  // can settle this and none is spent; the record contradicts itself on its
  // face. It also closes a live accounting split on main: counts.prOpened
  // filters on `status` while prsOpened filters on `n > 0`, so this record used
  // to be counted by one and dropped by the other, silently.
  const sReturns = Object.assign({}, trivialReturns(),
    { "solve:#11 (trivial)": claimed(11, 0, { status: "PR_OPENED" }) });
  const recS = await run(buildArgs(), { agentReturns: sReturns });
  const resS = resultOf(recS);
  const s11 = resS ? resS.results.filter(function (r) { return r.issue === 11; })[0] : null;
  out.sStatus = s11 ? s11.status : null;
  out.sClaimedStatus = s11 ? s11.claimedStatus : null;
  out.sAudit = !!(resS && resS.auditEvents.some(function (e) { return e.event === "pr_claim_incoherent"; }));
  out.sOpened = resS ? resS.counts.prOpened : null;
  out.sPrNums = resS ? resS.prsOpened.join(",") : null;
  out.sProbed = probedNums(recS);

  // Run O — the relay returns NULL (user-skip / terminal API error). The claims
  // must SURVIVE. A probe that could not speak proves nothing, and dropping a
  // real PR out of the /goal queue on silence is strictly worse than not probing.
  const oReturns = Object.assign({}, trivialReturns()); oReturns["verify-prs"] = null;
  const recO = await run(buildArgs(), { agentReturns: oReturns });
  const resO = resultOf(recO);
  out.oObservable = !!resO;
  out.oPrNums = resO ? resO.prsOpened.join(",") : null;
  out.oAudit = !!(resO && resO.auditEvents.some(function (e) { return e.event === "pr_proof_null"; }));
  out.oNullCounted = !!(resO && resO.nullsByPhase && resO.nullsByPhase.deliver >= 1);
  out.oViolations = recO.violations.length;

  // Run R — the relay returns `{}`: the harness absent-key / defaultAgentReturn
  // shape, and a live shape for any relay that answers without a body. `rows`
  // must never be dereferenced unguarded.
  const rReturns = Object.assign({}, trivialReturns()); rReturns["verify-prs"] = {};
  const recR = await run(buildArgs(), { agentReturns: rReturns });
  const resR = resultOf(recR);
  out.rObservable = !!resR;
  out.rProofs = resR ? resR.results.map(function (r) { return r.prProof; }).join(",") : null;
  out.rPrNums = resR ? resR.prsOpened.join(",") : null;
  out.rViolations = recR.violations.length;

  // Run P — a batch where nothing claims a PR. No relay, no agent, and NO
  // verification noise: a clean non-PR batch must read exactly as it did before
  // this change existed.
  const pReturns = Object.assign({}, trivialReturns(), {
    "solve:#11 (trivial)": claimed(11, 0, { status: "COMMITTED_NOT_PUSHED" }),
    "solve:#12 (small)": claimed(12, 0, { status: "COMMITTED_NOT_PUSHED" }),
  });
  const recP = await run(buildArgs(), { agentReturns: pReturns });
  const resP = resultOf(recP);
  out.pNoRelay = probedNums(recP) === null;
  out.pProofs = resP ? resP.results.map(function (r) { return r.prProof; }).join(",") : null;
  out.pPrEvents = resP ? resP.auditEvents.filter(function (e) {
    return String(e.event).indexOf("pr_") === 0;
  }).length : null;

  // Run Q — THE FALSE-DOWNGRADE WALL. 403 is GitHub declining to answer (rate
  // limit, token scope), not evidence the PR is absent. Treating it as a 404
  // would silently strip a real PR from the run summary and from the /goal queue
  // the first time the fleet gets throttled.
  const qReturns = Object.assign({}, trivialReturns(),
    { "verify-prs": proof([proofRow(901, "fix/11-x", { httpStatus: 403, attempts: 3 }),
                           proofRow(902, "fix/12-x")]) });
  const recQ = await run(buildArgs(), { agentReturns: qReturns });
  const resQ = resultOf(recQ);
  const q11 = resQ ? resQ.results.filter(function (r) { return r.issue === 11; })[0] : null;
  out.qStatus = q11 ? q11.status : null;
  out.qPrNums = resQ ? resQ.prsOpened.join(",") : null;
  out.qAudit = !!(resQ && resQ.auditEvents.some(function (e) {
    return e.event === "pr_claim_unverifiable" && String(e.reason).indexOf("403") >= 0;
  }));

  // Run L — the 404. THE case the whole change exists for: a solver reported a
  // PR that is not there. `status` drives the counts and the PR set /goal
  // ingests, so the proof wins on that field — and the claim is preserved
  // beside it rather than erased, because the disagreement is the signal.
  const lReturns = Object.assign({}, trivialReturns(),
    { "verify-prs": proof([proofRow(901, "fix/11-x", { httpStatus: 404, attempts: 1 }),
                           proofRow(902, "fix/12-x")]) });
  const recL = await run(buildArgs(), { agentReturns: lReturns });
  const resL = resultOf(recL);
  const l11 = resL ? resL.results.filter(function (r) { return r.issue === 11; })[0] : null;
  out.lOpened = resL ? resL.counts.prOpened : null;
  out.lPrNums = resL ? resL.prsOpened.join(",") : null;
  out.lStatus = l11 ? l11.status : null;
  out.lClaimedStatus = l11 ? l11.claimedStatus : null;
  out.lClaimedPr = l11 ? l11.claimedPrNumber : null;
  out.lAudit = !!(resL && resL.auditEvents.some(function (e) { return e.event === "pr_claim_unproven"; }));
  out.lPushedNoPr = resL ? resL.counts.pushedNoPr : null;
  out.lDisproven = resL ? resL.verification.disproven : null;

  // Run M — the commit-count disagreement. commitCount drives NOTHING, so the
  // claim stays put and the proof lands beside it. Overwriting a field no
  // consumer reads would destroy the evidence of the disagreement and buy
  // nothing.
  const mReturns = Object.assign({}, trivialReturns(), {
    "solve:#11 (trivial)": claimed(11, 901, { commitCount: 7 }),
    "verify-prs": proof([proofRow(901, "fix/11-x", { commitCount: 2 }), proofRow(902, "fix/12-x")]),
  });
  const recM2 = await run(buildArgs(), { agentReturns: mReturns });
  const resM2 = resultOf(recM2);
  const m11 = resM2 ? resM2.results.filter(function (r) { return r.issue === 11; })[0] : null;
  out.mCommitClaim = m11 ? m11.commitCount : null;
  out.mCommitProven = m11 ? m11.provenCommitCount : null;
  out.mAudit = !!(resM2 && resM2.auditEvents.some(function (e) { return e.event === "commit_count_mismatch"; }));
  out.mStatus = m11 ? m11.status : null;
  out.mPrNums = resM2 ? resM2.prsOpened.join(",") : null;

  // Run N — the PR exists, but its head ref is somebody else. That is a claim
  // on another agent work, and it is disproof, not ambiguity.
  const nReturns = Object.assign({}, trivialReturns(),
    { "verify-prs": proof([proofRow(901, "fix/99-someone-else"), proofRow(902, "fix/12-x")]) });
  const recN = await run(buildArgs(), { agentReturns: nReturns });
  const resN = resultOf(recN);
  const n11 = resN ? resN.results.filter(function (r) { return r.issue === 11; })[0] : null;
  out.nStatus = n11 ? n11.status : null;
  const nEvent = resN ? resN.auditEvents.filter(function (e) { return e.event === "pr_branch_mismatch"; })[0] : null;
  out.nAudit = !!nEvent;
  out.nBothRefs = !!(nEvent && nEvent.claimedBranch === "fix/11-x"
    && nEvent.provenBranch === "fix/99-someone-else");

  // Run T — CB1 must count the proof relay. MUTATION-SENSITIVE by construction:
  // 2 trivial issues, no design tier, maxAgents 3. The old projection is
  // 1 + 2 + 0 = 3, which does NOT trip; the new one is 2 + 2 + 0 = 4, which
  // does. Run G (maxAgents 2, medium) trips under both and could never catch a
  // stale formula.
  const recT = await run(buildArgs(null, { maxAgents: 3 }), { agentReturns: trivialReturns() });
  const resT = resultOf(recT);
  out.tTripped = !!(resT && resT.cb1Tripped);
  out.tNoSolvers = !recT.agentCalls.some(function (c) { return /^solve:#/.test(c.label || ""); });
  out.tAudit = !!(resT && resT.auditEvents.some(function (e) { return e.event === "agent_ceiling_cb1"; }));

  // Run V — an unusable repoSlug. The slug is the only non-numeric value that
  // reaches the proof prompt, so it is shape-gated; a malformed one must SKIP
  // the relay rather than emit a broken `gh api` path for an agent to "fix"
  // (which is how a mechanical relay turns into an improvising one). Without
  // this run the gate could be deleted and nothing would red.
  const recV = await run(buildArgs(null, { repoSlug: "not a slug" }),
    { agentReturns: trivialReturns() });
  const resV = resultOf(recV);
  out.vNoRelay = probedNums(recV) === null;
  out.vProofs = resV ? resV.results.map(function (r) { return r.prProof; }).join(",") : null;
  out.vPrNums = resV ? resV.prsOpened.join(",") : null;
  out.vAudit = !!(resV && resV.auditEvents.some(function (e) {
    return e.event === "pr_proof_skipped" && e.reason === "no_repo_slug";
  }));

  // The verification block must be READ by something, or it is the dead
  // contract this repo has been filing issues about all week.
  out.aProbed = resA ? resA.verification.probed : null;
  out.aConfirmed = resA ? resA.verification.confirmed : null;
  out.aRelayRc = resA ? resA.verification.relayRc : null;

  process.stdout.write(JSON.stringify(out));
})().catch(function (e) {
  process.stdout.write(JSON.stringify({ FIXTURE_ERROR: (e && e.message) ? e.message : String(e), STACK: (e && e.stack) ? e.stack : "" }));
});
' "$HARNESS" "$WORKFLOW" 2>&1)"

check() {
  local key="$1" expected="$2" label="$3" got
  got="$(printf '%s' "$FIXTURE_OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write(JSON.stringify(o["'"$key"'"]));}catch(e){process.stdout.write("PARSE_ERROR:"+e.message);}})' 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (expected $expected, got $got)"
  fi
}

if grep -q FIXTURE_ERROR <<<"$FIXTURE_OUT"; then
  fail "B0 the behavioral fixture did not run: $FIXTURE_OUT"
else
  pass "B0 the behavioral fixture ran"

  check aViolations 0        "B1 trivial/small run: zero harness violations"
  check aPhases '"intake,deliver"' "B2 per-issue chains use opts.phase (no racing global phase() inside a wave)"
  check aResearch 0          "B3 no research agents for trivial/small"
  check aDesign 0            "B4 no design agents for trivial/small"
  check aImplement 2         "B5 one solver per issue"
  check aPrs 2               "B6 both PRs counted"
  check aPrNums '"901,902"'  "B7 PR numbers surface in prsOpened"
  check aDesigned 0          "B8 designedIssues=0 on the no-design path"
  check aIntakeHaiku true    "B10 the manifest relay runs on haiku"
  check aSolversInherit true "B11 solvers inherit the session model (never pinned)"

  check bResearch 3          "B12 medium tier runs 3 research lenses"
  check bDesign 3            "B13 medium tier runs spec + review + plan"
  check bImplement 2         "B14 still one solver per issue"
  check bDesigned 1          "B15 only the medium issue is counted as designed"
  check bResearchArtifacts 3 "B16 all three research artifacts accepted"
  check bPlanInPrompt true   "B17 the medium solver receives its plan path"
  check bTrivialNoPlan true  "B18 the trivial solver receives no plan"

  check cSpecCalls 1         "B19 REVISIONS_REQUIRED does NOT re-run the spec writer (bounded loop)"
  check cReviewCalls 1       "B20 the review runs exactly once"
  check cStillPlanned true   "B21 planning still proceeds with an advisory spec"
  check cAudit true          "B22 the non-APPROVE verdict is audited"

  check dObservable true     "B23 intake null still returns a structured result"
  check dNoSolvers true      "B24 intake null dispatches no solver"
  check dNullAudit true      "B25 intake_null audit event fires"

  check eSolved 2            "B26 manifest/envelope mismatch solves only the claimed set"
  check eNo99 true           "B27 an unclaimed manifest issue is never dispatched"
  check eMismatchAudit true  "B28 the mismatch is audited, not silent"

  check fFailed 1            "B29 a null solver becomes exactly one FAILED record"
  check fOpened 1            "B30 the sibling issue still lands its PR"
  check fFailedIssue 11      "B31 the FAILED record is attributed to the right issue"
  check fNullAudit true      "B32 solver_null audit event fires"

  check gTripped true        "B33 CB1 trips when the projection exceeds maxAgents"
  check gNoSolvers true      "B34 CB1 aborts BEFORE any solver is dispatched"
  check gAudit true          "B35 agent_ceiling_cb1 audit event fires"

  check hIssues 2            "B36 concurrency=1 still solves every issue"
  check hConcurrency 1       "B37 the wave size is reported"
  check hSolverOrder '"solve:#11 (trivial),solve:#12 (small)"' "B38 waves run in manifest order"

  check iObservable true     "B39 a null research lens does not abort the run"
  check iArtifacts 2         "B40 the surviving lenses' artifacts are still used"
  check iStillSolved 2       "B41 the issue is still solved without one lens"
  check iNullCounted true    "B42 the null lens is counted in nullsByPhase"

  check jDesigned 0          "B43 an out-of-run-dir plan path is rejected"
  check jNoLeak true         "B44 the rejected path never reaches the solver prompt"

  check kBaseInPrompt true      "B45 a known base branch reaches the solver as --base \"<branch>\" (#439)"
  check kNoBaseWhenUnknown true "B46 an unknown base emits NO --base flag (detached HEAD safety)"

  # --- #515: claim verification ---------------------------------------------
  check sStatus '"PUSHED_NO_PR"'  "B47 an incoherent PR_OPENED/prNumber:0 claim is downgraded"
  check sClaimedStatus '"PR_OPENED"' "B48 the original claim is preserved beside the correction, never erased"
  check sAudit true               "B49 pr_claim_incoherent audit event fires (the disagreement is the signal)"
  check sOpened 1                 "B50a counts.prOpened drops the self-contradicting record"
  check sPrNums '"902"'           "B50b prsOpened agrees with counts.prOpened (they disagreed on main)"
  check sProbed '"902"'           "B51 no agent is spent probing PR id 0 — incoherence is settled script-side"

  check oObservable true          "B52 a null proof relay still returns a structured result"
  check oPrNums '"901,902"'       "B53 a null relay downgrades NOTHING — every claim is retained"
  check oAudit true               "B54 pr_proof_null audit event fires"
  check oNullCounted true         "B55 the null relay is counted in nullsByPhase.deliver"
  check oViolations 0             "B56 zero harness violations on the null-relay path"

  check rObservable true          "B57 a bodyless {} proof return does not throw (rows is never dereferenced unguarded)"
  check rProofs '"UNVERIFIED,UNVERIFIED"' "B58 a bodyless return classifies UNVERIFIED, claims retained"
  check rPrNums '"901,902"'       "B58b the retained claims still surface in prsOpened"
  check rViolations 0             "B59 zero harness violations on the bodyless-return path"

  check pNoRelay true             "B60 a batch with no PR claim dispatches NO proof relay at all"
  check pProofs '"NOT_APPLICABLE,NOT_APPLICABLE"' "B61 non-PR records are classified NOT_APPLICABLE"
  check pPrEvents 0               "B62 a clean non-PR batch emits zero verification noise"

  check qStatus '"PR_OPENED"'     "B63 a 403 does NOT disprove a PR (false-downgrade wall)"
  check qPrNums '"901,902"'       "B64 the throttled claim stays in prsOpened and in /goal's queue"
  check qAudit true               "B65 pr_claim_unverifiable fires with a reason naming the 403"

  check lOpened 1                 "B66 a 404 removes the phantom PR from counts.prOpened"
  check lPrNums '"902"'           "B67 the phantom number never reaches prsOpened (and so never reaches /goal)"
  check lStatus '"PUSHED_NO_PR"'  "B68 the proof wins on status — the field that drives behaviour"
  check lClaimedStatus '"PR_OPENED"' "B69a the claim is preserved, never erased"
  check lClaimedPr 901            "B69b the claimed PR number is preserved beside the correction"
  check lAudit true               "B70 pr_claim_unproven audit event fires"
  check lPushedNoPr 1             "B71 the downgraded record lands in counts.pushedNoPr"
  check lDisproven 1              "B71b verification.disproven reports it"

  check mCommitClaim 7            "B72 a commitCount disagreement leaves the CLAIM intact (it drives nothing)"
  check mCommitProven 2           "B73 the proof lands beside it in provenCommitCount"
  check mAudit true               "B74 commit_count_mismatch is audited, not silently corrected"
  check mStatus '"PR_OPENED"'     "B75a a commit-count disagreement never downgrades a proven PR"
  check mPrNums '"901,902"'       "B75b both PRs stay in prsOpened"

  check nStatus '"PUSHED_NO_PR"'  "B76 a 200 naming a different head ref DISPROVES the claim"
  check nAudit true               "B77 pr_branch_mismatch audit event fires"
  check nBothRefs true            "B78 the event carries both refs as named fields (never concatenated)"

  check tTripped true             "B79 CB1 counts the proof relay (2 trivial issues at maxAgents=3 now trips)"
  check tNoSolvers true           "B80 the raised projection still aborts BEFORE any solver is dispatched"
  check tAudit true               "B81 agent_ceiling_cb1 fires on the new projection"

  check vNoRelay true             "B85 a malformed repoSlug skips the relay (no broken gh api path is ever emitted)"
  check vProofs '"UNVERIFIED,UNVERIFIED"' "B86 a skipped probe classifies UNVERIFIED, never DISPROVEN"
  check vPrNums '"901,902"'       "B87 and the claims are retained in prsOpened"
  check vAudit true               "B88 pr_proof_skipped fires with reason no_repo_slug"

  check aProbed 2                 "B82 verification.probed reports what was actually sent to the relay"
  check aConfirmed 2              "B83 verification.confirmed is computed from the record classifications"
  check aRelayRc 0                "B84 verification.relayRc surfaces the relay rc"
fi

echo "== S: /goal runs ON the workflow backend — the interim demotion is GONE (RFC 0015 §5) =="
# S16-S20 used to pin the INTERIM `uberdev_dispatch_demote_workflow_to_detached`
# shim: /goal drove uberdev_dispatch_one itself, could not serve the `workflow`
# backend, and so demoted a workflow resolution back onto the retired per-OS
# detached matrix. That shim was the last thing keeping the since-deleted detached
# backend reachable from `auto` on a default path.
#
# /goal is now Workflow-native (lib/goal-phase1.sh claims only;
# skills/goal-pipeline/workflow.js makes ONE nested workflow() call per cycle
# into skills/solve-fleet/workflow.js), so these assertions are INVERTED rather
# than deleted: the helper must NOT exist, no surface may call it, and the
# goal-pipeline must mandate the Workflow call instead.
GOAL_SKILL="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"
GOAL_WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js"
GOAL_PHASE1="$REPO_ROOT/plugins/uberdev/lib/goal-phase1.sh"
for f in "$GOAL_SKILL" "$GOAL_WORKFLOW" "$GOAL_PHASE1"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

grep -q 'uberdev_dispatch_demote_workflow_to_detached()' "$DISPATCH" \
  && fail "S16 the demotion helper still exists in lib/dispatch.sh — auto can still reach a deprecated detached backend" \
  || pass "S16 the workflow->detached demotion helper is deleted from lib/dispatch.sh"

# A dormant helper is as bad as a live one, so assert nothing CALLS it either.
# Only *.sh can hold a call site, and a `#`-comment naming the retired helper is
# documentation, not a call — the point of that comment is to stop the per-OS
# matrix drifting back, so the guard must not punish it.
live_calls_in_sh() {  # $1=root  $2=symbol -> prints "file:line:text" per live hit
  local root="$1" sym="$2" f hits
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hits="$(grep -nE "(^|[^A-Za-z0-9_])$sym" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    [ -n "$hits" ] && printf '%s:%s\n' "$f" "$hits"
  done < <(find "$root" -type f -name '*.sh' 2>/dev/null | sort)
}

# One shipped runtime since issue #381 retired codex/uberdev-codex; the loop
# that also scanned that mirror went with it, not the scan itself.
DEMOTE_CALLERS=""
for _demote_root in "$REPO_ROOT/plugins/uberdev"; do
  [ -d "$_demote_root" ] || continue
  DEMOTE_CALLERS="$DEMOTE_CALLERS$(live_calls_in_sh "$_demote_root" 'uberdev_dispatch_demote_workflow_to_detached')"
done
if [ -n "$DEMOTE_CALLERS" ]; then
  fail "S17 a live call site for the retired demotion helper survives: $DEMOTE_CALLERS"
else
  pass "S17 no live call site for the retired demotion helper under plugins/uberdev"
fi

grep -q 'Workflow({scriptPath: "\$CLAUDE_PLUGIN_ROOT/skills/goal-pipeline/workflow.js"}' "$GOAL_SKILL" \
  && pass "S18 goal-pipeline mandates the Workflow call instead of dispatching detached children" \
  || fail "S18 goal-pipeline has no Workflow mandate — /goal would have no driver at all"

# The claim pass must NOT dispatch. If uberdev_dispatch_one reappears there the
# demotion problem comes straight back with it. Comment lines are excluded for
# the same reason as S17 — the file's header explains what it stopped doing.
PHASE1_DISPATCH="$(grep -nE '(^|[^A-Za-z0-9_])uberdev_dispatch_one' "$GOAL_PHASE1" \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -n "$PHASE1_DISPATCH" ]; then
  fail "S19 lib/goal-phase1.sh calls uberdev_dispatch_one again — it is claim-only by contract: $PHASE1_DISPATCH"
else
  pass "S19 lib/goal-phase1.sh is claim-only (no live uberdev_dispatch_one call)"
fi

# EXACTLY ONE nested workflow() call site, and it must target the fleet script.
# A per-issue nested call would spend the single nesting level on the wrong
# thing and the fleet's own agents could not run.
GOAL_NEST_COUNT="$(grep -cE '(^|[^A-Za-z0-9_])workflow\(\{' "$GOAL_WORKFLOW" || true)"
if [ "$GOAL_NEST_COUNT" = "1" ] && grep -q 'skills/solve-fleet/workflow.js' "$GOAL_WORKFLOW"; then
  pass "S20 the goal driver makes exactly one nested workflow() call, into skills/solve-fleet/workflow.js"
else
  fail "S20 expected exactly 1 nested workflow({ call into solve-fleet, found $GOAL_NEST_COUNT"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
