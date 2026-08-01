/* META-BEGIN */
export const meta = { "name": "goal-pipeline", "description": "Workflow-native convergence driver for /uberdev:goal (RFC 0015 §5). Owns the cycle loop in JS variables that span the whole run — queue, cycle counter, per-cycle records and fingerprints — and drives each cycle through four relay-run shell phases: lib/goal-phase1.sh claims the issues, ONE nested workflow() call into skills/solve-fleet/workflow.js solves the whole cycle, lib/goal-watch.sh polls the merge lane under its documented 0/42/1 exit contract, and lib/goal-phase3.sh collects the next queue. Replaces the per-issue detached claude-bg dispatch that used to live in the goal-pipeline SKILL.md fences.", "phases": ["dispatch", "watch", "collect", "finalize"], "whenToUse": "Invoked verbatim by skills/goal-pipeline/SKILL.md after lib/goal-phase0.sh emits the args envelope between WORKFLOW_ARGS_BEGIN/WORKFLOW_ARGS_END." };
/* META-END */

// skills/goal-pipeline/workflow.js — RFC 0015 §5 (the /goal half of the
// claude-bg retirement).
//
// WHY THIS EXISTS, STRUCTURALLY.
// /goal used to be five ```bash fences in a SKILL.md. The Claude-Code Bash tool
// gives each fence its OWN shell, so nothing survived a phase boundary: not the
// cycle counter, not the rollover queue, not the candidate set, not a trap, not
// a PID. Every bug this pipeline has shipped in that shape is a variant of that
// one fact — the false-converge (candidates rehydrated empty), the rollover
// wipe (queue overwritten instead of merged), the dead circuit breakers (a
// counter that reset every pass). Patching them individually kept working until
// the next variable died.
//
// Here the queue, the cycle counter, the per-cycle records (each carrying that
// cycle's candidate count) and the fingerprint history are ORDINARY JS
// VARIABLES that live for the whole run. The class is gone by construction, not
// by another guard.
//
// THE ONE NESTING LEVEL, AND WHERE IT IS SPENT.
// workflow() nesting is one level deep. It is spent on ONE call per cycle into
// skills/solve-fleet/workflow.js for the WHOLE cycle — never one per issue. The
// fleet script already fans out internally (waves of `concurrency`, one
// worktree-isolated solver each, plus the research/spec/plan chain for
// medium/large tiers). A nested call per issue would burn the single level on
// the wrong thing and the fleet's own agents could not run at all. There is no
// solve-one.js and there must not be one.
//
// WHAT THE SCRIPT NEVER DOES.
// It never decides a trust colour, and it never lets an agent report one. The
// merge lane, the verdict reads and the convergence calculus all run in
// lib/goal-*.sh under the same helpers the fence era used; agents are MECHANICAL
// RELAYS that run a script and report its exit status verbatim. The one place a
// verdict is surfaced (the per-cycle summary) hands the verdict PATH to a relay
// running `uberdev_goal_read_trust_signal` and consumes that helper's stdout.
//
// Carrier contract (tests/workflow-scripts.test.sh + tests/_workflow_harness.js):
//   T1 — node --check --input-type=module; self-contained; no Node/FS APIs, no
//        nondeterministic clock/random globals; <=512 KB.
//   T2 — pure-JSON meta literal between the META markers; every phase()/
//        opts.phase string declared in meta.phases.
//   T3 — async-IIFE-wrappable; runs under the harness stubs (behavioral fixture
//        in tests/goal-workflow.test.sh).
//   T4 — no // === SHARED:<name> === block here (no agent-derived string is
//        ever embedded in a downstream prompt; see ENVELOPE DISCIPLINE below).
//
// ENVELOPE DISCIPLINE (DR-5). Every value this script interpolates into a
// prompt is script-derived: absolute paths built from the launcher's own
// pluginRoot/tmpDir, a digit-validated goal id, digit-validated issue numbers,
// and closed-enum scalars. Issue titles and bodies are NEVER read here. The one
// agent-RETURNED structure the script consumes — the solve-fleet args envelope
// — is validated for shape and pipeline identity before it is handed to
// workflow(), and it is never spliced into a prompt string.
//
// DR-7: wall-clock arrives FROZEN in args (now_iso). The runtime forbids clocks
//       and timers in the script, so every wall-clock bound this pipeline needs
//       lives in the shell scripts (lib/goal-watch.sh's budget gate, the 4h
//       stuck_loop) and every in-script bound is a COUNTER. That is why the
//       watch stage is a bounded `for` and not a poll-until-done.
// DR-8: the whole run is wrapped in main()'s try/catch routing to emitResult(),
//       so a budget throw (or any relay-chain throw) still returns structure.

// args envelope (uberdev_emit_workflow_args, RFC 0012 §4.3): reserved keys
// (run_id, plugin_root, repo_root, cwd) + locked v/now_*/pipeline sit
// top-level; everything lib/goal-phase0.sh emits lands under .config.
// === SHARED:args-envelope v1 ===
// The runtime hands `args` to a scriptPath workflow as a JSON **string**, not a
// parsed object (probed live 2026-07-31: `typeof args === "string"`). Every
// script here previously guarded with `typeof args === "object"`, so `args`
// fell through to `{}` and the whole pipeline SILENTLY no-opped — returning
// success, zero agents, empty result. That is the worst failure mode there is,
// and it affected every migrated pipeline at once.
//
// Accept BOTH shapes: a future runtime (or the test harness) may hand over a
// real object, and a script must not care which. A string that does not parse
// is treated as absent rather than thrown on, so the script still reaches its
// own explicit "nothing to do" guard and reports it, instead of dying in the
// prologue where there is no structured result yet.
function _uberdevNormalizeArgs(raw) {
  var v = raw;
  if (typeof v === "string") {
    try { v = JSON.parse(v); } catch (e) { return {}; }
  }
  return (v && typeof v === "object") ? v : {};
}
// === END SHARED ===
const A = _uberdevNormalizeArgs(args);
const CFG = (A.config && typeof A.config === "object") ? A.config : {};

const runId = A.run_id || "";
const pluginRootAbs = String(CFG.pluginRootAbs || A.plugin_root || "");
const repoRootAbs = String(CFG.repoRootAbs || A.repo_root || "");
const tmpDirAbs = String(CFG.tmpDirAbs || "");
const nowIso = String(CFG.timestampIso || A.now_iso || "");
const backend = String(CFG.backend || "workflow");
const resumed = CFG.resumed === true || CFG.resumed === "true";
const onlyMine = CFG.onlyMine === true || CFG.onlyMine === "true";

// goalId is used to build shell arguments, so it is validated against the same
// shape lib/goal-state.sh's _uberdev_goal_validate_id enforces. An id that
// fails this check is fatal: every sidecar path is derived from it.
const goalIdRaw = String(CFG.goalId || "");
const goalId = /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(goalIdRaw) ? goalIdRaw : "";

const maxCycles = clampInt(CFG.maxCycles, 1, 20, 5);
const maxParallel = clampInt(CFG.maxParallel, 1, 10, 3);
const maxAgents = clampInt(CFG.maxAgents, 1, 2000, 250);
// The watch stage is bounded by a COUNTER, never by a clock (DR-7). Each tick
// is one lib/goal-watch.sh invocation, which itself honours the
// watchPasses/watchBudgetS bound lib/goal-phase0.sh resolved.
const maxWatchTicks = clampInt(CFG.maxWatchTicks, 1, 500, 40);
// lib/goal-phase0.sh resolves this (0 = the legacy unbounded watch loop). It is
// what sizes the Bash-tool timeout the watch relay is told to ask for: ONE
// lib/goal-watch.sh invocation runs for up to watchBudgetS before it exits 42.
const watchBudgetS = clampInt(CFG.watchBudgetS, 0, 86400, 0);
// The Bash tool's default timeout is 120 s, and lib/goal-phase0.sh defaults the
// watch budget to 480 s under the Claude-Code runtime — so the DEFAULT relay
// call outlives the DEFAULT tool timeout by 6x, and a timed-out call delivers
// no exit status at all (the 0/42/1 contract cannot survive it). The relay is
// therefore told the exact timeout to pass. +120 s of headroom covers one
// worst-case serial gh walk past the budget; 600000 ms is the tool's own cap.
const watchTimeoutMs = clampInt(
  ((watchBudgetS > 0 ? watchBudgetS : 480) + 120) * 1000, 120000, 600000, 600000);

const issuesFromArgs = String(CFG.issues || "")
  .split(",").map(function (s) { return s.trim(); }).filter(function (s) {
    return /^[0-9]+$/.test(s);
  });

// The bash >= 4 EXECUTION CONTRACT for the relay-run phase scripts (issue
// #294). lib/goal-phase0.sh's resolver re-execs ITSELF under a bash >= 4, which
// fixes phase 0 and nothing else: Phases 1/2/3 are separate processes launched
// from the relay prompts below. PATH `bash` is 3.2 on stock macOS, where
// lib/goal-watch.sh dies on `active_issues[@]: unbound variable` — a non-0/42
// status the driver would report as haltReason="watch_script_error" on cycle 1.
// So phase 0 publishes its resolved interpreter as config.bashBin and every
// relay command below runs under it. Only an absolute path of shell-safe
// characters is accepted; anything else degrades to PATH `bash` rather than
// letting an unvalidated string reach a command line.
const bashBinRaw = String(CFG.bashBin || "");
const bashBin = /^\/[A-Za-z0-9._/+-]+$/.test(bashBinRaw) ? bashBinRaw : "bash";

// One command word for a phase script, under the resolved interpreter.
function bashCmd(scriptPath) {
  return '"' + bashBin + '" "' + scriptPath + '"';
}

const solveFleetJs = pluginRootAbs + "/skills/solve-fleet/workflow.js";
const phase1Sh = pluginRootAbs + "/lib/goal-phase1.sh";
const watchSh = pluginRootAbs + "/lib/goal-watch.sh";
const phase3Sh = pluginRootAbs + "/lib/goal-phase3.sh";
const launcherSh = pluginRootAbs + "/lib/solve-launcher.sh";
const stateSh = pluginRootAbs + "/lib/goal-state.sh";

function clampInt(v, lo, hi, dflt) {
  var n = (typeof v === "number") ? v : parseInt(v, 10);
  if (typeof n !== "number" || n !== n) return dflt; // NaN guard (no isNaN dep)
  n = Math.floor(n);
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

function digitsOnly(list) {
  return (Array.isArray(list) ? list : [])
    .map(function (v) { return String(v).trim(); })
    .filter(function (s) { return /^[0-9]+$/.test(s); });
}

// The relays return comma-joined scalars (the shell prints one compact JSON
// line; the schema keeps every list a string so an agent cannot smuggle a
// nested object through a typed array).
function csvToList(s) {
  return digitsOnly(String(s || "").split(","));
}

// A shell-safe env prefix for every relay command. Script-derived only.
function envPrefix() {
  return 'CLAUDE_PLUGIN_ROOT="' + pluginRootAbs + '" '
    + 'UBERDEV_PLUGIN_ROOT="' + pluginRootAbs + '" '
    + 'UBERDEV_TMPDIR="' + tmpDirAbs + '" '
    + 'UBERDEV_GOAL_ID="' + goalId + '" '
    + 'UBERDEV_RESOLVED_BACKEND="' + backend + '" '
    // Forwarded so anything the phase scripts shell out to inherits the same
    // interpreter contract they are themselves launched under.
    + 'UBERDEV_GOAL_BASH="' + bashBin + '" ';
}

// ---- schemas (DR-4: structured returns, enums closed, counts integers) ----
const S = {
  claim: {
    type: "object", additionalProperties: false,
    required: ["rc", "dispatch", "rollover", "skipped"],
    properties: {
      rc: { type: "integer", description: "exit status of lib/goal-phase1.sh" },
      dispatch: { type: "string", description: "comma-joined issue numbers claimed this cycle" },
      rollover: { type: "string", description: "comma-joined issue numbers deferred past --max-parallel" },
      skipped: { type: "string", description: "comma-joined issue numbers that lost a claim race" },
      launcherRc: { type: "integer" },
      fleetArgsJson: { type: "string", description: "verbatim JSON between WORKFLOW_ARGS_BEGIN/END, or empty" },
      armed: { type: "string", description: "comma-joined issue numbers the launcher accepted" },
      markRc: { type: "integer", description: "exit status of the STEP 3 --mark-solving/--mark-failed reconciliation pass" },
      note: { type: "string", description: "one line, <=300 chars" },
    },
  },
  watch: {
    type: "object", additionalProperties: false,
    required: ["rc"],
    properties: {
      rc: { type: "integer", description: "0 drained, 42 re-invoke, 1 halt, other = script error, -1 = no status (timed out)" },
      timedOut: { type: "boolean", description: "true ONLY when the Bash call itself timed out before the script reported a status" },
      note: { type: "string", description: "the last diagnostic line the script printed, <=300 chars" },
    },
  },
  collect: {
    type: "object", additionalProperties: false,
    required: ["rc", "decision"],
    properties: {
      rc: { type: "integer" },
      decision: { type: "string", enum: ["converged", "loop", "halt", "state_error"] },
      candidates: { type: "integer" },
      queued: { type: "integer" },
      queue: { type: "string", description: "comma-joined issue numbers surviving into the next cycle" },
      fingerprints: { type: "string", description: "comma-joined 16-hex fingerprints seen this cycle" },
      reason: { type: "string", description: "the circuit-breaker reason when decision=halt, else empty" },
      note: { type: "string", description: "<=300 chars" },
    },
  },
  verdicts: {
    type: "object", additionalProperties: false,
    required: ["rows"],
    properties: {
      rows: {
        type: "array", maxItems: 200,
        items: {
          type: "object", additionalProperties: false,
          required: ["pr", "signal"],
          properties: {
            pr: { type: "integer" },
            // CONTRACT: trust-signal
            signal: { type: "string", enum: ["green", "yellow", "red", "stale", "missing"] },
          },
        },
      },
    },
  },
};

// ------------------------------- prompts -------------------------------
// Every prompt below interpolates ONLY script-derived values, and every one of
// them is a MECHANICAL RELAY brief: run the command, report what it printed.

function claimPrompt(cycleNo) {
  return "You are a mechanical relay for one /uberdev:goal cycle. Run the commands below EXACTLY as written, "
    + "in order, via Bash. Do not interpret, summarise or repair their output, and do not run anything else.\n\n"
    + "STEP 1 — claim the cycle's issues:\n\n"
    + "  " + envPrefix() + bashCmd(phase1Sh) + " --goal-id=" + goalId + "\n\n"
    + "It prints ONE JSON line: {\"phase\":\"claim\",\"goal_id\":...,\"cycle\":N,\"dispatch\":\"<csv>\","
    + "\"rollover\":\"<csv>\",\"skipped\":\"<csv>\",\"claimed\":N,\"rc\":0}. Record its exit status as rc and "
    + "copy dispatch/rollover/skipped VERBATIM.\n\n"
    + "If rc is non-zero, or `dispatch` is empty, STOP HERE: return rc, dispatch, rollover, skipped, "
    + "launcherRc 0, fleetArgsJson \"\", armed \"\", markRc 0.\n\n"
    + "STEP 2 — arm the solver fleet for exactly the claimed set (substitute <ISSUES> with the SPACE-separated "
    + "issue numbers from `dispatch`):\n\n"
    + "  " + envPrefix() + "AUTO_MODE=1 " + bashCmd(launcherSh)
    + " --auto-mode=1 --turbo -- <ISSUES> --backend=workflow --force\n\n"
    + "`--backend=workflow` makes the launcher write its manifest and print an args envelope INSTEAD of "
    + "dispatching anything itself. `--force` is required and is not a shortcut: STEP 1 already took the "
    + "`uberdev:active` claim for these issues on this run's behalf, so the launcher's own claim pass would "
    + "otherwise refuse them as a collision with us.\n\n"
    + "Record the launcher's exit status as launcherRc. Copy the JSON between the WORKFLOW_ARGS_BEGIN and "
    + "WORKFLOW_ARGS_END markers into fleetArgsJson VERBATIM — one line, byte for byte, no re-indentation, "
    + "no key reordering, nothing added or removed. If the markers are absent, set fleetArgsJson to \"\".\n\n"
    + "STEP 3 — reconcile the issue state with what actually happened:\n\n"
    + "  if the launcher succeeded (launcherRc 0 AND fleetArgsJson non-empty):\n"
    + "    " + envPrefix() + bashCmd(phase1Sh) + " --goal-id=" + goalId + " --mark-solving=<CSV>\n"
    + "  otherwise:\n"
    + "    " + envPrefix() + bashCmd(phase1Sh) + " --goal-id=" + goalId + " --mark-failed=<CSV>\n\n"
    + "where <CSV> is the comma-separated `dispatch` list. Set armed to that same list on the success path "
    + "and to \"\" otherwise. Record the exit status of whichever STEP 3 command you ran as markRc "
    + "(0 if STEP 1 stopped you before reaching STEP 3) — a non-zero markRc means a state transition did "
    + "NOT land, which the driver must see; do not repair it and do not re-run the command.\n\n"
    + "Return via StructuredOutput: rc, dispatch, rollover, skipped, launcherRc, fleetArgsJson, armed, markRc, "
    + "and note (one line naming what failed, if anything). This is cycle " + cycleNo + " of at most "
    + maxCycles + ".";
}

function watchPrompt(cycleNo, tickNo) {
  // UBERDEV_GOAL_SOLVERS_SETTLED=1 is load-bearing, not decoration. The
  // nested fleet call is AWAITED before this stage runs, so every solver in the
  // cycle has already returned. It tells lib/goal-watch.sh to classify a
  // no-PR issue as terminal immediately instead of sitting on the 150-minute
  // detached-solver liveness timeout, which cannot say anything new here.
  return "You are a mechanical relay. Run EXACTLY this command via Bash and report its numeric exit status. "
    + "Pass timeout: " + watchTimeoutMs + " to the Bash tool — this call is EXPECTED to run for up to "
    + (watchBudgetS > 0 ? watchBudgetS : 480) + " seconds, which is far longer than the tool's default "
    + "timeout, and a timed-out call returns no exit status at all:\n\n"
    + "  " + envPrefix() + "UBERDEV_GOAL_SOLVERS_SETTLED=1 " + bashCmd(watchSh) + " --goal-id=" + goalId + "\n\n"
    + "This is the /uberdev:goal watch pass (cycle " + cycleNo + ", tick " + tickNo + " of at most "
    + maxWatchTicks + "). It polls GitHub, drives the PR state machine and the merge barrier, and exits "
    + "with ONE of three documented codes:\n"
    + "  0  — the cycle drained (no active solvers, no merging PR)\n"
    + "  42 — still working; the pass/budget bound was reached and it should be re-invoked\n"
    + "  1  — a circuit breaker fired, or a run-state flush failed\n\n"
    + "Report the status EXACTLY as the shell reported it. Do NOT interpret it, do NOT decide whether the "
    + "goal is done, do NOT re-run the command, and do NOT run any other command. If the script ran and the "
    + "shell reported a status outside 0/42/1, report THAT status verbatim and leave timedOut false.\n\n"
    + "TIMEOUT CONTRACT: if the Bash call itself is killed by the tool's timeout — i.e. you receive a timeout "
    + "notice instead of an exit status — set timedOut true and rc -1. Do NOT invent a status, do NOT retry, "
    + "and do NOT report 0. The script installs a TERM handler that persists run-state before it dies, so the "
    + "driver re-ticks a timed-out pass; a fabricated 0 would tell it the cycle drained.\n\n"
    + "Return via StructuredOutput: rc (the integer exit status, or -1 when timedOut), timedOut (false unless "
    + "the tool timed the call out) and note (the LAST line the script wrote to stderr, verbatim, truncated "
    + "to 300 characters).";
}

function collectPrompt(cycleNo) {
  return "You are a mechanical relay. Run EXACTLY this command via Bash and report what it printed:\n\n"
    + "  " + envPrefix() + bashCmd(phase3Sh) + " --goal-id=" + goalId + "\n\n"
    + "This is the /uberdev:goal collect pass for cycle " + cycleNo + ". It enumerates the cycle's new "
    + "BLOCKER/CRITICAL `review-pr-finding` issues, runs the fingerprint-repeat detector, applies the "
    + "overflow truncation, and evaluates the terminal gates. It prints ONE JSON line "
    + "{\"phase\":\"collect\",...,\"decision\":\"converged|loop|halt|state_error\",\"rc\":N,"
    + "\"candidates\":N,\"queued\":N,\"queue\":\"<csv>\"} and exits 0 (converged) / 42 (loop back) / 1 (halt) "
    + "/ 3 (state error).\n\n"
    + "Copy decision, rc, candidates, queued and queue from that line VERBATIM — do not recompute them and do not "
    + "second-guess the decision. For `reason`, if and only if the decision is `halt`, report the `.data.reason` "
    + "field of the LAST goal_circuit_breaker row in \"" + tmpDirAbs + "/goal-" + goalId + ".jsonl\" "
    + "(read it with `tail`); otherwise report \"\". For `fingerprints`, report the comma-joined 16-hex "
    + "fingerprints in \"" + tmpDirAbs + "/goal-" + goalId + "-fingerprints.tsv\" whose cycle column equals "
    + cycleNo + ", or \"\" if the file is absent.\n\n"
    + "Return via StructuredOutput: rc, decision, candidates, queued, queue, fingerprints, reason, note.";
}

function verdictPrompt(cycleNo) {
  // The verdict colour is NEVER an LLM judgement. The relay hands each located
  // verdict PATH to uberdev_goal_read_trust_signal and reports that helper's
  // stdout; the enum in S.verdicts is the helper's own closed return set.
  return "You are a mechanical relay. Run EXACTLY this via Bash and report the lines it prints:\n\n"
    + "  " + envPrefix() + '"' + bashBin + '" -c \'. "' + stateSh + '"; '
    + 'while IFS="\t" read -r pr rest; do case "$pr" in ""|*[!0-9]*) continue ;; esac; '
    + 'printf "%s\\t%s\\n" "$pr" "$(uberdev_goal_read_trust_signal "$(uberdev_goal_locate_review_pr_audit_by_pr "$pr")")"; '
    + 'done < "' + tmpDirAbs + "/goal-" + goalId + '-pr-states.tsv" | sort -u\'\n\n'
    + "Each output line is `<pr-number><TAB><signal>` where signal is one of green, yellow, red, stale, "
    + "missing — produced by the `uberdev_goal_read_trust_signal` shell helper, NOT by you. Do not read the "
    + "PR, the diff, or any review file, and do not form an opinion about any PR's quality: copy the helper's "
    + "output. If the state file does not exist, return an empty rows array.\n\n"
    + "This is the cycle-" + cycleNo + " verdict snapshot for the run summary.\n\n"
    + "Return via StructuredOutput: rows (one object per output line: pr as an integer, signal as the string).";
}

// ----------------------------- run state -----------------------------
// These live for the WHOLE run. That is the entire structural point of this
// script: in the fence era each of them died at a phase boundary and had to be
// round-tripped through a sidecar, and every skipped round-trip was a silent
// false-converge or a stranded queue.
let cycle = 1;
let queue = issuesFromArgs.slice();       // the rollover queue, carried across cycles
const fingerprintHistory = {};             // fingerprint -> first cycle seen
const cycleRecords = [];
const auditEvents = [];
const nullsByPhase = {};
let verdictRows = [];
let cb1Tripped = false;                    // projected-agent ceiling
let cb2Tripped = false;                    // budget floor
let cbWatchTicks = false;                  // watch never settled within the tick bound
let halted = false;
let haltReason = "";
let converged = false;
let agentsSpent = 0;
let fleetRuns = 0;

function noteNull(phaseName) {
  nullsByPhase[phaseName] = (nullsByPhase[phaseName] || 0) + 1;
}

function finalize() {
  return {
    runId: runId,
    goalId: goalId,
    backend: backend,
    resumed: resumed,
    onlyMine: onlyMine,
    requestedIssues: issuesFromArgs.map(Number),
    cyclesRun: cycleRecords.length,
    maxCycles: maxCycles,
    maxParallel: maxParallel,
    converged: converged,
    halted: halted,
    haltReason: haltReason,
    queueRemaining: queue.slice().map(Number),
    fleetRuns: fleetRuns,
    agentsSpent: agentsSpent,
    cycles: cycleRecords,
    verdicts: verdictRows,
    repeatedFingerprints: Object.keys(fingerprintHistory).filter(function (fp) {
      return fingerprintHistory[fp].count > 1;
    }),
    cb1Tripped: cb1Tripped,
    cb2Tripped: cb2Tripped,
    cbWatchTicks: cbWatchTicks,
    nullsByPhase: nullsByPhase,
    auditEvents: auditEvents,
  };
}

// emitResult logs the full result as ONE structured line (the §4.6
// observability channel + the T3-fixture assertion seam) and returns it. Used
// on EVERY return path — the converged path, every breaker, and the DR-8 throw
// path — so an abort is exactly as observable as a clean finish.
function emitResult() {
  const result = finalize();
  log("WORKFLOW_RESULT " + JSON.stringify(result));
  return result;
}

function budgetExhausted() {
  return budget && budget.total && budget.remaining() <= 0;
}

// Projected agents for ONE cycle: the claim relay, up to maxWatchTicks watch
// relays, the collect relay, the verdict relay — plus what the nested fleet
// will spend (its own intake relay, one solver per issue, and at most the six
// research/design agents a medium-tier issue costs).
function projectedAgentsForCycle(issueCount) {
  return 3 + maxWatchTicks + 1 + (issueCount * 7);
}

// The fleet args envelope arrives as an agent-returned STRING. It is the only
// agent-derived structure this script consumes, so it is validated before it
// reaches workflow(): it must parse, it must be an object, it must declare
// itself as the solve-fleet pipeline, and — the load-bearing check — its issue
// set must be EXACTLY the set lib/goal-phase1.sh claimed this cycle.
//
// WHY THE SET CHECK IS NOT OPTIONAL. The relay arms the launcher with
// `--force`, which by its own documentation bypasses the launcher's
// `uberdev:active` collision guard, because STEP 1 already took that claim on
// this run's behalf. That is only safe while the armed set and the claimed set
// are the same set — and the armed set is produced by an agent copying a CSV by
// hand. solve-fleet's own intake cross-check compares the envelope against the
// manifest the SAME launcher call wrote, so it cannot catch a mis-copied list
// either. This is the only place both sides exist: the claim script's stdout,
// and the envelope. A mismatch means solvers would be armed on an issue nobody
// claimed (or a claimed issue would be silently dropped), so it is refused.
//
// Returns the parsed envelope, or a STRING reason for the refusal.
function parseFleetArgs(raw, claimedList) {
  if (typeof raw !== "string" || raw.length === 0) return "no_envelope";
  let parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return "unparseable";
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return "not_an_object";
  if (parsed.pipeline !== "solve-fleet") return "wrong_pipeline";
  if (!parsed.config || typeof parsed.config !== "object") return "no_config";
  const envelopeIssues = csvToList(parsed.config.issues).slice().sort().join(",");
  const claimedIssues = digitsOnly(claimedList).slice().sort().join(",");
  if (envelopeIssues !== claimedIssues) return "issue_set_mismatch";
  return parsed;
}

async function runCycle() {
  const rec = {
    cycle: cycle, claimed: [], rollover: [], skipped: [], armed: [],
    fleet: "not-run", watchTicks: 0, watchRc: null, decision: "", reason: "",
    candidates: 0,
  };

  // ------------------------------ dispatch ------------------------------
  phase("dispatch");
  const projected = projectedAgentsForCycle(Math.min(queue.length, maxParallel));
  if (agentsSpent + projected > maxAgents) {
    cb1Tripped = true;
    halted = true;
    haltReason = "agent_ceiling";
    auditEvents.push({ event: "agent_ceiling_cb1", cycle: cycle, projected: projected,
      spent: agentsSpent, maxAgents: maxAgents, ts: nowIso });
    log("CB1: cycle " + cycle + " would project " + projected + " more agents on top of " + agentsSpent
      + ", exceeding maxAgents=" + maxAgents + " — halting BEFORE the claim pass so no issue is claimed "
      + "and left unsolved.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  const claim = await agent(claimPrompt(cycle),
    { model: "haiku", phase: "dispatch", label: "goal-claim:c" + cycle, schema: S.claim });
  agentsSpent += 1;
  if (claim === null) {
    noteNull("dispatch");
    halted = true;
    haltReason = "claim_relay_null";
    auditEvents.push({ event: "claim_relay_null", cycle: cycle, ts: nowIso });
    log("cycle " + cycle + ": the claim relay returned nothing — halting rather than watching a cycle that "
      + "may or may not have claimed issues.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  rec.claimed = csvToList(claim.dispatch);
  rec.rollover = csvToList(claim.rollover);
  rec.skipped = csvToList(claim.skipped);
  rec.armed = csvToList(claim.armed);
  // The rollover the claim pass computed is authoritative for the next cycle:
  // it is what lib/goal-phase1.sh flushed into run-state.
  queue = rec.rollover.slice();

  if (claim.rc !== 0) {
    halted = true;
    haltReason = "claim_failed";
    auditEvents.push({ event: "claim_failed", cycle: cycle, rc: claim.rc, ts: nowIso });
    log("cycle " + cycle + ": lib/goal-phase1.sh exited " + claim.rc + " — halting.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  // STEP 3's reconciliation rc, checked BEFORE the fleet is spawned. A non-zero
  // markRc means a `dispatched -> solving` transition did not land, so the
  // issue's TSV row is stuck at `dispatched` — and lib/goal-watch.sh's
  // `solving -> pr-pushed` arc can then never apply for it. any_active would
  // stay 1 for the rest of the cycle and the run would burn every watch tick to
  // a `watch_tick_ceiling` halt that names the wrong cause. Halt here instead,
  // with the real reason, before spending a fleet on issues the state machine
  // has already lost track of. The claims and the on-disk state survive:
  // `/uberdev:goal --resume` (or lib/goal-abort.sh) is the recovery.
  const markRc = (typeof claim.markRc === "number") ? claim.markRc : 0;
  if (markRc !== 0) {
    halted = true;
    haltReason = "mark_reconcile_failed";
    rec.markRc = markRc;
    auditEvents.push({ event: "mark_reconcile_failed", cycle: cycle, markRc: markRc,
      claimed: rec.claimed.slice(), ts: nowIso });
    log("cycle " + cycle + ": the post-arm reconciliation pass (lib/goal-phase1.sh --mark-solving/"
      + "--mark-failed) exited " + markRc + " — at least one issue state transition did not land, so the "
      + "watch pass could never drive those issues to a terminal state. Halting before arming the fleet.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  if (rec.claimed.length > 0) {
    const fleetArgs = parseFleetArgs(claim.fleetArgsJson, rec.claimed);
    if (typeof fleetArgs === "string") {
      rec.fleet = "args-refused";
      rec.fleetRefusal = fleetArgs;
      auditEvents.push({ event: "fleet_args_refused", cycle: cycle, reason: fleetArgs,
        claimed: rec.claimed.slice(),
        launcherRc: (typeof claim.launcherRc === "number" ? claim.launcherRc : -1), ts: nowIso });
      // Where the claims end up differs by reason, and saying it wrong would
      // send an operator looking for a leak that is not there. `no_envelope`
      // means the launcher itself failed, so the relay's STEP 3 already took
      // the --mark-failed branch and released them. Every other reason means
      // the launcher SUCCEEDED and STEP 3 marked them `solving` — those are
      // reclaimed by the watch pass below, which runs with
      // UBERDEV_GOAL_SOLVERS_SETTLED=1 and so classifies a no-PR issue as
      // failed (releasing its claim) on the first tick instead of waiting out
      // the 150-minute detached-solver timeout.
      log("cycle " + cycle + ": the launcher produced no usable solve-fleet args envelope (" + fleetArgs
        + ") — NOT dispatching a fleet this cycle. "
        + (fleetArgs === "no_envelope"
            ? "The claimed issues were marked failed and released by the relay's STEP 3."
            : "The claimed issues are marked `solving` with no solver behind them; the watch pass below "
              + "runs with the settled-fleet marker, so it fails them and releases their claims this cycle."));
    } else {
      // THE one nested call. One per cycle, for the whole cycle. See the header:
      // a nested call per issue would spend the single nesting level on the
      // wrong thing and the fleet's own agents could not run.
      try {
        const out = await workflow({ scriptPath: solveFleetJs }, fleetArgs);
        fleetRuns += 1;
        agentsSpent += 1 + (rec.claimed.length * 7);
        rec.fleet = "ran";
        if (out && typeof out === "object" && Array.isArray(out.prsOpened)) {
          rec.prsOpened = digitsOnly(out.prsOpened).map(Number);
        }
      } catch (e) {
        rec.fleet = "threw";
        auditEvents.push({ event: "fleet_threw", cycle: cycle,
          reason: (e && e.message) ? e.message : String(e), ts: nowIso });
        log("cycle " + cycle + ": the nested solve-fleet workflow threw ("
          + ((e && e.message) ? e.message : String(e)) + "). The watch pass still runs — solvers that already "
          + "pushed a PR must still be driven to merge, and the claims must still be reconciled.");
      }
    }
  } else {
    rec.fleet = "no-claims";
    log("cycle " + cycle + ": nothing new to claim (every queued issue is already in flight, terminal, or "
      + "claimed by another process) — going straight to the watch pass.");
  }

  // -------------------------------- watch --------------------------------
  // A bounded `for`, not a poll-until-done: the runtime forbids timers in the
  // script (DR-7), so the LOOP COUNTER is the bound. Each tick is one
  // lib/goal-watch.sh invocation honouring its own 0/42/1 exit contract.
  phase("watch");
  let drained = false;
  for (let tick = 1; tick <= maxWatchTicks; tick++) {
    if (budgetExhausted()) {
      cb2Tripped = true;
      halted = true;
      haltReason = "budget_exhausted";
      auditEvents.push({ event: "budget_exhausted", cycle: cycle, tick: tick, ts: nowIso });
      log("CB2: token budget exhausted during the cycle-" + cycle + " watch pass — stopping. Live solvers are "
        + "left alive and the run is resumable with `/uberdev:goal --resume`.");
      rec.decision = "halt";
      rec.reason = haltReason;
      cycleRecords.push(rec);
      return false;
    }
    const w = await agent(watchPrompt(cycle, tick),
      { model: "haiku", phase: "watch", label: "goal-watch:c" + cycle + ":t" + tick, schema: S.watch });
    agentsSpent += 1;
    rec.watchTicks = tick;
    if (w === null) {
      noteNull("watch");
      auditEvents.push({ event: "watch_relay_null", cycle: cycle, tick: tick, ts: nowIso });
      // A null relay is not a verdict. Ticking again is the correct response —
      // the bound below is what stops it becoming an unbounded retry.
      log("cycle " + cycle + " tick " + tick + ": the watch relay returned nothing — re-ticking.");
      continue;
    }
    rec.watchRc = w.rc;
    // A tool-level timeout is NOT a script verdict — there is no exit status to
    // route. lib/goal-watch.sh's TERM handler persists run-state and takes the
    // same "still-active, re-invoke" interpretation (#301), so re-ticking is the
    // correct response and the tick bound below is what keeps it finite.
    // Treating it as a script error would halt the whole goal on a slow poll.
    if (w.timedOut === true) {
      rec.watchTimeouts = (rec.watchTimeouts || 0) + 1;
      auditEvents.push({ event: "watch_relay_timeout", cycle: cycle, tick: tick,
        timeoutMs: watchTimeoutMs, ts: nowIso });
      log("cycle " + cycle + " tick " + tick + ": the watch relay's Bash call timed out after "
        + watchTimeoutMs + "ms without reporting an exit status — re-ticking (the script's TERM handler "
        + "persists run-state on the way down).");
      continue;
    }
    if (w.rc === 0) { drained = true; break; }
    if (w.rc === 42) { continue; }
    // Anything else is a halt: 1 is a circuit breaker or a fail-loud run-state
    // flush failure; any other status means the script could not run at all.
    halted = true;
    haltReason = (w.rc === 1) ? "watch_breaker" : "watch_script_error";
    auditEvents.push({ event: "watch_halt", cycle: cycle, tick: tick, rc: w.rc,
      note: String(w.note || "").slice(0, 300), ts: nowIso });
    log("cycle " + cycle + ": the watch pass halted with rc=" + w.rc + " — " + String(w.note || ""));
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }
  if (!drained) {
    cbWatchTicks = true;
    halted = true;
    haltReason = "watch_tick_ceiling";
    auditEvents.push({ event: "watch_tick_ceiling", cycle: cycle, ticks: maxWatchTicks, ts: nowIso });
    log("CB3: the cycle-" + cycle + " watch pass used all " + maxWatchTicks + " ticks without draining. "
      + "Halting deterministically instead of ticking forever; the live solvers are left alive and "
      + "`/uberdev:goal --resume` picks the run back up.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  // ------------------------------- collect -------------------------------
  phase("collect");
  const verdicts = await agent(verdictPrompt(cycle),
    { model: "haiku", phase: "collect", label: "goal-verdicts:c" + cycle, schema: S.verdicts });
  agentsSpent += 1;
  if (verdicts === null) {
    noteNull("collect");
  } else if (Array.isArray(verdicts.rows)) {
    verdictRows = verdicts.rows.filter(function (r) {
      return r && Number.isInteger(r.pr) && typeof r.signal === "string";
    });
  }

  const col = await agent(collectPrompt(cycle),
    { model: "haiku", phase: "collect", label: "goal-collect:c" + cycle, schema: S.collect });
  agentsSpent += 1;
  if (col === null) {
    noteNull("collect");
    halted = true;
    haltReason = "collect_relay_null";
    auditEvents.push({ event: "collect_relay_null", cycle: cycle, ts: nowIso });
    log("cycle " + cycle + ": the collect relay returned nothing — halting rather than guessing whether the "
      + "goal converged.");
    rec.decision = "halt";
    rec.reason = haltReason;
    cycleRecords.push(rec);
    return false;
  }

  rec.decision = col.decision;
  rec.reason = String(col.reason || "");
  rec.candidates = clampInt(col.candidates, 0, 100000, 0);

  // Fingerprint bookkeeping lives HERE, in a JS object spanning the run. The
  // shell detector in lib/goal-phase3.sh is still the authority that HALTS; this
  // is the cross-cycle record that makes a repeat visible in the result even
  // when the run ends for some other reason.
  digitsFingerprints(col.fingerprints).forEach(function (fp) {
    if (!fingerprintHistory[fp]) fingerprintHistory[fp] = { first: cycle, count: 0 };
    fingerprintHistory[fp].count += 1;
    fingerprintHistory[fp].last = cycle;
  });

  cycleRecords.push(rec);

  if (col.decision === "converged") {
    converged = true;
    log("cycle " + cycle + ": CONVERGED — no new BLOCKER/CRITICAL findings and every PR is terminal.");
    return false;
  }
  if (col.decision === "loop") {
    // lib/goal-phase3.sh has already merged the candidates into the rollover
    // queue and bumped `cycle` in run-state. Mirror BOTH from what it actually
    // reported, so the JS view and the on-disk view agree: the projected-agent
    // gate at the top of the next cycle sizes itself from this queue, and a
    // stale JS view would size it from the wrong set.
    cycle += 1;
    queue = csvToList(col.queue);
    log("cycle " + rec.cycle + ": " + rec.candidates + " new candidate(s), " + col.queued
      + " issue(s) queued for cycle " + cycle + ".");
    return true;
  }
  halted = true;
  haltReason = rec.reason || col.decision;
  log("cycle " + cycle + ": halting (" + haltReason + ").");
  return false;
}

function digitsFingerprints(s) {
  return String(s || "").split(",")
    .map(function (x) { return x.trim(); })
    .filter(function (x) { return /^[a-f0-9]{16}$/.test(x); });
}

async function main() {
  log("goal " + (goalId || "<no-id>") + " run " + runId + " — " + issuesFromArgs.length
    + " issue(s) queued, max_cycles=" + maxCycles + ", max_parallel=" + maxParallel
    + ", backend=" + backend + (resumed ? ", resumed" : ""));

  try {
    if (goalId === "") {
      halted = true;
      haltReason = "invalid_goal_id";
      auditEvents.push({ event: "invalid_goal_id", ts: nowIso });
      log("preflight: the args envelope carried no usable goalId — every state sidecar path is derived from "
        + "it, so there is nothing safe to drive. Re-run lib/goal-phase0.sh.");
      return emitResult();
    }
    if (pluginRootAbs === "" || tmpDirAbs === "") {
      halted = true;
      haltReason = "invalid_paths";
      auditEvents.push({ event: "invalid_paths", ts: nowIso });
      log("preflight: pluginRootAbs/tmpDirAbs missing from the args envelope — cannot build the phase-script "
        + "commands.");
      return emitResult();
    }

    let keepGoing = true;
    while (keepGoing && cycle <= maxCycles) {
      keepGoing = await runCycle();
    }
    if (keepGoing && cycle > maxCycles) {
      // The shell gate in lib/goal-phase1.sh/lib/goal-phase3.sh is the primary
      // ceiling; this is the driver-side backstop so the JS loop can never
      // outrun it even if a relay mis-reports a decision.
      halted = true;
      haltReason = "max_cycles";
      auditEvents.push({ event: "max_cycles_driver_backstop", cycle: cycle, max: maxCycles, ts: nowIso });
      log("halt: cycle " + cycle + " exceeds max_cycles=" + maxCycles + " (driver backstop).");
    }

    phase("finalize");
    cycleRecords.forEach(function (r) {
      log("cycle " + r.cycle + ": claimed=" + r.claimed.length + " rollover=" + r.rollover.length
        + " skipped=" + r.skipped.length + " fleet=" + r.fleet + " watchTicks=" + r.watchTicks
        + " decision=" + (r.decision || "?") + (r.reason ? (" (" + r.reason + ")") : ""));
    });
    verdictRows.forEach(function (v) { log("verdict PR #" + v.pr + ": " + v.signal); });
    return emitResult();
  } catch (e) {
    auditEvents.push({ event: "run_threw",
      reason: (e && e.message) ? e.message : String(e), ts: nowIso });
    halted = true;
    haltReason = haltReason || "run_threw";
    log("goal-pipeline threw (" + ((e && e.message) ? e.message : String(e))
      + ") — finalizing with the cycles completed so far. Live solvers are untouched; "
      + "`/uberdev:goal --resume` picks the run back up.");
    return emitResult();
  }
}

// Final top-level statement: its resolved value is the workflow return value
// (the runtime wraps the body and captures main()'s return; the T3 harness IIFE
// discards it, which is why main() also log()s WORKFLOW_RESULT).
await main();
