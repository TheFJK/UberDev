# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.42.2] — 2026-07-31

### Fixed

- **Every Workflow-native pipeline silently did nothing.** The runtime hands `args` to a `scriptPath` workflow as a JSON **string**, but all five shipped `workflow.js` scripts opened with `const A = (args && typeof args === "object") ? args : {}` — so the envelope fell through to `{}` and `/ubergoal`, the `/solve`+`/turbo` solver fleet, `/uberscan`, `/ubersimplify`, `/testers` and `/uberthink` all returned **success having dispatched nothing**. A `/ubergoal` run finished in 5 ms with zero agents and an empty journal. Every script now carries a shared normaliser that accepts a string or an object and treats unparseable input as absent.

### Tests

- `tests/_workflow_harness.js` was the reason this survived nine releases: it passed `args` as a parsed **object**, so the suite stayed green while production was dead. It now runs every script under **both** shapes.
- Running both shapes is not sufficient on its own, and that was verified rather than assumed: reverting a script to the object-only guard still **passed** the both-shapes run, because a silent no-op raises no error. So `validate` also requires proof of consumption — `GENERIC_ARGS.run_id` is a sentinel that must appear in the script's observable output. Mutation-verified against all five scripts: restoring the old guard reds each one.
- Added `T2/T3.c1b`, a control fixture that guards with `typeof args === "object"` and must be **rejected**, so the exact shipped bug cannot return.

### Documentation

- RFC 0015 gains §6b, the args-shape contract: what the runtime actually passes, why a silent no-op outlived nine releases, and the three enforcement points.

## [0.42.1] — 2026-07-31

### Fixed

- **`/goal` could not dispatch at all.** `lib/solve_triage.py`'s `--backend=` whitelist was never updated when RFC 0015 added `workflow` to `_UBERDEV_DISPATCH_BACKEND_ENUM`, so an explicit `--backend=workflow` failed `routing_cli_invalid`. That gate is the *first* thing `lib/solve-launcher.sh` runs (`:87`), and `/goal`'s Workflow driver passes exactly that flag — so every `/goal` cycle aborted at dispatch. The default `auto` path was unaffected (`auto` is whitelisted and resolves to `workflow` later, inside `lib/dispatch.sh`), which is why this shipped unnoticed.

### Tests

- `tests/solve-routing.test.sh` now pins `--backend=workflow` in both token orders **and** iterates `_UBERDEV_DISPATCH_BACKEND_ENUM` from `lib/dispatch.sh`, asserting every backend it offers survives `parse-cli`. The two lists can no longer drift silently — which is the actual defect class, not the one missing name.

## [0.42.0] — 2026-07-31

### Changed

- **`/goal` is now a Workflow driver, completing RFC 0015.** `skills/goal-pipeline/SKILL.md` shrinks from 1931 lines to ~155 (preflight, the on-disk script guard, the Workflow mandate, a summary fence and the fallback section); the phase bodies move to `lib/goal-phase0.sh`, `lib/goal-phase1.sh`, `lib/goal-watch.sh` and `lib/goal-phase3.sh`, which the Skill loader never renders — closing the `$ARGUMENTS` positional-substitution hazard that has corrupted awk column refs in this file before.
- The cycle loop lives in `skills/goal-pipeline/workflow.js`, holding the queue, cycle counter and fingerprints in JavaScript variables spanning the whole run. That is what structurally retires the fence-death false-converge and rollover-wipe classes, rather than patching them again. Each cycle makes **exactly one** nested `workflow()` call into the solve-fleet; the fleet still fans out per issue internally.
- **`claude-bg` is now off every default path.** `uberdev_dispatch_demote_workflow_to_detached` — the interim that kept `/goal` on a detached backend — is deleted along with its call site, and the tests that pinned it now assert it cannot come back, in the Codex mirror as well.

### Fixed

- Two blockers the migration itself exposed: the watch loop's own `/merge` and `/review-pr` children would have hit the workflow-backend refusal on **every poll**, so `/goal` could never have merged — they now resolve an explicit, scoped child transport; and the 150-minute detached-solver liveness budget became dead weight against an awaited fleet, so a no-PR issue would have held the watch budget for hours.
- The fleet envelope is cross-checked against the issue set `/goal` actually claimed before any solver is armed, and refuses on mismatch. The launcher runs with `--force`, whose documented purpose is bypassing the claim guard, so without this check a mismatch could have worked an unclaimed issue.
- The post-Workflow summary fence was dead code, gated on a variable that could never be set in that shell; the `bash >= 4` execution contract was documented but never propagated to the relay-run phase scripts; and the watch relay could exceed the Bash tool's default timeout, where the `0/42/1` exit contract cannot survive.

### Tests

- New `tests/goal-workflow.test.sh` (112 assertions): convergence, the watch drain and tick breakers, max-cycles, repeated-fingerprint non-convergence, a non-empty rollover blocking convergence, candidates surviving across cycles, a null child, a budget throw still reaching finalize, exactly one nested call per cycle, and no timers anywhere in the script.
- `tests/goal.test.sh` re-anchored honestly (593 assertions): assertions about behaviour that **moved** now target the new file; the three cases where behaviour was genuinely **replaced** were rewritten to pin the replacement, with a comment saying so.
- Fixed 7 tautological assertions: a stray `--` was consumed as the pattern argument, so they matched any file containing a double dash. Correcting that exposed a second layer — the bare flag tokens also appear in prompt prose — so they now anchor on the armed command line. Every new assertion is mutation-verified.

## [0.41.7] — 2026-07-30

### Fixed

- `/goal`'s verdict channel collapsed six distinct outcomes into one empty result, so **indeterminate discovery and detected tamper both read as "never reviewed"**. Each outcome is now recorded on a run-scoped sidecar (found / absent / indeterminate / tamper / projection-failed / cleanup-failed / selector-unavailable); tamper announces itself loudly, and a proven verdict still publishes when only cleanup fails.
- `/goal` bounded the new anomaly states with their own counter and red-holds with `verdict_indeterminate` / `verdict_tamper_detected` instead of the misleading `dispatch_cap_exhausted`.
- The legacy verdict path read `.sha` with no shape check; it is now validated as a 40-hex object name with a zsh-safe test, and a malformed anchor warns loudly (it is still compared — skipping the binding would let an unbound colour through on a command that auto-merges on green).
- Resolving a helper's source directory fell back to the caller's cwd, so a planted file in that cwd could be sourced. The fallback is removed.
- `/goal` refetched the open-PR list per issue; each pass now takes one snapshot and resolves every issue from it, sharing one ranking program with the live finder. A pass that made progress skips the fixed 60-second sleep — bounded to five consecutive fast passes, because the unbounded form turns a rate-limit warning into a self-inflicted 403 storm.
- **RFC 0015 follow-through:** `workflow` was missing from all four backend sites in `lib/goal-state.sh`. The run-state sidecar allowlist silently *dropped* the value, after which the pid resolver defaulted to a detached backend and a Workflow run could be probed with `claude agents --json` and mis-reaped.

### Added

- `lib/goal-abort.sh` — releases every non-terminal `uberdev:active` claim for a run. Required now that fleet children do not survive their session: a closed window would otherwise strand those labels indefinitely.

### Tests

- New `tests/goal-verdict-receipt.test.sh` (45 cases): the closed-receipt colour matrix through the real locator, `missing` for all sixteen shape-gate clauses, every discovery classification, and forged-sidecar degradation — verified non-vacuous against the pre-change library.
- Sidecar round-trip under `env -i` with cleared environment (an environment-passing test would mask the re-export trap), a zsh mirror of the colour matrix, and lifted `abc123` fixtures to real 40-hex object names.

## [0.41.6] — 2026-07-30

### Fixed

- RFC prose named symbols that resolve nowhere. Two identifiers cited as live fan-out sites were retired by the scan-fleet and testers-pipeline Workflow migrations, and one `workflow.js` was labelled "as shipped" while no such file exists on disk. All now cite the shipped replacements, verified against the real call sites.
- Documentation that hand-enumerated the CI jobs was guarded in only one of the two files that do it, and the job-count assertion could not match the phrasing the docs actually used.

### Tests

- Replaced hand-maintained doc lists with **derived** guards: every identifier-shaped backticked token in RFC 0012 §1 must resolve in the tree, and every `skills/*/workflow.js` path the RFC names must exist if the line calls it shipped — so a new dead reference reds without anyone extending a list. Assertions now match word-bounded, so renaming a symbol no longer counts as resolved, and the trust-table guard slices data rows rather than grepping prose that names the emitter deliberately.

## [0.41.5] — 2026-07-30

### Added

- `/uberdev:status` — a read-only aggregator across the five run-state stores (solve claims, goal state, review reservations, the merge lock, and Workflow fleet runs). It reads and reports; it never mutates, never releases a claim and never breaks a lock.

### Fixed

- Under zsh, `local path=…` binds the **special `path` array tied to `$PATH`**, so `stat` resolved to command-not-found inside the mtime helper and `/status` inverted both of its safety-critical verdicts — reporting a live merge lock as stale and an in-flight review as finished, which would invite an operator to steal the lock and re-dispatch. Five locals renamed; the rule is recorded in the file's cross-shell notes.

### Tests

- The zsh coverage that would have caught this discarded its output and so could not fail on an output regression. Replaced with a bash-vs-zsh **rendered-byte diff** over both live and aged fixtures, normalising only elapsed times so a threshold divergence still reds, plus negative tests proving the shared-root ownership gate actually refuses a foreign-owned file. Every new assertion was mutation-proved.

## [0.41.4] — 2026-07-30

### Fixed

- `/merge` verdict discovery could report a verdict as **proven absent** — which reads as a passing gate — when its root-layout table simply disagreed with itself. The table restated one segment count three ways with nothing checking they agreed; it now carries one shape per root and derives the rest, asserted against a documented pin table and routed through the failure path so a mismatch can never exit with the code reserved for proven absence.
- A `/merge` scan aborted every root layout on the first `OSError`, so an unreadable directory could hide a good verdict under the canonical root. Errors now accumulate per root, every root is scanned, and the run fails once, naming root and errno.
- Artifact identities compared equal to a different type and to any bare 6-tuple, and the public constructor accepted unvalidated receipt JSON. Both are now frozen dataclasses with construction-time domain validation; the receipt wire format is unchanged.
- A mode-0400 verdict copy leaked per non-clean exit: the capture directory was removed with a swallowing `rmdir` that could never succeed, because the publisher had deliberately left a file inside it. Removal is now identity-guarded and a failure names the leaked absolute path instead of hiding it.
- The `/merge` auto-review cap was void — it lived in an associative array inside a bash fence, and fences share no shell state, so the array always read empty and re-dispatch was unbounded **while holding the merge lock**. The cap is now an atomic directory marker claimed before dispatch.
- The branch-protection probe mapped every non-zero exit to "skip". It now classifies on the HTTP status, and — after review found the first fix introduced a *new* fail-open — runs a local upstream-ref check first, so a `404` can no longer read a local-only branch as unprotected.
- An inherited `RUN_ID` was interpolated into the lock record unvalidated; a quote or newline broke the record and the holder check then warn-skipped, leaving the merge lock held.
- A FIFO at any artifact path hung the caller forever: `open()` for reading blocks until a writer appears, and the regularity check can only reject a node it has already opened — so `/merge` wedged while holding the lock. Opens are now non-blocking.

### Tests

- The Phase 1.4 trust gate is now extracted and **executed** against fixtures rather than only grepped, and an assertion that pinned the retired associative-array construct — passing off its own retirement comment — was re-anchored and mutation-proved.
- Added fixtures for a FIFO and a directory at the verdict path, the size boundary, divergent duplicate JSON keys, a root that is a regular file, and errno accumulation; converted 131 `echo | grep -q` sites to herestrings (the EPIPE-race class), fixing one that inverted an empty-input assertion in the process.

## [0.41.3] — 2026-07-30

### Fixed

- Converged four incompatible run-id contracts. `finish-branch` declared a widened format specifically to admit the `nohead` sentinel that `orchestrator` mints from `git rev-parse --short HEAD || echo nohead`; that id passed `finish-branch` and failed every canonical `[a-f0-9]` site, so `command-workspace.py` rejected it as invalid while `finish-branch` happily resolved the same run. The sentinel is now hex and both surfaces use the canonical regex, with tests locking the literals that previously had none.
- `finish-branch` enumerated exactly two secret-scan targets — the push diff and the composed PR body — and never the PR **title**, which it reads and ships to GitHub. The title now goes through the scanner.
- `secret-scan.sh` invoked `gitleaks` with no config, so a repository `.gitleaks.toml` allowlist was silently ignored and there was no escape hatch. The repo config is now honoured, with a line-level allowlist named in the abort message.
- `live-semaphore.sh` validated values with a pipeline that matches **per line** while the caller kept the whole string, so a newline-bearing value could pass validation at three poisonable sites. Each now goes through the file's existing safe-text primitive first.
- Hoisted ~32 duplicate 40-hex SHA patterns in `code_fixer_contract.py` to one compiled constant.

## [0.41.2] — 2026-07-30

### Fixed

- `/review-pr` Phase 3 dispatched the CI failure classifier and code fixer against CI that never failed. The monitor ran `timeout 1200 gh pr checks --watch` in ONE Bash fence, but the Bash tool caps at 600 s — so the harness killed the fence and returned a code that was neither `gh`'s success nor its documented "checks pending", which the next line mapped to "at least one check failed". Replaced with a bounded-pass loop that distinguishes a pass consuming its full budget (still pending) from one that returned early (genuinely red).
- The `sequential` fanout mode was a no-op: `/review-pr` exported its flag in one bash fence and `post-impl-review` read it in a later, separate fence, and Bash tool calls share no shell state. The cap is now passed as a Skill input.
- Abandoned `/review-pr` run reservations had no owner. The `EXIT` trap was replaced by a receipt redeemed only by the final publish fence, all four abandon sites sat inside the setup fence, and no reaper existed — so any mid-run abandonment stalled `/goal` for the full grace period. Added a reaper that runs immediately before reservation, on both the native-Windows and POSIX arms.
- A cleanup failure after publication masqueraded as a publication failure, so callers re-reviewed an already-published verdict. Marker retirement now has its own error path and exit code.
- Hardened five Python helpers that lacked a `spec is None` guard and ran `exec_module` outside their `try`; a `created = True` set after `os.fsync` that skipped rollback on an fsync error and orphaned the run directory; two blanket `except: pass` blocks; and a no-newline receipt that made the run id, receipt and marker directory compare equal so a base64 blob could be exported as the run id.
- Native Windows lost its reservation receipt and markers across a fresh shell, and the ignore tri-state/no-clobber matrix did not hold there.

### Tests

- Replaced a vacuous reaper oracle. Its assertions ran in an `if` condition, where bash suppresses `errexit` for the whole command — and that suppression is inherited by a subshell even when the subshell re-enables it, so `set -e` would not have fixed it either. Every assertion now routes through a helper that exits and names the failure, and both reviewer mutations were re-run to prove the oracle reds.
- Replaced a structural assertion that alternated on `link(`, which matched pre-existing `os.unlink(` lines so a plain truncating write would have passed, and added a non-empty guard before every awk-slice negative assertion (one was vacuous because its slice could be empty).

## [0.41.1] — 2026-07-30

### Changed

- Migrated `/uberthink` off the directive-emitter onto `skills/uberthink-pipeline/workflow.js`, leaving a thin preflight + args seam. The run ledger was designed as a key/value store but implemented as an append-only log, and the write and read paths disagreed about which occurrence of a key was authoritative; orchestration state now lives in JavaScript variables for the whole run, so the disagreement cannot exist.

### Fixed

- The fleet ceiling is live again. Every counter bump matched the FIRST occurrence of `AGENTS_DISPATCHED` — forever the Phase-0 seed of `0` — while every reader took the LAST, so waves of 3+32+2+6 reported 6 against a true total of 43 and `CB-ISLAND` could never halt a runaway genetic loop.
- Tooling crashes are no longer delivered as substance. The Wave-4 and Wave-7 cuts ran under `2>/dev/null || true`, so a module-load failure wrote no shortlist, the falsifier count fell to zero, `CB-CONVERGE` fired, and a ~90-minute run reported "the goal as framed admitted no feasible novel approach". A non-zero report run is now a `TOOLING` halt that can never route to a convergence verdict.
- Wave 5 dispatched against a fabricated composite path: it rebuilt the path from the shortlist *id* (`comp-island-K-NNN`) when the file is named by lens (`comp-NNN-<lens>.yaml`), so it pointed at a file that never exists. It now carries `report.py`'s authoritative `composite_path`, drops unusable rows with a halt rather than inventing one, and names falsifier dossiers by file stem so feasibility sub-scores actually reach the Wave-7 floor cut.
- `/uberthink` could not invoke the tool it now mandates: `allowed-tools` omitted `Workflow`. Added, with the byte-matched alias SSOT row and the assertion the sibling migrations already carry.
- `--resume` silently discarded the entire donor catalogue — cross-domain donor import is the premise of the command — because donors were assigned only on the non-resume branch. Donors now rehydrate from the scope verdict, or the scope gate re-runs.
- A personas relay returning the wrong shape at `rc 0` shipped empty persona blocks into every wave prompt and reported a clean success. The payload is validated before any dispatch, not just the return code.
- `--resume RUN_ID`, `--islands N` and `--max-new N` were documented with a space but only parsed with `=`; the space form fell through and launched a full ideation run on the run id as its goal. Both spellings now parse, and a value-taking flag with no value is a hard error.
- An existing-but-empty composites directory returned an empty design list at `rc 0`, which the preflight's eager `mkdir -p` made reachable; zero artifacts is now a missing input, not an honest frontier.

### Tests

- Added `tests/uberthink-workflow.test.sh` with a real accumulation fixture (3+32+2+6 must reach 43 and trip the ceiling), a report-runner `rc != 0` case asserting a `TOOLING` halt rather than a convergence verdict, resume-with-donors coverage, and persona-payload validation.
- Strengthened two assertions that passed for the wrong reason: the circuit-breaker check was satisfied by the sentence retiring a breaker, and the aggregate-path check matched a literal from an unrelated region. Every new assertion was mutation-proven.

## [0.41.0] — 2026-07-30

### Added

- Workflow-native dispatch for `/solve` and `/turbo` (RFC 0015): a new `workflow` backend runs one worktree-isolated solver agent per issue inside the calling session's Workflow runtime, via `skills/solve-fleet/workflow.js`. Progress is visible with `/workflows` and the run returns a structured per-issue result (`status`, `branch`, `prNumber`, `blocker`) instead of leaving outcome discovery to a separate agent surface.
- Script-orchestrated design phases for medium/large tier: a parallel research fan-out (codebase, constraints, test-coverage) feeding a spec writer, a bounded single-round spec review, and a plan writer, because a Workflow agent is a leaf and cannot fan out for itself.
- Live circuit breakers on the fleet: a projected-agent ceiling that aborts before any dispatch, a token-budget guard between waves, a manifest/claim cross-check that refuses to touch an unclaimed issue, and per-issue fault isolation so one failing issue cannot take the batch down.

### Changed

- `auto` now resolves to `workflow` on every Claude host and every OS class; a Codex session or Codex-only host still resolves to `codex`. The per-OS detached-supervisor matrix (macOS → WezTerm/claude-bg, WSL2/Linux → claude-bg, native Windows → WezTerm) is retired from automatic selection.
- Native Windows no longer hard-errors without WezTerm: the Workflow runtime owns agent lifetimes, so there is no process tree to supervise.
- The fanout cap is a real live concurrency ceiling on the `workflow` backend (waves are barriers), where on the detached backends it only ever chunked the dispatch burst.

### Deprecated

- `--backend=claude-bg`. The transport still works, still passes its full suite, and now prints a one-line deprecation notice when selected; `auto` never picks it. Removal target v1.0.0. `wezterm`, `background` and `codex` remain fully supported explicit choices, and every migrated surface documents a No-Workflow fallback for runtimes without the `Workflow` tool.

### Tests

- Added `tests/solve-fleet-workflow.test.sh`: the shell seam (backend enum, `auto` resolution across all four OS classes, the deprecation notice, the no-provider-arm refusal, launcher Step 5w ordering and args emission), shape greps over the fleet script and its skill, and T3 behavioral fixtures covering tier routing, wave barriers, both circuit breakers, null-agent handling, the manifest cross-check, out-of-run-dir path rejection, and model policy.
- Re-anchored `tests/dispatch-fallback.test.sh` on the new auto contract (auto never selects a detached backend; native Windows resolves rather than refusing; an explicit deprecated backend still resolves, loudly) and updated the enum and Codex-skill-count locks.

## [0.40.3] — 2026-07-28

### Fixed

- Canonicalized review receipts and bound published evidence to validated artifact descriptors and digests.
- Made publication attempts replacement-safe and uniquely identified, with retry behavior safe on native Windows.
- Made Phase 1 aggregation executable without carrying artifact paths across trust boundaries.
- Restricted Phase 3 CI-fixer dispatch to validated scalar inputs bound to the captured PR head.
- Bound final review consumers to immutable local, live, and run-carrier SHAs before lifecycle advancement.
- Bound CI run selection to authoritative pull-request checks and reselected after every head-changing repair.
- Streamed bounded failed-job logs directly into an immutable PR/run/head/digest authority record without mutable staging paths.
- Preserved primary artifact-capture failures and structured cleanup diagnostics when descriptor closure also fails.
- Retired worktree receipts durably with shared atomic, no-overwrite moves so an existing terminal receipt can never be replaced.
- Bound `/review-pr` verdict discovery across the root checkout and three worktree layouts to stable command-line-root identities, one-time secure candidate captures, timestamp-prefix ranking, byte-identical selected ties, and a private digest/identity-recaptured snapshot receipt consumed without later pathname reopens.
- Made unknown verdict identity fail closed according to recency while ignoring known other-PR artifacts, and made strict duplicate-key-safe parsing distinguish exhaustive absence, legacy telemetry, current telemetry, and indeterminate discovery.
- Reused the canonical verdict selector in `/goal`, replacing its duplicate glob/sort/path-read implementation with normalized closed controller state.
- Enforced blocker- and critical-deferred acceptance independently in the trust evaluator, including halted Phase 2.5 results.
- Atomically reserved `/review-pr` run directories with collision-safe generated IDs, carried reservation/marker authority across fresh shells in a closed identity-and-digest receipt, preserved caller-owned `EXIT` traps, and published verdict JSON through the shared exact-name writer without truncating, replacing, or rolling back prior evidence.
- Installed a private ignore policy over `.uberdev/runs/` through the same no-clobber publisher when the repository's effective ignore stack does not already cover it, so review evidence never surfaces as untracked working-tree noise; the probe that detects an already-covered stack no longer aborts setup on its expected not-ignored exit status.
- Kept an already-observed red CI result terminal when the post-monitor metadata refresh is unavailable.
- Bound every routed child handoff to a controller-retained whole-file digest before preflight parsing or dispatch.
- Preserved receipt-authority argv byte-for-byte across Git Bash native-Python launches so raw short-name, case, symlink, and junction aliases remain rejectable, and normalized native descriptor artifact identities, including descriptor link-count portability, without weakening same-handle mutation or replacement detection.
- Added native Codex marketplace metadata and its canonical install selector to generated prkit output, and made the Codex source, manifest, and marketplace contract mandatory generation inputs.
- Made standalone generation fail closed on dirty, ignored, uninspectable, or non-empty non-Git targets; `--force` remains the explicit managed-path replacement override and never bypasses containment or the generation lock.
- Rejected symbolic-link, reparse-point, special, and Windows-reserved managed paths before replacement and during final verification; sealed generated trees before recursive deletion.
- Published copied and rendered files atomically from destination-local temporaries, propagated publication failures instead of accepting stale output, verified executable-mode postconditions, and pinned the generated CI checkout action by immutable SHA.
- Raised the Linux shape-check timeout to 40 minutes after a green 91/0 suite exhausted the 30-minute ceiling, preserving a bounded hang guard with measured hosted-runner headroom.

### Tests

- Added regression coverage for receipt and publication identity, immutable SHA binding, path-free aggregation, authoritative CI-run selection and reselection, direct-stream classifier limits and encoding failures, coherent handoff mutation, fail-closed post-monitor refresh, capture cleanup diagnostics, CI-fixer dispatch, verdict-root retargeting, external root symlinks, strict JSON compatibility/type matrices, timestamp ties, unknown-candidate recency, snapshot drift, atomic run collisions, no-clobber verdict publication, native-Windows retries and stat semantics, prkit Codex marketplace validation, dirty/ignored target preservation, non-Git force semantics, symbolic-link/reparse and special-path containment, Windows reserved names, cooperative locking, immutable CI action pins, atomic publication failures, and the Linux CI timeout budget.
- Exercised durable worktree-receipt retirement natively on Linux, macOS, and Windows.

## [0.40.2] — 2026-07-26

### Fixed

- Pinned Codex-originated review fanouts to the Codex backend, including clean environments without `CODEX_HOME`; explicit backend requests remain visible to governed preflight and are rejected when incompatible rather than silently accepted or rerouted.
- Hardened detached Claude supervision with unattended-permission preflight, exact `claude stop` cancellation, blocked-session terminalization, and exact capacity-lease release.
- Isolated routed runtime state under a private user-owned directory and derived each Codex reviewer worktree and branch from its run-scoped child identity with terminal cleanup.
- Reconciled review `changed_paths` with a traversal-safe repository-relative contract that also supports deleted files.
- Added one canonical machine-readable Phase 1 reviewer result schema to manifest-routed reviewer prompts across the packaged Claude and Codex runtimes.
- Shipped the run-tree policy and reviewer schema in generated prkit Claude and Codex packages so clean installs no longer depend on stale runtime files.
- Kept routed Codex workers leaf-only with the supported `features.multi_agent=false` setting instead of the rejected `agents.max_depth=0` override.
- Scoped routed child allocation identities to each review run so preserved evidence from earlier runs does not reuse the same allocation identity.
- Added manifest-declared caller workspace execution for the five review repair edges so their commits land in the validated review checkout, while other children retain isolated worktrees.
- Scoped Codex child logs to their unique status artifacts and made cleanup failures terminal, observable failures without deleting unsafe evidence.
- Hardened logical repository paths and ownership receipts for native Windows, including fail-closed Git probe errors.
- Kept routed output contracts edge-local instead of promoting them into every native role invocation.
- Rejected malformed CI classifier anchors before routing and kept CI-refusal aggregates inside the command-owned research directory.
- Bounded indeterminate Claude probes, resolved full session IDs before cancellation, and made launch terminalization and exact lease release fail closed with durable supervisory evidence.
- Preserved complete large-PR path sets, rejected Windows drive-relative paths, and restored Python 3.10-compatible standalone PRKit verification.
- Made reviewer-evidence and deferred-findings publication/refusal paths fail closed, preventing malformed or unpublished artifacts from reaching fixers or trust emission.
- Bound review evidence and re-entry snapshots to immutable run-carrier lineage plus current local/remote PR heads, and required validated fixer mutations and disposition artifacts before the lifecycle can advance.

### Tests

- Added a six-child Codex review integration fixture covering backend selection, non-interactive dispatch, unique worktrees, success and failure cleanup, terminal lifecycle receipts, and zero leaked leases.
- Added regressions for Claude idle and ambiguous sessions, nested auto-permission propagation, subdirectory Codex cleanup, cleanup-failure recovery evidence, and large review diffs.
- Added regressions for publication failures and refusals, PR-head drift, carrier lineage, evidence-ledger completeness, and fixer/disposition re-entry gates.

## [0.40.1] — 2026-07-11

### Fixed

- Hardened the live-semaphore CI observer against concurrent mutex generation removal while preserving strict direct-lease counting.

## [0.40.0] — 2026-07-11

### Added

- Adaptive GPT-5.6 routing for Codex with six named routes: Luna economy, Terra standard, and Sol quality/high/max/ultra. Lead work scales by issue tier and risk; high-risk work is promoted to a safe minimum automatically.
- Role-aware fanout routing across research, planning, implementation, review, CI repair, testers, and UberThink. Mechanical and routine tasks use cheaper routes while judgment-heavy work receives Sol; large or high-risk plan writing uses Sol Ultra.
- Project and environment overrides for routing mode, role/workflow routes, reasoning effort, service tier, and policy location, with `.codex/uberdev.local.md` preferred over the Claude fallback.
- A versioned 40-edge run-tree contract with typed child inputs, canonical handoffs, bounded leaf delegation, lifecycle receipts, risk propagation, and format-retry validation.

### Changed

- Brainstorm, orchestrator, subagent-driven development, post-implementation review, `/review-pr`, and `/simplify` now dispatch every provider child through the shared routing runtime.
- Codex dispatch now passes the independently resolved model, reasoning effort, service tier, sandbox ceiling, and leaf-agent limits instead of inheriting one expensive model for every fanout task.
- The plan writer remains a non-delegating leaf and receives tier-aware Sol routing: high for trivial/small, max for medium, and Ultra for large or high-risk plans.
- Codex skills, command-skills, agents, runtime libraries, and policy mirrors are regenerated from the canonical plugin sources.

### Security

- Routed child inputs are validated before handoff; receipt and manifest files use private modes, atomic writes, symlink/hard-link defenses, closed schemas, and payload-free diagnostics.
- Provider invocations outside the routing boundary are denied by CI, while production fanout harnesses verify the real build → handoff → dispatch lifecycle.

## [0.39.1] — 2026-07-08

### Fixed

- `codex/install-codex.sh` now adopts older full UberDev Codex skill installs that predate `.uberdev-codex-managed` markers, upgrades them in place, and installs the missing runtime directory while still refusing partial or user-owned skill collisions.

## [0.39.0] — 2026-07-08

### Added — Codex CLI support (RFC 0012 §3.4 codex-port)

UberDev now installs into the [OpenAI Codex CLI](https://developers.openai.com/codex) — the full toolkit (26 skills, 42 subagents, 13 command-skills, autonomous dispatch) alongside the existing Claude Code delivery. Two install paths ship:

- **`codex/install-codex.sh`** — standalone installer (mirrors `install.sh`): skills → `~/.agents/skills/`, agents → `~/.codex/agents/uberdev-*.toml`, primer merged into `~/.codex/AGENTS.md`. Idempotent + `--uninstall`. This is the path that carries the 42 subagents (the Codex plugin manifest has no `agents` field, so the plugin alone can't ship them).
- **Codex-native plugin + marketplace** — `codex/uberdev-codex/` (`.codex-plugin/plugin.json` bundles skills + session-start hook) + `.agents/plugins/marketplace.json`. Install via `codex plugin marketplace add TheFJK/UberDev` → `/plugins`. Browse-and-toggle UX; pairs with the installer for full functionality.

**Converter tooling** (`codex/tools/`, idempotent, regeneratable from source):
- `convert-agents.py` — Claude `agents/*.md` (YAML frontmatter + body) → Codex `*.toml` (`name`/`description`/`developer_instructions`). Tolerant of Claude's lenient unquoted-scalar-with-colons frontmatter (8 of 42 agents tripped strict YAML). `model: inherit` (41 agents) → omit `model`; `model: haiku` (the lone outlier, `research-test-coverage`) → `gpt-5.4-mini`. Drops Claude-only `color`/`allowed-tools`/`tools`.
- `convert-commands.py` — 13 Claude slash commands → `uberdev-cmd-*` Codex skills (Codex custom prompts are deprecated; skills are the documented shareable replacement). Skips the 2 Claude-only alias commands (`install-aliases`/`uninstall-aliases` — no Codex equivalent).
- `port-skill.sh` — copies the 26 skills ~verbatim with `CLAUDE_PLUGIN_ROOT`→`PLUGIN_ROOT` + `~/.claude/`→`~/.codex/` path fixes. Tool-name bridging (`Task`→`spawn_agent`, etc.) is runtime, via the shipped `references/codex-tools.md`.

**Dispatch backend** — new `codex` arm in `lib/dispatch.sh` (`_uberdev_dispatch_codex`): execs `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>` in a per-issue git worktree, nohup-detached + PID-tracked (mirrors the proven `background` backend — no new liveness mechanism). Auto-selected when `CODEX_HOME` is set or `claude` is absent + `codex` present; overridable via `--backend=codex`. `lib/solve-launcher.sh`'s claude-version gate is now backend-conditional (codex path requires `codex` on PATH instead). `lib/goal-state.sh` liveness polling is backend-aware: the codex/background path uses `kill -0` PID checks instead of `claude agents --json`.

**Hooks** — `hooks/session-start` gained a Codex arm (`CODEX_HOME` → SDK-standard `additionalContext` shape), extending the existing three-way Cursor/Claude/Copilot platform dispatch. The `using-uberdev` primer is distilled into `codex/AGENTS.md` for Codex's global-instruction layer.

**Tests** — `tests/dispatch-codex.test.sh` (22 assertions: enum, probe, preflight auto-resolve, dispatch_one routing, the codex exec mechanism, backend-aware goal-state, solve-launcher gating) + `tests/codex-port.test.sh` (17 assertions: converter round-trips, model-mapping edge cases, command-skill counts, skill-port residuals, installer idempotency + uninstall, manifest validity). Both wired into `.github/workflows/test.yml` (codex-port is ubuntu-only — python3+rsync deps; documented in the windows-skip-list).

### Known limitations (Codex v1)

- The `testers-pipeline` / `scan-fleet` `workflow.js` skills use Claude's `Workflow` tool (no Codex equivalent); Codex bundles the Markdown agent prompts those workflows read, and users still fall back to the skills' `## No-Workflow fallback` path when the Workflow tool is unavailable.
- `uberdev_goal_review_pr_in_flight` uses backend-specific liveness: `claude agents --json` for Claude-backed sessions and PID/status JSON for `background` / `codex` sessions.
- Agent model mapping (`haiku`→`gpt-5.4-mini`) is a 2026-07 snapshot — revisit on each OpenAI model release.
- `codex cloud exec` (async server-side dispatch) is a future enhancement; v1 uses local `codex exec` + `nohup`.

## [0.38.0] — 2026-06-25

### Changed

- **RFC 0012 Phase 3 — `/uberscan` + `/ubersimplify` migrated to the shared `scan-fleet` Workflow** (`skills/scan-fleet/workflow.js`). One `workflow.js` backs both commands via a `mode` (`scan`|`simplify`) branch: it packs the repo into ≤N byte-balanced areas (`lib/chunk.py`), runs ONE multi-lens reviewer per area in concurrency-bounded `parallel()` waves, then for scan runs an inline repo-global Semgrep+coverage pass and `report.py` aggregation, and for simplify runs `aggregate.py`, a sequential `code-fixer` apply (one `refactor:` commit per area on a shared branch — sequential to stay git-index-safe), one PR, and leftover-issue filing. Both pipeline `SKILL.md` bodies are now thin preflight + args-emit + Workflow mandate + `## No-Workflow fallback` seams (≈682/715 → ≈170 lines each). Closes the `/uberscan` + `/ubersimplify` half of #305 (the zsh `ARR=($VAR)` scalar-split wave bug, the fence-scoped circuit-breaker death, and the `$ARGUMENTS` hazards are eliminated by construction — the orchestration is JS, not a directive-emitter bash fence).

### Added

- `skills/scan-fleet/global-pass.sh` — the inline repo-global Semgrep SAST + test-coverage pass, extracted from the legacy `uberscan-pipeline` Phase 1b (reused by both the Workflow relay and the No-Workflow fallback).
- `tests/scan-fleet-workflow.test.sh` — shape greps + a T3 behavioral fixture that drives `scan-fleet.js` under the harness stubs and asserts per-mode phase order, sequential-apply, model policy, CB5/CB7, and the budget-throw (DR-8) path.

### Notes

- The time-based circuit breakers CB3/CB4 (per-wave / wall-clock) are intentionally dropped: they were already dead in the ms-returning directive-emitter fence, and the Workflow runtime forbids `Date.now` (DR-7 determinism); the real `budget` lifetime cap + CB5 (blocker flood) + CB7 (agent ceiling) cover the live failure modes. The simplify apply phase uses sequential dispatch with NO worktree isolation (git forbids two worktrees on one branch; sequential dispatch already removes the index race).

## [0.37.1] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.37.0] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.12] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.11] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.10] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.9] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.8] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.7] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.6] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.5] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.4] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.3] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.2] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.1] — 2026-05-31

### Fixed
- **`/goal` Phase-2 watch loop is now driveable from the Claude Code Bash tool (#299).** Three fixes so `/ubergoal` → `/uberdev:goal` runs end-to-end as-presented:
  - **Bounded / single-tick watch mode (finding 2).** New `--watch-passes=N` / `--watch-budget=SECS` flags (and the `GOAL_SINGLE_TICK=1` env shorthand for one pass) make the Phase-2 watch loop run a bounded number of poll passes (or a per-fence wall-clock budget) and then exit with a documented re-invocation contract instead of the unbounded `while true … sleep` loop that a single 600s-capped Bash-tool call cannot host. Exit codes: `0` = drained (proceed to Phase 3), `42` = still-active (re-invoke Phase 2), `1` = circuit-breaker halt. Each bounded tick persists run-state via `uberdev_goal_write_run_state` and prints current state; the reaper fires only on a breaker or a genuine INT/TERM — **never on a bounded pause**, so live bg solver agents survive between ticks. Default 0 = unbounded (legacy behaviour unchanged). The bound round-trips run-state (new `WATCH_PASSES` / `WATCH_BUDGET` sidecar fields, exported by `uberdev_goal_read_run_state`) so it survives the fresh-shell Phase-2 fences.
  - **Doubled `goal-goal-<id>-` sidecar prefix dropped (finding 3).** `GOAL_ID` is now generated WITHOUT the leading `goal-` (`<epoch>-<rand>` instead of `goal-<epoch>-<rand>`), so the per-goal sidecars are single-`goal-`-prefixed on disk (`goal-<epoch>-<rand>-runstate`, …) instead of `goal-goal-…`. Fixes the debugging foot-gun where `"$TMPDIR"/goal-<id>-*` silently matched nothing. Read/write symmetry preserved (every site shares the `goal-$GOAL_ID-` format string); the id stays digits/dash/alnum so the path-traversal + mis-pathing guards are unaffected.
  - **Cross-shell verdict-locator regression guard (finding 1).** Locks the (already-fixed at HEAD via `_uberdev_goal_glob_worktree`) behaviour that the watch loop's verdict locator + peer glob enumerators return cleanly on zero matches under zsh — a bare unmatched glob fatals `no matches found` under zsh, so a new `tests/goal-state-zsh.test.sh` case (Z10) asserts none of them ever fatal.

## [0.36.0] — 2026-05-30

### Changed
- **`/uberscan` + `/ubersimplify` fan-out is now area-scoped (fixed fleet) instead of per-byte-chunk × N reviewers.** The old model dispatched the 6-reviewer Phase-1 fleet (uberscan) or 3 lens Tasks (ubersimplify) against every ~48 KB chunk, so agent count scaled as `files × fleet`: on this 251-file repo a true whole-repo `/uberscan --all` projected **70 chunks × 6 + 2 = 422 agents**, and the default `MAX_CHUNKS=25` cap didn't shrink the fleet — it silently **truncated coverage** to the alphabetically-first 25/70 chunks (~36% of the tree). There was no path to "audit the whole repo at a sane cost." Now `lib/chunk.py --areas N` (new `pack_areas`) packs **all** in-scope files into **≤ N byte-balanced areas** (default 8, config `uberscan.areas` / `ubersimplify.areas`, range 1-24) via a binary-searched contiguous partition — every file covered exactly once, no overflow-truncation — and **one multi-lens agent reviews each area** (uberscan: a single `code-reviewer` sweeping correctness/silent-failures/type-design/comments/tests; ubersimplify: a single `code-simplifier` running all active lenses). Whole-repo cost drops from **422 → ~8 agents** (uberscan) and **210 → ~8** (ubersimplify), regardless of repo size, and the scan actually covers the whole repo.
- **`/uberscan` repo-global Semgrep + test-coverage passes now run INLINE** (plain `semgrep`/`python3` in Phase 1b) instead of as 2 dispatched `research-*` agents — fail-soft (a missing/erroring Semgrep degrades to a skip note, never aborts the audit).
- **Circuit-breaker recalibration:** CB1 (`MAX_CHUNKS` overflow) is **retired** in area mode (it can never trip — nothing is dropped); CB7 now projects `areas × 1` as a backstop against an absurd explicit `--areas`. New `--areas=N` flag on both commands; `--max-chunks=N` is retained as a legacy alias. The manifest `chunks[]` schema and `chunk-NNN-*.yaml` filenames are unchanged (each entry is now an area), so `report.py` / `aggregate.py` / findings-to-issues are untouched. Design: amendments to `docs/rfc/0007` + `docs/rfc/0008`.

### Tests
- `tests/uberscan-chunk.test.sh` gains 8 area-mode invariants (≤ N areas, every file covered exactly once, deterministic, byte-balanced, fail-loud on `--areas 0`). `tests/uberscan.test.sh` (U7) and `tests/ubersimplify.test.sh` add fixed-fleet shape locks so a regression to the per-chunk × N fan-out turns CI red.

## [0.35.19] — 2026-05-29

### Tests
- **`/goal` orchestration layer gains runtime coverage (#293)** — the `lib/goal-state.sh` layer was densely unit-tested, but **no test executed the `skills/goal-pipeline/SKILL.md` bash fences** (CI only sourced the lib and grepped the markdown), so every orchestration-wiring regression — including the defects fixed in #288/#289/#290/#291/#292/#294 — could ship green. Adds CI-wired `tests/goal-pipeline-zsh.test.sh`, which extracts the SKILL.md `bash` fences and runs the key ones under the real **zsh** Bash-tool shell with `gh` / `claude` / `uberdev_dispatch_one` mocked: Phase-0 arg-parse + the bash≥4 resolver (asserts no spurious `exit 2` under zsh when bash≥4 is present, and `exit 2` when none — the #294 regression guard), the Phase-3 queue-empty convergence calc (#288), and one watch-loop iteration. Replaces the single-line negative-grep `--dry-run` assertion (G17) with a behavioural mocked-dispatch run asserting zero dispatch calls + `exit 0` + no `goal_dispatched` audit row. Wired into `.github/workflows/test.yml` per the `ci-wiring.test.sh` invariant.

## [0.35.18] — 2026-05-29

### Fixed
- **`/goal` advanced PRs on stale reviews (#290.1)** — `uberdev_goal_read_trust_signal` now binds the `/review-pr` verdict to the PR's live `headRefOid` and returns `stale` when a commit landed after the GREEN verdict (fail-safe on a gh outage; backward-compatible when the verdict predates the `.sha` field), instead of driving `pushed-reviewing→green→merging` off a stale review.
- **`/goal` merge-result audit read missed the merge worktree (#290.2)** — `read_merge_result` now scans the worktree-mirror audit set (the same prefix glob the verdict locator uses) instead of cwd-only `.uberdev/audit.jsonl`, so the `merge_failed` breaker fires on the conflict/hook-failed path instead of looping the 60 m timeout.
- **`/goal` rode out sustained gh outages silently (#290.3)** — a consecutive-gh-failure breaker now records failures in `find_pr_for_issue` / `pr_state_gh` and fires `gh_api_failed` via `uberdev_goal_gh_failure_breaker_check`, rather than abandoning a solved-and-pushed issue to the solve-timeout.
- **`/goal` could bind the wrong PR (#290.4)** — `find_pr_for_issue` now scans `--state open` and prefers the `closingIssuesReferences` match over the `feat/N-` head-ref heuristic, so a stale closed branch can't corrupt batch-registry accounting.
- **`/goal` mutual-`Blocks:` deadlock (#292.1)** — new `uberdev_goal_detect_blocks_cycle` SCC detector surfaces `stuck_loop phase=blocks_cycle` instead of spinning two mutually-blocking held PRs to the 4 h cap.
- **`/goal` merge-attempt cap was per-PR-lifetime (#292.2)** — the per-PR cap now resets on a held→green recovery (`uberdev_goal_reset_merge_attempts`), so a PR legitimately blocked for cycles isn't permanently locked out of auto-merge by transient stalls.
- **`/goal` merge barrier deadlocked on a phantom label (#289.1)** — `batch_unblock_wait_clear` now gates on the `uberdev-approved` label `/review-pr` actually emits (the old `review-pr:green` had zero producers, so a held batch row returned rc 1 forever and blocked every co-batched GREEN PR until the 4 h `stuck_loop`); a blocker-closed-but-still-held PR is now pseudo-terminal so it stops gating others.
- **`/goal` didn't serialize version-bump merges (#289.2)** — the green-PR loop now dispatches the lowest green PR and waits (a non-terminal `MERGING` batch-sentinel interlock) for it to land on fresh main before the next `/merge`, so two version-bump PRs can't both land `vN+1` and silently eat the second bump.
- **`/goal` multi-blocker unblock inconsistency (#289.3)** — `batch_unblock_wait_clear` now requires ALL `Blocks:` issues closed (was break-after-first), matching `check_unblock`.
- **Cross-shell worktree-glob hardening (#270 class)** — the `_UBERDEV_GOAL_WORKTREE_PREFIXES` globs never expanded under the zsh Bash tool; all three consumers now route through `_uberdev_goal_glob_worktree` (zsh `${~pat}` + `nonomatch` / bash bare), and loop-body `local` decls are hoisted to function scope.

### Tests
- `tests/goal-batch-barrier.test.sh` (B10–B18), `tests/goal.test.sh` (BT23a–e + repoints), and `tests/goal-state-zsh.test.sh` (Z6–Z9, dual-shell) cover each fix; every fix red-checked via revert. Full `tests/*.test.sh` suite 58/0 under bash and zsh.

## [0.35.17] — 2026-05-29

### Fixed
- **`/goal` was unrunnable out-of-box under the zsh Bash tool (#294)** — the Phase-0 `bash>=4` guard hard-`exit 2`ed whenever `BASH_VERSINFO` was unset, which is *always* the case under the `/bin/zsh` Bash-tool runtime, so `/goal` tripped on its very first fence even on hosts with bash 5.x installed. Phase 0 now **resolves** bash≥4 instead of dead-ending: proceed if already ≥4; else discover a ≥4 binary (`/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `command -v bash` — each version-verified), publish `UBERDEV_GOAL_BASH`, and shebang-gated re-exec the fence under it; only `exit 2` when no bash≥4 exists anywhere. Execution contract documented in `commands/goal.md` + a README Prerequisites row.
- **`/goal` false convergence stranded rollover issues (#288)** — both Phase-3 terminal gates (`goal_converged`, `queue_empty_not_converged`) now also require an empty `queue`, so issues rolled past `--max-parallel` can no longer be reported converged while still OPEN and never dispatched. Adds a cycle-ceiling backstop at the top of Phase 1 (halts `max_cycles` regardless of which fence the orchestrator re-enters) and a per-cycle merge-barrier reset (`barrier_start_ts=0` + batch-PR TSV truncate) so a healthy late cycle no longer spuriously trips `stuck_loop phase=merge_barrier`.
- **`/goal` concurrent double-solve (#291)** — Phase 1 now acquires the cross-process `uberdev:active` claim (label-absent-guarded SETNX, mirroring solve-pipeline) **before** dispatch and releases it on every terminal non-merge transition, closing the gap where `/goal` dispatched `/uberdev:orchestrator` directly and bypassed the claim. The `--only-mine` multi-identity caveat is documented (opt-in, OFF by default; single-identity setups unaffected).

### Tests
- `tests/goal.test.sh` gains G41/G42/G43 (structural + behavioural; the #294 group runs the Phase-0 guard under zsh and asserts no spurious `exit 2`). Verified red-on-old-code; full goal suite green under both bash and zsh.

## [0.35.16] — 2026-05-29

### Fixed
- **Envelope the Phase-2 simplify-lens dispatch diff (prompt-injection — #271 follow-up)** (#286). #271 enveloped the Phase-1 reviewer dispatch + added the untrusted-input stanza to the six agent bodies (incl. `code-simplifier`), but the **Phase-2 simplify-lens dispatch** reused `code-simplifier` at two command-site points that still passed the diff raw: `commands/simplify.md` (`<<diff_brief>>`) and `commands/review-pr.md` Step 6 (`<<base_brief>>`). Both now wrap the diff in `<external-untrusted-input source="pr-diff">…</external-untrusted-input>` (the trusted `## Lens emphasis:` / `## Additional Focus` directives stay OUTSIDE the envelope), completing defense-in-depth across every diff-ingesting agent-dispatch site.

### Tests
- `tests/simplify.test.sh` + `tests/review-pr.test.sh` gain region-scoped open/close-tag asserts (awk-ranged to the Phase-2 lens-dispatch block so the pre-existing `source="post-impl-review-aggregate"` close tag cannot false-PASS) PLUS a literal dispatch-line pin on `prompt: <external-untrusted-input source="pr-diff">` (so a prose-only mention can't false-PASS). Mutation-tested via revert. 60/0 + 135/0.

## [0.35.15] — 2026-05-29

### Fixed
- **`uberthink` report.py — clamp `ambition_score` axes to avoid a complex-number dossier-sort crash** (#277). `ambition_score` applied fractional exponents (`BETA/GAMMA/DELTA = 1.2/1.3/1.2`) to axes that can be negative; in Python a negative base with a fractional exponent returns a `complex` rather than raising, so `round(complex)` raised `TypeError` and `rank()`'s `sorted(key=ambition)` raised `'<' not supported between instances of 'complex' and 'complex'`, aborting the Wave-7 dossier render with no cause-specific message (`feasibility_floor_fails()` cuts only `feas < 4.0`, so a negative `novelty`/`combination`/`impact` from the Arbiter's `ranked.yaml` survived to the exponent). Each axis is now clamped with `max(0.0, float(x))` before the power — a negative axis fails closed to `0` (worse than zero → product `0` → ambition tanks → still a real, sortable float), matching the existing zero-floor semantics; the clamp is identity for in-domain `[0,10]` values.

### Tests
- `tests/uberthink-report.test.sh` gains a negative-axis regression block: asserts `ambition_score` returns a real float (`== 0.0`) for a negative on every axis, that in-domain scores are unchanged, and that `rank()` does not raise on a `ranked.yaml` whose negative axes survive the feasibility floor. Reds pre-fix (`-771.29…`), greens after. 13/0.

## [0.35.14] — 2026-05-29

### Fixed
- **`findings-to-issues` — document the SEARCH-bucket rate-limit guard + drop a tautological test** (#276). The agent's "Refusal triggers" section documented only the **core**-bucket rate-limit guard (`CORE_REMAINING < (2*max_new+50)`) under a stale single `REMAINING` var name, omitting the **SEARCH**-bucket fail-CLOSED condition (`SEARCH_REMAINING < (max_new+5)`) that Process Step 2 mandates (the load-bearing guard against silently mapping dedupe lookups into `blocked_by_dedupe[]` with no issues filed). The section now enumerates BOTH bucket conditions verbatim against Step 2. The Suite-3 "L4 runtime assertion" in `tests/findings-to-issues.test.sh` exercised only the test's own mock `gh()` (a near-tautology); it and its now-orphaned mock scaffolding are removed — the real label-idempotency contract stays locked by the structural L1 assert.

### Tests
- `tests/findings-to-issues.test.sh` Suite 16 (3 section-bounded asserts) locks both bucket conditions in the Refusal-triggers block and asserts the stale bare-`REMAINING` single-bucket form is gone; mutation-tested (each flips to FAIL when the threshold or section is broken). 53/0.

## [0.35.13] — 2026-05-29

### Fixed
- **Test count idioms no longer mask a missing file / tool crash as a passing `0`** (#275). The repo-blacklisted `… | grep -cE … || true` / `… 2>/dev/null || echo 0` idiom collapses three outcomes into one passing `0` — a legitimate zero-count, a missing/unreadable file, and a tool crash. `tests/_lib_assert_structural.sh` `assert_count` (the SSOT helper sourced by 14 test files) now fail-loud-preflights `[ -r "$file" ]` and captures `awk`'s exit status on a separate statement (an `awk` crash FAILs; only `grep` rc ≥ 2 is treated as an error, so a legitimate zero-match on a present file still PASSES). `tests/uberthink.test.sh` (U11) drops the `2>/dev/null || echo 0` mask and adds an explicit `[ -r "$F2I" ]` preflight, restoring the diagnostic that distinguishes a real allow-list regression from brittle-anchor drift.

### Tests
- New `tests/lib-assert-count.test.sh` (5 assertions): present-file count, legitimate zero-count on a present file (over-correction guard), and the bug — a missing file (AC3) + an unreadable file (AC4) with `expected==0` must FAIL loud, not pass vacuously. Reds against the pre-fix helper (2/5), greens after (5/5). Wired **ubuntu-only** (AC4's `chmod 000` is a no-op under Windows Git Bash) and declared in the windows-skip-list marker.

## [0.35.12] — 2026-05-29

### Fixed
- **Cross-platform shell portability — `run-hook.cmd` Windows args + GNU-sed `probe` dependency** (#274). The Windows `cmd.exe` arm of `plugins/uberdev/hooks/run-hook.cmd` forwarded args as bare `%2 %3 … %9` (re-splitting spaced/quoted args, capping at 8 trailing args), asymmetric with the Unix arm's `exec bash … "$@"`; it now uses a `SHIFT`-based `goto` loop accumulating `HOOK_ARGS` with quoting, mirroring the `"$@"` contract (the `: << 'CMDBLOCK'` polyglot heredoc stays balanced under both `bash -n` and `zsh -n`). `tests/manual/probe-prompt-file-slash-expansion.sh` used GNU-sed-only `\x1B` in its ANSI strip (treated literally by BSD/macOS sed → escapes survive → empty `SESSION_ID` → spurious `INDETERMINATE`); replaced with a portable `tr -d '\033'` + POSIX-sed strip.

### Tests
- New `tests/crossplatform-shell-wrappers.test.sh` (21 assertions): structural asserts the broken forms are gone + portable forms present, a POSIX model of the `cmd` SHIFT-loop proving 8/11/spaced-arg forwarding, a `bash -n`/`zsh -n` heredoc-balance check (the `zsh -n` arm self-skips when zsh is absent — Windows-safe), and a platform-independent ANSI-strip regression kernel. Reds pre-fix (8 fails), greens post-fix (21/21). Portable — wired into both CI jobs.

## [0.35.11] — 2026-05-29

### Fixed
- **Docs-accuracy sweep — vendored `testing.md`, stale `CONTRIBUTING`, dead link, RFC 0004 collision** (#273). `plugins/uberdev/docs/testing.md` was verbatim-upstream Superpowers (documented `tests/claude-code/`, `run-skill-tests.sh`, `superpowers@superpowers-dev` — none exist here); rewritten to describe the real `tests/*.test.sh` shape-check harness and the `.github/workflows/test.yml` two-job (ubuntu + windows) matrix, with `uberdev@uberdev` as the marketplace key. `CONTRIBUTING.md` now points at `test.yml` as the test-suite SSOT (dropping the false "no behavioral tests yet" claim and the partial 4-file list) and its dead `[Repo layout](README.md#repo-layout)` link is fixed. The **RFC 0004 number collision** is resolved by renumbering the alias-reliability draft to **RFC 0011** (the dispatch-backends RFC keeps 0004 — shipped code + CHANGELOG cite it), with cross-refs updated in `hooks/session-start`, `lib/aliases-sync.sh`, and the CHANGELOG; the dispatch RFC's internal §4/§5 version refs are corrected to `0.29.0 → 0.30.0`.

### Tests
- New `tests/docs-accuracy.test.sh` (fail-loud on missing inputs; dynamic duplicate-RFC-number detection) guards against re-vendoring `testing.md`, the dead README link, and RFC-number collisions. Portable grep-and-assert — wired into both the ubuntu and windows CI jobs.

## [0.35.10] — 2026-05-29

### Fixed
- **`/review-pr` Phase-3 CI probe — align to the real `gh pr checks` field contract** (#272). `commands/review-pr.md` probed `gh pr checks --json name,status,conclusion`, but `gh` 2.83.1 exposes only `name,state,bucket` (no `status`/`conclusion`) — so against real `gh` the probe errored on unknown fields and Phase-3 silently degraded to the `ci_probe_unreachable` carve-out on every run, never gating real red CI on a to-`main` PR. The probe now reads `--json name,state,bucket` and maps terminal/non-terminal off `state` + `bucket` (red outranks pending). The `tests/_fixtures/fake-gh/gh` stub emits `state`/`bucket` to match.

### Tests
- `tests/review-pr-phase3-ci.test.sh` gains genuine RUNTIME coverage (S15-RUNTIME): prepends the `fake-gh` stub to `PATH`, sets `FAKE_GH_MODE`, runs the real probe, and applies the jq verdict program extracted live from `review-pr.md` (so it cannot drift); a mutation back to the old `status`/`conclusion` shape reds it. Because it now executes the `fake-gh` fixture via `PATH` (committed-`+x` dependency, like `merge-discovery-resilience.test.sh`), it moves to the ubuntu-only CI job and is added to the windows-skip-list marker.

## [0.35.9] — 2026-05-29

### Fixed
- **review-pr reviewer fleet — envelope the attacker-controlled PR diff (prompt-injection defense)** (#271). All six PR-diff reviewer agents (`code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`, `pr-test-analyzer`, `code-simplifier`) ingested the pasted diff inline with no `<external-untrusted-input>` envelope and no "treat as DATA, not instructions" stanza — even though `post-impl-review/SKILL.md` documents the injection chain (issue-author text → diff hunk → reviewer report → aggregate → fixer prompt) and already wrapped only the downstream aggregate→fixer hop. Each agent body now carries the canonical untrusted-input-handling stanza (byte-identical to the research-* agents), and `post-impl-review/SKILL.md` wraps the pasted diff/changed-code (including the >2000-line summarised-diff path) in `<external-untrusted-input source="pr-diff">`. `comment-analyzer` and `pr-test-analyzer` run on `haiku` and were the highest-risk carriers (comment text is a natural injection vector).

### Tests
- `tests/post-impl-review.test.sh` gains 14 assertions locking the untrusted-input stanza heading + verbatim body per agent and the Step-1 envelope open/close around the diff (awk-bounded so the pre-existing reader-side `source="post-impl-review-aggregate"` close tag cannot false-PASS); reverting the envelope reds the suite.

## [0.35.8] — 2026-05-29

### Fixed
- **goal-pipeline / finish-branch — five zsh-runtime bugs under the `/bin/zsh`-backed Bash tool** (#270). The `/goal` and `finish-branch` SKILL.md bash fences execute under zsh on macOS, where bash-only syntax misfires; CI only ran the suite under bash, so the breakage escaped. Fixed in `lib/goal-state.sh`: (1) `_uberdev_goal_parse_blocks_line` now reads `${match[1]:-${BASH_REMATCH[1]}}` (the only `Blocks: #N` parser — held-PR unblock was dead under zsh, so the `/goal` merge barrier could clear prematurely); (2) `uberdev_goal_agent_stuck_on_dialog` renames `local status` (zsh's read-only special parameter, which hard-aborted the function on its first line) and routes `${!var}` indirection through a new `_uberdev_goal_indirect_get` helper branching on the live shell (`${(P)name}` / `${!name}`) using only native parameter expansion — no `eval`/`bash -c` (respecting the file's T3 no-shell-eval rule); (3) `write_run_state` replaces `compgen -v` with `env | grep` enumeration so per-PID stuck-dialog samples persist across fences; (4) a `${BASH_SOURCE[0]:-}` guard for `set -u` zsh callers. In `skills/goal-pipeline/SKILL.md`, `print_summary()` is hoisted out of the Phase-4 fence into `lib/goal-state.sh` — it was called from the Phase-1/2/3 fences but a shell function cannot cross a fence boundary, so every circuit-breaker and the convergence exit hit `command not found` (rc 127) and silently dropped the operator summary line + held-PR post-mortem rows. In `skills/finish-branch/SKILL.md`, the PR number is now `${PR_URL##*/}` on the already-`PR_URL_REGEX`-validated URL (sidesteps the `BASH_REMATCH` capture), restoring the #95 `review-pr:pending` backstop label on finish-branch PRs created on macOS.

### Tests
- New `tests/goal-state-zsh.test.sh` (modeled on `solve-pipeline-zsh.test.sh`) sources `goal-state.sh` under the live shell and asserts the five #270 behaviours plus the two structural must-dos (print_summary hoist; `agent_stuck_on_dialog` free of `read-only`/`bad substitution`); green under both bash and zsh (13/13 each). Wired into the ubuntu CI job under `zsh` (windows-skip — `windows-latest` ships no zsh).

## [0.35.7] — 2026-05-29

### Changed
- **tests — DRY the version-lock assertion block into a shared `assert_version_bump` helper** (#231). The identical four-surface version-propagation asserts duplicated across `tests/goal.test.sh` (G20) and `tests/solve-claim.test.sh` are now a single `assert_version_bump <repo_root> <version>` helper in `tests/_lib_assert_structural.sh`. A release bump is now one `<version>`-arg change per call site instead of lockstep multi-form-regex edits across two files — removing the release footgun that previously required hand-editing plain, single-escaped, and double-escaped regex variants in lockstep.

## [0.35.6] — 2026-05-29

### Changed
- **findings-to-issues — accepted-source allow-list is now a single source of truth** (#198; prevents #182-class drift). Extracted `ACCEPTED_SOURCES` as a `frozenset` in `lib/report_primitives.py`; `envelope()` now asserts `source in ACCEPTED_SOURCES` and raises `ValueError` at emit time, so a typo or a new pipeline shipping an un-accepted source fails loudly **where it is emitted** instead of silently filing ZERO issues (the #182 bug: `testers-aggregate` was emitted by `report.py` but missing from the allow-list, so every `/uberdev:testers` run filed nothing). The agent spec's partial source re-enumeration in `agents/findings-to-issues.md` was collapsed to a pointer at the Step-1 closed set, so the 7 sources are enumerated in exactly one place.

### Tests
- New `tests/findings-to-issues.test.sh` Suite 15 cross-consistency gate: asserts the python `ACCEPTED_SOURCES` frozenset equals the agent-spec closed set, every emitter `envelope()` source literal is a member, and `envelope()` raises on a non-accepted source while accepting a member — so the allow-list and the emitters can no longer silently drift.

## [0.35.5] — 2026-05-29

### Fixed
- **cluster-pipeline — hard-fail (not silent-zero) on a crashed Phase-1/2 producer** (#265). `TOTAL` (issues.json) and `POOL_SIZE` (cluster-pool.json) previously used the `jq 'length' … 2>/dev/null || echo 0` idiom, which maps a crashed/partial/0-byte producer to `0` — indistinguishable from a legitimately-empty run (the same masking class fixed for the Phase-4 dispatch count in #263). Both now use the `[ -s ]` + `type=="array"` fail-closed shape (mirroring the Phase-4 `CLUSTERS_N` gate), aborting with a FATAL diagnostic instead of flooring to 0. A legitimately-empty pool still writes valid `[]` and proceeds normally.
- **cluster-pipeline — Phase-4 YAML aggregation emits stderr diagnostics on silent skips** (#265). The python3 aggregation's `except ImportError` (PyYAML missing → empty set), per-file `except Exception` (unparseable `analyses/*.yaml`), and per-cluster `except (TypeError, ValueError)` (non-numeric confidence) blocks each now write a `cluster: WARN …` line to stderr, so an operator can distinguish "0 clusters" from "PyYAML missing / N files unparseable" — without changing the yaml-optional design intent.

### Tests
- New `tests/cluster-pipeline.test.sh` gates **P20** (issues.json) + **P21** (cluster-pool.json), mirroring the P18 verbatim-fence pattern — each asserts hard-fail (rc≠0 + FATAL on stderr + no DISPATCH/output leak) on missing / 0-byte / non-array inputs and correct counts on valid / empty arrays.

## [0.35.4] — 2026-05-29

### Changed
- **goal-pipeline — hoisted all 8 inline `awk` state-reads into `lib/goal-state.sh` helpers** (#229, #237, #230, #234). The awk one-liners in `skills/goal-pipeline/SKILL.md` previously relied on the `-v c1=1 -v c2=2 -v c3=3` renderer-collision workaround (#222); they are now seven sourced helpers — `uberdev_goal_get_issue_state`, `uberdev_goal_issue_ts_in_state`, `uberdev_goal_pr_ts_in_state`, `uberdev_goal_pr_first_ts_in_state`, `uberdev_goal_batch_has_pr`, `uberdev_goal_count_distinct_prs`, `uberdev_goal_count_resolved_issues` — backed by an internal `_uberdev_goal_ts_in_state`. Because `lib/goal-state.sh` is **sourced, never Skill-rendered**, the helpers use clean, semantic `$1`/`$2`/`$3` field refs the renderer cannot corrupt, and the SKILL.md call sites now carry zero awk. The per-site `$ARGUMENTS`-collision rationale collapses to a single anchor on the first-wins helper.

### Fixed
- **goal-pipeline convergence no longer false-fails on macOS** (#229). `uberdev_goal_count_distinct_prs` returns a clean integer; the prior `… | sort -u | wc -l` form padded with leading spaces under macOS/BSD `wc -l`, and the convergence check compares it with `=` (string equality) against a grep-based terminal count — so the padding could falsely block convergence.
- **goal-pipeline surfaces a failed `/review-pr` re-dispatch** (#219). The `_uberdev_goal_dispatch_review_pr` call site in the held-PR poll loop now emits an rc breadcrumb on a genuine dispatch failure (the intentional cap-reached skip stays silent) instead of swallowing the return code.
- **`/review-pr` conflict-file extraction is renderer-safe** (#237). The executed `awk '/^UU / {print $2}'` in `commands/review-pr.md`'s multi-stage-rebase recovery used a bare `$2` the slash-arg renderer would overwrite with the PR-number argv; parameterised to `-v c2=2 … $c2`. A new `R1b` drift-guard in `tests/skill-renderer-awk-collision.test.sh` scans `commands/*.md` so the shape cannot regress (agent system prompts are excluded — they are not positionally substituted).
- **`requesting-code-review` doc example is renderer-safe** (#232). The illustrative SHA-extraction `awk '{print $1}'` in an Example block is now `cut -d' ' -f1` — no `$N`, reads cleanly, immune to the renderer.

## [0.35.3] — 2026-05-29

### Added
- `/uberdev:cluster` (short alias `/ubercluster`) — repo-wide issue similarity
  analyzer and fold-into-lead consolidator. Reduces /goal multi-issue run cost
  by collapsing semantically duplicate finding-issues before /turbo dispatch.
  Three-layer decomposition: `commands/cluster.md` (thin) →
  `skills/cluster-pipeline/SKILL.md` (6-phase directive-emitter) →
  `agents/issue-similarity-analyzer.md` (read-only, `model: inherit`). Hard `--min-confidence 0.85`
  floor under `--execute`; idempotent via HTML-comment marker + `folded` label
  + per-run JSONL ledger. RFC 0010. Closes #247.
- Consolidated `/uberdev:cluster` behavioral test coverage — gates P13–P19:
  Phase 4 proposal generation + dry-run exit, Phase 5 lead-body fold-append,
  Phase 3.5 cross-chunk meta-pass skip/execute/boundary, the Phase 4 dispatch
  hard-fail gate, and the cluster-render schema-validation gate. Closes #257,
  #258, #259.

### Fixed
- **Phase 4 dispatch hard-fails on unreadable `clusters-filtered.json` (Closes #263).**
  The old `jq 'length' … || echo 0` masked a crashed / zero-byte / malformed /
  non-array Phase-4 aggregation as `CLUSTERS=0`, indistinguishable from a
  legitimate empty run. Now requires a non-empty valid JSON array (`[ -s ]` +
  `type=="array"`) and hard-fails (`exit 2`) otherwise; a genuinely empty run
  still writes `[]` → `CLUSTERS=0` and dispatches normally.
- **`cluster_propose.py` validates every cluster's schema before rendering (gate P19).**
  `render_cluster()` coerces `lead`/`members`/`confidence` via `int()`/`float()`;
  a malformed analyzer cluster previously crashed the render loop *after* the
  report header was printed, leaving a partial `proposals.md` indistinguishable
  from a complete one. `main()` now validates all clusters up front and aborts
  (`exit 2`, no partial stdout) on any schema violation — all-or-nothing.
  Surfaced by `/uberdev:review-pr` (type-design lens).

## [0.35.2] — 2026-05-28

### Changed
- **Recorded won't-fix verdict for #240 dispatch `--prompt-file` probe.** The empirical probe at `tests/manual/probe-prompt-file-slash-expansion.sh` was run 2026-05-28 against claude-code 2.1.153.
  - Probe verdict: `INDETERMINATE`. `--prompt-file` is accepted (session backgrounds successfully), but the file body is not promoted to the session-name surface (unlike argv-mode, where the session name = opening message verbatim). The session went idle without the name field diverging.
  - Decision: the natural-language wrapper introduced by PR #238 at the 5 prompt-build callsites (`skills/goal-pipeline/SKILL.md`, `skills/solve-pipeline/SKILL.md` × 2, `lib/goal-state.sh` × 2) remains canonical. `BG_PROMPT_MODE=argv` stays at `lib/dispatch.sh`.
  - Migration targets: the `file`/`stdin` arms in `_uberdev_dispatch_claude_bg` remain pre-wired for a future CLI revision per RFC 0004 §3.4.

### Added
- `tests/manual/probe-prompt-file-slash-expansion.sh` — manual reproducer for the AC1 empirical probe (writes verdict to `${UBERDEV_TMPDIR:-/tmp}/issue-240-probe-verdict.txt`; not wired into CI).

### Notes
- Version bumped to 0.35.2 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

## [0.35.1] — 2026-05-28

### Fixed
- **`/uberdev:goal` fresh-shell `stuck_loop` misfire on cycle 1 (Closes #245).** The goal-pipeline SKILL.md Phase 0 Constants block declared 13 scalar tunables (e.g. `_UBERDEV_GOAL_STUCK_SECS=14400`, `_UBERDEV_GOAL_POLL_SECS=60`, `_UBERDEV_GOAL_SOLVE_TIMEOUT=9000`, `_UBERDEV_GOAL_BODY_CAP=65536`, `FINDING_LABEL='review-pr-finding'`) and 2 regex constants — but every fresh-shell rehydration fence in Phases 1/2/3/4 sources ONLY `lib/goal-state.sh`, never re-executing the Phase 0 block. The first watch-loop check at SKILL.md:411 — `(( now - watch_start >= _UBERDEV_GOAL_STUCK_SECS ))` — saw an unset variable, bash arithmetic coerced to 0 (POSIX.1-2017 §2.6.4), the comparison reduced to `(( elapsed > 0 ))`, and `stuck_loop` fired on iteration 1 (live repro: `/ubergoal 225 226 227` cycle 1 printed `STUCK_LOOP (4h cap)` with elapsed=0 and all 3 issues still in `solving`).
  - `plugins/uberdev/lib/goal-state.sh` — added 12 defaulted-assignment declarations (`: "${VAR:=default}"`, the same idiom proven on `_UBERDEV_GOAL_STUCK_DIALOG_SECS:=60` from PR #221) for the 10 SKILL.md-declared integer scalars + `FINDING_LABEL` + the latent `_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:=3` (used by `_uberdev_goal_dispatch_review_pr` via `:-3` fallback but never declared until now). Added 2 plain-assignment regex declarations (`BLOCKS_LINE_REGEX`, `FINDING_FINGERPRINT_REGEX`) — `:=` is intentionally NOT used on the regexes (Q2 security advisory: defaulted-assignment would let a hostile env override regex shape and widen the ReDoS attack surface without a validator). All 14 new declarations live after the `_UBERDEV_GOAL_STATE_LOADED=1` marker (within the guarded first-source-per-process region per RFC 0005 D19; relies on each fresh-shell rehydration fence being a new process), immediately after the line-101 precedent.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` — Constants block kept byte-identical (tests G24/G28/G34 grep the literals verbatim — partial change would red CI); added a one-line prose pointer above the block declaring `lib/goal-state.sh` as the runtime SSOT and the SKILL.md block as the documentation SSOT.
  - Tests: `tests/goal.test.sh` G20 ratcheted to 0.35.1; new G40 regression test sources ONLY `lib/goal-state.sh` in a fresh `bash -c` and asserts `_UBERDEV_GOAL_STUCK_SECS == 14400` — proves the fix on the exact path that fails today. `tests/solve-claim.test.sh` version block ratcheted 0.35.0 → 0.35.1.

### Notes
- Version bumped to 0.35.1 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant (memory `project_uberdev_version_lock_tests`).
- Out of scope: consumer-call-site SSOT migration for the two regex constants (`_uberdev_goal_parse_blocks_line` and `_uberdev_goal_extract_fingerprint` still hardcode the literal — deferred per Q2); `_uberdev_goal_validate_int` hardening for arithmetic uses of the integer constants (latent env-injection surface, pre-existing); a fuller Phase-1→2→3→4 fresh-shell-fence integration test (G40 covers the primary scalar; deeper test logged as a follow-up).

## [0.35.0] — 2026-05-28

### Changed
- **Models:** `/turbo`, `/solve`, and `/goal` now dispatch every agent on `claude-opus-4-8[1m]` (was `claude-opus-4-7[1m]`).
- **Agents:** the 22 former-`sonnet` subagents plus the 9 `opus` subagents and 4 pipeline skills now use `model: inherit`, so the whole subagent tree runs on the session's Opus 4.8 1M model. The 6 `haiku` agents and 4 pre-existing `inherit` agents are unchanged. Former-`sonnet` agents carry a `# WAIT 4.8 sonnet` comment to revisit when Sonnet 4.8 ships.
- Swept stale Sonnet / Opus-4.7 model references from agent descriptions, the `/issue` command docs, the `orchestrator` and `post-impl-review` skills, and the README; `plan-writer` no longer pins its internal research subagents to Sonnet.

## [0.34.13] — 2026-05-28

### Fixed
- **`/uberdev` dispatch pairs `--dangerously-skip-permissions` with `--permission-mode bypassPermissions` so the bg UI cycle ring no longer lands on `auto` (Closes #246).** The PR #243 collapse populated `PERM_FLAG` with `--dangerously-skip-permissions` alone. In Claude Code 2.1.152+, `--dangerously-skip-permissions` bypasses permission *checks* but does NOT set `--permission-mode`; the bg session's UI cycle ring is driven by `--permission-mode`, and without an explicit setting it defaults to `auto` — exactly the mode that silently breaks Search and other agent tools (see memory `feedback_permission_tier_bypass_default`). Caught while reviewing `/ubergoal 225 226 227` cycle 1 — the bg session status bar showed `↗ auto mode on` even though argv passed `--dangerously-skip-permissions`. This is the missing other half of PR #243.
  - `plugins/uberdev/lib/dispatch.sh` `uberdev_dispatch_resolve_env` — both `PERM_FLAG=( --dangerously-skip-permissions )` sites (the `SKIP_PERMISSIONS=1` branch and the `AUTO_PERMISSIONS=1` branch) now resolve to `PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )`. Belt-and-suspenders: `bypassPermissions` pins the cycle-ring position so the UI doesn't default to `auto`; `--dangerously-skip-permissions` short-circuits the actual permission-check codepath. The two flags target different mechanisms and are not redundant. Affects all three dispatch backends (`_uberdev_dispatch_claude_bg`, `_uberdev_dispatch_background`, `_uberdev_dispatch_wezterm`) because they all expand `"${PERM_FLAG[@]}"` from the same resolver.
  - Tests: `tests/dispatch-claude-bg.test.sh` — three behavioural cases ratcheted (D-perm / D-skip / D-precedence) from the bare-skip literal to the new paired literal; structural-grep `perm_flag_count` and the negative auto-mode guard updated; new bare-skip regression guard (`bare_skip_count == 0`) locks the pairing so the bare form cannot silently reappear.
  - `tests/goal.test.sh` G20 + `tests/solve-claim.test.sh` version-bump block ratcheted to `0.34.13`.

### Notes
- Version bumped to 0.34.13 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Pairs with the v0.34.9 cut that shipped PR #243 (the AUTO_PERMISSIONS collapse). Together, both halves of the bypass-tier contract are restored: argv flag AND cycle-ring position.

---

## [0.34.12] — 2026-05-28

### Fixed
- **`/uberdev:goal` mis-classifies orchestrator-driven close-without-PR as `failed` (Closes #249).** `/uberdev:orchestrator` (dispatched by `/goal` Phase 1 via `claude --bg`) can legitimately close a GitHub issue without producing a PR when the finding is stale, already-resolved, or non-actionable (concrete prior cases: #226 closed as "verified already resolved by PR #224", #227 closed as "stale finding on closed PR #223"). Phase 2 step 2a was checking only (a) does a PR exist, (b) is the solver still busy, (c) elapsed vs `_UBERDEV_GOAL_SOLVE_TIMEOUT` — it never probed the issue's GitHub `state`. A legitimately closed-without-PR issue spun in `solving` for ~150 minutes and was misleadingly marked `failed` rather than terminated cleanly.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` Phase 2 step 2a — inside the `else` branch (no PR yet, agent idle), inserted a `gh issue view --json state` probe. When `state == "CLOSED"` (uppercase, gh GraphQL semantics), transitions `solving → resolved-by-no-action` and emits the new `goal_issue_closed_without_pr` audit event. Non-zero `gh` rc falls through to the existing 150-min `SOLVE_TIMEOUT` backstop (RFC 0005 B6 — surface gh failures, never cascade into false terminal transitions). Stderr breadcrumb on failure.
  - `GOAL_ISSUE_STATE_ENUM` extended from 6 to 7 states (`+resolved-by-no-action`). Phase-2a skip-check widened to `pr-pushed|resolved|resolved-by-no-action|failed` — required for correctness; without it, an issue already in the new state would be re-probed every poll tick.
  - `GOAL_AUDIT_EVENT_ENUM` extended from 11 to 12 events (`+goal_issue_closed_without_pr`). Audit-event payload: `{goal_id, issue, detected_at}` — all three values upstream-validated, defence-in-depth `_uberdev_goal_validate_int "$issue"` before the `gh` call (T3 mitigation).
  - `plugins/uberdev/lib/goal-state.sh` — new arc `solving → resolved-by-no-action` in `uberdev_goal_issue_state_transition` case; new event case-arm `goal_issue_closed_without_pr)` in `uberdev_goal_audit` case. Both omissions would silently strand (rc=2 or rc=1) without the explicit arms — BT84 / BT85 are the only protection against silent strand.
  - `print_summary` `issues_resolved` awk filter broadened to count both `resolved` and `resolved-by-no-action`. Phase 3 terminal-set logic is PR-count driven and stays unchanged — an issue with zero PRs contributes zero to `all_pr_count`, so `0 == 0` already converges cleanly when the active-count drains.
  - Tests: `tests/goal.test.sh` G3 (issue-state enum), G11 (audit-event presence list — extended from 11 to 12), G24b (literal enum string), G20 (release-ratchet) updated to the new strings; new G39 structural-grep locks the SKILL.md probe call-site (4 sub-asserts: probe line, uppercase CLOSED check, transition arc call-site, audit event emission); new behavioural tests BT84 (`solving → resolved-by-no-action` arc returns rc=0 + TSV state assertion + negative regression guard on the previously-rejected `solving → resolved` direct arc) and BT85 (`uberdev_goal_audit goal_issue_closed_without_pr '...'` writes a JSONL line, rc=0, numeric `issue` field + negative regression guard on unknown events) added post-BT83. `tests/solve-claim.test.sh` version-bump block ratcheted to `0.34.12`.
  - RFC `docs/rfc/0005-uberdev-goal.md` §9 — new D249a addendum row documents the new event, the new state, the skip-check widening, and the `gh` rc no-signal contract. Bug-fix scope under §2.3 (the auto-merge carve-out): no new RFC.

### Notes
- Version bumped to 0.34.12 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Renumbered from the original PR target (0.34.10) to 0.34.12 after rebase onto main absorbed v0.34.10 (#244) and v0.34.11 (#250). PR #250's `/uberdev:orchestrator` direct-dispatch change is preserved intact (G38 + BT83 ratchets unchanged); this PR's #249 fix is strictly additive on top.

---

## [0.34.11] — 2026-05-28

### Fixed
- **`/uberdev:goal` Phase 1 now dispatches `/uberdev:orchestrator --turbo` directly, skipping the `/turbo` wrapper (Closes #248).** The previous dispatch chain spawned two `claude --bg` sessions per issue (`goal → bg(/turbo) → bg(/orchestrator)`). Phase 1 now invokes `/orchestrator` directly via `claude --bg`, collapsing to a single bg session per issue and halving per-issue boilerplate cost; scales linearly with `--max-parallel`.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` Phase 1 (search for `Invoke the slash command /uberdev:orchestrator`) — the `printf` body now reads `Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #%s now. …`; the `--backend=%s` arg flag is dropped because `/orchestrator` does not accept it. Backend now forwards exclusively via the `UBERDEV_RESOLVED_BACKEND` env-var that Phase 0 exports — `claude --bg` inherits the parent shell's full env table, so the env-var path is the canonical mechanism (RFC 0005 D15 single-resolution invariant preserved).
  - Side-effect: `SKIP_PERMISSIONS=1` (set by `/goal` Phase 0) now reaches the orchestrator child unimpeded. Previously, the intermediate `/turbo` wrapper's defensive `unset SKIP_PERMISSIONS` (in `commands/turbo.md`) actively conflicted with `/goal`'s autonomous-loop opt-in; removing the wrapper layer closes that latent bug. Standalone `/turbo` still keeps the defensive `unset` to guard against shell-rc / stale-session pollution.
  - Tests: `tests/goal.test.sh` — `G15.backend-forwarding` re-pointed at the new env-propagation comment (no longer references the removed `--backend=` arg flag); new `G38.goal-phase-1-orchestrator-dispatch` shape gate (assert_grep + assert_no_grep) locks the orchestrator-direct invocation against silent regression.
  - No user-facing CLI surface change. Standalone `/uberdev:turbo` users are unaffected.

### Notes
- Version bumped to 0.34.11 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.10] — 2026-05-28

### Fixed
- **Skill-loader $N substitution corrupts `emit_topic_log()` in orchestrator (#225).** Same bug class as #222 (awk one-liners), different surface — the Claude Code Skill renderer text-substitutes positional non-flag args of `$ARGUMENTS` into the entire rendered SKILL.md body, including inside bash function bodies. The Phase 1 fanout's `emit_topic_log()` helper used bash positional refs, so all 12 call sites were silently emitting the same render-time substitution (e.g. `agent=research-solve status=GH note=issue` on `/uberdev:orchestrator --turbo solve GH issue #225`) instead of binding at call time. The per-topic observability log was effectively useless: every line emitted the same agent/status/note triple regardless of which topic was being dispatched or whether it was cache-reused vs fresh-dispatched.
  - `plugins/uberdev/skills/orchestrator/SKILL.md` — `emit_topic_log()` now reads positional args via the `${@:N:1}` array-slice form. The slice has no dollar-immediately-followed-by-digit substring (the digit follows `:`, not the dollar), so the renderer leaves it verbatim and bash evaluates the slice at call time. The local variable holding the `status` arg is named `topic_status` rather than `status` because `status` is a read-only special parameter in zsh (the Bash-tool default shell on macOS) — `local status="…"` aborts the function with `read-only variable: status`. Added a comment header naming the renderer-substitution mechanic, the symptom, and the safe form, plus the zsh-special-parameter caveat. The two awk-surface sites in `emit_topic_log`'s neighbourhood (the cached-research staleness check and the multi-line files-investigated parse) were already fixed in PR #224 (the `-v cN=N` + `$cN` form) — this PR's fix is the third surface from issue #225's deferred finding.
  - `tests/skill-renderer-awk-collision.test.sh` — extended from 4 to 9 assertions. R4 scans `orchestrator/SKILL.md` for any bare `$N` and red-CIs on a regression, sharing `BASH_GUARD_REGEX` as SSOT with the R5 inverse fixtures. R5.bad + R5.safe are the inverse fixture proofs (a naïve bash function body MUST be flagged; the recommended `${@:N:1}` form MUST NOT be flagged), mirroring the R2/R3 pattern from the awk surface. R6.bash + R6.zsh execute the live `emit_topic_log` definition extracted from `orchestrator/SKILL.md` under both shells and assert the emitted log line matches the schema — this catches cross-shell regressions (such as the zsh-reserved `status` local-var bug that surfaced in /review-pr review of this PR) that static regex scans miss. The test now covers both #222 (awk) and #225 (bash) bug classes in a single drift guard. Scope is intentionally narrow to `orchestrator/SKILL.md` — the broader bash-positional sweep across other pipeline SKILL.md files (7+ known sites in solve/goal/finish/testers/ubersimplify) is documented in the test header comment as a follow-up and NOT enforced here (would red CI on those known-vulnerable sites until they too are fixed).

### Notes
- Version bumped to 0.34.10 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.9] — 2026-05-27

### Changed
- **Collapsed the `AUTO_PERMISSIONS` middle tier into `--dangerously-skip-permissions` (post-#241 follow-up).** `--permission-mode auto` is silently broken in practice — Claude Code's auto-mode classifier refuses some agent tools (notably Search) both inside and outside cmux, leaving operators in a half-broken state that defeated the whole point of `/turbo --auto` / `/solve --auto`. The middle tier was dead weight, so `AUTO_PERMISSIONS=1` now resolves to the same `--dangerously-skip-permissions` flag as `SKIP_PERMISSIONS=1`. The env-var name is preserved for backward compat with `/turbo --auto`, `/solve --auto`, and any external callers.
  - `lib/dispatch.sh:uberdev_dispatch_resolve_env` — the `elif [[ "$AUTO_PERMISSIONS" == "1" ]]` branch now sets `PERM_FLAG=( --dangerously-skip-permissions )` instead of `PERM_FLAG=( --permission-mode auto )`. The if/elif ordering is preserved for audit-log clarity (which env var the caller set), but both branches now emit the same flag.
  - `solve-pipeline/SKILL.md` — the `PERM_DESC` strings updated to `bypass (--dangerously-skip-permissions; <TIER>_PERMISSIONS tier ...)`; the tier-name suffix lets post-hoc grep attribute the bypass to `/goal` (SKIP) vs `/turbo --auto` / `/solve --auto` (AUTO). The flat-var if/else form is preserved (zsh-NOMATCH regression guard, audit-fixups.test.sh C8).
  - `commands/solve.md` — the `--auto` flag description updated to reflect the remap; documents that the trade-off is broad (dangerous tools no longer prompt) and recommends use only when the issue is unattended-friendly.
  - Tests: `dispatch-claude-bg.test.sh` D-perm + D-precedence assertions updated to expect `--dangerously-skip-permissions` from `AUTO_PERMISSIONS=1`; new structural assertion that exactly 2 `PERM_FLAG=( --dangerously-skip-permissions )` sites exist in `dispatch.sh` (SKIP + AUTO branches, both bypass); new regression guard that `PERM_FLAG=( --permission-mode auto )` does NOT re-appear at runtime. `solve-pipeline-zsh.test.sh` R3 fixture rewritten to test the single-token `--dangerously-skip-permissions` argv form + auto-mode-collapse regression guard (the two-token zsh-array-word-split coverage now lives in R2's `--effort max` path). `audit-fixups.test.sh` PERM_DESC asserts updated to the new bypass strings.
  - Trust-boundary unchanged — the orchestrator's `<external-untrusted-input>` trust-wrap is unaffected by the `--permission-mode` argv flag remap. Residual security risk is explicitly accepted (continuation of #241 stance): the alternative (broken agents under `--permission-mode auto`) is worse.

### Notes
- Version bumped to 0.34.9 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.8] — 2026-05-27

### Fixed
- **`/uberdev:goal` stalls on cmux-mediated environments — bg agents flap busy/idle without producing PRs (Closes #241).** On macOS + cmux, dispatched bg `/turbo` agents stall on the first `Bash` tool call ("The user doesn't want to proceed with this tool use") because cmux's `PermissionRequest` hook (injected via `--settings <blob>` into the bg session's `respawnFlags`) shadows the user's own `~/.claude/settings.json` and refuses the prompt after a 125 s timeout. The contrast run with a manual `claude --bg --dangerously-skip-permissions` ran cleanly with zero rejections — confirming the strict bypass is the unblocking flag.
  - Added a third `SKIP_PERMISSIONS` env-var tier to `uberdev_dispatch_resolve_env` (`lib/dispatch.sh`) with strict precedence over `AUTO_PERMISSIONS`. Maps to `PERM_FLAG=( --dangerously-skip-permissions )` when `${SKIP_PERMISSIONS:-0} == 1`. Literal `PERM_FLAG=()` and `PERM_FLAG=( --permission-mode auto )` lines preserved verbatim for structural-shape tests.
  - `goal-pipeline/SKILL.md` Phase 0 step 4 exports `SKIP_PERMISSIONS=1` unconditionally — the operator's `/uberdev:goal` invocation IS the opt-in to autonomous-convergence; no per-run flag.
  - Both `BG_TURBO_ENV` blocks (`_uberdev_dispatch_claude_bg` and `_uberdev_dispatch_background`) append `SKIP_PERMISSIONS=1` when set, propagating the env-var across the `env(1)` boundary so nested child dispatches also resolve to the bypass flag. Gates on `${SKIP_PERMISSIONS:-0}` directly (NOT on `AUTO_MODE`) — the semantics are independent of turbo-mode and the defensive `unset` in `/turbo`/`/solve` is the pollution gate.
  - Defensive `unset SKIP_PERMISSIONS` in `commands/turbo.md` and `commands/solve.md` mirrors the #97 `UBERDEV_TURBO` hardening pattern — prevents shell-rc / stale-session pollution from silently elevating bare invocations.
  - New "## Permission requirements (cmux/hooks caveat)" section in `commands/goal.md` documents the `--settings`-shadowing failure mode and the env-var path that actually unblocks the loop.
  - Tests: D-skip + D-precedence behavioural tests (mirror D-perm template); structural greps for `PERM_FLAG=( --dangerously-skip-permissions )` and `BG_TURBO_ENV+=( SKIP_PERMISSIONS=1 )` in both dispatch arms; G20c assertion for `export SKIP_PERMISSIONS=1`; T-no-skip-turbo / T-no-skip-solve negative-test assertions; D-iso unset list updated to include `SKIP_PERMISSIONS`.
  - Trust-boundary unchanged. The orchestrator's `<external-untrusted-input>` trust-wrap (emitted at prompt-construction time, unaffected by the `--permission-mode` argv flag) remains the defence against prompt-injection. Residual security risk is explicitly accepted as the cost of autonomous-convergence; the alternative (perpetually stalled `/goal`) is worse.

### Notes
- Version bumped to 0.34.8 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.7] — 2026-05-27

### Fixed
- **`/uberdev:goal` Phase-1 skip-check re-dispatched issues on leaf-side pre-state-write crashes (Closes #236).** The Phase-1 skip-check only matched `solving|pr-pushed` — states the parent wrote AFTER `uberdev_dispatch_one` returned. Any leaf-side failure between the spawn returning success and the post-spawn `solving` write (network blip mid-init, OOM, agent timeout before first state write, the argv-slash bug from #235, any future CLI regression) left the TSV row in its pre-dispatch `input` default, indistinguishable from "never attempted". The next cycle re-read the TSV, fell through the skip-check, and dispatched the issue a second time — producing TWO `solve-issue-N/` worktrees, two zombie `claude agents` sessions, and two `/review-pr` runs against (eventually) two duplicate PRs. Closed by adding a `dispatched` pre-spawn guard state: the parent now writes `input → dispatched` BEFORE calling `uberdev_dispatch_one` and the skip-check matches `dispatched|solving|pr-pushed`, so a leaf failure between spawn and the post-spawn `solving` refinement still leaves a row the next cycle's skip-check sees. The post-spawn `dispatched → solving` transition is now a refinement rather than the load-bearing in-flight signal. On `uberdev_dispatch_one` rc!=0 (hard error, not `claim_collision`), the parent transitions `dispatched → failed` before exiting so the TSV reflects the true terminal state.
  - State machine extended (`lib/goal-state.sh:430` + RFC 0005 §3.2.2 D2): 6 states (`input → dispatched → solving → pr-pushed → resolved`) with `dispatched → failed`, `solving → failed`, `pr-pushed → failed` sinks. `input → solving` retained for the legacy single-write path; `input → dispatched` and `dispatched → solving|failed` added.
  - Enum constant (`GOAL_ISSUE_STATE_ENUM`) and Phase-1 prose updated.
  - BT80-BT82 (goal.test.sh) cover the 3 new valid transitions, 5 new invalid-transition guards, and the leaf-crash-pre-state-write simulation (TSV row written `dispatched`, skip-check matches, no re-dispatch on cycle 2). G24b grep-tests the SKILL.md shape (enum + skip-check + pre-spawn write line-order vs `uberdev_dispatch_one` call + dispatch-failure cleanup).
  - Companion #235 (argv-slash non-expansion) is one trigger of this surface and is resolved CLI-side; this fix closes the structural weakness so future leaf failures cannot reproduce the double-spawn.

### Notes
- Version bumped to 0.34.7 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Landed via rebase+renumber after 0.34.6 (PR #238, dispatch-argv natural-language fix) collided on the same version slot — `/merge` autopilot caught the collision before publication.

---

## [0.34.6] — 2026-05-27

### Fixed
- **`claude --bg` argv-mode slash-command never expanded — `/goal` → `/turbo` leaf silently died (Closes #235).** `claude --bg ... -- "<prompt>"` passes the prompt as the first user message of the spawned agent. Since CLI 2.1.139 (the version `--bg` first shipped) argv-supplied opening messages have NOT been slash-expanded by the child, so a prompt body opening with `/uberdev:turbo …` was silently treated as natural language and the child agent answered conversationally instead of running the command. Every medium-tier `/goal` → `/turbo` → `/orchestrator` chain died at the prompt-delivery boundary; the resulting silent-leaf failure cascaded into double worktrees / double reviews when goal-pipeline's Phase-1 skip-check saw no `solving` row and re-dispatched on the next cycle. Five prompt-build callsites are rewritten to wrap the slash invocation in a natural-language imperative (`Invoke the slash command /uberdev:… now. Do not respond conversationally — execute it.`) so the child reads the body as an instruction it must act on, not a question to discuss:
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md:240-242` — `/uberdev:turbo` dispatch.
  - `plugins/uberdev/skills/solve-pipeline/SKILL.md:776,778` — medium-tier `/uberdev:orchestrator` dispatch (both turbo and interactive arms).
  - `plugins/uberdev/lib/goal-state.sh:1267` — `_uberdev_goal_dispatch_review_pr`.
  - `plugins/uberdev/lib/goal-state.sh:1311` — `_uberdev_goal_dispatch_merge`.
- **`uberdev_goal_review_pr_in_flight` probe regex relaxed (companion fix; sibling-applied via Phase 1 of /review-pr).** `claude agents --json` derives `.name` from the prompt body verbatim, so the anchored regex `^/uberdev:review-pr <pr>` could not match the new natural-language wrapper. Dropped the leading `^` to a substring match in `plugins/uberdev/lib/goal-state.sh`; the trailing `($|[^0-9])` boundary stays as the load-bearing anti-collision guard (rejects 21 matching 218, 42 matching 421). Without this companion fix the in-flight gate landed by #220 (PR #221, v0.34.4) would silently no-op for every PR dispatched post-#235. Added `tests/goal.test.sh` BT76.match-nl-wrapper case + renamed BT76.no-match-421-anchor → BT76.no-match-421-boundary + G32.name-regex → G32.substring-name-regex for self-documenting naming consistency.

### Added
- `tests/dispatch-prompt-no-bare-slash.test.sh` — drift-guard scanning the three prompt-build callsite files (`goal-pipeline/SKILL.md`, `solve-pipeline/SKILL.md`, `lib/goal-state.sh`) for any `printf` / `echo` writing a body that opens with `/uberdev:`. R2 fixture proves the regex flags vulnerable shapes; R3 inverse fixture proves the natural-language imperative shape is NOT false-positived. Wired into both ubuntu and windows CI matrices.

### Notes
- Version bumped to 0.34.6 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Scope strictly option 3b from the issue (lowest-blast-radius rewrite). Switching `BG_PROMPT_MODE` to `--prompt-file` (option 3a) requires verifying the file-mode arm re-evaluates the body through the interactive parser on 2.1.152 and is deferred. Symptom B hardening (state-transition-on-dispatch, label-probe skip-check) per issue §5 is independently scoped.

---

## [0.34.5] — 2026-05-27

### Fixed
- **Skill renderer corrupted awk `$0`-`$9` field refs across 6 SKILL.md files (Closes #222).** The Claude Code Skill loader substitutes positional non-flag args of `$ARGUMENTS` into the entire SKILL.md body, **including inside single-quoted awk one-liners AND multi-line awk script bodies**. `/ubergoal all gh issues` rendered `awk '$1==p && $2=="x"{t=$3}'` as `awk 'gh==p && issues=="x"{t=}'` (or `'219==p && 198=="x"{t=}'` for numeric args), producing false convergence (`all_pr_count=1` regardless of real PR set), bogus `FAILED` transitions (every `dispatch_ts` returned 0), and broken state-skip gates. The same class also bit `$0` (the renderer substitutes the first positional non-flag into `$0`), which silently broke `/turbo 5 6 7` multi-issue dedupe (`awk '!seen[$0]++'` rendered as `!seen[5]++`, dropping every issue past the first). 14 awk sites total across 6 SKILL.md files were rewritten to use parameterised field refs (`-v cN=N` + `$cN`) so the renderer cannot touch them — the `$cN` form is not a positional shell reference and the renderer leaves it untouched:
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` — 8 sites (lines 221, 353, 367, 387, 461, 680, 958, 1061) on `$1`/`$2`/`$3`.
  - `plugins/uberdev/skills/orchestrator/SKILL.md` — 2 sites (line 199 single-line `$2`, line 225 multi-line `$1`) plus matching doc at line 279.
  - `plugins/uberdev/skills/requesting-code-review/SKILL.md` — 1 site (line 56) on `$1`.
  - `plugins/uberdev/skills/solve-pipeline/SKILL.md` — 1 site (line 93) on `$0`.
  - `plugins/uberdev/skills/merge-pipeline/SKILL.md` — 1 site (line 809) on `$0`.
  - `plugins/uberdev/skills/finish-branch/SKILL.md` — 1 site (line 162) on `$0` (3 references in one awk).

### Added
- `tests/skill-renderer-awk-collision.test.sh` — drift-guard scanning every `plugins/uberdev/skills/*/SKILL.md` for awk script bodies containing bare `$N` field refs (0-9). Uses a flattened-file scan (`tr '\n' ' '`) to catch multi-line awks (orchestrator/SKILL.md:225-class regressions that line-anchored greps silently pass), with regex constrained to `awk[^']*'[^']*\$[0-9][^c]` so it matches only inside the FIRST single-quoted body after `awk` (prevents greedy `.*` from spanning across the whole flattened file). R2 fixture proofs cover both single-line AND multi-line vulnerable shapes; R3 inverse fixture covers the full `$c0`/`$c1`/`$c2`/`$c3` safe set. Wired into both ubuntu and windows CI matrices.

### Notes
- Version bumped to 0.34.5 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Scope expanded mid-review (from `$1`-`$3` to `$0`-`$9`) after the `/review-pr` Phase 1 general-lens reviewer surfaced the orchestrator multi-line awk site missed by the original line-anchored regex; same root cause, so the three additional `$0` sites are folded into this PR rather than deferred.

---

## [0.34.4] — 2026-05-27

### Fixed
- fix(goal): bump review-grace default to 60m + add `goal.review_grace_secs` config key (Closes #220, AC ❶)
- fix(goal): in-flight `/review-pr` gate before `/merge` and stale-arm re-dispatch — emits `goal_merge_deferred` (Phase 2c gate) and `goal_review_pr_deferred` (Phase 2b gate) (Closes #220, AC ❷)
- fix(goal): stuck-on-dialog detector + `agent_stuck_on_dialog` circuit-breaker (Closes #220, AC ❸)
- fix(goal): Phase 3 rollover preservation — merges Phase-1 carry-over instead of overwriting; adds `rolled_over` to `goal_cycle_completed` audit (Closes #220, AC ❹)

### Added
- feat(goal): zombie reaper on Ctrl-C / SIGTERM / circuit-breaker — emits `goal_reaper_kill` / `goal_reaper_skipped` (Closes #220)

### Notes
- Version bumped to 0.34.4 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- RFC 0005 §9 D-code addendum block D220a–D220h documents all enum amendments. No new RFC required (bug-fix scope under §2.3 carve-out).

---

## [0.34.3] — 2026-05-26

### Fixed
- **`tests/*.test.sh` source sites of `_lib_assert_structural.sh` were unguarded, so a missing or unreadable helper could yield a vacuous-green run (#209).** The suite uses the deliberate `set -u; set -o pipefail` + manual PASS/FAIL-counter convention (NOT `set -e` — see `install.test.sh:26-29` for the rationale): when `source` of the shared helper failed, the subsequent `assert_in_section` / `assert_subagent_type` / `assert_count` calls then exited 127, but execution continued and the test could still `exit 0` if its locally-defined `assert_grep` checks all passed. Only latent today because the helper is a committed file (always present after `actions/checkout`); became slightly more consequential once PR #208 wired the structural tests into CI. Fix: append the existing FATAL-preflight convention (`|| { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }`) to every `source` / `.` of the helper across the 9 affected files (`code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `goal-batch-barrier`, `post-impl-review`, `review-pr-phase3-ci`, `review-pr`, `simplify`, `trust-trail-evaluator`). New structural drift-guard `tests/test-harness-source-guards.test.sh` (9 assertions; auto-discovers any current or future sourcing file via the shell glob and enforces the literal FATAL message contract). Wired into both ubuntu + windows CI matrices. Behavioral verification: rename the helper aside, run each guarded test, observe rc=2 with the FATAL message on stderr — confirmed across all 9 files.

### Changed
- Version bumped to 0.34.3 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`). Re-numbered from #218's original 0.34.1 to avoid collision with #216 + #217 (PR landing order: #216 → 0.34.1, #217 → 0.34.2, #218 → 0.34.3).

## [0.34.2] — 2026-05-26

### Fixed
- **`lib/goal-state.sh` `_uberdev_goal_dispatch_review_pr` + `_uberdev_goal_dispatch_merge`: guard the `uberdev_dispatch_one` lib/dispatch.sh dependency (#207, same latent-crash class as #195).** Both helpers now run a `command -v uberdev_dispatch_one` preflight after argument validation and BEFORE any counter-write or `mktemp`; on a missing dep they fail loud with the distinct dep-missing rc=4 and a `goal-state:` diagnostic naming the symbol, instead of crashing mid-dispatch on a bare `command not found` after the per-PR attempt counter had already been incremented (phantom attempt with no actual dispatch). The "External imports" header at the top of `goal-state.sh` consolidates both dispatch-lib symbols (`_uberdev_dispatch_prepare_tmp_target`, `uberdev_dispatch_one`) under one paragraph; `_uberdev_goal_dispatch_merge` also reorders `_uberdev_goal_validate_id` above the `mktemp` so the id-validate failure path no longer leaks a stray prompt file. New `tests/goal-dispatch-helpers.test.sh` covers the rc=4 + diagnostic + no-CNF-leak + no-stray-file negative cases (fresh `bash -c` without dispatch.sh) plus a stub-based positive case proving both helpers reach `uberdev_dispatch_one` with the `(pr, "small", prompt_file)` shape when the dep is present. Wired into both ubuntu + windows CI matrices.

### Changed
- Version bumped to 0.34.2 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`). Re-numbered from #217's original 0.34.1 to avoid collision with #216 (PR landing order: #216 → 0.34.1, #217 → 0.34.2, #218 → 0.34.3).

## [0.34.1] — 2026-05-26

### Added
- **`tests/ci-wiring.test.sh` — drift-guard for `.github/workflows/test.yml` (#210; prevents #196 recurrence).** Converts the existing SYNC convention between the `shape-checks` (ubuntu) and `shape-checks-windows` jobs into an enforced invariant. Asserts five locks: W1 every `tests/*.test.sh` on disk is wired into the ubuntu job; W1b ubuntu has no references to nonexistent test files; W2 windows is a (non-strict) subset of ubuntu; W3 windows has no phantom references; W4 (ubuntu − windows) equals the canonical `# === BEGIN ci-wiring windows-skip-list ===` marker block now embedded in the windows job's comment header. A new `tests/*.test.sh` committed without being wired into the ubuntu job — or a Unix-only fixture added without an entry in the marker block — now reds CI immediately. Portable: bash + awk + grep + sed + sort + comm, runs in both shape-checks jobs (ubuntu-latest native bash + windows-latest Git Bash). Wired as the FIRST entry in each job's `run:` block so a wiring drift fails fast.

### Changed
- Version bumped to 0.34.1 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.34.0] — 2026-05-26

### Added
- **`/uberthink` — read-only cross-domain ideation engine.** Spawns an agent fleet (frame → generator × personas → moderator → synthesizer × {weave/crossover/mutate} → falsifier × {steelman/premortem/redteam/physics} → arbiter) across parallel evolutionary "islands" with a genetic loop-back (cap 3) for fixable kills. Emits a 4-axis ranked dossier with a 🌙 Moonshot lane (Novelty × Impact Pareto) + files top ideas as GitHub issues. Flags: `--islands N` (default 2), `--handoff` (auto-invoke `/uberdev:brainstorm` on the #1 design), `--no-issues`, `--max-new N` (default 3). Cost: ~K × 15× a normal chat. RFC: `docs/rfc/0009-uberthink-ideation-engine.md`.

### Changed
- Version bumped to 0.34.0 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).
- `tests/uberthink.test.sh` and `tests/uberthink-report.test.sh` wired into the CI matrix (ubuntu-only, alongside the other python3-dependent fixtures).

## [0.33.20] - 2026-05-26

### Added
- `/goal` config keys `goal.max_parallel` (`UBERDEV_GOAL_MAX_PARALLEL`, `--max-parallel=N`, default 3, range 1–10) and `goal.barrier_timeout_s` (`UBERDEV_GOAL_BARRIER_TIMEOUT_S`, `--barrier-timeout=N`, default 14400 s = 4h, range 60..86400).
- Three new public helpers in `lib/goal-state.sh`: `uberdev_goal_register_batch_pr`, `uberdev_goal_batch_all_terminal`, `uberdev_goal_batch_unblock_wait_clear`. RFC 0005 §9 D-211a/b/c.
- New batch-registry sidecar `goal-<id>-batch-prs.tsv` (per-PR rows with `pr<TAB>issue<TAB>dispatch_ts<TAB>terminal_state`); cleaned up by `uberdev_goal_cleanup_run_state`.
- **B8/B9 behavioral test coverage for `/goal` cap-rollover and wall-clock barrier breaker (#214; supersedes #213).** Added `uberdev_goal_barrier_breaker_check` helper to `lib/goal-state.sh` (replaces ~12 lines of inline elapsed-time math in `goal-pipeline/SKILL.md` Phase 2c); helper preserves the exact prior audit payload (`reason=stuck_loop`, `phase=merge_barrier`, `elapsed_s`, `pending_prs`). Two new test blocks: B8 cap-rollover (MAX_PARALLEL=3 vs 5-issue queue → 3 dispatched, 2 rolled over) and B9 wall-clock barrier (positive fire at elapsed≥timeout, negative no-fire under threshold, zero-start no-fire). Wired `tests/goal-batch-barrier.test.sh` into both ubuntu + windows CI matrices. G25/G28 shape-grep guards retained.

### Changed
- `/goal` per-cycle `/turbo` dispatch is now capped at 3 by default (previously uncapped); queue overflow rolls to the next cycle without re-claim collisions.
- `/merge` no longer fires per-PR the instant a PR turns GREEN; `/goal` holds until every PR in the cycle's batch is in a terminal state. Manifest-collision PRs (e.g. version-bump triplet) merge sequentially in PR-number-ascending order with `git fetch origin main` + rebase between each.
- Wall-clock breaker on the new merge barrier (4h default) escalates to the existing `stuck_loop` circuit-breaker reason — no new reason added, no `GOAL_CIRCUIT_BREAKER_REASONS` enum mutation.

## [0.33.19] - 2026-05-26

### Added
- **Wired the 10 orphaned `tests/*.test.sh` files into the CI matrix (`.github/workflows/test.yml`), so important surfaces that previously never ran in CI are now covered (#196, uberscan MAJOR).** A `/uberscan` whole-codebase pass found 10 test files present on disk but absent from both CI jobs — `code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `install`, `merge-discovery-resilience`, `simplify`, `testers-agent-contract`, `testers-rate-limit-audit`, `testers-rate-limit-wrapper`, `trust-trail-evaluator` — covering rate-limit enforcement, merge-discovery resilience, the code-fixer dispatch contract, findings→issues, trust-trail evaluation, and the installer bootstrap, none of which were regression-guarded by CI. Each test was **run locally and confirmed passing before wiring** (the PR's own CI then executes them). Job placement was decided by Git-Bash portability, mirroring the existing `solve-pipeline-zsh` / `testers-pipeline` / `uberscan`-trio precedent: 6 pure shape-check / proven-portable-runtime tests (`code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `install`, `simplify`, `trust-trail-evaluator`) run on **both** the ubuntu and windows shape-check jobs; 4 Unix-runtime tests run **ubuntu-only** — `merge-discovery-resilience` (executes an executable `fake-gh` fixture via PATH + sources `lib/discover.sh`, neither proven on Git Bash) and the three `testers-*` tests (`python3` + PyYAML, the same reason `testers-pipeline` is ubuntu-only). The `both`-job placements are each backed by an existing Windows-green precedent: `_lib_assert_structural.sh` (used by `review-pr.test.sh` et al.), `lib/config-read.sh` runtime (via `config-override.test.sh`), the `bash -c … uberdev_run_secret_scan_stdin` pattern (via `secret-scan.test.sh`), and chmod+x-stub execution (via `solve-effort-flag.test.sh`).
- **Investigated and dismissed the issue's "orphaned test of a nonexistent `agents/code-fixer.md`" concern.** The uberscan finding flagged `code-fixer-dispatch.test.sh` as referencing a missing agent file; the test actually references `plugins/uberdev/agents/code-fixer.md` (present, 7979 bytes) and passes — the agent exists, so the test was wired normally with no fabricated file.

### Changed
- Version bumped to 0.33.19 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.18] - 2026-05-26

### Fixed
- **`plugins/uberdev/lib/goal-state.sh`'s run-state writer hard-depended on `lib/dispatch.sh`'s `_uberdev_dispatch_prepare_tmp_target` without declaring or guarding the dependency, so sourcing `goal-state.sh` standalone crashed the writer with a cryptic `command not found` and a misdiagnosed return code (#195, uberscan MAJOR).** `uberdev_goal_write_run_state` calls `_uberdev_dispatch_prepare_tmp_target` (the #155 TOCTOU-safe target-prep helper) at four sidecar-write sites, but that function lives in `lib/dispatch.sh`, not `goal-state.sh` — and the file header's "External imports" note explicitly (and now-falsely) claimed the module required NO function from another lib. With no `command -v` preflight, a caller that sourced `goal-state.sh` without first sourcing `dispatch.sh` hit a bare `command not found` at the first call site; because that site is `… || return 3`, the writer then returned **rc=3 — the code documented for a genuine TOCTOU target rejection / disk write failure** — so the real cause (a missing `source`) was both unlogged and actively misdiagnosed. It worked in production only because the goal-pipeline fences happen to source `dispatch.sh` first; the contract was implicit and the header contradicted it. Fix: (1) correct the header to declare `lib/dispatch.sh :: _uberdev_dispatch_prepare_tmp_target` as REQUIRED and document that the caller must source it first (goal-state.sh deliberately does not self-source dispatch.sh — no stable relative path from a sourced lib + avoids a load-order cycle); (2) add a `command -v` preflight at the top of `uberdev_goal_write_run_state`, BEFORE any `mktemp` (so no temp sibling can leak), that fails loud with a distinct **rc=4** and a `goal-state: run-state writer requires lib/dispatch.sh sourced first …` diagnostic. `command -v` (not the `type -t` bashism, which misreports under the zsh-backed runner) keeps the probe correct in both bash and zsh. Regression-guarded by `tests/goal-state-sidecar.test.sh` (5 assertions: distinct rc=4, clear diagnostic, no `command not found` leakage, no stray temp file, and the happy path still returns 0 with `dispatch.sh` sourced).

### Changed
- Version bumped to 0.33.18 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.17] - 2026-05-26

### Fixed
- **`skills/using-git-worktrees/SKILL.md` built the global-directory worktree path with a literal tilde inside double quotes, so `git worktree add "$path"` created a directory literally named `~` under the current working directory instead of placing the worktree under `$HOME` (#194, uberscan MAJOR).** The global-dir case arm set `path="~/.config/uberdev/worktrees/$project/$BRANCH_NAME"` (and the matching case pattern was `~/.config/uberdev/worktrees/*`). Tilde expansion does NOT occur inside double quotes nor on the RHS of a quoted assignment — verified in both bash and zsh, where the value stays the literal string `~/.config/...` — so the subsequent `git worktree add "$path"` / `cd "$path"` polluted the repo with a stray `~` directory and put the worktree in the wrong place, the exact opposite of the intended global, outside-project location. (The common project-local `.worktrees/` branch was unaffected — only the global-config branch was broken.) Fix: expand explicitly with `path="${HOME}/.config/uberdev/worktrees/$project/$BRANCH_NAME"`, and widen the case pattern to `"$HOME"/.config/uberdev/worktrees/*|"~/.config/uberdev/worktrees/"*` so the global branch is selected whether `$LOCATION` arrives as the literal `~/...` the menu displays or an already-expanded `$HOME/...` form. Regression-guarded by the new `tests/using-git-worktrees.test.sh` (4 assertions: `${HOME}` expansion present, no quoted-literal-tilde path assignment, and both case-pattern forms matched), wired into both the ubuntu and windows CI shape-check jobs. The same `case` block also gained a loud `*)` default arm so an unrecognized `$LOCATION` fails fast instead of silently leaving `$path` unset for `git worktree add` (surfaced by the PR review fanout; guarded by assertion W5).

### Changed
- Version bumped to 0.33.17 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.16] - 2026-05-25

### Fixed
- **`uberscan-pipeline/SKILL.md` Phase 4 ran in a fresh shell and lost `CIRCUIT_BREAKER_HALT`/`FINDINGS_FLOOD`, so a CB3/CB4/CB5 halt exited 0 (false-clean) with no partial banner (#192, uberscan MAJOR).** Each ```bash``` fence re-derives `RUN_ID`/`RUN_DIR` via the #171 rehydration stanza — every phase is a separate shell. CB3 (per-wave timeout), CB4 (wall-clock) and CB5 (findings-flood) set `CIRCUIT_BREAKER_HALT`/`FINDINGS_FLOOD` only in memory inside the Phase-1 loop, but Phase 4's exit gate read `${CIRCUIT_BREAKER_HALT:-0}` — which defaults to `0` in its fresh shell — so a documented exit-1 halt silently exited `0` and the partial banner never printed. Persistence was asymmetric: CB1/CB7 already wrote `OVERFLOW=true` and CB5 wrote `PARTIAL=true` to `run-state.txt` (Phase 4 read `OVERFLOW` back), but the halt flag and flood flag were never wired through the file. Fix: each Phase-1 break now appends its trip reason (`CIRCUIT_BREAKER_HALT=CB3|CB4|CB5`, plus `FINDINGS_FLOOD=true`+`PARTIAL=true` for CB5) to `run-state.txt`, and Phase 4 reconstructs the exit decision + the halt/flood banners by reading it back with `grep`, exactly as it already did for `OVERFLOW`. The persisted `run-state.txt` is now documented as the single source of truth (the bash loop is a millisecond directive-emitter whose in-loop counters never accumulate across waves; the orchestrator persists the trip reason between waves). A latent `grep -c … || echo 0` double-`0` integer-comparison error in the OVERFLOW banner — which the now-always-present `run-state.txt` would have surfaced on every CB3/CB4 halt — was fixed to `grep -q` in the same pass. Regression-guarded by `tests/uberscan.test.sh` (8 shape assertions) plus a behavioral reconstruction smoke test covering CB5/CB3/clean/overflow-only.
- **`uberscan-pipeline/report.py` `SEV_RANK` tied `major` and `important` at rank 2, so `--min-severity=major` silently filed `important`-tier findings as issues (#193, uberscan MAJOR).** `severities_at_or_above("major")` and `severities_at_or_above("important")` returned the identical set `{blocker,critical,major,important}`, so the `--min-severity` floor could not distinguish the two tiers — every `important` finding was filed under the default `--severity=major`. Fix: give `important` a distinct rank below `major` (`blocker:5, critical:4, major:3, important:2, suggestion:1`) so the floor is a true total order. Coupled hazard addressed: `_global_rows` hardcodes the synthetic Semgrep-SAST + test-coverage rows at severity `important` and previously gated emission on `important in allowed`, which only passed at the default floor *because* of the now-removed tie; the curated global rows are now filed **unconditionally** (gated on artifact presence, not on the chunk `--min-severity`), so the SAST/coverage signal `/uberscan` exists to surface keeps reaching the issue aggregate at the default floor and above. Regression-guarded by `tests/uberscan-report.test.sh`: `--min-severity major` now excludes `important` chunk findings, while the global Semgrep/coverage rows are still filed at the default floor (and even at `--min-severity critical`); the byte-identical golden snapshots prove the rank change preserved existing ordering.

### Changed
- Version bumped to 0.33.16 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.15] - 2026-05-25

### Fixed
- **`testers-pipeline/aggregate.py` crashed the entire wave when one persona emitted `evidence` as a truthy non-dict (#191, uberscan MAJOR).** `has_evidence()` deliberately raises `ValueError` on a string/list `evidence` (the schema deviation its own comment anticipates), but the per-finding loop in `main()` had no `try/except` — so a single malformed persona output (`evidence: "free text"` or `evidence: [..]`, which survives `f.get("evidence") or {}` as a truthy value and reaches the type guard) propagated an uncaught `ValueError`. The aggregator aborted at the first offending finding **before `wave-N.yaml` was ever written**, discarding the valid findings from all 8 agents in that wave (and, because the uncaught exception exits 1, the wave loop additionally mis-read it as a polite-rate breach). Persona output is untrusted free-form agent YAML, so a schema deviation is *expected*, not exceptional — the guard meant to surface bad input instead weaponized one bad agent into a wave-killer. Fix: wrap the per-finding `has_evidence` call in `try/except ValueError`, mirroring the file's existing malformed-YAML skip-and-continue — log a one-line `warning: skipping finding with non-dict evidence in <path>: <err>` to stderr and `continue` to the next finding. `has_evidence`'s raise-on-bad-shape contract is preserved (the deviation is still surfaced, now as a logged warning rather than a crash), and the documented drop-contract holds (evidence-less findings are dropped, not fatal). Regression-guarded by `tests/testers-pipeline.test.sh` P11 (string + list evidence across one persona; the two well-formed personas' findings survive, both offenders dropped with one stderr warning each).

### Changed
- Version bumped to 0.33.15 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.14] - 2026-05-25

### Fixed
- **`tests/merge.test.sh` reassigned `CMD_FILE` to a relative path mid-suite — cwd-dependent FAILs + a structural false-green in the M87.13 env-var tombstone (#190, uberscan MAJOR).** Line 60 sets `CMD_FILE` to the absolute `$REPO_ROOT/plugins/uberdev/commands/merge.md` and the rest of the 1928-line suite is cwd-independent, but line 1723 silently overwrote it with the relative literal `plugins/uberdev/commands/merge.md` (the only relative path in the file). Run from any dir other than the repo root, M84/M85 emitted spurious FAILs, and — worse — M87.13's negative guard `grep -qE "UBERDEV_${TOKEN}|…" "$CMD_FILE" "$SKILL_FILE"` could not open the unresolved relative `CMD_FILE`, so the tombstone asserting "no env-var variant exists for the deferral flags" PASSED without ever scanning `merge.md`: a future edit reintroducing an env-var variant would slip past the guard whenever the suite ran from a non-root cwd (e.g. a CI scratch dir). The suite passed before only because it happened to be launched from the repo root. Fix: delete line 1723 — the absolute `CMD_FILE` from line 60 is already in scope and correct, so M84/M85/M87.13 now scan `merge.md` regardless of cwd. Regression-proven by running the suite from a non-root cwd (`cd /tmp && bash …/tests/merge.test.sh`) with M84/M85/M87.13 green, then re-running from the repo root.

### Changed
- Version bumped to 0.33.14 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.13] - 2026-05-25

### Fixed
- **`lib/secret-scan.sh` regex fallback could not distinguish a broken scanner from a real match — grep rc≥2 was mis-handled (#189, uberscan MAJOR).** The fallback used `if printf … | grep …; then return 1; fi; return 0`, collapsing grep's tri-state exit (`0`=match, `1`=no-match, `≥2`=regex/I-O error) into a binary. A grep **error** (rc≥2 — e.g. a malformed future pattern making grep exit `2` on every call) fell through to `return 0`, so a broken scanner reported every input as **clean** with no diagnostic (fail-OPEN), and in no case was a scanner error distinguishable from a real secret match. The fallback now captures grep's rc explicitly via `… >&2 || grep_rc=$?` (errexit-safe) and branches: `0`→`return 1` (secret found, fail-CLOSED), `1`→`return 0` (clean), `≥2`→emit a distinct stderr diagnostic naming the scanner failure (never "secret found") and `return` grep's own rc — fail-CLOSED on a code distinct from the match code `1`, so a broken scanner is loud and unmistakable. The gitleaks primary path is unchanged. Regression-locked by new `tests/secret-scan.test.sh` (S1 clean→0, S2 match→1, S3 grep rc≥2→distinct diagnostic + fail-CLOSED), registered in both CI jobs.

### Changed
- Version bumped to 0.33.13 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.12] - 2026-05-25

### Fixed
- **`/uberdev:testers` per-host RPS cap was bypassable and its audit blind to the bypass — rate-limit cluster (#184, #185, #186, #187, #188; uberscan MAJOR ×5).** The runtime wrapper (`lib/rate-limit-curl.sh`) and the post-hoc auditor (`lib/rate-cap-audit.sh`) both keyed per-host buckets/groups on a naive `scheme://([^/?#]+)` authority capture, so `a@host` / `b@host` / `Host` / `host:443` / `host.` each got a DISTINCT bucket — defeating the cap (#184) and letting the same variants evade the audit meant to detect the bypass (#186). Five coherent fixes:
  - **#184 + #186 (shared root cause).** Introduced one canonical host normalizer, `lib/normalize_host.py`, built on `urllib.parse.urlsplit().hostname` (the hardened stdlib URL parser — lowercases, strips userinfo + `:port`, de-brackets IPv6) plus a trailing-dot drop and the historic `..`/`/` scope-escape reject. Both files now key on it (the wrapper calls it as a subprocess; the audit imports it), so all authority variants of one host collapse to a single bucket/group. No more duplicated, drift-prone host parsing.
  - **#185.** `DELAY_MS=$(( (1000 / RPS_CAP) - … ))` truncated `1000/RPS_CAP` to an integer before subtracting elapsed time, under-delaying for any non-integral interval (cap=600 → 1ms instead of 1.667ms, ~67% over cap). The interval is now computed in float (folded into the awk math) and gated on `> 0`.
  - **#187.** The auditor did `cap = int(cap_str)` with no range check (cap=0 flagged every request; a negative cap flagged everything) and raised an uncaught `ValueError` (cryptic traceback) on non-numeric input. It now validates to `[1, 1000]` like the runtime wrapper and exits non-zero with a clear stderr message — no traceback.
  - **#188.** `printf … > "$STATE.tmp" && mv -f …` ignored the `printf` return code; on a failed write the `&&` short-circuited, the state file kept a stale timestamp, and the next call silently re-paced from it. The write rc is now checked and the wrapper fails loud (exit 2) rather than corrupting the rate gate silently.
  - Regression-locked by new assertions in `tests/testers-rate-limit-wrapper.test.sh` (normalizer collapses `a@host`/`Host`/`host:443` identically; wrapper buckets variants into one state dir; cap=600 yields the float delay; a state-write failure surfaces) and `tests/testers-rate-limit-audit.test.sh` (variants group as one host → breach; cap=0/-5/non-numeric rejected). These two suites remain orphaned from CI (tracked separately by #196).

### Changed
- Version bumped to 0.33.12 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.11] - 2026-05-25

### Fixed
- **`/uberdev:ubersimplify` aggregate could be broken out of its spotlighting envelope — prompt-injection into `findings-to-issues` AND `code-fixer` (#183, uberscan CRITICAL).** `skills/ubersimplify-pipeline/aggregate.py` defined its own hand-rolled `_cell()` (and wrote the `<external-untrusted-input>` open/close markers inline) that only collapsed newlines and escaped the `|` delimiter — it did NOT neutralize a literal `</external-untrusted-input>` close-tag. Because `code-simplifier` finding `summary`/`detail` is prose generated over ARBITRARY repo files (attacker-influenceable), a finding whose text contained the literal close-tag terminated the envelope early and promoted the following attacker-derived rows to TRUSTED text — an envelope breakout into both `findings-to-issues` (the `issues` / `ubersimplify-aggregate` path) and `code-fixer` (the `fixer` / `post-impl-review-aggregate` path). Deleted the hand-rolled `_cell()` and the inline envelope writes; `aggregate.py` now imports the hardened shared `cell()` (inserts a U+200B ZWSP after `<`, breaking the verbatim byte sequence the downstream parser scans for) and `envelope()` from `lib/report_primitives.py` — EXACTLY as the sibling reporters (`skills/uberscan-pipeline/report.py`, `skills/testers-pipeline/report.py`) already do. Both aggregate modes now route every field through `cell()` and wrap via `envelope()`. Regression-locked by new D7 tests in `tests/ubersimplify-aggregate.test.sh` mirroring `uberscan-report.test.sh` AC-D7.

### Changed
- Version bumped to 0.33.11 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.10] - 2026-05-25

### Fixed
- **`/uberdev:testers` filed ZERO issues — its Phase-5 envelope source `testers-aggregate` was missing from the `findings-to-issues` closed allow-list (#182).** `skills/testers-pipeline/report.py` wraps the findings-to-issues aggregate as `<external-untrusted-input source="testers-aggregate">`, but `agents/findings-to-issues.md` Step 1 enforces a CLOSED accepted-source set `{post-impl-review-aggregate, simplify-aggregate, ci-refused-synthetic, uberscan-aggregate, ubersimplify-aggregate}` (the pre-fix set) and refuses (`rationale: "input-malformed"`) any aggregate whose leading marker is absent. `testers-aggregate` was not in the set, so every `/uberdev:testers` run's findings-to-issues dispatch was refused and no issues were ever filed — the squad's headline deliverable was silently broken (`/uberscan` and `/ubersimplify` had added their sources; testers was missed). Added `testers-aggregate` to the closed allow-list.

### Changed
- Version bumped to 0.33.10 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.9] - 2026-05-23

### Fixed
- **`/goal` Phase-2 watch loop never advanced on Claude Code CLI 2.1.150 — auto-merged nothing (#180).** The loop keyed solver-completion, PR discovery, and merge detection on stdout markers grepped from the captured `solve-bg-stdout-<N>.log`. On CLI 2.1.150 `claude --bg` detaches in ~4s writing only a launch banner there, so `backgrounded · ` (a *startup* banner, not a terminal marker), `pushed PR #N` (which has **zero** producers — `finish-branch` prints `PR created:`), and the merge gate's read of `merge-bg-stdout-<pr>.log` (a file that is **never written**) could not reflect real state; the loop spun to the 4h `stuck_loop` breaker. Detection is now CLI-version-independent and GitHub-native:
  - PR discovery / solve completion → `gh pr list --json number,closingIssuesReferences,headRefName` (a PR closing issue N, or whose head is `feat/N-…`), via new `uberdev_goal_find_pr_for_issue`.
  - merge completion → `gh pr view <pr> --json state == MERGED`, via new `uberdev_goal_pr_is_merged` / `uberdev_goal_pr_state_gh`. `uberdev_goal_read_merge_result` now consults gh state first, decoupling convergence from the (formerly agent-improvised) `merge_executed` audit-row shape.
  - solver liveness → `claude agents --json` (cwd `solve-issue-N` + busy status), via new `uberdev_goal_agent_busy_for_issue`, used only to tell "still working" from "died".
  - the already-correct file-based contracts are unchanged: the review-pr verdict JSON locator (`uberdev_goal_locate_review_pr_audit_by_pr`), `uberdev_goal_read_trust_signal`, and the flat `.uberdev/audit.jsonl` merge audit. The retired `uberdev_goal_extract_pr_num_from_log` (`pushed PR #N` parser) is removed.
- **`/goal` review timing (#180).** The leaf solver runs its OWN `/review-pr` ~20 min after pushing and frequently goes idle in that window, so "agent idle ⇒ review done" is false. Phase 2 now waits `_UBERDEV_GOAL_REVIEW_GRACE` (30 min, re-read every poll) for the leaf's verdict before dispatching its own `/review-pr` — eliminating redundant reviews and premature red-holds of a PR whose GREEN verdict simply has not landed.
- **`/goal` requires bash ≥ 4 with a clear preflight error (#180).** macOS's default `/bin/bash` is 3.2 (no `mapfile`/`declare -A`) and zsh fatals on the verdict locator's unmatched-glob iteration. Phase 0 now refuses anything below bash 4 (`brew install bash`); Phase 3 replaced `mapfile` with a portable `while read` loop.
- **`/merge` `merge_executed` audit row now has a concrete printf template (#180).** Previously agent-improvised with no guaranteed `data.pr`; now emitted success-only (a failed merge emits `error`, never `merge_executed`, so it can never falsely advance `/goal`).
- **`/solve` + `/turbo` claim protocol aborted on every repo — `uberdev:active` label description exceeded GitHub's 100-char limit.** `UBERDEV_ACTIVE_LABEL_DESCRIPTION` was 107 chars; `gh label create --force` returns HTTP 422 above 100 (on create *and* force-update of an existing label), so the fail-loud claim provisioning (`solve-pipeline/SKILL.md` Step 4.5) aborted with "no agents dispatched". Trimmed to ≤100 chars.
- **`/review-pr` + findings-to-issues label descriptions exceeded the same 100-char limit.** The YELLOW trust-label description (141 chars, fail-loud → aborted `/review-pr` trust-signal emission on deferred-CRITICAL verdicts) and the finding-label description (137 chars, fail-soft → finding labels unprovisioned on fresh repos) were both trimmed ≤100 chars. A repo-wide audit now shows zero label descriptions over the limit.

### Changed
- Version bumped to 0.33.9 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.8] - 2026-05-23

### Added
- **`/uberscan` hardening (#166).** Extracted schema-agnostic report primitives into `plugins/uberdev/lib/report_primitives.py` (hardened `cell()` escaper, parameterized `<external-untrusted-input>` envelope emitter, rank-parameterized deterministic sort helper); both `report.py` files now import it in-process (`sys.path.insert` from `__file__`). `SEV_RANK` stays pipeline-local (uberscan `important=2`, testers `important=1`) — NOT unified. Added a `totals.json` sidecar (emitted under `$RUN_DIR`, incl. `--no-report` mode) that Phase 4 reads via a single `jq`, replacing the grep-the-rendered-report + python-recount paths. Surfaced repo-global Semgrep (`research-security`) + coverage (`research-test-coverage`) findings into the findings-to-issues aggregate (enveloped + escaped, `disposition: DEFERRED`).

### Fixed
- **Envelope close-tag breakout (security, MEDIUM, D7).** The shared `cell()` now neutralizes a literal `</external-untrusted-input>` so an injected finding cannot close the spotlighting envelope early and promote attacker-derived rows to trusted prose. `testers-pipeline/report.py`'s aggregate now carries the spotlighting envelope it previously lacked (security.md #8).

### Changed
- **Closed five `/uberscan` test-coverage gaps** (dedupe 3+ reviewers, `norm()` unicode/emoji/tab, `cell()` newline/None, hotspot >15 deterministic truncation, chunk directory-grouping contents) and **registered the previously-orphaned `uberscan.test.sh` / `uberscan-report.test.sh` / `uberscan-chunk.test.sh` in CI** (ubuntu-latest only; Windows-skip documented). Collapsed Phase 0/1 manifest `jq` reads into one `@tsv` read and de-duplicated the `config-read.sh` sourcing. Closes #166.

## [0.33.7] - 2026-05-22

### Fixed
- **Pipeline run-state evaporated across fresh-shell Bash calls (`/goal` silent state-machine no-op).** Each Bash tool call is a fresh shell, and the goal-pipeline watch loop structurally forces call boundaries, so the Phase-0 `GOAL_ID` pointer, loop accumulators (`cycle`/`watch_start`/`overflow_count`/`overflow_detected`), and sourced `uberdev_goal_*` definitions evaporated before Phases 1–4 — `$GOAL_ID` resolved empty (per-goal TSV paths degraded to `goal--*.tsv`) and `uberdev_goal_*` calls hit "command not found", silently no-op'ing state-machine transitions and circuit-breaker accounting. Added `uberdev_goal_write_run_state` / `uberdev_goal_read_run_state` / `uberdev_goal_cleanup_run_state` to `lib/goal-state.sh` — a hardened `KEY=value` sidecar under `$UBERDEV_TMPDIR`, written atomically via the #155 TOCTOU-safe `_uberdev_dispatch_prepare_tmp_target` and read back with per-field-validating loops (never `source`/`eval`, never `mapfile`; bash-3.2/zsh portable). goal-pipeline now re-sources the three libs and re-reads run-state at the top of every later phase block; sibling pipelines get the lighter re-source-per-block treatment. The TSV-keyed-by-`GOAL_ID` model (PR #129) is unchanged. (#171)

## [0.33.6] - 2026-05-22

### Fixed
- **`/goal` first-dispatch crash (rc=126).** Extracted the six dispatch-env vars (`TIMEOUT_BIN`, `SOLVE_TIMEOUT`, `MODEL`, `PERM_FLAG`, `EFFORT_FLAG`, `BG_PROMPT_MODE`) from solve-pipeline Phase A into a shared sourced helper `uberdev_dispatch_resolve_env()` in `lib/dispatch.sh`, now called by both solve-pipeline and goal-pipeline. goal-pipeline previously sourced `lib/dispatch.sh` and called `uberdev_dispatch_preflight` (backend only) but never established the env vars, so its first `uberdev_dispatch_one` exec'd an empty `$TIMEOUT_BIN` and failed with `permission denied` (rc=126). The helper mirrors `/turbo`'s unattended dispatch env (`AUTO_MODE=1`, `AUTO_PERMISSIONS=0`, `EFFORT_LEVEL=max`) and preserves the verbatim fail-loud `timeout(1)`/`gtimeout(1)` probe guard. Backend resolution (`UBERDEV_RESOLVED_BACKEND`) is unchanged (RFC 0005 D15). (#175)

## [0.33.5] - 2026-05-22

### Changed
- **De-monolithed the `AUDIT_EVENT_ENUM` Constants cell in `skills/merge-pipeline/SKILL.md` (#119).** The cell was a single ~5131-char line (enum literals + ~3500 chars of field-level prose + member-addition history) — unscannable, and every new audit event made it worse. The ~3500 chars of prose moved into a dedicated `### AUDIT_EVENT_ENUM — event semantics & member history` subsection (with paragraph breaks per member cohort); the **canonical comma-separated list of event literals stays in the table cell** (now ~1274 chars) so the M-row grep-the-row tests (`merge.test.sh` M23/M52/M74/M75/M76 across 6 test files) keep resolving unchanged. `merge.test.sh` M76 was repointed at the relocated subsection; new M88 locks the refactor (row points at the subsection; prose no longer monolithic). No behaviour change. Closes #119.

## [0.33.4] - 2026-05-22

### Fixed
- **Aligned the stale alias enumerations in `skills/using-uberdev/SKILL.md` with the installed set (#162).** The "Auto-installed aliases" line said "**six** … (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`)" — missing `/dev`, `/testers`, `/ubergoal`, `/uberscan`, `/ubersimplify` (the set has grown to **eleven**); now lists all eleven. The `auto_install_aliases` config-example comment was de-enumerated (points at `aliases-sync.sh` as the canonical set) to stop it drifting again. `aliases-sync.sh` and the README already listed eleven. Docs-only; no behaviour change. Closes #162.

## [0.33.3] - 2026-05-22

### Security
- **Hardened the predictable `$UBERDEV_TMPDIR` dispatch paths against TOCTOU symlink-swap / pre-creation (#155).** `lib/dispatch.sh` writes `solve-bg-stdout-<issue>.log` and `solve-bg-status-<issue>.json[.pid]` to a world-writable tmpdir at intentionally predictable paths (the `/goal` watcher polls them by name, so `mktemp`-randomisation isn't an option). An attacker could pre-create a symlink there to clobber a victim file or feed attacker-chosen bytes into the `DISPATCH_ID` extraction. New `_uberdev_dispatch_tmp_target_safe` guard rejects a symlink, a foreign-owned entry, or a non-regular file at the predicted path; `_uberdev_dispatch_prepare_tmp_target` then re-creates the file `0600` under `set -C` (noclobber) so the sticky-bit dir protects it from a later swap (and the guard fails CLOSED when ownership is undeterminable — e.g. a minimal `stat` lacking both `-f` and `-c`). **All three** dispatch backends (`claude-bg`, `background`, `wezterm`) fail-CLOSED (rc=3 + `dispatch_setup_failed` audit with `phase ∈ {tmp_target_unsafe, tmp_target_create, pid_target_unsafe}`) instead of writing through. Success path unchanged. Regression fixture in `tests/dispatch-claude-bg.test.sh` (symlink pre-creation → fail-closed). Closes #155.

## [0.33.2] - 2026-05-22

### Fixed
- **`/uberdev:review-pr` now provisions the trust label before adding it (#170).** GREEN/YELLOW runs add `uberdev-approved` / `uberdev-approved-with-concerns` via `gh pr edit --add-label`, which CANNOT auto-create a repo label and exits non-zero when it is missing — so on a fresh repo (or any repo where the trust labels were never created) the first GREEN/YELLOW run aborted the entire trust-signal emission with `exit 2`. Each label is now provisioned fail-loud via `gh label create --force` (idempotent — updates colour/description, never errors on "already exists") with a per-tier colour/description immediately before the add. Same assume-label-exists class as #168; surfaced by PR #169. Regression-tested in `tests/review-pr.test.sh` (R9.16/R9.16b). Closes #170.

## [0.33.1] - 2026-05-22

### Fixed
- **`/solve` `/turbo` claim protocol (Step 4.5): `gh label create --force` for the `uberdev:active` label is now fail-loud.** It previously swallowed failures with `|| true`, but the per-issue combined `gh issue edit --add-label --add-assignee` write hard-depends on the label existing — gh cannot auto-create a label from `--add-label` and fails the combined mutation *atomically* when it is missing. A transient or permission-related create failure was therefore silenced, then resurfaced downstream as a misleading `failed to write claim (label or assignee) — check gh auth` abort that pointed the operator at the wrong cause. `--force` already guarantees idempotency (it updates colour/description on "already exists", never errors), so a non-zero exit is *always* a genuine failure (auth gap, missing repo write/triage scope, API/network error). It now captures gh's stderr, emits `claim_write_failed{step:label_create}`, and exits 1 before any claim is written (so no rollback is needed). The combined claim write (E1) is unchanged. Unlike the fail-soft `gh label create` in `finish-branch` / `dev-pipeline` / `findings-to-issues` (where the dependent `--add-label` is also fail-soft and the label is a nice-to-have), here the label is the canonical claim signal gating a fail-loud write. Regression-tested in `tests/solve-claim.test.sh` (4 new assertions). Closes #168.

## [0.33.0] - 2026-05-22

### Added
- `/uberdev:ubersimplify` — whole-codebase 3-lens simplification (Reuse/Quality/Efficiency). Chunks the repo (shared `lib/chunk.py`), audits each chunk with the `code-simplifier` lenses in concurrent waves, applies preserve-behavior fixes via `code-fixer` as one `refactor:` commit per chunk on a new branch, opens ONE PR, and files leftover blocker findings as GitHub issues (`ubersimplify-finding` label). `--audit-only` for a read-only scan. Seven circuit breakers bound cost (RFC 0008).
- `/ubersimplify` short-form alias for `/uberdev:ubersimplify` (alias count 10 → 11).
- `findings-to-issues`: `ubersimplify-aggregate` accepted source.

### Changed
- `chunk.py` moved from `skills/uberscan-pipeline/` to `lib/chunk.py` (shared by `/uberscan` and `/ubersimplify`; path-only, behavior unchanged).

## [0.32.0] - 2026-05-22

### Added
- `/uberdev:uberscan` — whole-codebase read-only audit. Chunks the repo, runs the `/review-pr` Phase-1 reviewer fleet (6 reviewers) per chunk + a repo-global Semgrep/test-coverage pass, aggregates into a markdown report, and files deduped GitHub issues (`uberscan-finding` label). Never writes code. Whole-repo by default, path-scopable; seven circuit breakers bound cost (RFC 0007). Simplify lenses intentionally excluded (separate command).
- `/uberscan` short-form alias for `/uberdev:uberscan`.
- `findings-to-issues`: `finding_label` / `finding_marker_slug` / `source_ref` inputs + `uberscan-aggregate` source (back-compatible defaults preserve `/review-pr` behavior).

## [0.31.0] - 2026-05-21

### Added
- `/uberdev:goal` — autonomous convergence orchestrator (RFC 0005). Chains `/turbo` → `/review-pr` (auto) → `/merge` if GREEN; recurses on BLOCKER/CRITICAL `review-pr-finding` issues until convergence or one of seven circuit breakers fires.
- Seven circuit breakers: `max_cycles` (default 5, range 1–20 via `UBERDEV_GOAL_MAX_CYCLES`), `nonconvergence` (fingerprint repeat from prior cycle), `stuck_loop` (4h goal-level wall-clock), `merge_failed` (conflict or hook failure), `gh_api_failed` (Phase 3 `gh issue list` or `gh api user` rc!=0 — surfaces transient rate-limit / network errors instead of falsely emitting `goal_converged`), `unknown_merge_result` (Phase 2c default-arm guard against `uberdev_goal_read_merge_result` returning a value outside the documented `success|conflict|hook_failed|missing` set — contract-drift halt), `queue_empty_not_converged` (deterministic Phase 3 halt when the candidate queue is empty but at least one PR remains in a non-terminal in-flight state — alternative to spinning until the 4h `stuck_loop` fallback).
- `/ubergoal` short-form alias for `/uberdev:goal` (installed by `/uberdev:install-aliases`).
- `lib/goal-state.sh` — PR + issue state machines, per-goal audit-sink JSONL at `$UBERDEV_TMPDIR/goal-<id>.jsonl`.
- `skills/goal-pipeline/SKILL.md` — 5-phase pipeline (Preflight → Dispatch → Watch → Collect-Next → Converge/Halt).
- `tests/goal.test.sh` — 20-section shape-check harness (G1–G20).
- **`/uberdev:testers`** — adversarial multi-persona QA audit squad. 6 distinct-persona testers (`panicked_grandma`, `power_user`, `adversarial_security`, `chaos_engineer`, `a11y_critic`, `mobile_thumb`) + 2 monitors (`monitor_primary`, `monitor_devils_advocate`) over 3 coordinated waves. Auto-detects target surface (web/api/native/all). Findings are evidence-anchored against a 10-invariant oracle library and filed as GitHub issues via the existing `findings-to-issues` pipeline. Read-only — the squad never writes app code. Alias: `/testers`. See `docs/rfc/0006-testers-command.md`.

### Changed
- Plugin version bumped from `v0.30.4` to `v0.31.0`.
- `tests/solve-claim.test.sh:258-265` version-drift assertions updated to `0.31.0`.

### Security
- `Blocks: #` parser is ReDoS-safe (anchored bash regex + 64 KiB body cap).
- `/merge` auto-chain is scoped to `/goal` only via `UBERDEV_GOAL_ID` env-var provenance check (T5).
- Per-PR `automerge_attempt_count >= 3` short-circuits `uberdev_goal_should_automerge` so the goal stops re-dispatching `/merge` for that PR (the runaway-loop containment, R5). The PR sits in `green` until `max_cycles` fires or the operator intervenes; no `merge_failed` halt is emitted.

## [0.30.4] - 2026-05-21

### Documentation

- **README install paragraph: align alias count with reality.** The auto-install paragraph said "seven short-form aliases" and only listed `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`, `/dev` — `/testers` (auto-installed since v0.30.0 via `aliases-sync.sh`) was missing. Now lists all eight (`/testers` added) and the count matches `UBERDEV_ALIAS_NOTICE` runtime emit ("installed 8 short-form aliases").

## [0.30.3] - 2026-05-21

### Fixed (#143)

- **dispatch:** `claude --bg` id extraction now strips ANSI CSI escapes before
  the marker grep, fixing false-positive `DISPATCH_RC=2`
  (`dispatch_setup_failed phase=id_extract`) on Claude Code 2.1.146+ where
  the bg session id is wrapped in cyan SGR codes (`\x1B[36m<id>\x1B[39m`).
  Defense-in-depth: line-anchored marker re-grep + hex-only scrub on the
  extracted id closes OSC/DCS injection surfaces. B3 fail-CLOSED guard
  preserved — genuinely missing markers still surface as rc=2. Combined with
  the #154 rc-capture fix (grep-own-rc + subphase discriminator) from v0.30.2.
  Closes #143.

## [0.30.2] - 2026-05-21

### Fixed (#154)

- **`claude --bg` dispatch id-extraction no longer silently masks pipeline failures.** `lib/dispatch.sh`'s `DISPATCH_ID` extraction (`grep -oE 'backgrounded · <id>' | awk | head`) swallowed pipeline-level errors (sed/grep failure ≠ "no match") into an empty `DISPATCH_ID`, so the B3 guard surfaced `rc=2 phase=id_extract` identically for transient infra failure and persistent format drift. Now captures grep's own rc and adds a distinct subphase discriminator to the `dispatch_setup_failed` audit JSON so incident responders can tell a retryable transient failure from a non-retryable `claude --bg` output-format change. (PR #158)

## v0.30.1 — 2026-05-21

### Fixed (#133)

- **`/uberdev:testers` `--rps-cap` is now actually enforced.** Previously parsed and serialised but no layer enforced it; a run with `--rps-cap=5` could let any persona fire 50+ req/sec at the target. Now:
  - Pre-emptive (hard cap) via `plugins/uberdev/lib/rate-limit-curl.sh` (token-bucket, per-host, `mkdir`-as-mutex) for `Bash(curl*)` traffic.
  - Post-hoc audit via `plugins/uberdev/lib/rate-cap-audit.sh` for Playwright / browser-MCP traffic that cannot be HTTP-wrapped; a breach synthesises a `critical` `polite_rate_cap` finding and the run exits 1.
  - Parse-site input validation: anchored regex `^[1-9][0-9]*$`, range `[1, 1000]`, `exit 2` on bad input. Closes a MAJOR-severity argv-injection surface.
  - URL flag-smuggling neutralised: wrapper invokes `command curl <args> -- "$URL"`.

### Breaking (internal CLI)

- `aggregate.py --rps-cap=N` is now a **required** flag. Direct callers outside SKILL.md must pass it explicitly. SKILL.md's invocation has been updated. The previous default (no flag) silently disabled the audit; making it required ensures the audit always runs.

### Documentation (#133)

- RFC 0006 §Risks rewritten to match the implementation: hard cap for curl, post-hoc audit fail-the-run for MCP, with the single-wave detection-latency caveat made explicit. Removes the misleading "limit the exfil bandwidth" framing.
- All 6 testers persona agent files (`testers-adversarial-security`, `testers-a11y-critic`, `testers-chaos-engineer`, `testers-mobile-thumb`, `testers-panicked-grandma`, `testers-power-user`) carry a uniform Polite-rate clause naming the wrapper, the audit, and the populate-`timestamp` directive.

## [0.30.0] - 2026-05-19

### Added

- **Cross-platform dispatch backends for `/solve` and `/turbo` (RFC 0004).** A `dispatch_backend` abstraction with three tested backends — `claude-bg` (today's default), `wezterm` (visible panes, opt-in), and `background` (dependency-free fallback) — selected by a platform-aware fallback chain (macOS → `[wezterm, claude-bg]`; native Windows → `[wezterm, background]`; WSL2 → `[claude-bg]`). New `--backend=` CLI flag and `dispatch_backend:` config key let users override the resolved backend per invocation or per repo.
- **Native Windows hardening of the bash dispatch pipeline.** Coreutils-first `TIMEOUT_BIN` probe (no more accidentally invoking `System32\timeout.exe`), `MSYS_NO_PATHCONV` wrap around path arguments, a single `UBERDEV_TMPDIR` replacing every hardcoded `/tmp/`, a native-Windows-without-bash fast-fail, and a WSL2 `/mnt` slowness warning. New `windows-latest` shape-check CI job covers the regression surface.
- **New `lib/dispatch.sh` module** sourcing `uberdev_dispatch_preflight` + `uberdev_dispatch_one` + three backend functions; `solve-pipeline/SKILL.md` Step 5b' rewired to call it.

### Why

`/solve` and `/turbo` were silently macOS-and-WSL2-only because the dispatch path hardcoded `claude --bg` and `/tmp/`. RFC 0004 introduces a platform-aware backend abstraction so the same commands work end-to-end on macOS, WSL2, and native Windows (Git Bash). See `docs/rfc/0004-cross-platform-dispatch-backends.md`. Known limitation: on hosts with a pre-existing `~/.wezterm.lua`, the appended Lua config is unreachable if the existing file contains its own `return config` (first-return-wins) — users with custom WezTerm configs must integrate the managed values by hand for now.

## [0.29.0] - 2026-05-19

### Fixed

- **Alias auto-install no longer silently depends on `jq`.** The `SessionStart` hook (`plugins/uberdev/hooks/session-start`) hard-requires `jq` to JSON-encode its context injection and `exit 0`s early when `jq` is absent — previously *before* the auto-alias-sync block ever ran, so a new user on a machine without `jq` got zero short-form aliases (`/issue`, `/solve`, `/turbo`, …) and no warning. The alias-sync block now runs **before** the `jq` guard, and `lib/aliases-sync.sh` no longer calls `jq` at all: its one use (`jq -r .version` on `plugin.json`) is replaced by a jq-free `_aliases_read_version()` `sed` parse of the plugin's own manifest. Forwarders now install regardless of `jq`. See `docs/rfc/0011-alias-install-reliability.md`.

### Added

- **Alias-install outcomes are surfaced in the session context.** `aliases_sync_main` now composes a `UBERDEV_ALIAS_NOTICE` that the `SessionStart` hook injects as an `<important-reminder>`: a first-run summary, a collision notice naming any alias skipped because a non-uberdev file already occupies its short name (with the resolution steps), or a write-failure notice. Previously this went only to `stderr` and only on first run, so a skipped `/turbo` was invisible. The notice is conditional — empty in steady state, so post-first-run sessions stay silent.
- **When `jq` is absent the hook now emits a fixed notice** (`uberdev: jq not found …`) instead of a silently-empty context, making the jq-missing degradation visible.
- **`tests/aliases.test.sh` — new cases S10–S14:** `_aliases_read_version` parity with `jq -r .version`, `aliases_sync_main` notice composition, jq-masked install (all seven forwarders install with `jq` off `PATH`), and collision / first-run notices reaching the context injection.

### Why

`README.md` already promised the seven aliases are "auto-installed on first session" — but the auto-sync was fail-open and silent, so on a jq-less machine or a short-name collision the user got less than promised with no signal. This release closes that reliability gap against the stated contract: aliases install unconditionally, and any skip or failure is reported. Claude Code has no install-time plugin hook (feature request anthropics/claude-code#11240, closed unshipped), so the `SessionStart` hook remains the provisioning mechanism — it is hardened, not replaced. Deliberately out of scope and deferred: content-hash idempotency, retry of a previously-skipped alias, and `install.sh`-side provisioning.

## [0.28.0] - 2026-05-18

### Added

- **Small-team issue-claim protocol for `/solve` and `/turbo`.** On dispatch, the launcher (`plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 4.5) now marks each target issue ACTIVE on GitHub with three coordinated writes (in sequence with rollback on partial failure — not atomic): the `uberdev:active` label (queryable via `gh issue list --label uberdev:active`), the `@me` assignee (native GitHub UI signal — matches what `gh api user --jq .login` resolves to), and an HTML-comment-fingerprinted audit comment carrying dispatcher username, hostname, branch (`worktree-solve-issue-N`), tier, and ISO-8601 timestamp. Concurrent teammates running `/solve` or `/turbo` on overlapping issue numbers get a hard refusal showing who/where/when, instead of racing into divergent worktrees and duplicate PRs. The fail-loud claim-write contract (any `gh` permission gap aborts the batch and rolls back prior writes) prevents the silent-partial-claim mode that would defeat collision prevention.
- **`--force` / `-f` override flag on `/solve` and `/turbo`.** Bypasses the claim-collision refusal for stale-claim recovery (e.g. a teammate's machine crashed mid-run leaving the label stuck). Anchored token regex `^(--force|-f)$` — flag fragments inside larger tokens (`--force-foo`) do NOT match. Overrides are recorded as `claim_force_override` audit events so post-hoc grep can distinguish intentional recoveries from regressions.
- **Auto-cleanup of `uberdev:active` on `/merge`** (`plugins/uberdev/skills/merge-pipeline/SKILL.md` Step 3.4 — NEW; the prior Step 3.4 "Failure-mode summary" renumbered to 3.5). After a successful `gh pr merge` (clean-merge or conflict-resolve path), the merged PR body is parsed for the documented GitHub closing keywords (`close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved` followed by `#N`, case-insensitive, with a left word-boundary anchor so `preclose #42` / `postfix #100` do NOT false-match — added in #123 B1 follow-up) and the `uberdev:active` label is removed from each linked issue. The cleanup loop ALSO clears the `@me` assignee for each linked issue (symmetric with the Phase B dispatch-failure rollback in solve-pipeline; without this the dispatcher's "Assigned to me" GitHub filter accumulates closed-and-merged issues over time — fixed in #123 B5 follow-up). Cross-repo `org/repo#N` references are intentionally not parsed (the claim protocol only applies to issues in the current repo). Failure-soft: a PR with no closing keywords is a no-op; a `gh issue edit` failure is silently ignored (the dispatch-time stale-claim sweeper in solve-pipeline Step 4 picks up anything `/merge` misses).
- **Dispatch-failure rollback in Phase B.** When `claude --bg` returns non-zero (e.g. model unavailable, worktree creation failed, gtimeout exec failure), the claim acquired in Step 4.5 is now released immediately: label removed, assignee cleared, a release-comment is posted (same `CLAIM_COMMENT_MARKER` fingerprint so future collision checks see the latest claim event as a release). Rollback first re-fetches the latest claim comment and verifies the `User:` line still names this dispatcher — if a teammate raced in and won the claim between Step 4.5 and the dispatch-failure window (e.g. via `--force` after seeing a stuck label from a different bug), rollback **skips** the strip and logs a warning instead of stealing the racing dispatcher's claim (#123 B3 follow-up). Without all of this, a crashed dispatcher would orphan the claim and force every teammate to use `--force` for that issue indefinitely.
- **Five new `SOLVE_AUDIT_EVENT_ENUM` members** in solve-pipeline: `claim_acquired`, `claim_collision`, `claim_force_override`, `claim_write_failed`, `claim_released`. Plus one new `AUDIT_EVENT_ENUM` member in merge-pipeline: `uberdev_active_label_cleared` (with `data.issue: int`, `data.pr: int`, `data.reason: "merge"`).
- **`tests/solve-claim.test.sh`.** Structural-grep coverage for the constants binding, --force parser, JSON-projection extension, collision check (jq + grep field extraction), claim-write loop fail-loud structure, Phase B dispatch-failure rollback, all five new audit-event emission sites + enum membership, merge-pipeline Step 3.4/3.5 rename, command-file documentation, and the version-bump drift check. Wired into the CI `&&`-chain in `.github/workflows/test.yml`. Includes a negative regression guard that no `Co-Authored-By: Claude` or `Generated with Claude Code` strings leak into the claim or release comment bodies (per global `CLAUDE.md`).

### Why

UberDev was originally built for a solo developer for whom GitHub issues function as a personal TODO queue — no coordination needed. With even a single teammate, two concurrent `/turbo 5 6 7` invocations on overlapping issue lists silently produced two divergent worktrees, two PRs, and wasted effort that surfaced only at merge time. The claim protocol adds the missing coordination primitive without standing up new infrastructure: GitHub itself is the coordination surface (label + assignee + comment), and the protocol is opt-out-by-`--force` for stale-claim recovery.

The refusal fires on ANY claim collision — including same-machine re-runs. This is deliberate: accidentally re-dispatching `/turbo 42` from the same laptop while the first run is still going would race two bg sessions into the same worktree, which is the same failure mode as the cross-teammate collision the protocol exists to prevent. After a manual `claude agents stop`, the operator passes `--force` as the deliberate "yes I really want to re-dispatch" gesture; the override is auditable so post-hoc review can spot patterns (recovery from real failures vs. accidental retries that should have used a different approach).

**Known limitation — TOCTOU race window (#123 B2).** The Step 4 collision-check read and Step 4.5 claim-write happen in separate gh round-trips. Two dispatchers running concurrently against the same issue can both observe "no label present" in their Step 4 reads and both write the label in Step 4.5 — `gh issue edit --add-label` is idempotent on the GitHub side. The protocol is **best-effort, not atomic**; the race window is bounded by gh round-trip latency (tens to hundreds of ms). For the small-team usage this targets, that's acceptable. Larger-team operators or workflows that need a strong distributed lock should NOT rely on this protocol — a post-write verification step (re-fetch latest claim comment, refuse if a different dispatcher's marker won) would close the window at the cost of one extra round-trip per issue and is deferred until measured contention warrants it.

### Fixed

- **`/merge` Phase 1.4 PATH_2 sub-condition (c.0) audit-JSON discovery now traverses ALL worktree-local mirror paths.** The bash discovery glob at `plugins/uberdev/skills/merge-pipeline/SKILL.md` Step (c.0) only searched `.uberdev/runs/*/review-pr-verdict.json` relative to `/merge`'s CWD. When `/merge` ran from the main checkout but the PR was produced by ANY worktree-based flow (`/solve` and `/turbo` per `solve-pipeline/SKILL.md`'s `.claude/worktrees/solve-issue-N/`, OR `subagent-driven-dev` / `executing-plans` / brainstorm-Phase-4 per the generic `using-git-worktrees/SKILL.md`'s `.worktrees/` preferred + `worktrees/` alternate conventions), `/review-pr` wrote the audit JSON inside that worktree's gitignored `.uberdev/runs/` — invisible from the main-checkout glob. `trust-trail-evaluator` was then dispatched with `phase2_5_present=false`, which per its Step 1.5 short-circuits to `STALE`, gating otherwise-valid trust trails. Step (c.0) bash and sub-condition (d) prose now glob the full four-layout enumeration: `.uberdev/runs/`, `.claude/worktrees/*/.uberdev/runs/`, `.worktrees/*/.uberdev/runs/`, `worktrees/*/.uberdev/runs/`. The `~/.config/uberdev/worktrees/<project>/<branch>/` global-fallback layout (also declared in `using-git-worktrees/SKILL.md`) is intentionally NOT globbed — it lives outside the project root and would require runtime `$HOME` resolution; deferred to the writer-side path-anchoring follow-up (anchor `/review-pr`'s artifact writer on `git rev-parse --show-toplevel`, mirroring the convention in `orchestrator/SKILL.md`). The RUN_ID_REGEX basename-of-dirname projection (D4/F8 path-traversal hardening) works identically on all four layouts because the prefix segments are never concatenated from untrusted input — no security regression. New `M63.worktree-glob.{c0.compgen,c0.forloop,c0.or-operator,d,cm}` structural-grep assertions in `tests/merge.test.sh` lock the fix in five places (compgen-OR chain + for-loop iteration + OR-operator semantics + sub-condition (d) prose + Common Mistakes bullet). Observed twice locally on worktree-produced PRs; manual `cp` workaround retired.

## [0.27.0] - 2026-05-16

### Added

- **`/uberdev:dev` — prototype fast-lane command (short alias `/dev`).** Builds a minimal working prototype or small function from a free-text idea, deliberately skipping the spec → plan → full `/review-pr` pipeline that `/solve` and `/turbo` run. The output is honestly labelled: a `prototype`-labelled PR plus an auto-filed harden issue with a tracked path back to production. Closes #120.
- **Backing skill `uberdev:dev-pipeline`.** A 7-phase Phase 0–6 in-session pipeline running on a `proto/<slug>` branch, with parallel `Task()` subagents dispatched in a single message.
- **Two-column Quality Contract.** The relaxed column is the harden-issue backlog — edge cases, TDD depth, abstractions, and similar rigor are explicitly deferred for prototype code. The hard floors hold: security, secret-handling, crash-hiding, and "the code must actually run".
- **Meta-quality.** The `/dev` implementation itself meets the full AAA quality bar; the relaxed column applies only to `/dev`'s future prototype output, never to `/dev`'s own code.
- **`/dev` short-form alias.** Registered via the `ALIASES` SSOT in `lib/aliases-sync.sh`; auto-installed on first session and refreshed on plugin upgrade alongside the existing six aliases.
- **`docs/rfc/0003-dev-command.md`.** The design RFC for the `/dev` fast-lane command.
- **`tests/dev.test.sh` + `tests/dev-pipeline.test.sh`.** Structural-grep shape-check coverage for the command-file frontmatter contract and the skill's 7-phase structure, security regression locks (no `git add -A`, explicit-path staging), and the scope gate. Both wired into the CI `&&`-chain in `.github/workflows/test.yml`. `tests/aliases.test.sh` extended to exercise install/uninstall/collision for `/dev`.

### Security

- **Slug sanitization gate in `dev-pipeline`.** Free-text ideas are reduced to a kebab `<slug>` via a derive-then-validate allow-list (`^[a-z0-9]+(-[a-z0-9]+)*$`, 48-char cap) with a `git check-ref-format` belt-and-braces check before any `git checkout -b proto/<slug>` — closing shell-word-split and git-ref-injection surfaces. All `gh` bodies are delivered via `--body-file -` (never `--body "$VAR"`); the idea text is wrapped in `<external-untrusted-input source="dev-idea">` envelopes in every subagent prompt.

## [0.26.1] - 2026-05-14

### Added (test coverage)

- **T1–T7 — structural-grep tests for RFC 0002 surfaces.** Locks the GREEN/YELLOW/RED predicate prose and `phases.phase2_5` audit JSON schema in `commands/review-pr.md` (T1, T2); the `halted` + `by_severity` + per-URL `tier` return-contract fields in `agents/findings-to-issues.md` (T3, T6); the three new `/merge` override flags (`--accept-blocker-deferred`, `--accept-critical-deferred`, `--i-know-what-im-doing`) in both `commands/merge.md` and `skills/merge-pipeline/SKILL.md` (T4); the `ci-code-fixer` REFUSED halt path in `commands/review-pr.md` Phase 3 6c.5 (T5); the broken-feature overflow guard in `agents/findings-to-issues.md` Step 6 (T6); and the `trust-trail-evaluator` Phase 2.5 gate (Step 1.5) in a new `tests/trust-trail-evaluator.test.sh` file (T7).
- **First structural-grep coverage for `agents/trust-trail-evaluator.md`.** The agent was previously uncovered; T7 introduces the dedicated test file mirroring the per-agent-file convention used elsewhere in `tests/`.

### Added (observability)

- **O1 — `audit_json_phase2_5_parse_failure` audit event.** Distinguishes legacy audit (no event, fail-open) from malformed audit JSON (emits `audit_json_phase2_5_parse_failure` with truncated `data.jq_error` and `data.audit_path`). Extends `AUDIT_EVENT_ENUM` in `skills/merge-pipeline/SKILL.md` (+ M86.8 containment assertion in `tests/merge.test.sh`). Fail-open preserved — parse failure is auditable but does NOT halt.
- **O2 — `author_lookup_failed` return field on `findings-to-issues`.** Captures `gh pr view <N> --json author` exit-code failure into a typed boolean return field. Adds integer regex guard (`[[ "$pr_number" =~ ^[0-9]+$ ]]`) before the `gh` call (security defence-in-depth).
- **O3 — Explicit-bash ToolSearch fail-fast in `review-pr.md` Step 6b.1.** Concretizes the prior prose contract ("If `ToolSearch` fails, `/review-pr` aborts — NEVER silently auto-pick") into deterministic shell that emits the audit event via the project's pseudo-shell form `audit halt_tool_unavailable data.tool="AskUserQuestion"` and exits 1. Mirrors the existing 6c.6 HALT pattern. The `halt_tool_unavailable` event joins `AUDIT_EVENT_ENUM` alongside `audit_json_phase2_5_parse_failure` (+ M86.9 grep assertion in `tests/merge.test.sh`).
- **O4 — `is_transient` field on `blocked_by_dedupe[]` entries.** Splits `gh issue create` write failures into transient (rc=429, HTTP 5xx, rate limit, secondary rate) vs permanent (everything else; conservative default). 200-char stderr truncation preserved (security Note B).
- **O5 — CI-REFUSED issue creation refactored to `findings-to-issues` dispatch.** Replaces the inline `gh issue create` shell in `commands/review-pr.md` Phase 3 6c.5 with a `Task(subagent_type: uberdev:findings-to-issues)` dispatch carrying a synthetic single-row aggregate wrapped in `<external-untrusted-input source="ci-refused-synthetic">`. Eliminates prose-drift risk between the two issue-creation sites. The issue title prefix shifts from `[ci-refused] $signal_anchor — $rationale` (pre-O5) to `[finding] $file_path:$line — $summary` (post-O5) to share the agent's standard CRITICAL-tier title shape; body, labels, and the `ci_refused_issue_url` audit field are unchanged.

### Notes

- **T8 (synthetic-PR fixture-runner integration test) and T9 (AskUserQuestion halt-choice integration test) remain deferred to v0.27 per issue #116.** Both require a 350–560-line fixture-runner harness that does not yet exist; tracked in #116 surfacing in this release's PR description as a known gap.

## [0.26.0] - 2026-05-14

### Changed (BREAKING — trust-trail contract)

- **`/uberdev:review-pr` Phase 2.5 promoted from advisory to severity-tiered gating (RFC 0002).** The findings-to-issues sub-phase (added in PR #112, v0.24.0) previously declared `the sub-phase NEVER causes /review-pr or /simplify to exit non-zero` (`agents/findings-to-issues.md:187`); audit of the post-PR-#112 flow surfaced three silent-drop paths where a green trust trail co-existed with unresolved blocker findings, dropped Phase 2 `important` / Phase 1 `major` findings, and silent CI fixer refusals. RFC 0002 fixes all three with a tiered model:
  - **`blocker` deferred → RED trail** (no `Reviewed-by` trailer, no `uberdev-approved` label, exit 1). `/merge` requires `--accept-blocker-deferred` to land.
  - **`critical` deferred → YELLOW trail** (trailer carries `severity=critical-deferred count=N`, label becomes `uberdev-approved-with-concerns`). `/merge` requires `--accept-critical-deferred` to land.
  - **`important` / `major` deferred → GREEN unchanged** (file silently, no @mention, no halt).
  - **CI `ci-code-fixer` `status: REFUSED` → user-visible halt prose** (mirrors `billing_quota` shape) + file the failing test as a CRITICAL-tier issue + drop the 3-iteration retry (REFUSED is deterministic, not flake).
  - Operator can opt out per-run via interactive AskUserQuestion option 3 (`Override — emit GREEN`), which logs `override_reason: "user-selected-emit-green-on-blocker-deferred"` in the audit JSON and requires `/merge --i-know-what-im-doing` to land downstream.
- **Audit JSON shape** (`.uberdev/runs/<run-id>/review-pr-verdict.json`) gains `phases.phase2_5` and a top-level `trust_trail_state ∈ {GREEN, YELLOW, RED}` field. Legacy audit JSON (pre-v0.26.0) without `phases.phase2_5` triggers `trust-trail-evaluator` to emit `STALE` with rationale `audit JSON predates phase2_5 schema; re-run /uberdev:review-pr to refresh trail` — one-time friction; scoped to open PRs only.
- **`/uberdev:merge` accepts three new override flags**: `--accept-blocker-deferred`, `--accept-critical-deferred`, `--i-know-what-im-doing` — all per-invocation only (no env-var, no config key) so muscle-memory use is discouraged.
- **`trust-trail-evaluator` agent gains Phase 2.5 gate** (Process Step 1.5 — runs before structural primitives). Two new `TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM` members: `phase2_5_blocker_deferred`, `phase2_5_override_unacknowledged`.
- **`findings-to-issues` agent**: severity filter extended to `{blocker, critical, important, major}` (was `{blocker, critical}`); BLOCKER/CRITICAL-tier issues now carry `@<pr-author>` @mention + `Blocks: #PR` backref; agent gains `halted: <bool>` + `by_severity: {blocker, critical, major}` + `filed_issue_urls: [...]` + `override_reason: <string|null>` in its return YAML; broken-feature overflow guard fires `halted: true` when truncated rows include BLOCKER/CRITICAL tier.

### Migration

- Existing in-flight PRs see `STALE` trust trail after the version bump per `trust-trail-evaluator` Step 1.5 legacy-audit branch. Re-run `/uberdev:review-pr` once on each open PR to refresh the trail with the new `phases.phase2_5` schema.
- No data migration needed — issues are durable in GitHub; audit JSON is ephemeral per-PR-head and refreshed on each `/review-pr` run.
- No feature flag — plugin code updates atomically when the marketplace pulls the new manifest.

### Notes

- **Scope of the BREAKING tag.** API surface (CLI flags, skill names, agent dispatch shapes) is preserved; behavioral break is in the trust-trail predicate (PR with blocker findings that previously emitted GREEN now emits RED). Audit JSON gains a new block additively; legacy consumers that don't read `phases.phase2_5` see no change in the fields they do read.
- **Solo-dev workflow preservation.** For the personal-TODO-queue workflow ([[user_workflow_todo_queue]]), the design intentionally preserves the "land imperfect work + file TODOs" pattern for `important` / `major` findings (silent file, no halt). The halt path is reserved for `blocker` — by definition the findings the reviewer agents consider unshippable.
- **Rollback procedure.** Pin the marketplace to `0.25.0` in `.claude-plugin/marketplace.json` via the user-side override path; no code rollback is required server-side.

## [0.25.0] - 2026-05-14

### Added

- **Visual companion in orchestrator Phase 2 (`/solve` and `/turbo` medium/large tier)** — `plugins/uberdev/skills/orchestrator/SKILL.md` Phase 2 (Q&A) now offers the browser-based visual companion already shipped with the brainstorm skill (`skills/brainstorm/scripts/server.cjs` + `start-server.sh`, full protocol in `skills/brainstorm/visual-companion.md`). Previously, `/solve` for medium/large issues went straight to text-only `AskUserQuestion` because the orchestrator was built as a separate Phase 2 path that bypassed the brainstorm skill (`skills/brainstorm/SKILL.md:16`); design questions that would benefit from mockups, layout comparisons, or architecture diagrams were forced into prose. The new sub-section adds:
  - (a) **When to offer** — research-bundle / issue-body heuristic: frontend file globs (`*.tsx`/`*.jsx`/`*.vue`/`*.svelte`/`*.css`), directory hints (`components/`/`ui/`/`design/`/`screens/`/`pages/`), OR visual keywords (`layout`/`design`/`mockup`/`color`/`theme`/`wireframe`/`palette`/`typography`/`hierarchy`/`UI`/`UX`).
  - (b) **Consent capture** — verbatim consent message mirroring `skills/brainstorm/SKILL.md:166`, captured via `AskUserQuestion` 2-option vote.
  - (c) **Per-question decision protocol** — visual content (mockups, layout comparisons, architecture diagrams) routes to the browser; conceptual content (scope/requirements/A-B-C text/tradeoff lists) routes to the terminal. Mixing is allowed across the 3-5 Phase 2 questions.
  - (d) **Plugin-root-anchored path resolution** — `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/scripts` with `find ~/.claude/plugins` fallback so the orchestrator can locate `start-server.sh` regardless of its own CWD.
  - (e) **`qa_answers` normalization** — terminal and browser answers share `{question, answer, source: "terminal" | "browser"}` shape; the browser path's authoritative `type:"submit"` event maps to `choice` (or `selections[]` for multi-select).
  - (f) **`waiting.html` unload pattern** — `skills/brainstorm/visual-companion.md:118-127` verbatim, for switching between visual and terminal questions so the user does not stare at a stale resolved mockup.
  - (g) **Turbo skip** — visual companion is interactive-only; the existing `TURBO=1` gate (`skills/orchestrator/SKILL.md` "Turbo detection (hybrid)" section) bypasses the entire flow without invoking `start-server.sh`.
  - (h) **Threat-model inheritance** — `skills/brainstorm/SKILL.md:206-214` (localhost-only bind, no auth, single-user assumption — never `--host 0.0.0.0` in CI/shared-host contexts).

### Notes

- **No new infrastructure.** The change is documentation/protocol only — `server.cjs`, `start-server.sh`, `stop-server.sh`, `helper.js`, `frame-template.html`, and the `inject-brainstorm-answers` plugin hook were already shipped with `41d072b feat(uberdev): full Superpowers parity port` (v0.3.0). The new sub-section teaches the orchestrator to reuse them; nothing in the brainstorm skill changes.
- **Degradation is non-fatal.** If plugin-root resolution fails (custom install layout, missing `find` results), the orchestrator logs to stderr and falls back to terminal-only Phase 2 — visual companion is enrichment, not a hard requirement.

## [0.24.0] - 2026-05-14

### Added

- **Findings-to-Issues sub-phase (`/uberdev:review-pr` Phase 2.5 + `/uberdev:simplify` Phase 3.5)** — persists deferred-critical findings (`severity ∈ {blocker, critical} AND disposition != APPLIED`) from Phase 1 (`post-impl-review`) and Phase 2 (`simplify`) aggregates as durable GitHub issues with HTML-comment fingerprint dedupe. State branching across runs: `state==open` triggers an `Also flagged on commit <SHA>` comment (no duplicate issue); `state==closed` skips (user resolved); no match creates a new issue with `--label review-pr-finding`. Hard cap `MAX_NEW=10` per run; rate-limit pre-flight aborts the sub-phase if `gh api rate_limit` remaining `< 2*MAX_NEW + 50` (verbatim pattern from `commands/review-pr.md:181-198`). All `gh issue create` / `gh issue comment` calls use `--body-file -` with stdin piping (never `--body "$VAR"`). Sub-phase NEVER fails the parent run. Closes #111.
- **`uberdev:findings-to-issues` agent (`plugins/uberdev/agents/findings-to-issues.md`)** — single-shell-turn no-fanout agent dispatched by both `/uberdev:review-pr` Phase 2.5 and `/uberdev:simplify` Phase 3.5. Implements the dedupe + write loop. Verifies aggregate-file inputs are wrapped in `<external-untrusted-input source="post-impl-review-aggregate">` / `simplify-aggregate` envelopes before interpolation. Refuses on `input-malformed`, `rate-limit-budget-insufficient`, or `secret-scan-lib-unavailable`.
- **`--no-defer-issues` CLI flag on `/uberdev:review-pr` and `/uberdev:simplify`** — sets `DEFER_ISSUES_PHASE=0`, short-circuits the Phase 2.5 / Phase 3.5 dispatch. Mirrors `--no-ci-fix` / `--no-simplify` shape.
- **`defer_issues_enabled: <true|false>` config key in `.claude/uberdev.local.md`** — read via the existing `uberdev_read_enum` helper. Default `true` (always-on). Either knob (CLI flag OR config key) is sufficient to disable.
- **`review-pr-finding` GitHub label (auto-provisioned per repo, fail-soft)** — `gh label create --force review-pr-finding --color d93f0b` runs once at the top of the sub-phase; failure emits one stderr warning and proceeds (subsequent `gh issue create --label` calls may degrade to no-label gracefully).

### Refactored

- **Extracted `run_secret_scan_stdin` from `plugins/uberdev/skills/finish-branch/SKILL.md` into shared library `plugins/uberdev/lib/secret-scan.sh` (public name: `uberdev_run_secret_scan_stdin`).** Source-time idempotency guard (`_UBERDEV_SECRET_SCAN_LOADED=1`) mirrors the `lib/config-read.sh` pattern. Behaviour-preserving — gitleaks primary + regex fallback + fail-CLOSED semantics identical to the pre-refactor inline function. `finish-branch/SKILL.md` now sources the library and renames its four call sites. The library is also sourced by the new `findings-to-issues` agent for candidate-body scanning before `gh issue create`. Added `tests/finish-branch.test.sh` as a regression lock.

### Tests

- **`tests/findings-to-issues.test.sh`** — 5 core fixture suites (parser, dedupe-fingerprint, label-idempotency, opt-out flag, config override) + 4 bonus suites (fail-CLOSED dedupe, MAX_NEW cap, secret-scan integration, fingerprint-marker reject). Fixtures under `tests/fixtures/findings-to-issues/` include synthesised aggregate `.md` files (with trust envelopes) + disposition `.yaml` files + opt-out config fixtures. Mocks `gh` inline as a shell function that captures argv and returns canned JSON.
- **`tests/finish-branch.test.sh`** — regression lock for the `lib/secret-scan.sh` extraction (5 assertions: SKILL.md sources the lib, no longer inlines the function, lib exists, lib has idempotency guard, lib retains gitleaks primary + regex fallback).

## [0.23.5] - 2026-05-13

### Fixed

- **Move `pr-test-analyzer` dispatch from orchestrator Phase 5.5 into `subagent-driven-dev` Step 4.5.** The previous design described a logically impossible window: `subagent-driven-dev` invokes `finish-branch` inline, `finish-branch` globs `pr-test-analyzer.md` to compose the PR body, and by the time orchestrator Phase 5.5 could fire the PR had already been pushed without the analyzer's findings. Fix: relocate the dispatch into a new Step 4.5 inside `subagent-driven-dev` (between the post-wave full-test-suite and the `finish-branch` handoff), gated on `tier == "large"` AND `summary_dir` present. The orchestrator's Phase 5 dispatch now passes `summary_dir: $RESEARCH_DIR_ABS/` and `tier` to SDD as additive optional inputs (backward-compatible — non-orchestrator callers gracefully skip Step 4.5). `pr-test-analyzer` is intentionally dispatched twice on large tier — pre-merge (Step 4.5, single `Task()`, feeds the PR body) and post-PR-push (the `uberdev:post-impl-review` 6-agent fanout, feeds `/uberdev:review-pr`'s fix loop). The two dispatches serve different integration points and are not redundant. Closes #92.
  - **Why patch only.** Skill-prose change with observable pipeline effect (dispatch site moves between skills) but no code-shape change and no breaking API — `summary_dir` and `tier` are additive optional inputs to SDD. Mirrors PR #103 convention.
- **orchestrator: refuse interactive /solve in `claude --bg` context.** Added a Phase 0 bg-context gate to `plugins/uberdev/skills/orchestrator/SKILL.md` that evaluates BEFORE run-id generation, artifact-dir creation, and issue-body fetch. Layered detection: turbo exemption (`$ARGUMENTS contains --turbo` OR `${UBERDEV_TURBO:-0} == "1"`) short-circuits first; bg-context test (`[ -n "${CLAUDE_JOB_DIR:-}" ]` OR `[ ! -t 0 ]`) triggers abort with stderr message and `exit 2`. Removes three failure modes documented in #93: indefinite `AskUserQuestion` block, `InputValidationError` collapse when `ToolSearch` was not pre-loaded, and agent-initiated auto-pick that silently turned `/solve` into `/turbo`. The Phase 2 identity rule ("This phase is the only signal that distinguishes /solve from /turbo…") and ToolSearch caveat ("Do NOT silently auto-pick on tool-load failure…") both already forbade the auto-pick path; this gate enforces that contract structurally by removing the precondition. Stderr message generalises to "interactive orchestrator (/solve or /uberdev:orchestrator without --turbo)" so the standalone-invocation path is named accurately. Tests added: `tests/orchestrator-phase-0-bg-detection.test.sh` (A1-A7 — both detection arms, literal stderr, exit 2, turbo-exemption ordering, MUST imperative wording, fail-fast position, Phase 2 detector unchanged). Closes #93.
  - **Why patch only.** Single SKILL.md prose block, one new structural-grep test, additive only. No new env vars, no new CLI flags. `/turbo` users see no change (turbo exemption fires); interactive `/solve` users in a foreground terminal see no change (TTY arm is false); only the previously-hanging path (`/solve` under `claude --bg`) gets the new abort behaviour.

## [0.23.4] - 2026-05-13

### Refactored

- **Replace brittle 3-layer `--turbo` arg-forwarding chain with `UBERDEV_TURBO=1` env-var inheritance.** The chain `orchestrator → subagent-driven-dev → finish-branch → review-pr` previously forwarded `--turbo` as an LLM-interpreted argument across four prompts; a drop at any layer collapsed `/turbo` semantics silently (the chain fell back to interactive prompts inside a `claude --bg` session, which then deadlocked). Now the bit is set once at the pipeline entry point (`commands/turbo.md` `export UBERDEV_TURBO=1`) and propagates via two boundaries: (a) Skill() boundary (same agent process, in-process env table) into `solve-pipeline`; (b) OS process boundary (POSIX fork+exec) into `claude --bg` via inline-prefix exec `UBERDEV_TURBO=1 claude --bg …`. Each downstream consumer reads `[[ "${UBERDEV_TURBO:-0}" == "1" ]]`. `commands/solve.md` adds `unset UBERDEV_TURBO` to defend against shell-rc pollution. Mirrors `AUTO_MODE` (PR #19) and `UBERDEV_AUTO_REVIEW_ON_MERGE` (PR #90) precedents. **Hybrid arg-OR-env detector preserved on `orchestrator` and `commands/review-pr`** for legit standalone-invocation paths (`/uberdev:orchestrator --turbo …`, `merge-pipeline`'s separate `Skill("uberdev:review-pr", args: "${PR} --turbo")` dispatch). `subagent-driven-dev` and `finish-branch` are env-var-only (chain-internal). Test surface refactored: `tests/turbo-flow.test.sh` rewritten in dedicated commit `test(turbo-flow): assert UBERDEV_TURBO env-var propagation`. Closes #97.

## [0.23.3] - 2026-05-13

### Added

- **`review-pr:pending` label backstop one layer upstream of `/merge`.** Mirrors the v0.23.0 `/merge` trust-trail backstop at the previous chain link. `plugins/uberdev/skills/finish-branch/SKILL.md` now adds the `review-pr:pending` GitHub PR label (via `gh label create --force` + `gh pr edit --add-label`, both fail-soft per the fire-and-surface contract) immediately before invoking `uberdev:review-pr` via the `Skill` tool. `plugins/uberdev/commands/review-pr.md` Trust-Signal Emission block clears the label on green outcome (fail-soft per spec D4 — the label may legitimately not exist when `/review-pr` is invoked directly). `plugins/uberdev/skills/merge-pipeline/SKILL.md` Step 1.4.5 gains a new positive-signal label-presence probe (gated by `AUTO_REVIEW_ON_MERGE`) that short-circuits trust-trail reason resolution by assigning `reason="trust_trail_label_missing"` directly. **No new `AUDIT_EVENT_ENUM` or `GATE_FAIL_REASON_ENUM` members** — D1 reuses the existing `trust_trail_label_missing` value. The label is the durable cross-process signal: it survives session boundaries and any tool with `gh` access can inspect it. New named constant `REVIEW_PR_PENDING_LABEL = "review-pr:pending"` in `merge-pipeline/SKILL.md` Constants table. The `AUTO_REVIEW_DISPATCH_CAP = 1` cap-ordering invariant from v0.23.0 is preserved (counter write still precedes `Skill()` dispatch). Tests added: `tests/finish-branch-auto-chain.test.sh` (#95.1–#95.5 — label-add presence, line-order guard, fail-soft contract), `tests/review-pr.test.sh` R21 (label-remove presence, prose-anchor, fail-soft tombstone, section-anchor), `tests/merge.test.sh` M86 (Constants row, probe presence, gate, reason-reuse, `AUDIT_EVENT_ENUM` set-equality, cap-ordering preservation, Common Mistakes anchor). Total 16 new assertions. Closes #95.
  - **Why patch only.** Mirror of the v0.23.0 backstop one layer upstream; no new public CLI flags; default-off behaviour is bit-identical for users not opted into `AUTO_REVIEW_ON_MERGE`.

## [0.23.2] - 2026-05-13

### Fixed

- **solve-pipeline:** route trivial/small heredocs through `uberdev:finish-branch` instead of inline `gh pr create` + prose Skill-invoke. All four trivial/small heredocs now end with a `Hand off to uberdev:finish-branch` directive (turbo variants append `--turbo`); the agent retains the commit step. finish-branch owns push, `gh pr create` with URL validation, and the canonical `Skill("uberdev:review-pr")` chain hand-off (with `--turbo` forwarded). All tiers now converge on the same single PR-creation + review-pr chain site, closing the silent-drop gap where a child `claude --bg` agent exiting after `gh pr create` (permission denial, classifier abort) would bypass the global mandatory-review-after-push rule. `tests/turbo-flow.test.sh` re-anchored to the new positive (Hand-off=4, finish-branch `--turbo`=2) and negative (`gh pr create`=0 inside trivial/small slice) contract; pre-push-simplify directive count=4 preserved. Closes #91.

## [0.23.1] - 2026-05-13

### Documentation

- **`plugins/uberdev/skills/orchestrator/SKILL.md`**: Added `### Phase 6: PR creation + review chain` to make the `subagent-driven-dev → finish-branch → /uberdev:review-pr` cascade explicit inside the orchestrator skill. Deleted the misleading `## End-of-pipeline` section that previously read "the orchestrator's job is done" after Phase 5. Phase 6 names the two downstream `/uberdev:review-pr` phases (Phase 1: 6 advisory reviewers via `uberdev:post-impl-review`; Phase 2: 3 simplify lenses) and acknowledges the large-tier `Phase 5.5` ordering. Closes #94.

## [0.23.0] - 2026-05-13

### Added

- **Opt-in `/merge` Phase 1.4 auto-dispatch of `/review-pr` when trust trail is missing.** Gated by per-repo config key `auto_review_on_merge: true|false` (default `false`) with env override `UBERDEV_AUTO_REVIEW_ON_MERGE`. Conservative trigger filter — fires ONLY on `trust_trail_label_missing` and `trust_trail_trailer_missing`. Bounded: 1 auto-review per PR per `/merge` run (named constant `AUTO_REVIEW_DISPATCH_CAP = 1`). Two new `AUDIT_EVENT_ENUM` members: `auto_review_dispatched`, `auto_review_returned`. Default-off path is bit-identical to current `/merge` (zero new audit events, zero new wall-clock). Static shape-checks ship now (M74–M85, U9.1–U9.5); runtime-emission tests deferred until the existing `tests/merge-discovery-resilience.test.sh` harness can stub the `Skill()` call (tracked as follow-up; see spec §Risks R3). Closes #89.

## [0.22.2] - 2026-05-12

### Fixed
- **`/turbo` and `/solve` failed to dispatch under zsh — every `claude --bg` invocation exited with `error: unknown option '--effort max'`.** v0.22.1 (#87) shipped the `--effort` threading as scalar variables (`PERM_FLAG="--permission-mode auto"`, `EFFORT_FLAG="--effort $EFFORT_LEVEL"`) and relied on word-splitting of the unquoted `$PERM_FLAG $EFFORT_FLAG` tokens in the dispatch case-arms to produce separate argv slots. That assumption holds under bash but NOT under zsh — zsh's default `SH_WORD_SPLIT=off` keeps `"--effort max"` as a single argv slot, which `claude --bg` rejects. Since zsh is the default shell on macOS (and the Claude Code Bash tool inherits the user's shell), every dispatch on a macOS host failed at the wave-batch boundary. The CI tests passed green because `tests/solve-effort-flag.test.sh` runs under `#!/usr/bin/env bash` — the bash-only test runner masked the regression in the actual production shell. Same trap that the earlier `TIMEOUT_BIN` block already documented inline, but applied to the wrong code path.
  - **Fix.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Phase A hoist converts both flags to bash+zsh arrays (`PERM_FLAG=()` / `PERM_FLAG=( --permission-mode auto )`; `EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )`). All three dispatch case-arms (`file` / `stdin` / `argv` in Step 5b') expand via `"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, which preserves one argv slot per element identically in bash and zsh regardless of `SH_WORD_SPLIT`. Empty arrays expand to zero slots, populated arrays to their elements verbatim.
  - **Tests.** `tests/solve-pipeline-zsh.test.sh` (NEW, 7 assertions) — zsh-runtime regression fixture that EXECUTES the dispatch composition under a real `#!/usr/bin/env zsh` shell, captures the dispatched argv via a stub `claude` on PATH, and asserts `--effort` + level land as separate adjacent argv slots (R2) and that the AUTO_PERMISSIONS path also splits correctly (R3). Includes a negative `--effort max` collapsed-slot tombstone. Wired into `.github/workflows/test.yml` with a `sudo apt-get install -y zsh` step on the ubuntu-latest runner. `tests/dispatch-claude-bg.test.sh` re-anchored on the array hoist (`^EFFORT_FLAG=\( --effort `, `^PERM_FLAG=\(\)$`, `PERM_FLAG=\( --permission-mode auto \)`), and the `${PERM_FLAG[@]} ${EFFORT_FLAG[@]}` token-pair count switched to the array-quoted form (`"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, ≥3 occurrences); added a scalar-form tombstone that fails if a future edit reverts to the broken `$PERM_FLAG $EFFORT_FLAG` shape. `tests/solve-effort-flag.test.sh` R3 mirror updated to the array form so the bash test stays in sync with the SKILL.md.
  - **Why patch only.** Pure bug fix in the dispatch shape; no new flags, no behavioural change for users invoking `/solve` or `/turbo` correctly. Patch-version bump per the bump-everywhere rule so the marketplace pulls the fix.

## [0.22.1] - 2026-05-12

### Fixed
- **`/turbo` (and `/solve`) silently downgraded child-agent quality because `claude --bg` does NOT inherit the parent session's `/effort` setting.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 5b''s three case-statement arms (`file` / `stdin` / `argv`) composed the bg-dispatch argv as `… --model "$MODEL" $PERM_FLAG …` with no `--effort <level>` token. `claude --effort <level>` is a real CLI flag in Claude Code 2.1.139 accepting `low | medium | high | xhigh | max`, but in the absence of explicit pass-through every spawned bg session fell back to the supervised daemon's default. For `/turbo` — which runs unattended — the user-facing symptom was that setting `/effort max` (or anything else) in the parent session had **zero** effect on the dispatched solver agents, so any quality benefit from a higher effort level evaporated at the worktree boundary. The downgrade was invisible: no warning, no audit entry.
  - **Fix.** Phase A now parses `--effort=<level>` from `$ARGUMENTS` and resolves an `EFFORT_LEVEL` via the same precedence chain `/solve` already uses elsewhere (`SOLVE_AUTO`, `SOLVE_TIMEOUT`): **CLI flag > `UBERDEV_SOLVE_EFFORT` env var > `solve_effort:` in `.claude/uberdev.local.md` > `EFFORT_LEVEL_DEFAULT` (`max`)**. The hoisted `EFFORT_FLAG="--effort $EFFORT_LEVEL"` is threaded into all three case-statement arms immediately after `$PERM_FLAG`, so word-split preserves `--effort` and the level as two separate argv slots. Default is `max` because `/turbo` is autopilot — wall-clock and cost are secondary to quality; interactive `/solve` callers who want to spend less can pass `--effort=high` or set the repo-wide config key.
  - **Validation.** Invalid levels (typos like `--effort=hgh`, env values like `UBERDEV_SOLVE_EFFORT=ludicrous`) are rejected loudly at Phase A with an actionable stderr message naming the enum — `claude --effort hgh` would otherwise fail at the child with a less obvious error.
  - **Telemetry.** New `effort_resolved` audit event (added to `SOLVE_AUDIT_EVENT_ENUM`) records `{source: cli|env|config|default, level}` for each dispatch. Mirrors the `deprecated_flag_used` precedent.
  - **Constants table** gains `EFFORT_LEVEL_DEFAULT` (`max`) and `EFFORT_LEVEL_ENUM` (`low | medium | high | xhigh | max`). Audit-event enum extended with `effort_resolved`.
  - **Docs.** `commands/solve.md` and `commands/turbo.md` Usage lines gain `[--effort=<level>]`; both ship a one-paragraph note documenting the default, precedence chain, and rationale.
  - **Tests.** `tests/dispatch-claude-bg.test.sh` extended with 10 new anchored-grep assertions covering Constants entries, parser block, env override, audit emit, EFFORT_FLAG hoist, and the `$PERM_FLAG $EFFORT_FLAG` token-pair count in all three case arms. `tests/solve-effort-flag.test.sh` (NEW) — runtime fixture: extracts the Phase A parser block via awk markers, evaluates it against the five precedence-ladder paths (default / CLI wins / env wins / config wins / all five enum values), asserts invalid CLI and env values exit non-zero with the enum-name stderr, and asserts the dispatched-argv (captured by a stub `claude` on PATH) contains `--effort` and the level as separate slots in order. Wired into `.github/workflows/test.yml`. Pre-fix run on the new assertions: fail. Post-fix: all 13 new + 10 added assertions pass, full suite remains green (1046 assertions across 19 test scripts).
  - **Out of scope.** Auto-detecting the parent session's `/effort` setting and inheriting it. Claude Code 2.1.139 does not expose that to children via env or any documented introspection surface; inheritance would require an upstream RFE. The default-of-`max` plus explicit override is the pragmatic fix.

## [0.22.0] - 2026-05-12

### Changed
- **`/uberdev:solve` and `/uberdev:turbo` now dispatch `claude --bg` background sessions instead of opening per-issue terminal windows (#85).** The five-branch `case "$TERMINAL" in cmux) … ghostty) … iterm) … terminal) … nohup|*) … esac` block (`solve-pipeline/SKILL.md` Step 5c) is retired wholesale. Monitor sessions via `claude agents` (Agent View). Hard-requires Claude Code >= 2.1.139.
- **`/turbo` parallelism is capped via `fanout_concurrency.solve_bg` (default 6, range [1, 50]).** Mirrors `fanout_concurrency.merge_strategy` (#49 / v0.17.0). Larger queues split into `ceil(N / cap)` sequential single-message dispatch waves with per-wave `solve_bg_fanout_wave_started` audit events.
- **Orchestrator artifact paths anchored to `$(git rev-parse --show-toplevel)`.** `.uberdev/research/$RUN_ID/` is now resolved via `--show-toplevel` instead of relative-CWD interpolation. Closes the worktree path-leak documented in `memory/project_uberdev_artifact_path_leak.md` (research-patterns / spec-writer artifacts previously landed in the parent project root and required a manual `cp` to the worktree).

### Deprecated
- **`--terminal=cmux|ghostty|iterm|terminal|nohup` flag and `$SOLVE_TERMINAL` env var.** Parsed without error, emit `TERMINAL_FLAG_DEPRECATED_NOTE` once per run on first encounter, record `deprecated_flag_used` audit event, no behavioural effect. Removal target: v1.0.0. Pattern matches `--squash` / `--rebase` retirement in #49 / v0.17.0 and `--bypass-protections` retirement in #35 / v0.17.0.
- **`solve_terminal` config key in `.claude/uberdev.local.md`.** Same retirement — parsed but ignored. `using-uberdev/SKILL.md` no longer documents the key.
- **`SOLVE_GHOSTTY_NEW_WINDOW=1` env var.** The Ghostty new-window codepath is retired; the env var is parsed but has no behavioural effect.

### Removed
- `solve-pipeline/SKILL.md` Step 3 terminal detection block (cmux socket detection, `$TERM_PROGRAM` cascade, `$REAL_CLAUDE` PATH walk).
- `solve-pipeline/SKILL.md` Step 5b launcher shell script heredoc (`/tmp/solve-$ISSUE_NUM.sh`, the `cd "REPO_ROOT"` prologue, the worktree-cleanup pre-step, the `${TIMEOUT_BIN} ${SOLVE_TIMEOUT} CLAUDE_BIN … --worktree solve-issue-$ISSUE_NUM …` invocation).
- `solve-pipeline/SKILL.md` Step 5c per-terminal dispatch case statement (cmux / ghostty / iterm / terminal / nohup branches) and the 0.6s inter-Ghostty sleep guard.
- `solve-pipeline/SKILL.md` Step 6 cmux-notify / terminal-notifier / osascript-display-notification chain. Replaced by single stderr echo. Closes latent `osascript-e-shell-var` ERROR-class security finding as a side-effect.
- `solve-pipeline/SKILL.md` Step 7 OSC tab-retitle / cmux workspace-rename block. Agent View shows session names natively from `--worktree solve-issue-N`.
- `tests/cmux-detection.test.sh` (no longer applicable; replaced by tombstone assertions in `tests/dispatch-claude-bg.test.sh` + `tests/ghostty-dispatch-no-instance-leak.test.sh`).

### Tests
- `tests/ghostty-dispatch-no-instance-leak.test.sh` extended into a broader tombstone test: assertions added for `cmux new-workspace`, `osascript -e`, `tell application "iTerm"`, `tell application "Terminal"`, `nohup zsh -l` absence. The original `open -na Ghostty --args --command=` regression guard (PR #33) is preserved verbatim; the `#31` issue reference in solve-pipeline SKILL.md is preserved (historical rationale).
- `tests/dispatch-claude-bg.test.sh` (NEW) — positive shape-check for the three-arm `BG_PROMPT_MODE` case-switch (`file` / `stdin` / `argv`; only `argv` fires today since `BG_PROMPT_MODE=argv` is hardcoded — `_uberdev_probe_bg_prompt_mode` was removed in `fix(solve)` 0c17169 because `claude --bg --help` is not introspective in v2.1.139), Phase A version gate (`_uberdev_require_claude_version "2.1.139"`), wave-batching (`MAX_PARALLEL_BG_AGENTS`, `solve_bg_fanout_wave_started`), deprecation shim (`TERMINAL_FLAG_DEPRECATED_NOTE`, `deprecated_flag_used`), and anti-pattern guards (no `claude --bg "$PROMPT"`, no `eval "claude --bg …"`). Wired into `.github/workflows/test.yml`.
- `tests/turbo-flow.test.sh` retrofitted: REAL_CLAUDE-hoist assertion retired and replaced with Phase A hoist assertion (anchors on `_uberdev_require_claude_version "2.1.139"` or `BG_PROMPT_MODE=argv`); Ghostty inter-spawn sleep assertion removed; new assertions for `MAX_PARALLEL_BG_AGENTS`, `uberdev_read_int_in_range fanout_concurrency.solve_bg`, `solve_bg_fanout_wave_started`, `_uberdev_require_claude_version "2.1.139"`. The differential guard awk anchor `^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$` (line 92) is preserved verbatim — the trivial and small heredoc bodies retain `!=1` form (interactive branch first, turbo in `else`) per the post-impl-review.test.sh contract.
- `tests/config-override.test.sh` I2 section updated: I2d asserts `"$TIMEOUT_BIN" "$SOLVE_TIMEOUT" claude --bg` instead of `… CLAUDE_BIN`; new I2g asserts the three-arm `BG_PROMPT_MODE` case-switch presence. I2a / I2b / I2c / I2e / I2f preserved verbatim.

### Migration
- Callers on Claude Code < 2.1.139 see an actionable error on `/solve` invocation: `error: /solve and /turbo require Claude Code >= 2.1.139 (found: <X>). install with: npm i -g @anthropic-ai/claude-code@latest`. Update Claude Code, then re-run.
- Callers passing `--terminal=cmux` (or any value) see one stderr line per run (`TERMINAL_FLAG_DEPRECATED_NOTE`); dispatch proceeds via `claude --bg` regardless. Remove the flag from your habit / aliases when convenient. `$SOLVE_TERMINAL` env var emits a parallel deprecation note.
- Users with `solve_terminal: <value>` in `.claude/uberdev.local.md` should remove the line. The key parses but has no behavioural effect.
- Artifact-path-leak fix: orchestrator-managed artifacts under `.uberdev/research/$RUN_ID/` now anchored to `$(git rev-parse --show-toplevel)`. No user action required.

### Security
- **Closed `claude-bg-arg-injection` (ERROR-class, hypothetical).** The Step 5b' dispatch case-switch prefers `--prompt-file` > stdin pipe > positional argv-via-bash-array (no `eval`). The naive `claude --bg "$PROMPT"` shape is explicitly forbidden by inline anti-pattern comment + `tests/dispatch-claude-bg.test.sh` regression guard.
- **Closed `osascript-e-shell-var` (ERROR-class, latent at former `solve-pipeline:484`).** Step 6 retirement (osascript display notification) eliminates the interpolation site.
- **Closed `applescript-keystroke-shell-var` / `applescript-do-script-shell-var` / `cmux-new-workspace-with-var` (WARNING-class, 4 sites).** Step 5c retirement eliminates every AppleScript / cmux IPC interpolation.
- **Hardened `_uberdev_audit_emit` against JSON injection** (`fix(solve)` 0c17169). The two audit-emit call sites for `$TERMINAL_FLAG_USED` / `$SOLVE_TERMINAL` route values through `jq -Rs .` so env values containing quotes / backslashes / newlines produce valid escaped JSON.

## [0.21.6] - 2026-05-12

### Fixed
- **`/solve` wall-clock kill never engaged on macOS.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 5b's heredoc-template launcher probed `command -v timeout` only — but macOS does **not** ship GNU `timeout(1)`. The only supported install path (`brew install coreutils`) places the binary at `gtimeout` (Homebrew's `g`-prefix avoids masking BSD utilities), so the wrap branch was dead code for the entire macOS audience: stock boxes hit the fail-open warning, and `brew install coreutils` did nothing to fix it. The user-facing symptom was `warning: timeout(1) not on PATH; /solve will run unwrapped (no wall-clock kill)` firing on every `/solve` and `/turbo` launch, with `command_timeouts.solve` (default 3600s) silently unenforced. /turbo, which runs unattended, was the most exposed: a stuck Opus-4.7 1M-context agent could burn tokens until the user manually noticed.
  - **Fix.** The launcher template now probes `timeout` then `gtimeout` and binds the resolved path to `TIMEOUT_BIN`; the wrap branch becomes `"$TIMEOUT_BIN" "${SOLVE_TIMEOUT}" CLAUDE_BIN …`. The quoted-`"$TIMEOUT_BIN"` form keeps it as a single `argv[0]` token under zsh `SH_WORD_SPLIT=off` (mirrors the inline-`timeout` zsh-safety precedent from #63/#72). Comment block updated to call out the `gtimeout` rationale explicitly.
  - **Misleading prose corrected.** The Step 5b narration previously called the missing-timeout case "rare on bare macOS without coreutils". It was actually the **default** behaviour on every macOS box (with or without coreutils). Rewritten to state that macOS does not ship GNU `timeout(1)`, that `brew install coreutils` installs it as `gtimeout`, and that fail-open fires only when **neither** binary is on PATH.
  - **Remediation pointer in the warning.** The fail-open stderr line previously read `warning: timeout(1) not on PATH; /solve will run unwrapped (no wall-clock kill)` — mystery, not action. Now: `warning: neither timeout(1) nor gtimeout on PATH; /solve will run unwrapped (no wall-clock kill). Fix: brew install coreutils`.
  - **Sibling doc synced.** `plugins/uberdev/skills/using-uberdev/SKILL.md` "Enforcement scope" paragraph (lines 193-196) now mentions the `gtimeout` fallback so the user-facing config reference matches the launcher behaviour.
  - **Tests.** `tests/config-override.test.sh` I2 block extended: I2c now asserts `command -v gtimeout` appears in the SKILL.md heredoc, I2d asserts the new `"$TIMEOUT_BIN" "${SOLVE_TIMEOUT}" CLAUDE_BIN` wrap form (replaces the old I2c `timeout "${SOLVE_TIMEOUT}" CLAUDE_BIN` literal regex which no longer matches), I2e asserts the warning contains the `brew install coreutils` remediation pointer. Pre-fix run: I2c/I2d/I2e fail. Post-fix run: all five I2 assertions pass; full suite remains green (77/77 config-override, 1080/1080 across 18 test scripts).
  - **Backward compatibility.** Linux and any macOS box with `timeout` shimmed onto PATH (e.g. via `brew install coreutils --with-default-names` on Intel, or manual symlink) continue down the original probe-and-wrap branch unchanged — `command -v timeout` still matches first.

## [0.21.5] - 2026-05-11

### Fixed
- **`/merge` skill double-load due to command/skill name collision.** `commands/merge.md` and `skills/merge/SKILL.md` both registered under plugin-namespaced ID `uberdev:merge` — `merge` was the only uberdev surface where a slash command and a skill shared a name (every other command — `/solve`, `/issue`, `/review-pr`, `/simplify`, `/turbo` — is command-only). The collision surfaced as a duplicate `uberdev:merge` entry in the system-reminder "skills available" listing (one with the command description, one with the skill description) and at runtime as `commands/merge.md` plus `skills/merge/SKILL.md` both being pulled into context for a single `/merge` invocation. Auto-discovery on the skill's `Use when the user invokes /merge…` description compounded the load on any non-slash mention of merge intent.
  - **Rename.** `plugins/uberdev/skills/merge/` → `plugins/uberdev/skills/merge-pipeline/` (skill `name:` frontmatter `merge` → `merge-pipeline`). The skill is now an internal implementation detail invoked exclusively by `commands/merge.md`; its description was rewritten as `Internal 4-phase pre-flight/plan/merge-resolve/sync pipeline for the /merge command. Invoked exclusively by commands/merge.md; do not call directly.` so it no longer auto-discovers on user mentions of `/merge`.
  - **Invocation update.** `commands/merge.md:49` now invokes `uberdev:merge-pipeline` (was `uberdev:merge`).
  - **Internal lib path updates.** Three `${CLAUDE_PLUGIN_ROOT}/skills/merge/lib/discover.sh` references in SKILL.md (Steps 1.0.5, 1.2.5, 1.4) repointed to `${CLAUDE_PLUGIN_ROOT}/skills/merge-pipeline/lib/discover.sh`.
  - **Cross-reference path updates.** Repointed across `agents/merge-strategy-decider.md`, `agents/conflict-resolver.md` (description + calling-skill ref at line 56), `agents/trust-trail-evaluator.md`, `agents/ci-rebase-handler.md`, `commands/review-pr.md` (six occurrences across Phase 3 + trust-signal artifacts + Run-ID format prose), and the two SKILL.md mirror-site enumerators in the "Author identity is NOT a gate condition" section. Historical `skills/merge/` paths in past CHANGELOG entries are left as-is — they're frozen narration of past states.
  - **Test-shape updates.** Four test files updated to track the new path: `tests/merge.test.sh` (`SKILL_FILE` constant, M3 header/regex, M4 echo header), `tests/merge-discovery-resilience.test.sh` (`LIB` / `SKILL` constants + A4d glob regex), `tests/review-pr.test.sh` R19 (`MERGE_SKILL` constant), `tests/review-pr-phase3-ci.test.sh` (`MERGE_SKILL` constant).
  - **Regression guard (NEW in M3).** `tests/merge.test.sh` M3 gains a `M3.collision` assertion that fails if `commands/merge.md` ever re-references the bare `uberdev:merge` skill (which would re-introduce the name collision with the command). M3 positive assertion now demands `uberdev:merge-pipeline\b`.
  - **No user-facing slash-command change.** `/merge` and `/uberdev:merge` continue to work exactly as before — those are commands (not skills) and their names did not change. Only the internal skill behind them moved.

## [0.21.3] - 2026-05-10

### Changed
- **`PATCH_LINE_CAP` raised from 200 → 500.** The conflict-resolver agent's per-file rejection threshold (declared at `plugins/uberdev/skills/merge/SKILL.md:25` Constants table; enforced at `plugins/uberdev/agents/conflict-resolver.md:31` Step 6 sanity-check; cited at `plugins/uberdev/skills/merge/SKILL.md:682` Red Flags) now accepts resolutions up to 500 lines.
  - **Strictly additive.** Previously-accepted resolutions remain accepted; previously-`REFUSED`-on-cap resolutions now have a 2.5× larger headroom before tripping the guard.
  - **Other refusal triggers unchanged.** `PATCH_FILE_CAP=5`, secret-shaped strings, out-of-hunk edits, prompt-injection-shaped markers, `.github/`/`.git`/hooks paths, and generated lockfiles are all preserved.
  - **Safety analysis.** The textual-evidence requirement at `plugins/uberdev/agents/conflict-resolver.md:28` Step 3 (each agent edit must cite a verbatim quote from each side) implicitly bounds legitimate patch volume to the union of the two conflict sides. The line cap is therefore a soft upper bound on legitimate volume, not a security guard against runaway agents — those are owned by the refusal triggers enumerated above.
  - **Why patch only.** Pure constant change (test shape, public API, and runtime behaviour all unchanged); patch-version bump per the bump-everywhere rule.

## [0.21.4] - 2026-05-10

### Fixed
- **`/review-pr` Phase 3 stale_base CONFLICT-resolve arm — caller-side procedural arm wired in (#80).** PR #76 (`feat(review-pr): add Phase 3 — CI Health`, v0.21.0) shipped `agents/ci-rebase-handler.md` with the explicit hand-off contract that on `status: CONFLICT, conflicted_files: [...]` the caller's main turn dispatches one `Task(subagent_type: uberdev:conflict-resolver)` per file in a SINGLE message (mirroring `merge/SKILL.md` Phase 3.3.iii–iv). The agent contract was sound; the matching procedural arm in `commands/review-pr.md` Step 6c.5 POST-FIX was never written. The latent gap defeated `/review-pr`'s entire CI-health autopilot for any `stale_base` PR with conflicts: a `CONFLICT` return either silently fell through to POST-FIX's "fixer pushed a commit" flow (no commit was actually pushed — Phase 1 re-entry then ran against unchanged HEAD, returned APPROVE, and emitted the trust signal on a still-broken rebase state) or the orchestrator halted with no user-facing explanation. Neither outcome matched the agent contract's promise.
  - **Fix.** `commands/review-pr.md` Step 6c.5 POST-FIX now opens with a "Branch on dispatched-fixer return status" preamble that explicitly conditions on `ci-code-fixer` `status: APPLIED | REFUSED` and `ci-rebase-handler` `status: REBASED | CONFLICT | REFUSED`, then runs the matching procedural arm. The new **CONFLICT-RESOLVE arm** re-creates the conflict state in the PR worktree (re-fetch + re-run rebase, capturing `EXPECTED_OLD_SHA` for the resume-push lease), resolves `CONFLICT_RESOLVER_CAP` from `lib/config-read.sh` (default 10, env override `UBERDEV_FANOUT_CONFLICT_RESOLVER`, range [1, 50]), splits `len(conflicted_files) > cap` into `ceil(len / cap)` sequential single-message waves, and dispatches one `Task(subagent_type: uberdev:conflict-resolver)` per file in a single assistant turn (matches `merge/SKILL.md` Phase 3.3.iii cap-resolve + fanout shape). Aggregation:
    - **All `RESOLVED`:** `git add` + `git rebase --continue` + push under the original lease (`--force-with-lease="$pr_head_branch":"$EXPECTED_OLD_SHA" --force-if-includes`). On push success → emit `ci_fix_pushed` with `data.by_agent="ci-rebase-handler+conflict-resolver"` (composite); fall through to existing Phase 1 re-entry. On lease-mismatch → `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_lease_mismatch`; exit 1.
    - **Any `AMBIGUOUS`:** `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_ambiguous`; exit 1.
    - **Any `REFUSED`:** `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_refused`; exit 1.
  - **Five new typed `data.subreason` values** for `ci_phase_outcome` audit events: `rebase_conflict_ambiguous`, `rebase_conflict_refused`, `rebase_lease_mismatch`, `rebase_continue_failed`, `rebase_push_failed`. These join the existing free-form-ish subreason vocabulary (`flaky_rerun_failed`, `post_fix_review_rejected`) — no new `CI_OUTCOME_ENUM` row, since `data.outcome` stays at `halted`. The latter two pin failure modes the original arm silently swallowed: `rebase_continue_failed` for non-zero `git rebase --continue` exit (pre-commit hook reject / GPG signing failure / unrecoverable continuation state) with no fresh conflict set; `rebase_push_failed` for non-lease-mismatch push failures (auth, pre-receive hook, rate-limit, network) — without these the `ci_fix_pushed` audit event would emit falsely. Two more documented for the `ci-rebase-handler` `status: REFUSED` arm (`ci_rebase_refused_<reason>`) and the `ci-code-fixer` `status: REFUSED` arm at the Phase 3 dispatch site (`ci_fixer_refused_<rationale>`).
  - **Anti-pattern guard restated.** The CONFLICT-RESOLVE arm is single-shot per `ci-rebase-handler` dispatch and bounded by `CI_FIX_LOOP_CAP = 3` from 6c.7 LOOP GUARD. The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge/SKILL.md:523` (in "PARK is the terminal floor" prose) is restated inline.
- **`tests/review-pr-phase3-ci.test.sh` now runs in CI.** PR #76 added the suite (9 scenarios + 3 agent-shape blocks) but did not wire it into `.github/workflows/test.yml`, so the Phase 3 prose contracts were unguarded against regression on `push` / `pull_request` events. Added to the workflow's `bash …` chain between `review-pr.test.sh` and `finish-branch-auto-chain.test.sh`. The new S13 assertions (below) inherit CI coverage from this wiring.

### Tests
- **`tests/review-pr-phase3-ci.test.sh` S13 (NEW, 17 assertions)** locks the procedural arm into the prose so a future edit cannot silently regress to the "POST-FIX assumes REBASED" shape: S13.1 (`uberdev:conflict-resolver` dispatched in Phase 3 CONFLICT path), S13.2 (`conflicted_files` YAML field referenced), S13.3 (`status: CONFLICT` conditional present), S13.4 (single-message Task() invariant), S13.5 (`CONFLICT_RESOLVER_CAP` cap referenced by name), S13.6 / S13.7 / S13.8 (typed `rebase_conflict_ambiguous` / `rebase_conflict_refused` / `rebase_lease_mismatch` `data.subreason` values), S13.9 / S13.10 / S13.11 (post-resolution push uses `--force-with-lease=<branch>:<sha>` + `--force-if-includes` + `EXPECTED_OLD_SHA` original-lease SHA), S13.12 (`git rebase --continue` runs on RESOLVED), S13.13 (`git rebase --abort` runs on AMBIGUOUS / REFUSED / lease-mismatch), S13.14 (cross-references `merge/SKILL.md` Phase 3.3 reference pattern), S13.15 (`OUTCOME=halted` surface for non-RESOLVED terminal cases), S13.16 (POST-FIX path explicitly conditions on `status: REBASED`), S13.17 (composite `data.by_agent="ci-rebase-handler+conflict-resolver"` audit string pinned on conflict-resolve push success). Suite total: 77 PASS / 0 FAIL (was 65). Adjacent suites unchanged: `tests/review-pr.test.sh` (112/112), `tests/merge.test.sh` (265/265), `tests/post-impl-review.test.sh` (31/31), `tests/audit-fixups.test.sh` (22/22).

## [0.21.2] - 2026-05-07

### Fixed
- **`/merge` Phase 1.4 PATH_2 sub-condition (d) gate-failure storm (#78).** The trust-trail JSON gate had two compounding bugs that surfaced when a downstream consumer ran `/merge` against PR #36 with four prior `/review-pr` runs in `.uberdev/runs/`:
  - **No PR-filter.** `skills/merge/SKILL.md:333` described sub-condition (d) as `∃ a file matching .uberdev/runs/<run-id>/review-pr-verdict.json` with no constraint on `<run-id>` and no constraint on the JSON's `.pr` field. The /merge agent's ad-hoc bash globbed every JSON in `.uberdev/runs/` and demanded each `.sha` equal `headRefOid`. Prior `/review-pr` runs (whether from earlier states of this PR or from other PRs in the same repo) left stale JSONs whose SHAs were correct *for their run* but no longer matched the current PR HEAD. Result: gate_fail across all 4 of them, even when one of them was the JSON for the current PR with a valid SHA. The gate got *harder* the more `/review-pr` history a repo accumulated — the absurd workaround was `rm -rf .uberdev/runs/`.
  - **Strict `"sha" == headRefOid` contradicted (c)'s fixup tolerance.** `SKILL.md:341` promises *"Honest fast-forward fixup commits added between /review-pr and /merge … evaluate to PASS"* — sub-condition (c) (the `trust-trail-evaluator` agent) honors this via cumulative-diff-empty heuristics. (d)'s strict equality did not. Any empty-anchor-on-top, sibling-equivalent `commit --amend`, or trivially-empty fixup moved `headRefOid` and broke (d) while (c) still PASSed. (d), explicitly framed as **corroborating-only** at line 333, was gating *harder* than the load-bearing (c) check.
  - **Producer recipe ambiguity.** `commands/review-pr.md:437` left the JSON's `"sha"` field as `<full-40-char-head-sha>` — undefined. The recipe at lines 416-420 only named `PARENT_SHA` (pre-anchor). Whether the JSON should record `PARENT_SHA` (matching the trailer payload) or post-anchor HEAD (matching `gh pr view --json headRefOid`) was left to agent inference, allowing producer drift.
  - **Fix.** Sub-condition (d) is now PR-filtered (glob → retain `.pr == <N>` → most-recent run-id) and presence + shape only (run-id regex / JSON parse / 40-hex `"sha"` field). The strict `"sha" == headRefOid` equality check is RETIRED post-#78 — tamper detection is fully delegated to (c). `data.reason="trust_trail_json_sha_mismatch"` is preserved in `GATE_FAIL_REASON_ENUM` (deprecation pattern; mirrors `trust_trail_json_missing` post-#52) but its scope is narrowed to shape failures only. The `/review-pr` recipe now explicitly captures `ANCHOR_SHA="$(git rev-parse HEAD)"` after `git push origin HEAD` and uses `${ANCHOR_SHA}` in the JSON `"sha"` field — the `<full-40-char-head-sha>` placeholder is removed.

### Tests
- **`tests/merge.test.sh` M63** narrowed and extended for #78. `M63.mismatch-gatefail` rephrased to "shape-malformed gate_fail (narrowed scope post-#78)". New assertions: `M63.pr-filter` (Phase 1.4 PATH_2 (d) prose explicitly requires filtering by top-level `.pr` field), `M63.strict-equality-retired` (prose explicitly retires `"sha" == headRefOid` equality), `M63.shape-malformed-narrow` (reason emission narrowed to shape failures), `M63.most-recent-tiebreak` (deterministic tie-break to lex-greatest run-id), `M63.inequality-phrasing-absent` (negative regression guard — the retired strict-inequality phrasing `"sha" != headRefOid` / `"sha" ≠ headRefOid` must not return to (d) prose). The `M37.gfr8` row-membership assertion is preserved (deprecation pattern keeps the enum row) and now carries the same `M63.{strict-equality-retired,shape-malformed-narrow,inequality-phrasing-absent}` cross-reference in its description.
- **`tests/review-pr.test.sh` R9.8–R9.11** (new). `R9.8` asserts `ANCHOR_SHA="$(git rev-parse HEAD)"` is captured after the push; `R9.9` asserts the JSON `"sha"` field literal `${ANCHOR_SHA}` substitution; `R9.10` is a regression guard that the ambiguous `<full-40-char-head-sha>` placeholder is gone; `R9.11` asserts the disambiguation prose between `ANCHOR_SHA` and `PARENT_SHA`.

## [0.21.1] - 2026-05-07

### Fixed
- **`solve-pipeline/SKILL.md:134` zsh-NOMATCH transcription trap.** The "Permission mode" echo packed `$([[ "$AUTO_PERMISSIONS" == "1" ]] && echo 'auto (Claude Code AI classifier)' || echo 'default (manual per-tool gating)')` inside an outer `"…"`. The line is valid bash/zsh in isolation, but every time an agent re-emits the SKILL block into a generated `/tmp/solve-*.sh` launcher (heredoc → sed pipeline), any slip in the nested `"`/`'`/`(…)` layers leaves the literal `(manual per-tool gating)` outside a quote. Under zsh's default `NOMATCH` that becomes an unmatched glob → `zsh:<line>: no matches found: (…)` → fatal under `set -e`, and the whole solve-pipeline run aborts before the validation loop. Reproduced by user against `TheFJK/WAGYPROD#35` (`zsh:32: no matches found: (manual gating)"`).
  - **Fix.** Hoisted the conditional out of the echo into a flat `PERM_DESC` variable populated by an `if/else`. Behaviour identical (same two strings, same `$AUTO_PERMISSIONS` semantics), but no nested substitution-with-parens-in-singlequotes pattern for the agent to mis-quote on re-emit. Comment block in the SKILL records the failure mode so future edits don't re-introduce the one-liner.
  - **Why patch only.** No new flags, no behavioural change, no test-shape change — single-block edit in the bash recipe inside one SKILL. Per the project's bump-everywhere rule, still a patch-version bump (0.21.0 → 0.21.1) so marketplace clients pull the fix.

### Tests
- **`tests/audit-fixups.test.sh`: regression guard for the `Permission mode` one-liner.** Asserts the SKILL no longer contains `Permission mode: $([[`; the assertion never matches the new flat-var form, only matches the resurrected substitution-with-parens form. Pattern observed twice in the field at line 134, so a permanent shape guard is the standard playbook (cf. the line-385 `[1m]` glob and line-410 `timeout` word-splitting guards).

## [0.21.0] - 2026-05-06

### Added
- **`/review-pr` Phase 3 — CI Health (#76).** New phase between Phase 2 and trust-signal emission that probes live CI, monitors pending runs, classifies red runs into one of six failure classes, dispatches per-class fix agents, and halts via `AskUserQuestion` for the two human-only classes. Closes the gap where today a green `/review-pr` run can co-exist with a red CI run, leading `/merge` to park the PR by surprise.
  - **Phase 3 prose** added inline in `commands/review-pr.md` as Step 6c (probe → monitor → classify → route → post-fix → halt → loop guard).
  - **3 new agents.** `agents/ci-failure-classifier.md` (regex-driven 6-class classifier; never quotes log lines verbatim — secret-leak guard), `agents/ci-code-fixer.md` (root-cause fixer for `code_bug` / `env_drift`; refuses on forbidden patterns including `--no-verify`, test-skip, error-swallow, secret-mask, new-file-creation, multi-lockfile-churn), `agents/ci-rebase-handler.md` (rebase-on-base for `stale_base`; uses `--force-with-lease=<branch>:<expected-old-sha> --force-if-includes` with worktree-scoped lock — the single sanctioned exception to `merge/SKILL.md`'s never-`--force-with-lease`-against-PR-head invariant).
  - **`--no-ci-fix` flag.** Probe-only mode: PROBE + MONITOR + CLASSIFY run for audit telemetry; ROUTE / POST-FIX / HALT are skipped. Mirrors `--no-simplify` shape.
  - **12 new `AUDIT_EVENT_ENUM` members** declared in `plugins/uberdev/skills/merge/SKILL.md` Constants table: `ci_probe_started`, `ci_probe_skipped_no_checks`, `ci_probe_unreachable`, `ci_monitor_green`, `ci_monitor_red`, `ci_monitor_timeout`, `ci_classify_dispatched`, `ci_classify_returned`, `ci_fix_dispatched`, `ci_fix_pushed`, `ci_loop_cap_reached`, `ci_phase_outcome`.
  - **3 new ENUMs** declared in `merge/SKILL.md` Constants: `CI_STATUS_ENUM` (`pending`, `green`, `red`, `unreachable`); `CI_FAILURE_CLASS_ENUM` (`code_bug`, `billing_quota`, `platform_outage`, `flaky`, `env_drift`, `stale_base`); `CI_OUTCOME_ENUM` (`green`, `green_after_fix`, `skipped_no_checks`, `halted`, `loop_cap_exhausted`). Plus prose constants `CI_FIX_LOOP_CAP=3` and `RERUN_FLAKY_CAP=1`.

### Changed
- **BREAKING** (predicate-level): `/uberdev:review-pr` GREEN now requires Phase 3 outcome ∈ `{green, green_after_fix, skipped_no_checks}` in addition to Phase 1 + Phase 2 conditions. Existing trust-signal artifacts (anchor commit, label, audit JSON) keep their format. The audit JSON gains a `phases.phase3` block. Callers parsing exit codes are unaffected: 0 / 1 / 2 semantics preserved (Phase 3 halts reuse exit 1).
- **`--turbo` scope narrowed.** R7 prose tightened from "does NOT alter Phase 1, Phase 2, or trust-signal emission" to "does NOT alter Phase 1 or Phase 2." Phase 3 halt classes (`billing_quota`, `platform_outage`) suppress the `AskUserQuestion` prompt under `--turbo` and exit 1 without emitting a trust signal — the queue would block silently otherwise. Phases 1 and 2 remain unaffected.
- **`merge/SKILL.md` cross-references `ci-rebase-handler`** as the single sanctioned exception to its "never `--force-with-lease` against PR head" invariant. The exception is bounded by a worktree-scoped lock, an explicit-old-SHA lease form, and `--force-if-includes`.

### Tests
- **`tests/review-pr.test.sh` extended (R14–R20).** New shape assertions: Phase 3 inline block exists; GREEN predicate updated to 3-conjunct; `--no-ci-fix` documented; exit-code contract reuses 1 for Phase 3 halts; `--turbo` prose narrowed; 12 new `AUDIT_EVENT_ENUM` members in `merge/SKILL.md`; new `CI_*_ENUM` rows present.
- **`tests/review-pr-phase3-ci.test.sh` (NEW, 9 scenarios + 3 agent-shape blocks)** — green-skip fast path, pending → green, pending → red → fix → green, 6 classification paths, loop-cap exhaustion, `--no-ci-fix` probe-only, `--turbo` halt classes, `gh` outage carve-out, audit-trail 12-event coverage; plus structural shape tests for each of the 3 new agent files (frontmatter, return-contract YAML fence, refusal triggers, no-quote-rule for the classifier).
- **`tests/_fixtures/fake-gh/gh` extended** with 7 new modes: `ci-checks-no-checks`, `ci-checks-pending`, `ci-checks-green`, `ci-checks-red`, `ci-checks-mixed`, `gh-unreachable`, `ci-rate-limit-low`.

## [0.20.3] - 2026-05-06

### Fixed
- **`/simplify` dispatcher-drift hardening (G1–G7).** Audit comparing UberDev's `/simplify` to upstream `claude-plugins-official` `code-simplifier` surfaced seven dispatcher-drift risks where invariants lived only in the command file, leaving the agent file weaker than its dispatch context implied. A standalone `Task(subagent_type: uberdev:code-simplifier)` without the command's preamble would fall back to a generic 91-line system prompt with softer iron-rule language and no per-lens checklists. This release makes the agent file the single source of truth for the lens checklists and the strict iron rule, and tightens the command file's Phase 1 fallback, RUN_ID minting, worktree-path anchoring, dedup policy, and per-lens output schema.
  - **G1 — Lens checklists deduped to agent.** `agents/code-simplifier.md` now has a top-level `## Lens checklists` section with `Lens: Reuse`, `Lens: Quality`, `Lens: Efficiency` subsections (the same 3+8+7-item checklists previously only in `commands/simplify.md`). The command file's three lens sections now point at the agent file by name + section anchor instead of restating the prose. Single source of truth: agent file.
  - **G2 — Strict iron rule mirrored into agent.** `agents/code-simplifier.md` Rule 1 ("Preserve Functionality") now carries the strict invariants from the command file ("Do not change function signatures, return types, thrown exception types, or public API surface"), labeled "iron rule", with the explicit fail-safe "If a simplification cannot be made without behavior risk, surface it as an advisory finding — do not propose it as an apply candidate."
  - **G3 — RUN_ID minting recipe inlined.** `commands/simplify.md` Phase 3 now inlines the canonical RUN_ID recipe `RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"` matching `/uberdev:review-pr` (verified at `commands/review-pr.md:68` and `:255`), with a regex-validation guard that exits non-zero if the format ever drifts.
  - **G4 — Aggregate path anchored to worktree root.** Phase 3 now derives `WORKTREE_ROOT="$(git rev-parse --show-toplevel)"` and writes `simplify-final.md` to `$WORKTREE_ROOT/.uberdev/research/$RUN_ID/`, defending against the artifact path-leak class noted in memory `project_uberdev_artifact_path_leak.md` (research artifacts leaking to parent project root when invoked from a worktree).
  - **G5 — Dedup policy specified.** Phase 3 now documents how to merge overlapping findings: dedup by `file:line` key; if 2+ lenses flag the same location, merge into one finding with `lens: Reuse+Quality` (etc.), summary/detail concatenated with ` | ` separators and lens-name prefixes, severity = max across merged. Eliminates implicit-behavior risk in the fixer's parse path.
  - **G6 — Per-lens output schema pinned.** New `## Return contract` section in `agents/code-simplifier.md` defines the structured shape every lens emits (`location`, `severity`, `lens`, `summary`, `detail`) — exactly what `code-fixer.md` Step 2 parses. The `lens` field is now mandatory so the aggregator can dedup deterministically.
  - **G7 — Phase 1 fallback tightened.** Removed the brittle "review the most recently modified files that the user mentioned or that you edited earlier in this conversation" prose, which relied on session-history introspection and produced non-deterministic drift. Now: if both git diff is empty AND `$ARGUMENTS` is empty, refuse with the literal message `/simplify needs either a non-empty git diff or an explicit scope hint via $ARGUMENTS`.
- **Post-review hardening (R1–R5).** `uberdev:code-reviewer` flagged five follow-up issues against the G1–G7 patch; all five fixed in the same release:
  - **R1 — Severity-enum parity.** Initial draft used `critical | important | suggestion` for the new agent return contract; canonical pipeline uses `blocker | suggestion` (`agents/pr-test-analyzer.md:57`, `skills/post-impl-review/SKILL.md:128`). `code-fixer.md` Step 2 parses the `post-impl-review-aggregate` envelope and would have silently coerced/dropped the non-canonical values. Agent return contract now emits `severity: blocker | suggestion` matching every other producer; cross-references the canonical sources inline.
  - **R2 — `code-fixer.md` Step 2 parser acknowledges optional `lens?` field.** Previously the extraction list was `{severity, location, summary, detail}` with no awareness of the `lens` field that simplify aggregates carry; the parser would have silently dropped it. Step 2 now extracts `{severity, location, summary, detail, lens?}` and passes the lens through into the commit-row label as `- [preserve] (Reuse) file.ts:42 — short summary` when present.
  - **R3 — Cross-file lens-name parity asserted.** `commands/simplify.md` references the agent's lens sections by name (`Lens: Reuse`, etc.). Initial test suite locked the names in the agent file but not in the command file, so a rename in one place would have left a dangling pointer. Six paired assertions added (one per lens, in each file) so renaming requires a coordinated edit.
  - **R4 — Iron-rule consolidation.** Strict invariants ("function signatures, return types, thrown exception types, public API surface") previously appeared in BOTH the command preamble and the agent's Rule 1. Command preamble now cross-references the agent ("strict invariants defined once in `plugins/uberdev/agents/code-simplifier.md` Rule 1") so there is exactly one place to edit.
  - **R5 — Machine-parseable refusal.** G7's empty-diff/empty-args refusal previously emitted only a literal English string. Phase 1 now also fences a YAML block (`status: REFUSED, rationale: "empty-diff-and-empty-arguments"`) so callers (`/turbo`, future automation) can detect refusals programmatically — matches `code-fixer.md`'s refusal envelope shape.
- **37 new structural assertions in `tests/simplify.test.sh`** lock G1–G7 + R1–R5 invariants (57 PASS / 0 FAIL total, up from 20). Two RED-GREEN cycles: G1–G7 RED (24 fails) → GREEN (44 pass) → R1–R5 RED (6 fails) → GREEN (57 pass). Adjacent suites untouched: `tests/code-fixer-dispatch.test.sh` (44/44), `tests/review-pr.test.sh` (76/76), `tests/post-impl-review.test.sh` (31/31).

## [0.20.2] - 2026-05-06

### Changed
- **`code-fixer` and `code-reviewer` agents now use `model: inherit`.** Previously hard-pinned to `sonnet` (code-fixer) and `opus` (code-reviewer). Inherit makes both agents track whatever model the user runs in their main Claude Code session — so when the user is on Opus 4.7 1M, every code-fixer commit and code-reviewer pass is also Opus 4.7 1M, with no per-agent model drift. Quality matters most for these two agents (they touch the diff before merge), and pinning a specific model name would gradually float behind whatever Anthropic ships next. `tests/code-fixer-dispatch.test.sh` asserts the new `^model: inherit$` contract.

### Fixed
- **`solve-pipeline/SKILL.md` Step 3 cmux detection now `set -u`-safe.** Wrapped the legacy fallback in `${CMUX_SOCKET:-}` so the fallback chain `${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}` no longer errors on unbound `CMUX_SOCKET`. Current launcher uses `set -e` only so 0.20.1 was already correct in production, but the defensive form future-proofs against any future flip to `set -u` and matches uberdev's "no implicit unbound-var reads" convention. `tests/cmux-detection.test.sh` regex relaxed to accept both `${CMUX_SOCKET_PATH:-$CMUX_SOCKET}` and `${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}` forms.
- **`tests/merge-discovery-resilience.test.sh` A11 version assertion no longer hard-codes a release version.** Previously pinned to `0.19.3` (PR #75 era); the 0.20.0 release commit (`e42d20c`) forgot to update the test, leaving 3 stale-pin failures in main between 0.20.0 and 0.20.2. The fix reads the canonical version from `plugin.json` at test runtime and asserts `marketplace.json` + `README.md` badge match — so future bumps don't keep breaking this test, and a real cross-file drift (which is what A11 was meant to catch) still fires loudly.

## [0.20.1] - 2026-05-06

### Fixed
- **`/solve` and `/turbo` cmux detection no longer falls through to standalone Ghostty when invoked from inside cmux.** `solve-pipeline/SKILL.md` Step 3 read `$CMUX_SOCKET`, but current cmux releases export the socket path as `$CMUX_SOCKET_PATH` and explicitly set `CMUX_SOCKET=` to empty string inside live sessions. The bare `[[ -n "$CMUX_SOCKET" ]]` check therefore failed inside cmux, the elif fell through to the ghostty arm (since `TERM_PROGRAM=ghostty` is set when cmux bundles Ghostty), and AppleScript activated *standalone* `/Applications/Ghostty.app` when present — keystrokes `zsh -l /tmp/solve-N.sh` then landed in whatever window held focus (browser address bar, etc.) instead of a fresh shell, and the agent never started. Detection and the explicit-override validation arm now read `${CMUX_SOCKET_PATH:-$CMUX_SOCKET}` so current-cmux installs are detected first and legacy installs still work. New `tests/cmux-detection.test.sh` (5/5 passing) locks in both env-var checks and guards against regressions to a bare `$CMUX_SOCKET`-only test. Workaround for unpatched 0.20.0 installs: `--terminal=cmux` or `export SOLVE_TERMINAL=cmux`.

## [0.20.0] - 2026-05-05

### Added
- **`/review-pr` Phase 2 simplify-lens dispatch + new `code-fixer` agent (#73 → #74).** `/review-pr` now plumbs `aspect_emphasis` to per-reviewer dispatches, honors `sequential` mode, and dispatches `code-fixer` in Phase 3 to apply advisory simplifier findings. `/simplify` Phase 2 names the `code-simplifier` dispatcher and Phase 3 dispatches `code-fixer` (audit-and-apply).
- **`code-fixer` agent.** New `agents/code-fixer.md` audit-and-apply agent that consumes simplifier-style YAML findings and produces patches; standalone `pr_number` is documented; defensive R8.6 guard added.
- **Post-impl-review fanout 5 → 6.** `post-impl-review/SKILL.md` now dispatches 6 reviewers (swap `code-simplifier` for `pr-test-analyzer` in the Phase 1 fanout). `pr-test-analyzer` migrated to standard YAML output. Config override default tracks the cap change.
- **New tests.** `tests/code-fixer-dispatch.test.sh` (locks code-fixer agent contract); `tests/simplify.test.sh` (locks `/simplify` Phase 2 + Phase 3 contract); structural assertions for 5→6 reviewer fanout in `tests/post-impl-review.test.sh`; `tests/_lib_assert_structural.sh` shared helpers; retrofitted dispatch-site assertions in `tests/review-pr.test.sh`.

### Fixed
- Stale references to "5 reviewers" in `/review-pr` and related skills propagated to "6 reviewers" so docs and audit-event text match the new fanout cap.
- Documentation: `code-simplifier` description updated to clarify Phase 2 lens role.

## [0.19.3] - 2026-05-05

### Fixed
- **R1 (in-process filter):** All three `gh … --json` discovery sites in `/merge` (Steps 1.0.5, 1.2.5, 1.4) now use `gh … --jq '<filter>'` so jq runs inside the gh process on the parsed Go object before serializing stdout. No external pipe = no FD-pollution surface for the spinner-leak bug class fixed for `/solve` in `21ad417`.
- **R2 (lib extraction):** Discovery logic factored into `plugins/uberdev/skills/merge/lib/discover.sh` (`discover_bare_fast_path` / `discover_multi` / `pr_view_projection` + `emit_gate_fail` helper). SKILL.md Steps 1.0.5 / 1.2.5 / 1.4 now source the lib via `${CLAUDE_PLUGIN_ROOT}/skills/merge/lib/discover.sh` (mirroring the existing `lib/config-read.sh` precedent — `BASH_SOURCE`/`$0` does not resolve in Claude's skill-eval context) and call the functions instead of inlining bash blocks. Eliminates the model-improv surface that re-introduced `2>&1` despite the pattern being absent from the spec text.
- New audit event `discovery_gh_failed` (members: `reason`, `step`, `exit_code`, `gh_stderr`, `pr_number?`) and new gate_fail reason `pr_view_unreachable` (Step 1.4 infrastructure failure). `gh_stderr` is raw-truncated to ≤512 bytes pre-JSON-escaping (escaped form may expand to ≤2048 bytes for adversarial backslash-heavy stderr).
- **JSON-injection defense in audit emit.** Numeric inputs (`exit_code`, `pr_number`) are sanitised to integers before bare-numeric `printf` substitution — non-numeric inputs are normalised (`exit_code` → `-1`, `pr_number` → `0` or omitted) so a caller bug or future field-source change cannot produce malformed JSON or inject extra fields into the audit log.
- New test suite `tests/merge-discovery-resilience.test.sh` (67 assertions; 14/14 test files pass) with a fake-gh fixture that simulates the spinner-leak shape (ANSI on stderr while gh succeeds on stdout). Locks: no `gh … 2>&1`, no `gh … | jq`, lib uses `--jq '<filter>'` at ≥3 sites, SKILL.md sources via `${CLAUDE_PLUGIN_ROOT}` (not `BASH_SOURCE`), audit-log path configurable via `UBERDEV_AUDIT_LOG_PATH`. Pre-processes file contents (folds backslash-continuations, strips comments) so multi-line bug-shape regressions cannot hide. Includes a canary on `solve-pipeline/SKILL.md` Step 4 detecting any revert of `21ad417`.

## [0.19.2] - 2026-05-05

### Fixed
- **`/finish-branch` skill load no longer aborts with `(eval): parse error near `)'` on the gh-pr-create comment block.** A `` `if !` `` backtick-quoted incomplete-shell-keyword inside a `#`-prefixed comment in `finish-branch/SKILL.md` (line 280) was eval'd as command substitution by the same Claude Code permission-pattern evaluator that bit #42 (heredoc delimiters) and #55 (apostrophes) — the body `if !` is unterminated bash, surfacing as a parse error and aborting the skill before the option menu / `gh pr create` path could run. Rephrased the comment to non-backticked prose ("the negated-conditional branch below") — pure prose change, zero behavioural delta. Regression canary added to `tests/finish-branch-auto-chain.test.sh` matching bash reserved words (if/then/else/elif/fi/while/for/until/do/done/case/esac/function/select/time) at the start of a backtick body inside `#`-comments; suite 36→37 passing.

## [0.19.1] - 2026-05-05

### Fixed
- **`/solve` and `/turbo` Phase A validation no longer crashes with `jq: parse error: Invalid string: control characters from U+0000 through U+001F must be escaped` (exit 5).** `solve-pipeline/SKILL.md` Step 4 captured `gh issue view --json` with `2>&1`, merging gh's stderr into `$ISSUE_JSON`. On slow API responses gh's spinner (default `spinner=enabled` in `gh config`) renders ANSI escape frames containing raw `ESC` (0x1B) — a U+0000-U+001F control character that's illegal inside a JSON string per RFC 8259 §7. The mixed bytes broke `jq -r .state <<<"$ISSUE_JSON"` mid-validation, after Step 3 had already echoed `Dispatching via: <terminal>`. Fix: capture stderr to `mktemp` and only read it on the failure path; stdout stays pure JSON. Same fail-open shape as `merge/SKILL.md` Step 1.0.5.

## [0.19.0] - 2026-05-05

### Added
- **`.claude/uberdev.local.md` knob expansion (#63, #72).** New per-project tunables: `solve_tier_floor` / `solve_tier_ceiling` clamp `/solve` and `/turbo` tier classification (`small`/`medium`/`large`); `fanout_concurrency.research` / `.post_impl_review` / `.merge_strategy` / `.conflict_resolver` cap parallel agent dispatch (bounds [1,50], defaults 5/5/10/10); `command_timeouts.solve` (enforced) / `.review_pr` (advisory) / `.merge` (advisory) bound wall-clock budgets (bounds [60,86400] seconds, defaults 14400/900/600). Each key has a corresponding env-var override (`SOLVE_TIER_FLOOR`, `SOLVE_TIER_CEILING`, `UBERDEV_FANOUT_RESEARCH`, etc.). New `plugins/uberdev/lib/config-read.sh` helper (bash-`=~` regex validation; surfaces audit-write failures rather than swallowing them) is the single read site; `solve-pipeline`, `orchestrator`, `post-impl-review`, `merge`, `using-uberdev` skills wire it through. Wave-chunking math documented as `ceil(N / CAP)` per skill.

### Fixed
- **`/finish-branch` apostrophe in `#`-comments unblocks skill load (#55, #70).** Apostrophes inside `#`-prefixed permission-evaluator preamble comments tripped the YAML/Markdown skill loader and silently dropped the skill. Phrasing rewritten to remove the contraction; regression canary `tests/finish-branch-auto-chain.test.sh` added.
- **`/solve-pipeline` `timeout(1)` invocation no longer crashes under zsh word-splitting (#63, #72).** Inlined the `timeout` call to side-step the zsh word-split footgun that surfaced when `command_timeouts.solve` was non-empty.
- **`/solve` `CLAUDE_PLUGIN_ROOT` path correction + `sed` substitution fix (#63, #72).** Launcher template substitution now resolves correctly under the marketplace install path.

### Documentation
- **README — explicit "we rejected upstream's HARD-GATE" stance now documented (#61, #69).** Adds a row to the `## Design decisions worth knowing` table plus a `<details>` block answering "why doesn't UberDev pause for approval?" and naming the three trust anchors (`spec-reviewer` always-on, `plan-reviewer` always-on, `post-impl-review` end-of-issue fanout) that replace user-approval gates.
- **Orchestrator Phase 1 artifact-reuse contract formalised + shape-check test added (#62, #71).** `orchestrator/SKILL.md` documents how cached `.uberdev/research/<run-id>/*.md` artifacts are reused across re-runs, and `spec-writer` / `plan-writer` wrap reused artifacts in `<external-untrusted-input>` envelopes (defense-in-depth against second-order injection). New `tests/orchestrator-phase1-shortcircuit.test.sh` registered in the `shape-checks` CI chain.

## [0.18.2] - 2026-05-04

### Changed
- **Post-impl review now runs after PR push, not before (#67, #68).** The 5-reviewer post-impl-review fanout (code-reviewer, simplifier, silent-failure-hunter, type-design-analyzer, comment-analyzer) has moved from the pre-push call sites in `solve-pipeline` (trivial AUTO_MODE=0 step 6 and small AUTO_MODE=0 step 5) and `subagent-driven-dev` (end-of-issue step 5) to a single canonical post-PR-push location: **`/uberdev:review-pr` Phase 1**. `/review-pr` now invokes `Skill(uberdev:post-impl-review)` directly; the skill remains the single source of truth for the parallel single-message dispatch and is no longer enumerated inline in `/review-pr`. Canonical findings artifact path is now `.uberdev/research/<RUN_ID>/post-impl-review-final.md` (no `wave-` infix; `RUN_ID` is minted by `/review-pr` per its own regex, decoupled from any earlier subagent-driven-dev `RUN_ID`). Phase 1 apply-loop reads the artifact and **MUST** wrap content in `<external-untrusted-input source="post-impl-review-aggregate">` before interpolating into any fixer prompt — defense-in-depth against second-order injection (issue-author text → diff hunk → reviewer report → aggregate → fixer). Phase 1 vs Phase 2 separate-commit invariant preserved (review-fix commits stay distinct from the simplify commit).
- **`finish-branch` PR-body glob widened to `post-impl-review-*.md`** — matches both the new canonical `post-impl-review-final.md` artifact AND any legacy `post-impl-review-wave-final.md` artifacts left over from pre-refactor runs (zero-migration). The legacy `.uberdev/research/issue-*/post-impl-review.md` glob is retained for in-flight artifacts from trivial/small inline pre-push runs. Interactive-mode Options 1/3/4 (local merge / keep / discard) carry a new caveat blockquote documenting that they bypass `/uberdev:review-pr` Phase 1 and therefore the post-impl-review fanout — only Option 2 (the default and `--turbo` auto-select) preserves the chain. Quick Reference table extended with a "Post-impl review" column.
- **Top-level `CLAUDE.md` is now `.gitignore`'d** — local-only personal Claude instructions, not part of the published plugin. `.gitignore` was already covering `.claude/` but missed the top-level file.

### Fixed
- **`/review-pr` end-of-run trust trail now anchors HEAD via empty anchor commit, not via per-simplify-commit trailer.** The pre-fix Phase 2 emit pattern wrote `Reviewed-by: uberdev/review-pr@<sha>` into the simplify commit's body itself, capturing `<sha>` from `git rev-parse HEAD` *before* the simplify commit landed — which left the trailer pointing at the **parent** (Phase 1's last commit) instead of the simplify commit's own SHA. When `/merge`'s `trust-trail-evaluator` ran `git merge-base --is-ancestor <trailer-sha> <head>` it got YES (parent → child) and `git diff --shortstat <trailer-sha> <head>` got non-empty (the real simplify changes), correctly returning `STALE` and skipping the PR with `gate_fail` reason `trust_trail_stale_sha`. Reproduced live on PR #68 (the very PR that introduced the post-push relocation): `Reviewed-by: uberdev/review-pr@2aa77b8…` on simplify commit `3f04244` with parent `2aa77b8` and a +5/−13 diff between them. Post-fix, `/review-pr` Trust-Signal Emission step appends ONE empty commit at HEAD (`git commit --allow-empty`) whose body carries `Reviewed-by: uberdev/review-pr@<PARENT_SHA>` where `<PARENT_SHA>` is captured *before* the anchor. The anchor's diff is empty by construction, so `trust-trail-evaluator` PASSes via the empty-cumulative-diff path: ancestor=YES + tree-diff=EMPTY → `PASS`. Independent of how many Phase 1 / Phase 2 commits landed, and independent of whether they pushed mid-run or batched. `git commit --amend` is **NEVER** used in trust-signal emission, so push **never** requires `--force-with-lease`. Phase 2's simplify commit body itself no longer carries the trailer. Sibling-equivalence support in `trust-trail-evaluator` is preserved for **user-side** amends made between `/review-pr` and `/merge` (the agent's M61 sibling case). `merge/SKILL.md` line 280 prose updated to reflect that `/review-pr`'s own pattern is now the empty-anchor path; sibling-equivalence is documented as covering user amends only. `tests/review-pr.test.sh` adds the R9 block (7 assertions: anchor-commit pattern named, `git commit --allow-empty` literal, `--amend` is NEVER used regression guard, `PARENT_SHA` capture, `chore(review-pr): trust trail anchor` subject literal, simplify commit body has NO trailer regression guard, anchor-commit failure path in artifact-emission failure prose). `tests/merge.test.sh` M61 motivating-case comment updated to reflect that user-side amends — not `/review-pr`'s own pattern — are the live motivating case post-v0.18.1.
- **Conflict-resolver REFUSED/AMBIGUOUS justification now surfaces in `/merge` run-summary (#64).** When the conflict-resolver agent returns `refused` or `ambiguous` for one or more files in Phase 3, the run-summary now renders a `conflict files:` sub-block (rendered only when `outcome=Parked` AND park reason is in `{refused, ambiguous}`) with per-file lowercase bracketed verdict (`[refused]` / `[ambiguous]`), `fmt -w 80`-wrapped justification, and `risks[]`. Render-time sanitisation strips C0/C1 + DEL bytes via `LC_ALL=C tr -d`; the audit log keeps raw `data.rationale` bytes — sanitisation is render-only. Previously a Parked outcome from `refused`/`ambiguous` exited without telling the user *why* per file, forcing a separate audit-log read. PASS / RESOLVED / test-fail-exhausted / push-non-ff render paths unchanged.
- **`/review-pr` Phase 1 sequential-fallback warnings now go to stderr, not `/dev/null`** (#68 Phase 1 review-fix from silent-failure-hunter). Prose explicitly forbids silent suppression or routing to an internal log file — the user must see the override warning on the same surface they invoked the command from.
- **`tests/post-impl-review.test.sh` heredoc anchor extraction now guards against silent setup-failure** (#68 Phase 1 review-fix). Previously, if the awk anchor patterns disappeared from `solve-pipeline`, `grep -qE` on empty output returned 1 — causing the assertions to PASS when they should report a setup error and hiding any heredoc reshape that broke the test's preconditions. Adds anchor-presence and body-non-empty pre-checks that emit explicit `setup error:` FAIL lines pointing at the awk extraction site.
- **`tests/merge.test.sh` 247 → 258 assertions** (M64 block: 11 new BATS-style assertions covering field/tag/conditional/sanitize-impl shape-checks for the conflict-files sub-block, scoped to a `CONFLICT_BLOCK` slice extracted via `awk '/^[[:space:]]*conflict files:/,/^\`\`\`$/'` so future template edits surface as failures rather than silently passing against incidental occurrences in surrounding prose).

### Added
- **Superpowers vendor audit + SHA-pinned provenance headers (#57, #66).** All 20 vendored superpowers files under `plugins/uberdev/skills/{test-driven-development,writing-skills,systematic-debugging}/` now carry SHA-pinned provenance headers tracing back to upstream `obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6`. Sub-files take line-1 placement; shebang scripts (`find-polluter.sh`, `render-graphs.js`) take line-2 placement after the shebang; parent `SKILL.md` files take body-first placement (after the closing `---` of the YAML frontmatter) so the dispatcher still sees `---` on line 1. Three files have intentional local divergence recorded in the suffix: `writing-skills/SKILL.md` and `writing-skills/testing-skills-with-subagents.md` carry the `superpowers:` → `uberdev:` namespace rebrand; `systematic-debugging/SKILL.md` carries the rebrand plus a local "Parallel hypothesis testing" section enhancement. The other 17 files are byte-equivalent to upstream.
- **`docs/uberdev/audits/` subdirectory** — new public-by-default doc subdirectory (parallel to `docs/rfc/`) for committed audit records. First record: the 2026-05-04 superpowers vendor audit (inventory, byte-equivalence diff results vs. upstream HEAD, attribution stack, AC mapping for #57, hardened manual re-diff procedure with `set -euo pipefail`, validated `FRESH_SHA` from `git ls-remote` (40-char check), `--fail` and `--max-time 30` on `curl`, single `mktemp` scratch file with trap-cleanup, and case-dispatched `diff` exit code (0 → MATCH, 1 → DIFFER, * → DIFF_ERROR with diff exit N to stderr) so I/O failures no longer collapse into the DIFFER branch).

## [0.18.0] - 2026-05-04

### Added
- **Bare `/merge` auto-discovers eligible PRs (#56, #65).** Invoking `/merge` with no positional argument and no `--all` flag now infers scope from ambient context: single-PR fast path when the current branch has exactly one open PR; multi-PR auto-discovery against `integration_branch` (same code path as `--all`) otherwise. Hard-errors with a clear diagnostic when the current branch has more than one open PR (ambiguity); clean exit 0 when the discovered set is empty (no eligible PRs is not a failure — preserves the Step 1.7 single-PR-pre-flight-fail-edge-case precedent). Multi-discover mode emits a `PREFLIGHT_SUMMARY_FORMAT` line to stderr listing the discovered set before Phase 2 — visibility, not a `[y/N]` prompt; the queue still proceeds unattended. Single-PR fast path preserves today's UX (no pre-flight noise).
- **Three new SKILL.md constants:** `BARE_MODE_FAST_PATH_QUERY` (current-branch fast-path query — `gh pr list --head <current_branch> --state open`), `DISCOVERY_FILTER` (canonical multi-discover filter, sole shared dispatch point for both bare-multi-discover and `--all`), `PREFLIGHT_SUMMARY_FORMAT` (the stderr summary line emitted in multi-discover mode only, 80-char wrap convention).
- **Two new SKILL.md steps:** Step 1.0.5 (mode-detect, runs pre-lock — does NOT consume `$integration_branch`, that resolution happens at Step 1.2; three-way branch on candidate cardinality 0 / 1 / N>1 with stderr breadcrumbs and no new audit-event enum member by design) and Step 1.2.5 (multi-discover dispatch, runs after Step 1.2 against the resolved `$integration_branch`; both bare-multi-discover and `--all` route through this single dispatch point per Q4).
- **Step 2.2 pre-flight summary subsection** — emits the `PREFLIGHT_SUMMARY_FORMAT` line in multi-discover mode only (Q2 + Q5). Full ordered set, 80-char wrap; not a `[y/N]` prompt; single-PR mode preserves today's UX with no pre-flight noise.

### Changed
- **`commands/merge.md` argument-hint frontmatter and Usage signature drop `[--yes|-y (deprecated)]` from the visible hint surface.** Surfacing deprecated flags in the active-surface hint contradicts the deprecation lifecycle and gives users a misleading "supported" signal. The flag is still parsed at runtime and the deprecation notice still emits — that documentation stays in the `## Deprecated Flags` section. Usage bullet 1 rewritten from "land the PR for the current branch (errors if none)" to "context-aware: single PR if on a PR branch, else discover and land all eligible open PRs against integration_branch."
- **`tests/merge.test.sh` 197 → 247 assertions** (M64–M73 block: 33 sub-assertions across 10 blocks covering the new constants, Step 1.0.5 / Step 1.2.5 dispatch sites, Step 2.2 pre-flight summary, Step 1.7 zero-eligible cross-reference, `commands/merge.md` argument-hint deprecation drop, and Phase 1.4 / Step 2.2 single-message Task() invariant preservation). M20.1 and M20.2 retired in lockstep — they asserted the now-flipped `--yes|-y`-in-hint contract; replaced with negative regression guards mirroring the new M72 contract. M20.3–M20.6 (Deprecated Flags section + "no behavioural effect" prose + flag-deprecation annotation + autopilot mention) preserved.

### Refactored
- **`/uberdev:review-pr` Phase 1 advisory fix-ups** — drop M72.length-cap (verbatim duplicate of M2's `wc -l < commands/merge.md ≤ 50` cap on the same file; flagged by 3 reviewers as redundant); tighten Step 1.0.5 detached-HEAD wording (explicitly skip step 2 entirely when current_branch is empty; forbid empty-`--head` invocation, which is undefined gh-CLI behaviour); add explicit "no audit event by design" rationale to Step 1.0.5's N>1 ambiguity hard-error path (mirrors Phase 2.1 cycle-break stderr-only convention; clarifies that Step 1.0.5 runs pre-lock so there is no audit context yet — no run_id allocated); brief acknowledgment that gh-CLI failure-mode handling is a cross-cutting concern shared with the existing `--all` discovery path (deferred to a follow-up issue).
- **`/uberdev:review-pr` Phase 2 simplify-pass high-conviction tightens** — `tests/merge.test.sh` M67 sub-checks scoped to extracted `PREFLIGHT_FORMAT_ROW` variable (mirrors M65/M66 row-variable pattern; future Step 2.2 prose additions can't accidentally satisfy uniqueness checks); M73 drops redundant `STEP_22_FOR_M73` awk extraction in favour of reusing M70's `STEP_22_BLOCK` (same range, same boundaries; shell variables are session-scoped); SKILL.md Step 1.2.5 closing paragraph tightens split-detection rationale repeat (one-sentence pointer + "do not collapse" guard, replacing 3× restated invariant). Iron rule preserved (Step 2.2 pre-flight prose 3→1 paragraph fold attempted, reverted: M70.no-prompt's negative regex is line-scoped and folding put `pre-flight` and `[y/N]` on the same line, matching the regex and failing the assertion). Final suite: 247 PASS / 0 FAIL.

### Tests
- **Suite: 247 PASS / 0 FAIL** (was 197 → +50 net: M64–M73 added 33; M67/M73 simplification consolidations and M72.length-cap drop net to the final count; M20.1/M20.2 retirement net-zero against M20-style negative regression guards). Frozen contracts upheld: five trust-gate mirror sites (M44/M46), audit JSON contract (#52), single-message Task() fanout invariant, `AUDIT_EVENT_ENUM` closed set (no new event for Step 1.0.5; stderr breadcrumb only), Phase 1.4 per-PR fanout shape.

### Backwards compatibility
- **No breaking changes.** `/merge <PR#>` and `/merge --all` invocation paths unchanged. Bare `/merge` (no positional, no `--all`) previously errored when the current branch had no open PR — now auto-discovers. Single-PR fast path on a PR feature branch is unchanged (preserves today's UX with no pre-flight noise).
- **`AUDIT_EVENT_ENUM` closed set unchanged.** Step 1.0.5 mode-detect emits a stderr breadcrumb but no new audit event — by design; the step runs pre-lock so no run_id is allocated.
- **Five trust-gate mirror sites unchanged** (M44/M46 regression guards remain green).

## [0.17.2] - 2026-05-04

### Fixed
- **`/merge` Step 1.1 lock acquisition no longer mis-classifies missing `flock(1)` on macOS as lock contention.** `flock` is not part of the macOS base system, so the previous unguarded invocation exited 127 (`command not found: flock`), and Step 1.1's error-translation classified every non-zero exit as genuine contention — surfacing `"another /merge run in progress"` on stock-macOS users' very first invocation with no actual contender. `/merge` was effectively unusable on macOS without a separate `brew install flock`. `skills/merge/SKILL.md` Step 1.1 now probes `command -v flock` BEFORE invoking it and branches: flock-available path is unchanged; flock-missing path falls back to a portable `mkdir`-based mutex at `${LOCK_FILE_PATH}.d/` (POSIX-atomic for exclusive creation), with a PID-stamp file powering the existing `kill -0` stale-lock cleanup. Concrete bash code block prescribes the acquisition + cleanup pattern including the explicit `trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM` that Step 4.6 references as the cleanup contract. Failure-mode distinctions are now load-bearing prose: missing-flock → silent fall-through (NOT contention); mkdir EEXIST + holder alive → contention; mkdir EEXIST + holder dead OR PID empty → stale, retry once; mkdir non-EEXIST (ENOSPC, EACCES, EROFS, parent missing) → distinct `"filesystem error"` diagnostic; PID-write failure → release lock dir + distinct `"cannot stamp PID"` diagnostic. The new prose closes both the original mis-classification AND three derivative silent-failure surfaces (FS-error vs contention conflation, unguarded PID-write, hopeful "MUST install trap" without literal syntax) surfaced by Phase 1 review of PR #53. Issue #51.
- **`tests/merge.test.sh` 197 → 203 assertions** (M62 block: 6 sub-assertions covering the `command -v flock` probe, the mkdir fallback, the explicit `MUST NOT.*contention` mis-classification guard, the Step 4.6 cleanup contract, the FS-error-distinct-from-contention requirement, and the literal `trap ... EXIT INT TERM` syntax). Repo-wide 475 → 481 pass / 0 fail.

### Backwards compatibility
- **No API or contract change.** `LOCK_FILE_PATH` constant unchanged; the contention diagnostic message string unchanged; the existing flock-on-Linux path unchanged. The fix is internal to Step 1.1's branch structure and adds a new portable-mutex code path for the missing-`flock` case. Existing flock-equipped systems (Linux, macOS-with-Homebrew-flock) see no behavior change.

## [0.17.1] - 2026-05-04

### Fixed
- **`trust-trail-evaluator` no longer rejects sibling-equivalent commits as `FORCE_PUSHED`.** The agent's Process Step 2 short-circuited to `FORCE_PUSHED` on `git merge-base --is-ancestor` exit 1 (non-ancestor) without ever running the tree-diff check. This blocked legitimate `/review-pr` trust trails produced by `/review-pr`'s own `git commit --amend` trailer rewrite, which generates a sibling commit (same parent, different SHA, identical tree contents) that is non-ancestor in the DAG sense but trust-equivalent. Concrete repro on first encounter: PR #50's HEAD `a410dda` was a sibling of trailer SHA `201a2dbb` via the Phase 2 trailer-amend with byte-identical trees (`git diff --shortstat` empty), yet the agent emitted `FORCE_PUSHED` → `gate_fail` → unscalable `/merge` wall. Fix defers the `FORCE_PUSHED` decision to Step 3: Step 2 now passes an `is_ancestor` flag (true on exit 0, false on exit 1) to Step 3, where the four-quadrant decision matrix combines ancestor relationship with tree-diff result — `empty diff AND is_ancestor=false` → `PASS` (sibling-equivalent rewrite), `non-empty AND is_ancestor=false` → `FORCE_PUSHED` (real history rewriting). The verdict enum stays at four members (`PASS` / `STALE` / `INVALID` / `FORCE_PUSHED`); caller-side mappings unchanged. Step 4 (log-empty) is skipped when `is_ancestor=false` because Step 3's tree-diff check is already authoritative for the non-ancestor branch. `skills/merge/SKILL.md` prose updated in lockstep — both the `Honest fast-forward fixup` paragraph and the `Stale-SHA verification primitive (D3)` paragraph now mention sibling-equivalent commits.
- **`tests/merge.test.sh` 192 → 197 assertions** (M61 block: 5 sub-assertions covering the four-quadrant decision matrix, the `is_ancestor` flag plumbing, the cited `commit --amend` motivating case, and a negative regression guard against the pre-fix `Exit 1 → verdict: FORCE_PUSHED` short-circuit). Repo-wide 470 → 475 pass / 0 fail.

### Backwards compatibility
- **No API or contract change.** The verdict enum, audit-event names, gate_fail reason strings, and caller-side mapping table are all unchanged. The fix is internal to the agent's verdict-derivation logic. PRs that previously emitted `FORCE_PUSHED` for true history rewriting still emit `FORCE_PUSHED`; the fix narrows the verdict to ONLY those cases (non-ancestor AND tree contents differ). PRs that previously emitted `STALE` for ancestor + non-empty diff still emit `STALE`. The change set is purely additive on the PASS path.

## [0.17.0] - 2026-05-04

### Changed (BREAKING)
- **`/merge` Phase 1.4 trust resolution + Phase 2.2 strategy selection are now agent-decided (#47, #49).** The structurally unsatisfiable strict trailer-SHA equality check at PATH_2 sub-condition (c) (`trailer-sha == live headRefOid` is a SHA-1 fixed-point — mathematically impossible to satisfy when the trailer is part of HEAD's own commit content) is replaced with a `trust-trail-evaluator` agent that inspects three structural primitives (`git merge-base --is-ancestor`, `git diff --shortstat`, `git log` between the trailer SHA and live head). The agent returns `TRUST_TRAIL_VERDICT_ENUM = {PASS, STALE, INVALID, FORCE_PUSHED}` with rationale and `signals_inspected`. **Honest fast-forward fixup commits between `/review-pr` and `/merge` whose cumulative tree-diff vs the trailer SHA is empty now evaluate to PASS** — typo touch-ups, comment edits, and `/review-pr`'s own Phase 2 trailer-only amends no longer force a re-run. Force-pushes that rewrite history evaluate to FORCE_PUSHED. PATH_3 (admin bypass via `--bypass-protections`) is **deleted entirely**; the CI-red waiver clause is dropped. Phase 2.2 inline signal-by-signal heuristic is replaced by a parallel `merge-strategy-decider` fanout that picks per-PR strategy in `MERGE_STRATEGY_DECIDER_VERDICT_ENUM = {squash, rebase, merge}` (`drop` is intentionally excluded from the agent's verdict — it remains a Phase 3 outcome only). Fanout chunked at `MAX_PARALLEL_AGENTS` (default 10) with `merge_strategy_fanout_wave_started` audit events per wave. Refusal cases fall back to `squash` with `rationale='agent-refusal-fallback'` so the queue continues.
- **CLI flags `--squash` / `--rebase` / `--merge` and `--bypass-protections` are deprecated.** Parsed without error for backward compat but have **no behavioural effect**. First encounter per run emits the verbatim `STRATEGY_FLAGS_DEPRECATED_NOTE` / `BYPASS_PROTECTIONS_DEPRECATED_NOTE` to stderr and records a `deprecated_flag_used` audit event. The `merge-strategy-decider` agent picks per-PR strategy from PR-shape signals; the CLI flag does NOT override the agent's choice.

### Added
- **Two new agents** under `plugins/uberdev/agents/`:
  - `trust-trail-evaluator.md` — Phase 1.4 PATH_2 sub-condition (c) dispatch site. Mirrors the conflict-resolver template: typed Inputs with `external-untrusted-input` envelopes for PR body / commit messages, restricted Tools authorised list (no Edit / Write / WebFetch), numbered Process, explicit Refusal triggers, fenced YAML return contract.
  - `merge-strategy-decider.md` — Phase 2.2 dispatch site. Five-step weighted enumeration over structural signals (commit count, conventional-commit ratio, divergence from base, WIP markers, advisory `merge-strategy:<name>` PR label, repo_convention). PR label wrapped in `<external-untrusted-input source="github-pr-label">` and treated as DATA, never WebFetched.
- **Nine new constants** in `skills/merge/SKILL.md`: `TRUST_TRAIL_VERDICT_ENUM`, `MERGE_STRATEGY_DECIDER_VERDICT_ENUM`, `STRATEGY_OVERRIDE_FLAGS`, `STRATEGY_FLAGS_DEPRECATED_NOTE`, `BYPASS_PROTECTIONS_DEPRECATED_NOTE`, `GATE_FAIL_REASON_TRUST_TRAIL_AGENT_INVALID_INPUT`, `MAX_PARALLEL_AGENTS` (default 10), `TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM` ({input_malformed, trailer_sha_not_in_local_clone}), `TRUST_TRAIL_AGENT_DECISION_RETRY_ATTEMPT_RANGE` ({0, 1}).
- **Three new audit events**: `trust_trail_agent_decision`, `merge_strategy_agent_decision`, `merge_strategy_fanout_wave_started`. Field-level extensions land on the existing `gate_pass.data.trust_anchor` and `gate_fail.data.reason`; no new event names beyond the three.
- **Bounded one-retry path** for `INVALID/trailer_sha_not_in_local_clone` (trailer SHA garbage-collected after a fresh checkout). Caller runs ONE `git fetch --prune origin <branch>` then re-dispatches the agent; second INVALID is terminal. `git fetch` failure (network, auth, branch deleted, rate limit) emits a stderr warning + `error` audit event with `data.reason="git_fetch_failed"`, then re-dispatches unchanged — autopilot continues; the queue does not halt. Mirrors Phase 3.3v's max-1-retry policy.

### Fixed
- **Pre-condition gate reasons restored to `GATE_FAIL_REASON_ENUM`** (T1 narrowed 10→7 incorrectly; total now 11). Phase 1.4 pre-flight gates emit `pr_state_not_open`, `is_draft`, `ci_red`, `merge_state_blocked` as `data.reason` regardless of trust path; the seven trust-resolution reasons remain semantically distinguished.
- **Phase 2.2 agent-refusal fallback now emits a user-facing diagnostic.** Previously fell back silently to `squash`; now emits a one-line stderr warning before falling back, plus `data.refusal_reason=<reason>` on the audit event so consumers can distinguish agent-refused vs agent-decided fallbacks.
- **Phase 1.4 "Otherwise" diagnostic reworded** to drop the structurally-close-to-the-retired-antipattern wording. Was: `run /review-pr first, then re-invoke /merge`. Now: `run /review-pr first to establish a trust trail; the next /merge invocation will pick this PR up automatically`.
- **Run-summary rationale vocabulary aligned with `merge-strategy-decider` signals.** Replaces the legacy `flag, label, heuristic, agent-decided` with the agent's actual signal vocabulary (`wip-marker`, `single-commit`, `conventional-ratio`, `divergence`, `label-hint`, `repo-convention`, `agent-refusal-fallback`).
- **Editor-note line numbers replaced with semantic anchors.** The five-mirror-site editor note carried hardcoded `SKILL.md:157` / `:415` / `:23` / `:31` / `:146` line numbers that drifted as soon as Wave 3 inserted prose into Phase 1.4. Replaced with section/heading anchors that stay accurate across future prose edits.

### Refactored
- **`/uberdev:review-pr` Phase 2 simplify pass on PR #47** — 5 of 14 advisory simplify findings auto-applied: Phase 3.4 failure-mode-table consistency, Common Mistakes bullet rephrasing, redundant `Refusal triggers:` inline label dropped from both new agent files, M55 (literal duplicate of M37.gfr3) and M57 (no-op meta-marker) deleted from `tests/merge.test.sh`, `CONVENTIONAL_COMMIT_THRESHOLD` referenced by name in `merge-strategy-decider` Process step 2(c) per the SKILL.md "values are NOT re-inlined" convention.

### Tests
- **`tests/merge.test.sh` 130 → 192 assertions.** Modified M35 (PATH_3 retirement), M37 (`GATE_FAIL_REASON_ENUM` 6 → 11 members with the four pre-condition gate reasons restored), and M45.trail (T6 wording change). Appended M47–M60 covering agent contract files, Phase 1.4 / Phase 2.2 dispatch sites, new Constants rows, deprecated stderr strings, atomic five-mirror-site update, fanout chunking prose, PATH_2 (c) retry path prose. M55 (literal duplicate of M37.gfr3) and M57 (no-op meta-marker) deleted in Phase 2 simplify. Final: **192 pass / 0 fail**.

### Backwards compatibility
- **`--bypass-protections` is a no-op post-v0.17.0.** Trust resolution is fully agent-decided via `trust-trail-evaluator`; there is no PATH_3 admin-bypass anchor and no CI-red waiver. `admin_bypass` and `waiver_recorded` audit events remain declared in `AUDIT_EVENT_ENUM` but are never emitted post-v0.17.0.
- **`--squash` / `--rebase` / `--merge` are no-ops post-v0.17.0.** Same backward-compat shape as `--yes` / `-y`: parsed without error, deprecated stderr notice + `deprecated_flag_used` audit event.
- **PATH_1 (`reviewDecision == "APPROVED"`) trust path unchanged.** Team-mode callers with branch protection are unaffected by the v0.17.0 changes; only PATH_2 (uberdev review trail) is agent-delegated.
- **Five-mirror-site atomicity preserved.** Author-identity-NOT-a-gate framing remains repeated across all five mirror sites (`skills/merge/SKILL.md` Phase 1.4 + Common Mistakes, `commands/merge.md` Autopilot + Deprecated Flags `bot_authors_allow_list`, `skills/using-uberdev/SKILL.md` `bot_authors_allow_list`).

## [0.16.1] - 2026-05-03

### Fixed
- **`finish-branch` permission-pattern `unmatched '` (#42, #45)** — Single-quoted heredoc delimiters (`<<'EOF_HEADER'`, `<<'PR_TITLE_EOF'`) in `plugins/uberdev/skills/finish-branch/SKILL.md` tripped Claude Code's permission-pattern evaluator with `(eval): unmatched '`, leaving `/finish-branch` and the `/finish` alias unrunnable (manual `gh pr create` was the only escape hatch). The evaluator's shell tokenizer doesn't honor heredoc literal-context semantics — it paired the delimiter's leading `'` with the next `'` it saw (the `PR_URL_REGEX='…'` assignment), inverted quote-balance from there, and surfaced the regex's trailing `'` as the unmatched-quote error. Fix: drop the quotes from both delimiters (`<<EOF_HEADER` / `<<PR_TITLE_EOF`); the agent contract now requires composed PR title and body bytes free of `$`, backticks, and backslash (typical PR Summary text already satisfies this). The title-injection guard is preserved end-to-end by the existing `gh --title "$PR_TITLE_VAR"` double-quoted byte-verbatim expansion. Test coverage adds an `assert_not_grep` regression canary that rejects any `<<'X'` or `<<"X"` form anywhere in the skill (`tests/finish-branch-auto-chain.test.sh` 23 → 24 assertions).

## [0.16.0] - 2026-05-03

### Added
- **`/review-pr` → `/merge` SHA-bound trust signal (#40)** — `/review-pr` on a green run now emits three durable artifacts: PR label `uberdev-approved`, commit trailer `Reviewed-by: uberdev/review-pr@<head-sha>` (full 40-character SHA), and local audit JSON at `.uberdev/runs/<run-id>/review-pr-verdict.json`. The trailer is the load-bearing trust artifact (intrinsically SHA-bound via the git object DAG); label and JSON are corroborating defense-in-depth presence checks. `/merge` Phase 1.4 reframes from a single-condition gate to **trust-resolution** with three paths: PATH_1 (`reviewDecision == "APPROVED"` — team / branch-protection), PATH_2 (`/review-pr` trail bound to live `headRefOid` — solo-dev / no-protection), PATH_3 (`--bypass-protections` admin override). New `gate_pass.data.trust_anchor` ∈ `{reviewDecision_approved, uberdev_review_trail, bypass_with_waiver}` and `gate_fail.data.reason` ∈ `{review_decision_not_approved, trust_trail_missing, trust_trail_stale_sha, trust_trail_label_missing, trust_trail_trailer_missing, trust_trail_json_missing, ci_red, pr_state_not_open, is_draft, merge_state_blocked}` field-level extensions land on the existing `gate_pass` / `gate_fail` events (no new event names).
- **Stale-SHA detection covers force-push + amend + rebase + squash uniformly.** Phase 1.4 PATH_2 (c) compares the trailer's embedded `<head-sha>` against **live** `gh pr view <N> --json headRefOid` (NOT against any local ref). One verification primitive covers all rewrite types. Refusal diagnostic: `/review-pr ran on commit <trailer-sha> but PR head is now <live-sha> — re-run /review-pr, then re-invoke /merge`.
- **Five new constants** in `skills/merge/SKILL.md`: `UBERDEV_APPROVED_LABEL`, `REVIEW_PR_TRAILER_PREFIX`, `RUN_ID_REGEX` (`^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` — path-traversal hardening), `TRUST_ANCHOR_ENUM`, `GATE_FAIL_REASON_ENUM`.
- **Editor note at `skills/merge/SKILL.md:125` corrected** from "four mirrors" to "five mirror sites" with explicit file:section enumeration of all 5 (this skill body, this skill's `## Common Mistakes`, `commands/merge.md:23`, `commands/merge.md:31`, `skills/using-uberdev/SKILL.md:146`).

### Changed
- **`/review-pr` exit codes are now 0 / 1 / 2** (was always 0). `0` = green (Phase 1 APPROVE + Phase 2 status ∈ {ran/APPROVE, skipped}); `1` = Phase 1 REJECT or REVISIONS_REQUIRED; `2` = Phase 2 status `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure). **Behavioral break** for callers that scripted against the always-0 contract — either ignore the exit code (preserve old behavior) or branch on it (use new behavior). Surfaces silent reviewer-crash failures that the trust signal exists to eliminate.
- **`commands/review-pr.md:82-83` prose updated in lockstep** with the exit-code contract change. Distinguishes "skipped" (Phase 2 not run; eligible for green; exit 0) from "blocked" (Phase 2 fanout crashed; exit 2). The previous "still exits successfully" wording is removed.
- **`tests/merge.test.sh` 103 → 130 assertions** (12 new M-blocks M35–M46, 27 new sub-assertions covering trust-signal constants, PATH_1/PATH_2/PATH_3 trust-resolution structure, gate_pass/gate_fail enum values, stale-SHA primitive, and mirror-site sync). **`tests/review-pr.test.sh` 33 → 43 assertions** (R1–R6, 10 new sub-assertions covering the green-run predicate, label/trailer literals, exit-code table, and run-id regex).

### Fixed
- **`code-simplifier` agent persona reframed as audit-only (#43)** — frontmatter description and system-prompt body claimed the agent "applies project best practices", but `code-simplifier` dispatched by `uberdev:post-impl-review` only emits YAML findings and never modifies files. The mismatch silently dropped simplifier value on every wave/inline review (LLM read the persona literally, expected to write code, then emitted nothing actionable). Reframe touches `plugins/uberdev/agents/code-simplifier.md` (frontmatter description, system-prompt body, three example blocks, audit/refinement-process steps — all now read as audit-only: "audits", "advisory findings", "you do not modify files") and `plugins/uberdev/skills/post-impl-review/SKILL.md` (skill description marks reviewers as advisory; Q1-deferral and "Per Q1" wording replaced with an explicit audit-only invariant plus pointers to the writer entry points `/uberdev:simplify` and `/uberdev:review-pr` Phase 2). Output Rules block (cite-by-`file:line` + secret-leak prevention) preserved verbatim. Out of scope: agent rename, post-impl-review delegating to apply machinery, no SDD or solve-pipeline changes — both already treat aggregation as advisory PR-body text.

### Refactored
- **Drop redundant applier-pointer trailer in `code-simplifier` system prompt (#43)** — Phase 2 `/uberdev:review-pr` simplify pass converged across all three lenses (reuse, quality, efficiency) on the same finding: the appended Output Rules trailer ("To apply findings, the user runs `/uberdev:simplify` or `/uberdev:review-pr` Phase 2.") duplicated the identical applier pointer already present in the line-87 closing activation paragraph ("a follow-up `/uberdev:simplify` / `/uberdev:review-pr` Phase 2 invocation can act on. **You do not modify files.**"). Iron rule preserved: documented contract is unchanged — line 87 retains both the applier pointer and the bolded **You do not modify files.** sentinel; the `## Output Rules — secret-leak prevention` block remains byte-identical. Tightens the system prompt by ~20 tokens per dispatch — `code-simplifier` runs on every wave/inline review, so the saving compounds.

### Backwards compatibility
- **Trust-signal emission is additive on green runs.** Existing `/review-pr` invocations on REJECT / REVISIONS_REQUIRED paths produce no new artifacts (label not added, trailer not written, JSON not created). The exit-code change is the only behavioral break; CHANGELOG calls it out explicitly.
- **`/merge` Phase 1.4 trust resolution preserves PATH_1 (existing `reviewDecision == "APPROVED"` behavior).** Team-mode callers with branch protection are unchanged. PATH_2 is only consulted if PATH_1 fails. PATH_3 (`--bypass-protections`) is unmodified.
- **No new packages, no infra changes, no schema migrations.** Pure additive markdown driver edits + bash shape-check tests. Rollback is a single PR that removes the artifact-emission logic, reverts Phase 1.4 to the single-condition gate, and resets the 5 mirror sites.

## [0.15.2] - 2026-05-02

### Fixed
- **Trivial- and small-tier `/solve` and `/turbo` PRs were silently skipping the `/uberdev:review-pr` chain — and with it the entire Phase 2 simplify ceremony.** The 4 heredocs in `solve-pipeline/SKILL.md` (`trivial-solve`, `trivial-turbo`, `small-solve`, `small-turbo`) ended with `Open PR with Closes #N` and a *negative* directive ("Do NOT run `/uberdev:simplify` standalone before push — Phase 2 of `/uberdev:review-pr` runs it automatically"), but **never told the spawned agent to actually invoke `/uberdev:review-pr` after `gh pr create`**. Trivial/small bypass `finish-branch` entirely (they call `gh pr create` directly), so the canonical chain hand-off (`finish-branch` Option 2 → invoke `uberdev:review-pr` via the Skill tool, line 296) never fired either. The chain was implicit — the spawned agent had to read user-global `CLAUDE.md` ("MANDATORY: run `/uberdev:review-pr` after pushing the PR. No exceptions, hotfixes included.") and infer the next step on its own. Same class of bug as the orchestrator Phase 2 fix in v0.15.1: the heredoc-prose was relying on inference where it should have been imperative.
- **Net effect of the bug:** trivial/small PRs got a Phase-1 review fanout *only if* the spawned agent independently decided to run `/review-pr`; the 3-lens simplify pass (reuse / quality / efficiency) — wired to fire as Phase 2 of `/review-pr` — never ran on trivial/small at all. Medium/large was unaffected (orchestrator → subagent-driven-dev → finish-branch → invoke `uberdev:review-pr` is hard-coded and locked by an existing test assertion).
- **Tightened all 4 heredocs.** Added an explicit numbered final step to each: `Capture the PR URL from gh pr create output and invoke the uberdev:review-pr [--turbo] skill via the Skill tool with that URL. This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory — do NOT block on REVISIONS_REQUIRED.` Turbo heredocs forward `--turbo` into `/review-pr` to keep the chain unattended (mirrors `finish-branch`'s `--turbo` propagation pattern).

### Added
- **`tests/turbo-flow.test.sh` 55 → 57 assertions.** Two new positive locks:
  - `Capture the PR URL` literal anchor count must equal 4 (one per heredoc; future edits cannot delete the directive from one heredoc while leaving three intact).
  - `uberdev:review-pr --turbo` literal anchor count must equal 2 (trivial-turbo, small-turbo) so a future edit cannot drop `--turbo` propagation and re-introduce attended-mode regressions on trivial/small turbo runs.

  These mirror the pre-existing count=4 lock on the negative `Do NOT run /uberdev:simplify standalone before push` directive — both directives now move in lockstep, neither can drift without test failure.

## [0.15.1] - 2026-05-02

### Fixed
- **`/solve` was silently collapsing into `/turbo` for medium/large tier.** The launcher heredoc was correct (no `--turbo` written when `AUTO_MODE=0`, locked by the existing differential guard at `tests/turbo-flow.test.sh:91-103`); the regression was in `plugins/uberdev/skills/orchestrator/SKILL.md` prose. Phase 2 Q&A is the **only** phase that distinguishes `/solve` from `/turbo` for medium/large — every other phase (research fanout, spec-writer, spec-reviewer, plan-writer, plan-reviewer, subagent-driven-dev, finish-branch auto-PR) is unattended in both modes — and the prose around Phase 2 was too soft for a freshly-spawned LLM with no prior-conversation anchor:
  - **Skill description** called Q&A `optional` and spec-reviewer `optional`. Both stale: spec-reviewer is always-on for medium/large per Phase 3.5, and Q&A is the load-bearing /solve-vs-/turbo signal. "Optional" read as "agent's choice" → spawned agents skipped Q&A → /solve felt like /turbo.
  - **Phase 2 non-turbo prose** led with `unchanged — ask 3-5 clarifying questions…`. The word `unchanged` referenced previous-version behavior, but a freshly-spawned LLM has no "previous version" to reference; the line read as filler with no imperative force. No `MUST`, no gate language, nothing preventing the LLM from concluding "the issue is well-specified, no questions needed".
  - **`AskUserQuestion` is a deferred tool** in current Claude Code harnesses (calling without `ToolSearch` first throws `InputValidationError`). The skill never mentioned this; a spawned agent that hit the error could silently fall back to "best guess" and continue — indistinguishable from turbo.
- **Tightened all three sites.** Phase 2 now leads with "this phase is the only signal that distinguishes /solve from /turbo… Do not skip", uses imperative `You MUST ask 3-5 clarifying questions`, adds explicit `Do NOT proceed to Phase 3 until the user has answered` gate, and includes a `ToolSearch` instruction (`select:AskUserQuestion`) with a `Do NOT silently auto-pick on tool-load failure` rule. Skill description rewritten to drop "optional" mis-signals: `research fanout → Q&A [interactive unless --turbo] → spec-writer → spec-reviewer [always-on for medium/large] → plan-writer → plan-reviewer [always-on] → subagent-driven-dev`.

### Added
- **`tests/turbo-flow.test.sh` 48 → 55 assertions.** New `orchestrator Phase 2 imperative gate` section locks the imperative phrasing (`You MUST ask 3-5 clarifying questions`), the explicit `Do NOT proceed to Phase 3` gate, the "only signal that distinguishes /solve from /turbo" anti-skip prose, the `ToolSearch select:AskUserQuestion` deferred-tool callout, and the `Do NOT silently auto-pick on tool-load failure` rule. Two `assert_not_grep` canaries ban the stale `optional Q&A` and `optional spec-reviewer` strings from re-appearing in the description. Full suite still passes (322 assertions across 11 test files).

## [0.15.0] - 2026-05-02

### Refactored (simplify-loop edits from `/uberdev:review-pr` Phase 2)
- **Step 5b sed forks 6 → 1** (efficiency lens) — Phase B was running six sequential `sed -i` invocations per spawn to template the launcher script (`REPO_ROOT`, `CLAUDE_BIN`, `ISSUE_NUM`, `TIER`, `DETECTED_TERMINAL`, `PERM_FLAG_VALUE`). All placeholders are unique tokens with no cross-substitution risk, so they collapse into one `sed -e ... -e ... -e ...` call. Saves 5 forks per spawn × N issues — small per-call win that compounds across batch dispatches. `PERM_FLAG_VAL` setup hoisted above the consolidated sed so substitution-value computation reads contiguously. In-place semantics (`SED_INPLACE` BSD/GNU dispatch) and per-expression delimiter choice (`|` vs `/`) preserved.
- **Dead-alternation regex split into two single-line assertions** (quality lens) — `tests/turbo-flow.test.sh` had a TURBO MODE banner assertion whose left-hand alternation (`for n in "${ISSUE_NUMS[@]}"…\n…medium…\n…break`) was dead code: `grep -E` without `-z` does not match across newlines, so only the right-hand alternation (`TIERS[$n].*medium`) ever fired. Split into two genuine assertions: one greps for the dedup loop construct, the other for the `break` after the first medium-tier hit. Same prose intent, more rigorous lock.
- **Reuse lens** — analyzed 5 candidates (heredoc consolidation, `osascript` heredocs, sed substitutions, notification fallback chain, comment redundancy); all rejected as either test-locked, right-sized, or net-negative for clarity. The four trivial/small heredocs are contractually locked at count=4 by `tests/turbo-flow.test.sh`; the iTerm vs Terminal.app `osascript` heredocs use distinct AppleScript verbs (not duplication); the notification fallback chain is three single-line branches with no genuine indirection win.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **zsh word-split footgun in multi-issue parser** — initial Phase 1 implementation used `for token in $ARGUMENTS; do …`, which does NOT word-split scalar parameters in zsh (SH_WORD_SPLIT off by default). Under zsh — Claude Code's actual Bash-tool shell on macOS — the loop saw `"5 6 7"` as a single token, the anchored `^[0-9]+$` rejected it, and `/turbo 5 6 7` died at the usage check (`/turbo 42` worked only because `"42"` happens to satisfy the regex when treated as one token). Replaced with a portable subshell pipeline: `ISSUE_NUMS=($(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++'))`. Array assignment `arr=($(cmd))` word-splits the substitution output on `$IFS` in BOTH bash and zsh; the pipeline tokenizes on spaces, anchored regex rejects flag tokens like `--terminal=foo123`, awk dedupes preserving first-seen order. New regression test in `turbo-flow.test.sh` greps the pipeline form so the footgun cannot reappear.
- **Phase A title/tier had no concrete defaults** — initial pass left `TITLES[$ISSUE_NUM]="$TITLE"` and `TIERS[$ISSUE_NUM]="$TIER"` referencing variables that prose comments told Claude to set. Now the bash block computes both deterministically: `TITLE_RAW=$(jq -r .title <<<"$ISSUE_JSON")` with a 40-char ellipsis truncation, and `TIER="${OVERRIDE:-medium}"` (the safe escalation default — `--trivial`/`--small` override; ambiguity routes through the full brainstorm pipeline). The triage prose above the bash block still drives Claude to downgrade when an issue is genuinely trivial/small, but the dispatch is now valid even if the heuristic refinement is skipped.
- **Phase B silently dropped per-issue dispatch failures** — initial pass appended unconditionally to `SPAWNED+=("#$ISSUE_NUM ($TIER)")` after the `case` statement, so a failing `cmux new-workspace` (dead socket) or AppleScript permission denial never surfaced — the user saw "Spawned 3 agents" while one had actually died. Now `DISPATCH_RC=$?` after the case and an `if/else` route success to `SPAWNED` and failure to `DISPATCH_FAILED`. Ghostty's branch ends in an `echo` for both AppleScript-success and AppleScript-fail-then-nohup paths, so both legitimately record as success (the agent is spawned either way, just via a different mechanism). Phase B failure summary block prints partial-batch failures to stderr; the success notification body appends `— N dispatch failure(s)` if any. Locked by 2 new assertions (`DISPATCH_FAILED` array, `DISPATCH_RC=$?` capture).
- **Apple Event queue claim softened** — the comment justifying why iTerm/Terminal don't need the Ghostty 600 ms pause read "(Apple Event queue serializes)" as a load-bearing fact; reworded to "(the Apple Event queue serializes same-application AppleScript calls in practice)" to flag it as an empirical observation, not an unconditional API guarantee.

### Added
- **`/turbo` and `/solve` accept multiple issue numbers** — `/turbo 5 6 7` (and `/solve 5 6 7`) validates each listed issue (OPEN + classifiable) before dispatching, then spawns one autonomous Claude agent per issue into its own terminal session (cmux workspace / Ghostty tab / iTerm window / Terminal.app window / nohup background process). Per-issue artifacts are namespaced by `$ISSUE_NUM` (`/tmp/solve-prompt-N.txt`, `/tmp/solve-N.sh`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch, `#N <title>` tab) so the spawns are collision-free. Single-issue invocation behaviour is byte-identical. Override flags (`--trivial|--small|--full`, `--auto`, `--terminal=...`) apply batch-wide; per-issue overrides are not supported (run separate invocations for different tiers).
- **Phase A validate-all-first contract in `solve-pipeline/SKILL.md`** — if any of the listed issues is closed, missing, or fails `gh` fetch, all errors are printed and the run aborts with `no agents dispatched` **before** spawning anything. No partial-state cleanup ever required. Phase B then loops the per-issue dispatch (write prompt → write launcher → spawn into chosen terminal).

### Changed
- **`solve-pipeline/SKILL.md` restructured into Phase A (validate) + Phase B (spawn).** Step 1 parses `ISSUE_NUMS` array (anchored `^[0-9]+$` rejects `--terminal=foo123`-style flag tokens; dedupe prevents same-issue race on shared worktree path). Step 3 hoists terminal detection + REAL_CLAUDE binary resolution + TURBO MODE banner out of the per-issue loop (terminal-detect runs once; banner prints once if any tier is medium). Steps 4 (was 3) becomes Phase A; Steps 5a/5b/5c (were 4/5/6) execute inside the Phase B `for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do ... done` loop. The medium `if [[ "$AUTO_MODE" == "1" ]]; then ... else ... fi` block is preserved at column 0 (zsh/bash do not require indentation inside `for ... done`), so `tests/turbo-flow.test.sh`'s differential-guard awk anchor remains valid.
- **Ghostty multi-spawn serialized with 600 ms pause.** AppleScript `Cmd+T` keystroke dispatch is asynchronous; firing three keystrokes in <100 ms can race all three into the first-created tab. Pause applies only when `TERMINAL=ghostty` AND `${#ISSUE_NUMS[@]} > 1`. cmux (IPC API), iTerm/Terminal (scripted `create window`/`do script`, Apple Event queue serializes), and nohup all spawn race-free without the pause.
- **Notifications batched.** One summary `cmux notify` / `terminal-notifier` / `osascript display notification` per `/turbo` invocation listing all spawned issues, replacing the prior N per-spawn notifications. Removes notification flooding on multi-issue runs.
- **`tests/turbo-flow.test.sh` 29 → 48 assertions.** New section locks the multi-issue parser (portable subshell pipeline with `tr`+`grep -E '^[0-9]+$'`+`awk '!seen[$0]++'`, zsh word-split footgun comment, Phase A error-printf format, all-errors-before-abort), Phase A contract (`no agents dispatched`, validate-all-first), Phase B loop construct (`for ISSUE_NUM in "${ISSUE_NUMS[@]}"`, `DISPATCH_FAILED` tracking, `DISPATCH_RC=$?` capture), TURBO MODE banner-printed-once dedup mechanic (`break` after first medium hit, split into two single-line assertions because `grep -E` without `-z` does not match across newlines), Ghostty serialization (`sleep 0.6`), batched-summary notification (`SPAWNED[@]`), and REAL_CLAUDE-hoist line-ordering. Wrapper section gains argument-hint shape assertions for both `/solve` and `/turbo`.
- **`tests/ghostty-dispatch-no-instance-leak.test.sh` awk anchor updated.** The dispatch case moved from `### 6.` to `#### 5c.` inside the new Phase B for-loop; the test's section-extraction awk pattern follows. Same 7 assertions as before; no contract change.
- **`/turbo` and `/solve` command frontmatter** updated: `argument-hint` becomes `<issue-number> [<issue-number>...]`; `description` notes multi-issue dispatch; usage examples added showing `/turbo 5 6 7`.
- **README.md `/turbo` section** gains a "Multi-issue dispatch" paragraph after the orthogonality table.

### Backwards compatibility
- **No user-facing breakage.** `/turbo 42` and `/solve 42` (single-issue) behaviour is byte-identical to 0.14.0. New multi-issue syntax is purely additive. No flag deprecations. Plugin manifest version bumped 0.14.0 → 0.15.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.14.0] - 2026-05-01

### Changed
- **`/uberdev:merge` is now unconditionally non-blocking** — every blocking gate that previously halted the queue or asked the user a question has been removed. Specifically: the Phase 1.4 PR-author allow-list condition (`PR author is repo collaborator OR ∈ bot_authors_allow_list`) is **deleted** — any APPROVED + CI-green PR is eligible regardless of author identity (collaborator, bot, external contributor); the trust anchor is `reviewDecision == "APPROVED"` plus GitHub branch protections. The Phase 2.2 step 3 external-author defer logic, the `defer` strategy, and the `pr_deferred` audit event are deleted along with it. Phase 1.3's ask-and-persist branch prompt is replaced by a literal `INTEGRATION_BRANCH_FALLBACK` (`main`) with a one-line stderr warning — autopilot does not ask, it acts. Phase 2.1 dependency-cycle abort is replaced by auto-break-via-createdAt-fallback. Phase 3.3vi push-non-FF halt is replaced by per-PR park (`PARK_REASON_ENUM` value `push-non-ff`); queue continues. Phase 4.2 `git pull --ff-only` halt is replaced by auto-rebase against `origin/<integration_branch>`; on rebase conflict the rebase aborts (preserving local head) and the divergence surfaces in the run summary while the run still completes. Phase 1.7 single-PR pre-flight fail now exits cleanly with a "no eligible PRs" summary rather than erroring. The pre-flight banner now reads `/merge autopilot — no prompts, no halts; per-PR failures park and the queue continues.` (the `Allow-listed authors:` line + Print-Twice rule are removed). The only remaining halt is `flock` contention from another live `/merge` (concurrent-run safety, not a user gate).
- **`bot_authors_allow_list` config key is now DEPRECATED** alongside `auto_confirm` / `--yes` / `-y`. Parses without error for backward compat but has no behavioural effect. `using-uberdev/SKILL.md` config-key documentation updated to reflect both deprecations and the new literal-`main` integration-branch fallback.
- **`tests/merge.test.sh` 90 → 103 assertions.** M22 splits into M22.drop (positive) + M22.no-defer (negative — STRATEGY_ENUM must NOT list the removed `defer`). M23 drops `pr_deferred` from the required audit-event list and adds an explicit M23.no-pr_deferred negative. M24 swaps the `external-author-not-allow-listed` PARK_REASON_ENUM assertion for `push-non-ff` (the new park reason) and adds M24.PARK.no-ext-author negative. M27 drops the `Deferred:` outcome assertion and adds M27.no-Deferred negative. M28 retargets the banner-content scope from "all of Phase 1" to "just Step 1.0" so the legitimate Phase 1.4 deprecation prose isn't tripped by the negative grep. M16 retargets from the removed atomic-rename mktemp pattern (no more persist step) to a negative guard that Step 1.3 contains no `mktemp` / `mv` / `[Y/n]`. New M16b verifies Phase 1.3 ships the fallback-branch existence check (`git ls-remote --heads origin` + `fallback-branch-missing` audit event). New M29–M33 cover the no-blocker contract directly: M29 (Phase 1.4 has no author gate), M30 (Phase 1.3 falls back to `INTEGRATION_BRANCH_FALLBACK` with no prompt), M31 (Phase 4.2 auto-rebases on ff-only fail), M32 (Phase 3.3vi parks PR on push-non-FF, queue continues), M33 (Phase 2.1 auto-breaks dependency cycles via createdAt fallback) — M33 collapsed to a single positive check + explicit `M33.no-old-rule` negative regression guard. New M34 directly inspects the Phase 3.4 failure-mode table for the no-halt invariant (Action column may never list `halt`). Suite total: 342/342 across 11 test files.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **`agents/conflict-resolver.md` orphan halt-prose** — line 56 still claimed `status: AMBIGUOUS halts the queue`, contradicting the new no-halt invariant in `skills/merge/SKILL.md` Step 3.3iv. Replaced with the correct park-and-continue contract; the calling skill maps the agent's status to a `pr_parked` audit event with `data.reason="ambiguous"` or `"refused"`.
- **`commands/merge.md` Deprecated Flags now lists `bot_authors_allow_list`** alongside `--yes` / `-y` / `auto_confirm`. The deprecation story was previously split across two files (`using-uberdev/SKILL.md` + `skills/merge/SKILL.md`) but missing from the command's own help; readers consulting `/merge` documentation now see the full list.
- **`skills/merge/SKILL.md` Phase 1.3 fallback-branch existence check** — added `git ls-remote --exit-code --heads origin "<INTEGRATION_BRANCH_FALLBACK>"` probe before proceeding to Step 1.4. Repos whose default branch is not `main` (e.g. `master`, `trunk`, `develop`) and whose four-tier resolution fails would previously have hit a confusing `gh pr merge --base main` 404 several phases downstream; now /merge declines cleanly with `error` audit event `data.reason="fallback-branch-missing"` and a one-line stderr pointing the user at `integration_branch:` config.
- **CHANGELOG 0.13.0 backfill** — PR #35 ("/merge true autopilot") bumped the manifest version but skipped its own CHANGELOG entry; the gap is now backfilled to keep Keep-a-Changelog readers consistent.

### Backwards compatibility
- **No CLI breakage.** Existing `/merge` invocations work identically; the surface change is purely the removal of failure modes that previously rejected work the user wanted to land. `/merge --yes` / `-y` / `auto_confirm` / `bot_authors_allow_list` remain parseable (deprecated). Plugin manifest version bumped 0.13.0 → 0.14.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.13.0] - 2026-05-01

### Changed
- **`/uberdev:merge` initial autopilot pass** (#35, PR #35) — removed the `[y/N]` plan-confirm prompt at Phase 2.4; deprecated `--yes` / `-y` CLI flags and the `auto_confirm` config key (parsed without effect, with a stderr deprecation notice and a `deprecated_flag_used` audit event). Stale-branch handling at Phase 4.5 became autopilot agent-decided with safety-precondition gates (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection). Constants table grew with `AUTO_CONFIRM_KEY`, `AUTO_CONFIRM_FLAGS`, `AUTO_CONFIRM_REASON_ENUM`, `STALE_REBASE_DECISION_ENUM`, `TEST_FAIL_DECISION_ENUM`, `DEPRECATED_FLAGS_NOTE`. Six new audit events added: `pr_parked`, `pr_deferred`, `stale_branch_rebase_decision`, `deprecated_flag_used`, `agent_strategy_switch`, `test_fail_agent_decision`. Test-fail handling at Phase 3.3v gained a 1-retry-1-switch agent-decided branch tree (re-resolve / strategy-switch / park) with audit-logged choices.
- **`/uberdev:review-pr` chains a mandatory simplify-pass** (PR #32) — Phase 1 review-and-fix loop is followed by Phase 2 simplify fanout; pre-push standalone `/simplify` calls collapsed since they duplicated work.
- **`/uberdev:review-pr` collapses duplicate `/simplify` pass** (PR #37) — the pre-push `/simplify` call in trivial/small heredocs duplicated work already done by Phase 2 of `/uberdev:review-pr`. Removed from solve-pipeline heredocs; saves three Task agent invocations per `/solve` trivial/small run with no quality loss.

### Fixed
- **`/solve` Ghostty dispatch instance leak** (#31, PR #33) — the auto-dispatched Claude agent no longer poisons the user's running Ghostty session.
- **Trust-boundary asymmetries flagged by `/uberdev:review-pr`** — orchestrator and merge skills tightened against prompt-injection-shaped content in untrusted external inputs (PR/issue bodies, conflict markers).

## [0.12.0] - 2026-04-30

### Added
- **`/uberdev:merge`** (#24, PR #27) — new top-level command + skill that orders, strategizes, and merges approved PRs end-to-end. 4-phase pipeline (pre-flight gate → merge plan with single user-confirm → merge + parallel conflict-resolve in scratch worktree → post-merge local sync) at `plugins/uberdev/skills/merge/SKILL.md`. New `agents/conflict-resolver.md` with textual-evidence return contract and 6 refusal triggers, dispatched one Task per conflicted file in a single assistant turn. New per-repo config keys `integration_branch` (CLI flag > env var `UBERDEV_INTEGRATION_BRANCH` > config file > `gh repo view --json defaultBranchRef`, with ask-and-persist fallback) and `bot_authors_allow_list` (default `["dependabot[bot]", "renovate[bot]"]`). Audit log at `.uberdev/runs/<run-id>/audit.jsonl`. `tests/merge.test.sh` ships 16 shape-check assertions (M1–M16) including the `Co-Authored-By: Claude` proximity guard and same-directory `mktemp` atomic-rename guard.
- **Auto-install for top-level aliases** (#21, PR #26) — `hooks/session-start` now auto-installs the six short-form forwarders (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`) on first session and refreshes them on plugin upgrade — no manual `/uberdev:install-aliases` step. Idempotent via `~/.claude/.uberdev-aliases-version` marker. Opt-out via `UBERDEV_NO_AUTO_ALIAS=1` (env, wins) or `auto_install_aliases: false` in `.claude/uberdev.local.md`. ALIASES table extracted into a shared helper `plugins/uberdev/lib/aliases-sync.sh` sourced by both the hook (auto-install) and `/uberdev:install-aliases` (manual install) — single source of truth, A6 drift test now reads from the helper. Marker-scoped collision skip preserves hand-authored files; `mktemp + mv -f` atomic-rename writes; symlink-containment guard refuses to sync into `~/.claude/commands` if it's a symlink. New `tests/aliases.test.sh` sections S1–S9 cover fresh install, second-session no-op, version-marker refresh, both opt-out paths (env + file), hand-authored file preservation, symlink containment, unreadable-marker degradation, concurrent-session race, CI wire-up.

### Changed
- **`/uberdev:finish-branch` defaults to push + create PR** (#20, PR #25) — the legacy 4-option menu (Merge / Push+PR / Keep / Discard) moves behind a new `--interactive` flag; default and `--turbo` paths now auto-push the branch, open a PR, then chain into `/uberdev:review-pr` via the `Skill` tool. Fulfills the global `~/.claude/CLAUDE.md` "MANDATORY: run `/uberdev:review-pr` after pushing the PR" rule by construction. Hardens the new auto-push path against (a) **title injection** via heredoc + quoted-variable read-back (closes the `gh pr create --title "<title>"` shell-substitution vector) and (b) **secret leakage** via a layered pre-push scan (gitleaks primary, regex floor for AWS / GH PAT / private-key shapes when gitleaks is missing) over both the to-be-pushed commit range AND the composed PR body file. The 6 reviewer agents whose output flows into the PR body (`code-reviewer`, `pr-test-analyzer`, `comment-analyzer`, `silent-failure-hunter`, `type-design-analyzer`, `code-simplifier`) gain a `## Output Rules — secret-leak prevention` "do not quote source/secrets" rule. New `tests/finish-branch-auto-chain.test.sh` and `tests/review-pr.test.sh` lock the contracts; `tests/turbo-flow.test.sh` retargeted to assert default-auto-PR + interactive-restores-menu + Skill-tool-chain canary.

### Fixed
- **Linux-only mtime test failure in `tests/aliases.test.sh` (S2/S3)** — try GNU `stat -c %Y` before BSD `stat -f %m`. On Linux GNU stat, `-f` is filesystem-mode (not format-string) and `%m` is treated as a missing file path, so the command dumps multi-line filesystem info on stdout *and* exits non-zero, which then ran the `-c %Y` fallback whose mtime got *appended* to the same captured value. The S2/S3 comparisons compared a multi-line blob (NEW) to an awk-extracted single token "File:" (OLD) — guaranteed to fail on every Linux runner. Order reversed; both macOS and Linux now exercise the same idempotency-equivalence assertion (52→55 assertions after also extending S1/S5/S8 to the 6th alias `/merge`).

### Backwards compatibility
- **No user-facing breakage.** Existing `/uberdev:finish-branch` invocations still work; `--interactive` restores the legacy 4-option menu for users who relied on it. `/uberdev:install-aliases` continues to be a valid manual entry point alongside the new auto-install. New `/uberdev:merge` and the `/merge` short-form alias are purely additive. Plugin manifest version bumped 0.11.0 → 0.12.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.11.0] - 2026-04-30

### Added
- **Top-level command aliases** (#16, PR #17) — `/uberdev:install-aliases` writes one-way forwarders into `~/.claude/commands/` so the five daily-driver commands work without the `uberdev:` namespace prefix: `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`. `/uberdev:uninstall-aliases` removes them (marker-scoped — hand-authored files preserved). Existing `/uberdev:<command>` invocations are unchanged (additive only). Forwarders capture the absolute plugin-install path at write time; no body duplication. Run `/uberdev:install-aliases` once after plugin install to opt in. `tests/aliases.test.sh` (27 assertions) pins the marker contract, collision detection, and README discoverability.

### Changed
- **`/issue` slimmed to 2 Sonnet scouts** (#14, PR #18) — replaces the prior 8-Opus-agent research fanout (Phases 1.5/2-4/4.5/7) with a thin 2-Sonnet-scout fanout (`codebase-scout`, `triage-scout`) dispatched in a single assistant turn. **Median wall-clock drops from minutes to under 30s.** New dedicated agents at `plugins/uberdev/agents/codebase-scout.md` and `triage-scout.md`, both pinning `model: sonnet` with four-layer defence-in-depth against the upstream `affaan-m/everything-claude-code#173` model-frontmatter regression. Documented escape hatch: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`. `--no-explore` soft-deprecated (notice + no-op, removal target v1.0.0). `## Security signals` / `## Current ecosystem` / `## Constraints` sections removed from `/issue` templates. `brainstorm/SKILL.md`'s issue-research short-circuit removed (orchestrator solve-time fanout unchanged). RFC `2026-04-29-issue-deep-root-cause-research-fanout.md` annotated as partially superseded.
- **`/solve` and `/turbo` deduped via shared skill** (#15, PR #19) — extracts the ~360-line shared launcher pipeline (arg parsing, repo detection, tier classification, prompt heredoc, terminal spawn, notify, retitle) from `commands/solve.md` (430 → 27 lines) and `commands/turbo.md` (452 → 29 lines) into a new inline skill at `plugins/uberdev/skills/solve-pipeline/SKILL.md` (397 lines). Both commands now set `export AUTO_MODE={0,1}` and invoke the skill; the 10 `DELTA from /solve:` / `DELTA from /turbo:` markers and the `DUPLICATION NOTE` banner are gone — divergence is now expressed as `if [[ "$AUTO_MODE" == "1" ]]` conditionals in a single source of truth. Renamed the legacy `AUTO_MODE` (permission-mode flag) to `AUTO_PERMISSIONS` inside the skill to disambiguate from the new `AUTO_MODE` (turbo-vs-interactive). `tests/audit-fixups.test.sh` adds C6/C7 (skill exists, no `context:` frontmatter, AUTO_PERMISSIONS count ≥ 3, both wrappers ≤ 100 lines); `tests/turbo-flow.test.sh` pins both wrapper-to-skill links and the AUTO_MODE exports. Suite goes 83 → 92 assertions.

### Backwards compatibility
- **No user-facing breakage.** `/uberdev:solve` and `/uberdev:turbo` invocations are byte-equivalent in behavior; the wrappers now delegate to `solve-pipeline`. `/uberdev:issue --no-explore` still parses but is soft-deprecated. The `legacy cache` heredoc step in solve-pipeline's trivial/small tiers no-ops on issues created after the #14 redesign (no more `.uberdev/research/issue-N/` writes from `/issue`); legacy issues whose research was persisted under the previous fanout still get inlined.

## [0.10.0] - 2026-04-29

### Added
- **CI shape-check workflow** at `.github/workflows/test.yml` — single ubuntu-latest job runs all `tests/*.test.sh` on every push and PR with `permissions: contents: read` and `timeout-minutes: 5`. `actions/checkout@v4` major-tag pin.
- **Plan-drift awareness in per-task spec reviewer** (`subagent-driven-dev`). New `## Plan Task Description` placeholder in `spec-reviewer-prompt.md`; new `plan_task_description` dispatch parameter in `SKILL.md` step 4f with a ~3000-token excerpt size guard. Reviewer DO-list bullet directs flagging *plan drift* (structural deviation from plan even when spec appears satisfied — e.g., implementer skipped prescribed steps, swapped libraries, merged tasks).
- **Threat model section** in `plugins/uberdev/skills/brainstorm/SKILL.md` — documents localhost-only bind, single-user assumption, no auth, no proxy/tunnel for the brainstorm WebSocket+HTTP companion server.
- **Shared reviewer-prompt template** at `plugins/uberdev/skills/_shared/document-reviewer-template.md` — canonical Status/Issues/Recommendations skeleton referenced (via back-link comments) from `brainstorm/spec-document-reviewer-prompt.md` and `write-plan/plan-document-reviewer-prompt.md`. Skills don't auto-include partials; this is a documentation convention plus drift-defense reference.
- **2 new test suites:**
  - `tests/spec-reviewer-plan-aware.test.sh` (3/3) — verifies plan-drift wiring in spec-reviewer prompt + SKILL.md.
  - `tests/audit-fixups.test.sh` (12/12) — regression coverage for the C1/C3/C4/C5 review-fixup contracts: code-simplifier auto-trigger gate, stop-server `stopped_no_cleanup` JSON status, `gh` prereq moved from theatre command-files to `hooks/session-start`, brainstorm `## Threat model` section anchor.
- **Configuration documentation** in `README.md`: split into Implemented (`solve_terminal`, `solve_auto`) and Planned (`solve_tier_default`, `review_depth`, `parallel_solve`) tables with YAML-frontmatter example and env-var override precedence.
- **Tracked public docs**: `docs/rfc/` is now ignored-with-exception (`docs/*` + `!docs/rfc/`) so RFCs referenced from README/CHANGELOG resolve in clones; `plugins/uberdev/docs/testing.md` smoke-test matrix tracked.

### Changed
- **3 shell hooks hardened against symlink and path-traversal abuse:**
  - `hooks/inject-brainstorm-answers`: previous `[ -L "$f" ]` symlink check covered only the resolved file, not ancestors. Replaced with `is_safe_path()` helper that canonicalizes and walks every ancestor; refuses a symlinked root entirely; falls back to `python3 os.path.realpath` on macOS where BSD `realpath -m` is missing. `is_safe_path()` rejections now log to stderr (previously silent).
  - `skills/brainstorm/scripts/stop-server.sh`: replaced `[[ "$SESSION_DIR" == /tmp/* ]]` glob (passed for `/tmp/../home/...` traversals) with canonicalize-then-exact-prefix `case` over `/tmp/brainstorm-*` and `/private/tmp/brainstorm-*`. JSON shape now distinguishes success (`"stopped"`) from skipped cleanup (`"stopped_no_cleanup"` with `"reason"` field) — callers can detect partial failures.
  - `hooks/session-end`: replaced `rm -rf /tmp/uberdev-*` (followed symlinks) with `find -H /tmp -maxdepth 1 \( -name 'uberdev-*' -type d \) -not -type l -exec rm -rf {} +`. The `-H` is required because `/tmp` is itself a symlink on macOS.
- **`canonicalize()` helper** (used by the two hardened hooks): captures python3/realpath stderr into a variable and emits a useful diagnostic on total failure with helper-name prefix. Admins can now distinguish "tool unavailable" from "path rejected."
- **`code-simplifier` agent description AND body** narrowed to require explicit invocation. Body's "operate autonomously and proactively, refining code immediately after it's written" prose removed — it had directly contradicted the new gating frontmatter. The agent now activates ONLY when invoked via `/uberdev:simplify` or by the `subagent-driven-dev` post-wave fanout. Examples retained but framed as "illustrating logic, not licensing auto-trigger."
- **`gh` prerequisite check moved from markdown-command-file theatre to a real runtime guard** in `hooks/session-start` — Claude reads command markdown as instructions, not bash, so the prior `command -v gh || exit 1` blocks were never executed. New session-start check mirrors the existing `jq` check and injects a one-time visible warning when `gh` is missing without failing the session.
- **`/solve` ↔ `/turbo` divergence annotated**: verified Claude Code commands do not support textual file partials (the `@path` syntax is context-attachment, not substitution), so the original "extract `_solve-shared.md`" plan was infeasible. Both files now carry a `DUPLICATION NOTE — KEEP IN SYNC` banner with section-anchor references plus inline `<!-- DELTA -->` markers at every divergence point. Inline markers are the source of truth; the banner index is for navigation only. Out-of-scope follow-up: `/turbo` trivial/small tier omits the `post-impl-review` invocation that `/solve` includes.
- `eval "$VAR=1"` → `declare "$VAR=1"` in `skills/brainstorm/SKILL.md:124` and `skills/orchestrator/SKILL.md:68`. Currently safe (TOPIC iterates a hardcoded list) but a footgun if ever driven from external input.
- `hooks-cursor.json` paths normalized from `./hooks/...` to `${CLAUDE_PLUGIN_ROOT}/hooks/...` matching `hooks.json`.
- `.gitignore` adds `.env*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa*`, `node_modules/`, `*.log`, `.claude/`, plus explicit ignores for `plugins/uberdev/docs/{plans,uberdev,windows}/` (local-only design notes).
- Generic-ified `/Volumes/FJK SSD/...` example paths in `commands/{solve,turbo}.md` to `/Users/me/My Project/...`.

### Security
- 3 P0 path-traversal/symlink hazards in shell hooks closed (above).
- `server.cjs` carries an explicit localhost-only / single-user / unauthenticated header note pointing to the new SKILL.md threat model section.

### Backwards compatibility
- `stop-server.sh` JSON: callers parsing the literal `"stopped"` string would now correctly fail-loud when cleanup is skipped (the new `stopped_no_cleanup` status replaces `stopped` only on partial failure). `grep -rn '"stopped"'` confirmed no in-repo consumers depend on the old shape.
- Markdown `command -v gh || exit 1` removal is invisible to runtime (the blocks were never executed); the new session-start warning replaces them.

Closes the audit findings catalogued by the multi-agent research sweep on PR #13.

## [0.9.0] - 2026-04-29

### Added
- **`/uberdev:issue` Phase 2-4 fanout grows from 4 → 8 Task agents** in a single assistant turn. Existing four (`research-codebase`, `research-patterns`, duplicate-search, label/scope-validation) plus `research-prior-art`, `research-constraints`, `research-security` (Semgrep MCP + awesome-secure-defaults), `research-test-coverage` (test-surface mapping). Issue templates gain `## Current ecosystem`, `## Constraints`, and conditional `## Security signals` sections. `NO_EXPLORE=1` narrows to the four in-repo agents only.
- **Always-on spec/plan/PR-test reviewers** (tier-independent quality bar). Orchestrator Phase 1 short-circuits per-topic against `.uberdev/research/issue-<N>/` (mirrors brainstorm). Spec-reviewer is always-on for medium AND large; `--paranoid` deprecated as a no-op. New Phase 4.5 dispatches `plan-reviewer` (1-retry, non-blocking). New Phase 5.5 runs `pr-test-analyzer` pre-merge for large tier.
- **`uberdev:post-impl-review` skill** — 5-agent advisory fanout (`code-reviewer`, `simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`) in a single message. Invoked by `/solve` trivial/small inline prompts AND by `subagent-driven-dev` after each wave.
- **Non-blocking `/turbo` Q&A.** Orchestrator Phase 2 under `--turbo` auto-picks each clarifying answer using research-bundle synthesis and writes `questions.md`. `finish-branch` Option 2 reads it and appends `## Open questions answered by /turbo` (Question | Choice | Confidence) plus `## Reviewer findings summary` to the PR body.
- New agent definitions: `agents/research-security.md`, `agents/research-test-coverage.md`.
- Tests: `tests/post-impl-review.test.sh` (10/10 — frontmatter, 5 reviewer agent names, single-message invariant, both call-site refs, anti-loop guard); `tests/issue-causal-fanout.test.sh` extended to 39/39 (8 new 8-agent assertions + 1 new `--no-explore` 4-agent assertion); `tests/turbo-flow.test.sh` extended to 19/19 (9 new always-on-reviewer assertions).

### Changed
- **`--paranoid` flag is now a no-op.** Spec-reviewer runs unconditionally for medium and large tiers. Old `tier == medium AND --paranoid` gate prose removed from orchestrator; deprecation prose retained for two flag mentions.
- `brainstorm` step 2 short-circuit pattern relaxed to match generic loop variable naming used by orchestrator artifact-reuse.

### Backwards compatibility
- `--paranoid` still parses without error (deprecated no-op) — pre-v0.9 invocations continue to run.
- Issues created before v0.9.0 retain a 4-agent fanout fallthrough when no `## Current ecosystem` / `## Constraints` sections are present in the body.

Closes #11.

## [0.8.0] - 2026-04-29

### Added
- **`/uberdev:issue` deep root-cause research fanout.** Phase 2 now dispatches a 2-agent parallel fanout (`research-codebase` + `research-patterns`) when `NO_EXPLORE=0`, in the same single message as the existing Phase 3 (Duplicate Search) and Phase 4 (Label/Scope Validation) Task() calls — four agents fan out together, Phase 4.5 aggregates all four returns. Research summaries write to `.uberdev/research/run-<RUN_ID>/` and rename to `.uberdev/research/issue-<ISSUE_NUM>/` after `gh issue create`.
- **Bug-template `## Likely root cause` is now a causal triple** — `**Symptom:**` (observable failure), `**Mechanism:**` (specific code/data path), `**Owning code:**` (path/symbol — the assumption to challenge). Optional 5 Whys nested chain for non-trivial bugs. Replaces the previous file-list placeholder.
- **`/uberdev:brainstorm` short-circuit on `.uberdev/research/issue-<N>/`.** When invoked downstream of `/issue` for the same issue number, brainstorm reads the persisted summaries instead of re-dispatching equivalent research agents. Per-topic skip (codebase + in-repo prior art only — external prior art still dispatches); mtime-based staleness fallback; clean fallthrough for issues created before this change.
- **Body authoring rules subsection in `issue.md`** — codifies the WHAT/HOW boundary ahead of the templates: issue body says what is broken or wanted, never how to fix it. Implementation strategy is `/uberdev:brainstorm`'s job.
- **`tests/issue-causal-fanout.test.sh`** — structural-assertion test (modelled on `tests/turbo-flow.test.sh`) locking the contract invariants: Phase 1.5 RUN_ID/SUMMARY_DIR, Phase 2 4-agent single-message fanout, `--no-explore` placeholder verbatim, causal triple labels, feat template rename invariant, Phase 7 artifact-binding rename, brainstorm short-circuit + per-topic skip + stale-check + backwards-compat fallthrough.
- **RFC:** `docs/rfc/2026-04-29-issue-deep-root-cause-research-fanout.md` records the why (2-agent rather than 4-agent fanout, stable artifact directory rather than return-value handoff, triple rather than freeform causal essay, field rename rather than rules-text reminder) and rejected alternatives.

### Changed
- **Feat-template field rename:** `## Proposed approach` → `## What changes`. Field-name pressure replaces rules-text pressure for keeping implementation strategy out of the issue body. Downstream parsers (`/solve`, `/turbo`, `/orchestrator`) read only `**Triage hint:**` from the body, so the rename is contract-preserving.
- **Phase 4.5 aggregate** in `issue.md` extended to reconcile two new research returns (`codebase.md` drives the bug-template triple and `## Likely area`; `patterns.md` drives the `## Related` prior-pattern bullets and informs the causal chain when prior bugs exist).
- **Rules subsection** in `issue.md` gains a WHAT/HOW boundary bullet: issue body never contains an implementation checklist or fix design.

### Backwards compatibility
- No breaking change to issue-body parsing. `**Triage hint:**`, severity checkboxes, label format, and conventional-commit titles all preserved verbatim.
- Issues created before v0.8.0 have no `.uberdev/research/issue-<N>/` directory; brainstorm's short-circuit `[ -d ... ]` check returns false and falls through cleanly to the existing parallel-dispatch path. No data migration.

Closes #9.

## [0.7.1] - 2026-04-29

### Fixed
- `/turbo` unattended chain now propagates `--turbo` end-to-end through every handoff (`brainstorm` → `write-plan` → `subagent-driven-dev` → `finish-branch`). PR #8 closed issue #5 architecturally by making `write-plan` non-interactive, but `finish-branch` was still prompting at the chain tail because none of the downstream skills forwarded `--turbo`. `finish-branch` now auto-selects "Push and Create PR" under `--turbo` and announces the auto-selection.
- `orchestrator` Phase 5 forwards `--turbo` to `subagent-driven-dev` — closes the medium/large `/turbo` gap PR #8 introduced (`/turbo` for medium/large tier routes through `/uberdev:orchestrator --turbo`, but Phase 5 was invoking `subagent-driven-dev` without forwarding the flag, so the chain still stalled at `finish-branch`).
- `finish-branch` Step 5 cleanup behavior reconciled with the file's own Quick Reference table and Red Flags section: cleanup runs only for Options 1 (Merge locally) and 4 (Discard). Option 2 (Push and create PR) leaves the worktree alive for PR-feedback fixups; Option 3 (Keep as-is) is explicit. Pre-existing contradiction surfaced as a live runtime bug under `/turbo` — unattended runs auto-route to Option 2.

### Added
- `tests/turbo-flow.test.sh` — 9 contract assertions locking the `--turbo` propagation contract at every handoff (`brainstorm`, `write-plan`, `subagent-driven-dev`, `finish-branch`, plus `orchestrator` Phase 5 and the `/turbo` command entry point). Default-mode regression canaries also included so future edits can't silently break the non-`--turbo` paths.

## [0.7.0] - 2026-04-28

### Added
- `/uberdev:orchestrator` skill — writer-subagent pipeline used by `/solve` and `/turbo` for medium/large tier issues. Drives 5 phases: research fanout (parallel Sonnet subagents) → optional Q&A (skipped for `/turbo`) → spec-writer (Opus) → optional spec-reviewer (Opus, gated by `--paranoid` for medium tier; always for large tier) → plan-writer (Opus, with internal research fanout) → existing `subagent-driven-dev`. Each writer returns a structured YAML summary; orchestrator main holds pointers, not raw artifacts. Reclaims spawned-agent context for wave dispatch and error recovery.
- 8 new agent definitions: `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints` (Sonnet); `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer` (Opus). Each is invokable via Task() dispatch with a strict universal return contract.
- `--paranoid` flag on `/uberdev:orchestrator` enables spec-reviewer for medium tier issues.

### Changed
- `/solve` and `/turbo` medium/large tier prompts now invoke `/uberdev:orchestrator` instead of `/uberdev:brainstorm` directly. Trivial and small tier paths unchanged. `--turbo` flag now propagates as `/uberdev:orchestrator --turbo …`.
- `brainstorm` skill: added a note acknowledging `/solve` and `/turbo` route through the orchestrator skill; brainstorm itself remains the canonical reference and the right invocation for ad-hoc design work.
- `write-plan` skill: execution handoff is now non-interactive — defaults to subagent-driven; explicit user opt-in for inline. Resolves the `/turbo` unattended-flow break (issue #5).

### Fixed
- `/turbo` no longer halts on a "Subagent-Driven vs. Inline Execution?" prompt during plan handoff. Closes #5 (architecturally, via the writer-subagent refactor in #6).

## [0.6.0] - 2026-04-28

### Added
- `/solve` Ghostty dispatcher tab-spawns into the originating Ghostty window when invoked from inside Ghostty (`TERM_PROGRAM=ghostty`), keeping per-project workspaces visually grouped instead of cluttering the desktop with new top-level windows. `SOLVE_GHOSTTY_NEW_WINDOW=1` forces the legacy new-window behavior; AppleScript failures (e.g. Accessibility permission denied) fall back to it automatically with a stderr warning.
- `/turbo <issue>` slash command: unattended `/solve` that auto-accepts the brainstorm phase's lead-agent recommendations for medium/large tiers (parallel research still runs — recommendation grounding preserved). Trivial/small tiers behave identically to `/solve`. Composes orthogonally with `--auto` (permission-mode flag); `/turbo <issue> --auto` is the max-autonomy combo. No new approval gates — only collapses the clarifying-questions loop. `/turbo` also gains the same Ghostty tab-spawn behavior as `/solve`.
- `/solve --auto` (and `/turbo --auto`) flag: enables Claude Code's `--permission-mode auto` classifier in the spawned agent. Auto-approves low-risk ops (file edits, reads, package installs) and blocks high-risk ones (force push, `rm -rf` on pre-existing files, exfil, self-modification, `--dangerously-skip-permissions`). Resolves from CLI flag → `SOLVE_AUTO=1` env → `solve_auto: true` in `.claude/uberdev.local.md`. `/turbo <issue> --auto` is the max-autonomy combo.

### Changed
- `brainstorm` skill: parallel research dispatch promoted to **default first step** (before clarifying questions; skipped only for trivial tasks). The 2-3 proposed approaches are now grounded in research synthesis, not speculation. No approval gates added — "single forward pass" stays.

### Removed
- Deprecated slash-command shims `/uberdev:brainstorm`, `/uberdev:execute-plan`, `/uberdev:write-plan` removed. They were Superpowers-port leftovers redirecting to the canonical skills of the same name; invoke the skills directly via the Skill tool instead.

## [0.5.0] - 2026-04-28

### Added
- `SessionEnd` hook: best-effort cleanup of `~/.claude/.uberdev-answers`, `/tmp/uberdev-*` (plugin-prefixed only), and brainstorm event files older than 24h.
- `PreCompact` hook: append `.claude/auto-memory.md` to `.claude/session-archive.md` before compaction wipes context (silent no-op when absent; refuses to write through a symlinked `.claude/`).
- `.claude/uberdev.local.md` per-project configuration (YAML frontmatter for tier, review depth, terminal, parallel toggle); env vars override file settings.
- `AskUserQuestion` fast-path in `brainstorm` skill for discrete direction selection (2-5 options) without spinning up the visual companion. Visual companion remains the primary path for full design exploration.
- `isolation: "worktree"` guidance in `subagent-driven-dev` skill — Pattern B's controller-only-git approach is the documented opt-out; everything else defaults to worktree isolation.
- YAML frontmatter (`description`, `argument-hint`, `allowed-tools`) on `/issue` and `/solve` — were previously missing, leaving the picker with empty descriptions and triggering permission prompts on every `gh`/`find`/`osascript` call.
- `CONTRIBUTING.md` (contributor onboarding: quick start, repo layout, conventional commits, branch naming, PR expectations, `/simplify` mandate).
- `CHANGELOG.md` (Keep-a-Changelog 1.1.0 format covering v0.2.0 → v0.5.0).

### Changed
- 5 detail-oriented agents (`comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `plan-reviewer`, `type-design-analyzer`) switched from `model: inherit` to `model: haiku`. Since `/uberdev:review-pr` dispatches all 7 agents in parallel and is bound by the slowest, switching the detail agents to Haiku 4.5 cuts wall-time ~15-20%.
- `code-simplifier` agent rules made stack-agnostic — was hardcoding JS/React conventions (ES modules, `function` keyword, React Props types); now defers to project CLAUDE.md / style guide and language-agnostic clarity rules.
- `plugin.json` description trimmed from ~1.4 KB to one impactful sentence (marketplace listing aesthetics).
- `/uberdev:simplify` `allowed-tools` gains `Edit`, `Write`, `MultiEdit` (was hitting permission prompts on every fix attempt).
- `/uberdev:review-pr` `allowed-tools` narrows `Bash` to `Bash(git*)`, `Bash(gh*)` (read-only command).

### Fixed
- **Critical:** v0.4.0's `/issue` Phase 2/3/4 parallel fanout was silently broken — subagents have no shell context, so `$REPO`/`$DESC`/`$KEYWORDS`/`$COMMITLINT` references in agent briefs didn't resolve. Now resolves in orchestrator bash and bakes literal values into each agent brief.
- **Security (RCE):** `/solve` no longer passes `--dangerously-skip-permissions` to the autonomous agent. A malicious GitHub issue body could otherwise have executed under the user's account; the spawned agent now runs in an interactive terminal where the user gates each permission.
- **Security (prompt-injection):** `inject-brainstorm-answers` hook validates each event line as JSON via `jq`, HTML-escapes `<`/`>`, and refuses symlinked event paths. Closes a vector where any process in the cwd could plant arbitrary closing tags + instructions in the next user turn.
- `session-start` hook replaces fragile manual `escape_for_json` + `printf '%s'` interpolation with `jq -Rs`-style construction. Handles control bytes 0x00-0x1f and stray `%` format-spec collisions that previously corrupted output.
- `pre-compact` hook now refuses to write through a symlinked `.claude/` directory (`[ -d ]` follows symlinks; explicit `[ ! -L ]` guard added).
- Cross-platform `sed -i` in `/solve` — was BSD-only `-i ''` (broke on Linux with `sed: can't read : No such file`); now detects platform via `uname` and uses correct syntax on macOS + Linux.
- `session-start` no longer captures stderr into the SKILL.md content variable (`2>&1` → `2>/dev/null`); a missing skill file now degrades to empty injection rather than appearing as `Error reading…` content.

### Performance
- `inject-brainstorm-answers` per-line `jq -e -c .` fork loop collapsed to a single streaming `jq -R 'fromjson? // empty'` call. Saves ~200-500ms per UserPromptSubmit on active brainstorm sessions (50+ events).
- Two filesystem walks in `inject-brainstorm-answers` (blanket symlink scan + events-file `find`) folded into one targeted walk.

## [0.4.0] - 2026-04-28

### Added
- Parallel-fanout orchestration spread across the plugin: `/uberdev:review-pr` flips its default from sequential to **parallel** (all applicable review agents dispatch concurrently in a single turn).
- `/uberdev:issue` Phase 2/3/4 (codebase investigation + duplicate search + label/scope validation) runs as three parallel agents — roughly 60-70% wall-time savings.
- `systematic-debugging` skill gains **competing-hypothesis fanout** — read-only investigators per hypothesis, no anchoring on the first guess.
- `brainstorm` skill gains optional parallel design-direction exploration for high-stakes designs.
- `write-plan` skill gains opt-in alternative-plan generation (3 decomposition strategies).
- `receiving-code-review` skill adds multi-reviewer parallel triage.

### Changed
- `verification-before-completion` skill documents parallel verification dispatch (independent test/lint/build/typecheck checks running concurrently).
- Documented the parallel-default as a deliberate divergence from upstream `pr-review-toolkit`.

## [0.3.1] - 2026-04-28

### Changed
- `/uberdev:simplify` realigned with Anthropic's built-in `/simplify`: three-parallel-agent orchestrator — Code Reuse, Code Quality, and Efficiency reviewers fan out concurrently in a single Task-tool turn; controller aggregates findings and fixes them.
- Iron rule preserved (no behavior changes), plus UberDev's separate `refactor:` commit mandate.

### Fixed
- Restored proactive-trigger examples in the `code-simplifier` agent that were dropped during the orchestrator refactor.

## [0.3.0] - 2026-04-28

### Added
- Full Superpowers parity port: `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev` skills.
- Brainstorm Visual Companion: Neo Brutalism UI served by a local server, with `frame-template.html`; sessions persist to `.uberdev/brainstorm/`.
- `SessionStart` hook that injects the `using-uberdev` primer at conversation start so Claude knows how to discover plugin skills.

## [0.2.1] - 2026-04-27

### Added
- Wave-based parallel execution (Pattern B) in `/solve` and `/uberdev:subagent-driven-dev`: every task in a wave dispatches in parallel; waves run sequentially.
- `uberdev:write-plan` requires three new headers per task (`Depends on:`, `Wave:`, `Owns:`) and an `## Execution Waves` summary so dependencies and file ownership are explicit.

### Changed
- One shared feature-branch worktree across all waves — no per-task worktree, no merge step between waves.
- Controller (not implementers) runs `git add` / `git commit` to eliminate `.git/index.lock` races. Implementers report changed paths instead.

## [0.2.0] - 2026-04-27

### Added
- Initial public release of the UberDev marketplace and `uberdev` plugin.
- `/solve <issue-number>`: spawns an autonomous Claude agent in a new terminal session (cmux / Ghostty / iTerm / Terminal.app / nohup) with tier-aware triage — trivial issues skip the brainstorm; large ones get the full plan-and-review pipeline.
- `/issue <description>`: eight-phase pipeline that creates a well-investigated, deduped, label-validated GitHub issue, including codebase search, full-text dedup against closed issues, commitlint scope validation, and a triage hint that `/solve` reads later.
- Bundled skills: `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch` — `/solve` runs standalone with no Superpowers / pr-review-toolkit / code-simplifier dependency.
- Bundled review agents: `code-reviewer`, `code-simplifier`, `comment-analyzer`, `plan-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`.
- Bundled commands: `/uberdev:review-pr`, `/uberdev:simplify`.

### Changed
- Documentation: README expanded with `Updating` section explaining manual vs auto-update for third-party marketplaces (`docs:` commit `007537b` on 2026-04-27 superseded by this release).

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.16.0...HEAD
[0.16.0]: https://github.com/TheFJK/UberDev/compare/v0.15.2...v0.16.0
[0.9.0]: https://github.com/TheFJK/UberDev/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/TheFJK/UberDev/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/TheFJK/UberDev/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/TheFJK/UberDev/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/TheFJK/UberDev/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/TheFJK/UberDev/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
