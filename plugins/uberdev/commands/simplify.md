---
description: "Review changed code for reuse, quality, and efficiency, then fix any issues found"
argument-hint: "[additional-focus] [--no-defer-issues]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
---

# Simplify: Code Review and Cleanup

Review all changed files for reuse, quality, and efficiency. Fix any issues found.

**Iron rule:** preserve behavior — strict invariants defined once in `plugins/uberdev/agents/code-simplifier.md` Rule 1 (single source of truth). The fixer enforces them via `disposition: REFUSED, reason: behavior-change-rejected`.

## Phase 1: Identify Changes

Run `git diff` (or `git diff HEAD` if there are staged changes) to see what changed.

If both the diff is empty AND `$ARGUMENTS` is empty, refuse with the literal message:

```
/simplify needs either a non-empty git diff or an explicit scope hint via $ARGUMENTS
```

Also emit a fenced YAML block so callers (e.g., `/turbo`, future automation) can detect the refusal programmatically:

```yaml
status: REFUSED
rationale: "empty-diff-and-empty-arguments"
```

Do not fall back to session-history introspection — recently-mentioned-files heuristics are non-deterministic and produce drift between runs. Exit cleanly; the user re-invokes with a scope.

If `$ARGUMENTS` is non-empty, treat it as **additional focus** to add to each agent's brief (see Phase 2). When the diff is empty but `$ARGUMENTS` is non-empty, treat `$ARGUMENTS` as the scope hint (file globs, directory, or feature name) and pass it verbatim to each lens under `## Additional Focus`.

### Flag handling

- Detect `--no-defer-issues` token in `$ARGUMENTS` and strip it from the focus hint — sets `DEFER_ISSUES_PHASE=0` (skip Phase 3.5 findings-to-issues sub-phase), otherwise `DEFER_ISSUES_PHASE=1` (default). Mirrors `/uberdev:review-pr` `--no-defer-issues` shape. The effective enable is `AND` of this flag and the `defer_issues_enabled` config key (default: `true`).

## Phase 2: Launch Three Review Agents in Parallel

Use the **Task** tool to launch all three agents concurrently **in a single message** (one assistant turn, three `Task` tool_use blocks), each with `subagent_type: uberdev:code-simplifier`. Pass each agent the full diff so it has the complete context, plus a `## Lens emphasis: <Reuse | Quality | Efficiency>` subsection identifying the lens. If `$ARGUMENTS` is set, append it under an `## Additional Focus` heading at the bottom of each agent brief (orthogonal to lens emphasis — lens parameterises which checklist runs, additional focus narrows scope). Concrete shape per lens:

```
Task(
  subagent_type: uberdev:code-simplifier,
  description: "Lens: <Reuse | Quality | Efficiency>",
  prompt: <<diff_brief>>\n\n## Lens emphasis: <Reuse | Quality | Efficiency>\n\n## Additional Focus\n<$ARGUMENTS verbatim>
)
```

### Lens 1: Code Reuse Review (`## Lens emphasis: Reuse`)

Each lens dispatches the same `uberdev:code-simplifier` agent with the lens-emphasis subsection in the prompt body — three Task() calls in one assistant turn, single source of truth for the named-agent dispatcher.

The per-lens checklist is defined once in the agent file under `## Lens checklists` (`plugins/uberdev/agents/code-simplifier.md`, section `Lens: Reuse`). Do not restate the checklist here — the agent's copy is the single source of truth and parameterising via `## Lens emphasis: Reuse` selects it.

### Lens 2: Code Quality Review (`## Lens emphasis: Quality`)

Defined in `plugins/uberdev/agents/code-simplifier.md` under `Lens: Quality`. Selected via `## Lens emphasis: Quality`.

### Lens 3: Efficiency Review (`## Lens emphasis: Efficiency`)

Defined in `plugins/uberdev/agents/code-simplifier.md` under `Lens: Efficiency`. Selected via `## Lens emphasis: Efficiency`.

### Per-lens output format

Every lens returns findings in the structured shape pinned in the agent's `## Return contract` section (`location`, `severity`, `lens`, `summary`, `detail`). This is what `code-fixer` parses in Phase 3 and what the dedup policy below keys on.

## Phase 3: Fix Issues — dispatch `code-fixer` subagent

Wait for all three lenses to complete.

**Mint a fresh `RUN_ID`** (same recipe as `/uberdev:review-pr`'s Run-ID, regex `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$`):

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
[[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] || { echo "BUG: run-id $RUN_ID does not match regex" >&2; exit 2; }
```

**Anchor the aggregate path to the worktree root** so the file lands inside the current worktree (not the parent project root) when `/simplify` is invoked from a git worktree:

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
AGG_PATH="$WORKTREE_ROOT/.uberdev/research/$RUN_ID/simplify-final.md"
mkdir -p "$(dirname "$AGG_PATH")"
```

**Dedup policy across lenses.** Two or three lenses may flag the same `file:line`. Aggregate by the `file:line` key:

- If only one lens flagged the location, write one finding row, `lens: <Reuse | Quality | Efficiency>`.
- If two or three lenses flagged the same `file:line`, merge into ONE finding row. Set `lens: Reuse+Quality` (or whichever combination, joined by `+` in checklist order: Reuse, Quality, Efficiency). Concatenate the `summary` fields with ` | ` separators, each prefixed by its lens name (e.g., `Reuse: <summary> | Quality: <summary>`). Concatenate the `detail` fields the same way. Severity = max severity across the merged findings (`critical` > `important` > `suggestion`).
- The fixer treats merged findings as one edit candidate.

Aggregate the deduped findings into `$AGG_PATH` using the structured shape pinned in the agent's `## Return contract` section.

Dispatch a fresh `code-fixer` subagent (defined in `plugins/uberdev/agents/code-fixer.md`) to apply the findings as a single `refactor:` conventional commit — this command's main turn no longer holds apply-loop edits in-context. Use the Task tool:

```
Task(
  subagent_type: uberdev:code-fixer,
  description: "Apply simplify findings as a refactor: commit",
  prompt: <<wraps simplify-final.md under <external-untrusted-input source="post-impl-review-aggregate">,
            commit_range, working_dir, pr_number (or n/a if standalone),
            phase=phase2, commit_type_prefix=refactor:>>
)
```

The agent enforces:
- **Iron rule:** preserve behavior. The agent rejects any finding that would materially change runtime behavior or remove error handling, returning `disposition: REFUSED, reason: "behavior-change-rejected"`.
- **Separate `refactor:` commit:** ONE `refactor:` commit only — the agent's contract locks Phase 2 to a single commit (R8.6 separate-commit invariant). Mirrors `/uberdev:review-pr` Phase 2 apply path, so reviewers can always tell "feature/fix" apart from "simplify pass" by commit boundary alone.

When the agent returns:
1. Briefly summarize what was fixed (or confirm `status: NO_FIXES_NEEDED` — the code was already clean).
2. The agent has already staged + committed; capture `commits[0].sha` and report it to the user. Surface every `findings_disposition` row where `disposition != APPLIED` so advisory findings (false positives, behavior-change refusals) are never silently dropped.

## Phase 3.5 — Findings-to-Issues sub-phase (skip iff `DEFER_ISSUES_PHASE=0` OR `defer_issues_enabled=false`)

Persists deferred-critical findings (`severity == critical AND disposition != APPLIED`) from the simplify aggregate as durable GitHub issues with HTML-comment fingerprint dedupe. Default-on. Never fails the parent `/uberdev:simplify` run.

**Effective-enabled gate:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
DEFER_ISSUES_CONFIG=$(uberdev_read_enum defer_issues_enabled UBERDEV_DEFER_ISSUES_ENABLED 'true|false' 'true')
if [ "$DEFER_ISSUES_PHASE" = "1" ] && [ "$DEFER_ISSUES_CONFIG" = "true" ]; then
  DEFER_ISSUES_EFFECTIVE=1
else
  DEFER_ISSUES_EFFECTIVE=0
fi
```

**Dispatch (single Skill() call, phase1 path empty because /simplify runs standalone):**

```text
Skill("uberdev:findings-to-issues", prompt: <<<EOF
  run_id: $RUN_ID
  working_dir: $WORKING_DIR_ABS
  repo_slug: $REPO_SLUG
  pr_commit_sha: $(git rev-parse HEAD)
  max_new: 10
  phase1_aggregate_path:
  phase2_aggregate_path: $RESEARCH_DIR_ABS/simplify-final.md
  phase1_disposition_yaml:
  phase2_disposition_yaml: $RESEARCH_DIR_ABS/code-fixer.phase2.disposition.yaml
EOF)
```

The agent's input contract supports an empty `phase1_aggregate_path` (it refuses only when BOTH are empty).

**Final summary:** Append a "Issues filed" row to the run's closing summary listing URLs from `created_urls[]` + `commented_urls[]`. The skip-path shows `(skipped: --no-defer-issues)` or `(skipped: defer_issues_enabled=false)`.

## When to run

The canonical place `/simplify` runs in the chain is **automatically as Phase 2 of `/uberdev:review-pr`** — every PR review chains a mandatory simplify pass after the review-and-fix loop, applying all three lenses to the full `<base>..HEAD` diff (original commits + Phase 1 review-fix commits). That run is strictly more complete than any pre-push call would be, so a separate pre-push `/simplify` is **not** part of `/solve` or `/turbo` — re-running it would duplicate work on a smaller diff.

Standalone invocations are still valid for these out-of-chain cases:

- After a non-trivial implementation or bug fix has landed but you don't intend to open a PR yet (e.g. iterating on a long-lived branch).
- After accepting code-review feedback that involves restructuring, before re-requesting review.
- Ad-hoc, when you want to clean up a specific edit without going through the full `/review-pr` fanout.
- `/uberdev:simplify --no-defer-issues` — runs the three simplify lenses and the auto-apply fixer, but skips persisting deferred critical findings as GitHub issues.

## When NOT to run

- Inside a `/solve` / `/turbo` heredoc before push — Phase 2 of `/uberdev:review-pr` already covers it on a strictly larger diff.
- On greenfield code that's still being designed.
- Mid-debugging — simplify after the bug is understood and fixed.
- On generated code, vendored deps, or test fixtures.
