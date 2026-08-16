#!/usr/bin/env node
'use strict';
/*
 * tests/_workflow_harness.js — RFC 0012 §4.4 test harness for workflow scripts
 * (T2 meta validation, T3 behavioral dry-run, T4 shared-snippet drift guard).
 *
 * Driven by tests/workflow-scripts.test.sh (the suite entry — T1 lint and the
 * forbidden-token greps live THERE, in shell). This file is a TEST TOOL, not a
 * workflow script: it may use Node APIs (fs, vm) freely. The no-fs/no-Date.now
 * constraints apply to the workflow scripts it validates, never to itself.
 *
 * CLI:
 *   node tests/_workflow_harness.js self-test
 *       Run the embedded harness self-tests. These lock EVERY stub semantic
 *       and the preprocessing step (RFC 0012 §4.4 T3: "non-vacuous before the
 *       first workflow lands") so stub drift and wrapper bugs are caught by
 *       the suite itself even while zero workflow.js files exist on disk.
 *   node tests/_workflow_harness.js validate <file...>
 *       T2 + generic T3 per file: parse/validate the META block, preprocess,
 *       execute under the stub sandbox with a minimal args envelope, fail on
 *       meta-shape errors, phase-discipline violations, forbidden-global
 *       throws, escaped budget throws, or a hung script (timeout).
 *   node tests/_workflow_harness.js shared-drift <file...>
 *       T4: `// === SHARED:<name> v<N> ===` ... `// === END SHARED ===`
 *       blocks with the same name+version must be byte-identical across (and
 *       within) the given scripts.
 *   node tests/_workflow_harness.js meta <file>
 *       Print the parsed meta JSON (utility for other tests / debugging).
 *
 * Exit codes: 0 = all green; 1 = assertion failures; 2 = usage / IO error
 * (including a malformed UBERDEV_HARNESS_TIMEOUT_MS — see the budget block).
 *
 * ENV: UBERDEV_HARNESS_TIMEOUT_MS overrides the per-script/per-case dry-run
 * budget (positive integer milliseconds). It is a HANG detector, not a
 * stopwatch — see the "Dry-run budgets" block below for why that distinction
 * is load-bearing on a contended CI runner.
 *
 * T3 EXECUTION PATH (encoded choice per RFC 0012 §4.4): strip the
 * `export const meta` statement (T2 already parses it from the markers), wrap
 * the remaining body in an async IIFE, and evaluate via vm.runInNewContext.
 * The vm.SourceTextModule alternative is NOT used — it sits behind
 * --experimental-vm-modules, and an experimental runner flag is exactly the
 * unpinned-guard class T1 exists to kill.
 *
 * STUB SEMANTICS (faithful to the documented runtime, RFC 0012 §2.1; every
 * bullet below is locked by a self-test):
 *   - agent(prompt, opts) -> Promise. Canned returns keyed by opts.label,
 *     then opts.agentType, then the fixture default ({}). A canned `null`
 *     models user-skip / terminal API error (the runtime returns null, it
 *     does not reject). With opts.schema the canned return is handed back
 *     parsed (the runtime retries until schema-valid; fixtures supply valid
 *     shapes) and the call is recorded with hasSchema for fixture asserts.
 *   - budget = { total, spent(), remaining() } with total = null (falsy) by
 *     default. When total is set, an agent() call whose cost would go PAST
 *     the ceiling throws (and is NOT recorded as a dispatched call).
 *   - parallel(thunks): barrier (resolves only after every thunk settles),
 *     never rejects, a throwing thunk resolves to null in its slot, order
 *     preserved. NOTE: per the never-rejects contract this swallows budget
 *     throws inside thunks to null too — loop guards must check
 *     budget.total && budget.remaining() (DR-8), not rely on a rejection.
 *   - pipeline(items, ...stages): each item flows through stages
 *     independently — NO inter-stage barrier; stage callbacks receive
 *     (prevResult, originalItem, index); the FIRST stage receives the item
 *     itself as prevResult (harness encoding of the spec); a throwing stage
 *     drops that item to null and skips its remaining stages; the resolved
 *     array stays index-aligned with items.
 *   - phase(title) / log(message): recorders. phase()/opts.phase titles are
 *     matched EXACTLY against meta.phases at run time (mirroring the runtime)
 *     — an undeclared title is a violation that fails validate.
 *   - Date.now() / Math.random() / argless new Date(): sandbox shadows that
 *     THROW exactly like the runtime (resume determinism). new Date(value)
 *     WITH arguments stays usable.
 *   - args: the fixture's JSON, verbatim (deep-cloned per run).
 *   - workflow(nameOr{scriptPath}, args): recorder with canned returns keyed
 *     by scriptPath/name. One-level-nesting enforcement is the live runtime's
 *     job; the harness only records. A canned value may be a FUNCTION, called
 *     with the recorded entry (same as agentReturns) — a function that THROWS
 *     is the only way a fixture can make a nested run fail, and the call is
 *     recorded before the value is resolved so it stays visible either way.
 *   - No timers in the sandbox (setTimeout/setInterval absent — constraint 3:
 *     no script-level sleeps). A script that references them fails at call
 *     time with a ReferenceError, which fails validate.
 *
 * FIXTURE DISCIPLINE (RFC 0012 §4.4): any secret-shaped fixture token must be
 * assembled at runtime by string concatenation, never contiguous source
 * bytes — the finish-branch pre-push scanner hard-aborts on them.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const META_BEGIN = '/* META-BEGIN */';
const META_END = '/* META-END */';
const SHARED_BEGIN_RE = /^[ \t]*\/\/ === SHARED:([A-Za-z0-9._-]+) v([0-9]+) ===[ \t]*$/;
const SHARED_END_RE = /^[ \t]*\/\/ === END SHARED ===[ \t]*$/;

/* ------------------------------------------------------------------ *
 * Dry-run budgets (issue #396)
 * ------------------------------------------------------------------ *
 * Every budget below is a HANG DETECTOR — "does this script ever settle?" —
 * and NEVER a performance assertion. Nothing the harness runs is timed: the
 * self-test scripts do a handful of setImmediate hops, and a migrated
 * workflow.js dry-run only walks its own control flow under stubs. So the only
 * thing a budget must separate is "settles" from "never settles", and sizing
 * it tight buys nothing while costing CI flakes.
 *
 * It cost one: a hard-coded 2000 ms at every self-test call site reddened H11
 * at random on `shape-checks-windows` (#396) — byte-identical harness, no code
 * change between a failing and a passing attempt of the same commit, the whole
 * block 6.3x slower on the failing one with the preceding step taking 24.5 s.
 * A starved runner can stall this process for seconds; that is a fact about
 * the runner, not a defect in the script under test.
 *
 * ONE knob, so a slower host moves every budget together instead of leaving a
 * literal behind. Non-scaling by design: HANG_PROBE_TIMEOUT_MS (H15 asserts a
 * timeout FIRES on a script that never settles — starvation can only delay
 * that, never break it, and a scaled value would just make the suite slower).
 */
const RUN_TIMEOUT_ENV = 'UBERDEV_HARNESS_TIMEOUT_MS';
const DEFAULT_RUN_TIMEOUT_MS = 30000;

// A malformed override is a hard refusal, not a fallback: running the whole
// suite under a budget nobody chose is how a wrong oracle ships (cf. the ARGS
// SHAPE note on the `validate` CLI below).
function resolveRunTimeoutMs(env) {
  const raw = env[RUN_TIMEOUT_ENV];
  if (raw === undefined || String(raw).trim() === '') return DEFAULT_RUN_TIMEOUT_MS;
  const parsed = Number(String(raw).trim());
  if (!Number.isInteger(parsed) || parsed <= 0) {
    console.error(
      `FATAL: ${RUN_TIMEOUT_ENV}="${raw}" is not a positive integer number of milliseconds. `
      + `Unset it to use the ${DEFAULT_RUN_TIMEOUT_MS} ms default.`);
    process.exit(2);
  }
  return parsed;
}

// Per-script/per-case dry-run budget (T3 `validate` and every self-test case).
const RUN_TIMEOUT_MS = resolveRunTimeoutMs(process.env);
// H15 only: the script under test awaits forever, so this fires on any runner.
const HANG_PROBE_TIMEOUT_MS = 300;
// Ceiling on the wall-clock interleaving probes in the gated cases (H7/H8).
// Strictly below RUN_TIMEOUT_MS so a probe can never outlive the run it
// observes, at any override value.
const GATE_PROBE_TIMEOUT_MS = Math.max(1, Math.floor(RUN_TIMEOUT_MS / 3));
const GATE_POLL_INTERVAL_MS = 10;
// H7's "has it settled yet?" nudge. Not a race: the gate is still held, so a
// settle within this window would be a genuine barrier defect.
const SETTLE_PROBE_MS = 50;

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

function clone(value) {
  if (value === null || value === undefined) return value;
  if (typeof value !== 'object') return value;
  return JSON.parse(JSON.stringify(value));
}

/* ------------------------------------------------------------------ *
 * T2 — meta extraction + validation
 * ------------------------------------------------------------------ */

// Returns { meta, metaText, error }. error is a human-readable string with a
// clear remediation (RFC 0012 §4.4 T2: "enforced via clear T2 error messages").
function extractMeta(source) {
  const beginIdx = source.indexOf(META_BEGIN);
  if (beginIdx === -1) {
    return { error: `missing ${META_BEGIN} marker — the meta export must sit between ${META_BEGIN} and ${META_END}` };
  }
  if (source.indexOf(META_BEGIN, beginIdx + META_BEGIN.length) !== -1) {
    return { error: `more than one ${META_BEGIN} marker — exactly one meta block is allowed` };
  }
  const endIdx = source.indexOf(META_END);
  if (endIdx === -1) {
    return { error: `missing ${META_END} marker` };
  }
  if (source.indexOf(META_END, endIdx + META_END.length) !== -1) {
    return { error: `more than one ${META_END} marker — exactly one meta block is allowed` };
  }
  if (endIdx < beginIdx) {
    return { error: `${META_END} appears before ${META_BEGIN}` };
  }
  const region = source.slice(beginIdx + META_BEGIN.length, endIdx);
  const m = region.match(/^\s*export\s+const\s+meta\s*=\s*([\s\S]*?);?\s*$/);
  if (!m) {
    return { error: `the META region must contain exactly one statement of the form: export const meta = <pure JSON literal>;` };
  }
  let meta;
  try {
    meta = JSON.parse(m[1]);
  } catch (e) {
    return { error: `meta is not a PURE JSON literal (JSON.parse: ${e.message}) — no identifiers, comments, trailing commas, or computed values are allowed between the META markers` };
  }
  return { meta, metaText: m[1] };
}

// Returns [] when valid, else a list of error strings.
function validateMetaShape(meta) {
  const errors = [];
  if (meta === null || typeof meta !== 'object' || Array.isArray(meta)) {
    return ['meta must be a JSON object literal'];
  }
  if (typeof meta.name !== 'string' || meta.name.length === 0) {
    errors.push('meta.name must be a non-empty string');
  }
  if (typeof meta.description !== 'string' || meta.description.length === 0) {
    errors.push('meta.description must be a non-empty string');
  }
  if (!Array.isArray(meta.phases)) {
    errors.push('meta.phases must be an array of phase-title strings');
  } else {
    meta.phases.forEach((p, i) => {
      if (typeof p !== 'string' || p.length === 0) {
        errors.push(`meta.phases[${i}] must be a non-empty string`);
      }
    });
  }
  if (hasOwn(meta, 'whenToUse') && typeof meta.whenToUse !== 'string') {
    errors.push('meta.whenToUse, when present, must be a string');
  }
  const allowed = ['name', 'description', 'phases', 'whenToUse'];
  for (const key of Object.keys(meta)) {
    if (!allowed.includes(key)) {
      errors.push(`meta has unknown key "${key}" — allowed keys: ${allowed.join(', ')}`);
    }
  }
  return errors;
}

// Static scan: every phase("...") / phase: "..." STRING LITERAL in the body
// (meta region excluded) must be declared in meta.phases. Dynamic titles
// (template interpolation, variables) are invisible to this scan; the T3
// runtime recorder catches those when the script actually runs.
function scanPhaseLiterals(body) {
  const found = [];
  const callRe = /(^|[^.\w$])phase\s*\(\s*(['"`])((?:\\.|(?!\2)[^\\])*)\2\s*[,)]/g;
  const propRe = /(^|[^.\w$])phase\s*:\s*(['"`])((?:\\.|(?!\2)[^\\])*)\2/g;
  let m;
  while ((m = callRe.exec(body)) !== null) {
    if (!m[3].includes('${')) found.push(m[3]);
  }
  while ((m = propRe.exec(body)) !== null) {
    if (!m[3].includes('${')) found.push(m[3]);
  }
  return found;
}

/* ------------------------------------------------------------------ *
 * T3 — preprocessing + sandbox + execution
 * ------------------------------------------------------------------ */

// Strip the meta block (markers inclusive), refuse leftover export
// statements, wrap the body in an async IIFE. Returns { wrapped, error }.
function preprocess(source) {
  const beginIdx = source.indexOf(META_BEGIN);
  const endIdx = source.indexOf(META_END);
  if (beginIdx === -1 || endIdx === -1 || endIdx < beginIdx) {
    return { error: 'cannot preprocess: META markers missing or out of order (run the T2 checks first)' };
  }
  const body = source.slice(0, beginIdx) + source.slice(endIdx + META_END.length);
  if (/^[ \t]*export\s/m.test(body)) {
    return { error: 'leftover export statement after stripping the meta block — workflow scripts export ONLY the meta literal between the META markers' };
  }
  // NOTE: the wrapper adds exactly one line above the body — stack-trace line
  // numbers from the vm are offset by 1 relative to the original file.
  const wrapped = '(async () => { "use strict";\n' + body + '\n})()';
  return { wrapped };
}

function makeThrowingDate() {
  return new Proxy(Date, {
    construct(target, argList, newTarget) {
      if (argList.length === 0) {
        throw new Error('new Date() without arguments is forbidden in workflow scripts — wall-clock time arrives via args (now_epoch / now_iso); mid-run wall-clock gates use agent-side `date` (RFC 0012 DR-7)');
      }
      return Reflect.construct(target, argList, newTarget);
    },
    get(target, prop, receiver) {
      if (prop === 'now') {
        return () => {
          throw new Error('Date.now() is forbidden in workflow scripts — wall-clock time arrives via args (now_epoch / now_iso); mid-run wall-clock gates use agent-side `date` (RFC 0012 DR-7)');
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  });
}

function makeThrowingMath() {
  return new Proxy(Math, {
    get(target, prop, receiver) {
      if (prop === 'random') {
        return () => {
          throw new Error('Math.random() is forbidden in workflow scripts (resume determinism) — derive run-scoped uniqueness from args.run_id');
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  });
}

function makeRecord() {
  return {
    agentCalls: [],
    budgetThrows: 0,
    phaseThrows: 0,
    parallelCalls: [],
    pipelineCalls: [],
    pipelineDrops: [],
    phases: [],
    currentPhase: null,
    logs: [],
    consoleLines: [],
    workflowCalls: [],
    violations: [],
  };
}

// fixture = {
//   args?: object,                  // verbatim workflow args
//   budgetTotal?: number|null,      // default null (falsy) per §4.4
//   agentCost?: number,             // default 1 budget unit per agent() call
//   agentReturns?: { [labelOrAgentType]: any | (entry) => any },
//   defaultAgentReturn?: any,       // default {}
//   agentGate?: (entry) => Promise|null,   // self-test interleaving control
//   workflowReturns?: { [scriptPathOrName]: any | (entry) => any },
//   phaseThrows?: string,           // default-off; phase(<this exact title>) throws
// }
//
// phaseThrows is the ONLY lever that reaches a script's run-level catch. Every
// other seam is infallible on the whole-run path — parallel() maps a throwing
// thunk to null and never rejects, pipeline() drops the item to null, and
// agent() throws only on a budget ceiling the caller usually catches — so a
// script's outer `catch (e)` is otherwise structurally untestable, and the
// finalization it performs (audit rows, claim downgrades) cannot be pinned.
// Default-off, and equality on the title rather than "any phase", so an
// existing fixture cannot acquire a throw by adding a phase. Deliberately not
// a general fault-injection framework: one opt-in equality check, no per-call
// counters, no throw-on-Nth — generalise when a second caller exists.
function makeSandbox(fixture, meta, record) {
  const budgetState = {
    total: hasOwn(fixture, 'budgetTotal') ? fixture.budgetTotal : null,
    spent: 0,
  };

  async function agentStub(prompt, opts) {
    opts = opts || {};
    const entry = {
      prompt,
      label: typeof opts.label === 'string' ? opts.label : null,
      agentType: typeof opts.agentType === 'string' ? opts.agentType : null,
      phase: typeof opts.phase === 'string' ? opts.phase : record.currentPhase,
      hasSchema: opts.schema !== undefined && opts.schema !== null,
      model: typeof opts.model === 'string' ? opts.model : null,
    };
    if (typeof prompt !== 'string' || prompt.length === 0) {
      record.violations.push('agent() called with a non-string or empty prompt');
    }
    if (meta && typeof opts.phase === 'string' && !meta.phases.includes(opts.phase)) {
      record.violations.push(`agent() opts.phase "${opts.phase}" is not declared in meta.phases`);
    }
    const cost = hasOwn(fixture, 'agentCost') ? fixture.agentCost : 1;
    if (budgetState.total && budgetState.spent + cost > budgetState.total) {
      record.budgetThrows += 1;
      const err = new Error(`workflow budget exceeded: spent ${budgetState.spent} + cost ${cost} > total ${budgetState.total}`);
      err.workflowBudgetExceeded = true;
      throw err;
    }
    budgetState.spent += cost;
    record.agentCalls.push(entry);
    // Real async hop so barrier / no-barrier semantics are exercised on a
    // genuine tick, not resolved synchronously.
    await new Promise((resolve) => setImmediate(resolve));
    if (typeof fixture.agentGate === 'function') {
      const gate = fixture.agentGate(entry);
      if (gate) await gate;
    }
    let ret;
    if (entry.label !== null && fixture.agentReturns && hasOwn(fixture.agentReturns, entry.label)) {
      ret = fixture.agentReturns[entry.label];
    } else if (entry.agentType !== null && fixture.agentReturns && hasOwn(fixture.agentReturns, entry.agentType)) {
      ret = fixture.agentReturns[entry.agentType];
    } else if (hasOwn(fixture, 'defaultAgentReturn')) {
      ret = fixture.defaultAgentReturn;
    } else {
      ret = {};
    }
    if (typeof ret === 'function') ret = ret(entry);
    return clone(ret);
  }

  async function parallelStub(thunks) {
    if (!Array.isArray(thunks)) {
      record.violations.push('parallel() called with a non-array');
      return [];
    }
    record.parallelCalls.push(thunks.length);
    // Promise.all over throw-swallowing wrappers = barrier + never rejects +
    // throwing thunk -> null in its slot, order preserved.
    return Promise.all(
      thunks.map(async (thunk) => {
        if (typeof thunk !== 'function') {
          record.violations.push('parallel() received a non-thunk element');
          return null;
        }
        try {
          return await thunk();
        } catch (e) {
          return null;
        }
      })
    );
  }

  async function pipelineStub(items, ...stages) {
    if (!Array.isArray(items)) {
      record.violations.push('pipeline() called with a non-array items argument');
      return [];
    }
    record.pipelineCalls.push({ items: items.length, stages: stages.length });
    // Each item maps to its OWN stage chain — no inter-stage barrier.
    return Promise.all(
      items.map(async (item, index) => {
        let prev = item; // first stage receives the item itself as prevResult
        for (const stage of stages) {
          try {
            prev = await stage(prev, item, index);
          } catch (e) {
            record.pipelineDrops.push({ index });
            return null; // item drops to null; remaining stages skipped
          }
        }
        return prev;
      })
    );
  }

  function phaseStub(title) {
    record.phases.push(title);
    if (typeof title !== 'string' || title.length === 0) {
      record.violations.push('phase() called with a non-string or empty title');
      record.currentPhase = null;
      return;
    }
    record.currentPhase = title;
    if (meta && !meta.phases.includes(title)) {
      record.violations.push(`phase("${title}") is not declared in meta.phases`);
    }
    // Opt-in seam throw — LAST, so the phase record, the current-phase update
    // and any declaration violation all survive the throw and stay assertable.
    // The malformed-title early return above stays ahead of it: a non-string
    // or empty title must never reach the lever.
    if (hasOwn(fixture, 'phaseThrows') && fixture.phaseThrows === title) {
      record.phaseThrows += 1;
      throw new Error(`fixture: phase("${title}") threw (harness phaseThrows lever — models a mid-run failure reaching the script's run-level catch)`);
    }
  }

  function logStub(message) {
    record.logs.push(String(message));
  }

  const budget = {
    total: budgetState.total,
    spent: () => budgetState.spent,
    remaining: () => (budgetState.total == null ? Infinity : Math.max(0, budgetState.total - budgetState.spent)),
  };

  async function workflowStub(nameOrObj, args) {
    // Recorded BEFORE the value is resolved: a fixture whose value throws must
    // still leave the call visible, or every call-count assertion in the
    // suites that drive this stub becomes conditional on the nested run
    // succeeding.
    const entry = { ref: clone(nameOrObj), args: clone(args) };
    record.workflowCalls.push(entry);
    const key = nameOrObj && typeof nameOrObj === 'object' ? nameOrObj.scriptPath : nameOrObj;
    if (key != null && fixture.workflowReturns && hasOwn(fixture.workflowReturns, key)) {
      let ret = fixture.workflowReturns[key];
      // Symmetric with agentStub above: a function value is resolved per call,
      // so a fixture can vary the return by entry — or THROW, which is the only
      // way to drive a caller's catch arm. Before this, clone() handed a
      // function back to the script verbatim (non-object => returned as-is),
      // so a nested run could never fail and every catch arm was dead code.
      if (typeof ret === 'function') ret = ret(entry);
      return clone(ret);
    }
    return {};
  }

  const consoleStub = {
    log: (...a) => record.consoleLines.push(a.join(' ')),
    warn: (...a) => record.consoleLines.push(a.join(' ')),
    error: (...a) => record.consoleLines.push(a.join(' ')),
    info: (...a) => record.consoleLines.push(a.join(' ')),
  };

  const sandbox = {
    args: clone(hasOwn(fixture, 'args') ? fixture.args : {}),
    agent: agentStub,
    parallel: parallelStub,
    pipeline: pipelineStub,
    phase: phaseStub,
    log: logStub,
    budget,
    workflow: workflowStub,
    Date: makeThrowingDate(),
    Math: makeThrowingMath(),
    console: consoleStub,
    // Deliberately ABSENT: setTimeout/setInterval/setImmediate/queueMicrotask
    // (no script-level sleeps/timers — RFC 0012 §2.2 constraint 3), fs,
    // process, require, fetch (no Node/network API in the script itself).
  };
  return { sandbox, budgetState };
}

// Execute preprocessed source. Returns { result } or { error }.
async function executeWrapped(wrapped, sandbox, filename, timeoutMs) {
  let pending;
  try {
    // vm.runInNewContext is THE encoded execution path (RFC 0012 §4.4 T3);
    // it contextifies the stub sandbox, compiles and runs in one step. A
    // compile (Syntax) error surfaces here too — same catch. The timeout
    // option only bounds SYNCHRONOUS execution; the Promise.race below
    // bounds the async run.
    pending = vm.runInNewContext(wrapped, sandbox, { filename, timeout: timeoutMs });
  } catch (e) {
    return { error: `threw synchronously: ${e.message}` };
  }
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`dry-run timed out after ${timeoutMs}ms (hung await? scripts must not poll/sleep)`)), timeoutMs);
  });
  try {
    const result = await Promise.race([Promise.resolve(pending), timeout]);
    return { result };
  } catch (e) {
    return { error: e && e.message ? e.message : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

// Full T2+T3 pass over one script source. Returns { errors, record, meta }.
async function runScript(source, fixture, label, timeoutMs) {
  const errors = [];
  const extracted = extractMeta(source);
  if (extracted.error) {
    return { errors: [`[T2] ${extracted.error}`], record: makeRecord(), meta: null };
  }
  const meta = extracted.meta;
  for (const e of validateMetaShape(meta)) errors.push(`[T2] ${e}`);
  if (errors.length > 0) {
    return { errors, record: makeRecord(), meta };
  }

  const pre = preprocess(source);
  if (pre.error) {
    errors.push(`[T3] ${pre.error}`);
    return { errors, record: makeRecord(), meta };
  }

  // Static phase-literal discipline (meta region excluded from the scan).
  const beginIdx = source.indexOf(META_BEGIN);
  const endIdx = source.indexOf(META_END);
  const body = source.slice(0, beginIdx) + source.slice(endIdx + META_END.length);
  for (const lit of scanPhaseLiterals(body)) {
    if (!meta.phases.includes(lit)) {
      errors.push(`[T2] phase literal "${lit}" used in the script is not declared in meta.phases`);
    }
  }
  if (errors.length > 0) {
    return { errors, record: makeRecord(), meta };
  }

  const record = makeRecord();
  const { sandbox } = makeSandbox(fixture, meta, record);
  const run = await executeWrapped(pre.wrapped, sandbox, label, timeoutMs || RUN_TIMEOUT_MS);
  if (run.error) {
    errors.push(`[T3] dry-run failed: ${run.error}`);
  }
  for (const v of record.violations) {
    errors.push(`[T3] violation: ${v}`);
  }
  return { errors, record, meta };
}

// Fixture-assert helper for current and future per-pipeline fixtures.
function countAgentsByPhase(record) {
  const counts = {};
  for (const call of record.agentCalls) {
    const key = call.phase == null ? '(none)' : call.phase;
    counts[key] = (counts[key] || 0) + 1;
  }
  return counts;
}

/* ------------------------------------------------------------------ *
 * T4 — shared-snippet drift guard
 * ------------------------------------------------------------------ */

// Returns { blocks: [{name, version, body, file, line}], errors: [] }.
function extractSharedBlocks(source, file) {
  const blocks = [];
  const errors = [];
  const lines = source.split('\n');
  let open = null;
  let bodyLines = [];
  for (let i = 0; i < lines.length; i++) {
    const begin = lines[i].match(SHARED_BEGIN_RE);
    if (begin) {
      if (open) {
        errors.push(`${file}:${i + 1}: SHARED block "${begin[1]}" opens inside unterminated SHARED block "${open.name}" (line ${open.line})`);
        continue;
      }
      open = { name: begin[1], version: begin[2], line: i + 1 };
      bodyLines = [];
      continue;
    }
    if (SHARED_END_RE.test(lines[i])) {
      if (!open) {
        errors.push(`${file}:${i + 1}: END SHARED marker without a matching SHARED begin marker`);
        continue;
      }
      blocks.push({ name: open.name, version: open.version, body: bodyLines.join('\n'), file, line: open.line });
      open = null;
      continue;
    }
    if (open) bodyLines.push(lines[i]);
  }
  if (open) {
    errors.push(`${file}:${open.line}: SHARED block "${open.name}" is never closed with // === END SHARED ===`);
  }
  return { blocks, errors };
}

// fileSources: [{file, source}]. Returns error strings ([] = no drift).
function checkSharedDrift(fileSources) {
  const errors = [];
  const byKey = new Map();
  for (const { file, source } of fileSources) {
    const { blocks, errors: extractErrors } = extractSharedBlocks(source, file);
    errors.push(...extractErrors);
    for (const block of blocks) {
      const key = `${block.name} v${block.version}`;
      if (!byKey.has(key)) byKey.set(key, []);
      byKey.get(key).push(block);
    }
  }
  for (const [key, instances] of byKey) {
    const reference = instances[0];
    for (const other of instances.slice(1)) {
      if (other.body !== reference.body) {
        errors.push(
          `SHARED block ${key} drifted: ${other.file}:${other.line} is not byte-identical to ${reference.file}:${reference.line} — same name+version blocks must be copy-paste identical (bump v<N> if they legitimately diverge)`
        );
      }
    }
  }
  return errors;
}

/* ------------------------------------------------------------------ *
 * Self-tests (RFC 0012 §4.4: lock every stub semantic + preprocessing)
 * ------------------------------------------------------------------ */

// Build fixture sources from line arrays — avoids nested template-literal
// escaping pain and keeps `${` out of the harness's own source where the
// fixtures don't need it.
function src(lines) {
  return lines.join('\n');
}

const VALID_META = [
  '/* META-BEGIN */',
  'export const meta = { "name": "fixture-flow", "description": "harness self-test fixture", "phases": ["Alpha", "Beta"] };',
  '/* META-END */',
];

// Compose the one-line `  FAIL  <desc> — <cause>` row.
//
// The cause MUST ride on the FAIL line ITSELF. tests/workflow-scripts.test.sh
// surfaces a red self-test with `grep '^  FAIL'`, so anything printed on a
// continuation line never reaches the CI log — which is exactly how a silent
// dry-run budget overrun read as "stub drift or wrapper bug" and sent the #396
// investigation the wrong way. Whitespace is folded for the same reason: one
// row, one line, no matter how the cause was formatted.
function failLine(desc, cause) {
  const text = cause === undefined || cause === null
    ? '' : String(cause).replace(/\s+/g, ' ').trim();
  return text === '' ? `  FAIL  ${desc}` : `  FAIL  ${desc} — ${text}`;
}

async function selfTest() {
  let pass = 0;
  let fail = 0;
  // `detail` is a string or a thunk (evaluated only when the row fails).
  const ok = (cond, desc, detail) => {
    if (cond) {
      console.log(`  PASS  ${desc}`);
      pass += 1;
      return;
    }
    console.log(failLine(desc, typeof detail === 'function' ? detail() : detail));
    fail += 1;
  };
  // The standard cause for any row gated on a clean dry-run: name the harness
  // errors, and say so explicitly when there are none (then the row's own
  // predicate is what is false — real stub drift, not an environment stall).
  const why = (errors) => () => (errors && errors.length > 0
    ? `harness errors: ${errors.join(' ; ')}`
    : 'dry-run was clean, so the assertion itself is false (stub drift)');

  /* H1 — meta extraction happy path */
  {
    const { meta, error } = extractMeta(src(VALID_META));
    ok(!error && meta && meta.name === 'fixture-flow', 'H1.1 meta JSON parses from between the META markers');
    ok(!error && Array.isArray(meta.phases) && meta.phases.length === 2, 'H1.2 meta.phases array extracted');
    ok(!error && validateMetaShape(meta).length === 0, 'H1.3 valid meta shape produces zero errors');
  }

  /* H2 — meta negatives */
  {
    ok(!!extractMeta('export const meta = {"name":"x"};').error, 'H2.1 missing META markers is an error');
    ok(!!extractMeta(src(['/* META-BEGIN */', 'const meta = {"name":"x"};', '/* META-END */'])).error,
      'H2.2 META region without the export-const-meta statement is an error');
    ok(!!extractMeta(src(['/* META-BEGIN */', 'export const meta = { name: "x" };', '/* META-END */'])).error,
      'H2.3 non-pure-JSON meta (unquoted key) is an error');
    ok(!!extractMeta(src(['/* META-BEGIN */', 'export const meta = buildMeta();', '/* META-END */'])).error,
      'H2.4 computed meta (function call) is an error');
    const dupe = src(VALID_META) + '\n' + src(VALID_META);
    ok(!!extractMeta(dupe).error, 'H2.5 duplicate META blocks are an error');
    const noPhases = extractMeta(src(['/* META-BEGIN */', 'export const meta = { "name": "x", "description": "y" };', '/* META-END */']));
    ok(!noPhases.error && validateMetaShape(noPhases.meta).some((e) => e.includes('phases')),
      'H2.6 missing meta.phases fails shape validation');
    const unknownKey = extractMeta(src(['/* META-BEGIN */', 'export const meta = { "name": "x", "description": "y", "phases": [], "extra": 1 };', '/* META-END */']));
    ok(!unknownKey.error && validateMetaShape(unknownKey.meta).some((e) => e.includes('unknown key')),
      'H2.7 unknown meta key fails shape validation');
    const badPhase = extractMeta(src(['/* META-BEGIN */', 'export const meta = { "name": "x", "description": "y", "phases": [1] };', '/* META-END */']));
    ok(!badPhase.error && validateMetaShape(badPhase.meta).length > 0,
      'H2.8 non-string phases element fails shape validation');
  }

  /* H3 — static phase-literal discipline */
  {
    const good = src([...VALID_META, 'phase("Alpha");', 'await agent("p", { phase: "Beta" });']);
    const { errors } = await runScript(good, {}, 'h3-good', RUN_TIMEOUT_MS);
    ok(errors.length === 0, 'H3.1 declared phase()/opts.phase literals pass', why(errors));
    const bad = src([...VALID_META, 'phase("Gamma");']);
    const res = await runScript(bad, {}, 'h3-bad', RUN_TIMEOUT_MS);
    ok(res.errors.some((e) => e.includes('"Gamma"')), 'H3.2 undeclared phase() literal fails T2', why(res.errors));
    const badProp = src([...VALID_META, 'await agent("p", { phase: "Delta" });']);
    const resProp = await runScript(badProp, {}, 'h3-badprop', RUN_TIMEOUT_MS);
    ok(resProp.errors.some((e) => e.includes('"Delta"')), 'H3.3 undeclared opts.phase literal fails T2', why(resProp.errors));
  }

  /* H4 — preprocessing */
  {
    const pre = preprocess(src([...VALID_META, 'log("alive");']));
    ok(!pre.error && !pre.wrapped.includes('META-BEGIN') && !pre.wrapped.includes('export const meta'),
      'H4.1 preprocessing strips the meta block (markers + export statement)');
    ok(!pre.error && pre.wrapped.startsWith('(async () => {') && pre.wrapped.endsWith('})()'),
      'H4.2 preprocessing wraps the body in an async IIFE');
    const leftover = preprocess(src([...VALID_META, 'export const other = 1;']));
    ok(!!leftover.error && leftover.error.includes('leftover export'),
      'H4.3 leftover export statement after meta strip is a preprocessing error');
    const { errors, record } = await runScript(src([...VALID_META, 'log("alive");', 'await Promise.resolve(1);']), {}, 'h4-run', RUN_TIMEOUT_MS);
    ok(errors.length === 0 && record.logs.length === 1 && record.logs[0] === 'alive',
      'H4.4 preprocessed body executes in the sandbox (top-level await works inside the IIFE)', why(errors));
  }

  /* H5 — agent() canned returns */
  {
    const fixture = {
      agentReturns: {
        'review-1': { verdict: 'GREEN' },
        'uberdev:code-reviewer': { findings: 2 },
        'skip-me': null,
        // A FUNCTION value: resolved per call with the recorded entry, so a
        // fixture can vary the return by label/agentType/phase instead of
        // pinning one canned object for the whole run. H5.6 locks it — the
        // semantic was live but unasserted, so a rewrite of agentStub could
        // have dropped it and left every suite green.
        'vary-me': (entry) => ({ sawLabel: entry.label }),
      },
      defaultAgentReturn: { fallback: true },
    };
    const script = src([
      ...VALID_META,
      'const byLabel = await agent("p1", { label: "review-1" });',
      'const byType = await agent("p2", { agentType: "uberdev:code-reviewer" });',
      'const skipped = await agent("p3", { label: "skip-me" });',
      'const dflt = await agent("p4", { label: "unknown-label" });',
      'const withSchema = await agent("p5", { label: "review-1", schema: { "type": "object" } });',
      'const dyn = await agent("p6", { label: "vary-me" });',
      'log(JSON.stringify([byLabel, byType, skipped, dflt, dyn]));',
    ]);
    const { errors, record } = await runScript(script, fixture, 'h5', RUN_TIMEOUT_MS);
    const got = errors.length === 0 ? JSON.parse(record.logs[0]) : null;
    ok(errors.length === 0 && got && got[0].verdict === 'GREEN', 'H5.1 canned return keyed by opts.label', why(errors));
    ok(got && got[1].findings === 2, 'H5.2 canned return keyed by opts.agentType', why(errors));
    ok(got && got[2] === null, 'H5.3 canned null models user-skip / terminal API error (resolves null, never rejects)', why(errors));
    ok(got && got[3].fallback === true, 'H5.4 unmatched label falls through to the fixture default', why(errors));
    ok(record.agentCalls.filter((c) => c.hasSchema).length === 1, 'H5.5 schema presence recorded per call', why(errors));
    ok(!!got && !!got[4] && got[4].sawLabel === 'vary-me',
      'H5.6 a function VALUE is resolved per call and receives the recorded entry', why(errors));
  }

  /* H6 — budget semantics */
  {
    const noCeiling = src([
      ...VALID_META,
      'log("total:" + String(budget.total));',
      'for (let i = 0; i < 5; i++) { await agent("p" + i, { label: "any" }); }',
      'log("spent:" + String(budget.spent()));',
    ]);
    const r1 = await runScript(noCeiling, {}, 'h6-null', RUN_TIMEOUT_MS);
    ok(r1.errors.length === 0 && r1.record.logs[0] === 'total:null',
      'H6.1 budget.total is null (falsy) by default — loop guards can check budget.total && budget.remaining()',
      why(r1.errors));
    ok(r1.errors.length === 0 && r1.record.agentCalls.length === 5 && r1.record.logs[1] === 'spent:5',
      'H6.2 no ceiling: agent() never throws, spent() counts costs', why(r1.errors));

    const ceiling = src([
      ...VALID_META,
      'try {',
      '  for (let i = 0; i < 5; i++) { await agent("p" + i, { label: "any" }); }',
      '  log("never-reached");',
      '} catch (e) { log("caught:" + e.message); }',
      'log("remaining:" + String(budget.remaining()));',
    ]);
    const r2 = await runScript(ceiling, { budgetTotal: 2 }, 'h6-cap', RUN_TIMEOUT_MS);
    ok(r2.errors.length === 0 && r2.record.agentCalls.length === 2 && r2.record.budgetThrows === 1,
      'H6.3 with total=2 the third agent() call throws past the ceiling (and is not recorded as dispatched)',
      why(r2.errors));
    ok(r2.errors.length === 0 && r2.record.logs.some((l) => l.startsWith('caught:workflow budget exceeded')),
      'H6.4 the budget throw is catchable inside the script (DR-8 finalize pattern)', why(r2.errors));
    ok(r2.errors.length === 0 && r2.record.logs.includes('remaining:0'),
      'H6.5 budget.remaining() reaches 0 at the ceiling', why(r2.errors));

    const escaped = src([...VALID_META, 'await agent("a", {}); await agent("b", {});']);
    const r3 = await runScript(escaped, { budgetTotal: 1 }, 'h6-escape', RUN_TIMEOUT_MS);
    ok(r3.errors.some((e) => e.includes('budget exceeded')),
      'H6.6 an uncaught budget throw fails the dry-run (the DR-8 violation surfaces)', why(r3.errors));
  }

  /* H7 — parallel(): barrier + thunk-throws-to-null + order */
  {
    let release;
    const gatePromise = new Promise((resolve) => { release = resolve; });
    const fixture = {
      agentReturns: { fast: { id: 'fast' }, slow: { id: 'slow' }, boom: { id: 'boom' } },
      agentGate: (entry) => (entry.label === 'slow' ? gatePromise : null),
    };
    const script = src([
      ...VALID_META,
      'const results = await parallel([',
      '  () => agent("slow prompt", { label: "slow" }),',
      '  () => agent("fast prompt", { label: "fast" }),',
      '  () => { throw new Error("thunk exploded"); },',
      ']);',
      'log("barrier-released");',
      'log(JSON.stringify(results));',
    ]);
    const runPromise = runScript(script, fixture, 'h7', RUN_TIMEOUT_MS);
    // Give the fast thunk time to finish while the slow gate is still held.
    await new Promise((resolve) => setTimeout(resolve, SETTLE_PROBE_MS));
    const fixtureRecordProbe = 'barrier holds: run not settled while one thunk is gated';
    let settledEarly = false;
    const probe = runPromise.then(() => { settledEarly = true; });
    await new Promise((resolve) => setTimeout(resolve, SETTLE_PROBE_MS));
    ok(!settledEarly, `H7.1 ${fixtureRecordProbe}`,
      'the gated run settled before its gate was released (barrier broken, or the run budget expired under it)');
    release();
    const { errors, record } = await runPromise;
    await probe;
    const results = errors.length === 0 ? JSON.parse(record.logs[1]) : null;
    ok(errors.length === 0 && record.logs[0] === 'barrier-released',
      'H7.2 parallel() resolves only after ALL thunks settle (barrier)', why(errors));
    ok(results && results[0].id === 'slow' && results[1].id === 'fast',
      'H7.3 parallel() preserves thunk order in the results array', why(errors));
    ok(results && results[2] === null,
      'H7.4 a throwing thunk resolves to null in its slot (parallel never rejects)', why(errors));
  }

  /* H8 — pipeline(): callback args + drop-to-null + NO inter-stage barrier */
  {
    const argShapes = [];
    let releaseA;
    const gateA = new Promise((resolve) => { releaseA = resolve; });
    const events = [];
    const fixture = {
      agentReturns: {
        'stage1-a': () => { events.push('s1-a'); return { item: 'a', stage: 1 }; },
        'stage1-b': () => { events.push('s1-b'); return { item: 'b', stage: 1 }; },
        'stage2-a': () => { events.push('s2-a'); return { item: 'a', stage: 2 }; },
        'stage2-b': () => { events.push('s2-b'); return { item: 'b', stage: 2 }; },
      },
      agentGate: (entry) => (entry.label === 'stage1-a' ? gateA : null),
    };
    const script = src([
      ...VALID_META,
      'const out = await pipeline(["a", "b"],',
      '  (prev, item, index) => { log("argshape:" + JSON.stringify([prev, item, index])); return agent("s1 " + item, { label: "stage1-" + item }); },',
      '  (prev, item, index) => agent("s2 " + item + " prev " + prev.stage, { label: "stage2-" + item })',
      ');',
      'log("out:" + JSON.stringify(out));',
    ]);
    const runPromise = runScript(script, fixture, 'h8', RUN_TIMEOUT_MS);
    // Item b should clear BOTH stages while item a is still gated in stage 1.
    // Poll (instead of a fixed sleep) so a slow CI runner can't false-FAIL:
    // the gate on stage1-a is held, so 's2-a' CANNOT appear until releaseA().
    // The ceiling is a fraction of the run budget so the probe can never
    // outlive the run it is observing, at any override value (#396).
    {
      const deadline = Date.now() + GATE_PROBE_TIMEOUT_MS;
      while (!events.includes('s2-b') && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, GATE_POLL_INTERVAL_MS));
      }
    }
    const bFinishedFirst = events.includes('s2-b') && !events.includes('s2-a');
    releaseA();
    const { errors, record } = await runPromise;
    ok(errors.length === 0, 'H8.0 pipeline fixture runs clean', why(errors));
    const shapeLog = record.logs.find((l) => l.startsWith('argshape:'));
    ok(!!shapeLog && shapeLog.includes('["a","a",0]'),
      'H8.1 stage callbacks receive (prevResult, originalItem, index); the first stage sees the item as prevResult',
      why(errors));
    ok(bFinishedFirst,
      'H8.2 NO inter-stage barrier: item b reached stage 2 while item a was still in stage 1',
      () => `stage events after ${GATE_PROBE_TIMEOUT_MS}ms: [${events.join(',')}]`);
    const outLog = record.logs.find((l) => l.startsWith('out:'));
    ok(!!outLog && JSON.parse(outLog.slice(4)).length === 2,
      'H8.3 pipeline() returns an array index-aligned with items', why(errors));

    const dropScript = src([
      ...VALID_META,
      'const out = await pipeline([1, 2, 3],',
      '  (prev, item) => { if (item === 2) throw new Error("stage boom"); return item * 10; },',
      '  (prev) => prev + 1',
      ');',
      'log(JSON.stringify(out));',
    ]);
    const dropRun = await runScript(dropScript, {}, 'h8-drop', RUN_TIMEOUT_MS);
    const dropOut = dropRun.errors.length === 0 ? JSON.parse(dropRun.record.logs[0]) : null;
    ok(dropOut && dropOut[0] === 11 && dropOut[1] === null && dropOut[2] === 31,
      'H8.4 a throwing stage drops that item to null and skips its remaining stages (others unaffected)',
      why(dropRun.errors));
    ok(dropRun.record.pipelineDrops.length === 1 && dropRun.record.pipelineDrops[0].index === 1,
      'H8.5 the drop is recorded with the item index', why(dropRun.errors));
  }

  /* H9 — forbidden-global shadows THROW */
  {
    const cases = [
      ['Date.now()', 'const t = Date.now();'],
      ['Math.random()', 'const r = Math.random();'],
      ['argless new Date()', 'const d = new Date();'],
    ];
    for (const [name, line] of cases) {
      const { errors } = await runScript(src([...VALID_META, line]), {}, 'h9', RUN_TIMEOUT_MS);
      ok(errors.some((e) => e.includes('forbidden')), `H9 ${name} throws inside the sandbox`, why(errors));
    }
    const allowed = src([
      ...VALID_META,
      'const d = new Date(1700000000000);',
      'const f = Math.floor(2.7);',
      'log("ok:" + d.getUTCFullYear() + ":" + f);',
    ]);
    const r = await runScript(allowed, {}, 'h9-allowed', RUN_TIMEOUT_MS);
    ok(r.errors.length === 0 && r.record.logs[0] === 'ok:2023:2',
      'H9.4 new Date(value) with arguments and non-random Math statics stay usable', why(r.errors));
  }

  /* H10 — args verbatim */
  {
    const fixture = { args: { v: 1, run_id: 'r-1', config: { areas: 8, nested: { deep: true } } } };
    const script = src([...VALID_META, 'log(JSON.stringify(args));']);
    const { errors, record } = await runScript(script, fixture, 'h10', RUN_TIMEOUT_MS);
    ok(errors.length === 0 && record.logs[0] === JSON.stringify(fixture.args),
      'H10.1 args arrive verbatim (deep-equal round-trip)', why(errors));
  }

  /* H11 — phase/log recorders + per-phase agent counts */
  {
    const script = src([
      ...VALID_META,
      'phase("Alpha");',
      'log("in alpha");',
      'await agent("a1", {});',
      'await agent("a2", {});',
      'phase("Beta");',
      'await agent("b1", {});',
      'await agent("b2", { phase: "Alpha" });',
    ]);
    const { errors, record } = await runScript(script, {}, 'h11', RUN_TIMEOUT_MS);
    ok(errors.length === 0 && record.phases.join(',') === 'Alpha,Beta',
      'H11.1 phase() recorder captures titles in order', why(errors));
    ok(errors.length === 0 && record.logs.join(',') === 'in alpha',
      'H11.2 log() recorder captures messages', why(errors));
    const counts = countAgentsByPhase(record);
    ok(errors.length === 0 && counts.Alpha === 3 && counts.Beta === 1,
      'H11.3 agent-call counts per phase (opts.phase overrides the current phase() group)', why(errors));
  }

  /* H12 — runtime phase discipline catches dynamic titles */
  {
    const script = src([
      ...VALID_META,
      'const dynamic = ["Gam", "ma"].join("");',
      'phase(dynamic);',
    ]);
    const { errors } = await runScript(script, {}, 'h12', RUN_TIMEOUT_MS);
    ok(errors.some((e) => e.includes('not declared in meta.phases')),
      'H12.1 a dynamic phase title not in meta.phases is caught at run time (static scan cannot see it)',
      why(errors));
  }

  /* H13 — T4 shared-block drift guard */
  {
    const blockA = ['// === SHARED:retry v1 ===', 'const RETRIES = 3;', '// === END SHARED ==='].join('\n');
    const blockADrift = ['// === SHARED:retry v1 ===', 'const RETRIES = 4;', '// === END SHARED ==='].join('\n');
    const blockAv2 = ['// === SHARED:retry v2 ===', 'const RETRIES = 4;', '// === END SHARED ==='].join('\n');
    ok(checkSharedDrift([
      { file: 'one.js', source: blockA },
      { file: 'two.js', source: blockA },
    ]).length === 0, 'H13.1 byte-identical SHARED blocks across scripts pass');
    ok(checkSharedDrift([
      { file: 'one.js', source: blockA },
      { file: 'two.js', source: blockADrift },
    ]).some((e) => e.includes('drifted')), 'H13.2 a one-byte drift in a same-name+version SHARED block fails');
    ok(checkSharedDrift([
      { file: 'one.js', source: blockA },
      { file: 'two.js', source: blockAv2 },
    ]).length === 0, 'H13.3 same name with a DIFFERENT version is allowed to differ (bump-the-version escape hatch)');
    ok(checkSharedDrift([
      { file: 'one.js', source: '// === SHARED:retry v1 ===\nconst X = 1;' },
    ]).some((e) => e.includes('never closed')), 'H13.4 an unterminated SHARED block is an error');
    ok(checkSharedDrift([
      { file: 'one.js', source: blockA + '\n' + blockADrift },
    ]).some((e) => e.includes('drifted')), 'H13.5 drift between two instances INSIDE one file is also caught');
  }

  /* H14 — workflow() recorder */
  {
    const fixture = { workflowReturns: { 'skills/x/workflows/child.js': { child: 'ran' } } };
    const script = src([
      ...VALID_META,
      'const a = await workflow({ scriptPath: "skills/x/workflows/child.js" }, { v: 1 });',
      'const b = await workflow("saved-name", {});',
      'log(JSON.stringify([a, b]));',
    ]);
    const { errors, record } = await runScript(script, fixture, 'h14', RUN_TIMEOUT_MS);
    const got = errors.length === 0 ? JSON.parse(record.logs[0]) : null;
    ok(errors.length === 0 && got && got[0].child === 'ran',
      'H14.1 workflow() canned return keyed by scriptPath', why(errors));
    ok(errors.length === 0 && record.workflowCalls.length === 2,
      'H14.2 workflow() calls are recorded', why(errors));
  }

  /* H14 (cont.) — workflow() function values: per-call resolution + the throw seam
   *
   * Before these rows, a function in `workflowReturns` was NOT "ignored" — it
   * was handed to the script RAW (clone() returns any non-object verbatim), so
   * a caller testing `out && typeof out === "object"` silently took its
   * failure path and the run still read as clean. That is the shape of #564:
   * no fixture in this repo could make a nested workflow() call FAIL, so every
   * caller's catch arm was unreachable and its charges/audit events untested.
   */
  {
    const fixture = {
      workflowReturns: {
        'skills/x/workflows/dyn.js': (entry) => ({ echoed: entry.args.v }),
        'skills/x/workflows/boom.js': () => { throw new Error('nested workflow refused'); },
      },
    };
    const script = src([
      ...VALID_META,
      'const dyn = await workflow({ scriptPath: "skills/x/workflows/dyn.js" }, { v: 7 });',
      'let thrown = "no-throw";',
      'try {',
      '  await workflow({ scriptPath: "skills/x/workflows/boom.js" }, { v: 8 });',
      '} catch (e) { thrown = e.message; }',
      'log(JSON.stringify({ dyn: dyn, thrown: thrown }));',
    ]);
    const { errors, record } = await runScript(script, fixture, 'h14-fn', RUN_TIMEOUT_MS);
    const got = errors.length === 0 && record.logs.length > 0 ? JSON.parse(record.logs[0]) : null;
    ok(!!got && !!got.dyn && got.dyn.echoed === 7,
      'H14.3 a function VALUE in workflowReturns is resolved per call and receives the recorded entry (symmetric with agentReturns / H5.6)',
      why(errors));
    ok(!!got && got.thrown === 'nested workflow refused',
      'H14.4 a THROWING function value propagates into the caller await — the only way any fixture in this repo can make a nested workflow() run fail',
      why(errors));
    ok(errors.length === 0 && record.workflowCalls.length === 2
      && record.workflowCalls[1].args && record.workflowCalls[1].args.v === 8,
      'H14.5 the throwing call is still RECORDED — the push happens before the value is resolved, so call-count assertions in the suites that drive this stub stay unconditional',
      why(errors));
  }

  /* H15 — hung script hits the timeout */
  {
    // The one case that keeps a SHORT budget on purpose: the script under test
    // never settles, so the timeout fires however starved the runner is, and
    // scaling it with RUN_TIMEOUT_MS would only make the suite slower (#396).
    const script = src([...VALID_META, 'await new Promise(() => {});']);
    const { errors } = await runScript(script, {}, 'h15', HANG_PROBE_TIMEOUT_MS);
    ok(errors.some((e) => e.includes('timed out')),
      'H15.1 a hung await fails the dry-run with a timeout (scripts must not poll/sleep)', why(errors));
  }

  /* H16 — sandbox has no timers / Node APIs */
  {
    const script = src([...VALID_META, 'setTimeout(() => {}, 10);']);
    const { errors } = await runScript(script, {}, 'h16', RUN_TIMEOUT_MS);
    ok(errors.some((e) => e.includes('setTimeout')),
      'H16.1 setTimeout is absent from the sandbox (constraint 3: no script-level timers)', why(errors));
    const script2 = src([...VALID_META, 'const data = fs.readFileSync("/etc/hosts");']);
    const r2 = await runScript(script2, {}, 'h16-fs', RUN_TIMEOUT_MS);
    ok(r2.errors.some((e) => e.includes('fs')),
      'H16.2 fs is absent from the sandbox (constraint 6: the script cannot touch the filesystem)', why(r2.errors));
  }

  /* H17 — opt-in phase-seam throw lever */
  {
    // The ONLY lever that reaches a workflow's run-level catch: every other
    // seam is modelled infallible on the whole-run path (parallel() maps a
    // throwing thunk to null, pipeline() drops the item, agent() throws only
    // on a budget ceiling the caller usually catches). Without it a script's
    // outer `catch (e)` is structurally untestable. Default-off, equality on
    // the phase title — see the fixture doc block.
    const script = src([...VALID_META, 'phase("Alpha");', 'log("after");']);
    const fired = await runScript(script, { phaseThrows: 'Alpha' }, 'h17', RUN_TIMEOUT_MS);
    ok(fired.errors.some((e) => e.includes('fixture: phase("Alpha") threw')),
      'H17.1 fixture.phaseThrows makes the named phase() throw, surfacing as a dry-run failure',
      why(fired.errors));
    ok(fired.record.phases.includes('Alpha') && fired.record.phaseThrows === 1,
      'H17.2 the phase is recorded and the throw counted BEFORE the throw, so a test can still assert the phase was entered',
      () => `phases: ${JSON.stringify(fired.record.phases)}, phaseThrows: ${String(fired.record.phaseThrows)}`);
    const off = await runScript(script, {}, 'h17-off', RUN_TIMEOUT_MS);
    ok(off.errors.length === 0 && off.record.phaseThrows === 0,
      'H17.3 the lever is default-off with the key absent, and phaseThrows is 0 (a number, never undefined)',
      () => `errors: ${JSON.stringify(off.errors)}, phaseThrows: ${String(off.record.phaseThrows)}`);
    const other = await runScript(script, { phaseThrows: 'Zeta' }, 'h17-other', RUN_TIMEOUT_MS);
    ok(other.errors.length === 0 && other.record.phaseThrows === 0,
      'H17.4 the lever is equality on the title, not "any phase" — a non-matching title never fires',
      () => `errors: ${JSON.stringify(other.errors)}, phaseThrows: ${String(other.record.phaseThrows)}`);
  }

  console.log('');
  console.log('== _workflow_harness self-test summary ==');
  console.log(`  passed: ${pass}`);
  console.log(`  failed: ${fail}`);
  return fail === 0 ? 0 : 1;
}

/* ------------------------------------------------------------------ *
 * CLI
 * ------------------------------------------------------------------ */

// Minimal args envelope for generic `validate` runs (per-pipeline T3 fixtures
// with real canned returns land WITH each migrated-pipeline PR per RFC 0012
// §9; the carrier ships the generic dry-run + the self-tests above).
//
// ARGS SHAPE — this harness got this WRONG and it cost the whole migration.
// It handed `args` to every script as a parsed OBJECT, so the suite stayed
// green while the real runtime handed over a JSON **STRING** and every shipped
// pipeline silently no-opped (probed live 2026-07-31). A test oracle that
// models the runtime incorrectly is worse than no oracle: it certifies the bug.
// `validate` now runs each script under BOTH shapes and requires both to pass,
// so a script that handles only one is a red test.
// Sentinel run_id — the consumption oracle in `validate` requires this exact
// string to appear in a script's observable output, proving it parsed the
// envelope instead of silently falling through to an empty default.
const ARGS_SENTINEL = 'workflow-harness-args-sentinel-7f3a';

const GENERIC_ARGS = {
  v: 1,
  run_id: ARGS_SENTINEL,
  now_epoch: 0,
  now_iso: '1970-01-01T00:00:00Z',
  plugin_root: '/workflow-harness/plugin_root',
  repo_root: '/workflow-harness/repo_root',
  cwd: '/workflow-harness/cwd',
  config: {},
};

function readFileOrExit(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (e) {
    console.error(`FATAL: cannot read ${file}: ${e.message}`);
    process.exit(2);
  }
}

async function main() {
  const [, , command, ...rest] = process.argv;
  if (command === 'self-test') {
    process.exit(await selfTest());
  }
  if (command === 'validate') {
    if (rest.length === 0) {
      console.error('usage: node tests/_workflow_harness.js validate <file...>');
      process.exit(2);
    }
    let failures = 0;
    for (const file of rest) {
      const source = readFileOrExit(file);
      // Both shapes, every script, every run. `string` is what the live runtime
      // actually passes; `object` is what a future runtime (and every existing
      // per-pipeline fixture) may pass. A script must be indifferent.
      const shapes = [
        ['string', JSON.stringify(GENERIC_ARGS)],
        ['object', GENERIC_ARGS],
      ];
      const shapeErrors = [];
      for (const [shapeName, argsValue] of shapes) {
        const { errors, record } = await runScript(
          source, { args: argsValue }, `${path.basename(file)} [args:${shapeName}]`, RUN_TIMEOUT_MS);
        for (const e of errors) shapeErrors.push(`[args:${shapeName}] ${e}`);
        // CONSUMPTION ORACLE — the load-bearing half. Running both shapes is
        // NOT enough on its own: the real failure is a SILENT NO-OP, not a
        // throw, so a script that drops its args still "passes" a
        // dry-run-completes check. (Verified: reverting a script to the
        // object-only guard passed the both-shapes run cleanly.)
        //
        // So require PROOF the envelope was actually read: GENERIC_ARGS carries
        // a sentinel run_id, and every workflow script surfaces its runId in a
        // log line and/or its WORKFLOW_RESULT. If args never parsed, runId is
        // "" and the sentinel cannot appear anywhere in the observable output.
        const observable = JSON.stringify({
          logs: record.logs,
          agentCalls: record.agentCalls.map((c) => ({ label: c.label, prompt: c.prompt })),
          workflowCalls: record.workflowCalls,
        });
        if (observable.indexOf(ARGS_SENTINEL) < 0) {
          shapeErrors.push(
            `[args:${shapeName}] script never surfaced the args sentinel (${ARGS_SENTINEL}) in any log, `
            + `agent prompt or nested workflow call — the envelope was not consumed. The runtime passes `
            + `args as a JSON STRING; a \`typeof args === "object"\` guard drops it and the pipeline `
            + `silently no-ops.`);
        }
      }
      if (shapeErrors.length === 0) {
        console.log(`  PASS  validate ${file} (args as string AND object)`);
      } else {
        failures += 1;
        console.log(`  FAIL  validate ${file}`);
        for (const e of shapeErrors) console.log(`        ${e}`);
      }
    }
    process.exit(failures === 0 ? 0 : 1);
  }
  if (command === 'shared-drift') {
    if (rest.length === 0) {
      console.error('usage: node tests/_workflow_harness.js shared-drift <file...>');
      process.exit(2);
    }
    const fileSources = rest.map((file) => ({ file, source: readFileOrExit(file) }));
    const errors = checkSharedDrift(fileSources);
    if (errors.length === 0) {
      console.log(`  PASS  shared-drift across ${rest.length} file(s): no drift`);
      process.exit(0);
    }
    console.log('  FAIL  shared-drift:');
    for (const e of errors) console.log(`        ${e}`);
    process.exit(1);
  }
  if (command === 'meta') {
    if (rest.length !== 1) {
      console.error('usage: node tests/_workflow_harness.js meta <file>');
      process.exit(2);
    }
    const source = readFileOrExit(rest[0]);
    const { meta, error } = extractMeta(source);
    if (error) {
      console.error(`FAIL: ${error}`);
      process.exit(1);
    }
    const shapeErrors = validateMetaShape(meta);
    if (shapeErrors.length > 0) {
      for (const e of shapeErrors) console.error(`FAIL: ${e}`);
      process.exit(1);
    }
    console.log(JSON.stringify(meta, null, 2));
    process.exit(0);
  }
  console.error('usage: node tests/_workflow_harness.js <self-test|validate|shared-drift|meta> [args]');
  process.exit(2);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`FATAL: harness crashed: ${e && e.stack ? e.stack : e}`);
    process.exit(2);
  });
}

module.exports = {
  extractMeta,
  validateMetaShape,
  scanPhaseLiterals,
  preprocess,
  makeSandbox,
  makeRecord,
  runScript,
  countAgentsByPhase,
  extractSharedBlocks,
  checkSharedDrift,
  failLine,
  // Budget surface (#396): the resolved value is what per-pipeline fixture
  // suites should pass when they need one, so a slow host moves them together.
  RUN_TIMEOUT_MS,
  RUN_TIMEOUT_ENV,
  DEFAULT_RUN_TIMEOUT_MS,
};
