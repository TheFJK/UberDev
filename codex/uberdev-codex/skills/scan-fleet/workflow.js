/* META-BEGIN */
export const meta = { "name": "scan-fleet", "description": "Shared whole-codebase fixed-fleet Workflow for /uberscan (read-only audit) and /ubersimplify (preserve-behavior refactor). Packs the repo into <= N byte-balanced areas via lib/chunk.py, runs ONE multi-lens reviewer per area in concurrency-bounded waves, then branches on mode: scan runs an inline repo-global Semgrep+coverage pass, aggregates via report.py, and files deduped issues; simplify aggregates via aggregate.py, applies one code-fixer refactor: commit per area on a shared branch (sequential — git-index safe), opens ONE PR, and files leftover-blocker issues. --audit-only collapses simplify to read-only. RFC 0012 §3.7 (Phase 3).", "phases": ["pack","areas","global-pass","aggregate","apply","pr","issue-filing"], "whenToUse": "Invoked verbatim by uberscan-pipeline (mode=scan) and ubersimplify-pipeline (mode=simplify) SKILL.md after the preflight emits args." };
/* META-END */

// skills/scan-fleet/workflow.js — RFC 0012 §3.7 (Phase 3, the first read-only
// fleet + the first WRITING workflow). ONE script serves BOTH /uberscan and
// /ubersimplify; the `mode` config key is the branch. In SKILL.md directive-
// emitter form the phases diverge across un-shareable prose; in the Workflow
// runtime they are functions branching on one constant, sharing the area-pack +
// per-area-reviewer wave verbatim. (§0 of the design verdict.)
//
// Orchestration state lives in JS variables spanning the whole run; only the
// return value + log() lines reach the main session. Agents do ALL filesystem /
// git / gh / chunk.py / semgrep / commit work — this script never touches the FS
// (forbidden by the runtime; enforced by tests/workflow-scripts.test.sh T1).
//
// Carrier contract (tests/workflow-scripts.test.sh + tests/_workflow_harness.js):
//   T1 — node --check --input-type=module; self-contained (no module loaders),
//        no Node/FS APIs, no nondeterministic clock/random globals outside SHARED
//        blocks; <=512 KB.
//   T2 — pure-JSON meta literal between the META markers; every phase()/opts.phase
//        string is declared in meta.phases (declaring-without-emitting is legal —
//        scan never emits apply/pr; simplify never emits global-pass).
//   T3 — async-IIFE-wrappable; runs under the harness stubs (behavioral fixture in
//        tests/scan-fleet-workflow.test.sh).
//   T4 — the // === SHARED:envelope v1 === block is BYTE-IDENTICAL to
//        testers-pipeline/workflow.js (same name+version => copy-paste identical).
//
// Model policy (RFC 0012 §5): area reviewers/simplifiers + code-fixer applies +
// findings-to-issues are JUDGMENT paths — opts.model is OMITTED so the user's
// session flagship flows through. Mechanical relays (chunk.py pack, report.py /
// aggregate.py runners, the inline semgrep+coverage pass, the gh-pr/branch
// relays) pin haiku (rc + path passthrough). Fable is never pinned.
//
// DR-7: wall-clock arrives FROZEN in args (now_iso); the runtime forbids the
//       nondeterministic clock/random globals. The SKILL.md prose CB3/CB4
//       (>900s/wave, >3600s wall) are time-based and therefore IMPOSSIBLE inside
//       the script — but they were ALREADY DEAD in the ms-returning directive-
//       emitter fence (memory: project_uberdev_pipeline_directive_emitter). Net
//       no loss: the real `budget` lifetime cap + CB5 (blocker flood) + CB7
//       (agent ceiling) cover the live failure modes. Documented in the PR body.
// DR-8: the whole orchestration is wrapped in main()'s try/catch routing to
//       emitResult(), so a budget throw (or any agent-chain throw) never skips
//       the structured return.

// args envelope (uberdev_emit_workflow_args, RFC 0012 §4.3): reserved keys
// (run_id, plugin_root, repo_root, cwd) + locked v/now_*/pipeline sit top-level;
// everything the preflight emits lands under .config. Normalize both into one
// view (the testers-pipeline/workflow.js:42-51 idiom).
const A = (args && typeof args === "object") ? args : {};
const CFG = (A.config && typeof A.config === "object") ? A.config : {};

const mode = (CFG.mode === "simplify") ? "simplify" : "scan";   // default-closed to read-only scan
const runId = A.run_id || CFG.runId || "";
const pluginRootAbs = CFG.pluginRootAbs || A.plugin_root || "";
const repoRootAbs   = CFG.repoRootAbs   || A.repo_root   || "";
const runDirAbs = CFG.runDirAbs || "";
const scope = CFG.scope || ".";
const manifestPathAbs = CFG.manifestPathAbs || (runDirAbs ? runDirAbs + "/manifest.json" : "");
const nowIso = CFG.timestampIso || A.now_iso || "";

// numeric knobs clamped defensively (a script must never trust an out-of-range
// value into the 1000-agent lifetime cap), matching the SKILL.md config ranges.
const numAreas    = clampInt(CFG.numAreas, 1, 24, 8);
const concurrency = clampInt(CFG.concurrency, 1, 16, 3);
const maxAgents   = clampInt(CFG.maxAgents, 1, 2000, 250);
const maxNew      = clampInt(CFG.maxNew, 1, 200, mode === "simplify" ? 10 : 15);
const blockerCap  = clampInt(CFG.cumulativeBlockerCap, 1, 100000, 150);

const auditOnly = CFG.auditOnly === true || CFG.auditOnly === 1 || CFG.auditOnly === "1";
const noIssues  = CFG.noIssues  === true || CFG.noIssues  === 1 || CFG.noIssues  === "1";
const noReport  = CFG.noReport  === true || CFG.noReport  === 1 || CFG.noReport  === "1";

// scan: report/issue gate; simplify ignores (lens severity is blocker|suggestion).
const minSeverity = String(CFG.minSeverity || "major");
// simplify-only: the active lens set (default all three, checklist order).
const lenses = String(CFG.lenses || "Reuse,Quality,Efficiency")
  .split(",").map(function (s) { return s.trim(); }).filter(Boolean);
const branchName = CFG.branchName || ((mode === "simplify") ? "ubersimplify/" + runId : "");

// NOTE on envelope discipline (DR-5): unlike testers-pipeline/workflow.js, this
// script never embeds agent-derived / repo-content-derived strings into a
// downstream prompt — every prompt input is script-derived (run-dir-relative
// paths, validated digit-only area ids, config scalars). The untrusted finding
// text is enveloped at the PRODUCER (report.py / aggregate.py via
// lib/report_primitives.py — source=uberscan-aggregate / ubersimplify-aggregate)
// and only ever passed onward BY PATH (underRunDir-checked). So there is no
// JS-side SHARED:envelope block here — nothing in this script's prompts needs
// wrapping. (Carry one verbatim from testers the moment a prompt embeds
// agent-returned content.)

function clampInt(v, lo, hi, dflt) {
  var n = (typeof v === "number") ? v : parseInt(v, 10);
  if (typeof n !== "number" || n !== n) return dflt; // NaN guard (no isNaN dep)
  n = Math.floor(n);
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

// Zero-pad an area id to the chunk-NNN-*.yaml convention report.py/aggregate.py
// glob (`chunk-*-findings.yaml` / `chunk-*-lens.yaml`). Area ids from chunk.py
// are 1..N (<=24), so 3-digit padding is always sufficient.
function pad(id) {
  return ("00" + String(id)).slice(-3);
}

// realpath-prefix discipline (§4.5 C-7 / DR-6): an agent-returned path must sit
// under the run dir before a downstream phase trusts it. The script cannot call
// realpath (no fs); a prefix-string check is the in-script floor. Every path we
// EMIT is script-derived (runDirAbs + a fixed suffix), never agent-returned.
function underRunDir(p) {
  return typeof p === "string" && runDirAbs.length > 0
    && (p === runDirAbs || p.indexOf(runDirAbs + "/") === 0);
}

// ---- schemas (DR-4: structured returns, enums closed, counts integers) ----
const S = {
  pack: { type: "object", additionalProperties: false,
    required: ["areaIds", "areaCount", "overflow", "rc"],
    properties: {
      areaIds: { type: "array", items: { type: "string" } },
      areaCount: { type: "integer", minimum: 0 },
      overflow: { type: "boolean" },
      rc: { type: "integer" },
      skippedOversize: { type: "integer", minimum: 0 },
    } },
  // area reviewer returns stay THIN (disk is the evidence channel): the per-area
  // YAML on disk is what report.py/aggregate.py consume. blockerCount feeds the
  // in-script CB5 flood decision only.
  area: { type: "object", additionalProperties: false,
    required: ["areaId", "outPath", "findingCount"],
    properties: {
      areaId: { type: "string" },
      outPath: { type: "string" },
      findingCount: { type: "integer", minimum: 0 },
      blockerCount: { type: "integer", minimum: 0 },
    } },
  // inline semgrep+coverage relay (scan only). Writes the two global-*.md files
  // report.py read_global() consumes; returns counts for the log line.
  global: { type: "object", additionalProperties: false,
    required: ["rc"],
    properties: {
      semgrepPath: { type: "string" },
      coveragePath: { type: "string" },
      semgrepFindingCount: { type: "integer", minimum: 0 },
      coverageGapCount: { type: "integer", minimum: 0 },
      rc: { type: "integer" },
    } },
  // scan aggregate (report.py) relay.
  aggScan: { type: "object", additionalProperties: false,
    required: ["rc"],
    properties: {
      reportPath: { type: "string" },
      aggregatePath: { type: "string" },
      totalFindings: { type: "integer", minimum: 0 },
      rc: { type: "integer" },
    } },
  // simplify per-area fixer aggregate (aggregate.py fixer) relay.
  aggFixer: { type: "object", additionalProperties: false,
    required: ["outPath", "rc"],
    properties: {
      outPath: { type: "string" },
      mergedCount: { type: "integer", minimum: 0 },
      rc: { type: "integer" },
    } },
  // branch-setup relay (simplify apply).
  branch: { type: "object", additionalProperties: false,
    required: ["rc"],
    properties: { branch: { type: "string" }, baseBranch: { type: "string" }, rc: { type: "integer" } } },
  // code-fixer apply (simplify, judgment — model omitted).
  fixer: { type: "object", additionalProperties: false,
    required: ["areaId", "status"],
    properties: {
      areaId: { type: "string" },
      status: { type: "string", enum: ["APPLIED", "NO_FIXES_NEEDED", "REFUSED"] },
      commitSha: { type: "string" },
      dispositionPath: { type: "string" },
    } },
  // pr-open relay (simplify).
  pr: { type: "object", additionalProperties: false,
    required: ["rc"],
    properties: {
      prNumber: { type: "integer", minimum: 0 },
      prUrl: { type: "string" },
      branch: { type: "string" },
      commitCount: { type: "integer", minimum: 0 },
      rc: { type: "integer" },
    } },
  // simplify leftover-issues aggregate (aggregate.py issues) relay.
  issuesAgg: { type: "object", additionalProperties: false,
    required: ["aggregatePath", "rc"],
    properties: { aggregatePath: { type: "string" }, rc: { type: "integer" } } },
  // findings-to-issues (judgment — model omitted). Byte-identical to testers S.f2i.
  f2i: { type: "object", additionalProperties: false,
    required: ["issuesCreated", "skipped"],
    properties: {
      issuesCreated: { type: "array", items: { type: "integer" } },
      skipped: { type: "integer", minimum: 0 },
    } },
};

// ----------------------------- prompt builders -----------------------------

function packPrompt() {
  // Mechanical relay (haiku): run chunk.py, read the manifest back, return the
  // area inventory. chunk.py CLI (lib/chunk.py:121-128): --scope / --areas
  // (required positive int) / --run-id. It writes the manifest JSON to STDOUT —
  // there is NO --out flag — so the relay redirects stdout to manifestPathAbs.
  // The deleted --budget-bytes/--max-chunks modes MUST NOT appear.
  var cmd = 'python3 "' + pluginRootAbs + '/lib/chunk.py" '
    + '--scope "' + scope + '" --areas ' + numAreas + ' --run-id "' + runId + '" '
    + '> "' + manifestPathAbs + '"';
  return "Run EXACTLY this via Bash and report its result — mechanical relay, do not interpret.\n\n"
    + "  " + cmd + "\n\n"
    + "Then Read " + manifestPathAbs + " and return via StructuredOutput: areaIds (an array of the "
    + "manifest chunks[].id values AS STRINGS, e.g. [\"1\",\"2\"]), areaCount (integer = manifest.total_chunks), "
    + "overflow (boolean manifest.overflow — MUST be false in area mode), rc (chunk.py's exit code), and "
    + "skippedOversize (integer length of manifest.skipped_oversize, the coverage-gap count).";
}

function areaPrompt(areaId) {
  var num = pad(areaId);
  var out = runDirAbs + "/chunk-" + num + (mode === "simplify" ? "-lens.yaml" : "-findings.yaml");
  var lines = [];
  if (mode === "simplify") {
    lines.push("You are the sole multi-lens code-simplifier for AREA " + num
      + " of a /uberdev:ubersimplify whole-codebase audit. Read the agent instructions at "
      + pluginRootAbs + "/agents/code-simplifier.md and follow them exactly.");
    lines.push("");
    lines.push("Read the manifest at " + manifestPathAbs + ", find the chunk whose id == "
      + areaId + " (integer), and audit EVERY file in that chunk's .files list AS THEY STAND in the "
      + "repository — this is NOT a diff review.");
    lines.push("");
    lines.push("## Lens emphasis: " + lenses.join(", "));
    lines.push("> Run EVERY listed lens's checklist over the whole area. For the Reuse lens, hunt "
      + "cross-file duplication across the whole repository. Tag each finding with the lens it came from.");
    lines.push("");
    lines.push("Write the area's findings to " + out + " in the C-LENS schema (one record per finding):");
    lines.push("");
    lines.push("  schema_version: 1");
    lines.push("  chunk_id: " + areaId);
    lines.push("  files: [<the file paths you examined>]");
    lines.push("  findings:");
    lines.push("    - location: <path>:<line>");
    lines.push("      severity: blocker | suggestion");
    lines.push("      lens: Reuse | Quality | Efficiency");
    lines.push("      summary: <1-line, no source quoting>");
    lines.push("      detail: <prose rationale + suggested direction>");
    lines.push("");
    lines.push("If you have zero findings, write an empty findings list — do not invent findings.");
    lines.push("");
    lines.push("Return via StructuredOutput: areaId (\"" + areaId + "\"), outPath (\"" + out + "\"), "
      + "findingCount (integer total findings you wrote), and blockerCount (integer count of "
      + "severity: blocker rows).");
  } else {
    lines.push("You are the sole multi-lens reviewer for AREA " + num
      + " of a /uberdev:uberscan whole-codebase read-only audit. Read the agent instructions at "
      + pluginRootAbs + "/agents/code-reviewer.md and follow them exactly. You do NOT write source files.");
    lines.push("");
    lines.push("Read the manifest at " + manifestPathAbs + ", find the chunk whose id == "
      + areaId + " (integer), and audit EVERY file in that chunk's .files list AS THEY STAND in the "
      + "repository — this is NOT a diff review. Read each file in full, then sweep ALL of these lenses "
      + "in one pass:");
    lines.push("  1. Correctness — bugs, logic errors, race conditions, edge cases.");
    lines.push("  2. Silent failures & error handling — swallowed errors, missing fallbacks, fail-open paths.");
    lines.push("  3. Type design — weak/over-broad types, unexpressed invariants, any.");
    lines.push("  4. Comment accuracy — comments that contradict the code, comment rot.");
    lines.push("  5. Test coverage — untested branches, missing edge-case tests.");
    lines.push("  6. General catch-all — anything else that lowers quality or safety.");
    lines.push("");
    lines.push("Minimum severity to report: " + minSeverity);
    lines.push("");
    lines.push("Write the area's findings to " + out + " in the C2 schema (one row per finding):");
    lines.push("");
    lines.push("  schema_version: 1");
    lines.push("  chunk_id: " + areaId);
    lines.push("  files: [<the file paths you examined>]");
    lines.push("  findings:");
    lines.push("    - severity: blocker | critical | major | important | suggestion");
    lines.push("      location: <path>:<line>");
    lines.push("      agent: code-reviewer");
    lines.push("      summary: <1-line, lead with the lens, e.g. \"[correctness] ...\">");
    lines.push("      detail: <prose>");
    lines.push("      confidence: low | medium | high");
    lines.push("");
    lines.push("Return via StructuredOutput: areaId (\"" + areaId + "\"), outPath (\"" + out + "\"), "
      + "findingCount (integer total findings you wrote), and blockerCount (integer count of "
      + "severity blocker+critical rows).");
  }
  return lines.join("\n");
}

function globalPassPrompt() {
  // Mechanical relay (haiku): the repo-global Semgrep SAST + test-coverage pass.
  // The logic lives in skills/scan-fleet/global-pass.sh (the T1 self-contained-
  // script grep forbids Python module-load keywords inside this JS file; the script is
  // also reused by the uberscan No-Workflow fallback). Fail-soft, and writes the
  // two artifacts report.py read_global() consumes BY NAME.
  var sec = runDirAbs + "/global-security.md";
  var cov = runDirAbs + "/global-coverage.md";
  return "Run EXACTLY this via Bash and report the result \u2014 mechanical relay, do NOT interpret the "
    + "findings. It runs the repo-global Semgrep SAST + test-coverage pass (fail-soft: a missing/erroring "
    + "semgrep or python3 degrades to a skip note, never aborts):\n\n"
    + '  bash "' + pluginRootAbs + '/skills/scan-fleet/global-pass.sh" "' + scope + '" "' + runDirAbs + '"\n\n'
    + "Then return via StructuredOutput: semgrepPath (\"" + sec + "\"), coveragePath (\"" + cov + "\"), "
    + "semgrepFindingCount (integer count of lines starting with '- **' in " + sec + ", or 0), "
    + "coverageGapCount (integer count of '- ' lines in " + cov + ", or 0), and rc (0 unless the script "
    + "itself failed to run).";
}
function scanAggregatePrompt() {
  // report.py CLI verified (uberscan-pipeline/report.py:156-171). One invocation
  // does report + totals sidecar + issue aggregate (main() handles all flags).
  var report = runDirAbs + "/uberscan-report.md";
  var totals = runDirAbs + "/totals.json";
  var agg = runDirAbs + "/f2i-aggregate.md";
  var cmd = 'python3 "' + pluginRootAbs + '/skills/uberscan-pipeline/report.py" '
    + '--run-id "' + runId + '" --chunks-dir "' + runDirAbs + '" '
    + (noReport ? "" : '--out "' + report + '" ')
    + '--emit-totals-json "' + totals + '" '
    + (noIssues ? "" : '--min-severity "' + minSeverity + '" '
        + '--emit-findings-to-issues-aggregate "' + agg + '" ');
  return "Run EXACTLY this via Bash — mechanical relay, do not interpret:\n\n"
    + "  " + cmd.trim() + "\n\n"
    + "Then return via StructuredOutput: reportPath (\"" + (noReport ? "" : report) + "\"), "
    + "aggregatePath (\"" + (noIssues ? "" : agg) + "\"), totalFindings (integer = .total from "
    + totals + " via jq), and rc (the command's exit code).";
}

function fixerAggPrompt(areaId) {
  // aggregate.py fixer --lens-file --out  (ubersimplify-pipeline/aggregate.py).
  var num = pad(areaId);
  var lensFile = runDirAbs + "/chunk-" + num + "-lens.yaml";
  var out = runDirAbs + "/chunk-" + num + "-fixer.md";
  var cmd = 'python3 "' + pluginRootAbs + '/skills/ubersimplify-pipeline/aggregate.py" fixer '
    + '--lens-file "' + lensFile + '" --out "' + out + '"';
  return "Run EXACTLY this via Bash — mechanical relay, do not interpret:\n\n"
    + "  " + cmd + "\n\n"
    + "If " + lensFile + " does not exist (the area produced no lens file), skip the command and return "
    + "rc=0 with mergedCount=0. Otherwise return via StructuredOutput: outPath (\"" + out + "\"), "
    + "mergedCount (integer count of finding rows in the merged aggregate, or 0), rc (exit code).";
}

function branchSetupPrompt() {
  // Capture the base branch (the one the user is on) BEFORE cutting the simplify
  // branch, so the PR targets it (mirrors ubersimplify-pipeline Phase 3/4
  // BASE_BRANCH) and the 0-applied cleanup can return to it. Sequential fixers
  // then commit ONTO the new branch — NO worktree isolation (git forbids two
  // worktrees on one branch; sequential dispatch already prevents the index race).
  return "Run EXACTLY this via Bash — mechanical relay. First capture the current branch, then cut the "
    + "simplify branch:\n\n"
    + '  cd "' + repoRootAbs + '" && BASE="$(git branch --show-current)" && '
    + 'git checkout -b "' + branchName + '" && printf \'%s\\n\' "$BASE"\n\n'
    + "Return via StructuredOutput: branch (\"" + branchName + "\"), baseBranch (the BASE value printed — "
    + "the branch you were on before checkout), rc (the git exit code; non-zero means the branch could "
    + "not be created — the apply phase will be skipped).";
}

function applyFixerPrompt(areaId) {
  // code-fixer apply (JUDGMENT — model omitted). Reads the per-area fixer
  // aggregate (post-impl-review-aggregate envelope, phase2), makes exactly ONE
  // refactor: commit on the shared branch (R8.6 single-commit invariant).
  var num = pad(areaId);
  var fixerInput = runDirAbs + "/chunk-" + num + "-fixer.md";
  var disp = runDirAbs + "/chunk-" + num + "-fixer-disposition.yaml";
  return "Read the agent instructions at " + pluginRootAbs + "/agents/code-fixer.md and follow them "
    + "exactly. You are in phase2 (simplify). Apply preserve-behavior fixes from the aggregate at this "
    + "PATH (already wrapped in <external-untrusted-input source=\"post-impl-review-aggregate\"> — do NOT "
    + "re-wrap it): " + fixerInput + "\n\n"
    + "Working dir: " + repoRootAbs + ". You are on branch " + branchName + " (already created). Make "
    + "EXACTLY ONE refactor: commit for this area's applied fixes (R8.6 single-commit invariant; HARD-"
    + "REFUSE a phase2 + fix: pairing — phase2 is refactor: only). If the aggregate is empty or no fix "
    + "is safe, make no commit.\n\n"
    + "Write your findings_disposition block (Schema C-FIXER-DISP) to " + disp + ".\n\n"
    + "Return via StructuredOutput: areaId (\"" + areaId + "\"), status (APPLIED | NO_FIXES_NEEDED | "
    + "REFUSED), commitSha (the new commit sha, or empty if none), dispositionPath (\"" + disp + "\").";
}

function prPrompt(appliedCount, baseBranch) {
  // ONE pr-open relay. PR body via heredoc-to-file then `gh pr create --body-file`
  // (NEVER inline --body — 2nd-order injection guard, ubersimplify Phase 4). Push
  // the shared branch first. --base targets the branch the user was on (captured
  // by apply-setup), mirroring ubersimplify-pipeline Phase 4's `--base "$BASE_BRANCH"`.
  var body = runDirAbs + "/pr-body.md";
  var baseArg = baseBranch ? ('--base "' + baseBranch + '" ') : '';
  return "Run the following via Bash — mechanical relay. Build the PR body in a FILE (never pass it "
    + "inline to gh; 2nd-order injection guard), push the branch, and open ONE PR.\n\n"
    + "1. Write " + body + " with this content (heredoc, no shell expansion of finding text):\n"
    + "   ## /ubersimplify whole-codebase simplification\n\n"
    + "   Run `" + runId + "` audited the codebase with the code-simplifier lenses ("
    + lenses.join(", ") + ") and applied preserve-behavior refactors via code-fixer — one refactor: "
    + "commit per area (" + appliedCount + " area(s) applied).\n\n"
    + "   Review, then run /review-pr on this PR.\n\n"
    + "2. Push + open the PR (no Claude/co-author trailer — project rule):\n"
    + '   cd "' + repoRootAbs + '" && git push -u origin "' + branchName + '" && \\\n'
    + '   gh pr create ' + baseArg + '--head "' + branchName + '" --title "refactor: /ubersimplify '
    + 'whole-codebase simplification (' + runId + ')" --body-file "' + body + '"\n\n'
    + "Return via StructuredOutput: prNumber (the integer PR number parsed from the gh URL, or 0 on "
    + "failure), prUrl (the URL or empty), branch (\"" + branchName + "\"), commitCount (integer commits "
    + "on the branch vs its base), rc (0 on success).";
}

function branchCleanupPrompt(baseBranch) {
  // 0-applied teardown: return to the base branch and delete the empty temp
  // branch so a clean simplify run leaves the tree untouched (mirrors
  // ubersimplify-pipeline Phase 4's 0-commit path). `git checkout -` falls back
  // to the previous branch when the base name is unknown.
  var base = baseBranch ? baseBranch : "-";
  return "Run EXACTLY this via Bash — mechanical relay (the simplify run applied 0 fixes; remove the "
    + "empty temp branch so the tree is untouched):\n\n"
    + '  cd "' + repoRootAbs + '" && git checkout "' + base + '" && git branch -D "' + branchName + '"\n\n'
    + "Return via StructuredOutput: branch (\"\"), rc (0 on success; non-zero is non-fatal — the empty "
    + "branch is just left for manual cleanup).";
}

function simplifyIssuesAggPrompt() {
  // aggregate.py issues --chunks-dir --out [--audit-only]  → ubersimplify-aggregate envelope.
  var agg = runDirAbs + "/f2i-aggregate.md";
  var cmd = 'python3 "' + pluginRootAbs + '/skills/ubersimplify-pipeline/aggregate.py" issues '
    + '--chunks-dir "' + runDirAbs + '" --out "' + agg + '"' + (auditOnly ? " --audit-only" : "");
  return "Run EXACTLY this via Bash — mechanical relay, do not interpret:\n\n"
    + "  " + cmd + "\n\n"
    + "Return via StructuredOutput: aggregatePath (\"" + agg + "\"), rc (the command's exit code).";
}

function f2iPrompt(aggregatePathAbs, sourceTag, prNumber) {
  // findings-to-issues (JUDGMENT — model omitted). Reads the aggregate by PATH;
  // the envelope source on disk is the source-of-record. The agent OWNS MAX_NEW /
  // dedupe / halt. working_dir + repo backref are resolved BY THE AGENT via git.
  return "Read the agent instructions at " + pluginRootAbs + "/agents/findings-to-issues.md and follow "
    + "them exactly. File GitHub issues from the aggregate at this PATH (envelope source="
    + sourceTag + ", validated at read): " + aggregatePathAbs + "\n\n"
    + "Resolve working_dir via `git rev-parse --show-toplevel` (REQUIRED — the agent refuses without an "
    + "absolute working_dir), repo_slug + pr_commit_sha via git/gh. "
    + "finding_label=" + (mode === "simplify" ? "ubersimplify" : "uberscan") + "-finding, "
    + "finding_marker_slug=" + (mode === "simplify" ? "ubersimplify" : "uberscan") + ", "
    + "source_ref=/" + (mode === "simplify" ? "ubersimplify" : "uberscan") + " run " + runId + ", "
    + "pr_number=" + (prNumber ? prNumber : "") + ".\n\n"
    + "Cap: create at most " + maxNew + " new issues (MAX_NEW). You OWN the MAX_NEW / dedupe / halt logic.\n\n"
    + "Return via StructuredOutput: issuesCreated (an array of the integer issue numbers you created) and "
    + "skipped (integer count of findings you skipped as duplicates or over the cap).";
}

// ----------------------------- run state -----------------------------
let areaCount = 0;
let areasReturned = 0;
let totalFindings = 0;
let cumulativeBlockers = 0;
let cb5Tripped = false;
let reportPath = "";
let aggregatePath = "";
let branch = "";
let prNumber = 0;
let appliedAreas = 0;
let refusedAreas = 0;
let noFixesNeededAreas = 0;
let baseBranch = "";
let issues = { issuesCreated: [], skipped: 0 };
const nullsByPhase = {};
const auditEvents = [];

function noteNull(phaseName) {
  nullsByPhase[phaseName] = (nullsByPhase[phaseName] || 0) + 1;
}

function finalize() {
  return {
    runId: runId,
    mode: mode,
    scope: scope,
    areaCount: areaCount,
    areasReturned: areasReturned,
    totalFindings: totalFindings,
    cumulativeBlockers: cumulativeBlockers,
    cb5Tripped: cb5Tripped,
    reportPath: reportPath,
    aggregatePath: aggregatePath,
    branch: branch,
    prNumber: prNumber,
    appliedAreas: appliedAreas,
    refusedAreas: refusedAreas,
    noFixesNeededAreas: noFixesNeededAreas,
    auditOnly: auditOnly,
    issues: issues,
    nullsByPhase: nullsByPhase,
    auditEvents: auditEvents,
  };
}

// emitResult logs the full result as ONE structured line (the §4.6 observability
// channel + the T3-fixture assertion seam) and returns it. Used on EVERY return
// path — success and the DR-8 throw-path — so an abort is just as observable.
function emitResult() {
  const result = finalize();
  log("WORKFLOW_RESULT " + JSON.stringify(result));
  return result;
}

function budgetExhausted() {
  return budget && budget.total && budget.remaining() <= 0;
}

async function main() {
  log("scan-fleet run " + runId + " — mode=" + mode + ", scope=" + scope
    + ", numAreas=" + numAreas + ", concurrency=" + concurrency
    + (mode === "simplify" ? (", auditOnly=" + auditOnly + ", lenses=" + lenses.join("+")) : ""));

  try {
    // ----------------------------- pack -----------------------------
    phase("pack");
    const packRet = await agent(packPrompt(),
      { model: "haiku", phase: "pack", label: "area-pack", schema: S.pack });
    if (packRet === null) {
      noteNull("pack");
      auditEvents.push({ event: "pack_null", ts: nowIso });
      log("pack: area-pack returned null — cannot proceed without an area inventory");
      return emitResult();
    }
    if (packRet.rc !== 0 || packRet.overflow === true || packRet.areaCount < 1
        || !Array.isArray(packRet.areaIds) || packRet.areaIds.length < 1) {
      auditEvents.push({ event: "pack_failed", rc: packRet.rc, overflow: packRet.overflow,
        areaCount: packRet.areaCount, ts: nowIso });
      log("pack: chunk.py failed/empty/overflow (rc=" + packRet.rc + ", overflow=" + packRet.overflow
        + ", areaCount=" + packRet.areaCount + ") — aborting");
      return emitResult();
    }
    // Validate each area id is digits-only before it is interpolated into any
    // later prompt (injection floor; manifest ids are 1..N integers).
    const areaIds = packRet.areaIds.filter(function (id) { return /^[0-9]+$/.test(String(id)); });
    areaCount = areaIds.length;
    if (areaCount !== packRet.areaCount) {
      auditEvents.push({ event: "area_id_mismatch", reported: packRet.areaCount, valid: areaCount, ts: nowIso });
    }
    log("pack: " + areaCount + " area(s)"
      + (packRet.skippedOversize ? (", " + packRet.skippedOversize + " oversize file(s) skipped") : ""));

    // CB7 projected-agent ceiling: areaCount reviewers + (scan ? 1 global) +
    // (simplify non-audit ? areaCount fixers) + ~4 relays/aggregators.
    const projected = areaCount
      + (mode === "scan" ? 1 : 0)
      + ((mode === "simplify" && !auditOnly) ? areaCount : 0)
      + 4;
    if (projected > maxAgents) {
      auditEvents.push({ event: "agent_ceiling_cb7", projected: projected, maxAgents: maxAgents, ts: nowIso });
      log("CB7: projected " + projected + " agents exceeds maxAgents=" + maxAgents + " — aborting "
        + "(lower --areas or raise the max_agents config)");
      return emitResult();
    }

    // ----------------------------- areas -----------------------------
    // Concurrency-bounded waves: parallel() is a barrier (the aggregate / global
    // pass read the union of all per-area YAML on disk). The for-loop serializes
    // batches to respect `concurrency`.
    phase("areas");
    const agentType = (mode === "simplify") ? "uberdev:code-simplifier" : "uberdev:code-reviewer";
    const labelPrefix = (mode === "simplify") ? "simplify-area-" : "scan-area-";
    for (let i = 0; i < areaIds.length; i += concurrency) {
      const batch = areaIds.slice(i, i + concurrency);
      const thunks = batch.map(function (areaId) {
        return function () {
          return agent(areaPrompt(areaId),
            { agentType: agentType, phase: "areas", label: labelPrefix + pad(areaId), schema: S.area });
          // model OMITTED — area review/simplify is a JUDGMENT path (RFC §5).
        };
      });
      const returns = await parallel(thunks);
      for (let j = 0; j < returns.length; j++) {
        const r = returns[j];
        if (r === null) { noteNull("areas"); continue; }
        areasReturned++;
        if (typeof r.findingCount === "number") totalFindings += r.findingCount;
        if (typeof r.blockerCount === "number") cumulativeBlockers += r.blockerCount;
      }
      // CB5 blocker-flood: authoritative ONLY for the halt decision. ALL downstream
      // reporting reads on-disk YAML (the aggregator re-counts) — never feed
      // cumulativeBlockers into a finding total (it is stale after a break).
      if (cumulativeBlockers > blockerCap) {
        cb5Tripped = true;
        auditEvents.push({ event: "blocker_flood_cb5", cumulative: cumulativeBlockers, cap: blockerCap, ts: nowIso });
        log("CB5: cumulative blockers " + cumulativeBlockers + " > " + blockerCap
          + " — halting the area wave loop (report marked partial)");
        break;
      }
      // budget guard between batches (DR-8: total truthy before remaining()).
      if (budgetExhausted()) {
        auditEvents.push({ event: "budget_exhausted", phase: "areas", ts: nowIso });
        log("budget exhausted during the area wave loop — stopping early");
        break;
      }
    }
    log("areas: " + areasReturned + "/" + areaCount + " area(s) returned, "
      + totalFindings + " raw finding(s), " + cumulativeBlockers + " blocker-tier");

    // --------------------- scan: global-pass + aggregate ---------------------
    if (mode === "scan") {
      phase("global-pass");
      const globalRet = await agent(globalPassPrompt(),
        { model: "haiku", phase: "global-pass", label: "global-pass", schema: S.global });
      if (globalRet === null) {
        noteNull("global-pass");
        auditEvents.push({ event: "global_pass_null", ts: nowIso });
        log("global-pass: returned null — report aggregates area findings only this run");
      } else {
        log("global-pass: " + (globalRet.semgrepFindingCount || 0) + " semgrep finding(s), "
          + (globalRet.coverageGapCount || 0) + " coverage gap(s) (inline; 0 dispatched reviewers)");
      }

      phase("aggregate");
      const aggRet = await agent(scanAggregatePrompt(),
        { model: "haiku", phase: "aggregate", label: "scan-aggregate", schema: S.aggScan });
      if (aggRet === null) {
        noteNull("aggregate");
        auditEvents.push({ event: "aggregate_null", ts: nowIso });
        log("aggregate: report.py relay returned null — no report/aggregate path available");
      } else {
        if (typeof aggRet.totalFindings === "number") totalFindings = aggRet.totalFindings; // deduped truth
        reportPath = underRunDir(aggRet.reportPath) ? (aggRet.reportPath || "") : "";
        aggregatePath = underRunDir(aggRet.aggregatePath) ? (aggRet.aggregatePath || "") : "";
        if (aggRet.reportPath && !reportPath) {
          auditEvents.push({ event: "report_path_out_of_run_dir", path: aggRet.reportPath, ts: nowIso });
        }
      }

      // scan issue-filing: the aggregate was built by report.py above.
      phase("issue-filing");
      if (noIssues) {
        log("issue-filing: --no-issues set — report only");
      } else if (aggregatePath) {
        const f2i = await agent(f2iPrompt(aggregatePath, "uberscan-aggregate", 0),
          { agentType: "uberdev:findings-to-issues", phase: "issue-filing", label: "findings-to-issues", schema: S.f2i });
        applyF2i(f2i);
      } else {
        auditEvents.push({ event: "issue_filing_skipped_no_aggregate", ts: nowIso });
        log("issue-filing: no usable aggregate path — skipping issue dispatch");
      }
      return emitResult();
    }

    // ------------------------ simplify: aggregate ------------------------
    // Per-area fixer aggregates run concurrently (each area's dedupe is
    // independent); barrier because the apply phase needs all fixer inputs.
    phase("aggregate");
    const fixerAggThunks = areaIds.map(function (areaId) {
      return function () {
        return agent(fixerAggPrompt(areaId),
          { model: "haiku", phase: "aggregate", label: "fixer-agg-" + pad(areaId), schema: S.aggFixer });
      };
    });
    const fixerAggs = await parallel(fixerAggThunks);
    for (let i = 0; i < fixerAggs.length; i++) if (fixerAggs[i] === null) noteNull("aggregate");

    // ------------------------ simplify: apply + pr ------------------------
    if (!auditOnly) {
      phase("apply");
      const branchRet = await agent(branchSetupPrompt(),
        { model: "haiku", phase: "apply", label: "apply-setup", schema: S.branch });
      if (branchRet === null || branchRet.rc !== 0) {
        auditEvents.push({ event: "branch_setup_failed", rc: branchRet ? branchRet.rc : null, ts: nowIso });
        log("apply: branch setup failed — skipping apply + pr (leftover issues still filed)");
      } else {
        branch = branchName;
        baseBranch = branchRet.baseBranch || "";
        // SEQUENTIAL — NEVER parallel(). Concurrent code-fixer agents race the git
        // index (ubersimplify SKILL.md:461). NO worktree isolation: git forbids
        // two worktrees on one branch, and sequential dispatch already removes the
        // race. One fixer per area, awaited one at a time onto the shared branch.
        for (let i = 0; i < areaIds.length; i++) {
          const areaId = areaIds[i];
          const disp = await agent(applyFixerPrompt(areaId),
            { agentType: "uberdev:code-fixer", phase: "apply", label: "fixer-" + pad(areaId), schema: S.fixer });
          if (disp === null) { noteNull("apply"); continue; }
          if (disp.status === "APPLIED") appliedAreas++;
          else if (disp.status === "REFUSED") refusedAreas++;
          else if (disp.status === "NO_FIXES_NEEDED") noFixesNeededAreas++;
          if (budgetExhausted()) {
            auditEvents.push({ event: "budget_exhausted", phase: "apply", ts: nowIso });
            log("budget exhausted during apply — stopping fixer loop early");
            break;
          }
        }
        log("apply: " + appliedAreas + " area(s) applied, " + refusedAreas + " refused, "
          + noFixesNeededAreas + " no-fixes-needed");

        phase("pr");
        if (appliedAreas > 0) {
          const prRet = await agent(prPrompt(appliedAreas, baseBranch),
            { model: "haiku", phase: "pr", label: "open-pr", schema: S.pr });
          if (prRet === null || prRet.rc !== 0) {
            auditEvents.push({ event: "pr_open_failed", rc: prRet ? prRet.rc : null, ts: nowIso });
            log("pr: open-pr relay failed — branch " + branchName + " retained for manual PR");
          } else {
            prNumber = (typeof prRet.prNumber === "number") ? prRet.prNumber : 0;
            log("pr: opened PR #" + prNumber + " on " + branchName);
          }
        } else {
          // 0 areas applied: the codebase was already clean for these lenses. Tear
          // down the empty temp branch and return to base so the tree is untouched
          // (mirrors ubersimplify-pipeline Phase 4's 0-commit path).
          auditEvents.push({ event: "pr_skipped_no_commits", ts: nowIso });
          log("pr: 0 areas applied — removing the empty temp branch " + branchName);
          await agent(branchCleanupPrompt(baseBranch),
            { model: "haiku", phase: "pr", label: "branch-cleanup", schema: S.branch });
          branch = "";
        }
      }
    } else {
      log("apply/pr: --audit-only — read-only, no branch/fix/PR");
    }

    // -------------------- simplify: leftover issue-filing --------------------
    phase("issue-filing");
    if (noIssues) {
      log("issue-filing: --no-issues set — no leftover issues filed");
      return emitResult();
    }
    const issuesAgg = await agent(simplifyIssuesAggPrompt(),
      { model: "haiku", phase: "issue-filing", label: "simplify-issues-agg", schema: S.issuesAgg });
    if (issuesAgg === null || issuesAgg.rc !== 0) {
      noteNull("issue-filing");
      auditEvents.push({ event: "issues_aggregate_failed", rc: issuesAgg ? issuesAgg.rc : null, ts: nowIso });
      log("issue-filing: leftover-issues aggregate failed — no issues filed");
      return emitResult();
    }
    aggregatePath = underRunDir(issuesAgg.aggregatePath) ? issuesAgg.aggregatePath : "";
    if (!aggregatePath) {
      auditEvents.push({ event: "issue_filing_skipped_no_aggregate", ts: nowIso });
      log("issue-filing: aggregate path outside run dir — skipping issue dispatch");
      return emitResult();
    }
    const f2i = await agent(f2iPrompt(aggregatePath, "ubersimplify-aggregate", prNumber),
      { agentType: "uberdev:findings-to-issues", phase: "issue-filing", label: "findings-to-issues", schema: S.f2i });
    applyF2i(f2i);
    return emitResult();

  } catch (e) {
    auditEvents.push({ event: "run_threw",
      reason: (e && e.message) ? e.message : String(e), ts: nowIso });
    log("scan-fleet threw (" + ((e && e.message) ? e.message : String(e)) + ") — finalizing with results so far");
    return emitResult();
  }
}

function applyF2i(f2i) {
  if (f2i === null) {
    noteNull("issue-filing");
    auditEvents.push({ event: "findings_to_issues_null", ts: nowIso });
    log("issue-filing: findings-to-issues returned null — no issues filed");
    return;
  }
  issues = {
    issuesCreated: Array.isArray(f2i.issuesCreated) ? f2i.issuesCreated : [],
    skipped: (typeof f2i.skipped === "number") ? f2i.skipped : 0,
  };
  log("issue-filing: created " + issues.issuesCreated.length + " issue(s), " + issues.skipped + " skipped");
}

// Final top-level statement: its resolved value is the workflow return value (the
// runtime wraps the body and captures main()'s return; the T3 harness IIFE
// discards it, which is why main() also log()s WORKFLOW_RESULT).
await main();
