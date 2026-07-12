# tools/prkit — the prkit generator

Generates the standalone **prkit** plugin (PR phase: review → fix → simplify → land)
from this repo's `plugins/uberdev/` as the single source of truth. See
`docs/rfc/0014-prkit-standalone-plugin.md`.

## Run

```bash
tools/prkit/generate.sh --target /path/to/prkit-repo --version 0.1.0
```

Stages: preflight → clean `plugins/prkit/` → copy (`manifest.txt`) → rewrite
(`rewrite.sh`: neutralize goal/solve, then blanket `uberdev`→`prkit`) → scaffold
(`templates/`) → verify (`verify.sh`) → summary. It never commits; commit in the
target repo yourself.

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
| `manifest.txt` | Declarative copy set (count-locked at 32 by `tests/prkit-manifest.test.sh`) |
| `rewrite.sh` | `prkit_neutralize` + `prkit_apply_rewrites` (sourced) |
| `templates/` | Standalone-only scaffold files (`{{VERSION}}`/`{{DATE}}`) |
| `verify.sh` | Token guard + referential integrity + syntax gate |
| `generate.sh` | Orchestrator |

## Adding a file to prkit

1. Add its path to `manifest.txt`, bump the count assert in `tests/prkit-manifest.test.sh`.
2. If it introduces a new `uberdev` pattern the blanket rule misses, the verify
   token guard will fail generation — add a rule to `rewrite.sh` (never weaken the guard).
3. Re-run `bash tests/prkit-generate.test.sh`.
