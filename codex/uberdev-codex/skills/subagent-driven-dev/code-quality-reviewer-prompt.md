<!--
  This file is a thin Task-tool dispatch wrapper that delegates to the `uberdev:code-reviewer`
  agent. The full reviewer prompt (checklist + output format + example) lives in:
  ../requesting-code-review/code-reviewer.md
  Both files share the Strengths / Critical / Important / Minor verdict shape — keep that
  verdict shape in sync if one side changes.
-->

# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

```
Task tool (uberdev:code-reviewer):

  WHAT_WAS_IMPLEMENTED: [from implementer's report]
  PLAN_OR_REQUIREMENTS: Task N from [plan-file]
  BASE_SHA: [commit before this task — for the wave's first reviewed task this is the wave's starting SHA; for later tasks in the same wave it's the previous task's commit SHA, since the controller committed in task ID order]
  HEAD_SHA: [this task's commit SHA]
  ALLOWED_PATHS: [task's file allowlist — review nothing outside these]
  DESCRIPTION: [task summary]

  Review focus:
  - Plan alignment: did the implementation cover the task's requirements?
  - Code quality: clarity, error handling, security, performance, maintainability
  - Architecture: separation of concerns, file boundaries, integration with existing code
  - Tests: coverage matches behavior; mocks only where unavoidable
  - Documentation: comments accurate where they exist (don't add unnecessary ones)

  Report format:
  - Strengths (what's done well)
  - Issues, categorized: Critical (must fix) / Important (should fix) / Minor (suggestions)
  - Assessment (overall verdict)
```

**In addition to standard code quality concerns, the reviewer should check:**
- Does each file have one clear responsibility with a well-defined interface?
- Are units decomposed so they can be understood and tested independently?
- Is the implementation following the file structure from the plan?
- Did this implementation create new files that are already large, or significantly grow existing files? (Don't flag pre-existing file sizes — focus on what this change contributed.)

**Code reviewer returns:** Strengths, Issues (Critical/Important/Minor), Assessment
