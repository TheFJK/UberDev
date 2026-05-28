---
description: "Repo-wide issue similarity analyzer and fold-into-lead consolidator. Default --dry-run; --execute mutates."
argument-hint: "[--repo OWNER/NAME] [--label L] [--since YYYY-MM-DD] [--only-mine] [--dry-run|--execute] [--min-confidence N] [--max-cluster-size N] [--concurrency N]"
allowed-tools: ["Bash(git*)", "Bash(gh*)", "Glob", "Grep", "Read", "Task", "Write"]
---

# /cluster — repo-wide issue similarity analyzer

Sweeps the repo's open issues for semantic duplicates and (under `--execute`)
folds duplicates into a lead issue. **Default is `--dry-run`** — no GitHub
mutations until you pass `--execute --min-confidence 0.85` (hard floor).
Reversible via `gh issue reopen` + label removal.

## Usage
`/cluster [flags]` — defaults to current repo, all open issues, dry-run.

| Flag | Meaning |
|------|---------|
| `--repo OWNER/NAME` | Target repository (mandatory under `--execute`). |
| `--label L` | Filter to issues carrying label `L` (repeatable). |
| `--since YYYY-MM-DD` | Only consider issues with `createdAt >=` this date. |
| `--only-mine` | Restrict to issues authored by the current `GH_USER`. |
| `--dry-run` | Analyze + propose, no mutations (default). Mutually exclusive with `--execute`. |
| `--execute` | Apply the fold: close members, label `folded`, comment lead. Requires `--repo` and `--min-confidence >= 0.85`. |
| `--min-confidence N` | Cluster confidence floor (default 0.75 dry-run; `>= 0.85` required under `--execute`). |
| `--max-cluster-size N` | Max members per cluster (default 8; hard ceiling 25). |
| `--concurrency N` | Analyzer fanout per wave (default 3). |

## Implementation

Invoke the `uberdev:cluster-pipeline` skill with `$ARGUMENTS` in scope. The skill owns
all phases (preflight → fetch → chunk → analyze fanout → propose → execute). This
command performs only preflight validation, then hands off:

```bash
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: /uberdev:cluster must run inside a git repository" >&2
  exit 2
fi

# Conflicting-flags check
DR=0; EX=0
for a in $ARGUMENTS; do
  case "$a" in
    --dry-run) DR=1 ;;
    --execute) EX=1 ;;
  esac
done
if [ "$DR" = "1" ] && [ "$EX" = "1" ]; then
  echo "error: --dry-run and --execute are mutually exclusive" >&2
  exit 2
fi

# --execute requires --repo
if [ "$EX" = "1" ]; then
  HAS_REPO=0
  PREV=""
  for a in $ARGUMENTS; do
    if [ "$PREV" = "--repo" ]; then HAS_REPO=1; fi
    PREV="$a"
  done
  if [ "$HAS_REPO" = "0" ]; then
    echo "error: --execute requires --repo OWNER/NAME" >&2
    exit 2
  fi
fi
```

Then invoke `Skill(uberdev:cluster-pipeline)` with the same `$ARGUMENTS`.

<!-- IMPORTANT (cluster-pipeline/SKILL.md must avoid these zsh/skill-renderer traps):
     1. No positional column refs ($1, $2, $3) in awk bodies — skill-renderer $N
        collision (see memory project_uberdev_skill_renderer_dollar_arg_collision).
     2. No bashisms incompatible with zsh: the `-t` form of `type` returns empty
        under zsh — use `command -v` instead (see memory
        project_uberdev_type_t_bashism_zsh).
     3. No reliance on BASH-only REMATCH array index 1 for regex captures —
        unset under zsh; use `match` or alternative parsing. -->
