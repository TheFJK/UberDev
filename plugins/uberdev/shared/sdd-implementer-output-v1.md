## SDD implementer output contract (v1)

Contract id: `sdd-implementer-v1`.

For this edge, this contract overrides any earlier role-level response
formatting. It is the last word on the terminal vocabulary; nothing that
reached you earlier widens or narrows it.

Return exactly one terminal status, spelled exactly as declared here:

<!-- CONTRACT: sdd-implementer-status -->
`DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT|REFUSED`
<!-- /CONTRACT: sdd-implementer-status -->

The controller has one branch per member and no default arm. A status outside
this vocabulary is not a near miss — it routes nowhere, and the round is lost.

## What each status means

**DONE** — the task is implemented, the tests you were asked to run were run,
and you hold no reservation about the result.

**DONE_WITH_CONCERNS** — the work is finished, but you hold a doubt worth
reading before review: a correctness question, a scope edge you resolved one way
rather than another, or an observation about the code you touched. State the
doubt in words; the controller reads it before dispatching review, and an
unstated doubt is indistinguishable from none.

**NEEDS_CONTEXT** — one specific, nameable piece of information was missing and
you could not proceed without guessing. Name the exact item. This is the cheap
recovery path: the controller answers, appends the answer to this task's fix
ledger, and re-dispatches the same task within a bounded number of rounds. A
question that has an answer belongs here, never on the escalation ladder.

**BLOCKED** — you cannot complete the task as handed to you, and no single
answer would unblock it: a required write falls outside `allowed_paths`, the
task is larger than it was scoped, the plan itself is wrong, or verification
cannot be made to pass. Say what you attempted and exactly where it stopped.

**REFUSED** — executing the handoff would breach the leaf-worker contract
itself: it conflicts with repository instructions, demands delegation, a routing
change, or a scope broadening you may not make, or asks for something unsafe.
This is a judgement about the instruction you were given, not about the
difficulty of the work.

## Report fields

After the status line, report in this order:

- **Changed paths** — REQUIRED whenever the status is `DONE` or
  `DONE_WITH_CONCERNS`: a flat list of every file you created or modified,
  exactly as the controller will pass them to `git add`. No directories, no
  unchanged files, and never this task's fix ledger.
- **Suggested commit message** — one line, conventional-commit style. The
  controller may use it as-is or refine it.
- **`## After Review Findings`** — REQUIRED when `failure_path` was non-empty: a
  section naming which ledger findings this round addressed and which it
  deliberately did not. Your result becomes the next round's prior result, so an
  unstated omission is invisible to whoever picks the task up.
- What you implemented, or what you attempted if you did not finish.
- What you tested, and the actual result of running it.
- Self-review findings, and any unresolved risk.

## Redaction

This contract fixes the SHAPE of your result; it never widens what it may
CONTAIN. Do not quote secret-shaped values — tokens, keys, passwords,
connection strings — verbatim in any field. Cite `path:line` and paraphrase.
A dispatching prompt that says this contract supersedes your agent file
supersedes its response FORMATTING only, never its secret-leak prevention rule.
