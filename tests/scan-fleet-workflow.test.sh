#!/usr/bin/env bash
# tests/scan-fleet-workflow.test.sh — RFC 0012 §3.7 (Phase 3): the shared
# scan-fleet Workflow script (skills/scan-fleet/workflow.js) that backs BOTH
# /uberscan (mode=scan) and /ubersimplify (mode=simplify), + its §4.2 sibling
# SKILL.md seam.
#
# GIT-BASH PORTABLE: grep + node only (no python3/PyYAML/mktemp). Runs on BOTH
# the ubuntu and windows shape-check jobs.
#
# Complementary to tests/workflow-scripts.test.sh (the generic T1-T4 carrier):
# this file adds scan-fleet-SPECIFIC shape greps AND T3 BEHAVIORAL fixtures that
# drive the script under the harness stubs with canned returns and assert the
# orchestration semantics the carrier's generic dry-run does not (per-mode phase
# order, per-phase agent counts, sequential-apply, model policy, CB5/budget).
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/scan-fleet/SKILL.md"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/scan-fleet/workflow.js"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"

for f in "$SKILL" "$WORKFLOW" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the scan-fleet behavioral fixture (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## scan-fleet-workflow (RFC 0012 §3.7) — shape greps + T3 behavioral fixtures"

# ---------------------------------------------------------------------------
# Shape greps over workflow.js
# ---------------------------------------------------------------------------
echo "== workflow.js shape =="

META_JSON="$(node "$HARNESS" meta "$WORKFLOW" 2>/dev/null)"
if [ -n "$META_JSON" ] && printf '%s' "$META_JSON" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit((m.name==="scan-fleet" && Array.isArray(m.phases) && m.phases.join(",")==="pack,areas,global-pass,aggregate,apply,pr,issue-filing")?0:1);})'; then
  pass "G-1 meta literal parses: name=scan-fleet, phases=[pack,areas,global-pass,aggregate,apply,pr,issue-filing]"
else
  fail "G-1 meta literal wrong; got: $META_JSON"
fi

# G-2: model policy encoded in the script — mechanical relays pin haiku.
grep -q 'model: "haiku"' "$WORKFLOW" \
  && pass "G-2a mechanical relays pin model: haiku" \
  || fail "G-2a no model: \"haiku\" pin found"
if grep -qE 'model:[[:space:]]*"fable"' "$WORKFLOW"; then
  fail "G-2b fable is pinned in workflow.js — forbidden"
else
  pass "G-2b fable is not pinned anywhere"
fi

# G-3: the mode branch is the single divergence point (scan vs simplify).
grep -q 'mode === "simplify"' "$WORKFLOW" \
  && pass "G-3 the scan|simplify mode branch is present" \
  || fail "G-3 no mode branch found"

# G-4: the apply path dispatches NO agent with isolation:"worktree" — git forbids
# two worktrees on one branch, and sequential dispatch already removes the index
# race. (Deliberate deviation from the design's isolation suggestion.) Grep the
# actual opt form, not the word in prose comments.
if grep -qE 'isolation:[[:space:]]*["'"'"']worktree' "$WORKFLOW"; then
  fail "G-4 workflow.js dispatches an agent with isolation:\"worktree\" — the apply path must be sequential-no-isolation (git one-worktree-per-branch rule)"
else
  pass "G-4 no isolation:\"worktree\" opt in workflow.js (apply is sequential on a shared branch)"
fi

# G-5: the apply fixer loop is SEQUENTIAL (awaited in a for-loop, not parallel()).
grep -q 'NEVER parallel' "$WORKFLOW" \
  && pass "G-5 the apply fixer loop is documented sequential (git-index race guard)" \
  || fail "G-5 no sequential-apply guard documented"

# ---------------------------------------------------------------------------
# Shape greps over the §4.2 sibling SKILL.md seam
# ---------------------------------------------------------------------------
echo "== SKILL.md seam (§4.2) =="

grep -qF 'Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js"}' "$SKILL" \
  && pass "S-1 SKILL.md mandates Workflow({scriptPath: .../scan-fleet/workflow.js}, ...)" \
  || fail "S-1 SKILL.md lacks the scriptPath Workflow mandate"

grep -qF '## No-Workflow fallback' "$SKILL" \
  && pass "S-2 SKILL.md carries the '## No-Workflow fallback' section (DR-10)" \
  || fail "S-2 SKILL.md lacks the No-Workflow fallback section"

if grep -qE '\[[[:space:]]+-f[[:space:]]+"\$WORKFLOW_JS"[[:space:]]+\]' "$SKILL" \
   && grep -qE '^[[:space:]]*WORKFLOW_JS=.*skills/scan-fleet/workflow\.js' "$SKILL"; then
  pass "S-3 SKILL.md runs the RFC §4.1 [ -f \"\$WORKFLOW_JS\" ] existence guard (variable form)"
else
  fail "S-3 SKILL.md lacks the executable [ -f \"\$WORKFLOW_JS\" ] existence guard"
fi

# ---------------------------------------------------------------------------
# T3 behavioral fixtures — drive workflow.js under the harness stubs.
# ---------------------------------------------------------------------------
echo "== T3 behavioral fixtures (canned returns under the harness stubs) =="

FIXTURE_OUT="$(node -e '
const h = require(process.argv[1]);
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8");
const meta = h.extractMeta(src).meta;
const RD_SCAN = "/r/.uberdev/scan/RID";
const RD_SIMP = "/r/.uberdev/simplify/RID";

function buildArgs(mode, extra) {
  const RD = mode === "simplify" ? RD_SIMP : RD_SCAN;
  const cfg = Object.assign({
    mode: mode, runId: "RID", runDirAbs: RD, pluginRootAbs: "/p", repoRootAbs: "/r",
    scope: ".", manifestPathAbs: RD + "/manifest.json", numAreas: 8, concurrency: 3,
    minSeverity: "major", maxNew: mode === "simplify" ? 10 : 15, maxAgents: 250,
    noIssues: false, noReport: false, lenses: "Reuse,Quality,Efficiency",
    branchName: mode === "simplify" ? "ubersimplify/RID" : "", timestampIso: "2026-01-01T00:00:00Z",
  }, extra || {});
  return { v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z", plugin_root: "/p",
    repo_root: "/r", cwd: "/r", pipeline: "scan-fleet", config: cfg };
}
function scanReturns() {
  const RD = RD_SCAN;
  return {
    "area-pack": { areaIds: ["1","2"], areaCount: 2, overflow: false, rc: 0, skippedOversize: 0 },
    "scan-area-001": { areaId: "1", outPath: RD+"/chunk-001-findings.yaml", findingCount: 3, blockerCount: 1 },
    "scan-area-002": { areaId: "2", outPath: RD+"/chunk-002-findings.yaml", findingCount: 2, blockerCount: 0 },
    "global-pass": { semgrepPath: RD+"/global-security.md", coveragePath: RD+"/global-coverage.md", semgrepFindingCount: 4, coverageGapCount: 2, rc: 0 },
    "scan-aggregate": { reportPath: RD+"/uberscan-report.md", aggregatePath: RD+"/f2i-aggregate.md", totalFindings: 5, rc: 0 },
    "findings-to-issues": { issuesCreated: [201,202], skipped: 1 },
  };
}
function simplifyReturns() {
  const RD = RD_SIMP;
  return {
    "area-pack": { areaIds: ["1","2"], areaCount: 2, overflow: false, rc: 0 },
    "simplify-area-001": { areaId: "1", outPath: RD+"/chunk-001-lens.yaml", findingCount: 2, blockerCount: 1 },
    "simplify-area-002": { areaId: "2", outPath: RD+"/chunk-002-lens.yaml", findingCount: 1, blockerCount: 0 },
    "fixer-agg-001": { outPath: RD+"/chunk-001-fixer.md", mergedCount: 2, rc: 0 },
    "fixer-agg-002": { outPath: RD+"/chunk-002-fixer.md", mergedCount: 1, rc: 0 },
    "apply-setup": { branch: "ubersimplify/RID", rc: 0 },
    "fixer-001": { areaId: "1", status: "APPLIED", commitSha: "aaa111", dispositionPath: RD+"/chunk-001-fixer-disposition.yaml" },
    "fixer-002": { areaId: "2", status: "APPLIED", commitSha: "bbb222", dispositionPath: RD+"/chunk-002-fixer-disposition.yaml" },
    "open-pr": { prNumber: 303, prUrl: "https://example/pull/303", branch: "ubersimplify/RID", commitCount: 2, rc: 0 },
    "simplify-issues-agg": { aggregatePath: RD+"/f2i-aggregate.md", rc: 0 },
    "findings-to-issues": { issuesCreated: [304], skipped: 0 },
  };
}
function run(args, fixture) {
  const pre = h.preprocess(src);
  const record = h.makeRecord();
  const sb = h.makeSandbox(Object.assign({ args }, fixture), meta, record).sandbox;
  const pending = vm.runInNewContext(pre.wrapped, sb, { filename: "scan-fleet", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function resultOf(record) {
  const line = record.logs.find(function (l) { return l.indexOf("WORKFLOW_RESULT ") === 0; });
  return line ? JSON.parse(line.slice("WORKFLOW_RESULT ".length)) : null;
}
function modelsNull(record, pred) {
  return record.agentCalls.filter(pred).every(function (c) { return c.model === null; });
}
function modelsHaiku(record, pred) {
  const m = record.agentCalls.filter(pred);
  return m.length > 0 && m.every(function (c) { return c.model === "haiku"; });
}

(async function () {
  const out = {};

  // Run A — scan mode, 2 areas.
  const recA = await run(buildArgs("scan"), { agentReturns: scanReturns() });
  const resA = resultOf(recA);
  const cA = h.countAgentsByPhase(recA);
  out.aViolations = recA.violations.length;
  out.aPhases = recA.phases.join(",");
  out.aPack = cA.pack || 0;
  out.aAreas = cA.areas || 0;
  out.aGlobal = cA["global-pass"] || 0;
  out.aAgg = cA.aggregate || 0;
  out.aIssue = cA["issue-filing"] || 0;
  out.aEverySchema = recA.agentCalls.every(function (c) { return c.hasSchema; });
  out.aAreaInherit = modelsNull(recA, function (c) { return c.label && c.label.indexOf("scan-area-") === 0; });
  out.aRelaysHaiku = modelsHaiku(recA, function (c) { return c.label === "area-pack" || c.label === "global-pass" || c.label === "scan-aggregate"; });
  out.aF2iInherit = modelsNull(recA, function (c) { return c.label === "findings-to-issues"; });
  out.aMode = resA ? resA.mode : null;
  out.aAreaCount = resA ? resA.areaCount : null;
  out.aTotalFindings = resA ? resA.totalFindings : null;
  out.aReportUnderRunDir = !!(resA && typeof resA.reportPath === "string" && resA.reportPath.indexOf(RD_SCAN) === 0);
  out.aIssues = resA ? resA.issues : null;
  // prompt assembly: a scan-area prompt reads the manifest by PATH + names the C2 schema.
  const ap = recA.agentCalls.find(function (c) { return c.label && c.label.indexOf("scan-area-") === 0; }).prompt;
  out.aPromptManifestByPath = ap.indexOf("/manifest.json") >= 0;
  out.aPromptSchema = ap.indexOf("schema_version: 1") >= 0;
  // The area-pack relay must REDIRECT chunk.py stdout (chunk.py has no --out flag,
  // review blocker #2) — inspect the actual rendered command string.
  const packCall = recA.agentCalls.find(function (c) { return c.label === "area-pack"; });
  out.aPackRedirects = !!(packCall && packCall.prompt.indexOf("/lib/chunk.py") >= 0
    && packCall.prompt.indexOf("> \"") >= 0 && packCall.prompt.indexOf("--out") < 0);

  // Run B — simplify apply, 2 areas.
  const recB = await run(buildArgs("simplify"), { agentReturns: simplifyReturns() });
  const resB = resultOf(recB);
  const cB = h.countAgentsByPhase(recB);
  out.bPhases = recB.phases.join(",");
  out.bAreas = cB.areas || 0;
  out.bAgg = cB.aggregate || 0;          // per-area fixer aggregates = 2
  out.bApply = cB.apply || 0;            // apply-setup + 2 fixers = 3
  out.bPr = cB.pr || 0;                  // 1
  out.bIssue = cB["issue-filing"] || 0;  // simplify-issues-agg + findings-to-issues = 2
  out.bParallelCalls = recB.parallelCalls.length;   // areas batch + fixer-agg = 2; fixers add NONE
  out.bFixerInherit = modelsNull(recB, function (c) { return c.label && c.label.indexOf("fixer-") === 0 && c.label.indexOf("fixer-agg-") !== 0; });
  out.bMode = resB ? resB.mode : null;
  out.bBranch = resB ? resB.branch : null;
  out.bPrNumber = resB ? resB.prNumber : null;
  out.bApplied = resB ? resB.appliedAreas : null;

  // Run C — simplify --audit-only: NO apply/pr phases.
  const recC = await run(buildArgs("simplify", { auditOnly: true }), { agentReturns: simplifyReturns() });
  const resC = resultOf(recC);
  const cC = h.countAgentsByPhase(recC);
  out.cPhases = recC.phases.join(",");
  out.cApply = cC.apply || 0;            // 0 — skipped
  out.cPr = cC.pr || 0;                  // 0 — skipped
  out.cAuditOnly = resC ? resC.auditOnly : null;
  out.cBranch = resC ? resC.branch : null;

  // Run D — scan --no-issues: findings-to-issues NOT dispatched.
  const recD = await run(buildArgs("scan", { noIssues: true }), { agentReturns: scanReturns() });
  out.dNoF2i = !recD.agentCalls.some(function (c) { return c.label === "findings-to-issues"; });

  // Run E — CB5 blocker flood (concurrency 1 so the break strands area 2).
  const eReturns = scanReturns();
  eReturns["scan-area-001"] = { areaId: "1", outPath: RD_SCAN+"/chunk-001-findings.yaml", findingCount: 9, blockerCount: 9 };
  const recE = await run(buildArgs("scan", { concurrency: 1, cumulativeBlockerCap: 1 }), { agentReturns: eReturns });
  const resE = resultOf(recE);
  out.eCb5 = resE ? resE.cb5Tripped : null;
  out.eAreasReturned = resE ? resE.areasReturned : null;     // 1 — area 2 never dispatched
  out.eCb5Audit = !!(resE && resE.auditEvents.some(function (ev) { return ev.event === "blocker_flood_cb5"; }));

  // Run F — budget throw: a small ceiling makes the global-pass agent() throw PAST
  // budget; the DR-8 try/catch routes to the observable finalize path.
  const recF = await run(buildArgs("scan"), { budgetTotal: 3, agentReturns: scanReturns() });
  const resF = resultOf(recF);
  out.fObservable = !!resF;
  out.fThrowAudit = !!(resF && resF.auditEvents.some(function (ev) { return ev.event === "run_threw"; }));
  out.fHarnessThrew = recF.budgetThrows > 0;

  // Run G — pack failure (empty/overflow): the run aborts after the pack phase.
  const recG = await run(buildArgs("scan"),
    { agentReturns: Object.assign({}, scanReturns(), { "area-pack": { areaIds: [], areaCount: 0, overflow: false, rc: 2 } }) });
  const resG = resultOf(recG);
  out.gPhases = recG.phases.join(",");
  out.gNoAreas = !recG.agentCalls.some(function (c) { return c.label && c.label.indexOf("scan-area-") === 0; });
  out.gPackFailedAudit = !!(resG && resG.auditEvents.some(function (ev) { return ev.event === "pack_failed"; }));

  // Run H — simplify branch-setup failure: apply entered, branch fails, fixers/PR skipped,
  // leftover issues STILL filed with an EMPTY pr_number (never the literal "(empty)").
  const hReturns = Object.assign({}, simplifyReturns(), { "apply-setup": { branch: "ubersimplify/RID", baseBranch: "main", rc: 1 } });
  const recH = await run(buildArgs("simplify"), { agentReturns: hReturns });
  const resH = resultOf(recH);
  out.hPhases = recH.phases.join(",");
  out.hBranchFailAudit = !!(resH && resH.auditEvents.some(function (ev) { return ev.event === "branch_setup_failed"; }));
  out.hNoFixers = !recH.agentCalls.some(function (c) { return /^fixer-[0-9]/.test(c.label || ""); });
  out.hIssuesFiled = recH.agentCalls.some(function (c) { return c.label === "findings-to-issues"; });
  const hF2i = recH.agentCalls.find(function (c) { return c.label === "findings-to-issues"; });
  out.hNoEmptySentinel = !!(hF2i && hF2i.prompt.indexOf("pr_number=(empty)") < 0);

  // Run I — scan aggregate returns a report path OUTSIDE the run dir: rejected (§4.5 C-7).
  const iReturns = Object.assign({}, scanReturns(), { "scan-aggregate": { reportPath: "/etc/passwd", aggregatePath: RD_SCAN + "/f2i-aggregate.md", totalFindings: 5, rc: 0 } });
  const recI = await run(buildArgs("scan"), { agentReturns: iReturns });
  const resI = resultOf(recI);
  out.iReportRejected = resI ? resI.reportPath : null;
  out.iRejectAudit = !!(resI && resI.auditEvents.some(function (ev) { return ev.event === "report_path_out_of_run_dir"; }));
  out.iIssuesStillFiled = recI.agentCalls.some(function (c) { return c.label === "findings-to-issues"; });

  // Run J — findings-to-issues returns null: run completes; findings_to_issues_null audit fires.
  const jReturns = Object.assign({}, scanReturns()); jReturns["findings-to-issues"] = null;
  const recJ = await run(buildArgs("scan"), { agentReturns: jReturns });
  const resJ = resultOf(recJ);
  out.jObservable = !!resJ;
  out.jNullAudit = !!(resJ && resJ.auditEvents.some(function (ev) { return ev.event === "findings_to_issues_null"; }));

  // Run K — simplify fixer-agg returns null: aggregate phase counts the null; apply still runs.
  const kReturns = Object.assign({}, simplifyReturns()); kReturns["fixer-agg-001"] = null;
  const recK = await run(buildArgs("simplify"), { agentReturns: kReturns });
  const resK = resultOf(recK);
  out.kObservable = !!resK;
  out.kAggNullCounted = !!(resK && resK.nullsByPhase && resK.nullsByPhase.aggregate >= 1);
  out.kApplyStillRan = (h.countAgentsByPhase(recK).apply || 0) >= 3;

  // Run L — simplify 0-applied (all NO_FIXES_NEEDED): the empty temp branch is cleaned up.
  const lReturns = Object.assign({}, simplifyReturns(),
    { "fixer-001": { areaId: "1", status: "NO_FIXES_NEEDED", commitSha: "", dispositionPath: RD_SIMP + "/d1.yaml" },
      "fixer-002": { areaId: "2", status: "NO_FIXES_NEEDED", commitSha: "", dispositionPath: RD_SIMP + "/d2.yaml" } });
  const recL = await run(buildArgs("simplify"), { agentReturns: lReturns });
  const resL = resultOf(recL);
  out.lApplied = resL ? resL.appliedAreas : null;
  out.lNoFixesNeeded = resL ? resL.noFixesNeededAreas : null;
  out.lCleanupDispatched = recL.agentCalls.some(function (c) { return c.label === "branch-cleanup"; });
  out.lBranchCleared = resL ? resL.branch : null;
  out.lSkipAudit = !!(resL && resL.auditEvents.some(function (ev) { return ev.event === "pr_skipped_no_commits"; }));

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

if printf '%s' "$FIXTURE_OUT" | grep -q 'FIXTURE_ERROR'; then
  fail "T3 fixture crashed: $FIXTURE_OUT"
else
  # Run A — scan
  check aViolations 0 "A.1 scan: no harness violations (good prompts, declared phases, no forbidden globals)"
  check aPhases '"pack,areas,global-pass,aggregate,issue-filing"' "A.2 scan phase order"
  check aPack 1 "A.3 scan: 1 area-pack agent"
  check aAreas 2 "A.4 scan: 2 per-area reviewers"
  check aGlobal 1 "A.5 scan: 1 inline global Semgrep+coverage relay"
  check aAgg 1 "A.6 scan: 1 report.py aggregate relay"
  check aIssue 1 "A.7 scan: 1 findings-to-issues"
  check aEverySchema true "A.8 every agent() call carries a schema (DR-4)"
  check aAreaInherit true "A.9 scan area reviewers OMIT model (judgment inherits flagship, RFC §5)"
  check aRelaysHaiku true "A.10 pack/global/aggregate relays pin haiku (mechanical)"
  check aF2iInherit true "A.11 findings-to-issues OMITs model (judgment inherits)"
  check aMode '"scan"' "A.12 return.mode == scan"
  check aAreaCount 2 "A.13 return.areaCount == 2"
  check aTotalFindings 5 "A.14 totalFindings reflects the deduped report.py count (aggregate override)"
  check aReportUnderRunDir true "A.15 returned reportPath is realpath-prefix-checked under the run dir (§4.5 C-7)"
  check aIssues '{"issuesCreated":[201,202],"skipped":1}' "A.16 issues carry created numbers + skipped back to the return"
  check aPromptManifestByPath true "A.17 area prompt reads the manifest by PATH"
  check aPromptSchema true "A.18 area prompt names the C2 schema_version"
  check aPackRedirects true "A.19 the area-pack relay redirects chunk.py stdout (no --out flag — review blocker #2)"
  # Run B — simplify apply
  check bPhases '"pack,areas,aggregate,apply,pr,issue-filing"' "B.1 simplify-apply phase order"
  check bAreas 2 "B.2 simplify: 2 per-area code-simplifiers"
  check bAgg 2 "B.3 simplify: 2 per-area fixer aggregates"
  check bApply 3 "B.4 simplify apply: apply-setup + 2 sequential code-fixers = 3"
  check bPr 1 "B.5 simplify: 1 pr-open relay"
  check bIssue 2 "B.6 simplify issue-filing: leftover-aggregate relay + findings-to-issues = 2"
  check bParallelCalls 2 "B.7 fixers are SEQUENTIAL: only areas + fixer-agg use parallel() (no parallel batch for the apply fixers)"
  check bFixerInherit true "B.8 code-fixer applies OMIT model (judgment)"
  check bMode '"simplify"' "B.9 return.mode == simplify"
  check bBranch '"ubersimplify/RID"' "B.10 return.branch is the shared simplify branch"
  check bPrNumber 303 "B.11 return.prNumber parsed from the pr relay"
  check bApplied 2 "B.12 return.appliedAreas == 2"
  # Run C — audit-only
  check cPhases '"pack,areas,aggregate,issue-filing"' "C.1 audit-only skips apply + pr phases"
  check cApply 0 "C.2 audit-only: 0 apply agents"
  check cPr 0 "C.3 audit-only: 0 pr agents"
  check cAuditOnly true "C.4 return.auditOnly == true"
  check cBranch '""' "C.5 audit-only: no branch created"
  # Run D — no-issues
  check dNoF2i true "D.1 --no-issues skips the findings-to-issues dispatch entirely"
  # Run E — CB5 flood
  check eCb5 true "E.1 CB5 blocker flood trips cb5Tripped"
  check eAreasReturned 1 "E.2 CB5 halts the wave loop (area 2 never dispatched under concurrency=1)"
  check eCb5Audit true "E.3 a blocker_flood_cb5 audit row is emitted"
  # Run F — budget throw
  check fObservable true "F.1 the DR-8 budget-throw path still returns an observable result"
  check fThrowAudit true "F.2 a budget-aborted run emits a run_threw audit row"
  check fHarnessThrew true "F.3 the budget ceiling actually made an agent() call throw (the guard fired, not vacuous)"
  # Run G — pack failure
  check gPhases '"pack"' "G.1 pack failure aborts after the pack phase"
  check gNoAreas true "G.2 pack failure dispatches no area reviewers"
  check gPackFailedAudit true "G.3 pack failure emits a pack_failed audit row"
  # Run H — simplify branch-setup failure
  check hPhases '"pack,areas,aggregate,apply,issue-filing"' "H.1 branch-setup failure skips the pr phase but still files leftover issues"
  check hBranchFailAudit true "H.2 branch-setup failure emits branch_setup_failed"
  check hNoFixers true "H.3 branch-setup failure dispatches no code-fixers"
  check hIssuesFiled true "H.4 branch-setup failure still files leftover issues (findings stay valid)"
  check hNoEmptySentinel true "H.5 the f2i prompt never emits the literal pr_number=(empty) (malformed-backref guard, review #1)"
  # Run I — out-of-run-dir report path rejection
  check iReportRejected '""' "I.1 an out-of-run-dir report path is rejected to empty (§4.5 C-7)"
  check iRejectAudit true "I.2 a report_path_out_of_run_dir audit row fires"
  check iIssuesStillFiled true "I.3 a valid aggregate path still files issues despite the report-path rejection"
  # Run J — findings-to-issues null
  check jObservable true "J.1 a null findings-to-issues return still yields an observable result"
  check jNullAudit true "J.2 a null findings-to-issues emits findings_to_issues_null"
  # Run K — fixer-agg null
  check kObservable true "K.1 a null fixer-agg still yields an observable result"
  check kAggNullCounted true "K.2 a null fixer-agg is counted in nullsByPhase.aggregate (not silently dropped)"
  check kApplyStillRan true "K.3 a null fixer-agg does not block the apply phase"
  # Run L — 0-applied empty-branch cleanup
  check lApplied 0 "L.1 all-NO_FIXES_NEEDED yields 0 applied areas"
  check lNoFixesNeeded 2 "L.2 NO_FIXES_NEEDED areas are counted (not silently dropped, review #0)"
  check lCleanupDispatched true "L.3 0-applied dispatches the empty-branch cleanup relay"
  check lBranchCleared '""' "L.4 0-applied clears the branch in the return (temp branch removed)"
  check lSkipAudit true "L.5 0-applied emits pr_skipped_no_commits"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
