#!/usr/bin/env bash
# tests/uberthink-workflow.test.sh — RFC 0012 §3.7 (Phase 3): the /uberthink
# Workflow script (skills/uberthink-pipeline/workflow.js) + its §4.2 sibling
# SKILL.md seam.
#
# GIT-BASH PORTABLE: grep + node only (no python3/PyYAML/mktemp). Runs on BOTH
# the ubuntu and windows shape-check jobs.
#
# Complementary to tests/workflow-scripts.test.sh (the generic T1-T4 carrier):
# this file adds uberthink-SPECIFIC shape greps AND T3 BEHAVIORAL fixtures that
# drive the script under the harness stubs with canned returns.
#
# The three fixtures below are the regression locks for the three defects the
# migration exists to kill. Each one FAILS against the pre-migration design:
#
#   A/B — FLEET-CEILING ACCUMULATION. The directive-emitter bumped its counter
#         with re.search(r"^AGENTS_DISPATCHED=(\d+)") (the FIRST match, forever
#         the Phase-0 seed of 0) and read it back with `tail -n1` (the LAST
#         match). Waves of 3+32+2+6 left run-state.txt as 0,3,32,2,6: the reader
#         saw 6 while the true total was 43, so MAX_AGENTS was unreachable and
#         CB-ISLAND could never halt a runaway genetic loop. Fixture A pins the
#         per-wave ledger AND its running totals; fixture B sets the ceiling at
#         44 and asserts the gap-regen wave TRIPS it — under the old tail-read
#         the same wave computed 2+6=8 and sailed through.
#
#   S/T — TOOLING CRASH vs NON-CONVERGENCE. The Wave-4/Wave-7 cuts ran under
#         `2>/dev/null || true`, so a module-load failure wrote no shortlist,
#         CB-CONVERGE fired, and the dossier told the user "the goal as framed
#         admitted no feasible novel approach" — tooling breakage rendered as a
#         substantive verdict. S drives a report.py rc=3 and asserts a TOOLING
#         halt with NO CB-CONVERGE and a partial report that says so; T is the
#         non-vacuous control where the cuts exit 0 and the frontier is honestly
#         empty, which MUST still reach CB-CONVERGE.
#
#   F   — WAVE-5 FILE-SET BRIEF. `grep -n frame_dir` over the old SKILL.md
#         returned ZERO hits while agents/uberthink-falsifier.md declares
#         frame_dir mandatory and the physics lens must read constraints.md.
#         Fixture F asserts EVERY falsifier prompt carries frame_dir, all four
#         frame artifacts, working_dir and the goal envelope.
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/SKILL.md"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/workflow.js"
PERSONAS="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/personas.yaml"
REPORT_PY="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/report.py"
FALSIFIER="$REPO_ROOT/plugins/uberdev/agents/uberthink-falsifier.md"
FRAME_AGENT="$REPO_ROOT/plugins/uberdev/agents/uberthink-frame.md"
CODEX_SKILL="$REPO_ROOT/codex/uberdev-codex/skills/uberthink-pipeline/SKILL.md"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"

for f in "$SKILL" "$WORKFLOW" "$PERSONAS" "$REPORT_PY" "$FALSIFIER" "$FRAME_AGENT" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the uberthink behavioral fixture (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## uberthink-workflow (RFC 0012 §3.7) — shape greps + T3 behavioral fixtures"

# ---------------------------------------------------------------------------
# Shape greps over workflow.js
# ---------------------------------------------------------------------------
echo "== workflow.js shape =="

META_JSON="$(node "$HARNESS" meta "$WORKFLOW" 2>/dev/null)"
if [ -n "$META_JSON" ] && printf '%s' "$META_JSON" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit((m.name==="uberthink-pipeline" && Array.isArray(m.phases) && m.phases.join(",")==="frame,diverge,gap-gate,combine,converge,falsify,cross-pollinate,rank,deliver")?0:1);})'; then
  pass "G-1 meta literal parses: name=uberthink-pipeline, 9 declared phases in wave order"
else
  fail "G-1 meta literal wrong; got: $META_JSON"
fi

if grep -qE '^function guard\(n, label\)' "$WORKFLOW"; then
  pass "G-2 the fleet ceiling is a live guard(n, label) function, not an on-disk counter"
else
  fail "G-2 no guard(n, label) function — the CB-ISLAND ceiling must be enforced in-script"
fi

if grep -q 'uberthinkHalt = "CB-ISLAND"' "$WORKFLOW" && grep -q 'uberthinkHalt = "CB-BUDGET"' "$WORKFLOW"; then
  pass "G-3 guard() THROWS CB-ISLAND and CB-BUDGET (a breaker that only logs is not a breaker)"
else
  fail "G-3 guard() does not throw both CB-ISLAND and CB-BUDGET"
fi

if grep -q 'function convergenceIsHonest' "$WORKFLOW" \
   && grep -qE 'if \(halts\[i\]\.indexOf\("TOOLING:"\) === 0\) return false' "$WORKFLOW"; then
  pass "G-4 CB-CONVERGE is gated on convergenceIsHonest() — a TOOLING halt disqualifies the verdict"
else
  fail "G-4 no convergenceIsHonest() TOOLING gate — a crashed cut could still be delivered as a verdict"
fi

if [ "$(grep -c 'addHalt("CB-CONVERGE")' "$WORKFLOW")" -eq 1 ]; then
  pass "G-5 CB-CONVERGE is raised from exactly ONE site (the gated one)"
else
  fail "G-5 CB-CONVERGE is raised from $(grep -c 'addHalt("CB-CONVERGE")' "$WORKFLOW") sites — every raise must go through the TOOLING gate"
fi

if grep -q 'frame_dir:' "$WORKFLOW" && grep -q 'function falsifyPrompt' "$WORKFLOW"; then
  pass "G-6 falsifyPrompt() emits frame_dir (the Wave-5 file-set brief exists in code)"
else
  fail "G-6 falsifyPrompt()/frame_dir missing from workflow.js"
fi

if grep -qE 'model:[[:space:]]*"fable"' "$WORKFLOW"; then
  fail "G-7 fable is pinned in workflow.js — forbidden"
else
  pass "G-7 fable is not pinned anywhere"
fi

if grep -q 'model: "haiku"' "$WORKFLOW"; then
  pass "G-8 mechanical relays pin model: haiku"
else
  fail "G-8 no model: \"haiku\" pin found"
fi

# The scope gate must be reached by a SOLO await, never inside a parallel()/burst()
# thunk list — verdict-first is shipped safety, not an optimisation target.
if grep -qE '^\s+const scopeRet = await agent\(scopePrompt' "$WORKFLOW"; then
  pass "G-9 the scope gate is a solo awaited dispatch (no pre-verdict parallel Wave 0)"
else
  fail "G-9 the scope gate is not a solo awaited dispatch — verdict-first would be broken"
fi

# ---------------------------------------------------------------------------
# The pre-migration masking idioms must be GONE (root-cause regression locks).
# ---------------------------------------------------------------------------
echo "== retired defect idioms =="

if grep -q 'AGENTS_DISPATCHED' "$SKILL"; then
  fail "R-1 SKILL.md still carries the AGENTS_DISPATCHED on-disk counter (the first-match/tail-read split)"
else
  pass "R-1 the AGENTS_DISPATCHED on-disk counter is gone from SKILL.md"
fi

if grep -qF '2>/dev/null || true' "$SKILL"; then
  fail "R-2 SKILL.md still runs a python step under '2>/dev/null || true' (crash-masking idiom)"
else
  pass "R-2 no '2>/dev/null || true' crash-masking idiom left in SKILL.md"
fi

if grep -qE 'emit (shortlist|floor-survivors)' "$SKILL" && grep -qE 'exit code|Check the exit code' "$SKILL"; then
  pass "R-3 the No-Workflow fallback routes both cuts through report.py AND mandates an exit-code check"
else
  fail "R-3 the fallback does not mandate checking the deterministic-cut exit code"
fi

for mode in shortlist floor-survivors; do
  if grep -qF "\"$mode\"" "$REPORT_PY"; then
    pass "R-4 report.py exposes --emit $mode as a real CLI mode with an exit code"
  else
    fail "R-4 report.py has no --emit $mode mode"
  fi
done

if grep -q 'class ArtifactError' "$REPORT_PY" && grep -q 'return 3' "$REPORT_PY"; then
  pass "R-5 report.py maps a missing/unreadable input to ArtifactError -> exit 3 (crash != empty)"
else
  fail "R-5 report.py has no ArtifactError/exit-3 crash-vs-empty discriminator"
fi

# personas.yaml multi-line block scalars are the "lens diet" fix: the old TSV
# relay ran every prompt through .replace(chr(10), " ").
if grep -qE '^\s+prompt: \|' "$PERSONAS"; then
  pass "R-6 personas.yaml carries multi-line block-scalar prompts (the lens diet is over)"
else
  fail "R-6 personas.yaml has no block-scalar prompt — the one-line lens diet is still in force"
fi
if grep -q 'chr(10)' "$SKILL"; then
  fail "R-7 the chr(10) prompt-flattening survived into the new SKILL.md"
else
  pass "R-7 the chr(10) prompt-flattening is gone"
fi

# The frame agent's stale claim that the pipeline "fans out all four in parallel"
# contradicted the verdict-first gate it documents two paragraphs later.
if grep -q 'fans out all four in parallel' "$FRAME_AGENT"; then
  fail "R-8 agents/uberthink-frame.md still claims all four Wave-0 lenses fan out in parallel (the scope gate runs ALONE)"
else
  pass "R-8 the stale 'fans out all four in parallel' claim is gone from uberthink-frame.md"
fi

# ---------------------------------------------------------------------------
# Shape greps over the §4.2 sibling SKILL.md seam
# ---------------------------------------------------------------------------
echo "== SKILL.md seam (§4.2) =="

grep -qF 'Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/uberthink-pipeline/workflow.js"}' "$SKILL" \
  && pass "S-1 SKILL.md mandates Workflow({scriptPath: .../uberthink-pipeline/workflow.js}, ...)" \
  || fail "S-1 SKILL.md lacks the scriptPath Workflow mandate"

grep -qF '## No-Workflow fallback' "$SKILL" \
  && pass "S-2 SKILL.md carries the '## No-Workflow fallback' section (DR-10)" \
  || fail "S-2 SKILL.md lacks the No-Workflow fallback section"

if grep -qE '\[[[:space:]]+-f[[:space:]]+"\$WORKFLOW_JS"[[:space:]]+\]' "$SKILL" \
   && grep -qE '^[[:space:]]*WORKFLOW_JS=.*skills/uberthink-pipeline/workflow\.js' "$SKILL"; then
  pass "S-3 SKILL.md runs the RFC §4.1 [ -f \"\$WORKFLOW_JS\" ] existence guard (variable form)"
else
  fail "S-3 SKILL.md lacks the executable [ -f \"\$WORKFLOW_JS\" ] existence guard"
fi

grep -qF 'uberdev_emit_workflow_args uberthink-pipeline' "$SKILL" \
  && pass "S-4 the preflight emits the canonical args envelope" \
  || fail "S-4 no uberdev_emit_workflow_args emission in the preflight"

grep -qF 'SINGLE assistant message' "$SKILL" \
  && pass "S-5 the fallback keeps the single-message fanout invariant" \
  || fail "S-5 the fallback lost the single-message fanout invariant"

if [ -r "$CODEX_SKILL" ]; then
  pass "S-6 the codex mirror of the pipeline SKILL.md exists"
else
  fail "S-6 codex/uberdev-codex/skills/uberthink-pipeline/SKILL.md missing (run the port scripts)"
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
const RD = "/r/.uberdev/think/RID";

// 12 donors x 2 islands + 4 operators x 2 islands = 32 generators.
const DONORS = ["distributed-systems","compilers-pl","databases","operating-systems",
  "networking-protocols","security-crypto","concurrency","compression-coding",
  "graph-theory","information-theory","biology","economics-markets"];

// A deliberately MULTI-LINE persona prompt: the pre-migration TSV relay ran every
// prompt through .replace(chr(10), " ") and could not have carried this.
const SCOUT_PROMPT = "SCOUT-LINE-ONE\nSCOUT-LINE-TWO";

function buildArgs(extra) {
  const cfg = Object.assign({
    runId: "RID", runDirAbs: RD, pluginRootAbs: "/p", repoRootAbs: "/r",
    goal: "make a covert transport that resists active probing",
    islands: 2, concurrency: 64, maxAgents: 500, maxFlood: 120, loopBackCap: 3,
    shortlistTop: 7, maxNew: 3, handoff: false, noIssues: false,
    resumeFromRunId: "", timestampIso: "2026-01-01T00:00:00Z",
  }, extra || {});
  return { v: 1, run_id: "RID", now_iso: "2026-01-01T00:00:00Z", plugin_root: "/p",
    repo_root: "/r", cwd: "/r", pipeline: "uberthink-pipeline", config: cfg };
}

function personasRet() {
  const named = function (n) { return { name: n, role: n, prompt: "P-" + n }; };
  return {
    rc: 0,
    frameLenses: [named("schema"), named("teardown"), named("prior-art"), named("constraints")],
    generators: [{ name: "field_scout", kind: "field_scout", prompt: SCOUT_PROMPT },
      { name: "triz", kind: "operator", prompt: "P-triz" },
      { name: "morphological", kind: "operator", prompt: "P-morph" },
      { name: "provocateur", kind: "operator", prompt: "P-prov" },
      { name: "bridge", kind: "meta", prompt: "P-bridge" }],
    moderator: { role: "Moderator", prompt: "P-mod" },
    synthesizerLenses: [named("weave"), named("crossover"), named("mutate")],
    falsifierLenses: [named("steelman"), named("premortem"), named("redteam"), named("physics")],
  };
}

// report.py writes BOTH an `id` and a `composite_path` on every shortlist row,
// and they are DIFFERENT strings: the id is comp-island-<K>-<NNN> while the file
// is comp-<NNN>-<synth-lens>.yaml. The relay hands both back, index-aligned, so
// Wave 5 never has to reconstruct a path (which would point at nothing).
function shortlistFor(k) {
  return { rc: 0, stderrTail: "", outPath: RD + "/island-" + k + "/shortlist.yaml",
    shortlist: ["comp-island-" + k + "-001", "comp-island-" + k + "-002"],
    compositePaths: [RD + "/island-" + k + "/composites/comp-001-weave.yaml",
      RD + "/island-" + k + "/composites/comp-002-crossover.yaml"],
    count: 2 };
}

function baseReturns(extra) {
  const r = {
    "personas": personasRet(),
    "scope-gate": { verdict: "PROCEED", rationale: "legitimate defensive research",
      framePath: RD + "/frame/frame.md", scopeVerdictPath: RD + "/frame/scope-verdict.yaml",
      donors: DONORS },
    "uberdev:uberthink-frame": { lens: "teardown", status: "ok", outPath: RD + "/frame/teardown.md" },
    "uberdev:uberthink-generator": { islandIndex: 1, persona: "field_scout", candidateCount: 3,
      outPath: RD + "/island-1/candidates/c.yaml" },
    "moderator-1": { islandIndex: 1, gapCount: 3, outPath: RD + "/island-1/gaps.yaml",
      gaps: [{ id: "gap-aa", persona: "morphological", donor: "", prompt: "q1" },
        { id: "gap-bb", persona: "triz", donor: "", prompt: "q2" },
        { id: "gap-cc", persona: "field_scout", donor: "biology", prompt: "q3" }] },
    "moderator-2": { islandIndex: 2, gapCount: 3, outPath: RD + "/island-2/gaps.yaml",
      gaps: [{ id: "gap-dd", persona: "morphological", donor: "", prompt: "q4" },
        { id: "gap-ee", persona: "bridge", donor: "", prompt: "q5" },
        { id: "gap-ff", persona: "provocateur", donor: "", prompt: "q6" }] },
    "uberdev:uberthink-synthesizer": { islandIndex: 1, lens: "weave", compositeCount: 2,
      outDir: RD + "/island-1/composites" },
    "shortlist-1-r0": shortlistFor(1),
    "shortlist-2-r0": shortlistFor(2),
    "uberdev:uberthink-falsifier": { islandIndex: 1, compositeId: "comp-island-1-001",
      lens: "steelman", outPath: RD + "/island-1/falsify/x.yaml", fatalKills: 1, fixableKills: 0,
      repairHints: [] },
    "cross-pollinate": { islandIndex: 1, lens: "crossover", compositeCount: 3,
      outDir: RD + "/composites" },
    "floor-survivors": { rc: 0, stderrTail: "", outPath: RD + "/floor-survivors.yaml",
      shortlist: ["comp-island-1-001", "comp-island-2-001"], count: 2 },
    "arbiter": { rankedPath: RD + "/ranked.yaml", rankedCount: 3, culledCount: 1 },
    "dossier": { rc: 0, stderrTail: "", outPath: RD + "/report.md" },
    "aggregate": { rc: 0, stderrTail: "", outPath: RD + "/f2i-aggregate.md" },
    "findings-to-issues": { issuesCreated: [901, 902], skipped: 1 },
    "partial-report": { rc: 0, stderrTail: "", outPath: RD + "/report.md" },
    "refusal-report": { rc: 0, stderrTail: "", outPath: RD + "/report.md" },
  };
  return Object.assign(r, extra || {});
}

function run(args, fixture) {
  const pre = h.preprocess(src);
  const record = h.makeRecord();
  const sb = h.makeSandbox(Object.assign({ args }, fixture), meta, record).sandbox;
  const pending = vm.runInNewContext(pre.wrapped, sb, { filename: "uberthink", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function resultOf(record) {
  const line = record.logs.find(function (l) { return l.indexOf("WORKFLOW_RESULT ") === 0; });
  return line ? JSON.parse(line.slice("WORKFLOW_RESULT ".length)) : null;
}
function ledgerFor(res, label) {
  const row = res.dispatchLedger.find(function (e) { return e.label === label; });
  return row ? [row.n, row.total] : null;
}

(async function () {
  const out = {};

  // ===== Run A — full clean run; the accumulation ledger is the payload. =====
  const recA = await run(buildArgs(), { agentReturns: baseReturns() });
  const resA = resultOf(recA);
  const cA = h.countAgentsByPhase(recA);
  out.aViolations = recA.violations.length;
  out.aPhases = recA.phases.join(",");
  out.aVerdict = resA ? resA.verdict : null;
  out.aHalts = resA ? resA.halts.join("|") : null;

  // THE accumulation assertion: four consecutive waves of 3 + 32 + 2 + 6 whose
  // RUNNING TOTAL must climb 5 -> 37 -> 39 -> 45. Under the retired
  // first-match-write / tail-read split each wave recomputed from 0.
  out.aWaveLenses = JSON.stringify(ledgerFor(resA, "diverge-frame-lenses"));
  out.aWaveGen = JSON.stringify(ledgerFor(resA, "diverge-generators"));
  out.aWaveMods = JSON.stringify(ledgerFor(resA, "gap-gate-moderators"));
  out.aWaveRegen = JSON.stringify(ledgerFor(resA, "gap-regen"));
  const waves = ["diverge-frame-lenses", "diverge-generators", "gap-gate-moderators", "gap-regen"];
  out.aWaveSum = waves.reduce(function (acc, l) { return acc + ledgerFor(resA, l)[0]; }, 0);
  out.aDispatchedTotal = resA ? resA.dispatched : null;
  // the ledger total must equal the counter at every step (no drift)
  out.aLedgerMonotonic = !!(resA && resA.dispatchLedger.every(function (e, i, arr) {
    return i === 0 ? e.total === e.n : e.total === arr[i - 1].total + e.n;
  }));

  out.aEverySchema = recA.agentCalls.every(function (c) { return c.hasSchema; });
  out.aRelaysHaiku = recA.agentCalls.filter(function (c) {
    return ["personas", "floor-survivors", "dossier", "aggregate"].indexOf(c.label) >= 0;
  }).every(function (c) { return c.model === "haiku"; });
  out.aJudgmentInherit = recA.agentCalls.filter(function (c) {
    return c.agentType && c.agentType.indexOf("uberdev:uberthink-") === 0;
  }).every(function (c) { return c.model === null; });
  out.aF2iInherit = !!recA.agentCalls.find(function (c) { return c.label === "findings-to-issues"; })
    && recA.agentCalls.find(function (c) { return c.label === "findings-to-issues"; }).model === null;
  out.aRanked = resA ? resA.rankedCount : null;
  out.aIssues = resA ? resA.issues : null;
  out.aReportUnderRunDir = !!(resA && resA.reportPath.indexOf(RD) === 0);

  // findings-to-issues closed caller contract (mirrors the retired U12 region test).
  const aF2i = recA.agentCalls.find(function (c) { return c.label === "findings-to-issues"; });
  out.aF2iContract = !!(aF2i
    && aF2i.prompt.indexOf("aggregate_path=" + RD + "/f2i-aggregate.md") >= 0
    && aF2i.prompt.indexOf("working_dir=/r") >= 0
    && aF2i.prompt.indexOf("pr_number=0") >= 0
    && aF2i.prompt.indexOf("finding_label=uberthink-idea") >= 0
    && aF2i.prompt.indexOf("finding_marker_slug=uberthink") >= 0
    && aF2i.prompt.indexOf("max_new=3") >= 0);
  out.aF2iNoSurplus = !!(aF2i
    && !/(?:run_id|repo_slug|pr_commit_sha|source_ref|phase1_aggregate_path)=/.test(aF2i.prompt));

  // ===== Fixture F — EVERY falsifier prompt carries the Wave-5 file set. =====
  const fals = recA.agentCalls.filter(function (c) { return (c.label || "").indexOf("falsify-") === 0; });
  out.fCount = fals.length;   // 2 islands x 2 composites x 4 lenses
  out.fAllFrameDir = fals.length > 0 && fals.every(function (c) {
    return c.prompt.indexOf("frame_dir:       " + RD + "/frame") >= 0;
  });
  out.fAllFrameArtifacts = fals.length > 0 && fals.every(function (c) {
    return c.prompt.indexOf(RD + "/frame/frame.md") >= 0
      && c.prompt.indexOf(RD + "/frame/teardown.md") >= 0
      && c.prompt.indexOf(RD + "/frame/prior-art.md") >= 0
      && c.prompt.indexOf(RD + "/frame/constraints.md") >= 0;
  });
  out.fAllGoalAndWorkingDir = fals.length > 0 && fals.every(function (c) {
    return c.prompt.indexOf("working_dir:     /r") >= 0
      && c.prompt.indexOf("source=\"user-goal\"") >= 0
      && c.prompt.indexOf("composite_path:  " + RD) >= 0;
  });
  const physics = fals.filter(function (c) { return (c.label || "").indexOf("-physics-") > 0; });
  out.fPhysicsReadsFence = physics.length > 0 && physics.every(function (c) {
    return c.prompt.indexOf("MUST read " + RD + "/frame/constraints.md FIRST") >= 0;
  });

  // F.6/F.7 — the composite_path a falsifier is briefed with must be the
  // AUTHORITATIVE path report.py wrote into the shortlist row, and the dossier
  // name must be derived from that FILE STEM. The composite id
  // (comp-island-K-NNN) is not the file stem (comp-NNN-<synth-lens>), so a path
  // rebuilt from the id points at a file that does not exist, and an id-named
  // dossier is never matched by the report.py
  // `<basename(composite_path) minus .yaml>-*.yaml` glob — every physics/redteam
  // feasibility sub-score would be silently dropped from the Wave-7 floor cut.
  function briefedPath(c) {
    const m = /composite_path:  (\S+)/.exec(c.prompt);
    return m ? m[1] : "";
  }
  out.fPathIsAuthoritative = fals.length > 0 && fals.every(function (c) {
    const island = String(c.label).split("-")[1];
    return /^\/r\/\.uberdev\/think\/RID\/island-[12]\/composites\/comp-00[12]-(weave|crossover)\.yaml$/
      .test(briefedPath(c))
      && briefedPath(c).indexOf(RD + "/island-" + island + "/composites/") === 0;
  });
  out.fNoIdDerivedPath = fals.length > 0
    && !fals.some(function (c) { return c.prompt.indexOf("/composites/comp-island-") >= 0; });
  out.fOutIsStemDerived = fals.length > 0 && fals.every(function (c) {
    const p = briefedPath(c);
    const lens = String(c.label).split("-")[3];     // falsify-<k>-<NNN>-<lens>-r<round>
    if (!p || !lens) return false;
    const base = p.slice(p.lastIndexOf("/") + 1);
    const stem = base.slice(0, base.length - ".yaml".length);
    return c.prompt.indexOf("/falsify/" + stem + "-" + lens + ".yaml") >= 0
      && c.prompt.indexOf("/falsify/comp-island-") < 0;
  });

  // Persona SSOT relay must carry the multi-line prompt through UNFLATTENED.
  const scoutCall = recA.agentCalls.find(function (c) {
    return (c.label || "").indexOf("gen-1-distributed-systems") === 0;
  });
  out.aPersonaMultiline = !!(scoutCall && scoutCall.prompt.indexOf(SCOUT_PROMPT) >= 0);
  out.aPersonaNotFlattened = !!(scoutCall
    && scoutCall.prompt.indexOf("SCOUT-LINE-ONE SCOUT-LINE-TWO") < 0);

  // ===== Run B — the ceiling ACTUALLY trips on accumulated total. =====
  // 39 dispatched when the 6-agent gap-regen wave is projected: 45 > 44.
  // The retired tail-read saw the moderator wave (2) and computed 2+6=8.
  const recB = await run(buildArgs({ maxAgents: 44 }), { agentReturns: baseReturns() });
  const resB = resultOf(recB);
  out.bHalts = resB ? resB.halts.join("|") : null;
  out.bDispatched = resB ? resB.dispatched : null;
  out.bPhases = resB ? resB.phasesRun.join(",") : null;
  out.bNoFalsify = !recB.agentCalls.some(function (c) { return (c.label || "").indexOf("falsify-") === 0; });
  out.bNoRegen = !recB.agentCalls.some(function (c) { return (c.label || "").indexOf("regen-") === 0; });
  out.bObservable = !!resB;

  // ===== Run S — report.py rc != 0 is a TOOLING halt, never a verdict. =====
  const crash = { rc: 3, stderrTail: "ModuleNotFoundError: No module named yaml",
    outPath: RD + "/island-1/shortlist.yaml", shortlist: [], count: 0 };
  const recS = await run(buildArgs(), { agentReturns: baseReturns({
    "shortlist-1-r0": crash,
    "shortlist-2-r0": Object.assign({}, crash, { outPath: RD + "/island-2/shortlist.yaml" }) }) });
  const resS = resultOf(recS);
  out.sHasTooling = !!(resS && resS.halts.some(function (x) { return x.indexOf("TOOLING:") === 0; }));
  out.sNoConverge = !!(resS && resS.halts.indexOf("CB-CONVERGE") < 0);
  out.sSuppressAudit = !!(resS && resS.auditEvents.some(function (e) {
    return e.event === "cb_converge_suppressed_tooling"; }));
  out.sNoFalsify = !recS.agentCalls.some(function (c) { return (c.label || "").indexOf("falsify-") === 0; });
  // A suppressed CB-CONVERGE must NOT let the run fall through to the floor cut
  // and the arbiter: ranking artifacts that were never written is precisely how a
  // crash gets re-dressed as substance.
  out.sNoRank = !recS.agentCalls.some(function (c) {
    return c.label === "floor-survivors" || c.label === "arbiter"; });
  out.sPhasesStopAtDeliver = resS ? resS.phasesRun.join(",") : null;
  const sPartial = recS.agentCalls.find(function (c) { return c.label === "partial-report"; });
  out.sPartialSaysTooling = !!(sPartial && sPartial.prompt.indexOf("A TOOLING failure stopped this run") >= 0);
  out.sPartialNotVerdict = !!(sPartial
    && sPartial.prompt.indexOf("admitted no feasible novel approach") < 0);
  out.sObservable = !!resS;

  // ===== Run T — control: clean cuts, honestly empty frontier => CB-CONVERGE. =====
  const empty = { rc: 0, stderrTail: "", outPath: RD + "/island-1/shortlist.yaml",
    shortlist: [], count: 0 };
  const recT = await run(buildArgs(), { agentReturns: baseReturns({
    "shortlist-1-r0": empty,
    "shortlist-2-r0": Object.assign({}, empty, { outPath: RD + "/island-2/shortlist.yaml" }) }) });
  const resT = resultOf(recT);
  out.tHasConverge = !!(resT && resT.halts.indexOf("CB-CONVERGE") >= 0);
  out.tNoTooling = !!(resT && !resT.halts.some(function (x) { return x.indexOf("TOOLING:") === 0; }));
  const tPartial = recT.agentCalls.find(function (c) { return c.label === "partial-report"; });
  out.tPartialIsNegativeResult = !!(tPartial
    && tPartial.prompt.indexOf("useful negative result") >= 0
    && tPartial.prompt.indexOf("A TOOLING failure stopped this run") < 0);

  // ===== Run U — REFUSE halts before ANY fanout (verdict-first safety). =====
  const recU = await run(buildArgs(), { agentReturns: baseReturns({
    "scope-gate": { verdict: "REFUSE", rationale: "primary purpose is extortion" } }) });
  const resU = resultOf(recU);
  out.uHalts = resU ? resU.halts.join("|") : null;
  out.uPhases = resU ? resU.phasesRun.join(",") : null;
  out.uLabels = recU.agentCalls.map(function (c) { return c.label; }).join(",");
  out.uNoParallel = recU.parallelCalls.length === 0;
  out.uNoGenerators = !recU.agentCalls.some(function (c) { return (c.label || "").indexOf("gen-") === 0; });
  out.uNoFrameLens = !recU.agentCalls.some(function (c) { return (c.label || "").indexOf("frame-") === 0; });

  // ===== Run V — genetic loop-back + CB-LOOP cap. =====
  const recV = await run(buildArgs({ loopBackCap: 2 }), { agentReturns: baseReturns({
    "uberdev:uberthink-falsifier": { islandIndex: 1, compositeId: "comp-island-1-001", lens: "premortem",
      outPath: RD + "/island-1/falsify/x.yaml", fatalKills: 0, fixableKills: 2,
      repairHints: ["widen the entropy budget", "drop the fixed handshake"] },
    "shortlist-1-r1": Object.assign({}, baseReturns()["shortlist-1-r0"]),
    "shortlist-1-r2": Object.assign({}, baseReturns()["shortlist-1-r0"]) }) });
  const resV = resultOf(recV);
  out.vLoopBacks = resV ? resV.islandStats[0].loopBacks : null;
  out.vCbLoop = !!(resV && resV.halts.some(function (x) { return x.indexOf("CB-LOOP:") === 0; }));
  const vRepairSynth = recV.agentCalls.find(function (c) { return (c.label || "").indexOf("synth-1-crossover-r1") === 0; });
  out.vRepairHintsInjected = !!(vRepairSynth
    && vRepairSynth.prompt.indexOf("REPAIR ROUND") >= 0
    && vRepairSynth.prompt.indexOf("widen the entropy budget") >= 0
    && vRepairSynth.prompt.indexOf("source=\"falsifier-repair-hints\"") >= 0);

  // ===== Run W — CB-FLOOD per island. =====
  const recW = await run(buildArgs({ maxFlood: 10 }), { agentReturns: baseReturns() });
  const resW = resultOf(recW);
  out.wFlood = !!(resW && resW.halts.some(function (x) { return x.indexOf("CB-FLOOD:") === 0; }));

  // ===== Run X — --no-issues + --handoff. =====
  const recX = await run(buildArgs({ noIssues: true, handoff: true }), { agentReturns: baseReturns({
    "handoff-seed": { rc: 0, stderrTail: "", outPath: RD + "/handoff-seed.md" } }) });
  const resX = resultOf(recX);
  out.xNoF2i = !recX.agentCalls.some(function (c) { return c.label === "findings-to-issues"; });
  out.xHandoffSeed = resX ? resX.handoff.seedPath : null;

  // ===== Run Y — the personas SSOT relay failing aborts before any wave. =====
  const recY = await run(buildArgs(), { agentReturns: baseReturns({
    "personas": { rc: 2, stderrTail: "personas.yaml not found" } }) });
  const resY = resultOf(recY);
  out.yTooling = !!(resY && resY.halts.some(function (x) { return x.indexOf("TOOLING:personas") === 0; }));
  out.yNoScopeGate = !recY.agentCalls.some(function (c) { return c.label === "scope-gate"; });

  // ===== Run P — a shortlist row with NO composite_path is DROPPED, never
  // dispatched at a fabricated path. =====
  const noPaths = { rc: 0, stderrTail: "", outPath: RD + "/island-1/shortlist.yaml",
    shortlist: ["comp-island-1-001", "comp-island-1-002"], count: 2 };
  const recP = await run(buildArgs(), { agentReturns: baseReturns({
    "shortlist-1-r0": noPaths,
    "shortlist-2-r0": Object.assign({}, noPaths, { outPath: RD + "/island-2/shortlist.yaml" }) }) });
  const resP = resultOf(recP);
  out.pNoFalsify = !recP.agentCalls.some(function (c) { return (c.label || "").indexOf("falsify-") === 0; });
  out.pTooling = !!(resP && resP.halts.some(function (x) {
    return x.indexOf("TOOLING:shortlist-island-") === 0; }));
  out.pNoConverge = !!(resP && resP.halts.indexOf("CB-CONVERGE") < 0);
  out.pShortlisted = resP ? resP.totalShortlisted : null;

  // ===== Run Y2 — the personas relay exits 0 with an unusable PAYLOAD. =====
  // personas.yaml is a mapping of keyed maps, so the relay has to transform it
  // into the requested arrays. rc alone never proves it did.
  const recY2 = await run(buildArgs(), { agentReturns: baseReturns({ "personas": { rc: 0 } }) });
  const resY2 = resultOf(recY2);
  out.y2Tooling = !!(resY2 && resY2.halts.some(function (x) {
    return x.indexOf("TOOLING:personas payload unusable") === 0; }));
  out.y2NoScopeGate = !recY2.agentCalls.some(function (c) { return c.label === "scope-gate"; });
  out.y2Observable = !!resY2;
  out.y2Audit = !!(resY2 && resY2.auditEvents.some(function (e) {
    return e.event === "personas_payload_unusable"; }));

  // ===== Run Z — resume skips the completed waves. =====
  const recZ = await run(buildArgs({ resumeFromRunId: "RID" }), { agentReturns: baseReturns({
    "resume-scan": { runDirExists: true, verdict: "PROCEED",
      frameLensesPresent: ["frame", "teardown", "prior-art", "constraints"],
      islandsWithCandidates: [1, 2], islandsWithShortlist: [], globalCompositeCount: 0,
      rankedExists: false, donors: DONORS } }) });
  const resZ = resultOf(recZ);
  out.zResumed = resZ ? resZ.resumed : null;
  out.zSkippedGate = !!(resZ && resZ.resumeSkipped.indexOf("scope-gate") >= 0);
  out.zNoGenerators = !recZ.agentCalls.some(function (c) { return (c.label || "").indexOf("gen-") === 0; });
  out.zNoScopeGate = !recZ.agentCalls.some(function (c) { return c.label === "scope-gate"; });

  // ===== Run Z2 — resume with NO island skipped: the donor fanout must survive.
  // Run Z above skips divergence on BOTH islands, which masks a resume that
  // silently dropped the donor catalog (no generators fire either way). Here the
  // Field Scout fleet MUST be rehydrated from scope-verdict.yaml. =====
  const recZ2 = await run(buildArgs({ resumeFromRunId: "RID" }), { agentReturns: baseReturns({
    "resume-scan": { runDirExists: true, verdict: "PROCEED",
      frameLensesPresent: ["frame", "teardown", "prior-art", "constraints"],
      islandsWithCandidates: [], islandsWithShortlist: [], globalCompositeCount: 0,
      rankedExists: false, donors: DONORS } }) });
  const resZ2 = resultOf(recZ2);
  out.z2Donors = resZ2 ? resZ2.donorCount : null;
  out.z2SkippedGate = !!(resZ2 && resZ2.resumeSkipped.indexOf("scope-gate") >= 0);
  out.z2Generators = recZ2.agentCalls.filter(function (c) {
    return (c.label || "").indexOf("gen-") === 0; }).length;
  out.z2Scouts = recZ2.agentCalls.filter(function (c) {
    return (c.label || "").indexOf("gen-1-distributed-systems") === 0; }).length;

  // ===== Z3 — a resumed PROCEED whose donors cannot be rehydrated re-runs the
  // scope gate instead of proceeding with an empty Field Scout fleet. =====
  const recZ3 = await run(buildArgs({ resumeFromRunId: "RID" }), { agentReturns: baseReturns({
    "resume-scan": { runDirExists: true, verdict: "PROCEED",
      frameLensesPresent: ["frame", "teardown", "prior-art", "constraints"],
      islandsWithCandidates: [], islandsWithShortlist: [], globalCompositeCount: 0,
      rankedExists: false, donors: [] } }) });
  const resZ3 = resultOf(recZ3);
  out.z3ScopeGateReRun = recZ3.agentCalls.some(function (c) { return c.label === "scope-gate"; });
  out.z3NotSkipped = !!(resZ3 && resZ3.resumeSkipped.indexOf("scope-gate") < 0);
  out.z3Donors = resZ3 ? resZ3.donorCount : null;
  out.z3Audit = !!(resZ3 && resZ3.auditEvents.some(function (e) {
    return e.event === "resume_donors_unrecoverable"; }));

  // ===== Run D — a decorated donor value is REJECTED with a log, not silently
  // swallowed (only the all-dropped case used to be observable). =====
  const recD = await run(buildArgs(), { agentReturns: baseReturns({
    "scope-gate": { verdict: "PROCEED", rationale: "ok",
      framePath: RD + "/frame/frame.md", scopeVerdictPath: RD + "/frame/scope-verdict.yaml",
      donors: ["biology", "rotating-exotic (linguistics/music)", "economics-markets"] } }) });
  const resD = resultOf(recD);
  out.dDonors = resD ? resD.donorCount : null;
  out.dRejectedAudit = !!(resD && resD.auditEvents.some(function (e) {
    return e.event === "donor_slugs_rejected" && (e.rejected || []).length === 1; }));

  process.stdout.write(JSON.stringify(out));
})().catch(function (e) {
  process.stdout.write(JSON.stringify({ FIXTURE_ERROR: (e && e.message) ? e.message : String(e),
    STACK: (e && e.stack) ? e.stack : "" }));
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

if grep -q 'FIXTURE_ERROR' <<<"$FIXTURE_OUT"; then
  fail "T3 fixture crashed: $FIXTURE_OUT"
else
  # Run A — clean run + THE accumulation ledger
  check aViolations 0 "A.1 no harness violations (good prompts, declared phases, no forbidden globals)"
  check aPhases '"frame,diverge,gap-gate,combine,converge,falsify,cross-pollinate,rank,deliver"' \
    "A.2 phase order matches the declared wave sequence"
  check aVerdict '"PROCEED"' "A.3 the scope gate verdict is carried into the return"
  check aHalts '""' "A.4 a clean run records no halts"
  check aWaveLenses '"[3,5]"' "A.5 wave 1 of 4: 3 frame lenses dispatched, running total 5"
  check aWaveGen '"[32,37]"' "A.6 wave 2 of 4: 32 generators ACCUMULATE onto the prior total (5+32=37)"
  check aWaveMods '"[2,39]"' "A.7 wave 3 of 4: 2 moderators accumulate (37+2=39)"
  check aWaveRegen '"[6,45]"' "A.8 wave 4 of 4: 6 gap-regens accumulate (39+6=45) — the retired reader saw 6"
  check aWaveSum 43 "A.9 the four waves sum to 43 dispatched agents (the defect's worked example)"
  check aDispatchedTotal 75 "A.10 the whole-run counter keeps climbing past the waves (75 total)"
  check aLedgerMonotonic true "A.11 every ledger row's total == previous total + n (no counter reset)"
  check aEverySchema true "A.12 every agent() call carries a schema (DR-4)"
  check aRelaysHaiku true "A.13 mechanical relays pin haiku"
  check aJudgmentInherit true "A.14 every uberthink wave agent OMITs model (judgment inherits flagship, RFC §5)"
  check aF2iInherit true "A.15 findings-to-issues OMITs model (judgment inherits)"
  check aRanked 3 "A.16 return.rankedCount comes from the arbiter"
  check aIssues '{"issuesCreated":[901,902],"skipped":1}' "A.17 filed issues reach the return"
  check aReportUnderRunDir true "A.18 the returned reportPath is prefix-checked under the run dir (§4.5 C-7)"
  check aF2iContract true "A.19 findings-to-issues gets the closed caller contract (path/working_dir/label/marker/max_new)"
  check aF2iNoSurplus true "A.20 findings-to-issues prompt omits agent-derived and legacy path fields"
  check aPersonaMultiline true "A.21 a multi-line personas.yaml prompt reaches the generator prompt intact"
  check aPersonaNotFlattened true "A.22 the persona prompt is NOT newline-flattened (the chr(10) lens diet is dead)"
  # Fixture F — Wave-5 file-set brief
  check fCount 16 "F.1 falsify fanout = 2 islands x 2 shortlisted composites x 4 lenses"
  check fAllFrameDir true "F.2 EVERY falsifier prompt carries frame_dir (the zero-hit grep is impossible now)"
  check fAllFrameArtifacts true "F.3 every falsifier prompt names all four frame artifacts by absolute path"
  check fAllGoalAndWorkingDir true "F.4 every falsifier prompt carries working_dir, composite_path and the goal envelope"
  check fPhysicsReadsFence true "F.5 the physics lens is told to read constraints.md FIRST (its feasibility fence)"
  check fPathIsAuthoritative true "F.6 composite_path is the path report.py wrote for THAT row, on THAT island"
  check fNoIdDerivedPath true "F.6a no falsifier is briefed with a path rebuilt from the composite id"
  check fOutIsStemDerived true "F.7 the falsify dossier is named <composite file stem>-<lens>.yaml (what report.py globs)"
  # Run B — the ceiling trips on the ACCUMULATED total
  check bObservable true "B.1 a ceiling abort still returns an observable result (DR-8)"
  check bHalts '"CB-ISLAND"' "B.2 the accumulated total (39+6=45 > 44) TRIPS CB-ISLAND"
  check bDispatched 39 "B.3 guard() throws BEFORE the unaffordable wave is dispatched (counter stays 39)"
  check bPhases '"frame,diverge,gap-gate"' "B.4 the run stops at the gap-gate wave"
  check bNoRegen true "B.5 no gap-regen agent was dispatched past the ceiling"
  check bNoFalsify true "B.6 no falsifier ran after the ceiling tripped"
  # Run S — TOOLING crash is not a verdict
  check sObservable true "S.1 a crashed deterministic cut still returns an observable result"
  check sHasTooling true "S.2 report.py rc=3 becomes a TOOLING halt"
  check sNoConverge true "S.3 a TOOLING halt NEVER routes to CB-CONVERGE (the core defect-2 lock)"
  check sSuppressAudit true "S.4 the suppression is recorded as cb_converge_suppressed_tooling"
  check sNoFalsify true "S.5 a failed cut dispatches no falsifiers (no work on a phantom empty shortlist)"
  check sNoRank true "S.5a a suppressed CB-CONVERGE still skips the floor cut + arbiter (no dossier from unwritten artifacts)"
  check sPhasesStopAtDeliver '"frame,diverge,gap-gate,combine,converge,cross-pollinate,rank,deliver"' \
    "S.5b the crashed run never enters the falsify wave"
  check sPartialSaysTooling true "S.6 the partial report tells the user a TOOLING failure stopped the run"
  check sPartialNotVerdict true "S.7 the partial report does NOT claim the goal admitted no feasible approach"
  # Run T — control: the honest negative result still fires
  check tHasConverge true "T.1 clean cuts + an empty frontier DO reach CB-CONVERGE (S.3 is not vacuous)"
  check tNoTooling true "T.2 the control run records no TOOLING halt"
  check tPartialIsNegativeResult true "T.3 the control's partial report renders the useful-negative-result text"
  # Run U — verdict-first safety
  check uHalts '"SCOPE_REFUSE"' "U.1 a REFUSE verdict halts the run"
  check uPhases '"frame"' "U.2 REFUSE never leaves the frame phase"
  check uLabels '"personas,scope-gate,refusal-report"' "U.3 REFUSE dispatches only the SSOT relay, the gate and the refusal report"
  check uNoParallel true "U.4 no parallel() burst is opened before the verdict is read"
  check uNoGenerators true "U.5 REFUSE dispatches zero generators"
  check uNoFrameLens true "U.6 REFUSE dispatches zero sibling frame lenses"
  # Run V — genetic loop-back
  check vLoopBacks 2 "V.1 island 1 loops back until the cap"
  check vCbLoop true "V.2 CB-LOOP halts further evolution of that island"
  check vRepairHintsInjected true "V.3 fixable repair hints are enveloped into the next crossover round"
  # Run W — CB-FLOOD
  check wFlood true "W.1 a per-island candidate flood trips CB-FLOOD"
  # Run X — flags
  check xNoF2i true "X.1 --no-issues skips the findings-to-issues dispatch entirely"
  check xHandoffSeed '"/r/.uberdev/think/RID/handoff-seed.md"' "X.2 --handoff returns the brainstorm seed path"
  # Run Y — SSOT relay failure aborts safely
  check yTooling true "Y.1 a failed personas SSOT relay is a TOOLING halt"
  check yNoScopeGate true "Y.2 nothing is dispatched when no prompt can be composed"
  # Run P — an unusable composite_path is dropped, not fabricated
  check pNoFalsify true "P.1 a shortlist row with no composite_path dispatches NO falsifier"
  check pTooling true "P.2 the unusable rows are recorded as a TOOLING failure of the cut"
  check pNoConverge true "P.3 that TOOLING halt suppresses CB-CONVERGE (it is not a verdict)"
  check pShortlisted 0 "P.4 no unusable row is counted as shortlisted"
  # Run Y2 — the personas payload is validated, not just its rc
  check y2Observable true "Y2.1 an unusable personas payload still returns an observable result"
  check y2Tooling true "Y2.2 rc 0 with a wrong-shaped payload is a TOOLING halt"
  check y2NoScopeGate true "Y2.3 nothing is dispatched when no prompt can be composed from it"
  check y2Audit true "Y2.4 the unusable payload is recorded as personas_payload_unusable"
  # Run Z — resume
  check zResumed true "Z.1 --resume rehydrates from the on-disk artifact scan"
  check zSkippedGate true "Z.2 an already-PROCEEDed scope gate is skipped on resume"
  check zNoScopeGate true "Z.3 the scope gate is not re-dispatched on resume"
  check zNoGenerators true "Z.4 islands whose candidates already exist are not re-diverged"
  # Run Z2 — resume must NOT destroy the donor fanout
  check z2Donors 12 "Z2.1 a resumed run rehydrates the donor catalog from scope-verdict.yaml"
  check z2SkippedGate true "Z2.2 the gate is still skipped once the donors are rehydrated"
  check z2Generators 32 "Z2.3 a resumed run still dispatches 12 donors + 4 operators per island"
  check z2Scouts 1 "Z2.4 the Field Scout fleet survives the resume (not just the fixed operators)"
  # Z3 — an un-rehydratable donor list re-runs the gate rather than degrading
  check z3ScopeGateReRun true "Z3.1 a resumed PROCEED with no donors on disk re-dispatches the scope gate"
  check z3NotSkipped true "Z3.2 the gate is NOT recorded as skipped in that case"
  check z3Donors 12 "Z3.3 the re-run gate repopulates the donor catalog"
  check z3Audit true "Z3.4 the degradation is audited as resume_donors_unrecoverable"
  # Run D — a decorated donor value is rejected loudly
  check dDonors 2 "D.1 a donor value that is not a bare slug is rejected"
  check dRejectedAudit true "D.2 the rejection is audited even though other slugs survived"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
