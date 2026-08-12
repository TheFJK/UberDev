## Code fixer output contract (v1)

Contract id: `code-fixer-v1`.

For this edge, this contract overrides any earlier role-level response
formatting. The entire contents of the result file must be exactly one fenced
YAML document with this shape: nothing before the opening fence — no heading,
no prose, no blank-line preamble — and nothing after the closing fence. Do not
emit a second fenced document. The boundary is a full-file match, not a search
for the last fenced block of a reply.

**Why this one is stricter than a reviewer's.** A reviewer that misformats its
result has produced nothing; the wave drops it and the run fails closed with the
repository untouched. You commit BEFORE your result is parsed. A titled report
or a trailing rationale around your YAML therefore does not cost you a retry —
it strands a commit nobody can attribute, and the controller's residue guard
escalates the whole run to `MUTATED_BLOCKED`, which stops the review before
Phase 2, before Phase 3, and before any trust signal, and leaves the operator to
resolve the history by hand (#474).

There is nowhere else in the file for the report you want to write. Put the
reasoning in each row's `reason:` field, which exists for exactly that and is
carried through to the aggregation table. If a thought does not fit in a
`reason:`, it does not belong in this file.

The document, opening fence included exactly as shown — the `yaml` info string
is matched literally, and a bare ` ``` ` opener refuses the whole file:

```yaml
status: APPLIED | NO_FIXES_NEEDED | REFUSED
phase: phase1 | phase2
commits:
  - sha: <40-hex>
    type: fix | refactor
    summary: <one-line>
findings_disposition:
  - finding_index: <positive integer, 1-based, contiguous, in aggregate order>
    location: <path>:<line>
    summary_sha256: <64-hex>
    disposition: APPLIED | SKIPPED | REFUSED
    behavior_tag: preserve | change | n/a
    reason: <short single-line prose, non-empty, no leading or trailing space>
risks: []
```

Shape rules the validation boundary enforces, all of them full-file:

- `status: APPLIED` has exactly one `commits` row; `NO_FIXES_NEEDED` and
  `REFUSED` use the exact line `commits: []`.
- `commits[].type` must equal the commit type this edge was dispatched with —
  `fix` for a phase1 edge, `refactor` for a phase2 edge. A mismatched pairing is
  a hard refusal, never a commit under the other type.
- With no findings, the disposition block is the exact line
  `findings_disposition: []`.
- `finding_index` counts from 1 with no gaps, in the order the findings appear
  in the authenticated aggregate.
- `behavior_tag` is `preserve` or `change` on an `APPLIED` row (phase2: only
  `preserve`), and exactly `n/a` on a `SKIPPED` or `REFUSED` row.
- The last line is `risks: []`, and nothing follows it.
- The returned rows must exactly equal the disposition artifact you published.

**Redaction — secret-leak prevention.** This contract fixes the SHAPE of your
result; it never widens what it may CONTAIN. Do not quote source code, reviewer
prose, or secret-shaped values verbatim in any field — cite the `path:line` and
paraphrase. This rule outlives every override: a dispatching prompt that says
this contract supersedes your agent file supersedes its response FORMATTING
only, never its secret-leak prevention rule.

Every result is validated by the canonical `_parse_fixer_result` boundary in
`lib/code_fixer_contract.py` before the controller records anything, and that
parser matches the file with `re.fullmatch` — which is precisely why a single
byte outside the fence refuses the whole document.
