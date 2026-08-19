#!/usr/bin/env bash
# tests/goal-workflow.test.sh — RFC 0015 §5: /goal as a Workflow-native driver.
#
# The convergence loop used to be five ```bash fences that the orchestrating
# model was TRUSTED to re-run in order. Nothing tested the loop itself, because
# there was no loop — only an instruction. This fixture tests the loop that
# replaced it.
#
# Three surfaces:
#   G — shape greps over skills/goal-pipeline/workflow.js, its SKILL.md seam,
#       and the four lib/goal-*.sh phase scripts it drives.
#   N — the NESTING budget: exactly one nested workflow() per cycle, into the
#       solve-fleet, and zero nested sites inside the fleet script itself.
#   B — T3 BEHAVIORAL fixtures driving the driver under the harness stubs with
#       canned relay returns, asserting the cycle semantics no grep can see:
#       convergence, loop-back with surviving candidates, the max-cycles
#       backstop, fingerprint repeats, the 42/42/0 watch drain, the tick
#       breaker, a rollover blocking convergence, a refused fleet envelope, a
#       budget throw still routing through finalize, and the per-cycle agent
#       SPEND ledger CB1 compares its ceiling against — including the arm that
#       charges for a nested fleet that threw.
#
# GIT-BASH PORTABLE: grep + node only (no python3/PyYAML). Runs on BOTH the
# ubuntu and windows shape-check jobs.
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js"
FLEET="$REPO_ROOT/plugins/uberdev/skills/solve-fleet/workflow.js"
SKILL="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"
GOAL_CMD="$REPO_ROOT/plugins/uberdev/commands/goal.md"
P0="$REPO_ROOT/plugins/uberdev/lib/goal-phase0.sh"
P1="$REPO_ROOT/plugins/uberdev/lib/goal-phase1.sh"
WATCH="$REPO_ROOT/plugins/uberdev/lib/goal-watch.sh"
P3="$REPO_ROOT/plugins/uberdev/lib/goal-phase3.sh"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"

for f in "$WORKFLOW" "$FLEET" "$SKILL" "$GOAL_CMD" "$P0" "$P1" "$WATCH" "$P3" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the goal-driver behavioral fixture (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## goal-workflow (RFC 0015 §5) — driver shape + nesting budget + T3 behavioral fixtures"

# ---------------------------------------------------------------------------
# G — shape
# ---------------------------------------------------------------------------
echo "== G: driver + phase-script shape =="

META_JSON="$(node "$HARNESS" meta "$WORKFLOW" 2>/dev/null)"
if [ -n "$META_JSON" ] && printf '%s' "$META_JSON" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit((m.name==="goal-pipeline" && Array.isArray(m.phases) && m.phases.join(",")==="dispatch,watch,collect,finalize")?0:1);})'; then
  pass "G1 meta literal parses: name=goal-pipeline, phases=[dispatch,watch,collect,finalize]"
else
  fail "G1 meta literal wrong; got: $META_JSON"
fi

# G2 — NO TIMERS, NO PAUSES. The runtime does not expose setTimeout/setInterval
# and a script-level pause is forbidden (RFC 0012 §2.2 constraint 3). The
# polling this pipeline genuinely needs lives in lib/goal-watch.sh, which is an
# ordinary shell script; the driver bounds it with a COUNTER. A timer literal
# here means someone tried to move the poll loop into the script.
if grep -nE 'setTimeout|setInterval|setImmediate|[^A-Za-z_]sleep[^A-Za-z_]|\bsleep\(' "$WORKFLOW" >/dev/null 2>&1; then
  fail "G2 the driver contains a timer/pause token — the watch loop belongs in lib/goal-watch.sh, and the driver's bound is a counter"
  grep -nE 'setTimeout|setInterval|setImmediate|[^A-Za-z_]sleep[^A-Za-z_]|\bsleep\(' "$WORKFLOW" | sed -n '1,5s/^/        /p'
else
  pass "G2 no setTimeout/setInterval/sleep anywhere in the driver"
fi
# Positive control: the token the guard looks for really does exist in the file
# that legitimately polls, so G2 is a discriminating grep and not a tautology.
grep -q 'sleep "\$_UBERDEV_GOAL_POLL_SECS"' "$WATCH" \
  && pass "G2b control: the poll pause lives in lib/goal-watch.sh (so G2's grep is discriminating, not vacuous)" \
  || fail "G2b control: lib/goal-watch.sh no longer contains the poll sleep — G2 may now be vacuous"

# G3 — model policy: every relay here is MECHANICAL (run a script, report its
# exit status), so haiku is correct for all of them; no judgment agent may be
# pinned to a flagship-substitute model.
grep -q 'model: "haiku"' "$WORKFLOW" \
  && pass "G3a the mechanical relays pin haiku" \
  || fail "G3a no haiku pin on the mechanical relays"
if grep -qE 'model:[[:space:]]*"(fable|sonnet|opus)"' "$WORKFLOW"; then
  fail "G3b an agent is pinned to a named flagship — relays are mechanical, judgment work belongs to the fleet"
else
  pass "G3b no flagship model pin"
fi

# G4 — no worktree isolation in the driver: it dispatches no implementer. The
# solvers are the fleet's, and only the fleet isolates them.
grep -q 'isolation: "worktree"' "$WORKFLOW" \
  && fail "G4 the goal driver isolates an agent into a worktree — it has no implementer to isolate; that is the fleet's job" \
  || pass "G4 the driver isolates nothing (no implementer of its own)"

# G5 — trust verdicts are NEVER an LLM judgement.
grep -q 'uberdev_goal_read_trust_signal' "$WORKFLOW" \
  && pass "G5a the verdict relay calls the shell trust-signal helper" \
  || fail "G5a no uberdev_goal_read_trust_signal call in the verdict relay"
grep -q 'uberdev_goal_locate_review_pr_audit_by_pr' "$WORKFLOW" \
  && pass "G5b the verdict PATH comes from the canonical locator, not from the agent" \
  || fail "G5b the verdict relay does not use the canonical locator"
grep -qi 'do not form an opinion about any PR' "$WORKFLOW" \
  && pass "G5c the verdict relay is explicitly forbidden from forming its own opinion" \
  || fail "G5c the verdict relay is not told to relay rather than judge"

# G6 — the exit contracts the driver depends on must be stated in the scripts
# that implement them, or the driver's rc branching is folklore.
grep -q 'exit 42' "$WATCH" \
  && pass "G6a lib/goal-watch.sh implements the 42 re-invoke code" \
  || fail "G6a lib/goal-watch.sh has no exit 42 arm"
grep -q 'exit 42' "$P3" \
  && pass "G6b lib/goal-phase3.sh implements the 42 loop-back code" \
  || fail "G6b lib/goal-phase3.sh has no exit 42 arm"
# Explicit `if` rather than `A || B && pass || fail`: that chain binds
# left-to-right in POSIX shell, so a failing A followed by a passing B would
# still evaluate `pass || fail` and could report either. The emitter helper is
# what actually writes the WORKFLOW_ARGS_BEGIN/END markers, so assert the call.
if grep -q 'uberdev_emit_workflow_args goal' "$P0"; then
  pass "G6c lib/goal-phase0.sh emits the goal args envelope"
else
  fail "G6c lib/goal-phase0.sh does not emit an args envelope"
fi

# G6d/G6e — the CHILD TRANSPORT seam. The solvers are Workflow agents, but the
# `/merge` + `/review-pr` children are dispatched by the watch loop itself, and
# lib/dispatch.sh has no provider arm for `workflow` by construction. Without an
# explicit child transport those two dispatches fail on every poll and /goal
# silently rides its breakers instead of merging anything.
if grep -q 'UBERDEV_GOAL_CHILD_BACKEND' "$WATCH"; then
  pass "G6d lib/goal-watch.sh resolves an explicit transport for its own /merge + /review-pr children"
else
  fail "G6d lib/goal-watch.sh has no child transport — with backend=workflow every /merge and /review-pr dispatch would hit the loud refusal in lib/dispatch.sh"
fi
# ...and it must not be the retired whole-run demotion in disguise. A comment
# saying so proves nothing: uberdev_dispatch_preflight EXPORTS
# UBERDEV_RESOLVED_BACKEND process-globally, and uberdev_goal_agent_busy_for_issue
# branches on that SAME variable — so an unscoped pin silently re-routes the
# SOLVER liveness probe onto the PID-file arm for Workflow agents that never
# write a PID file. What makes the pin genuinely scoped is that the run-level
# backend is SAVED before it and the liveness probe reads the saved value.
# (tests/goal.test.sh G51 runs the wrapper and asserts both halves behaviorally.)
if grep -q 'UBERDEV_GOAL_SOLVER_BACKEND="\${UBERDEV_GOAL_SOLVER_BACKEND:-\${UBERDEV_RESOLVED_BACKEND:-}}"' "$WATCH" \
   && grep -q '_uberdev_goal_watch_solver_busy "\$issue"' "$WATCH"; then
  pass "G6e the child-transport pin is scoped: the run-level solver backend is saved and the liveness probe reads it"
else
  fail "G6e the child-transport pin is process-global — it re-routes the solver liveness probe (save UBERDEV_GOAL_SOLVER_BACKEND and probe via _uberdev_goal_watch_solver_busy)"
fi
# The saved value must be captured BEFORE the pin, or it captures the pin itself.
G6E_SAVE="$(grep -n 'UBERDEV_GOAL_SOLVER_BACKEND="\${UBERDEV_GOAL_SOLVER_BACKEND:-' "$WATCH" | head -1 | cut -d: -f1)"
G6E_PIN="$(grep -n 'UBERDEV_DISPATCH_BACKEND_REQUESTED="\${UBERDEV_GOAL_CHILD_BACKEND:-' "$WATCH" | head -1 | cut -d: -f1)"
if [ -n "$G6E_SAVE" ] && [ -n "$G6E_PIN" ] && [ "$G6E_SAVE" -lt "$G6E_PIN" ]; then
  pass "G6e2 the solver backend is captured before the child transport overwrites it"
else
  fail "G6e2 solver-backend capture (line ${G6E_SAVE:-none}) must precede the child-transport pin (line ${G6E_PIN:-none})"
fi
# G6f — the settled-fleet short-circuit: the 150m detached-solver timeout is
# meaningless once the awaited fleet call has returned.
grep -q 'UBERDEV_GOAL_SOLVERS_SETTLED' "$WATCH" \
  && pass "G6f lib/goal-watch.sh honours the settled-fleet marker" \
  || fail "G6f lib/goal-watch.sh still waits out the 150m detached-solver timeout after an awaited fleet call"

# G7 — SKILL.md seam (RFC 0012 §4.1/§4.2 — the generic carrier also checks
# these, but a /goal-specific failure message is worth the duplication).
grep -q 'skills/goal-pipeline/workflow.js' "$SKILL" \
  && pass "G7a SKILL.md names its workflow script" || fail "G7a SKILL.md does not name workflow.js"
grep -q '## No-Workflow fallback' "$SKILL" \
  && pass "G7b SKILL.md carries the No-Workflow fallback section" || fail "G7b no fallback section"
grep -q 'WORKFLOW_ARGS_BEGIN' "$SKILL" \
  && pass "G7c SKILL.md names the args markers (verbatim relay, DR-2)" || fail "G7c no args markers"
grep -q '"Workflow"' "$GOAL_CMD" \
  && pass "G7d commands/goal.md allows the Workflow tool" || fail "G7d commands/goal.md does not list Workflow in allowed-tools"

# G8 (#592) — the partial-chain carrier, JOINED to the two scripts that parse
# it. The driver is the only party that sees the fleet's per-issue
# `chainComplete` AND composes the phase-script command lines, and RFC 0012
# §2.2 constraint 6 forbids it a filesystem, so argv is the whole channel. A
# flag spelled here and nowhere else is not a carrier — it is an `unknown
# argument` exit 2 on the first partial cycle — so each half is asserted
# against the script that consumes it rather than on its own.
if grep -q -- '--partial-prs=' "$WORKFLOW" && grep -q -- '--partial-prs=\*)' "$WATCH"; then
  pass "G8a the watch relay's command line carries --partial-prs and lib/goal-watch.sh parses that exact flag"
else
  fail "G8a the --partial-prs carrier is spelled on only one side (driver and lib/goal-watch.sh must agree)"
fi
if grep -q -- '--partial-issues=' "$WORKFLOW" && grep -q -- '--partial-issues=\*)' "$P3"; then
  pass "G8b the collect relay's command line carries --partial-issues and lib/goal-phase3.sh parses that exact flag"
else
  fail "G8b the --partial-issues carrier is spelled on only one side (driver and lib/goal-phase3.sh must agree)"
fi

# G8c/G8d — the audit-row FIELD NAME the collect relay is told to read.
# `uberdev_goal_audit` frames every row as {"ts","event","payload"}; a relay
# sent to `.data.reason` finds nothing, reports "", and the driver's
# `rec.reason || col.decision` fallback then publishes the degraded literal
# "halt" as the halt reason of every Phase-3 breaker. The writer's own framing
# is asserted too, so this row cannot go vacuous if the payload key is renamed.
if grep -q '\.payload\.reason' "$WORKFLOW" && grep -q '\.payload\.phase' "$WORKFLOW"; then
  pass "G8c the collect relay reads .payload.reason and .payload.phase off the breaker row"
else
  fail "G8c the collect relay does not name both .payload.reason and .payload.phase"
fi
if grep -q '\.data\.reason' "$WORKFLOW"; then
  fail "G8d the collect relay still points at .data.reason — uberdev_goal_audit writes no such key, so every Phase-3 halt reports the degraded literal 'halt'"
else
  pass "G8d no .data.* read survives in the driver"
fi
# G8f — a schema property the relay is never TOLD to return is a property that
# arrives undefined on every call, and the halt would then report its reason
# with no phase beside it. The instruction list and S.collect must agree.
grep -qE 'Return via StructuredOutput:[^"]*phase' "$WORKFLOW" \
  && pass "G8f the collect relay's StructuredOutput list names phase" \
  || fail "G8f S.collect declares phase but the relay is never told to return it"
grep -q '"payload":%s' "$REPO_ROOT/plugins/uberdev/lib/goal-state.sh" \
  && pass "G8e control: uberdev_goal_audit really does frame the row under \"payload\" (so G8c/G8d are discriminating)" \
  || fail "G8e control: the audit framing no longer writes a \"payload\" key — G8c/G8d now assert against the wrong field name"

# ---------------------------------------------------------------------------
# N — the nesting budget
# ---------------------------------------------------------------------------
echo "== N: the one-level nesting budget =="

N_DRIVER="$(grep -cE '(^|[^A-Za-z0-9_])workflow\(\{' "$WORKFLOW" || true)"
if [ "$N_DRIVER" = "1" ]; then
  pass "N1 the driver has exactly ONE nested workflow() call site (count=$N_DRIVER)"
else
  fail "N1 expected exactly 1 nested workflow() site in the driver, found $N_DRIVER — a per-issue nested call spends the single nesting level on the wrong thing and the fleet's own agents cannot run"
fi
grep -q 'skills/solve-fleet/workflow.js' "$WORKFLOW" \
  && pass "N2 the nested call targets skills/solve-fleet/workflow.js" \
  || fail "N2 the nested call does not target the solve-fleet script"

N_FLEET="$(grep -cE '(^|[^A-Za-z0-9_])workflow\(' "$FLEET" || true)"
if [ "$N_FLEET" = "0" ]; then
  pass "N3 the fleet script itself contains ZERO workflow( sites (a nested call inside the child throws at runtime)"
else
  fail "N3 the fleet script contains $N_FLEET workflow( site(s) — the nesting budget is already spent by the goal driver"
fi

# N4 — there must be no per-issue child script. `solve-one.js` (or any sibling
# under skills/goal-pipeline/) would be the shape this design explicitly rejects.
if [ -n "$(find "$REPO_ROOT/plugins/uberdev/skills" -type f -name 'solve-one*.js' 2>/dev/null)" ]; then
  fail "N4 a solve-one child script exists — the fleet already fans out per issue; a per-issue child spends the nesting level"
else
  pass "N4 no per-issue child script exists"
fi

# ---------------------------------------------------------------------------
# B — T3 behavioral fixtures
# ---------------------------------------------------------------------------
echo "== B: T3 behavioral fixtures (harness stubs) =="

# The fixture script is written to a FILE rather than passed with `node -e`.
# It is ~40 KB, and Windows caps a command line at 32767 bytes, so the -e form
# died inside the command substitution on the only Windows job and the failure
# surfaced as PARSE_ERROR on B1/B2 — the captured stderr was a bash error, not
# the JSON the rows expected. This file never reached that job before: the &&
# chain aborted at an earlier fixture, so the breakage sat latent.
#
# `process.argv.splice(1, 1)` drops the script path so the argv indices below
# keep their `node -e` meaning (argv[1] = harness) rather than shifting by one.
FIXTURE_JS="$(mktemp)"
trap 'rm -f "$FIXTURE_JS"' EXIT
{
  printf 'process.argv.splice(1, 1);\n'
  cat <<'UBERDEV_FIXTURE_JS_EOF'

const h = require(process.argv[1]);
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8");
const meta = h.extractMeta(src).meta;

const FLEET_PATH = "/p/skills/solve-fleet/workflow.js";

function buildArgs(cfgExtra) {
  const cfg = Object.assign({
    pluginRootAbs: "/p", repoRootAbs: "/r", tmpDirAbs: "/t",
    goalId: "1700000000-abcd1234", issues: "11,12",
    maxCycles: 5, maxParallel: 3, maxAgents: 250, maxWatchTicks: 40,
    barrierTimeoutS: 14400, reviewGraceSecs: 3600,
    watchPasses: 0, watchBudgetS: 0, onlyMine: false, resumed: false,
    backend: "workflow", timestampIso: "2026-01-01T00:00:00Z",
  }, cfgExtra || {});
  return { v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z", now_epoch: 1767225600,
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "goal", config: cfg };
}

// The optional second parameter merges extra keys into the envelope CONFIG. The
// driver reads that config back out (implementBudget, #564), so a run has to be
// able to relay a budget the operator raised — the envelope is the only channel
// carrying it. Defaulted, so every call site passing an issue list alone still
// produces byte-identical JSON.
function fleetEnvelope(issues, cfgExtra) {
  return JSON.stringify({ v: 1, run_id: "RID", now_epoch: 1767225600,
    now_iso: "2026-01-01T00:00:00Z", plugin_root: "/p", repo_root: "/r", cwd: "/r",
    pipeline: "solve-fleet",
    config: Object.assign({ runId: "RID", issues: (issues === undefined ? "11,12" : issues),
      concurrency: 6 }, cfgExtra || {}) });
}
// A healthy claim relay returns an envelope whose issue set IS the claimed set —
// that is the invariant `--force` arming depends on, so the default fixture
// derives the envelope from `dispatch` and a test that wants a mismatch has to
// pass fleetArgsJson explicitly.
function claim(o) {
  const base = { rc: 0, dispatch: "11,12", rollover: "", skipped: "",
    launcherRc: 0, armed: "11,12", markRc: 0, note: "" };
  const merged = Object.assign(base, o || {});
  if (!("fleetArgsJson" in merged)) merged.fleetArgsJson = fleetEnvelope(merged.dispatch);
  return merged;
}
function collect(o) {
  return Object.assign({ rc: 0, decision: "converged", candidates: 0, queued: 0,
    queue: "", fingerprints: "", reason: "", phase: "", note: "" }, o || {});
}
const VERDICTS = { rows: [{ pr: 901, signal: "green" }, { pr: 902, signal: "yellow" }] };

function run(args, fixture) {
  const pre = h.preprocess(src);
  const record = h.makeRecord();
  const sb = h.makeSandbox(Object.assign({ args }, fixture), meta, record).sandbox;
  const pending = vm.runInNewContext(pre.wrapped, sb, { filename: "goal-pipeline", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function resultOf(record) {
  const line = record.logs.find(function (l) { return l.indexOf("WORKFLOW_RESULT ") === 0; });
  return line ? JSON.parse(line.slice("WORKFLOW_RESULT ".length)) : null;
}
function labels(record) { return record.agentCalls.map(function (c) { return c.label; }); }

(async function () {
  const out = {};

  // Run A — converge on cycle 1.
  const recA = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resA = resultOf(recA);
  out.aViolations = recA.violations.length;
  out.aConverged = resA ? resA.converged : null;
  out.aHalted = resA ? resA.halted : null;
  out.aCycles = resA ? resA.cyclesRun : null;
  out.aNested = recA.workflowCalls.length;
  out.aNestedPath = recA.workflowCalls.length ? recA.workflowCalls[0].ref.scriptPath : null;
  out.aNestedPipeline = recA.workflowCalls.length ? recA.workflowCalls[0].args.pipeline : null;
  out.aPhases = recA.phases.join(",");
  out.aVerdicts = resA ? resA.verdicts.length : null;
  out.aRelaysHaiku = recA.agentCalls.every(function (c) { return c.model === "haiku"; });

  // Run B — the watch drain: 42, 42, then 0. Three relays, one nested call.
  const recB = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 42, note: "bound" },
    "goal-watch:c1:t2": { rc: 42, note: "bound" },
    "goal-watch:c1:t3": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resB = resultOf(recB);
  out.bTicks = resB ? resB.cycles[0].watchTicks : null;
  out.bConverged = resB ? resB.converged : null;
  out.bNested = recB.workflowCalls.length;
  out.bWatchLabels = labels(recB).filter(function (l) { return /^goal-watch/.test(l || ""); }).join(",");

  // Run C — the tick breaker: the watch never drains within the bound.
  const recC = await run(buildArgs({ maxWatchTicks: 2 }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 42, note: "bound" },
    "goal-watch:c1:t2": { rc: 42, note: "bound" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resC = resultOf(recC);
  out.cTripped = resC ? resC.cbWatchTicks : null;
  out.cReason = resC ? resC.haltReason : null;
  out.cNoCollect = !labels(recC).some(function (l) { return /^goal-collect/.test(l || ""); });
  out.cObservable = !!resC;

  // Run D — a watch breaker (rc 1) halts the run.
  const recD = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 1, note: "merge_failed" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resD = resultOf(recD);
  out.dHalted = resD ? resD.halted : null;
  out.dReason = resD ? resD.haltReason : null;
  out.dNoCollect = !labels(recD).some(function (l) { return /^goal-collect/.test(l || ""); });

  // Run E — loop-back: candidates survive cycle 1 into cycle 2, then converge.
  const recE = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 2, queued: 2, queue: "31,32",
      fingerprints: "aabbccdd11223344" }),
    "goal-claim:c2": claim({ dispatch: "31,32", armed: "31,32" }),
    "goal-watch:c2:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c2": VERDICTS,
    "goal-collect:c2": collect({ candidates: 0 }),
  } });
  const resE = resultOf(recE);
  out.eCycles = resE ? resE.cyclesRun : null;
  out.eC1Candidates = resE ? resE.cycles[0].candidates : null;
  out.eConverged = resE ? resE.converged : null;
  out.eNested = recE.workflowCalls.length;
  out.eC2Claimed = resE ? resE.cycles[1].claimed.join(",") : null;

  // Run F — a repeated fingerprint across cycles is recorded, and the shell
  // gate that HALTS on it is honoured verbatim.
  const recF = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 1, queued: 1, queue: "41",
      fingerprints: "deadbeefcafe0011" }),
    "goal-claim:c2": claim(),
    "goal-watch:c2:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c2": VERDICTS,
    "goal-collect:c2": collect({ rc: 1, decision: "halt", candidates: 1, queued: 1,
      fingerprints: "deadbeefcafe0011", reason: "nonconvergence" }),
  } });
  const resF = resultOf(recF);
  out.fRepeated = resF ? resF.repeatedFingerprints.join(",") : null;
  out.fHalted = resF ? resF.halted : null;
  out.fReason = resF ? resF.haltReason : null;

  // Run G — max-cycles: the driver backstop fires when the shell keeps saying
  // "loop" past the ceiling.
  const recG = await run(buildArgs({ maxCycles: 1 }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 3, queued: 3, queue: "51,52,53" }),
  } });
  const resG = resultOf(recG);
  out.gReason = resG ? resG.haltReason : null;
  out.gCycles = resG ? resG.cyclesRun : null;
  out.gNoSecondClaim = !labels(recG).some(function (l) { return l === "goal-claim:c2"; });

  // Run H — a non-empty ROLLOVER is carried, and the claimed set is what the
  // claim pass returned (never the full queue).
  const recH = await run(buildArgs({ issues: "11,12,13,14", maxParallel: 2 }), { agentReturns: {
    "goal-claim:c1": claim({ dispatch: "11,12", rollover: "13,14", armed: "11,12" }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 0, queued: 2, queue: "13,14" }),
    "goal-claim:c2": claim({ dispatch: "13,14", rollover: "", armed: "13,14" }),
    "goal-watch:c2:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c2": VERDICTS,
    "goal-collect:c2": collect(),
  } });
  const resH = resultOf(recH);
  out.hC1Claimed = resH ? resH.cycles[0].claimed.join(",") : null;
  out.hC1Rollover = resH ? resH.cycles[0].rollover.join(",") : null;
  out.hC2Claimed = resH ? resH.cycles[1].claimed.join(",") : null;
  out.hConverged = resH ? resH.converged : null;
  out.hQueueLeft = resH ? resH.queueRemaining.join(",") : null;

  // Run I — a NULL claim relay halts rather than watching a cycle whose claim
  // state is unknown.
  const recI = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": null,
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
  } });
  const resI = resultOf(recI);
  out.iObservable = !!resI;
  out.iReason = resI ? resI.haltReason : null;
  out.iNoNested = recI.workflowCalls.length === 0;
  out.iNoWatch = !labels(recI).some(function (l) { return /^goal-watch/.test(l || ""); });

  // Run J — a REFUSED fleet envelope: no nested call, the run still watches
  // (so already-pushed work is driven) and stays observable.
  const recJ = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ fleetArgsJson: "", launcherRc: 2, armed: "" }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resJ = resultOf(recJ);
  out.jNested = recJ.workflowCalls.length;
  out.jFleet = resJ ? resJ.cycles[0].fleet : null;
  out.jAudit = !!(resJ && resJ.auditEvents.some(function (e) { return e.event === "fleet_args_refused"; }));
  out.jStillWatched = labels(recJ).some(function (l) { return /^goal-watch/.test(l || ""); });

  // Run K — an envelope whose pipeline identity is WRONG is refused, not
  // repaired: the driver must never hand an arbitrary object to workflow().
  const recK = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ fleetArgsJson: JSON.stringify({ pipeline: "not-the-fleet", config: {} }) }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resK = resultOf(recK);
  out.kNested = recK.workflowCalls.length;
  out.kFleet = resK ? resK.cycles[0].fleet : null;

  // Run L — a budget throw still routes through finalize (DR-8). budgetTotal=2
  // lets the claim + first watch relay through, then the verdict relay throws.
  const recL = await run(buildArgs(), { budgetTotal: 2, agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resL = resultOf(recL);
  out.lObservable = !!resL;
  out.lThrew = !!(resL && resL.auditEvents.some(function (e) { return e.event === "run_threw"; }));
  out.lHalted = resL ? resL.halted : null;
  out.lBudgetThrows = recL.budgetThrows;

  // Run M — the projected-agent ceiling aborts BEFORE the claim relay, so no
  // issue is claimed and left unsolved.
  //
  // RE-DERIVED (#508). The old fixture used maxAgents:3, which trips under any
  // per-issue cost and so could not tell the arithmetic from the breaker. The
  // ceiling is pinned to the exact projection instead:
  //   projectedAgentsForCycle(min(queue=2, maxParallel=3))
  //     = 3 (claim/collect/verdict relays) + maxWatchTicks(40) + 2 + 2 * 33
  //     = 111,   where 33 = the fleet 9 design agents + IMPLEMENT_AGENT_BUDGET(24)
  // so 110 must trip and 111 must not. Change the per-issue cost without
  // changing this number and B52/B52b go red, which is the point.
  //
  // 9, not 6, since #524: the design chain gained a BOUNDED spec-revision round
  // (item 1), a plan REVIEW gate (item 2) and a risk-gated security research
  // lens (item 3). Only the plan review is unconditional; the revision round
  // fires on a non-APPROVE verdict and the security lens on a non-empty triage
  // risk-signal set. This projection is pessimistic about all three by design —
  // CB1 is computed before any verdict OR any manifest read exists, so the only
  // honest upper bound charges every design rung that can fire.
  //
  // DELIBERATELY RETYPED, unlike the fleet-side copies. This is the cross-file
  // ratchet for the two /goal cost copies, which have no behavioural counter of
  // their own: derive both sides of the comparison and it stops comparing.
  //
  // The flat term is 2, not 1 (#515): the fleet spends a batched PR-claim
  // verification relay alongside its intake relay, once per fleet run rather
  // than per issue.
  const CYCLE_PROJECTION = 3 + 40 + 2 + (2 * 33);   // 111
  const recM = await run(buildArgs({ maxAgents: CYCLE_PROJECTION - 1 }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
  } });
  const resM = resultOf(recM);
  out.mTripped = resM ? resM.cb1Tripped : null;
  out.mNoClaim = !labels(recM).some(function (l) { return /^goal-claim/.test(l || ""); });
  out.mAudit = !!(resM && resM.auditEvents.some(function (e) { return e.event === "agent_ceiling_cb1"; }));

  // ...and the companion no-trip probe at exactly the projection: the breaker
  // must not fire one agent early, and the claim relay must actually run.
  const recM2 = await run(buildArgs({ maxAgents: CYCLE_PROJECTION }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resM2 = resultOf(recM2);
  out.m2Tripped = !!(resM2 && resM2.cb1Tripped);
  out.m2Claimed = labels(recM2).some(function (l) { return /^goal-claim/.test(l || ""); });

  // Run N — the claim prompt must carry the exact arming chain (the runtime
  // complement to tests/goal.test.sh BT83s source-shape greps).
  const claimCall = recA.agentCalls.find(function (c) { return c.label === "goal-claim:c1"; });
  const cp = claimCall ? claimCall.prompt : "";
  out.nPhase1 = cp.indexOf("/p/lib/goal-phase1.sh") >= 0;
  out.nLauncher = cp.indexOf("/p/lib/solve-launcher.sh") >= 0;
  // The ARMED COMMAND, not the loose flag token: the prompt explains both flags
  // in prose at length, so a bare-token check passes even after the flag is
  // deleted from the command line (verified by mutation).
  out.nBackend = cp.indexOf("--turbo -- <ISSUES> --backend=workflow --force") >= 0;
  out.nForce = cp.indexOf("backend=workflow --force") >= 0;
  out.nVerbatim = cp.indexOf("VERBATIM") >= 0;
  out.nMarkSolving = cp.indexOf("--mark-solving=<CSV>") >= 0;
  out.nMarkFailed = cp.indexOf("--mark-failed=<CSV>") >= 0;
  const watchCall = recA.agentCalls.find(function (c) { return c.label === "goal-watch:c1:t1"; });
  out.nWatchNoInterpret = !!(watchCall && watchCall.prompt.indexOf("Do NOT interpret it") >= 0);
  out.nWatchSettled = !!(watchCall && watchCall.prompt.indexOf("UBERDEV_GOAL_SOLVERS_SETTLED=1") >= 0);

  // Run O — the envelope issue set must be the set the claim pass CLAIMED.
  // The launcher is armed with --force, which bypasses its own uberdev:active
  // collision guard, so an envelope naming any other issue would solve an
  // unclaimed one. Same shape as a healthy run except for the substituted list.
  const recO = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ dispatch: "11,12", armed: "11,12",
      fleetArgsJson: fleetEnvelope("11,12,99") }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resO = resultOf(recO);
  out.oNested = recO.workflowCalls.length;
  out.oFleet = resO ? resO.cycles[0].fleet : null;
  out.oReason = !!(resO && resO.auditEvents.some(function (e) {
    return e.event === "fleet_args_refused" && e.reason === "issue_set_mismatch";
  }));
  // ...and a DROPPED issue is a mismatch too, not just an extra one.
  const recO2 = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ dispatch: "11,12", armed: "11,12", fleetArgsJson: fleetEnvelope("11") }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  out.o2Nested = recO2.workflowCalls.length;
  // Control: the same run with a MATCHING set (order permuted) still dispatches,
  // so the guard is a set comparison and not an accidental always-refuse.
  const recO3 = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ dispatch: "11,12", armed: "11,12", fleetArgsJson: fleetEnvelope("12,11") }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  out.o3Nested = recO3.workflowCalls.length;

  // Run P — a failed STEP 3 reconciliation halts BEFORE the fleet is armed.
  // A stuck `dispatched` row can never take the goal-watch `solving -> pr-pushed`
  // arc, so the cycle would otherwise burn every tick to a misattributed
  // watch_tick_ceiling.
  const recP = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim({ markRc: 1 }),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resP = resultOf(recP);
  out.pHalted = resP ? resP.halted : null;
  out.pReason = resP ? resP.haltReason : null;
  out.pNoNested = recP.workflowCalls.length === 0;
  out.pNoWatch = !labels(recP).some(function (l) { return /^goal-watch/.test(l || ""); });
  out.pAudit = !!(resP && resP.auditEvents.some(function (e) { return e.event === "mark_reconcile_failed"; }));

  // Run Q — a Bash-tool TIMEOUT on the watch relay is not a script verdict.
  // It carries no exit status, so it must re-tick (the goal-watch.sh TERM handler
  // persisted run-state) instead of halting the goal as a script error.
  const recQ = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: -1, timedOut: true, note: "tool timeout" },
    "goal-watch:c1:t2": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resQ = resultOf(recQ);
  out.qConverged = resQ ? resQ.converged : null;
  out.qHalted = resQ ? resQ.halted : null;
  out.qTicks = resQ ? resQ.cycles[0].watchTicks : null;
  out.qAudit = !!(resQ && resQ.auditEvents.some(function (e) { return e.event === "watch_relay_timeout"; }));
  // Negative control: WITHOUT the timedOut flag the same rc IS a script error.
  const recQ2 = await run(buildArgs(), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: -1, note: "some other failure" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const resQ2 = resultOf(recQ2);
  out.q2Reason = resQ2 ? resQ2.haltReason : null;
  const watchQ = recQ.agentCalls.find(function (c) { return c.label === "goal-watch:c1:t1"; });
  out.qPromptTimeout = !!(watchQ && watchQ.prompt.indexOf("timeout: 600000") >= 0);
  out.qPromptContract = !!(watchQ && watchQ.prompt.indexOf("TIMEOUT CONTRACT") >= 0);

  // Run R — the bash>=4 execution contract reaches the RELAY-RUN phase scripts.
  // The phase-0 re-exec only fixes the phase-0 process itself; these are separate
  // processes, and PATH `bash` is 3.2 on stock macOS.
  const recR = await run(buildArgs({ bashBin: "/opt/homebrew/bin/bash", watchBudgetS: 300 }), {
    agentReturns: {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect(),
    } });
  const claimR = recR.agentCalls.find(function (c) { return c.label === "goal-claim:c1"; });
  const watchR = recR.agentCalls.find(function (c) { return c.label === "goal-watch:c1:t1"; });
  const collectR = recR.agentCalls.find(function (c) { return c.label === "goal-collect:c1"; });
  out.rClaimBash = !!(claimR && claimR.prompt.indexOf("\"/opt/homebrew/bin/bash\" \"/p/lib/goal-phase1.sh\"") >= 0);
  out.rLauncherBash = !!(claimR && claimR.prompt.indexOf("\"/opt/homebrew/bin/bash\" \"/p/lib/solve-launcher.sh\"") >= 0);
  out.rWatchBash = !!(watchR && watchR.prompt.indexOf("\"/opt/homebrew/bin/bash\" \"/p/lib/goal-watch.sh\"") >= 0);
  out.rCollectBash = !!(collectR && collectR.prompt.indexOf("\"/opt/homebrew/bin/bash\" \"/p/lib/goal-phase3.sh\"") >= 0);
  out.rNoBarePathBash = !!(watchR && watchR.prompt.indexOf("bash \"/p/lib/goal-watch.sh\"") < 0);
  // watchBudgetS=300 -> (300+120)*1000
  out.rWatchTimeout = !!(watchR && watchR.prompt.indexOf("timeout: 420000") >= 0);
  // A malformed/absent bashBin degrades to PATH `bash`, never to an unvalidated word.
  const recR2 = await run(buildArgs({ bashBin: "rm -rf /; bash" }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
    "goal-verdicts:c1": VERDICTS,
    "goal-collect:c1": collect(),
  } });
  const claimR2 = recR2.agentCalls.find(function (c) { return c.label === "goal-claim:c1"; });
  out.r2Sanitised = !!(claimR2 && claimR2.prompt.indexOf("rm -rf") < 0
    && claimR2.prompt.indexOf("\"bash\" \"/p/lib/goal-phase1.sh\"") >= 0);

  // Run S (#515) — the nested fleet gained a second relay (its PR-claim proof
  // pass), so the goal-side projection has to grow with it or CB1 under-counts
  // by one per cycle and the "halt before claiming" guarantee stops being exact.
  //
  // MUTATION-SENSITIVE by construction — and RE-DERIVED from the live per-issue
  // cost instead of from arithmetic frozen when this row was written. The
  // hand-written ceiling of 58 charged 7 agents per issue; the shared constant
  // BOTH sides of the comparison read is 33, so the real projection sat far
  // above 58 and the breaker tripped whether the added relay term was 2 or 1.
  // A row advertising a sensitivity it no longer has is worse than no row: the
  // next reader trusts the message instead of re-deriving it.
  //
  // Default fixture: 2 queued issues, maxParallel 3, maxWatchTicks 40, so the
  // projection is CYCLE_PROJECTION (111) and the pre-#515 one is 110. At a
  // ceiling of 110, the current formula trips (111 > 110) and a formula whose
  // flat term is reverted to 1 does not (110 > 110 is false), which is exactly
  // the term this row exists to protect.
  const recS = await run(buildArgs({ maxAgents: CYCLE_PROJECTION - 1 }), { agentReturns: {
    "goal-claim:c1": claim(),
    "goal-watch:c1:t1": { rc: 0, note: "drained" },
  } });
  const resS = resultOf(recS);
  out.sTripped = resS ? resS.cb1Tripped : null;
  out.sNoClaim = !labels(recS).some(function (l) { return /^goal-claim/.test(l || ""); });

  // Run T (#515) — the UNTESTED CONSUMER. `grep -rn prsOpened tests/` used to
  // hit only the fleet own suite: the goal ingestion of the fleet PR set had no
  // coverage at all, which is precisely the leg a post-verification set has to
  // travel to matter. This locks the passthrough and nothing more.
  //
  // Note deliberately: `rec.prsOpened` is WRITTEN here and read by nothing
  // downstream — its only other mention in goal-pipeline/workflow.js is the
  // `rec.prsOpened = digitsOnly(out.prsOpened)` assignment itself. Cited by
  // identifier rather than by line number: a citation into a file this PR class
  // keeps editing rots, and this one already had. So
  // this is an ingestion-passthrough lock, NOT a behavioural one — there is no
  // "the cycle stops treating the issue as PR-bearing" behaviour to assert
  // against, and pretending otherwise would paper over a dead consumer.
  const recT = await run(buildArgs(), {
    agentReturns: {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect(),
    },
    workflowReturns: {
      // The fleet disproved the PR claimed for #11 and dropped it from the set;
      // the downgraded record still rides in `results`.
      [FLEET_PATH]: {
        prsOpened: [902],
        results: [
          { issue: 11, status: "PUSHED_NO_PR", prNumber: 0, claimedStatus: "PR_OPENED",
            claimedPrNumber: 901, prProof: "DISPROVEN" },
          { issue: 12, status: "PR_OPENED", prNumber: 902, prProof: "CONFIRMED" },
        ],
      },
    },
  });
  const resT = resultOf(recT);
  out.tPrsOpened = (resT && resT.cycles.length) ? resT.cycles[0].prsOpened : null;

  // Runs T2-T8 (#592) — the PARTIAL-CHAIN CARRIER, and the one surface no grep
  // can see: the COMMAND LINE the driver hands the two phase scripts.
  //
  // `chainComplete` has been script-derived and correct since #554 and reached
  // no consumer. /goal ingested `prsOpened` through a shape-only digit filter
  // and merged on the numbers, so a PR opened over a task chain that STOPPED
  // SHORT arrived at the merge gate byte-identical to one opened over a
  // finished chain, and the run then reported a convergence it had not
  // achieved. The driver is the only party that sees the fleet's return value
  // AND composes the phase-script command lines, and RFC 0012 §2.2 constraint 6
  // forbids it a filesystem — so argv is the whole channel, and these rows read
  // the emitted flag and the run ledger rather than the presence of a field.
  function promptFor(record, label) {
    const c = record.agentCalls.find(function (x) { return x.label === label; });
    return c ? c.prompt : "";
  }
  function fleetReturn(value) {
    const m = {};
    m[FLEET_PATH] = value;
    return m;
  }
  function partialReturns() {
    return {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect(),
    };
  }

  // Run T2 — one chain finished, one stopped short, both delivering a PR. The
  // POSITIVE half: an arity regression on the digit filter (calling it with a
  // scalar rather than the array it takes) empties both sets while every
  // negative control below still passes, which is a silent, green, total
  // failure. This is the row that reds for it.
  const recT2 = await run(buildArgs(), {
    agentReturns: partialReturns(),
    workflowReturns: fleetReturn({
      prsOpened: [901, 902],
      prsPartial: [901],
      results: [
        { issue: 11, status: "PR_OPENED", prNumber: 901, prProof: "CONFIRMED", chainComplete: false },
        { issue: 12, status: "PR_OPENED", prNumber: 902, prProof: "CONFIRMED", chainComplete: true },
      ],
    }),
  });
  const resT2 = resultOf(recT2);
  out.t2Issues = resT2 ? resT2.partialIssues : null;
  out.t2Prs = resT2 ? resT2.partialPrs : null;
  out.t2CycleIssues = (resT2 && resT2.cycles.length) ? resT2.cycles[0].partialIssues : null;
  out.t2WatchFlag = promptFor(recT2, "goal-watch:c1:t1").indexOf(" --partial-prs=901") >= 0;
  out.t2CollectFlag = promptFor(recT2, "goal-collect:c1").indexOf(" --partial-issues=11") >= 0;
  // The clean-path PR set is untouched by the partial ingest.
  out.t2PrsOpened = (resT2 && resT2.cycles.length) ? resT2.cycles[0].prsOpened : null;
  // #603 — the SAME argv channel carries the corroboration pairs. The fleet is
  // the only party that knows which PR it opened for which issue; without the
  // pairs the shell finder picks a PR for an issue on branch NAME alone and a
  // stranger's `fix/500-error-page` binds to issue 500. Read off the rendered
  // command line, because no grep over either file can assert what the driver
  // actually composed.
  out.t2SolverFlag = promptFor(recT2, "goal-watch:c1:t1").indexOf(" --solver-prs=11:901,12:902") >= 0;
  out.t2SolverLedger = resT2 ? (resT2.solverPrs || []).join("|") : null;

  // Run T3 — the negative control. Every relay command line stays
  // byte-identical to today's on a clean cycle: the flag is OMITTED, never
  // emitted empty, because `--partial-prs=` with no value is a malformed-shape
  // exit 2 in lib/goal-watch.sh and would halt every converging run.
  const recT3 = await run(buildArgs(), {
    agentReturns: partialReturns(),
    workflowReturns: fleetReturn({
      prsOpened: [901, 902],
      prsPartial: [],
      results: [
        { issue: 11, status: "PR_OPENED", prNumber: 901, prProof: "CONFIRMED", chainComplete: true },
        { issue: 12, status: "PR_OPENED", prNumber: 902, prProof: "CONFIRMED", chainComplete: true },
      ],
    }),
  });
  const resT3 = resultOf(recT3);
  out.t3Issues = resT3 ? resT3.partialIssues : null;
  out.t3Clean = promptFor(recT3, "goal-watch:c1:t1").indexOf("--partial-prs=") < 0
    && promptFor(recT3, "goal-collect:c1").indexOf("--partial-issues=") < 0;
  // #603 — the corroboration flag is NOT conditional on partialness: a clean
  // cycle is exactly the cycle whose PRs the finder must still attribute
  // correctly, so it rides every command line that has pairs to carry.
  out.t3SolverFlag = promptFor(recT3, "goal-watch:c1:t1").indexOf(" --solver-prs=11:901,12:902") >= 0;

  // Run T4 — three shapes at once, and the row cannot pass by rejecting
  // everything: the two records with NO `chainComplete` key are not counted
  // (absent means the record ran no task chain at all — the single-solver path
  // attaches the field nowhere — and a chain that never ran cannot have stopped
  // short) while their `chainComplete: false` siblings in the SAME return still
  // are. Issue 13 delivered no PR, so it owes the issue set a member and the PR
  // set nothing. And the whole return carries NO `prsOpened` key, so the ledger
  // cannot be nested inside that block.
  const recT4 = await run(buildArgs(), {
    agentReturns: partialReturns(),
    workflowReturns: fleetReturn({
      prsPartial: [903],
      results: [
        { issue: 11, status: "FAILED" },
        { issue: 12, status: "PR_OPENED", prNumber: 902, prProof: "CONFIRMED" },
        { issue: 13, status: "PUSHED_NO_PR", prNumber: 0, prProof: "DISPROVEN", chainComplete: false },
        { issue: 14, status: "PR_OPENED", prNumber: 903, prProof: "CONFIRMED", chainComplete: false },
      ],
    }),
  });
  const resT4 = resultOf(recT4);
  out.t4Issues = resT4 ? resT4.partialIssues : null;
  out.t4Prs = resT4 ? resT4.partialPrs : null;
  out.t4CollectFlag = promptFor(recT4, "goal-collect:c1").indexOf(" --partial-issues=13,14") >= 0;
  // #603 — the shapes that must NOT reach the ledger, all in one return: a
  // FAILED record with no PR at all, and a PUSHED_NO_PR record whose prNumber
  // is the 0 sentinel. Pairing issue 13 with PR 0 would corroborate every
  // lookup for issue 13 with a number no PR can ever have, and the finder would
  // then answer "no PR" for an issue whose solver may yet be found by the
  // guess — the over-tightening that turns a wrong-PR bug into a run halt.
  out.t4SolverFlag = promptFor(recT4, "goal-watch:c1:t1").indexOf(" --solver-prs=12:902,14:903") >= 0;

  // Run T5 — halt legibility. lib/goal-phase3.sh's partial-chain refusal reuses
  // the closed-set breaker reason `solver_failed` with `phase=partial_chain` as
  // the discriminator, so the phase subfield is the ONLY thing that tells the
  // two halts apart. It travels as its own field: concatenating it into
  // haltReason would rewrite the halt strings of the four live emitters that
  // already put a `phase` in a breaker payload.
  const recT5 = await run(buildArgs(), {
    agentReturns: Object.assign(partialReturns(), {
      "goal-collect:c1": collect({ rc: 1, decision: "halt", reason: "solver_failed",
        phase: "partial_chain" }),
    }),
  });
  const resT5 = resultOf(recT5);
  out.t5Reason = resT5 ? resT5.haltReason : null;
  out.t5Phase = resT5 ? resT5.haltPhase : null;

  // Run T6 — the regression guard for that decision. A breaker that carries a
  // phase from some OTHER emitter must still report its reason unsuffixed.
  const recT6 = await run(buildArgs(), {
    agentReturns: Object.assign(partialReturns(), {
      "goal-collect:c1": collect({ rc: 1, decision: "halt", reason: "stuck_loop",
        phase: "merge_barrier" }),
    }),
  });
  const resT6 = resultOf(recT6);
  out.t6Reason = resT6 ? resT6.haltReason : null;
  out.t6Phase = resT6 ? resT6.haltPhase : null;

  // Run T7 — and a breaker with no phase at all keeps B28/B29 semantics: the
  // reason verbatim, the phase empty rather than absent.
  const recT7 = await run(buildArgs(), {
    agentReturns: Object.assign(partialReturns(), {
      "goal-collect:c1": collect({ rc: 1, decision: "halt", reason: "nonconvergence" }),
    }),
  });
  const resT7 = resultOf(recT7);
  out.t7Reason = resT7 ? resT7.haltReason : null;
  out.t7Phase = resT7 ? resT7.haltPhase : null;

  // Run T8 — the ledger is RUN-LIFETIME, not per cycle. lib/goal-phase3.sh
  // truncates the batch-PR registry at loop-back and lib/goal-watch.sh
  // re-discovers PRs from `gh pr list` on every pass, so a set that reset with
  // the cycle would stop naming a cycle-1 partial delivery the moment cycle 2
  // returned a clean fleet — and the convergence gate would then converge the
  // run on the cycle it was cleanest. The per-cycle record still carries THIS
  // cycle's set, which is what makes the two observable separately.
  let t8FleetCalls = 0;
  const T8_FLEET = {};
  T8_FLEET[FLEET_PATH] = function () {
    t8FleetCalls += 1;
    return (t8FleetCalls === 1)
      ? { prsOpened: [901], prsPartial: [901],
          results: [{ issue: 11, status: "PR_OPENED", prNumber: 901, prProof: "CONFIRMED",
            chainComplete: false }] }
      : { prsOpened: [903], prsPartial: [],
          results: [{ issue: 13, status: "PR_OPENED", prNumber: 903, prProof: "CONFIRMED",
            chainComplete: true }] };
  };
  const recT8 = await run(buildArgs(), {
    agentReturns: {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 1, queued: 1, queue: "13" }),
      "goal-claim:c2": claim({ dispatch: "13", armed: "13" }),
      "goal-watch:c2:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c2": VERDICTS,
      "goal-collect:c2": collect(),
    },
    workflowReturns: T8_FLEET,
  });
  const resT8 = resultOf(recT8);
  out.t8Issues = resT8 ? resT8.partialIssues : null;
  out.t8Prs = resT8 ? resT8.partialPrs : null;
  out.t8Cycle2Issues = (resT8 && resT8.cycles.length > 1) ? resT8.cycles[1].partialIssues : null;
  out.t8Cycle2Carried = promptFor(recT8, "goal-watch:c2:t1").indexOf(" --partial-prs=901") >= 0
    && promptFor(recT8, "goal-collect:c2").indexOf(" --partial-issues=11") >= 0;

  // Runs U/V (#564) — the per-cycle SPEND accumulator, observed as a VALUE.
  //
  // Every run above asserts what the driver DID. None asserted what it CHARGED:
  // `grep -rn agentsSpent tests/` had ZERO hits, so the term CB1 compares its
  // ceiling against was free to be wrong in either direction and no row here
  // would have gone red. Two specific wrongs are what #564 is about — a fleet
  // priced at a hardcoded 30 per issue while the operator raised the relayed
  // implement budget, and a fleet that THREW being charged nothing at all.
  // Runs M/M2/S cannot see either: they trip CB1 while agentsSpent is still 0,
  // which is also why the `agentsSpent +` term at the CB1 comparison has never
  // been exercised by anything.
  //
  // READ-ONLY MIRROR of goal-pipeline/workflow.js: the per-issue design-agent
  // base READ OUT of the fleet script (9 at present), plus the clamped implement
  // budget per claimed issue, the two BATCHED fleet
  // relays (intake + PR-claim verification, #515), and the four relays the
  // driver charges one at a time per cycle (claim, one watch tick, verdicts,
  // collect). Named rather than typed, so no expected number below is a digit a
  // later reader has to re-derive by hand. The projection surface is a separate
  // formula owned by runs M/M2/S — CYCLE_PROJECTION above stays untouched.
  // perIssueFleetCost prices ONE issue as that same design-agent base plus
  // clampInt(cfg.implementBudget, 4, 96, 24). The clamp triple is NAMED because
  // runs W/X below drive the relayed budget past both bounds and every expected
  // total there is derived from it: a second typed copy of any of these three
  // numbers is a copy that can drift away from the fleet with no row noticing.
  // READ OUT of the fleet script, never retyped. This mirror was a literal `6`
  // and the fleet design base then moved to 9 when the spec-reviser, plan-
  // reviewer and security lens were added — every expected total in this block
  // silently became short by 3 per claimed issue, which is precisely the drift
  // the paragraph above warns about. The base is the same single term G31 in
  // tests/solve-fleet-workflow.test.sh pins, and it must resolve EXACTLY once:
  // a regex that matched twice would make the extracted value arbitrary, and
  // one that matched nothing would silently price every issue at its budget.
  const FLEET_DESIGN_AGENTS = (function () {
    const fleetSrc = fs.readFileSync(process.argv[3], "utf8");
    const rx = /designCount \* \((\d+) \+ IMPLEMENT_AGENT_BUDGET/g;
    const hits = [];
    let m;
    while ((m = rx.exec(fleetSrc)) !== null) hits.push(Number(m[1]));
    if (hits.length !== 1) {
      throw new Error("expected exactly one designCount * (N + IMPLEMENT_AGENT_BUDGET term in the fleet script, found " + hits.length);
    }
    return hits[0];
  })();
  const BUDGET_FLOOR = 4;
  const BUDGET_CEILING = 96;
  const BUDGET_DEFAULT = 24;
  function perIssueCost(budget) { return FLEET_DESIGN_AGENTS + budget; }
  const GOAL_PER_ISSUE_DEFAULT = perIssueCost(BUDGET_DEFAULT);  // the default arm: base + 24
  const FLEET_BATCHED_RELAYS = 2;
  const CYCLE_RELAYS = 4;
  const SPEND_CLAIMED = 2;                // the default fixture claims 11,12
  function fleetCost(issues, perIssue) { return FLEET_BATCHED_RELAYS + (issues * perIssue); }
  function cycleTotal(issues, perIssue) { return CYCLE_RELAYS + fleetCost(issues, perIssue); }
  const THROW_MSG = "runtime refused further agents";
  const THROWING_FLEET = {};
  // A FUNCTION value is resolved per call by the harness, so this is the only
  // way any fixture in this repo can make a nested workflow() call fail and
  // reach the catch arm under test (tests/_workflow_harness.js H14.4).
  THROWING_FLEET[FLEET_PATH] = function () { throw new Error(THROW_MSG); };
  // One assert per row, with BOTH numbers in the failure text: the shell side
  // then carries no second copy of the arithmetic above to drift from it.
  function spendMatch(observed, expected) {
    return (observed === expected) ? "match" : (String(observed) + " != " + String(expected));
  }
  function spendReturns() {
    return {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect(),
    };
  }

  // Run U — a clean converged cycle: the fleet ran, so the clean arm charges.
  // Only the TOTAL is pinned here. At the default budget the per-issue term the
  // driver derives from the relayed envelope and a hardcoded literal are the
  // same number, so this row cannot tell them apart — separating them needs a
  // run whose envelope carries a raised implementBudget, which is its own row.
  const recU = await run(buildArgs(), { agentReturns: spendReturns() });
  const resU = resultOf(recU);
  out.uSpend = spendMatch(resU ? resU.agentsSpent : null,
    cycleTotal(SPEND_CLAIMED, GOAL_PER_ISSUE_DEFAULT));

  // Run V — the SAME cycle with the nested fleet THROWING. The likeliest cause
  // of that throw is the runtime refusing further agents, which is the moment
  // the fleet has spent the MOST; a catch arm charging nothing would leave CB1
  // comparing its ceiling against a spend that never happened, and the run
  // would then die against an opaque runtime cap with no named halt.
  const recV = await run(buildArgs(),
    { agentReturns: spendReturns(), workflowReturns: THROWING_FLEET });
  const resV = resultOf(recV);
  out.vParity = spendMatch(resV ? resV.agentsSpent : null, resU ? resU.agentsSpent : null);
  // The ledger has to stay HONEST about what it does not know: the cycle is
  // marked, the estimate it charged is published, and the cause is recorded.
  // Reported as a diagnostic string so a failure names which half broke.
  out.vLedger = (function () {
    if (!resV) return "no result";
    const c0 = resV.cycles.length ? resV.cycles[0] : null;
    if (!c0 || c0.fleet !== "threw") return "cycle fleet=" + (c0 ? c0.fleet : "no cycle");
    const est = resV.auditEvents.filter(function (e) { return e.event === "fleet_spend_unmeasured"; })[0];
    if (!est) return "no fleet_spend_unmeasured event";
    const want = fleetCost(SPEND_CLAIMED, GOAL_PER_ISSUE_DEFAULT);
    if (est.estimated !== want) return "estimated " + est.estimated + " != " + want;
    if (est.claimed !== SPEND_CLAIMED) return "claimed " + est.claimed;
    const threw = resV.auditEvents.filter(function (e) { return e.event === "fleet_threw"; })[0];
    if (!threw) return "no fleet_threw event";
    if (String(threw.reason || "").indexOf(THROW_MSG) < 0) return "reason " + threw.reason;
    return "ok";
  })();

  // Runs W/X (#564) — the per-issue term is READ OUT of the relayed envelope.
  //
  // Run U pins the total at the DEFAULT budget, and at the default the shipped
  // derivation
  //     2 + (rec.claimed.length * perIssueFleetCost(fleetArgs))
  // and the hardcoded `* 30` it replaced produce the SAME number, so no row
  // above can tell them apart. G16 in tests/solve-fleet-workflow.test.sh does
  // red on that exact textual revert — but it is a grep, and a grep cannot see a
  // VALUE. Measured: making perIssueFleetCost read `{}` in place of
  // fleetArgs.config leaves every token G16 matches on exactly where it was,
  // keeps that suite GREEN at rc=0, and silently prices every issue at the
  // default again. Only the rows below red on it. The budget is operator-set
  // through UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET, which
  // lib/solve-launcher.sh plumbs into the very envelope the claim relay hands
  // back and this driver relays verbatim; at the ceiling one issue costs more
  // than three times the literal, so an accumulator reading 30 hands CB1 a
  // spend that is threefold short and the only NAMED halt never fires. These
  // rows are the only place in the repo where the two can be told apart at
  // runtime.
  //
  // Identical to run U in every other respect — same relays, same clean
  // converged cycle, same claimed set — so the only thing any delta below can
  // be attributed to is the config the claim relay put in the envelope.
  async function spendAtBudget(cfgExtra, expectedPerIssue) {
    const returns = spendReturns();
    returns["goal-claim:c1"] = claim({ fleetArgsJson: fleetEnvelope("11,12", cfgExtra) });
    const rec = await run(buildArgs(), { agentReturns: returns });
    const res = resultOf(rec);
    return spendMatch(res ? res.agentsSpent : null, cycleTotal(SPEND_CLAIMED, expectedPerIssue));
  }

  // Run W — a budget the operator raised to the top of the supported range.
  out.wRaised = await spendAtBudget({ implementBudget: BUDGET_CEILING },
    perIssueCost(BUDGET_CEILING));

  // Runs X — budgets the FLEET itself would refuse to run with. clampInt is what
  // it applies to this key, so charging a relayed budget as typed would overcount
  // as wrongly as the literal undercounts, and the ledger has to clamp the same
  // way. Probed just OUTSIDE each bound rather than far outside: that reds both
  // a missing clamp and a clamp whose boundary moved, which a distant value
  // cannot tell apart.
  out.xFloor = await spendAtBudget({ implementBudget: BUDGET_FLOOR - 1 },
    perIssueCost(BUDGET_FLOOR));
  out.xCeiling = await spendAtBudget({ implementBudget: BUDGET_CEILING + 1 },
    perIssueCost(BUDGET_CEILING));
  // A value that cannot be read as a number is not a budget of zero: it falls to
  // the fleet default, exactly as a missing key does. Charging zero would be the
  // same silent undercount by another route.
  out.xUnreadable = await spendAtBudget({ implementBudget: "abc" }, GOAL_PER_ISSUE_DEFAULT);
  out.xAbsent = await spendAtBudget(undefined, GOAL_PER_ISSUE_DEFAULT);

  // Runs Y (#564) — CB1 halts a LATER cycle because an EARLIER one was charged.
  //
  // Runs M/M2/S all trip CB1 on cycle 1, where agentsSpent is still zero. They
  // pin the projection and nothing else, so the `agentsSpent +` half of the
  // comparison the breaker actually makes has never been exercised by any row
  // in this repo — a ledger that never grows would keep every one of them
  // green. That half is the whole point of the accumulator: the projection is
  // computed before the claim pass and cannot know what the run already burnt.
  // And an accumulator reading low does not merely mis-report — CB1 is the only
  // NAMED halt, so it stops firing altogether and the run dies against the
  // runtime lifetime cap with no halt reason, no audit row, and no cycle record
  // saying why it stopped.
  //
  // Two cycles, with the ceiling placed exactly ONE agent below what cycle 1
  // spends plus what cycle 2 projects. Cycle 1 loops back carrying a single
  // surviving candidate, so cycle 2 sizes its projection from one issue. The
  // decision must be `loop`: the driver recognises only `converged` and `loop`,
  // and any other value halts at cycle 1 — cycle 2 would never run and the row
  // would pass on a ledger that was never read.
  const CYCLE1_TOTAL = cycleTotal(SPEND_CLAIMED, GOAL_PER_ISSUE_DEFAULT);
  // READ-ONLY MIRROR of projectedAgentsForCycle for the ONE issue cycle 2
  // claims: the three per-cycle relays it counts, the maxWatchTicks bound this
  // fixture runs at, the two batched fleet relays, and the per-issue term. Runs
  // M/M2/S own that surface; CYCLE_PROJECTION above stays untouched.
  //
  // That per-issue term is a flat LITERAL in the projection — it does NOT track
  // the relayed budget the spend term derives, which the workflow header states
  // outright and which is tracked as its own gap. At the fleet default the two
  // are the same number, so the named default is reused here rather than typed
  // a fourth time; if the fleet default ever moves, the projection stops
  // following it and this row reds naming which half moved.
  const CYCLE2_PROJECTION = 3 + 40 + 2 + (1 * GOAL_PER_ISSUE_DEFAULT);
  function twoCycleReturns() {
    return {
      "goal-claim:c1": claim(),
      "goal-watch:c1:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c1": VERDICTS,
      "goal-collect:c1": collect({ rc: 42, decision: "loop", candidates: 1, queued: 1, queue: "11" }),
      "goal-claim:c2": claim({ dispatch: "11", armed: "11" }),
      "goal-watch:c2:t1": { rc: 0, note: "drained" },
      "goal-verdicts:c2": VERDICTS,
      "goal-collect:c2": collect(),
    };
  }

  // Run Y — one agent short of the sum, so the breaker must fire, and it can
  // only fire on the charged ledger. Delete the clean-arm charge and cycle 1
  // costs the four driver relays alone: CYCLE_RELAYS + CYCLE2_PROJECTION is far
  // under this ceiling, nothing trips, and the run converges having spent a
  // fleet it never counted. Cycle 1 itself never trips at this ceiling either —
  // its own projection covers two issues and still fits — so the halt below is
  // attributable to the cycle-1 charge and to nothing else.
  const recY = await run(buildArgs({ maxAgents: CYCLE1_TOTAL + CYCLE2_PROJECTION - 1 }),
    { agentReturns: twoCycleReturns() });
  const resY = resultOf(recY);
  out.yCeiling = (function () {
    if (!resY) return "no result";
    if (resY.cb1Tripped !== true) return "not tripped at spent=" + resY.agentsSpent;
    const ev = resY.auditEvents.filter(function (e) { return e.event === "agent_ceiling_cb1"; })[0];
    if (!ev) return "no agent_ceiling_cb1 event";
    // The event has to publish BOTH terms, or an operator reading it cannot
    // tell a run that overspent from a projection that was too big.
    if (ev.spent !== CYCLE1_TOTAL) return "spent " + ev.spent + " != " + CYCLE1_TOTAL;
    if (ev.projected !== CYCLE2_PROJECTION) return "projected " + ev.projected + " != " + CYCLE2_PROJECTION;
    if (ev.cycle !== 2) return "cycle " + ev.cycle;
    return "ok";
  })();

  // Run Y2 — the same run with exactly one more agent of headroom. Without it
  // the row above could pass on a breaker that fires early for any reason at
  // all, and the claim label proves cycle 2 really went on to claim rather than
  // ending some other way with cb1Tripped left false.
  const recY2 = await run(buildArgs({ maxAgents: CYCLE1_TOTAL + CYCLE2_PROJECTION }),
    { agentReturns: twoCycleReturns() });
  const resY2 = resultOf(recY2);
  out.yHeadroom = (function () {
    if (!resY2) return "no result";
    if (resY2.cb1Tripped) return "tripped with exact headroom";
    if (!labels(recY2).some(function (l) { return l === "goal-claim:c2"; })) return "cycle 2 never claimed";
    return "ok";
  })();

  // Run V again (#564) — charging for the throw must not turn into HALTING on
  // it. Solvers that already pushed a PR still have to be driven to merge and
  // the claims still have to be reconciled, so the cycle continues past the
  // failed fleet; the charge is a ledger entry, not a verdict.
  out.vWatched = (function () {
    if (!resV) return "no result";
    if (!labels(recV).some(function (l) { return l === "goal-watch:c1:t1"; })) return "no watch pass";
    if (resV.halted !== false) return "halted " + resV.haltReason;
    if (resV.converged !== true) return "not converged";
    return "ok";
  })();
  // And the failed call is still ON the record: every call-count row in this
  // file would otherwise be silently conditional on the nested run succeeding.
  out.vNestedCalls = recV.workflowCalls.length;

  process.stdout.write(JSON.stringify(out));
})().catch(function (e) {
  process.stdout.write(JSON.stringify({ FIXTURE_ERROR: (e && e.message) ? e.message : String(e), STACK: (e && e.stack) ? e.stack : "" }));
});
UBERDEV_FIXTURE_JS_EOF
} > "$FIXTURE_JS"
FIXTURE_OUT="$(node "$FIXTURE_JS" "$HARNESS" "$WORKFLOW" "$FLEET" 2>&1)"

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

  check aViolations 0                     "B1 converge run: zero harness violations"
  check aConverged true                   "B2 a converged collect decision converges the run"
  check aHalted false                     "B3 convergence is not a halt"
  check aCycles 1                         "B4 exactly one cycle ran"
  check aNested 1                         "B5 EXACTLY ONE nested workflow() call for the whole cycle"
  check aNestedPath '"/p/skills/solve-fleet/workflow.js"' "B6 the nested call targets the solve-fleet script"
  check aNestedPipeline '"solve-fleet"'   "B7 the launcher envelope is passed through verbatim (pipeline intact)"
  check aPhases '"dispatch,watch,collect,finalize"' "B8 the phases run in order"
  check aVerdicts 2                       "B9 the shell-produced trust verdicts reach the result"
  check aRelaysHaiku true                 "B10 every relay is mechanical (haiku), none is a judgment agent"

  check bTicks 3                          "B11 the watch drains on 42,42,0 — three relay ticks"
  check bConverged true                   "B12 a 42-then-0 drain still converges"
  check bNested 1                         "B13 re-ticking the watch does NOT re-arm the fleet"
  check bWatchLabels '"goal-watch:c1:t1,goal-watch:c1:t2,goal-watch:c1:t3"' "B14 ticks are labelled and ordered"

  check cTripped true                     "B15 the tick breaker fires when the watch never drains"
  check cReason '"watch_tick_ceiling"'    "B16 the tick breaker names itself"
  check cNoCollect true                   "B17 a tick-breaker halt does NOT collect (the cycle never drained)"
  check cObservable true                  "B18 the tick breaker still emits WORKFLOW_RESULT"

  check dHalted true                      "B19 a watch rc=1 breaker halts the run"
  check dReason '"watch_breaker"'         "B20 the halt is attributed to the watch breaker"
  check dNoCollect true                   "B21 a halted watch does not fall through to collect"

  check eCycles 2                         "B22 a loop decision runs a second cycle"
  check eC1Candidates 2                   "B23 cycle-1 candidates survive into the result (JS state, not a sidecar round-trip)"
  check eConverged true                   "B24 cycle 2 converges"
  check eNested 2                         "B25 one nested fleet call PER CYCLE — never per issue"
  check eC2Claimed '"31,32"'              "B26 cycle 2 claims the new candidate issues"

  check fRepeated '"deadbeefcafe0011"'    "B27 a fingerprint seen in two cycles is recorded as repeated"
  check fHalted true                      "B28 the shell nonconvergence gate halts the run"
  check fReason '"nonconvergence"'        "B29 the halt reason is carried verbatim from the shell"

  check gReason '"max_cycles"'            "B30 the driver backstop halts past max_cycles"
  check gCycles 1                         "B31 no cycle runs past the ceiling"
  check gNoSecondClaim true               "B32 the ceiling aborts BEFORE claiming anything for cycle 2"

  check hC1Claimed '"11,12"'              "B33 the cap-limited claim set is what the claim pass returned"
  check hC1Rollover '"13,14"'             "B34 the rollover is carried, not dropped"
  check hC2Claimed '"13,14"'              "B35 the rollover is claimed on the next cycle"
  check hConverged true                   "B36 convergence only after the rollover drained"
  check hQueueLeft '""'                   "B37 nothing is stranded in the queue at convergence"

  check iObservable true                  "B38 a null claim relay still returns a structured result"
  check iReason '"claim_relay_null"'      "B39 the null relay is named, not guessed at"
  check iNoNested true                    "B40 a null claim relay never arms a fleet"
  check iNoWatch true                     "B41 a null claim relay does not proceed to the watch"

  check jNested 0                         "B42 an empty fleet envelope means NO nested call"
  check jFleet '"args-refused"'           "B43 the refusal is recorded on the cycle"
  check jAudit true                       "B44 fleet_args_refused is audited, not silent"
  check jStillWatched true                "B45 the watch still runs so already-pushed PRs are driven"

  check kNested 0                         "B46 a wrong-pipeline envelope is refused, never repaired"
  check kFleet '"args-refused"'           "B47 the wrong-pipeline refusal is recorded"

  check lObservable true                  "B48 a budget throw still emits WORKFLOW_RESULT (DR-8)"
  check lThrew true                       "B49 the throw is audited as run_threw"
  check lHalted true                      "B50 a thrown run is reported as halted, not as converged"
  check lBudgetThrows 1                   "B51 exactly one budget throw escaped to the driver"

  check mTripped true                     "B52 CB1 trips one agent below the projected per-cycle cost (the formula is pinned, not just the breaker)"
  check mNoClaim true                     "B53 CB1 aborts BEFORE the claim pass — no issue is claimed and stranded"
  check mAudit true                       "B54 agent_ceiling_cb1 is audited"
  check m2Tripped false                   "B52b CB1 does NOT trip at exactly the projected per-cycle cost"
  check m2Claimed true                    "B52c ...and the claim relay actually runs at that ceiling"

  check nPhase1 true                      "B55 the claim prompt names lib/goal-phase1.sh"
  check nLauncher true                    "B56 the claim prompt names lib/solve-launcher.sh"
  check nBackend true                     "B57 the launcher COMMAND is armed with --backend=workflow (not just prose about it)"
  check nForce true                       "B58 --force sits on that same command, right after the backend pin (our own claim would collide)"
  check nVerbatim true                    "B59 the envelope must be copied VERBATIM"
  check nMarkSolving true                 "B60 the relay reconciles dispatched->solving on success"
  check nMarkFailed true                  "B61 the relay reconciles dispatched->failed on an arming failure"
  check nWatchNoInterpret true            "B62 the watch relay is told to report the exit status, never interpret it"
  check nWatchSettled true                "B63 the watch relay carries the settled-fleet marker (the awaited fleet call makes the 150m solver timeout meaningless)"

  check oNested 0                         "B64 an envelope naming an UNCLAIMED issue is refused — --force would have solved it without a claim"
  check oFleet '"args-refused"'           "B65 the issue-set mismatch is recorded on the cycle"
  check oReason true                      "B66 the refusal is audited with reason=issue_set_mismatch"
  check o2Nested 0                        "B67 an envelope that DROPS a claimed issue is a mismatch too"
  check o3Nested 1                        "B68 a set-equal envelope in a different order still dispatches (set comparison, not string equality)"

  check pHalted true                      "B69 a non-zero STEP 3 reconciliation rc halts the run"
  check pReason '"mark_reconcile_failed"' "B70 the halt names the reconciliation, not a downstream tick ceiling"
  check pNoNested true                    "B71 no fleet is armed for issues whose state rows did not land"
  check pNoWatch true                     "B72 the watch pass does not run on an unreconciled cycle"
  check pAudit true                       "B73 mark_reconcile_failed is audited, not silent"

  check qConverged true                   "B74 a timed-out watch relay re-ticks and the cycle still converges"
  check qHalted false                     "B75 a Bash-tool timeout is not a circuit breaker"
  check qTicks 2                          "B76 the timed-out tick is counted against the tick bound"
  check qAudit true                       "B77 watch_relay_timeout is audited"
  check q2Reason '"watch_script_error"'   "B78 the SAME rc without timedOut is still a script error (the flag is what routes it)"
  check qPromptTimeout true               "B79 the watch relay is told the explicit Bash-tool timeout to pass"
  check qPromptContract true               "B80 the watch relay carries an explicit timeout contract"

  check rClaimBash true                   "B81 the claim relay runs lib/goal-phase1.sh under the resolved bash>=4"
  check rLauncherBash true                "B82 the launcher runs under the resolved bash>=4"
  check rWatchBash true                   "B83 the watch relay runs lib/goal-watch.sh under the resolved bash>=4 (PATH bash is 3.2 on stock macOS)"
  check rCollectBash true                 "B84 the collect relay runs lib/goal-phase3.sh under the resolved bash>=4"
  check rNoBarePathBash true              "B85 no relay falls back to a bare PATH \`bash\` when an interpreter was published"
  check rWatchTimeout true                "B86 the relay timeout is sized from the resolved watch budget"
  check r2Sanitised true                  "B87 a malformed bashBin degrades to PATH \`bash\`, never reaching the command line"

  check sTripped true                     "B88 the cycle projection counts the fleet PR-proof relay (#515)"
  check sNoClaim true                     "B89 the raised projection still halts BEFORE the claim pass"

  check tPrsOpened '[902]'                "B90 /goal ingests exactly the fleet post-verification PR set — the disproven number never enters it"

  check t2Issues '[11]'                   "B98a the run ledger names the ISSUE whose solver task chain stopped short — derived from the fleet's per-issue chainComplete, the value no consumer read before"
  check t2Prs '[901]'                     "B98b the run ledger names its PR, taken from the fleet's own prsPartial subset rather than re-derived: two records claiming ONE number disagreeing about completeness is a collision prsOpened has already settled, and a second derivation here would answer it differently with nothing to compare against"
  check t2CycleIssues '[11]'              "B98c the cycle record carries the cycle's own partial set"
  check t2PrsOpened '[901,902]'           "B98d the ingested PR set is unchanged by the partial ingest — both PRs still merge (#554's non-closing trailer is what keeps the unfinished issue open, not a withheld merge)"
  check t2SolverFlag true                 "B99a #603 the watch relay's COMMAND LINE carries --solver-prs=11:901,12:902 — the fleet's own issue->PR record, and the only thing that can tell the shell finder which PR belongs to issue N when a same-numbered stranger branch is open"
  check t2SolverLedger '"11:901|12:902"'  "B99b #603 the pairs are a run-lifetime ledger, not a per-cycle scalar: a cycle-1 PR must still be attributable on the pass that finally merges it"
  check t3SolverFlag true                 "B99c #603 ...and the flag is emitted on a CLEAN cycle too — corroboration is not conditional on partialness, and a row that only fired beside --partial-prs would leave every converging run guessing"
  check t4SolverFlag true                 "B99d #603 a FAILED record with no PR, and a PUSHED_NO_PR record whose prNumber is the 0 sentinel, are both excluded — pairing an issue with PR 0 would corroborate it with a number no PR can have"
  check t2WatchFlag true                  "B98e the watch relay's COMMAND LINE carries --partial-prs=901 — argv is the only channel from the JS ledger to the shell merge gate, and this is the assertion no grep over either file can make"
  check t2CollectFlag true                "B98f the collect relay's command line carries --partial-issues=11, which is what makes the convergence gate refuse"
  check t3Issues '[]'                     "B98g a fleet return whose every chain finished leaves the ledger empty"
  check t3Clean true                      "B98h ...and NEITHER flag is emitted at all on that clean path: an empty --partial-prs= is a malformed-shape exit 2 in lib/goal-watch.sh, so emitting the flag empty would halt every converging run"
  check t4Issues '[13,14]'                "B98i a record with NO chainComplete key is not partial (the single-solver path attaches the field nowhere) while a chainComplete:false sibling in the same return still is — the row cannot pass by rejecting everything"
  check t4Prs '[903]'                     "B98j a partial record that delivered NO pr contributes to the issue set and not to the PR set (0 is the fleet's no-PR sentinel, never a PR number the merge gate could match)"
  check t4CollectFlag true                "B98k ...and both partial issues reach the collect command line, comma-joined"
  check t5Reason '"solver_failed"'        "B98l a partial-chain halt reports its real reason: the collect relay reads .payload.reason off the breaker row, where uberdev_goal_audit actually writes it (the shipped .data.reason found nothing, so every Phase-3 halt degraded to the literal decision \"halt\")"
  check t5Phase '"partial_chain"'         "B98m the phase subfield travels as its OWN field — lib/goal-phase3.sh reuses the closed-set reason solver_failed and discriminates on phase, so without it the two halts are indistinguishable in the result"
  check t6Reason '"stuck_loop"'           "B98n a breaker carrying some other emitter's phase still reports its reason UNSUFFIXED — haltReason's composition is unchanged, which is what keeps the four live phase-carrying emitters' halt strings byte-identical"
  check t6Phase '"merge_barrier"'         "B98o ...with that phase surfaced separately"
  check t7Reason '"nonconvergence"'       "B98p B28/B29 semantics preserved: a breaker with no phase at all still carries its reason verbatim"
  check t7Phase '""'                      "B98q ...and reports an empty phase rather than an absent one"
  check t8Issues '[11]'                   "B98r the ledger is RUN-LIFETIME: a cycle-2 fleet with every chain finished does not clear the cycle-1 partial delivery"
  check t8Prs '[901]'                     "B98s ...nor its PR — lib/goal-watch.sh re-discovers PRs from gh each pass and lib/goal-phase3.sh truncates the batch registry at loop-back, so a set that reset with the cycle would go silent exactly when the run is closest to converging"
  check t8Cycle2Issues '[]'               "B98t while the cycle-2 RECORD still reports that cycle's own empty set — the two are observable separately, so neither can be mistaken for the other"
  check t8Cycle2Carried true              "B98u and cycle 2's own relay command lines still carry both flags"

  check uSpend '"match"'                  "B91 the per-cycle spend accumulator is charged for the fleet it ran: agentsSpent is the four driver relays plus the two batched fleet relays plus the per-issue fleet cost at the DEFAULT budget (nothing in tests/ read agentsSpent at all before this row; at the default this total cannot tell the envelope-derived per-issue term from a literal, which needs a raised-budget row of its own)"
  check vParity '"match"'                 "B92 a fleet that THREW is charged the same estimate as a fleet that ran — the catch arm is not free, and CB1 is never handed a ceiling to compare against a spend that never happened"
  check vLedger '"ok"'                    "B93 the unmeasurable cycle is NAMED, not inferred from a total that is quietly short: fleet=threw on the cycle, fleet_spend_unmeasured carries the estimate actually charged and the claimed count, and fleet_threw carries the cause"

  check wRaised '"match"'                 "B94 the per-issue fleet term is DERIVED from the relayed envelope, not typed: a raised implementBudget is charged at the raised budget — the only assertion in the repo that separates the shipped derivation from the hardcoded 30 it replaced, because at the default budget the two agree exactly and every other row here runs at the default"
  check xFloor '"match"'                  "B95a a relayed budget BELOW the fleet floor is charged at the floor the fleet would clamp it to, not as relayed"
  check xCeiling '"match"'                "B95b a relayed budget ABOVE the fleet ceiling is charged at the ceiling, so reading the envelope cannot make the ledger overcount either"
  check xUnreadable '"match"'             "B95c a non-numeric implementBudget is charged the fleet default, not read as a budget of zero"
  check xAbsent '"match"'                 "B95d an envelope carrying no implementBudget at all is charged the fleet default"

  check yCeiling '"ok"'                   "B96 CB1 halts cycle 2 ONLY BECAUSE cycle 1 was charged — the spent half of the ceiling comparison, which every earlier CB1 row (M/M2/S) leaves at zero and so cannot exercise: the audit event publishes the cycle-1 spend AND the cycle-2 projection, and with the fleet charge removed the same ceiling never trips at all"
  check yHeadroom '"ok"'                  "B96b one more agent of headroom and the same run claims cycle 2 instead — the ceiling row cannot pass on a breaker that fired early, nor on a run that ended some other way"
  check vWatched '"ok"'                   "B97 a nested fleet that THREW is charged but does not abort the cycle: the watch pass still runs, so solvers that already pushed a PR are still driven to merge and the claims are still reconciled, and the run finishes converged rather than halted"
  check vNestedCalls 1                    "B97b the nested call is RECORDED even though it threw, so no call-count assertion in this file is silently conditional on the fleet succeeding"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
