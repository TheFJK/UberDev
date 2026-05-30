---
description: "Whole-codebase read-only audit. Packs the repo into a fixed fleet of byte-balanced areas (default 8) and runs ONE multi-lens reviewer per area, plus an inline repo-global Semgrep + test-coverage pass. Aggregates findings into a markdown report and files deduped GitHub issues. Never writes code. Whole-repo by default; pass a path/glob to narrow."
argument-hint: "[path-or-glob] [--all] [--no-issues] [--no-report] [--areas=N] [--concurrency=N] [--severity=blocker|critical|major] [--turbo]"
allowed-tools: ["Bash(git*)", "Bash(gh*)", "Glob", "Grep", "Read", "Task", "Write"]
---

# /uberscan — whole-codebase read-only audit

Reviews the **entire codebase** (or a path-scoped subtree) with a **fixed fleet of area
agents** — one multi-lens reviewer per byte-balanced area (default 8), covering the
`/review-pr` Phase-1 lenses (correctness, silent-failures, type-design, comments, tests).
The repo-global Semgrep + test-coverage passes run **inline** (no dispatched agents).
Aggregates findings into a report and files deduped GitHub issues. **Never writes code** —
the absence of `Edit`/`MultiEdit` above is the enforced read-only invariant. The fixed
fleet means a whole-repo scan costs ~8 agents regardless of repo size (the legacy
per-byte-chunk model exploded to hundreds). (Simplify lenses are a separate command.)

## Usage
`/uberscan [path-or-glob] [flags]` — no path = whole repo.

| Flag | Meaning |
|------|---------|
| `--all` | Override the `MAX_AGENTS` (CB7) backstop for an explicit large `--areas`. |
| `--no-issues` | Skip GitHub issue filing; report only. |
| `--no-report` | Skip the markdown report; issues only. |
| `--areas=N` | Fleet size: pack the repo into ≤ N byte-balanced areas, one reviewer each (default 8, range 1-24). `--max-chunks=N` is a legacy alias. |
| `--concurrency=N` | Areas processed per wave (default from config, 3). |
| `--severity=LEVEL` | Minimum severity filed as issues (default major). |
| `--turbo` | Non-interactive: circuit breakers cap-and-continue instead of prompting. |

## Implementation

Invoke the `uberdev:uberscan-pipeline` skill with `$ARGUMENTS` in scope. The skill owns
all phases (scope+area-pack, per-area fan-out waves, inline repo-global pass, aggregate+report,
issue filing). This command performs only preflight validation, then hands off:

```bash
# Preflight
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: /uberscan must run inside a git repository" >&2; exit 2
fi
if printf '%s' "$ARGUMENTS" | grep -q -- '--no-issues' && printf '%s' "$ARGUMENTS" | grep -q -- '--no-report'; then
  echo "error: --no-issues and --no-report together leave no output sink" >&2; exit 2
fi
```

Then invoke `Skill(uberdev:uberscan-pipeline)` with the same `$ARGUMENTS`.
