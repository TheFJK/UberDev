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
#       breaker, a rollover blocking convergence, a refused fleet envelope, and
#       a budget throw still routing through finalize.
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

FIXTURE_OUT="$(node -e '
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

function fleetEnvelope(issues) {
  return JSON.stringify({ v: 1, run_id: "RID", now_epoch: 1767225600,
    now_iso: "2026-01-01T00:00:00Z", plugin_root: "/p", repo_root: "/r", cwd: "/r",
    pipeline: "solve-fleet",
    config: { runId: "RID", issues: (issues === undefined ? "11,12" : issues), concurrency: 6 } });
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
    queue: "", fingerprints: "", reason: "", note: "" }, o || {});
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
  //     = 3 (claim/collect/verdict relays) + maxWatchTicks(40) + 2 + 2 * 30
  //     = 105,   where 30 = the fleet 6 design agents + IMPLEMENT_AGENT_BUDGET(24)
  // so 104 must trip and 105 must not. Change the per-issue cost without
  // changing this number and B52/B52b go red, which is the point.
  //
  // The flat term is 2, not 1 (#515): the fleet spends a batched PR-claim
  // verification relay alongside its intake relay, once per fleet run rather
  // than per issue.
  const CYCLE_PROJECTION = 3 + 40 + 2 + (2 * 30);   // 105
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
  // MUTATION-SENSITIVE by construction. Default fixture: 2 queued issues,
  // maxParallel 3, maxWatchTicks 40. Old projection 3 + 40 + 1 + 14 = 58, and
  // 58 > 58 is false, so it does NOT trip. New projection 3 + 40 + 2 + 14 = 59,
  // which does. Run M above (maxAgents 3) trips under both and can never catch
  // a stale formula.
  const recS = await run(buildArgs({ maxAgents: 58 }), { agentReturns: {
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
  // downstream (goal-pipeline/workflow.js :585 is its only other mention). So
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
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
