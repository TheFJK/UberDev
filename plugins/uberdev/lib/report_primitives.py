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
import re

# The findings-to-issues envelope close marker. A finding whose text contains
# this literal would otherwise close the envelope early and promote
# attacker-derived rows to trusted prose (security.md #6, MEDIUM, D7). We
# neutralize it by splitting the closing `</...>` so the literal tag never
# appears verbatim in output, while staying human-readable.
_ENVELOPE_CLOSE = "</external-untrusted-input>"
_ENVELOPE_CLOSE_NEUTRALIZED = "<​/external-untrusted-input>"  # ZWSP after '<'


def cell(s):
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
    text = text.replace(_ENVELOPE_CLOSE, _ENVELOPE_CLOSE_NEUTRALIZED)
    return text.replace("|", "\\|")


def envelope(fh, source, body):
    """Write `body` wrapped in the findings-to-issues spotlighting envelope.

    The opening marker is written as the LEADING bytes of the file (no header,
    BOM, or blank line may precede it — findings-to-issues refuses if the
    marker is not within the first 128 bytes; agents/findings-to-issues.md:41).
    `source` MUST be a value in the findings-to-issues closed allow-list when
    the output is consumed by that agent. `body` is the already-rendered table
    (each cell already passed through cell()).
    """
    fh.write(f'<external-untrusted-input source="{source}">\n')
    fh.write(body)
    if body and not body.endswith("\n"):
        fh.write("\n")
    fh.write("</external-untrusted-input>\n")


def sort_by_rank(rows, rank_map, rank_key, *, tiebreakers=("location", "summary")):
    """Sort rows by descending rank, then by the given tiebreaker fields ascending.

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
