# Testing UberDev

UberDev's product is **markdown prompt files, shell libraries, a little Python, and (per RFC 0012) on-disk Workflow orchestration scripts in JavaScript** — there is no application server and no build step. The test suite reflects that: it is a set of **shape-check scripts** (`tests/*.test.sh`) that grep the shipped command / agent / skill / lib files for the exact tokens, contracts, and invariants each change is supposed to preserve. A few fixtures additionally *execute* a sourced `lib/` helper (or, for workflow scripts, a sandboxed dry-run — see the T1–T4 tier below) to lock a runtime behaviour, but the suite is grep-and-assert throughout — it never spins up a real Claude Code session.

## The harness at a glance

- **Where:** every test lives in `tests/` and is named `<name>.test.sh`.
- **Runner:** there is no separate runner binary — each file is self-contained and run directly with `bash tests/<name>.test.sh`. The `tests/*-zsh.test.sh` fixtures run under `zsh` instead — see below.
- **What CI runs:** `.github/workflows/test.yml` is the **single source of truth** for the active test set. Do not maintain a second hand-curated list anywhere — read `test.yml`.
- **Shared assertion library:** `tests/_lib_assert_structural.sh` provides the section-scoped `assert_in_section` / structural helpers that many tests `source`.
- **Workflow-script harness:** `tests/_workflow_harness.js` is a node-run helper (not a test file itself) that `tests/workflow-scripts.test.sh` drives for the T1–T4 workflow-script tiers below.

## Running tests locally

The canonical list of tests is whatever `.github/workflows/test.yml` runs. To run the whole suite locally the way CI does, drive it from that file rather than copying file names by hand:

```bash
# Run every tests/*.test.sh on disk (mirrors what CI gates on; needs zsh for
# the zsh-runtime fixtures — see below).
for t in tests/*.test.sh; do
  echo "== $t =="
  case "$t" in
    tests/*-zsh.test.sh) zsh "$t" || exit 1 ;;   # zsh-runtime fixtures
    *) bash "$t" || exit 1 ;;
  esac
done
```

To run a single test (the normal inner-loop while editing one command or skill):

```bash
bash tests/review-pr.test.sh
```

The shape-checks read the files in your checkout directly, so they need no plugin install. To additionally smoke-test that an edited command or skill still *loads* in Claude Code, reinstall the local plugin (the marketplace key is `uberdev@uberdev`): `/plugin install uberdev@uberdev`, then confirm `/plugin` → Installed → `uberdev` reports no errors.

Each test prints a `PASS` / `FAIL` line per assertion and a `== Summary ==` block, and **exits non-zero if any assertion failed**. `test.yml` runs every fixture through a `run_one` helper that records each failure and exits non-zero at the end naming all of them, so **a red file no longer hides the files after it** — scan the whole log, not just as far as the first `--- FAIL` (#628; the shape is locked by `tests/ci-wiring.test.sh` W12).

### The zsh-runtime fixtures

Every `tests/*-zsh.test.sh` fixture is run with **`zsh`**, not `bash` — `tests/solve-pipeline-zsh.test.sh` is the original. SKILL.md `bash` fences execute under Claude Code's Bash tool, which is `/bin/zsh` at runtime, so these fixtures lock behaviour that only manifests under zsh's word-splitting and array semantics (e.g. the v0.22.2 regression where a scalar `EFFORT_FLAG="--effort max"` broke under `SH_WORD_SPLIT=off`). The naming convention is load-bearing, not decorative: `tests/docs-accuracy.test.sh` asserts that every fixture `test.yml` invokes with `zsh` matches the `*-zsh.test.sh` glob, so the one-line local loop above stays truthful as fixtures are added. `ubuntu-latest` does not ship `zsh` by default, so the CI job installs it before running the suite. Run one locally with `zsh tests/solve-pipeline-zsh.test.sh`.

### The workflow-script tier (T1–T4)

RFC 0012 migrates the heavy pipelines onto on-disk Workflow orchestration scripts (`plugins/uberdev/skills/<name>/workflow.js`, children under `skills/<name>/workflows/`). Those scripts get their own four-tier check, driven by `tests/workflow-scripts.test.sh` (a normal `.test.sh`, wired into **both shape-check jobs** — node is preinstalled on the ubuntu and windows images) with `tests/_workflow_harness.js` as its engine:

| Tier | What it locks | Where |
| --- | --- | --- |
| **T1 — lint** | every glob-discovered workflow script parses as ESM via the **pinned** stdin form `node --check --input-type=module < "$f"` (bare/unpinned `node --check` flips between Node versions on the `export const meta` + top-level-await shape); forbidden-token greps (`import`/`require`/`process.`/`fs.`/`Date.now`/`Math.random`/`new Date(` outside `SHARED` marker blocks); 512 KB runtime size cap | `workflow-scripts.test.sh` (shell) |
| **T2 — meta validation** | the `meta` export is a **pure-JSON literal** between `/* META-BEGIN */` and `/* META-END */` markers; `{name, description, phases[]}` shape; every `phase()` / `opts.phase` string literal is declared in `meta.phases` | `_workflow_harness.js validate` |
| **T3 — behavioral dry-run** | the harness strips the meta export, wraps the body in an async IIFE and executes it via `vm.runInNewContext` under **faithful runtime stubs** (`agent()` canned returns keyed by label/agentType; `parallel` = barrier + thunk-throws-to-null; `pipeline` = no inter-stage barrier + item drop; budget with falsy `total` by default; `Date.now`/`Math.random`/argless `new Date()` shadows that THROW). Dead-circuit-breaker bugs become executed, deterministic tests | `_workflow_harness.js validate` + per-pipeline fixtures |
| **T4 — shared-snippet drift** | `// === SHARED:<name> v<N> ===` … `// === END SHARED ===` blocks with the same name+version must be **byte-identical** across scripts (scripts are self-contained; shared code is copy-paste) | `_workflow_harness.js shared-drift` |

The harness ships **self-tests** (`node tests/_workflow_harness.js self-test`) locking every stub semantic and the preprocessing step, so the tier is non-vacuous even while zero `workflow.js` files exist on disk. Every dry-run budget in the harness is a **hang detector**, never a stopwatch — one generous default, overridable per host with `UBERDEV_HARNESS_TIMEOUT_MS` (positive integer ms; a malformed value refuses with rc=2 rather than falling back). Tight per-call-site literals used to red a byte-identical harness at random on a contended Windows runner (#396), and a failing self-test row now names its cause on the `  FAIL` line itself, because that is the only line CI surfaces. `workflow-scripts.test.sh` also enforces the RFC 0012 §4.2 shape guard: every on-disk `skills/*/workflow.js` must have a sibling `SKILL.md` carrying both the Workflow invocation block and a `## No-Workflow fallback` section. Authoring conventions live in `plugins/uberdev/skills/writing-skills/SKILL.md`; the args-envelope contract (`uberdev_emit_workflow_args`, RFC 0012 §4.3) is locked by `tests/workflow-args.test.sh`.

## What the tests check (and what they don't)

These are **structural / contract** checks, not end-to-end behavioural tests of a running agent:

- **Prompt-file contracts** — that a command or agent file still names every dispatch slot, every required flag, every documented argument, and every guard rail it is supposed to (e.g. `review-pr.test.sh` asserts the seven Phase-1 reviewers run in one or more cap-controlled waves, with every child in each wave dispatched before its first wait).
- **Runtime behavioural fixtures** — a subset `source` a real `lib/` helper and assert its output. Examples: `solve-pipeline-zsh.test.sh` (zsh word-splitting), `goal.test.sh` BT84 / BT85 (goal-pipeline behaviour), `config-override.test.sh` (config precedence), `secret-scan.test.sh` (the pre-push scanner). So the suite is **not** purely static — the claim "no behavioural tests" is false.
- **Release-ratchet version locks** — `goal.test.sh` (the `G20: version bump locked` block) and `solve-claim.test.sh` (the `Version bump A.B.C -> X.Y.Z propagated` block) hardcode the current version and **turn CI red on a missed bump**. They are part of the mandatory bump-everywhere ritual (see the root `AGENTS.md`, "Bump version EVERYWHERE before merge"). A contributor who skips the full suite skips exactly the tests that catch a forgotten version bump.
- **CI-wiring invariant** — `tests/ci-wiring.test.sh` asserts that *every* `tests/*.test.sh` on disk is wired into the workflow, so a new test that is forgotten in `test.yml` fails CI rather than silently never running.

They deliberately do **not** launch real `claude` sessions, parse session transcripts, or measure token usage. UberDev ships no headless-integration runner and no token-analysis script — the suite is the `tests/*.test.sh` shape-checks (plus the helper files they drive: `tests/_lib_assert_structural.sh`, `tests/_workflow_harness.js`) and nothing else.

## The CI job layout

`.github/workflows/test.yml` runs on every push to `main` and every pull request. It declares these jobs — the file is the SSOT, and `tests/docs-accuracy.test.sh` asserts that each job declared there is named here, so this list cannot silently fall behind:

| Job | Runner | Shell | Scope |
| --- | --- | --- | --- |
| `shape-checks` | `ubuntu-latest` | `bash` (+ `zsh` installed for the `*-zsh.test.sh` fixtures) | The **full** suite — every `tests/*.test.sh`. |
| `shape-checks-windows` | `windows-latest` | Git Bash (`shell: bash`) | The full suite **minus** the Unix-only runtime fixtures Git Bash can't run reliably. |
| `supervision-smoke-macos` | `macos-latest` | `bash` (+ GNU `coreutils` for `timeout`) | A focused dispatch-supervision subset — the only job that exercises a real BSD/macOS userland. |

The `shape-checks` and `shape-checks-windows` jobs are a **matched pair**: `tests/ci-wiring.test.sh` enforces that `(ubuntu − windows)` equals exactly the canonical **`ci-wiring windows-skip-list`** marker block inside `test.yml`, so they cannot drift. The Windows job exists to prove the shape-check harness is Git-Bash-portable (RFC 0004 §3.8); the fixtures it skips are the zsh ones, the `python3 -c` + `mktemp -d` path-translation cases, and the ones needing a python module `windows-latest` does not ship (PyYAML). The macOS job is **not** part of that pair — it runs a short hand-picked list, so wiring a test there does not wire it into the suite.

That marker block is **enforced at runtime**, not just compared as a list of names (`ci-wiring.test.sh` W9, issue #520). Every fixture declared Unix-only carries a refusal guard as its first executable statement:

```bash
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
```

So a wired file that *nests* a declared-skipped fixture now reds on Windows instead of silently certifying coverage that never ran — which is exactly what `simplify.test.sh` did to `simplify-standalone-flow.test.sh` until #520 reclassified it. W9 locks the enforcing set and the declared set together in both directions, so un-skipping a fixture stays one atomic edit: delete the marker entry, delete the guard, add the `run:` line.

The complementary rule (`ci-wiring.test.sh` W10) is that **no `tests/*.test.sh` may announce it is asserting nothing and then finish with a zero status.** A file that gates on an optional dependency must refuse (non-zero) or run its rows.

A job may execute its list as a single sequential `run:` step or fan it out across cost-balanced shards (`strategy.matrix.shard`). **That is an execution detail with no bearing on wiring:** the contract is the union of every `run:` block belonging to a job, so a test wired into any shard of `shape-checks` counts as wired into `shape-checks`. Do not infer the number of CI *runs* from the number of jobs above.

> **When you add or remove a test file:** wire it into **both shape-check jobs** in `test.yml` by hand (and add it to the Windows skip-list block instead if it is a Unix-only runtime fixture). `ci-wiring.test.sh` runs first in both jobs and fails fast on any wiring drift.

## Writing a new test

Copy the shape of an existing test (e.g. `tests/review-pr.test.sh`). The conventions reviewers expect:

```bash
#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/plugins/uberdev/commands/your-command.md"

# Hard-fail (exit 2) if a required input file is missing — a moved/renamed
# target should be an explicit failure, not silently zero assertions.
for f in "$TARGET"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

PASS=0; FAIL=0
assert_grep() {           # or: source "$REPO_ROOT/tests/_lib_assert_structural.sh"
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep "$TARGET" 'some-required-token' "names the required token"

echo; echo "== Summary =="; echo "  passed: $PASS"; echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]          # non-zero exit on any failure
```

Conventions worth honouring:

1. **Fail loud on missing inputs.** Guard required files with an `exit 2` FATAL — a count-based test that finds zero assertions because the file moved must not report PASS.
2. **Anchor on the real token.** If you assert on a literal string the source ships, and you later rename that token, update the test in the same change. Relax start-anchored patterns (`^foo`) to tolerate leading whitespace (`^[[:space:]]*foo`) when the matched line may be indented.
3. **Mind the runtime shell.** SKILL.md `bash` fences run under **zsh** in production. If you are locking a runtime behaviour of a fence, prefer a `zsh`-run fixture (and add it to the zsh path in `test.yml`), because bashisms (`BASH_REMATCH`, `${!var}` indirection, `compgen`, `type -t`) misfire under zsh.
4. **Wire it into CI.** Add the new file to **both shape-check jobs** in `.github/workflows/test.yml` (or to the ubuntu job plus the windows skip-list block, if it is Unix-only); `ci-wiring.test.sh` will otherwise fail.
5. **Never bail out of the whole file with a zero status.** If an optional dependency is missing, report it on stderr and `exit 2` — do not print a notice and leave successfully. A file that announces it asserted nothing and then succeeds looks identical to one that passed, and `ci-wiring.test.sh` W4 counts its *filename* as coverage for the job it is wired into. `ci-wiring.test.sh` W10 rejects that shape across the whole corpus. If the dependency genuinely cannot exist on a runner, declare the file in the windows-skip-list instead — that is a recorded coverage loss rather than a false green.

6. **Carry an executed-row floor when the body can be skipped.** `EXPECTED_ROWS=<n>` next to `PASS=0; FAIL=0`, and at the end `[ "$((PASS + FAIL))" -eq "$EXPECTED_ROWS" ]` before the `[ "$FAIL" -eq 0 ]` verdict (see `tests/ubersimplify-aggregate.test.sh`). "Zero failures" is not the same claim as "the rows ran". Use the **exact** count, not a `-ge 1` floor: a floor of one is satisfied by turning a whole-file bail-out into a single "skipped" PASS row, which re-creates the defect one level down. Bump the number in the same commit that adds or removes a row.

7. **Scratch trees must not decide a verdict.** A python `tempfile` scratch tree created inside a `tests/` heredoc must be made with `tempfile.mkdtemp` and torn down with unlink errors suppressed — either the `scratch_dir(prefix, parent=None)` context manager, or, when the tree outlives a lexical scope, `atexit.register(shutil.rmtree, root, ignore_errors=True)`. `tempfile.TemporaryDirectory` is banned here: its `__exit__` re-raises every `OSError` but `PermissionError`/`FileNotFoundError`, so a cleanup race reds a whole shape-check job with a traceback in a file the PR author never touched (#428, #447). Row `A4` of `tests/test-harness-source-guards.test.sh` enforces both halves — the ban and the create/teardown pairing — across every `tests/*.sh` and `tests/*.py`, on both shape-check jobs. The rule covers python `tempfile` trees only; shell `mktemp -d` trees are a different class (these suites do not use `set -e`, so a failing `rm -rf` in a `trap` cannot change the verdict).

8. **No undeclared ripgrep dependency.** `rg` is not installed on the CI runners, so a test that shells out to it passes locally and fails — or, worse, silently misbehaves — on both shape-check jobs. Row `A2` of `tests/test-harness-source-guards.test.sh` enforces this across `tests/*.test.sh` (non-recursive; `tests/_lib_*.sh`, `tests/*.py` and `tests/manual/` are outside the corpus). Two exclusions are declared rather than accidental: a **whole-line `#` comment** is not a site, so prose about the tool stays writable, and a **`command -v` / `which` / `hash` / `type` probe** is not a site either, because guarding the call is exactly how you *declare* the dependency. A trailing comment on a live invocation does not exempt it. Use `grep -E` or `awk` instead; if a workflow genuinely needs the tool, install it there and guard the call site.

9. **On `supervision-smoke-macos`, arm the exit floor.** That job runs on `macos-latest`, whose `/bin/bash` is **3.2**, and on bash 3.2 a `set -u` abort **exits zero** when `set -e` is also in force and the script has an `EXIT` trap installed. All three are required, and the precision matters: measured on 3.2.57 against 5.3.9, `set -u` plus an `EXIT` trap but no `set -e` exits **1** on both majors, and so does `set -euo pipefail` with no trap at all — `pipefail` is not part of it. So a fixture written the way this file recommends — `set -euo pipefail`, a `mktemp -d` scratch tree, a cleanup `EXIT` trap — can die a third of the way in and still be recorded as a pass — `run_one` reads the exit status, and a status of zero is a green fixture no matter how far it actually got — which is exactly what `child-dispatch.test.sh` did for months (#551). De-chaining the block does **not** fix this one: accumulating failures still means accumulating the statuses the fixtures report, so a fixture that lies about its own status is invisible to the harness either way. Capturing and re-raising the status in the trap (`trap 'rc=$?; cleanup; exit $rc' EXIT`) does **not** fix it: bash 3.2 hands that trap `$? == 0` already, so the re-raise faithfully re-raises a zero. The working mechanism is a completion flag no abort path can forge:

   ```bash
   . "$ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }
   TMP="$(mktemp -d)"
   trap '_floor_rc=$?; rm -rf "$TMP"; uberdev_test_exit_floor <name> "$_floor_rc"' EXIT
   # …the rows…
   uberdev_test_exit_floor_reached          # last executable line
   echo '<name>: N checks passed'
   ```

   The floor only ever turns a `0` into a `1` — it is transparent on a completed run and preserves a genuine non-zero verdict verbatim. `tests/exit-floor.test.sh` proves the mechanism against both bash majors (row `E5` reproduces the 3.2 laundering itself) and row `E6` asserts every fixture in the macOS job carries it. It composes with the executed-row floor of convention 6 rather than replacing it: this one proves the file *reached its end*, that one proves its rows *ran*.

10. **A fixture's `PATH` is an input, not a constant.** A `tests/*.test.sh` that prepends a stub bin to `PATH` must keep the host `$PATH` behind it — `"$TMP/bin:$PATH…"`, never `"$TMP/bin:/usr/bin:/bin"`. The narrow form deletes every directory a host installs coreutils into, so the fixture silently selects a *different production branch per host* (on Darwin `_uberdev_dispatch_preflight_timeout_bin` finds nothing and the dispatch takes the **unbounded** preflight arm, while ubuntu takes the bounded one — both green, different code). Row `A6` of `tests/test-harness-source-guards.test.sh` enforces this across `tests/*.test.sh` (non-recursive, the same corpus `A2` declares), on both shape-check jobs. Declared exclusions: a **whole-line `#` comment** is not a site; an **append** (`VAR="$VAR:…"`) is not a prepend, because it preserves whatever the left-hand side held; and a deliberate hermetic environment (`env -i PATH=…`, a python `env={'PATH': …}` dict) is a different shape. Widening the `PATH` is only half the fix — pair it with a row that asserts *which* arm the dispatch took, because the dispatcher maps the resolver's "no `timeout(1)` on this host" rc straight to an empty bound and dispatches anyway: the resolved binary is the only observable, so every other verdict in the fixture is byte-identical on both arms (#521, #548).

## See also

- `.github/workflows/test.yml` — the authoritative test set and the CI job layout.
- `tests/ci-wiring.test.sh` — the wiring invariant that keeps the workflow and the on-disk test set in sync.
- `tests/_lib_assert_structural.sh` — shared section-scoped assertion helpers.
- `tests/_lib_exit_floor.sh` — the anti-vacuity exit floor, with the measured bash-3.2-vs-5 status table.
- `tests/_workflow_harness.js` — the T1–T4 workflow-script harness (self-tests: `node tests/_workflow_harness.js self-test`).
- RFC 0012 (ultracode workflow migration, `docs/rfc/`) — defines the workflow-script conventions the T1–T4 tier enforces.
- The root `AGENTS.md` — the bump-version-everywhere ritual the version-lock tests enforce, and which commit in each lane carries the bump.
