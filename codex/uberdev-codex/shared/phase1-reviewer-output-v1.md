## Phase 1 reviewer output contract (v1)

Emit exactly one fenced YAML block with this shape as the final content of your response. Do not add text after the closing fence.

```yaml
verdict: APPROVE | REVISIONS_REQUIRED | REJECT
findings:
  - severity: blocker | suggestion
    location: <repo-relative-path>:<line>
    summary: <one line>
    detail: <prose>
confidence: low | medium | high
```

Use `findings: []` when there are no findings. One or more blocker findings require `REVISIONS_REQUIRED` or `REJECT`; suggestions alone remain advisory and permit `APPROVE`.
