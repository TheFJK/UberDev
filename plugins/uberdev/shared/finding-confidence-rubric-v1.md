## Finding confidence rubric (v1)

> **Vendored.** The 0–100 scale and the false-positive catalogue below are
> adapted from Anthropic's official `code-review` plugin (Apache 2.0). The full
> licence text ships at `plugins/uberdev/licenses/pr-review-toolkit-Apache-2.0.txt`.

This file declares the **scale only**. It does not say what any consumer does
with a score — each consumer declares its own use, so that the scale can be
shared without the policies merging:

- `agents/code-reviewer.md` uses it as a **reporting filter**: score your own
  finding, stay silent below the floor, map the rest onto `blocker` /
  `suggestion`.
- `agents/finding-verifier.md` uses it as an **adjudication scale**: score
  somebody else's claim on its merits and emit the number. The verifier is
  never told the cutoff — the comparison happens controller-side, so the
  recorded score is an opinion about the claim, not about the gate.

Restating these anchors anywhere else under `plugins/` is a contract copy that
will drift; `tests/post-impl-review.test.sh` asserts they appear here and
nowhere else.

### The scale

Rate the issue from 0 to 100:

- **0-25**: Likely false positive, or a pre-existing issue this change did not
  introduce. Does not survive light scrutiny.
- **26-50**: Minor nitpick, not required by any project guideline.
- **51-75**: Valid but low-impact.
- **76-90**: Important issue requiring attention.
- **91-100**: Critical bug, or an explicit violation of a stated project
  guideline (`CLAUDE.md` or equivalent), independently reproduced from the
  change under review.

The two ends are the anchors that matter. **0** means the claim does not
survive light scrutiny or is pre-existing. **100** means you independently
reproduced the problem from the change itself, without relying on anyone's
argument that it exists.

### False positives — score these low

Each of the following is a reason to score toward the bottom of the scale, not
a reason to hedge in the middle:

1. **Pre-existing issues.** The problem is already present on the base; the
   change under review neither introduced nor worsened it.
2. **Things that look like bugs but are not.** Trace the actual control and
   data flow before believing the shape.
3. **Nitpicks a senior engineer would not raise** in a real review.
4. **Anything a linter, typechecker, or compiler catches.** Those tools already
   run; a finding that duplicates them costs attention and buys nothing.
5. **General code-quality opinions** with no backing requirement in the
   project's `CLAUDE.md` or equivalent.
6. **Issues explicitly silenced in code** — a suppression comment, an
   annotation, or a documented deliberate exception.
7. **Likely-intentional changes.** A deletion or behaviour change that reads as
   deliberate, and that nothing in the change contradicts.
8. **Findings on lines the change did not modify.** Out of scope by
   construction, whatever their merit.
9. **Speculative failure modes** with no concrete input, state, or sequence
   that produces them.

A finding that lands in any of these categories and still deserves a high score
needs the concrete evidence to say so — a specific input, a specific line in
the change, and the specific wrong outcome.
