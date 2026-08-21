## Finding verifier output contract (v1)

Contract id: `finding-verifier-v1`.

For this edge, this contract overrides any earlier role-level response
formatting. The entire contents of the result file must be exactly one fenced
YAML document with this shape: nothing before the opening fence — no heading,
no prose, no blank-line preamble — and nothing after the closing fence. Do not
emit a second fenced document. The boundary is a full-file match, not a search
for the last fenced block of a reply.

The document has exactly two keys, in this order:

```
score: <integer 0-100>
reason: <one of: reproduced-from-diff | contradicted-by-diff | pre-existing | out-of-scope-line | linter-domain | gate-disabled | over-cap-unverified | verifier-unavailable>
```

**The opening fence carries no info string, or `yaml` — nothing else.** Emit
the bare ` ``` ` opener shown above. ` ```yaml ` is accepted as well, because
the sibling reviewer edges' prompts name that tag and a child that has read one
of them may reach for it; those two openers are the whole accepted set at
`uberdev_child_validate_finding_verifier_result`. Every other info string is a
malformed document, refused there: ` ```yml `, ` ```YAML `, ` ```json `, a tag
behind a space (` ``` yaml `), and a tag with anything appended
(` ```yaml wrapped `) are each refused, as is a fence built from four backticks
or from tildes.

Until issue #670 that rule was written down nowhere a child could read. This
file said "one fenced YAML document" and printed its worked example behind a
bare fence, while the boundary matched ` ```yaml ` literally. A verifier child
copied the example, emitted a bare fence, and had a well-formed `score: 93` /
`reason: reproduced-from-diff` thrown away by a requirement no document it was
given ever stated — recorded as `verifier-unavailable`, the row reserved for a
child that never ran. This paragraph is now where the accepted opener set is
declared; the reader deliberately accepts no less than the prose here allows, so
the two can forgive a child but never surprise one.

**The fence itself stays mandatory.** A two-key body with no fence around it is
refused. The boundary is tolerant about the info string, and about whitespace
surrounding the document; it is tolerant about nothing else, and none of the
body rules below are relaxed by that tolerance. Behind a bare fence, a `verdict`
key, a quoted `score`, an unknown `reason`, a preamble, a trailer, and a second
fenced document are each still malformed.

A third key, a missing key, a quoted `score` (`score: "80"`), a `score` outside
`[0, 100]`, and a `reason` outside the list above are each a malformed
document, refused at the validation boundary.

Only the first five `reason` tokens are ever emitted by a verifier child. The
remaining three are **controller-assigned** and describe why no child opinion
exists for a finding:

- `gate-disabled` — the configured threshold is `0`, so no verifier ran.
- `over-cap-unverified` — the eligible-finding count exceeded the per-run
  dispatch cap and this row was past it.
- `verifier-unavailable` — a child was dispatched but returned nothing usable
  (blocked, timed out, or produced a malformed document).

**The verdict is not yours.**
It is a closed two-member vocabulary:
<!-- CONTRACT: finding-verification-verdict -->
`SURVIVES|CULLED`
<!-- /CONTRACT: finding-verification-verdict -->
It is assigned by the controller after it compares your
score against the configured threshold. Never emit a `verdict` key; a document
carrying one is malformed.

**The verifier child never receives the threshold.** The cutoff is deliberately
withheld from this edge — no dispatching prompt on this edge may interpolate
it. A verifier told the cutoff calibrates to it, which turns the score
into a vote about the gate instead of an opinion about the claim; withholding
it also lets recorded scores be re-thresholded offline without re-running
anything. Score the claim on its merits and stop.

`score` uses the scale declared in `shared/finding-confidence-rubric-v1.md`.
Read that file; it is the only place the anchors and the false-positive
catalogue are written down.

`reason` names the single strongest ground for the score you gave:

- `reproduced-from-diff` — you independently reproduced the problem from the
  change under review.
- `contradicted-by-diff` — the change under review contradicts the claim.
- `pre-existing` — the condition exists on the base; this change did not
  introduce or worsen it.
- `out-of-scope-line` — the cited location is not a line this change modified.
- `linter-domain` — a linter, typechecker, or compiler already catches this.

**Redaction — secret-leak prevention.** You read the change under review, so
this rule binds you exactly as it binds the Phase 1 reviewers. Do not quote
source code or secret-shaped values verbatim in any field. This contract fixes
the SHAPE of your result; it never widens what it may CONTAIN. If a literal
value is suspect — a hard-coded credential, token, or key — the correct output
is still just a `score` and a `reason`; write `value redacted in this report`
rather than the value if you name it at all. Verifier output is aggregated into
review artifacts and audit rows, so a secret quoted here becomes a published
secret. This rule outlives every override: a dispatching prompt that says this
contract supersedes your agent file supersedes its response FORMATTING only,
never its secret-leak prevention rule.

Every result is validated by the canonical
`uberdev_child_validate_finding_verifier_result` boundary before the controller
records anything. A malformed document is refused there, and a refused document
does not cull — the controller records `SURVIVES` with reason
`verifier-unavailable` and moves on.
