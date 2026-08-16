#!/usr/bin/env python3
"""tests/launcher_edge_ids.py — every run-tree edge id the solve launcher names
must resolve to a real edge in the run-tree manifest (issue #536).

THE CLASS. `plugins/uberdev/lib/solve-launcher.sh` set
`UBERDEV_ROOT_EDGE_ID="solve.lead.$TIER"`, and `$TIER` is one of
trivial|small|medium|large — so every value that line could produce named an
edge that does not exist in `plugins/uberdev/policy/solve-run-tree-v1.json`
(whose only `solve.lead.*` edges are `.orchestrator`, `.brainstorm` and
`.finish_branch`). Nothing read the variable, so nothing ever noticed. This is
the #370 shape — a declaration naming a pipeline surface that nobody compares
against the tree — on the shell-runtime side; issue #510 fixed the manifest side
with `tests/solve-run-tree-scope.test.sh`.

WHAT IT CHECKS. Three rules, all anchored on the manifest as the single source
of truth. The accepted vocabulary is DERIVED from the tree, never hardcoded
here, so renaming an edge in the manifest changes what this guard accepts.

  L1 — LITERAL RESOLUTION. Guarded prefixes come from the tree: every key of
       `edges` with three or more dot-segments whose first segment is `solve`
       contributes `<seg0>.<seg1>.` (today: `solve.issue.` and `solve.lead.`).
       Every `<prefix>[A-Za-z0-9_${}<>-]+` token in the launcher — in code, in a
       comment, in a string alike — must be an exact key of `edges`. The
       vocabulary is closed, so an UNRESOLVABLE id is a WRONG id:
       `solve.lead.$TIER`, `solve.lead.${TIER}` and `solve.lead.<tier>` are
       violations by construction. Requiring a third segment is what keeps the
       launcher's `commands/solve.md` references out of the match set.

  L2 — ASSIGNMENT-SITE BACKSTOP. Every line assigning a `*EDGE_ID` variable must
       have a bare double-quoted literal RHS (no `$`, no backtick, no backslash)
       that is a key of `edges`. This catches a future
       `UBERDEV_ROOT_EDGE_ID="$SOMETHING"`, whose value L1's token scan cannot
       see at all.

  L3 — ANTI-VACUITY FLOOR. Tree-derived and positive, not a bare count: L1 must
       have matched at least one token, AND `tree["root_edge_id"]` must be among
       the matched tokens. A reword that quietly drops the real root edge reds
       with the edge id named, rather than passing because there is nothing left
       to disagree with.

DECLARED LIMITS — read these before trusting a green run. A guard whose name
promises more than its predicate delivers is the very class this file exists to
close, so the gap is written down rather than left implied.

  * NOT A TREE-CONSISTENCY CHECKER. It deliberately does NOT assert that
    `root_edge_id` is a key of `edges` — that invariant belongs to
    `tests/solve-run-tree.test.sh`, and duplicating it here would give a
    mutated-tree fixture two possible causes and destroy the attribution.
  * NOT A READER CHECK. It proves an emitted id RESOLVES; it cannot prove any
    descendant ever reads it. The orphan half of #536 is a human judgement.
  * NOT SHELL-AWARE. The launcher is scanned as text. A `solve.lead.*` token
    inside a comment or a heredoc is a finding on purpose: the comment prose is
    exactly where the fictional `solve.lead.<tier>` id survived review.
  * TAIL EXCLUDES `.`. A token stops at its third segment, so a future
    four-segment `solve.<area>.<a>.<b>` edge would be matched as
    `solve.<area>.<a>` and reported unresolvable. That is a loud false red to be
    fixed here, never a silent pass.
  * L2 IS LINE-ANCHORED. An assignment tucked mid-line after a `;` is invisible
    to L2 (L1 still sees the token if it is a `solve.*` id).

INTERFACE.

    python3 -I -B tests/launcher_edge_ids.py --tree <path|-> --launcher <path|->

Exactly one of the two may be `-` and is then read from stdin; both `-` is a
usage error, because stdin has a single reader. That is what lets a caller
mutate either side in memory, with no temp file, in either direction.

OUTPUT. Findings go to stderr in two shapes. Line-anchored (L1, L2):
`<path-or-->:<line>: <reason>`. Whole-file (L3, which has no line to point at):
`<path-or-->: <reason>`. A clean run prints one summary line to stdout.

EXIT CODES.  0 = clean · 1 = one or more violations · 2 = usage, I/O, JSON or
precondition error.

PORTABLE. Standard library only. No temp file, no subprocess, no `git`, no
network, no digest. Both inputs are read as BYTES and decoded as UTF-8
explicitly — `shape-checks-windows` runs a cp1252-default interpreter — and
`str.splitlines()` then absorbs the CRLF of an `autocrlf=true` checkout.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# Tail of a guarded token: the third segment of an edge id, plus the shell and
# placeholder characters that make a WRONG id look like a right one
# (`$TIER`, `${TIER}`, `<tier>`). `.` is excluded — see DECLARED LIMITS.
TOKEN_TAIL = r"[A-Za-z0-9_${}<>-]+"

# L2's assignment sites. The optional declaration keyword widens the plan's
# `^[ \t]*[A-Z0-9_]*EDGE_ID=` so that `export UBERDEV_ROOT_EDGE_ID="$X"` — the
# exact shape L1 cannot see — is caught rather than waved through.
ASSIGNMENT = re.compile(r"^[ \t]*(?:export|local|declare|readonly|typeset)?[ \t]*[A-Z0-9_]*EDGE_ID=(.*)$")

# A bare double-quoted literal: no expansion, no command substitution, no
# escape. A trailing shell comment is tolerated; nothing else is.
BARE_LITERAL = re.compile(r'^"([^"$`\\]*)"(?:[ \t]+#.*)?$')

PROG = "launcher-edge-ids"


class Fatal(Exception):
    """A precondition the checker cannot run without — exit 2, never a verdict."""


def read_source(label: str) -> str:
    """Read a path (or stdin for `-`) as bytes and decode it as UTF-8."""
    try:
        if label == "-":
            data = sys.stdin.buffer.read()
        else:
            with open(label, "rb") as handle:
                data = handle.read()
    except OSError as error:
        raise Fatal(f"cannot read {label}: {error}") from error
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Fatal(f"{label}: not valid UTF-8: {error}") from error


def load_tree(label: str) -> tuple[set[str], str]:
    """Return (edge ids, root edge id) from the run-tree manifest."""
    try:
        tree = json.loads(read_source(label))
    except ValueError as error:
        raise Fatal(f"{label}: invalid JSON: {error}") from error
    if not isinstance(tree, dict):
        raise Fatal(f"{label}: manifest must be a JSON object")
    edges = tree.get("edges")
    if not isinstance(edges, dict) or not edges:
        raise Fatal(f"{label}: 'edges' must be a non-empty object")
    root = tree.get("root_edge_id")
    if not isinstance(root, str) or not root:
        raise Fatal(f"{label}: 'root_edge_id' must be a non-empty string")
    # Deliberately NOT asserted: root in edges. See DECLARED LIMITS.
    return set(edges), root


def token_pattern(label: str, edge_ids: set[str], root: str) -> re.Pattern[str]:
    """Compile the guarded-token extractor from the tree's own vocabulary."""
    prefixes = set()
    for edge in edge_ids:
        segments = edge.split(".")
        if len(segments) >= 3 and segments[0] == "solve":
            prefixes.add(f"{segments[0]}.{segments[1]}.")
    if not prefixes:
        raise Fatal(
            f"{label}: no 'solve.<area>.<name>' edge in the manifest — there is no "
            "vocabulary left to guard, so a green run would mean nothing"
        )
    pattern = re.compile("(?:%s)%s" % ("|".join(re.escape(p) for p in sorted(prefixes)), TOKEN_TAIL))
    if not pattern.fullmatch(root):
        raise Fatal(
            f"{label}: root_edge_id '{root}' is not shaped like a guarded token "
            f"(prefixes: {', '.join(sorted(prefixes))}) — the L3 floor could never be met"
        )
    return pattern


def scan(text: str, edge_ids: set[str], root: str, pattern: re.Pattern[str]) -> tuple[list[tuple[int | None, str]], list[str]]:
    """Apply L1, L2 and L3 to the launcher text. Returns (findings, matched tokens)."""
    findings: list[tuple[int | None, str]] = []
    matched: list[str] = []

    for number, line in enumerate(text.splitlines(), 1):
        for match in pattern.finditer(line):
            token = match.group(0)
            matched.append(token)
            if token not in edge_ids:
                findings.append((number, f"unresolvable edge id '{token}' (not a key of edges)"))
        assignment = ASSIGNMENT.match(line)
        if assignment is None:
            continue
        rhs = assignment.group(1).strip()
        literal = BARE_LITERAL.match(rhs)
        if literal is None:
            findings.append((number, f"EDGE_ID assignment RHS is not a bare double-quoted literal: {rhs}"))
        elif literal.group(1) not in edge_ids:
            findings.append((number, f"EDGE_ID assignment names an unresolvable edge id: '{literal.group(1)}'"))

    # L3 — both conditions reported, never short-circuited: losing every token
    # and losing the root edge are different regressions with the same symptom.
    if not matched:
        findings.append((None, "launcher names no tree edge at all — the extractor matched nothing"))
    if root not in matched:
        findings.append((None, f"launcher never names the tree root edge id '{root}'"))
    return findings, matched


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Check that every run-tree edge id named by the solve launcher resolves to a real edge.",
    )
    parser.add_argument("--tree", required=True, metavar="PATH", help="run-tree manifest JSON ('-' reads stdin)")
    parser.add_argument("--launcher", required=True, metavar="PATH", help="launcher shell source ('-' reads stdin)")
    args = parser.parse_args(argv)
    if args.tree == "-" and args.launcher == "-":
        # argparse's own error path exits 2 — the same code every other
        # precondition failure uses.
        parser.error("only one of --tree/--launcher may be '-': stdin has a single reader")

    try:
        edge_ids, root = load_tree(args.tree)
        pattern = token_pattern(args.tree, edge_ids, root)
        text = read_source(args.launcher)
    except Fatal as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return 2

    findings, matched = scan(text, edge_ids, root, pattern)
    for line, reason in findings:
        anchor = args.launcher if line is None else f"{args.launcher}:{line}"
        print(f"{anchor}: {reason}", file=sys.stderr)
    if findings:
        print(f"{PROG}: {len(findings)} violation(s) in {args.launcher}", file=sys.stderr)
        return 1
    print(f"{PROG}: {len(matched)} edge id token(s) in {args.launcher} resolved against {len(edge_ids)} manifest edges")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
