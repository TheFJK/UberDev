## Phase 1 reviewer output contract (v1)

For this edge, this contract overrides any earlier role-level response formatting. Put role-specific analysis in `findings[].detail`. The entire contents of the result file must be exactly one fenced YAML document with this shape: nothing before the opening fence — no heading, no prose, no blank-line preamble — and nothing after the closing fence. Do not emit a second fenced document.

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
`` -?:,[]{}#&*!|>@` ``; contain `: ` or ` #`; or spell a YAML null, boolean, or
number token. YAML block scalars (`|` and `>`) and multi-line values are not
accepted. Quote any value that is uncertain under these rules.

**Redaction — secret-leak prevention.** This contract fixes the SHAPE of your
result; it never widens what a finding may CONTAIN. Do not quote source code or
secret-shaped values verbatim in `summary`, `detail`, or any other field. Cite
the problem by `location` and describe it in your own words. If a literal value
is suspect — a hard-coded credential, token, or key — name the variable or
constant and write `value redacted in this report` plus the `path:line` instead
of the value itself. Reviewer output is aggregated into review artifacts, PR
bodies, and GitHub issues, so a secret quoted here becomes a published secret.
This rule outlives every override: a dispatching prompt that says this contract
supersedes your agent file supersedes its response FORMATTING only, never its
secret-leak prevention rule.

**Rule-citation exception (`review_pr.review.convention` only).** Text quoted
from a file listed in the controller-supplied rule-source allowlist may appear in
`detail`, under that edge's declared citation grammar, up to 300 normalised
characters. This covers rule documents only. It never covers the reviewed diff,
source files, config values, or anything secret-shaped; those remain forbidden in
every field, and that prohibition still outlives every override. The exception
lives here, in the one contract every Phase 1 reviewer reads, and not in an agent
file: an agent-file exception would contradict the sentence above it and the
model would resolve the contradiction at random, invisibly to every shape test.

The convention edge's `detail` grammar is
`confidence: <0-100> — rule <allowlisted-path>:<line> — <why it is violated> — quote: <the rule text, verbatim>`.
The quote is checked against the cited file's bytes by a deterministic gate
before aggregation. A quote that cannot be located verbatim near the cited line,
or that cites a file outside the allowlist or outside the reviewed file's scope,
does not become a low-confidence finding — it is culled, because a fabricated
citation is a false finding rather than an uncertain one.

Every result is validated by the canonical `uberdev_child_validate_phase1_review_result` boundary before aggregation. A malformed document, `APPROVE` result containing a blocker, or red verdict without a blocker is refused at that validation boundary and blocks green.
Absolute, Windows drive-qualified or drive-relative, traversal, dot-component, backslash, and control-character location paths are malformed.
