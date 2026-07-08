# Document Reviewer Prompt — Shared Template

> **Canonical template** for "review a written document" subagent prompts.
> Consumers: `brainstorm/spec-document-reviewer-prompt.md`, `write-plan/plan-document-reviewer-prompt.md`.
>
> Claude Code skills do not auto-include partials — this is a **documentation convention**, not a build step. When you change the shared skeleton below, update each consumer manually so the inline content stays in sync. Each consumer has a back-link comment naming this file.
>
> The `[DOCUMENT_TYPE]` placeholder is `spec` or `plan`. The `[DOCUMENT_TYPE_TITLE]` placeholder is `Spec` or `Plan`.

---

## Shared Skeleton (substitute `[DOCUMENT_TYPE]` per consumer)

```
Task tool (general-purpose):
  description: "Review [DOCUMENT_TYPE] document"
  prompt: |
    You are a [DOCUMENT_TYPE] document reviewer. Verify this [DOCUMENT_TYPE] is complete and ready for [next-phase].

    **[DOCUMENT_TYPE_TITLE] to review:** [FILE_PATH]
    [optional extra inputs — e.g. spec for reference, when reviewing a plan]

    ## What to Check

    | Category | What to Look For |
    |----------|------------------|
    | [consumer-specific rows — see each consumer file] |

    ## Calibration

    **Only flag issues that would cause real problems during [next-phase].**
    [consumer-specific calibration prose — concrete examples of what is and is not an issue]

    Approve unless there are serious gaps [consumer-specific examples of serious gaps].

    ## Output Format

    ## [DOCUMENT_TYPE_TITLE] Review

    **Status:** Approved | Issues Found

    **Issues (if any):**
    - [Section/Task X]: [specific issue] - [why it matters for [next-phase]]

    **Recommendations (advisory, do not block approval):**
    - [suggestions for improvement]
```

**Reviewer returns:** Status, Issues (if any), Recommendations

---

## Why this template exists

Both consumers ship a near-identical skeleton: opening prompt line, "What to Check" table, "Calibration" framing, three-part output (Status / Issues / Recommendations). Diverging skeletons silently diverge reviewer behaviour between spec-review and plan-review — so we centralize the shape here.

What is **NOT** shared: the per-row table contents, the calibration examples, and the per-section "what counts as a real problem" prose. Each consumer fills those in based on whether the document under review is a spec (requirements-readiness) or a plan (implementation-readiness).

## When updating

1. Edit the skeleton above.
2. Open each consumer (`brainstorm/spec-document-reviewer-prompt.md`, `write-plan/plan-document-reviewer-prompt.md`).
3. Apply the structural change to the inline copy.
4. Leave the consumer-specific table rows / calibration prose intact unless the change is intentional.
