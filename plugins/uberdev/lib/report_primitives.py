#!/usr/bin/env python3
"""Schema-agnostic report primitives shared by uberscan-pipeline/report.py and
testers-pipeline/report.py (issue #166, D1/D2/D6/D7).

Imported in-process via sys.path.insert from each report.py — NOT a subprocess
CLI (the callers need cell()/sort_by_rank as Python callables per row).

Extracted here (schema-agnostic): cell(), the <external-untrusted-input>
envelope emitter, and a rank-parameterized sort helper.
Deliberately NOT here (pipeline-local): SEV_RANK maps, norm()/fingerprint()/
dedupe(), load_findings()/read_global(), per-pipeline main()/column schemas.
"""
import json
import re
from typing import Callable, Sequence, TextIO

# The findings-to-issues envelope close marker. A finding whose text contains
# this literal would otherwise close the envelope early and promote
# attacker-derived rows to trusted prose (security.md #6, MEDIUM, D7). We
# neutralize it by splitting the closing `</...>` so the literal tag never
# appears verbatim in output, while staying human-readable.
_ENVELOPE_CLOSE = "</external-untrusted-input>"
# The neutralized form inserts a U+200B ZERO WIDTH SPACE immediately after the
# '<'. ZWSP is chosen because it is invisible when rendered yet breaks the exact
# byte sequence `</external-untrusted-input>` the downstream parser scans for, so
# a maintainer grepping the literal close-tag still finds this line. (The visible
# difference between the two string literals above/below is exactly that one ZWSP.)
_ENVELOPE_CLOSE_NEUTRALIZED = "<​/external-untrusted-input>"  # ZWSP after '<'

# The findings-to-issues accepted-source allow-list — the SINGLE source of truth
# (issue #198). Any value passed as `envelope(..., source, ...)` MUST be a member;
# envelope() asserts this at emit time so a typo or a new pipeline that ships an
# un-accepted source fails LOUDLY here instead of silently filing zero issues
# (the #182-class bug). When you add a pipeline/source, add it here AND to the
# closed set in agents/findings-to-issues.md Step 1 (a cross-consistency test in
# tests/findings-to-issues.test.sh asserts the two agree).
ACCEPTED_SOURCES = frozenset({
    "post-impl-review-aggregate",
    "simplify-aggregate",
    "ci-refused-synthetic",
    "uberscan-aggregate",
    "ubersimplify-aggregate",
    "testers-aggregate",
    "uberthink-aggregate",
})

PHASE1_CONTRIBUTORS = (
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
    "review_pr.review.convention",
)
PHASE2_CONTRIBUTORS = (
    "review_pr.simplify.reuse",
    "review_pr.simplify.quality",
    "review_pr.simplify.efficiency",
)


def cell(s: object) -> str:
    """Escape a value for a markdown table cell, shared by both report.py files.

    - None -> "" (never the literal string "None"); applied first so the
      newline-collapse below never receives a non-string.
    - Collapse any run of whitespace-newline-whitespace to a single space so one
      finding stays on one table row.
    - Neutralize a literal </external-untrusted-input> close-tag so an injected
      finding cannot break out of the spotlighting envelope (D7, security.md #6).
    - Escape the `|` column delimiter LAST.
    """
    text = str("" if s is None else s)
    text = re.sub(r"\s*\n\s*", " ", text)
    # Only the EXACT verbatim close-tag can terminate the downstream envelope;
    # the parser matches that byte sequence literally, so spaced/cased/split
    # variants are already inert and neutralizing the verbatim form suffices.
    text = text.replace(_ENVELOPE_CLOSE, _ENVELOPE_CLOSE_NEUTRALIZED)
    return text.replace("|", "\\|")


def envelope(fh: TextIO, source: str, body: str) -> None:
    """Write `body` wrapped in the findings-to-issues spotlighting envelope.

    The opening marker is written as the LEADING bytes of the file (no header,
    BOM, or blank line may precede it — findings-to-issues refuses if the
    marker is not within the first 128 bytes; agents/findings-to-issues.md:42).
    `source` MUST be a value in the findings-to-issues closed allow-list when
    the output is consumed by that agent; this is now asserted at emit time
    against ACCEPTED_SOURCES (issue #198) so an un-accepted source raises here
    instead of silently filing zero issues downstream. `body` is an already-
    rendered payload; callers own its schema and escaping.
    """
    if source not in ACCEPTED_SOURCES:
        raise ValueError(
            f"envelope(): source {source!r} is not in the findings-to-issues "
            f"ACCEPTED_SOURCES allow-list {sorted(ACCEPTED_SOURCES)} — add it here "
            f"and to agents/findings-to-issues.md Step 1 (issue #198/#182)."
        )
    fh.write(f'<external-untrusted-input source="{source}">\n')
    fh.write(body)
    if body and not body.endswith("\n"):
        fh.write("\n")
    fh.write("</external-untrusted-input>\n")


def canonical_json(value: object) -> str:
    """Return the aggregate contract's exact compact, sorted JSON bytes as text.

    JSON does not normally escape ``<``. Escape the envelope close marker's
    opening angle bracket as ``\u003c`` so reviewer-derived prose cannot create a
    second structural trailer. Decoding the JSON restores the original prose.
    """
    rendered = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return rendered.replace(_ENVELOPE_CLOSE, "\\u003c/external-untrusted-input>")


def json_envelope(fh: TextIO, source: str, value: object) -> None:
    """Write one canonical compact JSON value in a spotlighting envelope."""
    envelope(fh, source, canonical_json(value))


def sort_by_rank(
    rows: list[dict],
    rank_map: dict[str, int],
    rank_key: Callable[[dict], str],
    *,
    tiebreakers: Sequence[str] = ("location", "summary"),
) -> list[dict]:
    """Sort rows by descending rank, then by the given tiebreaker fields ascending.

    Note: currently uberscan-only; available for future report consumers.

    rank_map: caller-owned severity->int map (uberscan and testers differ — D2;
              the policy stays pipeline-local, only the mechanism is shared).
    rank_key: callable(row) -> the key looked up in rank_map (e.g. row severity).
    tiebreakers: row-dict keys appended to the sort key (ascending) to make the
                 order fully deterministic even when ranks tie (Item 4 / AC4).
                 Each tiebreaker value is coerced to str("" if None else v).
    Returns a NEW list (does not mutate input).
    """
    def _key(row):
        rank = rank_map.get(rank_key(row), 0)
        tb = tuple(str("" if row.get(t) is None else row.get(t)) for t in tiebreakers)
        return (-rank, *tb)
    return sorted(rows, key=_key)


def fingerprint16(s: str) -> str:
    """Return the lower-cased 16-hex prefix of sha256(s.encode()).

    Shared with cluster-pipeline/cluster_propose.py and reserved for a future
    findings-to-issues-aggregate helper (spec D7/Q11). Pinning the format here
    prevents divergent reimplementations of the same 16-hex prefix idiom.
    """
    import hashlib
    return hashlib.sha256(s.encode()).hexdigest()[:16].lower()
