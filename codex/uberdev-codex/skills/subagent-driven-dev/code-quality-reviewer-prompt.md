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
instance_id: sdd-w[wave]-t[task]-quality-review-a[attempt]
risk_scope: subtask
risk_signals: [copy from the immutable root decision]
inputs:
  task_id: "[task ID]"
  implemented_summary: "[from implementer report]"
  plan_requirements: "[Task N from plan]"
  base_sha: "[commit before this task]"
  head_sha: "[this task commit SHA]"
  allowlist: [controller-canonicalized absolute paths confined under the worktree]
  description: "[task summary]"
  attempt: [positive integer]
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
