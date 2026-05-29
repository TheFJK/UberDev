# Testing UberDev

UberDev's product is **markdown prompt files, shell libraries, and a little Python** — there is no application server and no build step. The test suite reflects that: it is a set of **shape-check scripts** (`tests/*.test.sh`) that grep the shipped command / agent / skill / lib files for the exact tokens, contracts, and invariants each change is supposed to preserve. A few fixtures additionally *execute* a sourced `lib/` helper to lock a runtime behaviour, but the suite is grep-and-assert throughout — it never spins up a real Claude Code session.

## The harness at a glance

- **Where:** every test lives in `tests/` and is named `<name>.test.sh`.
- **Runner:** there is no separate runner binary — each file is self-contained and run directly with `bash tests/<name>.test.sh` (one fixture, `solve-pipeline-zsh.test.sh`, runs under `zsh` — see below).
- **What CI runs:** `.github/workflows/test.yml` is the **single source of truth** for the active test set. Do not maintain a second hand-curated list anywhere — read `test.yml`.
- **Shared assertion library:** `tests/_lib_assert_structural.sh` provides the section-scoped `assert_in_section` / structural helpers that many tests `source`.

## Running tests locally

The canonical list of tests is whatever `.github/workflows/test.yml` runs. To run the whole suite locally the way CI does, drive it from that file rather than copying file names by hand:

```bash
# Run every tests/*.test.sh on disk (mirrors what CI gates on; needs zsh for
# the one zsh-runtime fixture — see below).
for t in tests/*.test.sh; do
  echo "== $t =="
  if [ "$t" = "tests/solve-pipeline-zsh.test.sh" ]; then
    zsh "$t" || exit 1          # zsh-runtime fixture
  else
    bash "$t" || exit 1
  fi
done
```

To run a single test (the normal inner-loop while editing one command or skill):

```bash
bash tests/review-pr.test.sh
```

The shape-checks read the files in your checkout directly, so they need no plugin install. To additionally smoke-test that an edited command or skill still *loads* in Claude Code, reinstall the local plugin (the marketplace key is `uberdev@uberdev`): `/plugin install uberdev@uberdev`, then confirm `/plugin` → Installed → `uberdev` reports no errors.

Each test prints a `PASS` / `FAIL` line per assertion and a `== Summary ==` block, and **exits non-zero if any assertion failed** — so `&&`-chaining them (as `test.yml` does) stops at the first red file.

### The zsh-runtime fixture

`tests/solve-pipeline-zsh.test.sh` is run with **`zsh`**, not `bash`. SKILL.md `bash` fences execute under Claude Code's Bash tool, which is `/bin/zsh` at runtime, so this fixture locks behaviour that only manifests under zsh's word-splitting and array semantics (e.g. the v0.22.2 regression where a scalar `EFFORT_FLAG="--effort max"` broke under `SH_WORD_SPLIT=off`). `ubuntu-latest` does not ship `zsh` by default, so the CI job installs it before running the suite. Run it locally with `zsh tests/solve-pipeline-zsh.test.sh`.

## What the tests check (and what they don't)

These are **structural / contract** checks, not end-to-end behavioural tests of a running agent:

- **Prompt-file contracts** — that a command or agent file still names every dispatch slot, every required flag, every documented argument, and every guard rail it is supposed to (e.g. `review-pr.test.sh` asserts all six Phase-1 reviewer slots are dispatched in a single message).
- **Runtime behavioural fixtures** — a subset `source` a real `lib/` helper and assert its output. Examples: `solve-pipeline-zsh.test.sh` (zsh word-splitting), `goal.test.sh` BT84 / BT85 (goal-pipeline behaviour), `config-override.test.sh` (config precedence), `secret-scan.test.sh` (the pre-push scanner). So the suite is **not** purely static — the claim "no behavioural tests" is false.
- **Release-ratchet version locks** — `goal.test.sh` (the `G20: version bump locked` block) and `solve-claim.test.sh` (the `Version bump A.B.C -> X.Y.Z propagated` block) hardcode the current version and **turn CI red on a missed bump**. They are part of the mandatory bump-everywhere ritual (see the project `CLAUDE.md`). A contributor who skips the full suite skips exactly the tests that catch a forgotten version bump.
- **CI-wiring invariant** — `tests/ci-wiring.test.sh` asserts that *every* `tests/*.test.sh` on disk is wired into the workflow, so a new test that is forgotten in `test.yml` fails CI rather than silently never running.

They deliberately do **not** launch real `claude` sessions, parse session transcripts, or measure token usage. UberDev ships no headless-integration runner and no token-analysis script — the suite is the `tests/*.test.sh` shape-checks and nothing else.

## The two-job CI matrix

`.github/workflows/test.yml` runs on every push and pull request, with **two jobs**:

| Job | Runner | Shell | Scope |
| --- | --- | --- | --- |
| `shape-checks` | `ubuntu-latest` | `bash` (+ `zsh` installed for the one zsh fixture) | The **full** suite — every `tests/*.test.sh`. |
| `shape-checks-windows` | `windows-latest` | Git Bash (`shell: bash`) | The full suite **minus** the Unix-only runtime fixtures Git Bash can't run reliably. |

The Windows job exists to prove the shape-check harness is Git-Bash-portable (RFC 0004 §3.8). The Unix-only fixtures it skips (zsh, and the `python3 -c` + `mktemp -d` path-translation cases) are enumerated in the canonical **`ci-wiring windows-skip-list`** marker block inside `test.yml`. `tests/ci-wiring.test.sh` enforces that `(ubuntu − windows)` equals exactly that list — so the two jobs cannot drift.

> **When you add or remove a test file:** wire it into **both** jobs in `test.yml` by hand (and add it to the Windows skip-list block if it is a Unix-only runtime fixture). `ci-wiring.test.sh` runs first in both jobs and fails fast on any wiring drift.

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
4. **Wire it into CI.** Add the new file to **both** jobs in `.github/workflows/test.yml`; `ci-wiring.test.sh` will otherwise fail.

## See also

- `.github/workflows/test.yml` — the authoritative test set and the two-job matrix.
- `tests/ci-wiring.test.sh` — the wiring invariant that keeps the workflow and the on-disk test set in sync.
- `tests/_lib_assert_structural.sh` — shared section-scoped assertion helpers.
- The project `CLAUDE.md` — the bump-version-everywhere ritual the version-lock tests enforce.
