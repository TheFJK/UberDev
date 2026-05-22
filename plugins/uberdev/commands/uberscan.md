---
description: "Whole-codebase read-only audit. Chunks the repo and runs the review-pr Phase-1 reviewer fleet (6 reviewers) per chunk, plus a repo-global Semgrep + test-coverage pass. Aggregates findings into a markdown report and files deduped GitHub issues. Never writes code. Whole-repo by default; pass a path/glob to narrow."
argument-hint: "[path-or-glob] [--all] [--no-issues] [--no-report] [--max-chunks=N] [--concurrency=N] [--severity=blocker|critical|major] [--turbo]"
allowed-tools: ["Bash(git*)", "Bash(gh*)", "Glob", "Grep", "Read", "Task", "Write"]
---

# /uberscan — whole-codebase read-only audit

Runs the `/review-pr` **Phase-1** reviewer fleet (6 reviewers) across the **entire
codebase** (or a path-scoped subtree), aggregates findings into a report, and files
deduped GitHub issues. **Never writes code** — the absence of `Edit`/`MultiEdit` above
is the enforced read-only invariant. (Simplify lenses are a separate command.)

## Usage
`/uberscan [path-or-glob] [flags]` — no path = whole repo.

| Flag | Meaning |
|------|---------|
| `--all` | Override the `MAX_CHUNKS` circuit breaker for large repos. |
| `--no-issues` | Skip GitHub issue filing; report only. |
| `--no-report` | Skip the markdown report; issues only. |
| `--max-chunks=N` | Override the chunk-count cap (default from config, 25). |
| `--concurrency=N` | Chunks processed per wave (default from config, 3). |
| `--severity=LEVEL` | Minimum severity filed as issues (default major). |
| `--turbo` | Non-interactive: circuit breakers cap-and-continue instead of prompting. |

## Implementation

Invoke the `uberdev:uberscan-pipeline` skill with `$ARGUMENTS` in scope. The skill owns
all phases (scope+chunk, per-chunk fan-out waves, repo-global pass, aggregate+report,
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
