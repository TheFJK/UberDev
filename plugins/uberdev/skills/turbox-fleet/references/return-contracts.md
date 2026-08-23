# Turbox-fleet — return contracts and circuit breakers

Reference for `skills/turbox-fleet/SKILL.md`. Read before parsing an agent return or interpreting a `$LIB` exit code.

## Return contracts

Every dispatched agent ends its reply with **exactly one** trailing fenced
`yaml` block, as the last thing in the reply. You machine-parse the block; prose
above it is fine, nothing may follow it.

Design rung (`design-planner`), whose handle is the plan you never read:

```yaml
status: DONE            # DONE | DONE_WITH_CONCERNS | BLOCKED
artifact_path: <the absolute plan_path it was given; empty on BLOCKED>
artifact_sha: <8-char sha256 prefix; empty on BLOCKED>
summary: |
  <=200 words: the design chosen, the wave structure, the decomposition calls
decisions:
  - { key: D1, choice: "...", rationale: "..." }
risks:
  - "<one line per risk the plan identifies>"
waves: 2
task_count: 5
next_phase_recommendation: auto   # auto | review | abort
```

`next_phase_recommendation` is advisory only — the plan reviewer is always on
regardless of what it says.

Implementer / fixer:

```yaml
status: DONE            # DONE | NO_CHANGES | BLOCKED | NEEDS_CONTEXT
paths:
  - <every path created or edited, relative to the worktree>
tests:
  cmd: "<the command you ran>"
  result: PASS          # PASS | FAIL | NOT_RUN
needs: null             # null, or ONE specific question you cannot answer from
                        # your allowed_paths, the plan, or the repository
blocker: null           # null, or one line
```

`NEEDS_CONTEXT` and `BLOCKED` are different answers and must not be collapsed.
`NEEDS_CONTEXT` says "ask me again with this one fact and I can finish";
`BLOCKED` says "this task cannot be done as specified". The first is worth a
re-dispatch, the second is worth a plan fix.

Reviewer:

```yaml
verdict: APPROVE        # APPROVE | REVISIONS_REQUIRED | REJECT
report_path: <absolute path to the findings you wrote>
blocking_count: 0
```

Delivery:

```yaml
status: PR_OPENED       # PR_OPENED | PUSHED_NO_PR | COMMITTED_NOT_PUSHED | FAILED
pr_number: 0
pr_url: ""
suite:
  cmd: "<the command you ran>"
  result: PASS          # PASS | FAIL | NOT_RUN
blocker: null
```

`paths` is the staging list of record: a path missing from it does not get
committed. A missing or unparseable block is a blocker, never a prompt to guess.

## Circuit breakers

| ID | Guard | On trip |
| --- | --- | --- |
| **TB1** | `project-agents` over `maxAgents` | abort before any dispatch; claims stay held and you say so |
| **TB2** | `budget-spend` reaching `implementBudget` for an issue | stop that issue's task loop, mark the rest SKIPPED, **still deliver** |
| **TB3** | `wave-disjoint` rc 3 / rc 2 | dispatch nothing for that wave; BLOCKED ladder |
| **TB4** | `round-permitted` rc 3 (`fix_rounds` 3, `retest_rounds` 2, `context_rounds` 2) | stop the loop, mark BLOCKED, keep committed work |
| — | a per-issue chain that throws | catch it, record that issue `FAILED`, keep the batch running |

Caps are read from `bash "$LIB" loop-cap <name>`. The lib's constants are
themselves a derived copy of `sdd_loop_cap` in
`skills/subagent-driven-dev/SKILL.md` — the canonical owner;
`tests/sdd-wave-contract.test.sh` §C asserts that chain numerically.
Never restate a cap from memory.

## Verdict vocabulary

Verdict vocabulary, and the two non-review verdicts are opposites:

- `NOT_APPLICABLE` — the task committed nothing, so there was nothing to
  review. A named sentinel, never an empty string.
- `UNREVIEWED` — commits exist that no reviewer saw: a null reviewer, a task
  recorded BLOCKED that committed anyway, or TB2 cutting the chain before the
  first review ran. Count these separately and name them in Phase 7.
