# tools/prkit — the prkit generator

Generates the standalone **prkit** plugin (PR phase: review → fix → simplify → land)
from this repo's `plugins/uberdev/` (Claude Code) as the single source of truth. See `docs/rfc/0014-prkit-standalone-plugin.md`.

## Run

```bash
tools/prkit/generate.sh --target /path/to/prkit-repo --version 0.1.0
```

Stages: preflight → clean `plugins/prkit/` → copy (`manifest.txt`) → rewrite
(`rewrite.sh`: de-namespace out-of-set refs, then blanket `uberdev`→`prkit`) →
scaffold (`templates/`) → verify (`verify.sh`) → summary. It never commits;
commit in the target repo yourself. Without `--force`, Git targets must be clean
and every managed replacement/overwrite path must also be free of ignored,
untracked content; the generator rechecks each path immediately before mutation.
An absent or empty non-Git target may bootstrap, but a non-Git target containing
any entry is rejected unless `--force` explicitly authorizes managed replacement.
RFC 0014 defines a Git worktree as the normal regeneration target.

## Bootstrap a fresh prkit repo

```bash
mkdir -p ../prkit && git -C ../prkit init
tools/prkit/generate.sh --target ../prkit --version 0.1.0
git -C ../prkit add -A && git -C ../prkit commit -m "chore: initial prkit 0.1.0"
# then: gh repo create TheFJK/prkit --public --source ../prkit --push
```

## Files

| File | Role |
|---|---|
| `manifest.txt` | Claude copy set (count-locked at 38 by `tests/prkit-manifest.test.sh`) |
| `managed-path-guard.py` | Shared generator/verifier containment guard: component-wise `lstat`, Windows reparse/reserved-name checks, required postconditions, and sealed-tree scans |
| `rewrite.sh` | `prkit_neutralize` (de-namespace out-of-set) + `prkit_apply_rewrites` (slug + blanket); sourced |
| `templates/` | Standalone-only scaffold files (`{{VERSION}}`/`{{DATE}}`) |
| `verify.sh` | Anti-drift gate: token guard, out-of-set resolution, referential integrity, syntax (sh/py/json), scaffold + placeholder checks, `codex/`-retirement assertion. Runs at **generation time in UberDev** — it is NOT copied into the prkit repo. |
| `published.json` | Publication currency register (#410): prkit version last published, per-file source sha256, and declared `pending` divergences |
| `published-check.py` | Verifies `published.json` against the live tree; `--refresh --prkit-version X.Y.Z` rewrites it. Gated by `tests/prkit-publish.test.sh`. |
| `generate.sh` | Orchestrator |

Nothing here is copied downstream, and no guard is duplicated there either. The
`trap … RETURN` class, for instance, is gated upstream by
`tests/crossplatform-shell-wrappers.test.sh`, whose corpus already covers
`plugins/uberdev/skills` (the copy source) and `tools/` (the generator,
including `templates/*.tmpl`); a second detector inside prkit would be the
"one contract, N uncompared copies" drift RFC 0016 is about.

The generated prkit repo ships its own `.github/workflows/ci.yml`, which re-checks
the committed tree with `bash -n` + `ast.parse` + `jq empty` + an inline
`grep -rilE 'uberdev'` namespace guard (a subset of `verify.sh`'s token-guard).

## Filesystem threat model

The generator rejects a symbolic-link/reparse target root and any pre-existing managed
path traversal, validates each component again at mutation boundaries, publishes
file leaves atomically from destination-local temporaries, and holds an exclusive
`.prkit-generate.lock` through mutation, verification, and final sealed-tree
checks. This prevents pre-existing traversal and serializes cooperative generator
processes; `--force` never bypasses containment or the lock.

A malicious same-user process that deliberately ignores the lock can still race
portable Bash/Python pathname operations between a check and a use. Eliminating
that adversarial race requires platform-specific handle-relative APIs
(`openat`/`renameat`/`unlinkat` on Unix and reparse-safe directory handles on
Windows), which are outside this generator's portability contract. The code and
documentation intentionally do not claim protection against that actor.

## Publish ritual

`generate.sh` never commits and never pushes (RFC 0014 §5.1) — publication is a
deliberate, ordered sequence, run from a synced `main` **after** the UberDev
change has landed, so the recorded digests are the ones that were shipped:

```bash
git -C ../prkit status --porcelain          # must be empty
tools/prkit/generate.sh --target ../prkit --version X.Y.Z
git -C ../prkit add -A
git -C ../prkit commit -m "chore: regenerate prkit X.Y.Z"
git -C ../prkit tag vX.Y.Z && git -C ../prkit push --follow-tags
gh release create vX.Y.Z -R TheFJK/prkit --notes-file <notes>
python3 tools/prkit/published-check.py --refresh --prkit-version X.Y.Z
python3 tools/prkit/published-check.py      # must print `published: OK — …`
```

The refresh is the **last** step, and it belongs in the same sitting: it is what
records that this exact source tree is what the published artifact was built
from. `tests/prkit-publish.test.sh` reds in CI while a copy-set file is ahead of
the record and not listed in `pending`.

**Never hand-patch the prkit repo.** UberDev is the sole source of truth and
`generate.sh` is the only legal producer; a downstream edit closes the symptom
and is reverted by the next generation.

## Adding a file to prkit

1. Add its path to `manifest.txt`, and bump the count assert in
   `tests/prkit-manifest.test.sh` (39). Then re-run
   `python3 tools/prkit/published-check.py --refresh --prkit-version <current>`,
   or `tests/prkit-publish.test.sh` P2 reds on the manifest/record mismatch.
2. If it introduces a new `uberdev` pattern the blanket rule misses, or a new
   out-of-set `prkit:<name>` ref, the verify gate fails generation — extend
   `rewrite.sh` (never weaken the guard).
3. Re-run `bash tests/prkit-generate.test.sh`.

> The Codex port stage (`manifest-codex.txt`, `templates/codex-*`, the `codex/`
> verify roots) was removed with the Codex distribution — issue #381. RFC 0014
> §14's "mandatory native Codex port" is superseded; see the dated note there.
