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
| `manifest.txt` | Claude copy set (count-locked at 37 by `tests/prkit-manifest.test.sh`) |
| `managed-path-guard.py` | Shared generator/verifier containment guard: component-wise `lstat`, Windows reparse/reserved-name checks, required postconditions, and sealed-tree scans |
| `rewrite.sh` | `prkit_neutralize` (de-namespace out-of-set) + `prkit_apply_rewrites` (slug + blanket); sourced |
| `templates/` | Standalone-only scaffold files (`{{VERSION}}`/`{{DATE}}`) |
| `verify.sh` | Anti-drift gate: token guard, out-of-set resolution, referential integrity, syntax (sh/py/json), scaffold + placeholder checks. Runs at **generation time in UberDev** — it is NOT copied into the prkit repo. |
| `generate.sh` | Orchestrator |

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

## Adding a file to prkit

1. Add its path to `manifest.txt`, and bump the count assert in
   `tests/prkit-manifest.test.sh` (37).
2. If it introduces a new `uberdev` pattern the blanket rule misses, or a new
   out-of-set `prkit:<name>` ref, the verify gate fails generation — extend
   `rewrite.sh` (never weaken the guard).
3. Re-run `bash tests/prkit-generate.test.sh`.

> The Codex port stage (`manifest-codex.txt`, `templates/codex-*`, the `codex/`
> verify roots) was removed with the Codex distribution — issue #381. RFC 0014
> §14's "mandatory native Codex port" is superseded; see the dated note there.
