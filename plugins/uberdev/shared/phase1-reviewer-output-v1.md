## Phase 1 reviewer output contract (v1)

For this routed edge, this contract overrides any earlier role-level response formatting. Put role-specific analysis in `findings[].detail`. Emit exactly one fenced YAML document with this shape as the final content of your response; do not emit another fenced YAML document or add text after the closing fence.

```yaml
verdict: APPROVE | REVISIONS_REQUIRED | REJECT
findings:
  - severity: blocker | suggestion
    location: <POSIX-repo-relative-path>:<line>
    summary: <one line>
    detail: <prose>
confidence: low | medium | high
```

Use `findings: []` when there are no findings. Verdict and severity form a two-way invariant: one or more blocker findings require `REVISIONS_REQUIRED` or `REJECT`, while zero blocker findings require `APPROVE`. Suggestions alone are advisory and therefore MUST use `APPROVE`.

Every result is validated by the canonical `uberdev_child_validate_phase1_review_result` boundary before aggregation. A malformed document, `APPROVE` result containing a blocker, or red verdict without a blocker is routed through the existing single format-retry path and blocks green if the retry remains invalid.
Absolute, Windows drive-qualified or drive-relative, traversal, dot-component, backslash, and control-character location paths are malformed.
