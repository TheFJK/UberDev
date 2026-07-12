# tools/prkit — the prkit generator

Generates the standalone **prkit** plugin (PR phase: review → fix → simplify → land)
from this repo's `plugins/uberdev/` (Claude Code) and `codex/uberdev-codex/` (Codex CLI)
as the single source of truth. See `docs/rfc/0014-prkit-standalone-plugin.md`.

## Run

```bash
tools/prkit/generate.sh --target /path/to/prkit-repo --version 0.1.0
```

Stages: preflight → clean `plugins/prkit/` → copy (`manifest.txt`) → rewrite
(`rewrite.sh`: de-namespace out-of-set refs, then blanket `uberdev`→`prkit`) →
scaffold (`templates/`) → **Codex port** (`manifest-codex.txt` → `codex/prkit-codex/`,
same rewrite) → verify (`verify.sh`, both trees) → summary. It never commits;
commit in the target repo yourself.

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
| `manifest.txt` | Claude copy set (count-locked at 32 by `tests/prkit-manifest.test.sh`) |
| `manifest-codex.txt` | Codex copy set (count-locked at 51 by `tests/prkit-codex-manifest.test.sh`) |
| `rewrite.sh` | `prkit_neutralize` (de-namespace out-of-set) + `prkit_apply_rewrites` (slug + blanket); sourced |
| `templates/` | Standalone-only scaffold files (`{{VERSION}}`/`{{DATE}}`), incl. `codex-*` |
| `verify.sh` | Anti-drift gate (both trees): token guard, out-of-set resolution, referential integrity, syntax (sh/py/json/toml), scaffold + placeholder checks. Runs at **generation time in UberDev** — it is NOT copied into the prkit repo. |
| `generate.sh` | Orchestrator |

The generated prkit repo ships its own `.github/workflows/ci.yml`, which re-checks
the committed tree with `bash -n` + `ast.parse` + `jq empty` + `tomllib` + an inline
`grep -rilE 'uberdev'` namespace guard (a subset of `verify.sh`'s token-guard).

## Adding a file to prkit

1. Add its path to `manifest.txt` (Claude) or `manifest-codex.txt` (Codex), and bump
   the count assert in the matching `tests/prkit-*-manifest.test.sh` (32 / 51).
2. If it introduces a new `uberdev` pattern the blanket rule misses, or a new
   out-of-set `prkit:<name>` ref, the verify gate fails generation — extend
   `rewrite.sh` (never weaken the guard).
3. Re-run `bash tests/prkit-generate.test.sh` (+ `prkit-codex-manifest.test.sh`).
