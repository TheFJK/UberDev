<!-- Vendored from obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6 (MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt — the base this file (upstream skills/writing-plans/plan-document-reviewer-prompt.md) was copied from and the SHA vendor.json records for the component. Measured against that blob (#503): the residual is the shared-skeleton comment below plus one behavioural rewrite — upstream dispatches this template to a general-purpose Task subagent, this copy is an INLINE self-review checklist that must not create a child. Permanent local divergence: vendor.json permanent_divergences[].plan-reviewer-inline-no-dispatch. -->
<!--
  Shared skeleton: ../_shared/document-reviewer-template.md
  Substitute: [DOCUMENT_TYPE] = plan, [DOCUMENT_TYPE_TITLE] = Plan.
  Mirror file: ../brainstorm/spec-document-reviewer-prompt.md.
  Claude Code skills do not auto-include partials — when the skeleton changes,
  update the inline content here AND in the mirror file manually.
-->

# Plan Document Reviewer Prompt Template

Use this checklist for the skill's inline plan self-review. It is not a
provider edge and must not create a child.

**Purpose:** Verify the plan is complete, matches the spec, and has proper task decomposition.

**Dispatch after:** The complete plan is written.

```
Review plan document:
    You are a plan document reviewer. Verify this plan is complete and ready for implementation.

    **Plan to review:** [PLAN_FILE_PATH]
    **Spec for reference:** [SPEC_FILE_PATH]

    ## What to Check

    | Category | What to Look For |
    |----------|------------------|
    | Completeness | TODOs, placeholders, incomplete tasks, missing steps |
    | Spec Alignment | Plan covers spec requirements, no major scope creep |
    | Task Decomposition | Tasks have clear boundaries, steps are actionable |
    | Buildability | Could an engineer follow this plan without getting stuck? |

    ## Calibration

    **Only flag issues that would cause real problems during implementation.**
    An implementer building the wrong thing or getting stuck is an issue.
    Minor wording, stylistic preferences, and "nice to have" suggestions are not.

    Approve unless there are serious gaps — missing requirements from the spec,
    contradictory steps, placeholder content, or tasks so vague they can't be acted on.

    ## Output Format

    ## Plan Review

    **Status:** Approved | Issues Found

    **Issues (if any):**
    - [Task X, Step Y]: [specific issue] - [why it matters for implementation]

    **Recommendations (advisory, do not block approval):**
    - [suggestions for improvement]
```

**Reviewer returns:** Status, Issues (if any), Recommendations
