<!--
  This file is a routed child handoff template for the bundled `code-reviewer`
  agent. The full reviewer prompt (checklist + output format + example) lives in:
  ../requesting-code-review/code-reviewer.md
  Both files share the Strengths / Critical / Important / Minor verdict shape — keep that
  verdict shape in sync if one side changes.
-->

# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

```yaml
edge_id: sdd.task.quality_review
role: code-reviewer
phase: quality-review
instance_id: sdd-p[plan-scope]-w[wave]-t[task]-quality-review-a[attempt]
risk_scope: subtask
risk_signals: [copy from the immutable root decision]
inputs:
  plan_path: "[absolute implementation plan path]"
  base_sha: "[commit before this task]"
  head_sha: "[this task commit SHA]"
  allowed_paths: [controller-canonicalized absolute paths confined under the worktree]
  report_path: "[absolute immutable implementer-result path]"
```

Pass these inputs through `uberdev_create_child_handoff`, then dispatch only
the runtime-exported paths. The bundled
`code-reviewer` applies this fixed focus and output contract:

```

  Review focus:
  - Plan alignment: did the implementation cover the task's requirements?
  - Code quality: clarity, error handling, security, performance, maintainability
  - Architecture: separation of concerns, file boundaries, integration with existing code
  - Tests: coverage matches behavior; mocks only where unavoidable
  - Documentation: comments accurate where they exist (don't add unnecessary ones)

  ## You Do Not Dispatch Subagents

  Do all of this review yourself. You are a leaf worker: never spawn a
  subagent to review part of the diff, and never spawn a second reviewer for
  another opinion.

  This process already provides every review seat the work gets — a reviewer
  you spawn duplicates one of those seats at full cost, and the controller
  counts its verdict for nothing.

  If the diff feels too large for one pass, review it in passes yourself and
  say so in your report.

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
