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
#   C4  the executed set has at least EXECUTED_KIND_FLOOR kinds (a RATCHET, not
#       a magic number — see the constant)
#   C5  dispatch_sites matches the static site count grepped below
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

for f in "$HARNESS" "$WORKFLOW" "$MANIFEST" "$LAUNCHER"; do
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

var srcBase = fs.readFileSync(WORKFLOW, "utf8");
var tree = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
var launcherBase = fs.readFileSync(LAUNCHER, "utf8");

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
function runFixture(source) {
  var meta = h.extractMeta(source).meta;
  var pre = h.preprocess(source);
  var record = h.makeRecord();
  var sb = h.makeSandbox({ args: buildArgs(), agentReturns: agentReturns() }, meta, record).sandbox;
  var pending = vm.runInNewContext(pre.wrapped, sb, { filename: "solve-fleet-scope", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function liveKinds(record) {
  var seen = {};
  record.agentCalls.forEach(function (c) { seen[kindOf(c.label)] = 1; });
  return Object.keys(seen).sort();
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

function rC1(t, live) {
  var E = entryFor(t, SRC_REL);
  if (!E) return ["no scope.does_not_govern entry declares source " + SRC_REL];
  var declared = Array.isArray(E.agent_kinds) ? E.agent_kinds : [];
  var union = {};
  declared.concat(edgeCovered(t, E)).forEach(function (k) { union[k] = 1; });
  var e = [];
  var missing = live.filter(function (k) { return !union[k]; });
  var extra = Object.keys(union).filter(function (k) { return live.indexOf(k) < 0; }).sort();
  if (missing.length) e.push("dispatched but undeclared: " + missing.join(","));
  if (extra.length) e.push("declared but never dispatched: " + extra.join(","));
  return e;
}

function rC2(t) {
  var E = entryFor(t, SRC_REL);
  if (!E) return ["no scope.does_not_govern entry declares source " + SRC_REL];
  var declared = Array.isArray(E.agent_kinds) ? E.agent_kinds : [];
  var covered = edgeCovered(t, E);
  var both = declared.filter(function (k) { return covered.indexOf(k) >= 0; }).sort();
  return both.length ? ["kinds are BOTH ungoverned and edge-covered: " + both.join(",")] : [];
}

function rC3(t) {
  var E = entryFor(t, SRC_REL);
  if (!E) return ["no scope.does_not_govern entry declares source " + SRC_REL];
  var edges = isObj(t) && isObj(t.edges) ? t.edges : {};
  var bad = Object.keys(edges).filter(function (id) {
    var row2 = edges[id];
    return isObj(row2) && row2.source === E.source && id.indexOf(E.reserved_edge_prefix) !== 0;
  }).sort();
  return bad.length
    ? ["edges sourced from " + E.source + " sit outside the reserved prefix: " + bad.join(",")]
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

function rC4(live) {
  return live.length >= EXECUTED_KIND_FLOOR
    ? []
    : ["the executed kind set has only " + live.length + " member(s), below the floor of "
       + EXECUTED_KIND_FLOOR + " — the fixture is not reaching every rung of the fleet"];
}

function rC5(t, sites) {
  var E = entryFor(t, SRC_REL);
  if (!E) return ["no scope.does_not_govern entry declares source " + SRC_REL];
  return E.dispatch_sites === sites
    ? []
    : ["dispatch_sites=" + JSON.stringify(E.dispatch_sites) + " but the source has " + sites + " dispatch site(s)"];
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

function check(t, live, sites, lsrc) {
  return [].concat(
    rGoverns(t), rEntryShape(t), rC6(t),
    rC1(t, live), rC2(t), rC3(t), rC4(live), rC5(t, sites),
    rC8(t, lsrc), rC9(t, lsrc)
  );
}

function copyTree() { return JSON.parse(JSON.stringify(tree)); }

(async function () {
  var recBase = await runFixture(srcBase);

  var z0 = [];
  if (recBase.violations.length) z0.push("harness violations: " + recBase.violations.join(" | "));
  if (recBase.agentCalls.length === 0) z0.push("the fixture dispatched no agent at all");
  var unlabelled = recBase.agentCalls.filter(function (c) { return !isStr(c.label); }).length;
  if (unlabelled > 0) z0.push(unlabelled + " dispatch(es) carry no opts.label, so their kind would normalize to the empty string");
  row(z0.length === 0, "Z0 the fleet fixture runs clean and every dispatch carries a label" + tail(z0));

  var LIVE = liveKinds(recBase);

  var e1 = rGoverns(tree);
  row(e1.length === 0, "Z1 scope.governs names the substrate, its adapter, a note and the agent-kind rule" + tail(e1));

  var e2 = rEntryShape(tree);
  row(e2.length === 0, "Z2 every does_not_govern entry carries the full evidence record with the right types" + tail(e2));

  var e3 = rC6(tree);
  row(e3.length === 0, "Z3 C6: each declared source is a real file under plugins/uberdev/ with a non-colliding prefix" + tail(e3));

  var e4 = rC4(LIVE);
  row(e4.length === 0, "Z4 C4: the executed fleet yields at least " + EXECUTED_KIND_FLOOR
      + " agent kinds (" + LIVE.join(",") + ")" + tail(e4));

  var e5 = rC1(tree, LIVE);
  row(e5.length === 0, "Z5 C1: declared kinds UNION edge-covered kinds equals the EXECUTED kinds" + tail(e5));

  var e6 = rC2(tree);
  row(e6.length === 0, "Z6 C2: no kind is both ungoverned and edge-covered" + tail(e6));

  var e7 = rC3(tree);
  row(e7.length === 0, "Z7 C3: every edge sourced from the fleet script sits under its reserved prefix" + tail(e7));

  var e8 = rC5(tree, SITES);
  row(e8.length === 0, "Z8 C5: dispatch_sites matches the " + SITES + " static dispatch site(s) in the fleet script" + tail(e8));

  // ------------------------------------------------------------------------
  // Differential rows. Each asserts BOTH halves: the UNMUTATED inputs are clean
  // AND the mutant is dirty. Stated one-sidedly ("the mutant fails") a row
  // passes vacuously on a manifest that fails for everything — which is exactly
  // the shape this issue is about.
  // ------------------------------------------------------------------------
  var baseErrs = check(tree, LIVE, SITES, launcherBase);

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
    var recMut = await runFixture(mutSrc);
    errs9 = check(tree, liveKinds(recMut), SITES, launcherBase);
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
    applied10 ? check(t10, LIVE, SITES, launcherBase) : []);

  var t11 = copyTree();
  var E11 = entryFor(t11, SRC_REL);
  var applied11 = !!(E11 && Array.isArray(E11.agent_kinds));
  if (applied11) E11.agent_kinds.push("invented_kind");
  differential("Z11 declaring a kind the fleet never dispatches reds the comparator",
    applied11, "there is no declaration to extend",
    applied11 ? check(t11, LIVE, SITES, launcherBase) : []);

  var t12 = copyTree();
  var E12 = entryFor(t12, SRC_REL);
  var applied12 = !!E12;
  if (applied12) E12.dispatch_sites = SITES + 1;
  differential("Z12 drifting the dispatch_sites backstop reds the comparator",
    applied12, "there is no entry to drift",
    applied12 ? check(t12, LIVE, SITES, launcherBase) : []);

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
  // comparator notice. The fixture is a shipped Workflow fleet outside this
  // manifest scope, so it is undeclared for a real reason rather than a
  // synthetic one, and the three guards on applied16 refuse to let the row
  // count if it ever goes missing, becomes enumerated, or becomes declared.
  // ------------------------------------------------------------------------
  var FIXTURE_REL = ANCHOR + "skills/review-fleet/workflow.js";
  var alreadySeen = FOUND.filter(function (s) { return s.source === FIXTURE_REL; }).length > 0;
  var applied16 = fs.existsSync(REPO_PREFIX + FIXTURE_REL) && !alreadySeen && !entryFor(tree, FIXTURE_REL);
  var lsrcMut = launcherBase + "\n# scope-test fixture lane surface: " + FIXTURE_REL.slice(ANCHOR.length) + "\n";
  differential("Z16 a dispatch substrate the launcher reaches and nobody declares reds C8",
    applied16,
    "the fixture substrate " + FIXTURE_REL + " is missing from disk, already enumerated, or already declared, so splicing it in would prove nothing",
    applied16 ? check(tree, LIVE, SITES, lsrcMut) : []);

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
    applied17 ? check(t17, LIVE, SITES, launcherBase) : []);

  process.stdout.write(rows.join("\n") + "\n");
})().catch(function (e) {
  process.stderr.write("comparator threw: " + ((e && e.stack) ? e.stack : String(e)) + "\n");
  process.exit(1);
});
' "$HARNESS" "$WORKFLOW" "$MANIFEST" "$SITES" "$LAUNCHER")"
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
[ "$ROW_COUNT" -eq 18 ] || {
  echo "FATAL: the comparator emitted $ROW_COUNT row(s), expected exactly 18 (Z0-Z17)" >&2
  exit 2
}

echo ""
echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
