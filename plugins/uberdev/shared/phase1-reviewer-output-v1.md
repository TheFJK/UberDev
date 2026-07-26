## Phase 1 reviewer output contract (v1)

For this routed edge, this contract overrides any earlier role-level response formatting. Put role-specific analysis in `findings[].detail`. Emit exactly one fenced YAML document with this shape as the final content of your response; do not emit another fenced YAML document or add text after the closing fence.

```yaml
verdict: APPROVE | REVISIONS_REQUIRED | REJECT
findings:
  - severity: blocker | suggestion
    location: <POSIX-repo-relative-path>:<line>
    summary: <one physical scalar line>
    detail: <one physical scalar line>
confidence: low | medium | high
```

Use `findings: []` when there are no findings. Verdict and severity form a two-way invariant: one or more blocker findings require `REVISIONS_REQUIRED` or `REJECT`, while zero blocker findings require `APPROVE`. Suggestions alone are advisory and therefore MUST use `APPROVE`.

`location`, `summary`, and `detail` use the validator's deliberately small
single-line scalar grammar. Each value must be non-empty and have no leading or
trailing whitespace or control characters. Use either a JSON-compatible
double-quoted string, a YAML single-quoted string with embedded apostrophes
doubled, or a plain scalar. Plain scalars may not begin with
`-?:,[]{}#&*!|>@\``; contain `: ` or ` #`; or spell a YAML null, boolean, or
number token. YAML block scalars (`|` and `>`) and multi-line values are not
accepted. Quote any value that is uncertain under these rules.

Every result is validated by the canonical `uberdev_child_validate_phase1_review_result` boundary before aggregation. A malformed document, `APPROVE` result containing a blocker, or red verdict without a blocker is routed through the existing single format-retry path and blocks green if the retry remains invalid.
Absolute, Windows drive-qualified or drive-relative, traversal, dot-component, backslash, and control-character location paths are malformed.
