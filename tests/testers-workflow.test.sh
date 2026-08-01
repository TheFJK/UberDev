#!/usr/bin/env bash
# tests/testers-workflow.test.sh — RFC 0012 §3.10 (testers-R4): the migrated
# /testers Workflow script (skills/testers-pipeline/workflow.js) + the thin
# SKILL.md seam contract.
#
# GIT-BASH PORTABLE BY DESIGN: grep + `node` only — none of the python3 / PyYAML
# / mktemp -d reasons that exile the four other testers tests to the ubuntu job.
# Runs on BOTH the ubuntu and windows shape-check jobs (node ships on both
# GitHub images; harness paths are passed as plain argv).
#
# Tiers here are complementary to tests/workflow-scripts.test.sh (the generic
# T1-T4 carrier): this file adds the testers-SPECIFIC shape greps AND a T3
# BEHAVIORAL fixture that drives the script under the harness stubs with canned
# persona/monitor/runner returns and asserts the orchestration semantics the
# carrier's generic dry-run does not (per-round agent counts, politeBreach
# propagation from a pass-B rc=1, null counting, budget-guard firing, model
# policy on every call).
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals; if one were
# ever needed it must be assembled at runtime (the finish-branch pre-push
# scanner hard-aborts on contiguous secret bytes).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/testers-pipeline/SKILL.md"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/testers-pipeline/workflow.js"
HARNESS="$REPO_ROOT/tests/_workflow_harness.js"

# Hard-fail (exit 2) on missing inputs — a moved/renamed file must be an
# explicit failure, never a silently-zero-assertions PASS.
for f in "$SKILL" "$WORKFLOW" "$HARNESS"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required for the testers-workflow behavioral fixture (preinstalled on both CI images)" >&2
  exit 2
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "## testers-workflow (RFC 0012 §3.10) — shape greps + T3 behavioral fixture"

# ---------------------------------------------------------------------------
# Shape greps over workflow.js
# ---------------------------------------------------------------------------
echo "== workflow.js shape =="

# W-1: the meta literal parses as the testers-waves workflow with the 3 phases.
# Use the harness `meta` CLI (it parses the PURE-JSON literal between the
# markers and validates the shape) + node to assert name + phases.
META_JSON="$(node "$HARNESS" meta "$WORKFLOW" 2>/dev/null)"
if [ -n "$META_JSON" ] && printf '%s' "$META_JSON" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=JSON.parse(s);process.exit((m.name==="testers-waves" && Array.isArray(m.phases) && m.phases.join(",")==="waves,synthesis,issue-filing")?0:1);})'; then
  pass "W-1 meta literal parses: name=testers-waves, phases=[waves,synthesis,issue-filing]"
else
  fail "W-1 meta literal wrong (expected name=testers-waves, phases=[waves,synthesis,issue-filing]); got: $META_JSON"
fi

# W-2: the model policy is encoded IN the script — aggregate/report runners pin
# haiku; personas / monitors / findings-to-issues OMIT model (judgment inherit).
grep -q 'model: "haiku"' "$WORKFLOW" \
  && pass "W-2a aggregate/report runner agents pin model: haiku (mechanical relay)" \
  || fail "W-2a no model: \"haiku\" pin found (the mechanical relays must pin haiku)"
# Fable must NOT be pinned anywhere (operator override of the RFC §5 suggestion).
if grep -qE 'model:[[:space:]]*"fable"' "$WORKFLOW"; then
  fail "W-2b fable is pinned in workflow.js — operator direction forbids it (deviation-by-design)"
else
  pass "W-2b fable is not pinned anywhere (operator override of RFC §5 devils-advocate fable)"
fi

# W-3: the envelope helper (ported report_primitives cell()/envelope) lives in a
# SHARED block and neutralises the close tag (§4.5 C-1 / DR-5).
grep -qE '// === SHARED:envelope v[0-9]+ ===' "$WORKFLOW" \
  && pass "W-3a envelope helper is a versioned SHARED block (T4 drift-guarded)" \
  || fail "W-3a no SHARED:envelope block found"
grep -q 'external-untrusted-input' "$WORKFLOW" \
  && pass "W-3b prompt assembler wraps target-derived content in the untrusted-input envelope" \
  || fail "W-3b no external-untrusted-input envelope in the prompt assembler"

# ---------------------------------------------------------------------------
# Shape greps over SKILL.md (the thin seam)
# ---------------------------------------------------------------------------
echo "== SKILL.md seam =="

# W-4: the Workflow call is mandated with the scriptPath form (not saved-name).
grep -qF 'Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/testers-pipeline/workflow.js"}' "$SKILL" \
  && pass "W-4 SKILL.md mandates Workflow({scriptPath: .../workflow.js}, ...)" \
  || fail "W-4 SKILL.md lacks the scriptPath Workflow mandate"

# W-5: the No-Workflow fallback section is present (DR-10).
grep -qF '## No-Workflow fallback' "$SKILL" \
  && pass "W-5 SKILL.md carries the '## No-Workflow fallback' section (DR-10)" \
  || fail "W-5 SKILL.md lacks the No-Workflow fallback section"

# W-6: the post-Workflow politeBreach exit-1 mandate is stated explicitly.
grep -q 'politeBreach' "$SKILL" \
  && grep -qiE 'exit 1' "$SKILL" \
  && pass "W-6 SKILL.md states the post-Workflow politeBreach -> exit 1 mandate (headline contract)" \
  || fail "W-6 SKILL.md missing the politeBreach exit-1 mandate"

# W-7: rounds are CLAMPED to [1,10] in the preflight (the 1000-agent cap guard).
grep -qE 'ROUNDS=10|ROUNDS -gt 10' "$SKILL" \
  && grep -qE 'ROUNDS=1\b|ROUNDS -lt 1' "$SKILL" \
  && pass "W-7 SKILL.md clamps --rounds to [1,10] (Workflow 1000-agent lifetime cap)" \
  || fail "W-7 SKILL.md does not clamp --rounds to [1,10]"

# W-8: emit_workflow_args is the args seam (verbatim relay, DR-2).
grep -q 'uberdev_emit_workflow_args testers' "$SKILL" \
  && pass "W-8 SKILL.md emits args via uberdev_emit_workflow_args testers (DR-2 verbatim relay)" \
  || fail "W-8 SKILL.md does not emit args via uberdev_emit_workflow_args"

# W-9: schema_version: 1 retained (C2 cross-lock; the wave-N.yaml schema is stable).
grep -q 'schema_version: 1' "$SKILL" \
  && pass "W-9 SKILL.md retains schema_version: 1" \
  || fail "W-9 SKILL.md lost schema_version: 1"

# W-10: the never-worked master mode leaves NO live call site (re-anchors the
# #306 contract under the migration — the mode is removed, not guarded).
if [ -n "$(grep -nE 'dispatch_master[[:space:]]+("|\$|[A-Za-z./])' "$SKILL" | grep -vE '`dispatch_master`')" ]; then
  fail "W-10 an executable dispatch_master call site remains in SKILL.md (master mode must be REMOVED at the migration, #306)"
else
  pass "W-10 no live dispatch_master call site in SKILL.md (master mode removed, #306)"
fi

# W-11 (RFC 0012 §4.1): the preflight RUNS the on-disk workflow.js existence
# check before emitting args + mandating the call — not merely a prose CLAIM
# that it did. Assert an executable `[ -f ... workflow.js ]` test guard in the
# fence (a missing/misnamed workflow.js must refuse cleanly at preflight, not
# fail later at the runtime layer with a worse error). The pattern matches the
# `[ -f "$WORKFLOW_JS" ]` form where WORKFLOW_JS holds the workflow.js path; the
# `-f` + workflow.js coupling on one line is what distinguishes the live test
# from the §4.2 invocation/`scriptPath` references and the line-187 prose.
if [ -n "$(grep -nE '\[[[:space:]]+-f[[:space:]]+"\$WORKFLOW_JS"[[:space:]]+\]' "$SKILL")" ] \
   && grep -qE '^[[:space:]]*WORKFLOW_JS=.*skills/testers-pipeline/workflow\.js' "$SKILL"; then
  pass "W-11 SKILL.md preflight executes the RFC §4.1 [ -f ...workflow.js ] existence guard (not just the prose claim)"
else
  fail "W-11 SKILL.md preflight lacks the executable [ -f \"\$WORKFLOW_JS\" ] existence guard before the Workflow mandate (RFC §4.1)"
fi

# ---------------------------------------------------------------------------
# T3 behavioral fixture — drive workflow.js under the harness stubs.
# Asserts the orchestration semantics the generic carrier dry-run does not.
# ---------------------------------------------------------------------------
echo "== T3 behavioral fixture (canned returns under the harness stubs) =="

FIXTURE_OUT="$(node -e '
const h = require(process.argv[1]);
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8");
const meta = h.extractMeta(src).meta;
const personas = ["panicked_grandma","power_user","adversarial_security","chaos_engineer","a11y_critic","mobile_thumb"];
const RD = "/r/.uberdev/research/RID/testers";

// One faithful run: 2 rounds. Round 2 pass-B returns rc=1 (politeness breach).
// One persona returns null (counted). Two personas share a (location,invariant)
// pair so the in-script >=2-persona within-wave promotion fires.
function buildArgs(rounds, noIssues) {
  return { v:1, run_id:"RID", now_iso:"2026-01-01T00:00:00Z", plugin_root:"/p",
    repo_root:"/r", cwd:"/r", pipeline:"testers",
    config:{ runId:"RID", runDirAbs:RD, pluginRootAbs:"/p",
      target:"http://localhost:3000", surface:"web", rounds:rounds, rpsCap:10,
      maxIssues:10, personas:personas.join(","), noIssues:noIssues,
      invariantsPathAbs:"/p/skills/testers-pipeline/invariants.yaml",
      invariantIds:"no_5xx,auth_isolation", timestampIso:"2026-01-01T00:00:00Z" } };
}
function buildReturns() {
  const ar = {};
  personas.forEach(function (p, i) {
    [1,2].forEach(function (r) {
      // persona index 0 returns null in round 1 (user-skip / terminal error).
      if (i === 0 && r === 1) { ar["persona-"+p+"-r"+r] = null; return; }
      ar["persona-"+p+"-r"+r] = { persona:p, scratchPath:RD+"/scratch/"+p,
        findingCount:1, findings:[{ location:"/checkout", invariant_violated:"no_5xx", severity:"critical" }] };
    });
  });
  ar["aggregate-A-r1"] = { rc:0, findings:5, verified:0, stderrTail:"" };
  ar["aggregate-A-r2"] = { rc:0, findings:6, verified:0, stderrTail:"" };
  ar["monitor-primary-r1"] = { scratchPath:RD+"/scratch/monitor_primary", followUps:{ power_user:["repro grandma 500"] }, verifiedAdded:1 };
  ar["monitor-primary-r2"] = { scratchPath:RD+"/scratch/monitor_primary", followUps:{}, verifiedAdded:0 };
  ar["monitor-da-r1"] = { scratchPath:RD+"/scratch/monitor_devils_advocate", rejected:1 };
  ar["monitor-da-r2"] = { scratchPath:RD+"/scratch/monitor_devils_advocate", rejected:0 };
  ar["aggregate-B-r1"] = { rc:0, findings:5, verified:2, stderrTail:"" };
  ar["aggregate-B-r2"] = { rc:1, findings:6, verified:3, stderrTail:"breach" }; // BREACH
  ar["report-runner"] = { reportPath:RD+"/report.md", totalFindings:6, verifiedFindings:3 };
  ar["findings-to-issues"] = { issuesCreated:[101,102], skipped:1 };
  return ar;
}

function run(args, fixture) {
  const pre = h.preprocess(src);
  const record = h.makeRecord();
  const sb = h.makeSandbox(Object.assign({ args }, fixture), meta, record).sandbox;
  const pending = vm.runInNewContext(pre.wrapped, sb, { filename:"testers-waves", timeout: 8000 });
  return Promise.resolve(pending).then(function () { return record; });
}
function resultOf(record) {
  const line = record.logs.find(function (l) { return l.indexOf("WORKFLOW_RESULT ") === 0; });
  return line ? JSON.parse(line.slice("WORKFLOW_RESULT ".length)) : null;
}

(async function () {
  const out = {};

  // Run A — full 2-round happy(ish) path with a breach in round 2 + 1 null.
  const recA = await run(buildArgs(2, false), { agentReturns: buildReturns() });
  const resA = resultOf(recA);
  const counts = h.countAgentsByPhase(recA);
  out.violations = recA.violations.length;
  out.wavesCount = counts.waves || 0;          // 2 rounds * (6 personas + aggA + 2 monitors + aggB) = 20
  out.synthesisCount = counts.synthesis || 0;  // 1 report runner
  out.issueFilingCount = counts["issue-filing"] || 0; // 1 findings-to-issues
  out.everyCallHasSchema = recA.agentCalls.every(function (c) { return c.hasSchema; });
  // model policy: personas/monitors/f2i inherit (model null); aggregate/report = haiku.
  out.personaModelsInherit = recA.agentCalls
    .filter(function (c) { return c.label && c.label.indexOf("persona-") === 0; })
    .every(function (c) { return c.model === null; });
  out.f2iInherits = recA.agentCalls
    .filter(function (c) { return c.label === "findings-to-issues"; })
    .every(function (c) { return c.model === null; });
  out.aggregateHaiku = recA.agentCalls
    .filter(function (c) { return c.label && c.label.indexOf("aggregate-") === 0; })
    .every(function (c) { return c.model === "haiku"; });
  out.politeBreach = resA ? resA.politeBreach : null;       // expect true (pass-B r2 rc=1)
  out.nullsByRound = resA ? resA.nullsByRound : null;       // expect [1,0] (persona null in r1)
  out.totalFindings = resA ? resA.totalFindings : null;     // expect 6 (report-runner override)
  out.verifiedFindings = resA ? resA.verifiedFindings : null;
  out.issues = resA ? resA.issues : null;                   // expect {issuesCreated:[101,102],skipped:1}
  out.reportPathUnderRunDir = !!(resA && typeof resA.reportPath === "string" && resA.reportPath.indexOf(RD) === 0);
  out.breachAudit = !!(resA && resA.auditEvents.some(function (e) { return e.event === "polite_rate_breach"; }));
  // prompt assembly: a persona prompt carries the rl-curl shim + invariants by
  // PATH + invariant IDs + the polite-rate cap.
  const pp = recA.agentCalls.find(function (c) { return c.label && c.label.indexOf("persona-") === 0; }).prompt;
  out.promptHasShim = pp.indexOf("/lib/rl-curl") >= 0;
  out.promptHasRateStateDir = pp.indexOf("--rate-state-dir=") >= 0;
  out.promptInvariantsByPath = pp.indexOf("invariants.yaml") >= 0 && pp.indexOf("schema_version") < 0;
  out.promptHasInvariantIds = pp.indexOf("no_5xx") >= 0;

  // Run B — --no-issues: the findings-to-issues agent must NOT be dispatched.
  const recB = await run(buildArgs(1, true), { agentReturns: buildReturns() });
  out.noIssuesSkipsF2i = !recB.agentCalls.some(function (c) { return c.label === "findings-to-issues"; });

  // Run C — budget guard: a low ceiling makes an aggregate agent() throw PAST
  // the budget; the DR-8 try/catch must route to the observable finalize path
  // (nullsByRound carries the -1 throw sentinel; a round_threw audit row fires).
  const recC = await run(buildArgs(2, true),
    { budgetTotal: 8, defaultAgentReturn: { persona:"x", scratchPath:RD+"/s", findingCount:0, findings:[], rc:0, verified:0, stderrTail:"", reportPath:RD+"/report.md", issuesCreated:[], skipped:0 } });
  const resC = resultOf(recC);
  out.budgetThrowObservable = !!resC;
  out.budgetThrowSentinel = !!(resC && resC.nullsByRound.indexOf(-1) >= 0);
  out.budgetThrowAudit = !!(resC && resC.auditEvents.some(function (e) { return e.event === "round_threw"; }));
  out.budgetHarnessThrew = recC.budgetThrows > 0;

  process.stdout.write(JSON.stringify(out));
})().catch(function (e) {
  process.stdout.write(JSON.stringify({ FIXTURE_ERROR: (e && e.message) ? e.message : String(e) }));
});
' "$HARNESS" "$WORKFLOW" 2>&1)"

# Parse each assertion out of the fixture JSON via node and check it.
check() {
  # check <jq-ish key> <expected-json> <label>
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
  check violations 0 "T3.1 no harness violations (no bad prompts / undeclared phases / forbidden globals)"
  check wavesCount 20 "T3.2 per-round agent count: 2 rounds * (6 personas + aggA + 2 monitors + aggB) = 20 in phase 'waves'"
  check synthesisCount 1 "T3.3 exactly 1 report-runner in phase 'synthesis'"
  check issueFilingCount 1 "T3.4 exactly 1 findings-to-issues in phase 'issue-filing'"
  check everyCallHasSchema true "T3.5 every agent() call carries a schema (DR-4 structured returns)"
  check personaModelsInherit true "T3.6 persona agents OMIT model (judgment path inherits the session flagship, RFC §5)"
  check f2iInherits true "T3.7 findings-to-issues OMITs model (judgment path inherits)"
  check aggregateHaiku true "T3.8 aggregate runner agents pin haiku (mechanical relay, RFC §5)"
  check politeBreach true "T3.9 politeBreach propagates from the pass-B rc==1 (the SOLE authoritative audit)"
  check nullsByRound '[1,0]' "T3.10 null persona return is COUNTED per round (nullsByRound=[1,0], not silently dropped)"
  check totalFindings 6 "T3.11 totalFindings reflects the final report-runner count"
  check verifiedFindings 3 "T3.12 verifiedFindings reflects the final report-runner count"
  check issues '{"issuesCreated":[101,102],"skipped":1}' "T3.13 issues carry the created numbers + skipped count back to the return"
  check reportPathUnderRunDir true "T3.14 returned reportPath is realpath-prefix-checked under the run dir (§4.5 C-7)"
  check breachAudit true "T3.15 a polite_rate_breach audit row is emitted on breach"
  check promptHasShim true "T3.16 persona prompt carries the lib/rl-curl shim invocation"
  check promptHasRateStateDir true "T3.17 persona prompt carries the per-call --rate-state-dir= injection"
  check promptInvariantsByPath true "T3.18 persona prompt carries invariants by PATH, not the YAML bytes (§3.10)"
  check promptHasInvariantIds true "T3.19 persona prompt names the invariant IDs"
  check noIssuesSkipsF2i true "T3.20 --no-issues skips the findings-to-issues dispatch entirely"
  check budgetThrowObservable true "T3.21 the DR-8 budget-throw path still returns an observable result"
  check budgetThrowSentinel true "T3.22 a budget-aborted round records the -1 nullsByRound sentinel"
  check budgetThrowAudit true "T3.23 a budget-aborted round emits a round_threw audit row"
  check budgetHarnessThrew true "T3.24 the budget ceiling actually made an agent() call throw (the guard fired, not vacuous)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
