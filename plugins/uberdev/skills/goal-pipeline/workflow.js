/* META-BEGIN */
export const meta = { "name": "goal-pipeline", "description": "Workflow-native convergence driver for /uberdev:goal (RFC 0015 §5). Owns the cycle loop in JS variables that span the whole run — queue, cycle counter, per-cycle records and fingerprints — and drives each cycle through four relay-run shell phases: lib/goal-phase1.sh claims the issues, ONE nested workflow() call into skills/solve-fleet/workflow.js solves the whole cycle, lib/goal-watch.sh polls the merge lane under its documented 0/42/1 exit contract, and lib/goal-phase3.sh collects the next queue. Replaces the per-issue detached `claude --bg` dispatch that used to live in the goal-pipeline SKILL.md fences.", "phases": ["dispatch", "watch", "collect", "finalize"], "whenToUse": "Invoked verbatim by skills/goal-pipeline/SKILL.md after lib/goal-phase0.sh emits the args envelope between WORKFLOW_ARGS_BEGIN/WORKFLOW_ARGS_END." };
/* META-END */

// skills/goal-pipeline/workflow.js — RFC 0015 §5 (the /goal half of the
// detached-session retirement).
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
// the medium tier). A nested call per issue would burn the single level on
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
// The nested fleet's CB3 per-issue implement-phase budget, relayed here by
// lib/goal-phase0.sh so the PRE-CLAIM projection can be priced against the
// budget the fleet will actually run with (#590). Phase 0 resolves it through
// the ordinary --implement-budget / UBERDEV_GOAL_IMPLEMENT_BUDGET /
// goal.implement_budget chain, defaulting to whatever
// UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET already says, and the claim relay pins
// the resolved value back onto the launcher's own command line — so the number
// projected here and the number the fleet spends are one number, not two.
// Clamped with the FLEET's triple, but as a BACKSTOP only — and the asymmetry
// is worth naming rather than papering over. The declared 4..96 range is
// refined two DIFFERENT ways along this seam: lib/goal-phase0.sh resolves the
// key through a reader that SUBSTITUTES the default for an out-of-range value,
// while this line and the fleet CLAMP to the nearest bound. Phase 0 has already
// normalised whatever reaches CFG, so this clamp can only ever fire on a relay
// that skipped that normalisation; it is defence in depth, never the thing that
// makes the projection and the arming agree. Enforcement of the declared range
// belongs to phase 0's reader, and that is the one to change if the two ends
// should ever refine alike.
const implementBudget = clampInt(CFG.implementBudget, 4, 96, 24);
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

// #592 — the issue numbers of the fleet records whose task chain stopped short.
// Returns an ARRAY, so digitsOnly() is called at its real arity: digitsOnly
// takes a list and answers [] for anything else, so a scalar call would leave
// the ledger permanently empty while every negative control still passed — a
// silent, green, total failure.
function partialIssuesFromResults(results) {
  return (Array.isArray(results) ? results : [])
    .filter(function (r) { return r && r.chainComplete === false; })
    .map(function (r) { return r.issue; });
}

// #603 — the fleet's issue->PR record, rendered as `<issue>:<pr>` pairs.
//
// WHY IT IS NEEDED AT ALL. lib/goal-state.sh's PR finder falls back to matching
// a PR's HEAD BRANCH NAME against `<type>/<issue>-`, and that arm has nothing
// behind it: a PR about an HTTP 500 error page on `fix/500-error-page` satisfies
// it exactly for issue 500, and `| max` then hands the issue to that PR even
// with the solver's own lower-numbered PR open beside it. Neither `--json`
// projection carries an author, and the claim comment records the WORKTREE
// directory name rather than the head ref, so nothing in the shell lane could
// corroborate the guess. These pairs are the evidence, and they exist in
// exactly one place: the fleet's return value, here.
//
// DERIVED FROM `results[]`, NOT FILTERED THROUGH `prsOpened`. The two answer
// different questions — `prsOpened` is "which PRs did this cycle open", this is
// "which PR belongs to which issue" — and only `results[]` carries the second.
// Riding `prsOpened` would also make a fleet return that omits it (a shape the
// #592 ingest below deliberately tolerates) lose corroboration for every issue
// in the cycle, and losing corroboration means falling back to the guess this
// exists to replace.
//
// COLLISIONS ARE DROPPED, never resolved by picking one. Two records naming the
// SAME PR number disagree about who owns it, and one issue named twice with
// different numbers disagrees with itself; corroborating either from a coin
// flip would bind an issue to a PR nobody opened for it, which is the very
// defect. Dropping leaves those issues on the head-ref guess — the pre-#603
// behaviour, and the only degradation direction that is safe here, because a
// finder that answered "no PR" would fail the issue on the first watch tick.
//
// prNumber 0 is the fleet's no-PR sentinel (PUSHED_NO_PR, FAILED, a claim the
// #515 proof pass DISPROVED and zeroed) and is excluded by the digit test plus
// the positive check: `0` is digits, so the string filter alone would let it
// through and corroborate an issue with a number no PR can have.
function solverPairsFromResults(results) {
  // Pass 1 — resolve each ISSUE to at most one PR. "" is the conflict marker: an
  // issue named twice with two different numbers disagrees with itself and gets
  // no pair at all.
  const byIssue = {};
  (Array.isArray(results) ? results : []).forEach(function (r) {
    if (!r) return;
    // digitsOnly() is this file's ONE definition of "digit string" — the helper
    // every other ingest here routes through. It trims each member and drops the
    // non-digit ones while preserving order, so a two-member result says exactly
    // what the inline pair of tests said: both halves are digit strings. Only the
    // positive check stays local, and it is what excludes the `0` no-PR sentinel.
    const pair = digitsOnly([r.issue, r.prNumber]);
    if (pair.length !== 2) return;
    const issue = pair[0];
    const pr = pair[1];
    if (Number(issue) <= 0 || Number(pr) <= 0) return;
    byIssue[issue] = (byIssue[issue] === undefined || byIssue[issue] === pr) ? pr : "";
  });
  // Pass 2 — count DISTINCT issues per PR, over the RESOLVED map rather than the
  // raw records. Counting raw occurrences would let a record repeated verbatim
  // (same issue, same PR) read as a two-issue collision and drop a pair that is
  // not in conflict with anything.
  const issuesPerPr = {};
  Object.keys(byIssue).forEach(function (i) {
    if (byIssue[i] === "") return;
    issuesPerPr[byIssue[i]] = (issuesPerPr[byIssue[i]] || 0) + 1;
  });
  return Object.keys(byIssue)
    .filter(function (i) { return byIssue[i] !== "" && issuesPerPr[byIssue[i]] === 1; })
    .map(function (i) { return i + ":" + byIssue[i]; });
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
      // #592 — the SAME row's `phase` subfield, and a separate field on purpose.
      // lib/goal-phase3.sh's partial-chain refusal reuses the closed-set reason
      // `solver_failed` and discriminates on `phase` (GOAL_CIRCUIT_BREAKER_REASONS
      // is closed by RFC 0005 §9), so without this the two halts are one string.
      phase: { type: "string", description: "the `.payload.phase` subfield of the same goal_circuit_breaker row as reason, else empty" },
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
    + "  " + envPrefix() + "AUTO_MODE=1 "
    + "UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET=" + implementBudget + " " + bashCmd(launcherSh)
    + " --auto-mode=1 --turbo -- <ISSUES> --backend=workflow --force\n\n"
    + "`--backend=workflow` makes the launcher write its manifest and print an args envelope INSTEAD of "
    + "dispatching anything itself. `--force` is required and is not a shortcut: STEP 1 already took the "
    + "`uberdev:active` claim for these issues on this run's behalf, so the launcher's own claim pass would "
    + "otherwise refuse them as a collision with us. The UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET pin is the "
    + "budget lib/goal-phase0.sh resolved for this run: /goal projected its agent ceiling against that number "
    + "before claiming anything, so the fleet has to be armed with the same one (#590).\n\n"
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

// #592 — the partial-chain carrier, and the ONE reason it is a command-line
// flag rather than anything tidier. The fleet's per-issue `chainComplete` is
// visible in exactly one place: the return value of the nested workflow() call
// below. The merge gate that has to act on it is not in this script — it is in
// lib/goal-watch.sh, which re-discovers PRs from `gh pr list` every pass and
// never sees a JS value at all — and RFC 0012 §2.2 constraint 6 forbids this
// script the filesystem, so it can neither write a file that gate would read
// nor reach into a running shell. argv is the whole channel.
//
// OMITTED, never emitted empty — and the reason is NOT that an empty value is
// refused. In the shipped lib/goal-watch.sh the outer shape guard opens with a
// bare no-op `"") ;;` arm, so an EMPTY value is simply ACCEPTED and the tick
// runs on; only a NON-EMPTY malformed value reaches the refusal and exits 2.
// (Measuring the script standalone shows exit 3 for an empty flag, but that is
// an artifact of the bare shell — an invocation with no flags at all exits 3
// identically. The 3 is run-state rehydration failing, never the flag. In a
// driver-composed pass, where run state rehydrates, the empty flag is accepted.)
// The rule stands on its own terms instead: an empty flag carries no value to
// act on, so emitting one buys nothing, and omitting it keeps the command line
// byte-identical to a pre-issue cycle. Both scripts still take a startup
// refusal as a bug in the caller that composed the command line rather than as
// something to poll through.
//
// Both values are script-derived: they leave the ledger below having passed
// digitsOnly(), so nothing but digits and commas can reach a command line, and
// the two scripts re-refuse the shape at their own edge regardless.
//
// The ledger these read lives in the run-state block further down (it must span
// the whole run, not one prompt); these are called from inside the cycle loop,
// long after that block has run.
function partialPrsFlag() {
  return partialPrs.length ? " --partial-prs=" + partialPrs.join(",") : "";
}
function partialIssuesFlag() {
  return partialIssues.length ? " --partial-issues=" + partialIssues.join(",") : "";
}
// #603 — same OMITTED-never-empty discipline as the two above, and on the same
// true footing: `--solver-prs=` with no value is NOT refused. The guard's empty
// arm is a bare no-op, so an empty value is ACCEPTED and the tick runs on; only
// a non-empty malformed value exits 2. (See the note above on why measuring the
// script standalone shows 3 — that is rehydration, not this flag.) The rule
// holds because an empty flag carries no pair, so on a cycle with no
// attributable pair the command line stays byte-identical to what it was before
// this issue. A startup refusal is still a bug in the caller that composed the
// command line rather than something to poll through.
// Every member left this ledger having passed the digit test in
// solverPairsFromResults, so nothing but digits, colons and commas can reach a
// command line — and lib/goal-watch.sh re-refuses the shape at its own edge.
function solverPrsFlag() {
  return solverPrs.length ? " --solver-prs=" + solverPrs.join(",") : "";
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
    + "  " + envPrefix() + "UBERDEV_GOAL_SOLVERS_SETTLED=1 " + bashCmd(watchSh) + " --goal-id=" + goalId
    + partialPrsFlag() + solverPrsFlag() + "\n\n"
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

// The reason read is `.payload.reason`, because that is where
// `uberdev_goal_audit` writes it — every row is framed
// {"ts","event","payload"}. The read this replaces went looking for the reason
// under a `data` object no writer has ever created, so it matched no key at
// all: the relay reported "" for every halt and the driver's
// `rec.reason || col.decision` fallback published the degraded literal "halt"
// as the reason of every Phase-3 breaker.
//
// The residual this comment used to describe — a Phase-3 exit 1 that wrote no
// breaker row at all, leaving the tail to find the newest row the RUN wrote,
// possibly an earlier CYCLE's — is CLOSED by #624, and the description of it
// was wrong in a way worth recording. The `uberdev_dispatch_resolve_env … ||
// exit 1` it named is not "above lib/goal-phase3.sh's rehydrate region": it is
// the LAST line INSIDE that region, after the lib is sourced and after
// uberdev_goal_read_run_state has exported the two variables the audit sink
// reads. The full halt shape was available there the whole time, so the fix was
// one emit in that script (reason `backend_resolve_failed`, RFC 0005 D624a),
// not the startup rework the wrong reading implied.
//
// What is NOT closed, and is a different defect from the one #624 names: that
// exit also precedes the `trap … EXIT` that prints the
// {"phase":"collect",…,"decision":…} line this relay is told to copy VERBATIM,
// so on that one path the relay has a status and an audit row but no decision
// line. Bounding the tail read by identity remains out of reach here for the
// original reason — it needs a clock the runtime denies this script (DR-7) on
// payloads that are not uniformly keyed by cycle.
function collectPrompt(cycleNo) {
  return "You are a mechanical relay. Run EXACTLY this command via Bash and report what it printed:\n\n"
    + "  " + envPrefix() + bashCmd(phase3Sh) + " --goal-id=" + goalId
    + partialIssuesFlag() + "\n\n"
    + "This is the /uberdev:goal collect pass for cycle " + cycleNo + ". It enumerates the cycle's new "
    + "BLOCKER/CRITICAL `review-pr-finding` issues, runs the fingerprint-repeat detector, applies the "
    + "overflow truncation, and evaluates the terminal gates. It prints ONE JSON line "
    + "{\"phase\":\"collect\",...,\"decision\":\"converged|loop|halt|state_error\",\"rc\":N,"
    + "\"candidates\":N,\"queued\":N,\"queue\":\"<csv>\"} and exits 0 (converged) / 42 (loop back) / 1 (halt) "
    + "/ 3 (state error).\n\n"
    + "Copy decision, rc, candidates, queued and queue from that line VERBATIM — do not recompute them and do not "
    + "second-guess the decision. For `reason`, if and only if the decision is `halt`, report the "
    + "`.payload.reason` field of the LAST goal_circuit_breaker row in \"" + tmpDirAbs + "/goal-" + goalId + ".jsonl\" "
    + "(read it with `tail`); otherwise report \"\". For `phase`, report the `.payload.phase` field of THAT "
    + "SAME row — most breakers carry no such key, so report \"\" whenever it is absent, and \"\" whenever "
    + "the decision is not `halt`. Do NOT merge it into `reason`. For `fingerprints`, report the comma-joined 16-hex "
    + "fingerprints in \"" + tmpDirAbs + "/goal-" + goalId + "-fingerprints.tsv\" whose cycle column equals "
    + cycleNo + ", or \"\" if the file is absent.\n\n"
    + "Return via StructuredOutput: rc, decision, candidates, queued, queue, fingerprints, reason, phase, note.";
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
// #592 — the partial-chain ledger: the issues whose solver task chain STOPPED
// SHORT this run, and the PRs those short chains still delivered. Run-lifetime
// beside the queue and the cycle records, for the same structural reason they
// are: lib/goal-phase3.sh truncates the batch-PR registry at loop-back and
// lib/goal-watch.sh re-discovers PRs from `gh pr list` on every pass, so a set
// that reset with the cycle would stop naming a cycle-1 partial delivery the
// moment a later cycle returned a clean fleet — and the convergence gate would
// then converge the run on the cycle it looked cleanest. Both are arrays of
// digit STRINGS (digitsOnly's output), deduped, in first-seen order.
const partialIssues = [];
const partialPrs = [];
// #603 — the issue->PR corroboration ledger, `<issue>:<pr>` strings in
// first-seen order. Run-lifetime for the same reason its neighbours are: the
// pass that finally resolves a cycle-1 PR can be three cycles later, and a set
// that reset with the cycle would leave that pass back on the head-ref guess.
// First record for an issue wins — a later cycle re-solving the same issue is
// not a correction of the earlier one, and overwriting would retro-attribute a
// PR that is already registered and under review.
const solverPrs = [];
const nullsByPhase = {};
let verdictRows = [];
let cb1Tripped = false;                    // projected-agent ceiling
let cb2Tripped = false;                    // budget floor
let cbWatchTicks = false;                  // watch never settled within the tick bound
let halted = false;
let haltReason = "";
// #592 — the breaker's `phase` subfield, SEPARATE from haltReason and never
// concatenated into it. Four live emitters already put a `phase` in a breaker
// payload, so folding it into the reason string would rewrite halt strings
// that existing readers match on.
let haltPhase = "";
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
    haltPhase: haltPhase,
    queueRemaining: queue.slice().map(Number),
    partialIssues: partialIssues.map(Number),
    partialPrs: partialPrs.map(Number),
    solverPrs: solverPrs.slice(),
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

// What ONE issue costs inside a nested fleet run, priced against a BUDGET
// rather than against a source of one. This is the ONLY copy of that
// arithmetic in this file, and it has two callers that read the budget from
// two different places at two different moments — the pre-claim projection
// from /goal's own relayed config, the spend accumulator from the fleet
// envelope the claim relay hands back. Both need the same number; a second
// typed copy is the #370 "one contract, N uncompared copies" shape, and this
// file shipped exactly that (a literal in the projection, a derivation in the
// accumulator) until #590.
//
// The term is the fleet's per-design-issue cost: the issue's OWN SOLVER, the nine
// research/design agents a medium-tier issue costs, and up to
// IMPLEMENT_AGENT_BUDGET implement-phase agents for the per-task
// implementer -> reviewer -> fix chain (#508). The fleet writes it as
// `designCount * (9 + IMPLEMENT_AGENT_BUDGET - 1)` and counts the issue's own
// solver separately in `intakeIssues.length`; folded together that is
// `9 + budget` per issue, which is why there is no `- 1` here.
//
// The clamp bounds and default are the FLEET's — clampInt(CFG.implementBudget,
// 4, 96, 24) at skills/solve-fleet/workflow.js — deliberately duplicated rather
// than guessed, and tests/solve-fleet-workflow.test.sh G16 reads them back out
// of the fleet constant and reds if the two drift. Clamping matters in both
// directions: a relayed budget the fleet would refuse must be priced as the
// fleet would RUN it, or reading the key merely swaps an under-count for an
// over-count.
function perIssueCostAtBudget(budget) {
  // SHARED COST: solve-fleet-per-issue-agent-cost
  return 9 + clampInt(budget, 4, 96, 24);
}

// What the fleet spends per RUN rather than per issue: its batched intake relay
// and its batched PR-claim verification relay (#515), plus the run-shared repo
// profile (#615 A) — one agent that derives the repo-invariant half of the
// research lenses once, dispatched only when the run has a design-tier issue to
// feed it. `skills/solve-fleet/workflow.js` charges it as
// `repoProfileAgents = designCount > 0 ? 1 : 0` and really dispatches it; this
// side has no manifest and so no tier breakdown, and prices every claimed issue
// as design-tier, which makes `issueCount > 0` the same gate. Charging it flat
// is why both callers below take their run-level term from here: a ceiling that
// under-projects is not a ceiling, and a ledger that under-counts hands CB1 a
// comparison it cannot make.
function fleetRunCost(issueCount) {
  return 2 + (issueCount > 0 ? 1 : 0);
}

// Projected agents for ONE cycle: the claim relay, up to maxWatchTicks watch
// relays, the collect relay and the verdict relay, plus the whole nested fleet
// run — its run-level term and its per-issue term.
//
// THE BUDGET IS AN INPUT, NOT A CONSTANT. The fleet declares
// IMPLEMENT_AGENT_BUDGET as clampInt(CFG.implementBudget, 4, 96, 24), so an
// operator can move the per-issue cost anywhere between base+4 and base+96 —
// better than threefold at the top of the range. This projection used to freeze
// the arithmetic at the default, which is the one number at which a literal and
// a derivation agree, so a raised budget under-projected here by up to 72
// agents per issue: CB1 stopped being the breaker that bound, and the run died
// against the runtime's own lifetime cap with no named halt event (#590). It is
// derived now, from the `implementBudget` key lib/goal-phase0.sh publishes in
// /goal's args envelope and the claim relay pins back onto the launcher command
// line, so the number projected here IS the number the fleet runs with.
//
// Consequence, stated out loud rather than buried in the arithmetic: at the
// default budget a design-tier issue costs 33 agents, and it is maxAgents that
// binds first, not the runtime's own 1000-agent lifetime cap. CB1 halts once
// agentsSpent plus this projection exceeds maxAgents, whose launcher default is
// 900 (lib/goal-phase0.sh), so a /goal run stops at roughly 26 design-tier
// issues — sooner once the per-cycle relay overhead above is counted. That
// default sits just under the runtime cap deliberately, so a long run ends on a
// named CB1 audit event instead of dying against the runtime limit. Raising the
// implement budget now moves this projection with it, so what makes the runtime
// cap binding again is raising maxAgents above 1000 (the clamp permits up to
// 2000) — and nothing else. That is the honest price of a review gate per task;
// intra-issue agents queue rather than accelerate on a busy host.
function projectedAgentsForCycle(issueCount) {
  return 3 + maxWatchTicks + fleetRunCost(issueCount)
    + (issueCount * perIssueCostAtBudget(implementBudget));
}

// The per-issue term for a fleet run whose ENVELOPE is already in hand. Same
// arithmetic as the projection, different source: by the time the accumulator
// runs, the claim relay has handed back the launcher's own envelope and it
// carries the effective `implementBudget` verbatim. Read it rather than
// re-reading /goal's config, so a launcher that resolved a different value than
// Phase 0 published is charged as what it actually armed.
function perIssueFleetCost(fleetArgs) {
  const cfg = (fleetArgs && typeof fleetArgs === "object" && fleetArgs.config
    && typeof fleetArgs.config === "object") ? fleetArgs.config : {};
  return perIssueCostAtBudget(cfg.implementBudget);
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
      // The fleet's run-level term — its two batched relays (intake + PR-claim
      // verification, #515) and the run-shared repo profile (#615 A) — plus its
      // per-issue solver/design/implement-chain agents, priced off the budget in
      // the envelope we are about to hand it. Both terms come from the same two
      // helpers the projection uses, so the ceiling and the ledger cannot answer
      // differently. Computed BEFORE the call so the throw arm can charge the
      // same number the clean arm charges.
      const fleetCost = fleetRunCost(rec.claimed.length)
        + (rec.claimed.length * perIssueFleetCost(fleetArgs));
      // THE one nested call. One per cycle, for the whole cycle. See the header:
      // a nested call per issue would spend the single nesting level on the
      // wrong thing and the fleet's own agents could not run.
      try {
        const out = await workflow({ scriptPath: solveFleetJs }, fleetArgs);
        fleetRuns += 1;
        agentsSpent += fleetCost;
        rec.fleet = "ran";
        if (out && typeof out === "object" && Array.isArray(out.prsOpened)) {
          rec.prsOpened = digitsOnly(out.prsOpened).map(Number);
        }
        // #592 — the partial-chain ingest. Deliberately a SIBLING of the block
        // above rather than nested inside it: the issue half is derived from
        // `results`, so a fleet return carrying records but no `prsOpened`
        // array must still reach the ledger. Nesting it would make the whole
        // refusal conditional on a field it does not read.
        //
        // The two halves come from different members ON PURPOSE.
        //
        //   PRs — `out.prsPartial`, the fleet's own filter OF `prsOpened`. Not
        //   re-derived from `results[].prNumber`: when two records claim ONE
        //   number and disagree about completeness, `prsOpened` has already
        //   decided which record owns it and the loser's per-record facts went
        //   with its discarded claim, so a second derivation here would be a
        //   second, uncompared copy of that collision rule (#370) and the two
        //   lists could answer differently with nothing to compare them. Taking
        //   the published subset also makes `partialPrs ⊆ ingested PRs`
        //   structural — no number the merge gate never saw can be flagged.
        //
        //   Issues — `results[].chainComplete`, because nothing else publishes
        //   an issue-number list and the convergence gate refuses on ISSUES.
        //   `=== false` is strict: an ABSENT flag means the record ran no task
        //   chain at all (the single-solver path attaches it nowhere, and a
        //   FAILED record never got that far), and a chain that never ran
        //   cannot have stopped short — `!r.chainComplete` would make every
        //   trivial-tier PR a partial delivery and refuse every convergence.
        //
        // The sets can differ by one issue in exactly that collision case: the
        // chain stopped short, so the issue is named, while its PR number
        // belongs to another record. That is the safe direction — the run still
        // refuses to report convergence.
        if (out && typeof out === "object") {
          const cycleIssues = digitsOnly(partialIssuesFromResults(out.results));
          // "0" is the fleet's no-PR sentinel, never a PR number the merge gate
          // could match; the issue behind it is still named above.
          const cyclePrs = digitsOnly(out.prsPartial).filter(function (s) { return s !== "0"; });
          cycleIssues.forEach(function (s) { if (partialIssues.indexOf(s) < 0) partialIssues.push(s); });
          cyclePrs.forEach(function (s) { if (partialPrs.indexOf(s) < 0) partialPrs.push(s); });
          rec.partialIssues = cycleIssues.map(Number);
          rec.partialPrs = cyclePrs.map(Number);
          // #603 — the corroboration ingest. A SIBLING of the partial ingest,
          // not a clause of it: the pairs must be published on a cycle whose
          // every chain ran to completion, which is precisely the cycle the
          // partial ledger stays empty for.
          const cyclePairs = solverPairsFromResults(out.results);
          cyclePairs.forEach(function (s) {
            // FIRST RECORD WINS — and BOTH halves of the relation are enforced.
            // solverPairsFromResults establishes one-PR-per-issue AND
            // one-issue-per-PR, but only within a single fleet return. Scanning
            // the issue half alone silently loses the second rule the moment the
            // accumulator spans cycles: cycle 1's `11:901` and cycle 2's `12:901`
            // would BOTH survive, both ride the watch flag into the shell ledger,
            // and lib/goal-state.sh would corroborate ONE PR onto TWO issues —
            // ranked ABOVE the head-ref guess, which is the exact mis-attribution
            // this ledger exists to remove.
            //
            // ASYMMETRIC WITH THE PER-CYCLE RULE, deliberately. Inside one return
            // a PR collision drops BOTH pairs: neither has been published and
            // there is nothing to prefer between them. Across cycles the earlier
            // pair has already reached a watch relay and cannot be recalled, so
            // refusing the newcomer is the only rule that is actually reachable
            // here — and it degrades that issue to the head-ref guess, which is
            // the safe direction (a finder answering "no PR" fails the issue on
            // the first tick).
            //
            // Both halves are split once here rather than once per element.
            const half = s.split(":");
            const issueHalf = half[0];
            const prHalf = half[1];
            const collides = solverPrs.some(function (k) {
              const q = k.split(":");
              return q[0] === issueHalf || q[1] === prHalf;
            });
            if (!collides) {
              solverPrs.push(s);
            }
          });
          rec.solverPrs = cyclePairs.slice();
        }
      } catch (e) {
        rec.fleet = "threw";
        // A fleet that threw still SPENT. Charging nothing here is what lets the
        // accumulator read zero for a cycle that ran agents, and the likeliest
        // cause of the throw is the runtime refusing further ones — precisely the
        // moment the fleet has spent the most. So the same conservative estimate
        // is charged, and the cycle whose real spend could not be measured is
        // NAMED rather than left to be inferred from a total that is quietly
        // short.
        agentsSpent += fleetCost;
        auditEvents.push({ event: "fleet_spend_unmeasured", cycle: cycle,
          estimated: fleetCost, claimed: rec.claimed.length, ts: nowIso });
        auditEvents.push({ event: "fleet_threw", cycle: cycle,
          reason: (e && e.message) ? e.message : String(e), ts: nowIso });
        log("cycle " + cycle + ": the nested solve-fleet workflow threw ("
          + ((e && e.message) ? e.message : String(e)) + "). The watch pass still runs — solvers that already "
          + "pushed a PR must still be driven to merge, and the claims must still be reconciled. An estimated "
          + fleetCost + " agent(s) are charged to the ceiling for it; the real spend is unmeasurable.");
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
  rec.phase = String(col.phase || "");
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
  // Reported beside the reason, never inside it. `solver_failed` covers two
  // distinct Phase-3 halts and `partial_chain` is the only thing that tells
  // them apart, but the reason string itself is what existing readers match.
  haltPhase = rec.phase;
  log("cycle " + cycle + ": halting (" + haltReason + (haltPhase ? ", phase " + haltPhase : "") + ").");
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
