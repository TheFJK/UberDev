#!/usr/bin/env bash
# tests/solve-run-tree-scope.test.sh — issue #510.
#
# THE DEFECT. policy/solve-run-tree-v1.json calls itself the solve run tree, but
# every one of its 54 edges is sourced from skills/orchestrator/SKILL.md,
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
#   C4  the executed set has at least 6 kinds (anti-vacuity floor)
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

for f in "$HARNESS" "$WORKFLOW" "$MANIFEST"; do
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

var srcBase = fs.readFileSync(WORKFLOW, "utf8");
var tree = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));

var slashed = WORKFLOW.split("\\").join("/");
var ANCHOR = "plugins/uberdev/";
var at = slashed.indexOf(ANCHOR);
if (at < 0) { throw new Error("workflow path is not under " + ANCHOR + ": " + WORKFLOW); }
var SRC_REL = slashed.slice(at);
var REPO_PREFIX = slashed.slice(0, at);

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
// then ":" mapped to "." and "-" mapped to "_".
// ---------------------------------------------------------------------------
function kindOf(label) {
  var s = String(label);
  s = s.replace(/:#[0-9]+/, "");
  s = s.replace(/ \([a-z0-9_-]+\)$/, "");
  return s.split(":").join(".").split("-").join("_");
}

// ---------------------------------------------------------------------------
// The fixture. ONE batch carrying a design tier and a trivial tier reaches every
// dispatch site in the fleet, so one run derives the whole live set. Kept local
// on purpose: tests/solve-fleet-workflow.test.sh owns a different contract and a
// shared fixture would make both files fragile.
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
function issueRec(issue, tier) {
  return { issue: issue, tier: tier, promptFile: RD + "/solve-prompt-" + issue + ".txt" };
}
function solvedRec(issue, pr) {
  return {
    issue: issue, status: "PR_OPENED", branch: "fix/" + issue + "-x", prNumber: pr,
    prUrl: "https://example.invalid/pull/" + pr, commitCount: 1, testsRun: true,
    summary: "done", blocker: ""
  };
}
function agentReturns() {
  return {
    "manifest-intake": { rc: 0, issues: [issueRec(11, "medium"), issueRec(12, "trivial")] },
    "research:#11:codebase": { artifactPath: RD + "/issue-11/research-codebase.md", rc: 0, headline: "h" },
    "research:#11:constraints": { artifactPath: RD + "/issue-11/research-constraints.md", rc: 0, headline: "h" },
    "research:#11:test-coverage": { artifactPath: RD + "/issue-11/research-test-coverage.md", rc: 0, headline: "h" },
    "spec:#11": { path: RD + "/issue-11/spec.md", rc: 0, headline: "h" },
    "spec-review:#11": { verdict: "APPROVE", rc: 0, headline: "h", blockingFindings: [] },
    "plan:#11": { path: RD + "/issue-11/plan.md", rc: 0, headline: "h" },
    "solve:#11 (medium)": solvedRec(11, 901),
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

function rC4(live) {
  return live.length >= 6
    ? []
    : ["the executed kind set has only " + live.length + " member(s) — the fixture is not reaching the fleet"];
}

function rC5(t, sites) {
  var E = entryFor(t, SRC_REL);
  if (!E) return ["no scope.does_not_govern entry declares source " + SRC_REL];
  return E.dispatch_sites === sites
    ? []
    : ["dispatch_sites=" + JSON.stringify(E.dispatch_sites) + " but the source has " + sites + " dispatch site(s)"];
}

function check(t, live, sites) {
  return [].concat(
    rGoverns(t), rEntryShape(t), rC6(t),
    rC1(t, live), rC2(t), rC3(t), rC4(live), rC5(t, sites)
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
  row(e4.length === 0, "Z4 C4: the executed fleet yields at least 6 agent kinds (" + LIVE.join(",") + ")" + tail(e4));

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
  var baseErrs = check(tree, LIVE, SITES);

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
    errs9 = check(tree, liveKinds(recMut), SITES);
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
    applied10 ? check(t10, LIVE, SITES) : []);

  var t11 = copyTree();
  var E11 = entryFor(t11, SRC_REL);
  var applied11 = !!(E11 && Array.isArray(E11.agent_kinds));
  if (applied11) E11.agent_kinds.push("invented_kind");
  differential("Z11 declaring a kind the fleet never dispatches reds the comparator",
    applied11, "there is no declaration to extend",
    applied11 ? check(t11, LIVE, SITES) : []);

  var t12 = copyTree();
  var E12 = entryFor(t12, SRC_REL);
  var applied12 = !!E12;
  if (applied12) E12.dispatch_sites = SITES + 1;
  differential("Z12 drifting the dispatch_sites backstop reds the comparator",
    applied12, "there is no entry to drift",
    applied12 ? check(t12, LIVE, SITES) : []);

  process.stdout.write(rows.join("\n") + "\n");
})().catch(function (e) {
  process.stderr.write("comparator threw: " + ((e && e.stack) ? e.stack : String(e)) + "\n");
  process.exit(1);
});
' "$HARNESS" "$WORKFLOW" "$MANIFEST" "$SITES")"
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

[ "$ROW_COUNT" -ge 13 ] || {
  echo "FATAL: the comparator emitted $ROW_COUNT row(s), expected at least 13 (Z0-Z12)" >&2
  exit 2
}

echo ""
echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
