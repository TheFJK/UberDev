#!/usr/bin/env bash
# tests/solve-run-tree-scope.test.sh — issue #510.
#
# THE DEFECT. policy/solve-run-tree-v1.json calls itself the solve run tree, but
# every one of its 51 edges is sourced from skills/orchestrator/SKILL.md,
# skills/subagent-driven-dev/SKILL.md, commands/review-pr.md and friends — the
# ROUTED-CHILD substrate. Since RFC 0015 the DEFAULT /solve + /turbo route is the
# Workflow-native fleet in skills/solve-fleet/workflow.js, and zero edges are
# sourced from it. So the manifest could describe a fully retired pipeline and
# stay green: nothing compared it against the path that actually runs.
#
# THE CLASS (#370). "One contract, N uncompared copies" — here N is zero. A guard
# whose universe IS the contract can only fail on what the contract already
# names, so the fix cannot be another read of the manifest alone. This file
# derives the live half BY EXECUTING the fleet script under
# tests/_workflow_harness.js and compares that against the manifest scope block.
# When the fleet gains or loses an agent, this reds; when the declaration drifts
# from the fleet, this reds.
#
# WHAT IT ASSERTS. scope.does_not_govern[] names each substrate this manifest
# deliberately does NOT cover, with the machine-checkable evidence:
#
#   C1  declared agent_kinds  UNION  edge-covered kinds  ==  executed kinds
#   C2  a kind is ungoverned OR carried by a reserved-prefix edge, never both
#   C3  every edge sourced from that substrate sits under its reserved prefix
#   C4  the executed set has at least that lane kindFloor kinds (a RATCHET, not
#       a magic number — see EXECUTED_KIND_FLOOR, which is solve_fleet own)
#   C5  dispatch_sites matches the static site count of that lane source: the
#       bash grep below for solve_fleet, countSites() over the lane own bytes
#       for the rest, matching (agent|workflow) so a nested workflow() dispatch
#       is counted rather than silently dropped
#   C6  source is under plugins/uberdev/ and exists; the reserved prefix does not
#       collide with the prkit-projected review_pr. / simplify. namespaces
#   C7  tracking_issues is a non-empty integer array (TYPE only — issue churn
#       must never red CI)
#
# Rows Z9-Z12 are DIFFERENTIAL on purpose: each asserts the unmutated inputs are
# clean AND the mutant is dirty. A one-sided "the mutant fails" row passes
# vacuously on a broken manifest, which is the exact shape this issue is about.
#
# WHAT #649 ADDED. C1-C7 every one of them READ A DECLARED ENTRY, so the set they
# validate is the set the manifest already names: a substrate that ships with no
# entry at all is invisible to all seven. /turbox (RFC 0020) shipped exactly that
# way — the calling session dispatches its whole fleet through the Task tool, it
# never sources lib/child-dispatch.sh, so it mints no handoff and leaves no edge
# here to notice its absence.
#
#   C8  ENUMERATE the dispatch substrates reachable from the run tree own
#       root_edge source (lib/solve-launcher.sh) and red when one is neither the
#       governed routed-child substrate nor declared in does_not_govern[]. The
#       universe is read out of the LAUNCHER bytes, never out of the manifest,
#       which is the whole point: a universe sourced from the manifest can only
#       ever contain what the manifest already declared. Row Z16 is the
#       anti-vacuity half — a fixture substrate spliced into the launcher source
#       and declared nowhere MUST red C8, or the enumeration is decorative.
#   C9  for a declared substrate whose source is prose rather than a script,
#       agent_kinds and dispatch_sites are derived from that source the way C1
#       and C5 derive the fleet ones. An agent identifier counts only when
#       plugins/uberdev/agents/<stem>.md exists, which is what keeps the label
#       `uberdev:active` and the command `uberdev:orchestrator` out of the set.
#
# THE BOUNDARY C8 DOES NOT CROSS, stated so nobody reads it as more than it is.
# Its universe is the lanes this run tree can reach FROM ITS OWN ROOT, which is
# the solve/turbo/turbox family. The other shipped Workflow fleets — review-fleet,
# scan-fleet, goal-pipeline, testers-pipeline, uberthink-pipeline — are rooted
# elsewhere and are not enumerated here, so C8 says nothing about them either
# way. Widening the universe to a fleet means deriving its agent_kinds by
# EXECUTING it under the harness the way C1 does, not by adding its path.
#
# WHAT #654 ADDED. Exactly that widening. The rule layer is lane-parameterised
# and the LANES table now carries all six shipped Workflow fleets, each with its
# own normalizer, its own fixture and its own live kind set derived by EXECUTING
# it under the harness. C8 own universe is UNCHANGED — it still enumerates only
# what the solve/turbo/turbox root reaches and still says nothing about the
# other five either way. What reds when one of those five drifts is its own
# per-lane C1/C4/C5 row, never C8.
#
# GIT-BASH PORTABLE: grep + node only (no python3/PyYAML/mktemp, no temp files,
# no digests, no PATH stubs). Runs on BOTH the ubuntu and windows shape-check
# jobs, so it needs no windows-skip-list entry.
#
# The node program is embedded in a single-quoted shell string and therefore
# contains no single-quote character anywhere — same constraint the inline
# program in tests/solve-fleet-workflow.test.sh already obeys.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/solve-fleet/workflow.js"
MANIFEST="$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
# The manifest own root_edge source, and therefore C8 universe: every lane the
# run tree can reach starts by this file naming the lane surface it validates
# before it emits anything. The comparator cross-checks the path below against
# edges[root_edge_id].source so a rotted root cannot leave C8 enumerating a file
# the tree no longer starts at.
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"

# #654. The five OTHER shipped Workflow fleets. Each lane source gets its own
# readability FATAL for the reason docs/testing.md gives — fail loud on missing
# inputs. A lane that vanishes must not silently drop out of the corpus: a
# fallback that hides the failure is a swallowed error, and here it would be a
# permanently green hole of exactly the class this file exists to close.
L_REVIEW="$REPO_ROOT/plugins/uberdev/skills/review-fleet/workflow.js"
L_SCAN="$REPO_ROOT/plugins/uberdev/skills/scan-fleet/workflow.js"
L_GOAL="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js"
L_TESTERS="$REPO_ROOT/plugins/uberdev/skills/testers-pipeline/workflow.js"
L_UBERTHINK="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/workflow.js"

for f in "$HARNESS" "$WORKFLOW" "$MANIFEST" "$LAUNCHER" \
         "$L_REVIEW" "$L_SCAN" "$L_GOAL" "$L_TESTERS" "$L_UBERTHINK"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required to execute the fleet script under the harness (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## solve-run-tree-scope (#510) — the manifest scope block vs the executed solve fleet"

# C5 static backstop. `grep -c` exits 1 on zero matches and this file is
# deliberately NOT `set -e`, so a rotted pattern would sail through as the
# integer 0 and certify a rotted manifest. Validate the capture instead.
SITES="$(grep -cE '(await|return) agent\(' "$WORKFLOW" | tr -d '\r')"
case "$SITES" in
  ''|*[!0-9]*)
    echo "FATAL: the dispatch-site grep produced a non-integer: [$SITES]" >&2
    exit 2
    ;;
esac
[ "$SITES" -ge 1 ] || {
  echo "FATAL: the dispatch-site pattern matched nothing in $WORKFLOW — the pattern has rotted" >&2
  exit 2
}

# argv is paths and one integer only: the two argv shapes Git Bash MSYS
# translation handles correctly. No JSON blob is ever passed as an argument.
ROWS="$(node -e '
var h = require(process.argv[1]);
var fs = require("fs");
var vm = require("vm");
var WORKFLOW = process.argv[2];
var MANIFEST = process.argv[3];
var SITES = parseInt(process.argv[4], 10);
var LAUNCHER = process.argv[5];
var L_REVIEW = process.argv[6];
var L_SCAN = process.argv[7];
var L_GOAL = process.argv[8];
var L_TESTERS = process.argv[9];
var L_UBERTHINK = process.argv[10];

var srcBase = fs.readFileSync(WORKFLOW, "utf8");
var tree = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
var launcherBase = fs.readFileSync(LAUNCHER, "utf8");

// The static dispatch-site count of a lane, over that lane own bytes. The bash
// grep above stays as the INDEPENDENT static backstop for solve_fleet and is
// not replaced by this: five more bash greps would mean five more non-integer
// validations and five more argv entries, and a node regex over the same bytes
// is the same evidence. The alternation is (agent|workflow) rather than agent
// alone because goal_pipeline dispatches its per-cycle fleet through a NESTED
// workflow() call, and an agent-only count would report that lane one site
// short — the same blindness D7 closes on the kind side.
function countSites(src) {
  var m = String(src).match(/(await|return) (agent|workflow)\(/g);
  return m ? m.length : 0;
}

// Lane sources OTHER than solve_fleet, keyed by LANES member id. solve_fleet is
// deliberately NOT a member here — its source is srcBase, which the Z9
// differential mutates in memory. Read ONCE, because the per-lane rename
// differential below mutates a copy of these bytes and must not re-read a file
// the mutation did not touch.
var laneSrc = {
  review_fleet: fs.readFileSync(L_REVIEW, "utf8"),
  scan_fleet: fs.readFileSync(L_SCAN, "utf8"),
  goal_pipeline: fs.readFileSync(L_GOAL, "utf8"),
  testers_pipeline: fs.readFileSync(L_TESTERS, "utf8"),
  uberthink_pipeline: fs.readFileSync(L_UBERTHINK, "utf8")
};

var ANCHOR = "plugins/uberdev/";
function relOf(p, what) {
  var slashed = p.split("\\").join("/");
  var at = slashed.indexOf(ANCHOR);
  if (at < 0) { throw new Error(what + " path is not under " + ANCHOR + ": " + p); }
  return { rel: slashed.slice(at), prefix: slashed.slice(0, at) };
}
var WF = relOf(WORKFLOW, "workflow");
var SRC_REL = WF.rel;
var REPO_PREFIX = WF.prefix;
var MANIFEST_REL = relOf(MANIFEST, "manifest").rel;
var LAUNCHER_REL = relOf(LAUNCHER, "launcher").rel;

var rows = [];
function row(ok, label) {
  rows.push((ok ? "PASS" : "FAIL") + "::" + String(label).split("\n").join(" "));
}
function tail(errs) { return errs.length ? " -- " + errs.join("; ") : ""; }
function isStr(v) { return typeof v === "string" && v.length > 0; }
function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }
function isInt(v) { return typeof v === "number" && isFinite(v) && Math.floor(v) === v; }

// ---------------------------------------------------------------------------
// The normalization. Mirrored VERBATIM in scope.agent_kind_rule: an agent kind
// is opts.label with the :#<issue> suffix and any trailing " (<tier>)" removed,
// the per-task :t<n> and per-round :r<n> indices collapsed to :tN and :rN, then
// ":" mapped to "." and "-" mapped to "_".
//
// THE COLLAPSE IS WHAT MAKES A FIXED LIST POSSIBLE. Without it the task index
// and the fix-round index stay inside the kind, so a round-3 reviewer of task 12
// is its own kind and the kind space is UNBOUNDED — no enumeration in the
// manifest could satisfy C1 for a chain that actually runs, which is why the
// only fixture that passed was one whose chain died at rung one. The indices are
// not part of what an agent IS; they are which instance of it ran.
// ---------------------------------------------------------------------------
function kindOf(label) {
  var s = String(label);
  s = s.replace(/:#[0-9]+/, "");
  s = s.replace(/ \([a-z0-9_-]+\)$/, "");
  s = s.replace(/:t[0-9]+/g, ":tN");
  s = s.replace(/:r[0-9]+/g, ":rN");
  return s.split(":").join(".").split("-").join("_");
}

// ---------------------------------------------------------------------------
// The fixture. ONE batch carrying a design tier and a trivial tier reaches every
// dispatch site in the fleet, so one run derives the whole live set. Kept local
// on purpose: tests/solve-fleet-workflow.test.sh owns a different contract and a
// shared fixture would make both files fragile.
//
// IT MUST DRIVE THE TASK CHAIN, NOT JUST ENTER IT. This fixture used to register
// a single-solver return for the design-tier issue and NO return for the task-1
// implementer, so the harness default empty return failed the workspace gate and
// the chain died at its first rung: three of the fleet dispatch sites — the
// per-task reviewer, the per-task fix agent and the delivery agent — were never
// reached, C1 certified an agent_kinds list that omitted all three, and the
// six-kind anti-vacuity floor passed comfortably at ten. The guard advertised as
// reddening when the fleet gains or loses an agent could not see any agent added
// inside the chain, which is the drift class this whole file exists for. Task 1
// therefore draws a REVISIONS_REQUIRED review and one fix round, and task 2 is
// approved, so every rung of the chain executes on the way to delivery.
// ---------------------------------------------------------------------------
var RD = "/r/.uberdev/run/RID";
function buildArgs() {
  return {
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "solve-fleet",
    config: {
      runId: "RID", runDirAbs: RD, pluginRootAbs: "/p", repoRootAbs: "/r",
      manifestPathAbs: RD + "/solve-fleet-manifest.json",
      issues: "11,12", issueCount: 2, concurrency: 6, autoMode: false,
      repoSlug: "acme/widget", branchPrefix: "worktree-solve-issue-",
      solveTimeoutS: 3600, maxAgents: 250, timestampIso: "2026-01-01T00:00:00Z"
    }
  };
}
// riskSignals is OPTIONAL and, on the design-tier issue, NON-EMPTY (#524 item
// 3): the security research lens is gated on it, so a fixture that omitted the
// field would never reach that rung and C1 would certify an agent_kinds list
// missing it — the same blindness that once hid three chain rungs here.
function issueRec(issue, tier, riskSignals) {
  var r = { issue: issue, tier: tier, promptFile: RD + "/solve-prompt-" + issue + ".txt" };
  if (riskSignals) { r.riskSignals = riskSignals; }
  return r;
}
function solvedRec(issue, pr) {
  return {
    issue: issue, status: "PR_OPENED", branch: "fix/" + issue + "-x", prNumber: pr,
    prUrl: "https://example.invalid/pull/" + pr, commitCount: 1, testsRun: true,
    summary: "done", blocker: ""
  };
}
// A per-task rung return. workspaceReady MUST be true or the chain stops at the
// gate before the rungs this fixture exists to reach.
function taskRec(id, extra) {
  var r = {
    taskId: id, status: "DONE", commitCount: 1, workspaceReady: true,
    summary: "s", blocker: ""
  };
  if (extra) { Object.keys(extra).forEach(function (k) { r[k] = extra[k]; }); }
  return r;
}
function agentReturns() {
  return {
    "manifest-intake": { rc: 0, issues: [issueRec(11, "medium", ["security"]), issueRec(12, "trivial")] },
    "research:#11:codebase": { artifactPath: RD + "/issue-11/research-codebase.md", rc: 0, headline: "h" },
    "research:#11:constraints": { artifactPath: RD + "/issue-11/research-constraints.md", rc: 0, headline: "h" },
    "research:#11:test-coverage": { artifactPath: RD + "/issue-11/research-test-coverage.md", rc: 0, headline: "h" },
    "research:#11:security": { artifactPath: RD + "/issue-11/research-security.md", rc: 0, headline: "h" },
    "spec:#11": { path: RD + "/issue-11/spec.md", rc: 0, headline: "h" },
    // NOT an APPROVE (#524). The bounded spec-revision round is conditional on a
    // non-APPROVE verdict, so an approving fixture never reaches the reviser and
    // C1 would certify an agent_kinds list missing it — the same blindness that
    // hid three chain rungs before this fixture was made to drive them.
    "spec-review:#11": { verdict: "REVISIONS_REQUIRED", rc: 0, headline: "h",
      blockingFindings: ["f"] },
    "spec-revise:#11": { path: RD + "/issue-11/spec-r1.md", rc: 0, headline: "h" },
    "plan:#11": { path: RD + "/issue-11/plan.md", rc: 0, headline: "h" },
    // Unconditional, unlike the reviser above: every accepted plan is reviewed
    // (#524 item 2). APPROVE here — this fixture exists to reach every rung, not
    // to drive the findings hand-off, which tests/solve-fleet-workflow.test.sh
    // owns.
    "plan-review:#11": { verdict: "APPROVE", rc: 0, headline: "h", blockingFindings: [] },
    "impl:#11:t1": taskRec(1, { taskCount: 2 }),
    "review:#11:t1:r1": { verdict: "REVISIONS_REQUIRED", rc: 0, headline: "h",
      blockingFindings: ["f"] },
    "fix:#11:t1:r1": taskRec(1),
    "review:#11:t1:r2": { verdict: "APPROVE", rc: 0, headline: "h", blockingFindings: [] },
    "impl:#11:t2": taskRec(2),
    "review:#11:t2:r1": { verdict: "APPROVE", rc: 0, headline: "h", blockingFindings: [] },
    "deliver:#11": solvedRec(11, 901),
    "solve:#12 (trivial)": solvedRec(12, 902)
  };
}
// One execution of one lane run. budgetTotal is threaded through rather than
// hardcoded because hasOwnProperty is how the harness decides between an
// explicit budget and its falsy default, and a loop-driven lane truncated by
// that default would have its kind set measured short. A dry-run budget is a
// hang detector, never a stopwatch, so a lane that needs one sets it high.
function runFixture(lane, source, run) {
  var meta = h.extractMeta(source).meta;
  var pre = h.preprocess(source);
  var record = h.makeRecord();
  var fixture = { args: run.args, agentReturns: run.agentReturns };
  if (Object.prototype.hasOwnProperty.call(run, "budgetTotal")) {
    fixture.budgetTotal = run.budgetTotal;
  }
  var sb = h.makeSandbox(fixture, meta, record).sandbox;
  var pending = vm.runInNewContext(pre.wrapped, sb, { filename: lane.id + "-scope", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}

// A fleet whose real dispatch is a NESTED workflow() call is invisible to
// record.agentCalls: an agentCalls-keyed derivation would certify such a lane
// at the width of its relay agents while the fleet it actually launches went
// unrecorded. Union both call logs so the derivation sees the whole surface.
// The nesting chase is bounded at ONE level by the runtime itself, so this
// namespace is complete by construction rather than by a depth guess.
function skillOfScriptPath(p) {
  var slashed = String(p).split("\\").join("/");
  var m = slashed.match(/skills\/([^/]+)\/workflow\.js$/);
  return m ? m[1].split("-").join("_") : "";
}
function liveKinds(record, lane) {
  var seen = {};
  record.agentCalls.forEach(function (c) { seen[lane.normalize(c.label)] = 1; });
  (record.workflowCalls || []).forEach(function (w) {
    var name = skillOfScriptPath(w && w.ref ? w.ref.scriptPath : "");
    if (name) { seen["workflow." + name] = 1; }
  });
  return Object.keys(seen).sort();
}

// The UNION of every run is the lane live set, because a lane whose stages are
// selected by its args cannot be driven to its full surface in one invocation.
// Runs execute in SERIES on purpose: one record per run, so two stage arms can
// never interleave into a single record and be read as one execution.
function liveOf(lane, source) {
  var seen = {};
  var chain = Promise.resolve();
  lane.runs.forEach(function (run) {
    chain = chain.then(function () {
      return runFixture(lane, source, run).then(function (rec) {
        liveKinds(rec, lane).forEach(function (k) { seen[k] = 1; });
      });
    });
  });
  return chain.then(function () { return Object.keys(seen).sort(); });
}

// A differential re-executes ONLY the mutated lane and reuses the cached live
// sets for the rest. Without this, every differential row below would re-run
// every lane and the file would grow from one script execution per row to one
// per lane per row.
function withLane(base, id, live) {
  var out = {};
  Object.keys(base).forEach(function (k) { out[k] = base[k]; });
  out[id] = live;
  return out;
}

// ---------------------------------------------------------------------------
// THE ENUMERATOR (#649). C1-C7 all start from a declared entry, so their
// universe IS the declared set and an entirely absent substrate is invisible to
// them. This block builds the universe from the OTHER side: the launcher bytes
// plus the filesystem. Nothing below reads the manifest, which is what lets the
// comparator name a substrate the manifest never mentions.
//
// EXTENSION-BLIND ON PURPOSE. The path pattern matches whatever literal the
// launcher wrote, so an extension-less surface (every shipped hook, lib/rl-curl)
// is enumerated exactly like a .sh one. A universe filtered by *.sh would skip
// them and go quietly green — the same vacuity this file exists to prevent.
// ---------------------------------------------------------------------------

// Every shipped agent card, by stem. An `uberdev:<stem>` token in a prose
// surface is a DISPATCH only when plugins/uberdev/agents/<stem>.md exists: that
// one filter is what keeps the LABEL `uberdev:active`, the COMMAND
// `uberdev:turbox` and the SKILL `uberdev:orchestrator` out of an agent set they
// have no business in, without a hand-maintained denylist that would rot.
var CARDS = {};
(function () {
  var dir = REPO_PREFIX + ANCHOR + "agents";
  fs.readdirSync(dir).forEach(function (n) {
    if (n.length > 3 && n.slice(-3) === ".md") { CARDS[n.slice(0, -3)] = 1; }
  });
  if (Object.keys(CARDS).length === 0) {
    throw new Error("no agent cards discovered under " + dir + " — the card filter would admit every token");
  }
})();

// A host built-in has no card and can never be discovered from agents/, so the
// one the fleets actually use is named here. It is a dispatchable KIND for the
// C9 derivation and deliberately NOT a classification marker: lib/goal-state.sh
// writes the phrase "general-purpose command" in a comment, and a marker that
// broad would classify a state helper as a solver fleet.
var BUILTIN_KINDS = ["general-purpose"];

function normKind(s) { return String(s).split("-").join("_"); }

// stem -> how many times this source tells the controller to dispatch it.
function agentMentions(body) {
  var counts = {};
  var re = /uberdev:([a-z0-9-]+)/g;
  var m;
  while ((m = re.exec(body)) !== null) {
    if (CARDS[m[1]]) { counts[m[1]] = (counts[m[1]] || 0) + 1; }
  }
  BUILTIN_KINDS.forEach(function (k) {
    var hits = body.match(new RegExp(k, "g"));
    if (hits) { counts[k] = (counts[k] || 0) + hits.length; }
  });
  return counts;
}

var RE_ROUTED = /child-dispatch\.sh|uberdev_dispatch_child|uberdev_create_child_handoff/;
var RE_WORKFLOW_NATIVE = /(?:await|return) agent\(/;
var RE_SESSION_TASK = /Task\(|subagent_type/;

// Which substrate a surface belongs to, decided by its own bytes.
//
// EXECUTABLE EVIDENCE OUTRANKS PROSE, and this order is load-bearing rather than
// arbitrary. RE_ROUTED matches a bare filename, which every one of its current
// hits in this repo is — three COMMENTS, in lib/solve-launcher.sh:1540,
// lib/dispatch.sh:1248 and skills/review-fleet/workflow.js:843. Tested first it
// would rule a Workflow fleet governed for mentioning the adapter it does not
// use, and the first draft of row Z16 passed vacuously for exactly that reason:
// the fixture substrate spliced into the launcher was classified routed off a
// comment and skipped. So a surface that CALLS agent() is workflow-native
// however much prose it also carries, and the adapter mention only decides the
// surfaces that show no dispatch call of their own.
function classify(body) {
  if (RE_WORKFLOW_NATIVE.test(body)) { return "workflow-native"; }
  var cardNamed = Object.keys(agentMentions(body)).filter(function (k) { return CARDS[k]; });
  if (RE_SESSION_TASK.test(body) || cardNamed.length > 0) { return "session-task-fanout"; }
  if (RE_ROUTED.test(body)) { return "routed-child-dispatch"; }
  return null;
}

// Every source the manifest carries an edge for. scope.governs.note says it
// plainly — "Every edge in `edges` is a child dispatched through the routed
// adapter" — so carrying an edge IS the act of governing a surface, and it is a
// positive commitment C3 and tests/run-tree-callsite-contract.test.sh already
// police. Silence can never buy the same exemption, which is the whole point.
function edgeSourceSet(t) {
  var out = {};
  var edges = isObj(t) && isObj(t.edges) ? t.edges : {};
  Object.keys(edges).forEach(function (id) {
    var e = edges[id];
    if (isObj(e) && isStr(e.source)) { out[e.source] = 1; }
  });
  return out;
}

var PATH_RE = /(?:lib|skills|commands|agents|hooks|policy|shared)\/[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*/g;
var bodyCache = {};
function bodyOf(rel) {
  if (!Object.prototype.hasOwnProperty.call(bodyCache, rel)) {
    bodyCache[rel] = fs.readFileSync(REPO_PREFIX + rel, "utf8");
  }
  return bodyCache[rel];
}

function enumerateSubstrates(lsrc, edgeSrc) {
  var seen = {};
  var out = [];
  var m;
  PATH_RE.lastIndex = 0;
  while ((m = PATH_RE.exec(lsrc)) !== null) {
    var rel = ANCHOR + m[0];
    if (seen[rel]) { continue; }
    seen[rel] = 1;
    // A policy document declares substrates; it is not one. Left in, the
    // manifest would classify as routed off its own adapter field.
    if (rel === MANIFEST_REL) { continue; }
    var st = null;
    try { st = fs.statSync(REPO_PREFIX + rel); } catch (err) { st = null; }
    if (!st || !st.isFile()) { continue; }
    var fam = classify(bodyOf(rel));
    // No dispatch call of its own, but the manifest carries edges for it: that
    // is the routed substrate by definition, and it keeps the launcher itself
    // enumerated off its root edge rather than off a comment that could be
    // reworded tomorrow.
    if (fam === null && edgeSrc[rel]) { fam = "routed-child-dispatch"; }
    if (fam === null) { continue; }
    out.push({ source: rel, family: fam });
  }
  out.sort(function (a, b) { return a.source < b.source ? -1 : (a.source > b.source ? 1 : 0); });
  return out;
}

// A RATCHET, like EXECUTED_KIND_FLOOR, and deliberately BELOW today count of 4.
// Three of the four are structural — lib/solve-launcher.sh (its root edge), the
// solve fleet script (its agent() calls) and the turbox skill (its agent cards).
// The fourth, lib/dispatch.sh, is enumerated off a single comment mentioning the
// adapter, so pinning the floor at 4 would red this file on an unrelated comment
// edit. Below 3 the enumeration has lost a structural member, which means a
// pattern rotted — and a shrunken universe reports every substrate left in it as
// declared: green, and blind.
var SUBSTRATE_FLOOR = 3;

// ---------------------------------------------------------------------------
// The rules. Each returns an array of violation strings; check() is their
// concatenation, so the differential rows can re-run the whole rule set against
// an in-memory mutant without duplicating a single predicate.
// ---------------------------------------------------------------------------
function scopeOf(t) { return isObj(t) && isObj(t.scope) ? t.scope : null; }
function entriesOf(t) {
  var s = scopeOf(t);
  return s && Array.isArray(s.does_not_govern) ? s.does_not_govern : null;
}
function entryFor(t, srcRel) {
  var d = entriesOf(t) || [];
  for (var i = 0; i < d.length; i++) {
    if (isObj(d[i]) && d[i].source === srcRel) return d[i];
  }
  return null;
}
function edgeCovered(t, E) {
  var out = [];
  var edges = isObj(t) && isObj(t.edges) ? t.edges : {};
  Object.keys(edges).forEach(function (id) {
    var e = edges[id];
    if (!isObj(e) || e.source !== E.source) return;
    out.push(id.indexOf(E.reserved_edge_prefix) === 0 ? id.slice(E.reserved_edge_prefix.length) : id);
  });
  return out;
}

function rGoverns(t) {
  var e = [];
  var s = scopeOf(t);
  if (!s) { e.push("scope is missing or not an object"); return e; }
  if (!isObj(s.governs)) { e.push("scope.governs is missing or not an object"); return e; }
  ["substrate", "adapter", "note"].forEach(function (k) {
    if (!isStr(s.governs[k])) e.push("scope.governs." + k + " is not a non-empty string");
  });
  if (!isStr(s.agent_kind_rule)) e.push("scope.agent_kind_rule is not a non-empty string");
  return e;
}

function rEntryShape(t) {
  var e = [];
  var d = entriesOf(t);
  if (!d) { e.push("scope.does_not_govern is missing or not an array"); return e; }
  if (d.length === 0) { e.push("scope.does_not_govern is empty"); return e; }
  d.forEach(function (x, i) {
    var at = "does_not_govern[" + i + "]";
    if (!isObj(x)) { e.push(at + " is not an object"); return; }
    ["substrate", "source", "reason", "reserved_edge_prefix"].forEach(function (k) {
      if (!isStr(x[k])) e.push(at + "." + k + " is not a non-empty string");
    });
    if (!isInt(x.dispatch_sites) || x.dispatch_sites < 1) {
      e.push(at + ".dispatch_sites is not a positive integer");
    }
    if (!Array.isArray(x.agent_kinds) || x.agent_kinds.length === 0 || !x.agent_kinds.every(isStr)) {
      e.push(at + ".agent_kinds is not a non-empty array of strings");
    }
    if (!Array.isArray(x.tracking_issues) || x.tracking_issues.length === 0
        || !x.tracking_issues.every(isInt)) {
      e.push(at + ".tracking_issues is not a non-empty array of integers");
    }
  });
  return e;
}

function rC6(t) {
  var e = [];
  var d = entriesOf(t) || [];
  d.forEach(function (x, i) {
    var at = "does_not_govern[" + i + "]";
    if (!isObj(x)) return;
    if (!isStr(x.source) || x.source.indexOf(ANCHOR) !== 0) {
      e.push(at + ".source is not under " + ANCHOR);
    } else if (!fs.existsSync(REPO_PREFIX + x.source)) {
      e.push(at + ".source names a file that does not exist: " + x.source);
    }
    if (x.reserved_edge_prefix === "review_pr." || x.reserved_edge_prefix === "simplify.") {
      e.push(at + ".reserved_edge_prefix collides with a prkit-projected namespace");
    }
  });
  return e;
}

// C1-C5 are LANE-PARAMETERISED. Each takes the lane record rather than closing
// over the solve-fleet globals, and each prefixes its violations with the lane
// id: with more than one lane in the table an unprefixed "dispatched but
// undeclared" names a drift without naming where it drifted.
function rC1(t, lane, live) {
  var E = entryFor(t, lane.source);
  if (!E) return ["lane " + lane.id + ": no scope.does_not_govern entry declares source " + lane.source];
  var declared = Array.isArray(E.agent_kinds) ? E.agent_kinds : [];
  var union = {};
  declared.concat(edgeCovered(t, E)).forEach(function (k) { union[k] = 1; });
  var e = [];
  var missing = live.filter(function (k) { return !union[k]; });
  var extra = Object.keys(union).filter(function (k) { return live.indexOf(k) < 0; }).sort();
  if (missing.length) e.push("lane " + lane.id + ": dispatched but undeclared: " + missing.join(","));
  if (extra.length) e.push("lane " + lane.id + ": declared but never dispatched: " + extra.join(","));
  return e;
}

function rC2(t, lane) {
  var E = entryFor(t, lane.source);
  if (!E) return ["lane " + lane.id + ": no scope.does_not_govern entry declares source " + lane.source];
  var declared = Array.isArray(E.agent_kinds) ? E.agent_kinds : [];
  var covered = edgeCovered(t, E);
  var both = declared.filter(function (k) { return covered.indexOf(k) >= 0; }).sort();
  return both.length
    ? ["lane " + lane.id + ": kinds are BOTH ungoverned and edge-covered: " + both.join(",")]
    : [];
}

function rC3(t, lane) {
  var E = entryFor(t, lane.source);
  if (!E) return ["lane " + lane.id + ": no scope.does_not_govern entry declares source " + lane.source];
  var edges = isObj(t) && isObj(t.edges) ? t.edges : {};
  var bad = Object.keys(edges).filter(function (id) {
    var row2 = edges[id];
    return isObj(row2) && row2.source === E.source && id.indexOf(E.reserved_edge_prefix) !== 0;
  }).sort();
  return bad.length
    ? ["lane " + lane.id + ": edges sourced from " + E.source
       + " sit outside the reserved prefix: " + bad.join(",")]
    : [];
}

// A RATCHET, not a round number. The old floor of 6 was chosen when the fleet
// was smaller and it passed comfortably at 10 — which is precisely why it could
// not notice that the fixture had stopped reaching three of the chain rungs. The
// value is the count derived when EVERY rung is driven, so a fixture that stops
// reaching one reds here even if the manifest is edited to agree with the
// shrunken set. Raise it deliberately when the fleet legitimately grows; the C1
// comparator is what proves the two lists match, and this is what proves the
// list was measured against a fleet that actually ran.
var EXECUTED_KIND_FLOOR = 16;

// ---------------------------------------------------------------------------
// THE FIVE FLEET LANES (#654) — one normalizer and one fixture per lane, each
// DERIVED FROM THAT LANE OWN BYTES and never borrowed from a sibling.
//
// A borrowed normalizer is the realistic error and it fails in BOTH directions.
// kindOf() collapses only the colon-prefixed :t<n> / :r<n>, so applied to
// scan_fleet (which indexes with a trailing zero-padded area id) every area
// stays its own kind, the kind space grows with --areas, and no finite
// agent_kinds list could satisfy C1 for a run that actually happens. Applied to
// goal_pipeline it leaves the CYCLE index in, and the kind space grows with
// maxCycles. In the other direction a normalizer that collapsed a lane
// SEMANTIC token — review_fleet lens slugs, scan_fleet scan-area versus
// simplify-area — would merge distinct dispatch edges into one kind and satisfy
// C1 trivially. Each function below therefore collapses exactly the instance
// indices its own label expressions carry and nothing else.
//
// The fixtures are INLINED rather than required from the Wave-B driver scripts:
// those drivers are evidence for the numbers, not a dependency this shipped
// test may load, and a workflow-harness fixture that lives outside tests/ would
// rot silently. Every args value is a JSON STRING, because that is the shape
// the runtime hands a scriptPath workflow (RFC 0015 section 6b) and an object
// fixture would be a silent no-op on some of these lanes — zero executed kinds,
// certifying a fleet as dispatching nothing.
// ---------------------------------------------------------------------------

// review_fleet. The ONE index its six label expressions carry is the Phase-3
// loop counter ciSlug() appends (base + "-ci" + pad2(ciLoopIter), clamped to
// 1..3). Everything else is semantic: the seven REVIEW_ROSTER slugs and three
// LENS_ROSTER slugs are fixed lens names, edgeSlug(fixerEdgeId) ranges over
// three FIXED edge ids, and ci-fix-code versus ci-rebase come from the fixed
// two-entry CI_FIX_ARMS route table.
function normReviewFleet(label) {
  return String(label)
    .replace(/-ci\d+/g, "-ciN")
    .split(":").join(".")
    .split("-").join("_");
}
// 64 lowercase hex — the grammar isNonce()/isSha256() enforce on the envelope.
function rfHex64(seed) {
  var alphabet = "0123456789abcdef";
  var out = "";
  for (var i = 0; i < 64; i++) { out += alphabet[(i * 7 + seed) % 16]; }
  return out;
}
function rfNonces(n) {
  var out = [];
  for (var i = 0; i < n; i++) { out.push(rfHex64(i + 1)); }
  return out.join(",");
}
function rfArgs(extra) {
  var config = {
    runId: "RID", pluginRootAbs: "/p", repoRootAbs: "/r", runDirAbs: "/r/run",
    startedAtIso: "2026-01-01T00:00:00Z", repoSlug: "TheFJK/UberDev",
    prNumber: 654, reviewIteration: 1, workspaceMode: "caller",
    worktreeAbs: "/r", branchName: "feat/654-lane"
  };
  Object.keys(extra).forEach(function (k) { config[k] = extra[k]; });
  return JSON.stringify({
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "review-fleet",
    config: config
  });
}
// ONE RUN PER stage ARM THAT CARRIES ITS OWN agent( SITE. The three remaining
// dispatching arms (simplify, verify, ci-conflicts) carry no site of their own
// — all three re-enter dispatchRoster, which run 1 already reaches — and the
// two dynamic ones build their roster from an envelope COUNT knob, so driving
// them would pin the floor to a number this fixture picked. agentReturns is {}
// on every run: this lane dispatch is gated on ENVELOPE shape, never on what a
// previous child returned. The ciLoopIter differs across the three CI runs
// (1, 2, 3 — the full clamp range) so the index collapse is exercised rather
// than merely declared.
function reviewFleetRuns() {
  return [
    { args: rfArgs({ mode: "review-pr", stage: "review",
        diffPathAbs: "/r/run/diff.md",
        phase1ContractPathAbs: "/p/policy/contracts/phase1-reviewer-v1.md",
        ruleSourcesPathAbs: "/r/run/rule-sources.txt",
        aspects: "correctness,tests", runNonces: rfNonces(7) }), agentReturns: {} },
    { args: rfArgs({ mode: "review-pr", stage: "fix",
        fixerEdgeId: "review_pr.fix.phase1", commitType: "fix",
        fixerContractPathAbs: "/p/policy/contracts/code-fixer-v1.md",
        findingsPathAbs: "/r/run/findings.md", findingsSha256: rfHex64(11),
        commitRangePathAbs: "/r/run/commit-range.json", commitRangeSha256: rfHex64(12),
        authorityPathAbs: "/r/run/authority.json", authoritySha256: rfHex64(13),
        dispositionPathAbs: "/r/run/disposition.yaml",
        appliedContentPathAbs: "/r/run/applied.json", workingDirAbs: "/r",
        runNonces: rfNonces(1) }), agentReturns: {} },
    { args: rfArgs({ mode: "review-pr", stage: "defer",
        phase1PathAbs: "/r/run/phase1-aggregate.md",
        phase2PathAbs: "/r/run/phase2-aggregate.md",
        phase1DispositionPathAbs: "/r/run/phase1-disposition.yaml",
        phase2DispositionPathAbs: "",
        verificationPathAbs: "/r/run/verification.json",
        runNonces: rfNonces(1) }), agentReturns: {} },
    { args: rfArgs({ mode: "review-pr", stage: "ci-classify", ciLoopIter: 1,
        ciAuthorityPathAbs: "/r/run/ci-authority.json", ciAuthoritySha256: rfHex64(21),
        ciInputSha256: rfHex64(22), ciRunId: "17777777777",
        ciHeadSha: rfHex64(23).slice(0, 40), runNonces: rfNonces(1) }), agentReturns: {} },
    { args: rfArgs({ mode: "review-pr", stage: "ci-fix", ciLoopIter: 2,
        ciFixerEdgeId: "review_pr.ci.fix_code", ciFailureClass: "code_bug",
        ciSignalAnchor: "tests/foo.test.sh:12",
        ciAuthorityPathAbs: "/r/run/ci-authority.json", ciAuthoritySha256: rfHex64(21),
        ciInputSha256: rfHex64(22), workingDirAbs: "/r",
        ciPrBranch: "feat/654-lane", ciBaseBranch: "main",
        runNonces: rfNonces(1) }), agentReturns: {} },
    { args: rfArgs({ mode: "review-pr", stage: "ci-defer", ciLoopIter: 3,
        ciAuthorityPathAbs: "/r/run/ci-authority.json", ciAuthoritySha256: rfHex64(21),
        ciAggregatePathAbs: "/r/run/ci-aggregate.md", ciAggregateSha256: rfHex64(24),
        ciInputSha256: rfHex64(22), runNonces: rfNonces(1) }), agentReturns: {} }
  ];
}

// scan_fleet. Its instance index is the TRAILING zero-padded area id pad()
// appends, carried by three of the twelve label expressions; the other nine are
// fixed literals. \d{3,} rather than \d{3} because pad() widens past three
// digits for an id >= 1000. This lane has no ":" in any label, so the ":" half
// of the launcher rule has nothing to act on.
var RE_SCAN_PAD_INDEX = /-\d{3,}$/;
function normScanFleet(label) {
  return String(label).replace(RE_SCAN_PAD_INDEX, "-NNN").split("-").join("_");
}
var SF_RD_SCAN = "/r/.uberdev/scan/RID";
var SF_RD_SIMP = "/r/.uberdev/simplify/RID";
function sfArgs(mode) {
  var RD = mode === "simplify" ? SF_RD_SIMP : SF_RD_SCAN;
  return JSON.stringify({
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "scan-fleet",
    config: {
      mode: mode, runId: "RID", runDirAbs: RD, pluginRootAbs: "/p", repoRootAbs: "/r",
      scope: ".", manifestPathAbs: RD + "/manifest.json", numAreas: 8, concurrency: 3,
      minSeverity: "major", maxNew: mode === "simplify" ? 10 : 15, maxAgents: 250,
      noIssues: false, noReport: false, lenses: "Reuse,Quality,Efficiency",
      branchName: mode === "simplify" ? "ubersimplify/RID" : "",
      timestampIso: "2026-01-01T00:00:00Z"
    }
  });
}
function sfScanReturns() {
  var RD = SF_RD_SCAN;
  return {
    "area-pack": { areaIds: ["1", "2"], areaCount: 2, overflow: false, rc: 0, skippedOversize: 0 },
    "scan-area-001": { areaId: "1", outPath: RD + "/chunk-001-findings.yaml", findingCount: 3, blockerCount: 1 },
    "scan-area-002": { areaId: "2", outPath: RD + "/chunk-002-findings.yaml", findingCount: 2, blockerCount: 0 },
    "global-pass": { semgrepPath: RD + "/global-security.md", coveragePath: RD + "/global-coverage.md", semgrepFindingCount: 4, coverageGapCount: 2, rc: 0 },
    "scan-aggregate": { reportPath: RD + "/uberscan-report.md", aggregatePath: RD + "/f2i-aggregate.md", totalFindings: 5, rc: 0 },
    "findings-to-issues": { issuesCreated: [201, 202], skipped: 1 }
  };
}
function sfSimplifyReturns(fixerStatus) {
  var RD = SF_RD_SIMP;
  return {
    "area-pack": { areaIds: ["1", "2"], areaCount: 2, overflow: false, rc: 0 },
    "simplify-area-001": { areaId: "1", outPath: RD + "/chunk-001-lens.yaml", findingCount: 2, blockerCount: 1 },
    "simplify-area-002": { areaId: "2", outPath: RD + "/chunk-002-lens.yaml", findingCount: 1, blockerCount: 0 },
    "fixer-agg-001": { outPath: RD + "/chunk-001-fixer.md", mergedCount: 2, rc: 0 },
    "fixer-agg-002": { outPath: RD + "/chunk-002-fixer.md", mergedCount: 1, rc: 0 },
    "apply-setup": { branch: "ubersimplify/RID", baseBranch: "main", rc: 0 },
    "fixer-001": { areaId: "1", status: fixerStatus, commitSha: "aaa111", dispositionPath: RD + "/chunk-001-fixer-disposition.json" },
    "fixer-002": { areaId: "2", status: fixerStatus, commitSha: "bbb222", dispositionPath: RD + "/chunk-002-fixer-disposition.json" },
    "open-pr": { prNumber: 303, prUrl: "https://example/pull/303", branch: "ubersimplify/RID", commitCount: 2, rc: 0 },
    "branch-cleanup": { branch: "", baseBranch: "main", rc: 0 },
    "simplify-issues-agg": { aggregatePath: RD + "/f2i-aggregate.md", rc: 0 },
    "findings-to-issues": { issuesCreated: [304], skipped: 0 }
  };
}
// THE THIRD RUN IS NOT REDUNDANT. branch-cleanup is the else arm of
// `appliedAreas > 0`: a run whose fixers all report APPLIED reaches open-pr and
// can NEVER reach branch-cleanup, and the reverse. The two arms are mutually
// exclusive in one invocation, so dropping this run pins the floor at 11 and
// silently certifies an eleven-site fleet.
function scanFleetRuns() {
  return [
    { args: sfArgs("scan"), agentReturns: sfScanReturns() },
    { args: sfArgs("simplify"), agentReturns: sfSimplifyReturns("APPLIED") },
    { args: sfArgs("simplify"), agentReturns: sfSimplifyReturns("NO_FIXES_NEEDED") }
  ];
}

// goal_pipeline. TWO instance dimensions, not one: a cycle index :c<n> and, in
// the watch loop, a tick index :t<n>. Order is load-bearing — both collapse
// while the colons are still colons, and only then is ":" mapped to "." and
// "-" to "_".
function normGoalPipeline(label) {
  return String(label)
    .replace(/:c\d+/g, ":cN")
    .replace(/:t\d+/g, ":tN")
    .split(":").join(".")
    .split("-").join("_");
}
function gpArgs() {
  return JSON.stringify({
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z", now_epoch: 1767225600,
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "goal",
    config: {
      pluginRootAbs: "/p", repoRootAbs: "/r", tmpDirAbs: "/t",
      goalId: "1700000000-abcd1234", issues: "11,12",
      maxCycles: 5, maxParallel: 3, maxAgents: 250, maxWatchTicks: 40,
      barrierTimeoutS: 14400, reviewGraceSecs: 3600,
      watchPasses: 0, watchBudgetS: 0, onlyMine: false, resumed: false,
      backend: "workflow", timestampIso: "2026-01-01T00:00:00Z"
    }
  });
}
// The fleet args envelope the claim relay hands back is itself a STRING the
// lane re-parses, and a claim whose envelope does not carry the CLAIMED issue
// set is refused before the nested workflow() fires. Deriving it from dispatch
// is therefore not cosmetic: a mismatched fixture would zero out the one edge
// this lane exists to expose while the run still looked healthy.
function gpFleetEnvelope(issues) {
  return JSON.stringify({
    v: 1, run_id: "RID", now_epoch: 1767225600, now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "solve-fleet",
    config: { runId: "RID", issues: issues, concurrency: 6 }
  });
}
function gpClaim(extra) {
  var r = {
    rc: 0, dispatch: "11,12", rollover: "", skipped: "",
    launcherRc: 0, armed: "11,12", markRc: 0, note: ""
  };
  if (extra) { Object.keys(extra).forEach(function (k) { r[k] = extra[k]; }); }
  r.fleetArgsJson = gpFleetEnvelope(r.dispatch);
  return r;
}
function gpCollect(extra) {
  var r = {
    rc: 0, decision: "converged", candidates: 0, queued: 0,
    queue: "", fingerprints: "", reason: "", phase: "", note: ""
  };
  if (extra) { Object.keys(extra).forEach(function (k) { r[k] = extra[k]; }); }
  return r;
}
function gpVerdicts() {
  return { rows: [{ pr: 901, signal: "green" }, { pr: 902, signal: "yellow" }] };
}
// Run 2 contributes NO NEW KIND and is kept anyway: without a second cycle the
// :c<n> collapse rests on an index that never varied, and the floor of 5 would
// not be known to be stable in the cycle count.
function goalPipelineRuns() {
  return [
    { args: gpArgs(), agentReturns: {
        "goal-claim:c1": gpClaim(),
        "goal-watch:c1:t1": { rc: 0, note: "drained" },
        "goal-verdicts:c1": gpVerdicts(),
        "goal-collect:c1": gpCollect()
      } },
    { args: gpArgs(), agentReturns: {
        "goal-claim:c1": gpClaim(),
        "goal-watch:c1:t1": { rc: 42, note: "bound" },
        "goal-watch:c1:t2": { rc: 0, note: "drained" },
        "goal-verdicts:c1": gpVerdicts(),
        "goal-collect:c1": gpCollect({ rc: 42, decision: "loop", candidates: 2,
          queued: 2, queue: "31,32", fingerprints: "aabbccdd11223344" }),
        "goal-claim:c2": gpClaim({ dispatch: "31,32", armed: "31,32" }),
        "goal-watch:c2:t1": { rc: 0, note: "drained" },
        "goal-verdicts:c2": gpVerdicts(),
        "goal-collect:c2": gpCollect({ candidates: 0 })
      } }
  ];
}

// testers_pipeline. Two instance dimensions, both loop variables: the round
// index -r<n> of the wave loop, and the persona name of the personas.map()
// fanout at the single persona site. The greedy (.*) takes the LAST -r<digits>
// so a persona name ending in digits still collapses; the [0-9]+$ anchor is
// what keeps report-runner out of the round arm.
function normTestersPipeline(label) {
  var s = String(label);
  var round = "";
  var m = s.match(/^(.*)-r([0-9]+)$/);
  if (m) { s = m[1]; round = "-rN"; }
  if (s.indexOf("persona-") === 0) { s = "persona-NAME"; }
  return (s + round).split("-").join("_");
}
// rounds and personas are DELIBERATELY OMITTED so the script own clamped
// defaults drive the fanout (rounds 3, DEFAULT_PERSONAS 6), which grounds the
// derived kind set in the script bytes rather than in a fixture-chosen roster.
// noIssues:false is what keeps the findings-to-issues site live — with it true
// the lane would silently derive 6 kinds from 6 sites.
function tpArgs() {
  var RD = "/r/.uberdev/research/RID/testers";
  return JSON.stringify({
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "testers",
    config: {
      runId: "RID", runDirAbs: RD, pluginRootAbs: "/p",
      target: "http://localhost:3000", surface: "web",
      rpsCap: 10, maxIssues: 10, noIssues: false,
      invariantsPathAbs: "/p/skills/testers-pipeline/invariants.yaml",
      invariantIds: "no_5xx,auth_isolation",
      timestampIso: "2026-01-01T00:00:00Z"
    }
  });
}
function testersPipelineRuns() {
  return [{ args: tpArgs(), agentReturns: {} }];
}

// uberthink_pipeline. Five instance tokens collapse — the island index k, the
// three-digit pad(c + 1) shortlist-row index, the -r<n> genetic round, the
// scope gate donor slug and the moderator gap id — and every script-declared
// literal is kept. UT_OPERATORS is the lane own OPERATORS list: gen-<k>-<x>
// carries either a declared operator name or an agent-returned donor slug in
// the same position, and only the first is a kind.
var UT_OPERATORS = ["triz", "morphological", "provocateur", "bridge"];
function normUberthinkPipeline(label) {
  var s = String(label);
  var m = /^falsify-\d+-\d{3}-(.+)-r\d+$/.exec(s);
  if (m) { return ("falsify_kN_cN_" + m[1] + "_rN").split("-").join("_"); }
  m = /^synth-\d+-(.+)-r\d+$/.exec(s);
  if (m) { return ("synth_kN_" + m[1] + "_rN").split("-").join("_"); }
  if (/^shortlist-\d+-r\d+$/.test(s)) { return "shortlist_kN_rN"; }
  if (/^moderator-\d+$/.test(s)) { return "moderator_kN"; }
  if (/^regen-\d+-.+$/.test(s)) { return "regen_kN_gap"; }
  m = /^gen-\d+-(.+)$/.exec(s);
  if (m) {
    return UT_OPERATORS.indexOf(m[1]) >= 0
      ? ("gen_kN_" + m[1]).split("-").join("_")
      : "gen_kN_donor";
  }
  return s.split("-").join("_");
}
var UT_RD = "/r/.uberdev/think/RID";
var UT_DONORS = ["distributed-systems", "compilers-pl", "databases", "operating-systems",
  "networking-protocols", "security-crypto", "concurrency", "compression-coding",
  "graph-theory", "information-theory", "biology", "economics-markets"];
function utArgs(extra) {
  var config = {
    runId: "RID", runDirAbs: UT_RD, pluginRootAbs: "/p", repoRootAbs: "/r",
    goal: "make a covert transport that resists active probing",
    islands: 2, concurrency: 64, maxAgents: 500, maxFlood: 120, loopBackCap: 3,
    shortlistTop: 7, maxNew: 3, handoff: true, noIssues: false,
    resumeFromRunId: "", timestampIso: "2026-01-01T00:00:00Z"
  };
  if (extra) { Object.keys(extra).forEach(function (k) { config[k] = extra[k]; }); }
  return JSON.stringify({
    v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z",
    plugin_root: "/p", repo_root: "/r", cwd: "/r", pipeline: "uberthink-pipeline",
    config: config
  });
}
function utNamed(n) { return { name: n, role: n, prompt: "P-" + n }; }
function utPersonas() {
  return {
    rc: 0,
    frameLenses: [utNamed("schema"), utNamed("teardown"), utNamed("prior-art"), utNamed("constraints")],
    generators: [{ name: "field_scout", kind: "field_scout", prompt: "P-scout" },
      { name: "triz", kind: "operator", prompt: "P-triz" },
      { name: "morphological", kind: "operator", prompt: "P-morph" },
      { name: "provocateur", kind: "operator", prompt: "P-prov" },
      { name: "bridge", kind: "meta", prompt: "P-bridge" }],
    moderator: { role: "Moderator", prompt: "P-mod" },
    synthesizerLenses: [utNamed("weave"), utNamed("crossover"), utNamed("mutate")],
    falsifierLenses: [utNamed("steelman"), utNamed("premortem"), utNamed("redteam"), utNamed("physics")]
  };
}
// TWO shortlist rows per island so pad(c + 1) actually varies (001 and 002),
// and compositePaths that sit under runDirAbs and end in .yaml: underRunDir()
// drops every row that does not, and a dropped row means the falsify site never
// dispatches at all.
function utShortlist(k) {
  return { rc: 0, stderrTail: "", outPath: UT_RD + "/island-" + k + "/shortlist.yaml",
    shortlist: ["comp-island-" + k + "-001", "comp-island-" + k + "-002"],
    compositePaths: [UT_RD + "/island-" + k + "/composites/comp-001-weave.yaml",
      UT_RD + "/island-" + k + "/composites/comp-002-crossover.yaml"],
    count: 2 };
}
function utGaps(k, ids) {
  return { islandIndex: k, gapCount: ids.length, outPath: UT_RD + "/island-" + k + "/gaps.yaml",
    gaps: ids.map(function (id, i) {
      return { id: id, persona: UT_OPERATORS[i % UT_OPERATORS.length], donor: "", prompt: "q-" + id };
    }) };
}
function utReturns(extra) {
  var r = {
    "personas": utPersonas(),
    "scope-gate": { verdict: "PROCEED", rationale: "legitimate defensive research",
      framePath: UT_RD + "/frame/frame.md", scopeVerdictPath: UT_RD + "/frame/scope-verdict.yaml",
      donors: UT_DONORS },
    "uberdev:uberthink-frame": { lens: "teardown", status: "ok", outPath: UT_RD + "/frame/teardown.md" },
    "uberdev:uberthink-generator": { islandIndex: 1, persona: "field_scout", candidateCount: 3,
      outPath: UT_RD + "/island-1/candidates/c.yaml" },
    "moderator-1": utGaps(1, ["gap-aa", "gap-bb", "gap-cc"]),
    "moderator-2": utGaps(2, ["gap-dd", "gap-ee", "gap-ff"]),
    "uberdev:uberthink-synthesizer": { islandIndex: 1, lens: "weave", compositeCount: 2,
      outDir: UT_RD + "/island-1/composites" },
    "shortlist-1-r0": utShortlist(1),
    "shortlist-2-r0": utShortlist(2),
    "uberdev:uberthink-falsifier": { islandIndex: 1, compositeId: "comp-island-1-001",
      lens: "steelman", outPath: UT_RD + "/island-1/falsify/x.yaml", fatalKills: 1,
      fixableKills: 0, repairHints: [] },
    "cross-pollinate": { islandIndex: 1, lens: "crossover", compositeCount: 3,
      outDir: UT_RD + "/composites" },
    "floor-survivors": { rc: 0, stderrTail: "", outPath: UT_RD + "/floor-survivors.yaml",
      shortlist: ["comp-island-1-001", "comp-island-2-001"], count: 2 },
    "arbiter": { rankedPath: UT_RD + "/ranked.yaml", rankedCount: 3, culledCount: 1 },
    "dossier": { rc: 0, stderrTail: "", outPath: UT_RD + "/report.md" },
    "aggregate": { rc: 0, stderrTail: "", outPath: UT_RD + "/f2i-aggregate.md" },
    "findings-to-issues": { issuesCreated: [901, 902], skipped: 1 },
    "partial-report": { rc: 0, stderrTail: "", outPath: UT_RD + "/report.md" },
    "refusal-report": { rc: 0, stderrTail: "", outPath: UT_RD + "/report.md" },
    "handoff-seed": { rc: 0, stderrTail: "", outPath: UT_RD + "/handoff-seed.md" },
    "resume-scan": { runDirExists: true, verdict: "", frameLensesPresent: [],
      islandsWithCandidates: [], islandsWithShortlist: [], globalCompositeCount: 0,
      rankedExists: false, donors: [] }
  };
  if (extra) { Object.keys(extra).forEach(function (k) { r[k] = extra[k]; }); }
  return r;
}
// SIX ARMS, and every one of them reaches a site the others cannot: resume-scan
// only under --resume, refusal-report only on a REFUSE verdict, the
// cross-pollinate passthrough only at islands 1, partial-report only when the
// arbiter returns nothing, and the -r<n> round only varies once the falsifiers
// return repair hints under a loop-back cap.
function uberthinkPipelineRuns() {
  return [
    { args: utArgs(), agentReturns: utReturns() },
    { args: utArgs({ resumeFromRunId: "PRIOR" }), agentReturns: utReturns() },
    { args: utArgs(), agentReturns: utReturns({
        "scope-gate": { verdict: "REFUSE", rationale: "weaponisation request",
          framePath: UT_RD + "/frame/frame.md", donors: [] } }) },
    { args: utArgs({ islands: 1 }), agentReturns: utReturns() },
    { args: utArgs(), agentReturns: utReturns({ "arbiter": null }) },
    { args: utArgs({ loopBackCap: 1 }), agentReturns: utReturns({
        "uberdev:uberthink-falsifier": { islandIndex: 1, compositeId: "comp-island-1-001",
          lens: "steelman", outPath: UT_RD + "/island-1/falsify/x.yaml", fatalKills: 0,
          fixableKills: 2, repairHints: ["tighten the timing channel"] },
        "shortlist-1-r1": utShortlist(1),
        "shortlist-2-r1": utShortlist(2) }) }
  ];
}

// ---------------------------------------------------------------------------
// THE LANES TABLE (#654). The rule layer stops being single-substrate: the five
// rules below take a lane record instead of closing over SRC_REL, so widening the
// file to another fleet is adding a member here rather than forking a rule.
// solve_fleet keeps its normalizer, its floor, its fixture and its
// argv-supplied site count byte for byte, so rows Z0-Z17 are unchanged in
// label, order and semantics.
//
// runs IS REQUIRED AND NON-EMPTY FOR EVERY MEMBER, and it is a LIST because a
// lane whose stage is selected by its args cannot be driven to its full
// surface in one invocation. A member without runs is a FATAL, never a skip: a
// rule that silently skips a lane is a permanently green hole of exactly the
// class this file exists to close. The check is at the top of the comparator.
//
// IT SITS HERE, BELOW EXECUTED_KIND_FLOOR, ON PURPOSE. The table is a var
// INITIALIZER, not a hoisted function declaration, so it is evaluated in source
// order. Read kindFloor from a constant declared further down the file and the
// field lands undefined, every comparison against it is false, and the lane
// reds for a reason that looks nothing like its cause. Keep any new member
// below every constant it interpolates.
// ---------------------------------------------------------------------------
var LANES = [
  {
    id: "solve_fleet",
    source: SRC_REL,
    normalize: kindOf,
    kindFloor: EXECUTED_KIND_FLOOR,
    sites: SITES,
    runs: [ { args: buildArgs(), agentReturns: agentReturns() } ]
  },
  // The five fleet lanes, in a FIXED order the row labels below depend on.
  // Every field is the number the lane derivation MEASURED by executing that
  // lane under the harness, never a number read off a design table.
  {
    id: "review_fleet",
    source: ANCHOR + "skills/review-fleet/workflow.js",
    normalize: normReviewFleet,
    kindFloor: 12,
    sites: countSites(laneSrc.review_fleet),
    renameFrom: "label: \"findings-to-issues\"",
    renameTo: "label: \"findings-to-issues-renamed\"",
    rows: { a: "Z23", b: "Z24", c: "Z25", d: "Z26", e: "Z27", f: "Z28" },
    runs: reviewFleetRuns()
  },
  {
    id: "scan_fleet",
    source: ANCHOR + "skills/scan-fleet/workflow.js",
    normalize: normScanFleet,
    kindFloor: 12,
    sites: countSites(laneSrc.scan_fleet),
    renameFrom: "label: \"branch-cleanup\"",
    renameTo: "label: \"branch-teardown\"",
    rows: { a: "Z29", b: "Z30", c: "Z31", d: "Z32", e: "Z33", f: "Z34" },
    runs: scanFleetRuns()
  },
  {
    id: "goal_pipeline",
    source: ANCHOR + "skills/goal-pipeline/workflow.js",
    normalize: normGoalPipeline,
    kindFloor: 5,
    sites: countSites(laneSrc.goal_pipeline),
    renameFrom: "\"goal-collect:c\"",
    renameTo: "\"goal-collectx:c\"",
    rows: { a: "Z35", b: "Z36", c: "Z37", d: "Z38", e: "Z39", f: "Z40" },
    runs: goalPipelineRuns()
  },
  {
    id: "testers_pipeline",
    source: ANCHOR + "skills/testers-pipeline/workflow.js",
    normalize: normTestersPipeline,
    kindFloor: 7,
    sites: countSites(laneSrc.testers_pipeline),
    renameFrom: "\"aggregate-A-r\"",
    renameTo: "\"aggregate-Q-r\"",
    rows: { a: "Z41", b: "Z42", c: "Z43", d: "Z44", e: "Z45", f: "Z46" },
    runs: testersPipelineRuns()
  },
  {
    id: "uberthink_pipeline",
    source: ANCHOR + "skills/uberthink-pipeline/workflow.js",
    normalize: normUberthinkPipeline,
    kindFloor: 31,
    sites: countSites(laneSrc.uberthink_pipeline),
    renameFrom: "synth-",
    renameTo: "synthX-",
    rows: { a: "Z47", b: "Z48", c: "Z49", d: "Z50", e: "Z51", f: "Z52" },
    runs: uberthinkPipelineRuns()
  }
];
var SOLVE_LANE = LANES[0];
// The five fleet lanes, in table order. Deriving them by slice rather than by
// name keeps ONE ordering source; the FATAL beneath is what stops a lane from
// disappearing quietly, because a vanished lane takes its four rows with it and
// the row-count lock at the bottom would then be the only thing left to notice.
var FLEET_LANES = LANES.slice(1);
if (FLEET_LANES.length !== 5) {
  throw new Error("expected exactly 5 fleet lanes beyond solve_fleet, found "
    + FLEET_LANES.length + " — a lane vanished and its rows would have vanished with it");
}

function rC4(lane, live) {
  return live.length >= lane.kindFloor
    ? []
    : ["lane " + lane.id + ": the executed kind set has only " + live.length
       + " member(s), below the floor of " + lane.kindFloor
       + " — the fixture is not reaching every rung of the fleet"];
}

function rC5(t, lane) {
  var E = entryFor(t, lane.source);
  if (!E) return ["lane " + lane.id + ": no scope.does_not_govern entry declares source " + lane.source];
  return E.dispatch_sites === lane.sites
    ? []
    : ["lane " + lane.id + ": dispatch_sites=" + JSON.stringify(E.dispatch_sites)
       + " but the source has " + lane.sites + " dispatch site(s)"];
}

// C8 — COMPLETENESS. The only rule here whose universe is not the manifest.
// Two self-checks come first, because a completeness rule that has gone blind
// reports perfect coverage: the floor catches a rotted pattern, and the
// known-positive catches an enumeration that can no longer see even the
// substrate does_not_govern[] already declares.
function rC8(t, lsrc) {
  var e = [];
  var found = enumerateSubstrates(lsrc, edgeSourceSet(t));
  if (found.length < SUBSTRATE_FLOOR) {
    e.push("the launcher enumeration yielded only " + found.length + " dispatch substrate(s), below the floor of "
      + SUBSTRATE_FLOOR + " — a pattern has rotted and C8 would certify by blindness");
  }
  var sawFleet = found.filter(function (s) { return s.source === SRC_REL; }).length > 0;
  if (!sawFleet) {
    e.push("the enumeration cannot see " + SRC_REL + ", which does_not_govern[] ALREADY declares — the predicate is broken, so its silence about every other substrate means nothing");
  }
  var declared = {};
  (entriesOf(t) || []).forEach(function (x) { if (isObj(x) && isStr(x.source)) { declared[x.source] = 1; } });
  found.forEach(function (s) {
    if (s.family === "routed-child-dispatch") { return; }
    if (declared[s.source]) { return; }
    e.push("UNDECLARED SUBSTRATE " + s.source + " (" + s.family + ") is reachable from "
      + LAUNCHER_REL + " and no scope.does_not_govern entry names it");
  });
  return e;
}

// C9 — the C1/C5 pair for a substrate whose source is PROSE. There is no script
// to execute, so the evidence is the set of shipped-agent identifiers the source
// names and how many times it names them. Every mention in such a source is a
// dispatch instruction; a rung added or removed moves both numbers.
function rC9(t, lsrc) {
  var e = [];
  var bySource = {};
  (entriesOf(t) || []).forEach(function (x) { if (isObj(x) && isStr(x.source)) { bySource[x.source] = x; } });
  enumerateSubstrates(lsrc, edgeSourceSet(t)).forEach(function (s) {
    if (s.family !== "session-task-fanout") { return; }
    var E = bySource[s.source];
    if (!E) { return; }  // rC8 owns the undeclared case; do not report it twice.
    var counts = agentMentions(bodyOf(s.source));
    var wantKinds = Object.keys(counts).map(normKind).sort();
    var wantSites = 0;
    Object.keys(counts).forEach(function (k) { wantSites += counts[k]; });
    var gotKinds = Array.isArray(E.agent_kinds) ? E.agent_kinds.slice().sort() : [];
    if (gotKinds.join(",") !== wantKinds.join(",")) {
      e.push(s.source + " declares agent_kinds [" + gotKinds.join(",")
        + "] but its source names [" + wantKinds.join(",") + "]");
    }
    if (E.dispatch_sites !== wantSites) {
      e.push(s.source + " declares dispatch_sites=" + JSON.stringify(E.dispatch_sites)
        + " but its source carries " + wantSites + " dispatch mention(s)");
    }
  });
  return e;
}

// The rule ORDER is preserved deliberately — the manifest-wide rules first, the
// per-lane block in the middle, the enumeration rules last — so the failure text
// the existing rows emit is unchanged by the widening.
//
// A MISSING LIVE SET THROWS rather than being treated as an empty one. An empty
// array would sail through rC1 as "nothing dispatched, nothing declared" and
// certify the lane by silence, which is the failure mode this table exists to
// remove.
function check(t, liveByLane, lsrc) {
  var e = [].concat(rGoverns(t), rEntryShape(t), rC6(t));
  LANES.forEach(function (lane) {
    var live = liveByLane[lane.id];
    if (!Array.isArray(live)) {
      throw new Error("no live kind set for lane " + lane.id + " — a lane is never skipped");
    }
    e = e.concat(rC1(t, lane, live), rC2(t, lane), rC3(t, lane), rC4(lane, live), rC5(t, lane));
  });
  return e.concat(rC8(t, lsrc), rC9(t, lsrc));
}

function copyTree() { return JSON.parse(JSON.stringify(tree)); }

(async function () {
  // A lane carrying no runs cannot be derived, and a derivation that cannot run
  // must not degrade into a skip: a skipped lane is declared-only again, which
  // is the single-substrate blindness the table replaces. FATAL before any row
  // is emitted — the catch below writes the stack and exits non-zero, and the
  // bash wrapper turns that into exit 2.
  LANES.forEach(function (lane) {
    if (!Array.isArray(lane.runs) || lane.runs.length === 0) {
      throw new Error("LANES member " + lane.id + " carries no runs — a lane is a FATAL, never a skip (#654)");
    }
  });

  // One live kind set per lane, derived by EXECUTING that lane. The loop is
  // indexed rather than a forEach because await inside a forEach callback does
  // not suspend the loop, so the runs would race instead of running in series.
  var LIVE_BY_LANE = {};
  for (var lx = 0; lx < LANES.length; lx++) {
    var L = LANES[lx];
    var srcL = (L.id === "solve_fleet") ? srcBase : laneSrc[L.id];
    LIVE_BY_LANE[L.id] = await liveOf(L, srcL);
  }

  var recBase = await runFixture(SOLVE_LANE, srcBase, SOLVE_LANE.runs[0]);

  var z0 = [];
  if (recBase.violations.length) z0.push("harness violations: " + recBase.violations.join(" | "));
  if (recBase.agentCalls.length === 0) z0.push("the fixture dispatched no agent at all");
  var unlabelled = recBase.agentCalls.filter(function (c) { return !isStr(c.label); }).length;
  if (unlabelled > 0) z0.push(unlabelled + " dispatch(es) carry no opts.label, so their kind would normalize to the empty string");
  row(z0.length === 0, "Z0 the fleet fixture runs clean and every dispatch carries a label" + tail(z0));

  // The solve-fleet live set, read out of the per-lane map so the Z4/Z5 row
  // label expressions below are untouched by the widening.
  var LIVE = LIVE_BY_LANE.solve_fleet;

  var e1 = rGoverns(tree);
  row(e1.length === 0, "Z1 scope.governs names the substrate, its adapter, a note and the agent-kind rule" + tail(e1));

  var e2 = rEntryShape(tree);
  row(e2.length === 0, "Z2 every does_not_govern entry carries the full evidence record with the right types" + tail(e2));

  var e3 = rC6(tree);
  row(e3.length === 0, "Z3 C6: each declared source is a real file under plugins/uberdev/ with a non-colliding prefix" + tail(e3));

  var e4 = rC4(SOLVE_LANE, LIVE);
  row(e4.length === 0, "Z4 C4: the executed fleet yields at least " + EXECUTED_KIND_FLOOR
      + " agent kinds (" + LIVE.join(",") + ")" + tail(e4));

  var e5 = rC1(tree, SOLVE_LANE, LIVE);
  row(e5.length === 0, "Z5 C1: declared kinds UNION edge-covered kinds equals the EXECUTED kinds" + tail(e5));

  var e6 = rC2(tree, SOLVE_LANE);
  row(e6.length === 0, "Z6 C2: no kind is both ungoverned and edge-covered" + tail(e6));

  var e7 = rC3(tree, SOLVE_LANE);
  row(e7.length === 0, "Z7 C3: every edge sourced from the fleet script sits under its reserved prefix" + tail(e7));

  var e8 = rC5(tree, SOLVE_LANE);
  row(e8.length === 0, "Z8 C5: dispatch_sites matches the " + SITES + " static dispatch site(s) in the fleet script" + tail(e8));

  // ------------------------------------------------------------------------
  // Differential rows. Each asserts BOTH halves: the UNMUTATED inputs are clean
  // AND the mutant is dirty. Stated one-sidedly ("the mutant fails") a row
  // passes vacuously on a manifest that fails for everything — which is exactly
  // the shape this issue is about.
  // ------------------------------------------------------------------------
  var baseErrs = check(tree, LIVE_BY_LANE, launcherBase);

  function differential(label, applied, notApplied, mutErrs) {
    var why = [];
    if (!applied) {
      why.push(notApplied);
    } else {
      if (baseErrs.length) why.push("the UNMUTATED inputs already fail: " + baseErrs.join("; "));
      if (mutErrs.length === 0) why.push("the mutant still validates");
    }
    row(applied && baseErrs.length === 0 && mutErrs.length > 0, label + tail(why));
  }

  var LIT = "\"spec-review:#\"";
  var mutSrc = srcBase.split(LIT).join("\"spec-revue:#\"");
  var errs9 = [];
  if (mutSrc !== srcBase) {
    // Only the mutated lane is re-executed; every other lane keeps its cached
    // live set, so a differential costs one script run rather than one per lane.
    var live9 = await liveOf(SOLVE_LANE, mutSrc);
    errs9 = check(tree, withLane(LIVE_BY_LANE, SOLVE_LANE.id, live9), launcherBase);
  }
  differential("Z9 renaming a label in the EXECUTED script reds the comparator",
    mutSrc !== srcBase,
    "the label literal " + LIT + " is gone from the fleet script, so the mutation never applied",
    errs9);

  var t10 = copyTree();
  var E10 = entryFor(t10, SRC_REL);
  var applied10 = !!(E10 && Array.isArray(E10.agent_kinds) && E10.agent_kinds.length > 0);
  if (applied10) E10.agent_kinds.splice(0, 1);
  differential("Z10 deleting a declared agent kind reds the comparator",
    applied10, "there is no declaration to shrink",
    applied10 ? check(t10, LIVE_BY_LANE, launcherBase) : []);

  var t11 = copyTree();
  var E11 = entryFor(t11, SRC_REL);
  var applied11 = !!(E11 && Array.isArray(E11.agent_kinds));
  if (applied11) E11.agent_kinds.push("invented_kind");
  differential("Z11 declaring a kind the fleet never dispatches reds the comparator",
    applied11, "there is no declaration to extend",
    applied11 ? check(t11, LIVE_BY_LANE, launcherBase) : []);

  var t12 = copyTree();
  var E12 = entryFor(t12, SRC_REL);
  var applied12 = !!E12;
  if (applied12) E12.dispatch_sites = SITES + 1;
  differential("Z12 drifting the dispatch_sites backstop reds the comparator",
    applied12, "there is no entry to drift",
    applied12 ? check(t12, LIVE_BY_LANE, launcherBase) : []);

  var FOUND = enumerateSubstrates(launcherBase, edgeSourceSet(tree));
  var e13 = rC8(tree, launcherBase);
  row(e13.length === 0, "Z13 C8: every dispatch substrate reachable from " + LAUNCHER_REL
      + " is governed or declared ("
      + FOUND.map(function (s) { return s.source + "=" + s.family; }).join(" ") + ")" + tail(e13));

  var e14 = rC9(tree, launcherBase);
  row(e14.length === 0, "Z14 C9: each declared prose substrate agent_kinds and dispatch_sites are derived from its own source" + tail(e14));

  // The C8 universe is only the run tree universe while the file it is read
  // from is still the tree root. Anchoring it here means a re-rooted manifest
  // reds instead of quietly leaving C8 enumerating a retired entrypoint.
  var rootEdges = isObj(tree.edges) ? tree.edges : {};
  var rootEdge = isObj(rootEdges[tree.root_edge_id]) ? rootEdges[tree.root_edge_id] : null;
  var rootSrc = rootEdge ? rootEdge.source : null;
  var e15 = rootSrc === LAUNCHER_REL ? []
    : ["root_edge_id " + JSON.stringify(tree.root_edge_id) + " is sourced from "
       + JSON.stringify(rootSrc) + ", not " + LAUNCHER_REL];
  row(e15.length === 0, "Z15 the C8 universe is read from the run tree own root_edge source" + tail(e15));

  // ------------------------------------------------------------------------
  // Z16 — THE ANTI-VACUITY ROW for C8. Everything above this point could hold
  // on an enumerator that returns the declared set and nothing else. This one
  // cannot: it splices a path into a COPY of the launcher source naming a real
  // dispatch substrate that does_not_govern[] does not declare, and demands the
  // comparator notice. The fixture is a shipped dispatch substrate outside this
  // manifest scope, so it is undeclared for a real reason rather than a
  // synthetic one, and the three guards on applied16 refuse to let the row
  // count if it ever goes missing, becomes enumerated, or becomes declared.
  //
  // THE FIXTURE MOVED IN #654, and the third guard is why. It used to be
  // skills/review-fleet/workflow.js — undeclared at the time, and the last
  // guard would now be false because that lane is declared above, flipping this
  // row to FAIL on a manifest that got MORE complete. The guard did its job:
  // it refuses to certify by splicing in something already declared. Every
  // shipped Workflow fleet is declared now, so the replacement is the other
  // shape of undeclared substrate the enumerator classifies — the /merge
  // session-Task fanout, which dispatches uberdev:conflict-resolver,
  // uberdev:merge-strategy-decider and uberdev:trust-trail-evaluator through
  // the Task tool, sources no routed adapter, and is rooted in a command this
  // run tree never reaches. It is outside this manifest scope for a real
  // reason, exactly as its predecessor was.
  // ------------------------------------------------------------------------
  var FIXTURE_REL = ANCHOR + "skills/merge-pipeline/SKILL.md";
  var alreadySeen = FOUND.filter(function (s) { return s.source === FIXTURE_REL; }).length > 0;
  var applied16 = fs.existsSync(REPO_PREFIX + FIXTURE_REL) && !alreadySeen && !entryFor(tree, FIXTURE_REL);
  var lsrcMut = launcherBase + "\n# scope-test fixture lane surface: " + FIXTURE_REL.slice(ANCHOR.length) + "\n";
  differential("Z16 a dispatch substrate the launcher reaches and nobody declares reds C8",
    applied16,
    "the fixture substrate " + FIXTURE_REL + " is missing from disk, already enumerated, or already declared, so splicing it in would prove nothing",
    applied16 ? check(tree, LIVE_BY_LANE, lsrcMut) : []);

  var t17 = copyTree();
  var TURBOX_REL = ANCHOR + "skills/turbox-fleet/SKILL.md";
  var d17 = entriesOf(t17) || [];
  var idx17 = -1;
  for (var i17 = 0; i17 < d17.length; i17++) {
    if (isObj(d17[i17]) && d17[i17].source === TURBOX_REL) { idx17 = i17; }
  }
  var applied17 = idx17 >= 0;
  if (applied17) { d17.splice(idx17, 1); }
  differential("Z17 deleting the /turbox declaration reds C8",
    applied17, "does_not_govern[] carries no entry sourced from " + TURBOX_REL,
    applied17 ? check(t17, LIVE_BY_LANE, launcherBase) : []);

  // ------------------------------------------------------------------------
  // PER-LANE ROWS (#654). ONE indexed loop over the five fleet lanes, in fixed
  // lane order, emitting (a) C1, (b) C4, (c) C5 and (e) the rename differential
  // for each lane before moving to the next. Indexed rather than forEach
  // because await inside a forEach callback does not suspend the loop, so the
  // rename re-executions would race instead of running in series.
  //
  // THE LABELS ARE FINAL AND NON-CONTIGUOUS ON PURPOSE: the (d) root-naming row
  // and the (f) entry-deletion row land in a later change at the gaps left
  // here, so nothing is ever renumbered. Do not tidy these into a contiguous
  // run — the byte-identity of rows Z0-Z17 and the exact row-count lock at the
  // bottom of this file are what a renumbering silently breaks.
  //
  // rC2 and rC3 get NO ROW OF THEIR OWN here, which is why the per-lane row
  // count is four and not six. Zero edges are sourced from any of these five
  // lanes today, so an edge-covered set is empty and both rules are
  // structurally vacuous for them. They still run inside check(), so an edge
  // added later must land under the reserved prefix — but a row asserting a
  // vacuous truth is a permanently green row, and this file does not ship one.
  // ------------------------------------------------------------------------
  for (var fi = 0; fi < FLEET_LANES.length; fi++) {
    var laneF = FLEET_LANES[fi];
    var liveF = LIVE_BY_LANE[laneF.id];

    var eA = rC1(tree, laneF, liveF);
    row(eA.length === 0, laneF.rows.a + " C1 " + laneF.id
        + ": declared kinds UNION edge-covered kinds equals the EXECUTED kinds" + tail(eA));

    var eB = rC4(laneF, liveF);
    row(eB.length === 0, laneF.rows.b + " C4 " + laneF.id
        + ": the executed lane yields at least " + laneF.kindFloor
        + " agent kinds (" + liveF.join(",") + ")" + tail(eB));

    var eC = rC5(tree, laneF);
    row(eC.length === 0, laneF.rows.c + " C5 " + laneF.id
        + ": dispatch_sites matches the " + laneF.sites
        + " static dispatch site(s) in the lane script" + tail(eC));

    // (e) THE RENAME DIFFERENTIAL. The literal Z16 splice does not transfer to
    // these lanes: their universe is a filesystem path handed in on argv, not a
    // path enumerator over their own bytes, so splicing a path literal into one
    // of them changes nothing any rule reads and a per-lane Z16 replica would
    // be a PERMANENTLY GREEN row. A rename is an ADD plus a DELETE, so this
    // proves the add-direction sensitivity AND proves the derivation re-reads
    // this lane own bytes at run time, which the literal splice could not. It
    // also kills a degenerate normalizer: one that mapped every label to a
    // constant could not red here. Only the mutated lane re-executes; every
    // other lane reuses its cached live set, so a differential costs one lane
    // run rather than six.
    var baseSrcF = laneSrc[laneF.id];
    var mutSrcF = baseSrcF.split(laneF.renameFrom).join(laneF.renameTo);
    var errsF = [];
    if (mutSrcF !== baseSrcF) {
      var liveMutF = await liveOf(laneF, mutSrcF);
      errsF = check(tree, withLane(LIVE_BY_LANE, laneF.id, liveMutF), launcherBase);
    }
    differential(laneF.rows.e + " renaming a label literal in the EXECUTED "
        + laneF.id + " script reds the comparator",
      mutSrcF !== baseSrcF,
      "the label literal " + laneF.renameFrom + " is gone from " + laneF.source
        + ", so the mutation never applied",
      errsF);
  }

  process.stdout.write(rows.join("\n") + "\n");
})().catch(function (e) {
  process.stderr.write("comparator threw: " + ((e && e.stack) ? e.stack : String(e)) + "\n");
  process.exit(1);
});
' "$HARNESS" "$WORKFLOW" "$MANIFEST" "$SITES" "$LAUNCHER" \
  "$L_REVIEW" "$L_SCAN" "$L_GOAL" "$L_TESTERS" "$L_UBERTHINK")"
NODE_RC=$?
[ "$NODE_RC" -eq 0 ] || {
  echo "FATAL: the node comparator threw (rc=$NODE_RC) — see the stderr above" >&2
  exit 2
}
ROWS="$(printf '%s\n' "$ROWS" | tr -d '\r')"

ROW_COUNT=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ROW_COUNT=$((ROW_COUNT + 1))
  case "$line" in
    PASS::*) pass "${line#PASS::}" ;;
    FAIL::*) fail "${line#FAIL::}" ;;
    *)       fail "unparseable comparator row: $line" ;;
  esac
done <<<"$ROWS"

# EXACTLY, not at least. Every row() call above is unconditional, so the count is
# deterministic — and a `-ge` floor cannot tell "a row was deleted" from "a row
# was added", which is how Z13-Z17 could be landed while Z0-Z12 quietly stopped
# running. Same predicate, same reason, as E70 in tests/solve-run-tree.test.sh.
#
# 38 = 18 + 4 x 5: the eighteen manifest-wide and launcher-lane rows Z0-Z17,
# plus four rows for each of the five fleet lanes. The LABELS run to Z51 with
# GAPS — Z18-Z22, Z26, Z28, Z32, Z34, Z38, Z40, Z44, Z46, Z50, Z52 are reserved
# for the rows a later change fills in place. A label is a name, not an index:
# renumbering them to close the gaps would break the byte-identity of Z0-Z17 and
# leave this lock passing on a set of rows nobody meant to ship.
[ "$ROW_COUNT" -eq 38 ] || {
  echo "FATAL: the comparator emitted $ROW_COUNT row(s), expected exactly 38" >&2
  exit 2
}

echo ""
echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
