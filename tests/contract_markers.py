#!/usr/bin/env python3
"""Closed-vocabulary drift guard — the Half A meta-test for issue #370.

WHAT THIS GUARDS
================
The class behind #360/#361/#362 is: *one contract, two or more independent
copies, and nothing comparing them*.  #370's Half A is the subset where every
copy is the SAME TOKEN SET written in a different language — a bash `case`
alternation, a jq regex, a Python `frozenset`, a JSON array, a shell scalar, a
markdown table cell.  Because those copies are textually comparable, ONE
comparator retires all of them plus every future member of the family.

Before this file, the only signal that two literals were coupled was a prose
comment (`lib/goal-state.sh` "Keep this list byte-aligned with the dispatch enum
minus auto"; `lib/status.sh` "Contract mirrors, not independent policy … so
drift stays auditable").  Auditable by a human, enforced by nothing.
**A comment is not a producer.**  The marker turns that comment into one.

MARKER GRAMMAR
==============
A comment line placed at the declaration site::

    CONTRACT: <name> [@<anchor>] [/<regex>/] [<delta> ...]

and, optionally, a closing line that extends the region::

    /CONTRACT: <name>

The comment leader is per-language and is stripped before parsing: ``#`` for
shell / Python / jq, ``//`` for JavaScript, ``<!-- ... -->`` for Markdown.

``<name>``   kebab-case contract id (``dispatch-backend``, ``trust-signal``).

``@anchor``  OPTIONAL.  Without it the region starts on the line directly below
             the marker.  With it the region starts at the first line at or
             after the marker containing the literal ``<anchor>`` text.  This
             exists because two real declaration sites cannot take a comment
             directly above them: `skills/goal-pipeline/SKILL.md`'s constants
             block is a fenced block held byte-identical by goal.test.sh
             G24/G28/G34, and `skills/merge-pipeline/SKILL.md`'s enum lives in a
             Markdown table where an interleaved comment line would split the
             table in two.

``!mode``    OPTIONAL.  Selects a built-in extractor.  Today only ``!case-arm``:
             every arm head of the region's OUTERMOST shell ``case``, quoted arms
             included, nested cases excluded by depth.  Regions default to ONE
             line, which makes "add a new arm" — the most likely real edit to a
             switch — invisible; close such a region with ``/CONTRACT:`` at its
             ``esac`` and use this mode.

``/regex/``  OPTIONAL.  Switches the site to *harvest mode*: members are the
             union of every match of the regex in the region (all participating
             capture groups, else group 0), each match then tokenised exactly
             like a span.  Needed where the declaration is SCATTERED rather than
             a single literal — `lib/live-semaphore.sh` assigns its 12 failure
             reasons across ~20 statements, and `uberdev_goal_read_trust_signal`
             emits its 5 values from 15 separate `printf` calls.

             The regex must key on the SHAPE of the emitting statement — not on
             the member names, and NOT on a member-name prefix.  A prefix filter
             looks like it keys on shape and does not: `/lease_acquire_[a-z_]+/`
             extracts a 12-member PROJECTION of a 22-member and a 13-member set,
             and a projection of a superset silently agrees with what it
             projects.  Where a site is a genuine superset, take the whole
             container span and declare the extras as `+member` deltas.  Keying
             on quoting style is the same trap in a different costume.

``<delta>``  Zero or more ``-<member>`` / ``+<member>`` tokens declaring that
             this site is deliberately the contract MINUS / PLUS those members.
             The delta is not a convenience, it is required by reality:
             `lib/goal-state.sh`'s resolved-backend allowlist is the dispatch
             enum minus ``auto``, and `lib/run_manifest.py` deliberately
             validates 4 of the 5 terminal events.  A declared delta is visible
             at the edit site and still reds when the BASE changes.  An
             undeclared one is the bug.  Deltas are themselves checked: a
             ``+m`` whose member is absent from the site, or a ``-m`` whose
             member is present, is a stale delta and fails.

WHAT THE HEURISTIC EXTRACTOR ACTUALLY GUARANTEES
================================================
Span mode picks, out of every quoted string / bracketed group / bare
pipe-alternation / Markdown table cell in the region, the one span that yields
the most members and contains NO rejected token.

An earlier edition of this file claimed "there is no span choice that makes two
genuinely different token sets compare equal."  **That claim was false and is
withdrawn.**  An adversarial sweep refuted it twice: a decoy token list in a
trailing comment won the max-members span and hid a member REMOVAL, and a
first-match `@anchor` bound to a decoy line inserted above a byte-locked
declaration.  Both holes are closed below, but the claim was the real defect.

The property that actually holds, stated so it can be checked:

  1. A region containing exactly ONE multi-member vocabulary extracts that
     vocabulary or fails loudly (zero members, or fewer than MIN_MEMBERS).
  2. A region containing TWO different multi-member vocabularies is a hard
     failure — `pick_span` refuses to choose rather than silently preferring the
     larger.  Singletons never compete and cannot win against a real vocabulary.
  3. Given 1 and 2, a mis-extraction that changes the member set cannot be
     silent: the mirror sites disagree and CI reds.

It does NOT guarantee that a marker is attached to the declaration its author
meant — only that whatever it is attached to is extracted honestly and compared.
See the "KNOWN LIMITS" section of docs/rfc/0016-contract-markers.md.

ANTI-VACUITY
============
`tests/component-token-schema.py` is the register's own cautionary tale: a guard
of this shape can sit in CI, look right, and cover nothing.  Therefore:

  * CONTRACTS below is a RATCHET — it names every expected contract and its
    EXACT expected site count.  Deleting a marker shrinks the comparison set,
    which must red rather than quietly pass.  Adding a legitimate new mirror is
    a deliberate one-number edit, in the same spirit as the repo's version-locks.
  * No contract may have fewer than 2 sites; a one-site "contract" needs no
    comparator, so its presence in the registry means someone marked the wrong
    thing.
  * Both trees must be walked and both must contribute sites — the
    `codex/uberdev-codex/**` mirror is a real copy, and a scan that silently
    missed it would be this very bug one level up.
  * Per contract, the set of marked relative paths under `plugins/uberdev/`
    must equal the set under `codex/uberdev-codex/`, so a marker added to one
    tree and forgotten in the other reds.
  * `--selftest` exercises the extractor itself against synthetic fixtures,
    including the negative cases (zero members, stale delta, unknown contract).

Usage::

    python3 -I tests/contract_markers.py [--selftest] [--dump] [REPO_ROOT]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

# --------------------------------------------------------------------------
# Registry — the ratchet.  name -> the EXACT multiset of plugin-tree-relative
# paths expected to declare it.  Both trees must present this same multiset, so
# the expected site count is 2x the list length.
#
# Pinning PATHS, not a bare count, is deliberate: a count-only ratchet lets a
# marker be moved off one file and duplicated onto another (the count and the
# per-tree parity both hold while the abandoned declaration drifts free).
# #370 rank in the comment.
# --------------------------------------------------------------------------
CONTRACTS: dict[str, list[str]] = {
    # rank 6 — lib/dispatch.sh enum + the goal run-state allowlist (enum - auto)
    "dispatch-backend": [
        "lib/dispatch.sh",
        "lib/goal-state.sh",
    ],
    # rank 7 — `claude agents --json` row values that mean "this agent is alive"
    "agent-liveness-value": [
        "lib/agent-dispatch.sh",
        "lib/goal-state.sh",
        "lib/goal-state.sh",
        "lib/goal-state.sh",
    ],
    # rank 8 — terminal `state` a per-run status FILE may legally carry (4)
    "run-terminal-status": [
        "lib/agent-dispatch.sh",
        "lib/agent-dispatch.sh",
        "lib/agent-dispatch.sh",
        "lib/agent-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/run_manifest.py",
    ],
    # rank 9 — the events uberdev_goal_audit accepts (13)
    "goal-audit-event": [
        "lib/goal-state.sh",
        "skills/goal-pipeline/SKILL.md",
    ],
    # rank 10 — merge-pipeline PARK_REASON_ENUM (4)
    "park-reason": [
        "lib/goal-state.sh",
        "skills/merge-pipeline/SKILL.md",
    ],
    # rank 11 — agent-lifecycle terminal EVENT set (5)
    "agent-terminal-event": [
        "lib/agent-dispatch.sh",
        "lib/agent-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/run_manifest.py",
        "lib/status.sh",
    ],
    # rank 12 — live-semaphore lease_acquire_* failure reasons (12)
    "semaphore-lease-acquire-reason": [
        "lib/agent-dispatch.sh",
        "lib/agent-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/live-semaphore.sh",
    ],
    # rank 13 — TRUST_SIGNAL_ENUM (5)
    "trust-signal": [
        "lib/goal-state.sh",
        "lib/goal-watch.sh",
        "skills/goal-pipeline/SKILL.md",
        "skills/goal-pipeline/workflow.js",
    ],
    # NOT in #370's register — found by applying this convention.
    # GOAL_CIRCUIT_BREAKER_REASONS (9) vs the CIRCUIT_BREAKER_HALT run-state
    # allowlist in uberdev_goal_read_run_state (8, missing `solver_failed`).
    # Latent, not live: today only `agent_stuck_on_dialog` is ever assigned to
    # that scalar. The divergence is DECLARED at the site, not laundered.
    "goal-circuit-breaker-reason": [
        "lib/goal-state.sh",
        "skills/goal-pipeline/SKILL.md",
    ],
    # rank 4 — the closed set of risk-signal names (11).  Textually comparable,
    # so it belongs to this mechanism even though #370 files it under Half B;
    # the Half B guard it still needs is a round-trip of solve_triage's
    # RISK_PATTERNS (the producer) through these validators.
    "risk-signal": [
        "lib/agent-dispatch.sh",
        "lib/child-dispatch.sh",
        "lib/child-dispatch.sh",
        "policy/model-routing-v1.json",
    ],
}

# Sites that cannot carry a comment at all.  JSON has no comment syntax, and
# adding a sibling key to a *versioned policy artifact* validated by
# lib/model_routing.py would be a behavioural change to shipped policy — out of
# scope for a marker package.  So the site is declared HERE, by path + key, and
# is COMPARED like any other site rather than skipped.  The extraction is exact
# (json.load + key lookup), not heuristic.
JSON_SITES: dict[str, list[tuple[str, str]]] = {
    "risk-signal": [
        ("plugins/uberdev/policy/model-routing-v1.json", "risk_signals"),
        ("codex/uberdev-codex/policy/model-routing-v1.json", "risk_signals"),
    ],
}

SCAN_ROOTS = ("plugins/uberdev", "codex/uberdev-codex")
MIRROR_PAIR = ("plugins/uberdev", "codex/uberdev-codex")

# A contract with one site needs no comparator.
MIN_SITES = 2
# A "set" of one member is a constant, not a vocabulary; a span that small is
# almost always the extractor having picked the wrong thing.
MIN_MEMBERS = 2

# The walk is a DENYLIST, not an allowlist.  An allowlist of "text" suffixes
# made the scan look exhaustive while silently skipping `.ts`, `.cmd`, `.html`
# and every extension-less executable under `hooks/` and `lib/` — a scan that
# quietly misses a tree is the same bug this file exists to catch, one level up.
# Anything that is not obviously binary is read; a UnicodeDecodeError skips it.
BINARY_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz",
    ".tgz", ".bz2", ".xz", ".woff", ".woff2", ".ttf", ".otf", ".eot", ".mp4",
    ".mp3", ".wav", ".so", ".dylib", ".dll", ".exe", ".pyc", ".class", ".jar",
    ".wasm", ".bin", ".db", ".sqlite",
}
SKIP_DIR_NAMES = {".git", "__pycache__", "node_modules", ".venv", "venv"}
# Guard against reading something pathological; nothing shipped is close.
MAX_SCAN_BYTES = 4 * 1024 * 1024

# --------------------------------------------------------------------------
# Marker grammar
# --------------------------------------------------------------------------
_LEADER = r"(?:\#+|//+|<!--)"
MARKER_RE = re.compile(r"^\s*" + _LEADER + r"\s*CONTRACT:\s*(?P<body>.*?)\s*(?:-->)?\s*$")
CLOSE_RE = re.compile(r"^\s*" + _LEADER + r"\s*/CONTRACT:\s*(?P<name>[A-Za-z0-9][A-Za-z0-9-]*)\s*(?:-->)?\s*$")
NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")

# A member token.  Anything carrying `$`, `(`, `)`, `^`, `*`, `:`, `%`, `\` etc.
# fails this and is a REJECT — which disqualifies its whole span (see
# `pick_span`), because a span containing shell/regex syntax is not a
# vocabulary declaration.
MEMBER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
SPLIT_RE = re.compile(r"[|,\s'\"`]+")

# Delimited spans.  The delimiters are stripped before tokenising: they are not
# separators, so leaving them on would make `{` and `}` rejected fragments and
# disqualify every Python set literal in the repo.
DELIMITED_SPAN_RES = (
    re.compile(r"'[^'\n]*'"),
    re.compile(r'"[^"\n]*"'),
    re.compile(r"`[^`\n]*`"),
    re.compile(r"\[[^\[\]\n]*\]"),
    re.compile(r"\{[^{}\n]*\}"),
)
# A bare pipe-alternation: shell `case` heads and arms, and the inside of an
# anchored jq/regex alternation such as `^(busy|running|starting|working)$`
# (the `^(` and `)$` are outside the character class, so the alternation is
# recovered intact where naive quote-splitting would drop its first and last
# member).
BARE_ALT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*(?:\|[A-Za-z0-9_.-]+)+")
TABLE_ROW_RE = re.compile(r"^\s*\|.*\|\s*$")

# Comment leaders, per language.  Region text is stripped of comments BEFORE any
# span or harvest work: a delimiter-separated decoy in a trailing comment
# ("# keep aligned with a|b|c|d") otherwise wins the max-members span and hides
# a member REMOVAL from the real declaration next to it.
COMMENT_LEADERS = {
    ".sh": ("#",),
    ".bash": ("#",),
    ".zsh": ("#",),
    ".py": ("#",),
    ".js": ("//",),
    ".mjs": ("//",),
    ".cjs": ("//",),
    ".ts": ("//",),
}
HTML_COMMENT_RE = re.compile(r"<!--.*?-->")

# A shell `case` arm head: `completed|failed)`, `"hook-fail")`, `paused)`.
# Quoted arms are legal shell and must tokenise, or a one-character edit hides
# the arm from the guard.
_CASE_ARM_MEMBER = r"['\"]?[A-Za-z0-9][A-Za-z0-9_.-]*['\"]?"
CASE_SCAN_RE = re.compile(
    r"(?P<case>\bcase\b)"
    r"|(?P<esac>\besac\b)"
    r"|(?:^|;;|\bin\b)[ \t]*(?P<arm>" + _CASE_ARM_MEMBER + r"(?:\|" + _CASE_ARM_MEMBER + r")*)\)",
    re.M,
)

BUILTIN_MODES = ("case-arm",)


def strip_comments(text: str, suffix: str) -> str:
    """Blank out comment tails, quote-aware, so a decoy cannot win a span.

    Only the shapes that actually appear in the marked trees are handled: `#`
    for shell/Python/jq, `//` for JavaScript, `<!-- ... -->` for Markdown.  A
    leader only starts a comment at line start or after whitespace, which is the
    real shell rule and keeps `$#`, `${x#y}` and `https://` intact.
    """
    if suffix == ".md":
        return HTML_COMMENT_RE.sub("", text)
    leaders = COMMENT_LEADERS.get(suffix)
    if not leaders:
        return text
    out = []
    for line in text.split("\n"):
        quote = ""
        cut = None
        i = 0
        while i < len(line):
            ch = line[i]
            if quote:
                if ch == "\\" and quote == '"':
                    i += 2
                    continue
                if ch == quote:
                    quote = ""
                i += 1
                continue
            if ch in "'\"`":
                quote = ch
                i += 1
                continue
            if i == 0 or line[i - 1] in " \t":
                if any(line.startswith(lead, i) for lead in leaders):
                    cut = i
                    break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


class ContractError(Exception):
    """A hard, loud failure.  Never downgraded to a skip."""


class Site:
    __slots__ = ("contract", "path", "line", "members", "minus", "plus", "mode")

    def __init__(self, contract, path, line, members, minus=(), plus=(), mode="span"):
        self.contract = contract
        self.path = path
        self.line = line
        self.members = frozenset(members)
        self.minus = frozenset(minus)
        self.plus = frozenset(plus)
        self.mode = mode

    @property
    def normalized(self) -> frozenset:
        """The site's members expressed in the contract's own terms."""
        return (self.members - self.plus) | self.minus

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line}"


def tokenize(text: str) -> tuple[list[str], list[str]]:
    """Split a span into (accepted members, rejected fragments)."""
    raw = [t for t in SPLIT_RE.split(text) if t]
    good, bad = [], []
    for tok in raw:
        (good if MEMBER_RE.fullmatch(tok) else bad).append(tok)
    return good, bad


def candidate_spans(region: str):
    """Yield (start_offset, span_text) for every candidate span in the region."""
    for pattern in DELIMITED_SPAN_RES:
        for match in pattern.finditer(region):
            yield match.start() + 1, match.group(0)[1:-1]
    for match in BARE_ALT_RE.finditer(region):
        yield match.start(), match.group(0)
    # Markdown table cells.  A table row's interesting cell is a comma-separated
    # list of backticked members; its neighbours are a symbol name and prose,
    # and prose reliably carries a rejected token (punctuation), which is what
    # disqualifies it under the zero-reject rule.
    offset = 0
    for line in region.split("\n"):
        if TABLE_ROW_RE.match(line):
            cell_start = offset
            for cell in line.split("|"):
                yield cell_start, cell
                cell_start += len(cell) + 1
        offset += len(line) + 1


def pick_span(region: str, where: str) -> tuple[list[str], str]:
    """Span mode: the zero-reject span yielding the most distinct members.

    Deterministic: max member count, ties broken by earliest offset.

    AMBIGUITY IS A HARD FAILURE.  If a second zero-reject span in the same region
    also carries >= MIN_MEMBERS members and its set differs from the winner's,
    the region declares two competing vocabularies and the extractor has no
    principled way to choose.  Silently taking the larger is exactly how a decoy
    token list hides a member REMOVAL from the real declaration beside it, so the
    ambiguity is reported instead of resolved.  Singleton spans (an individual
    quoted string inside a set literal, `"string"` next to a JS enum array) are
    below MIN_MEMBERS and never compete.
    """
    candidates = []
    for start, text in candidate_spans(region):
        good, bad = tokenize(text)
        if bad or not good:
            continue
        candidates.append((len(set(good)), -start, frozenset(good), text))
    if not candidates:
        return [], ""
    candidates.sort(key=lambda c: (c[0], c[1]), reverse=True)
    winner = candidates[0]
    for count, _neg_start, members, text in candidates[1:]:
        if members == winner[2] or count < MIN_MEMBERS:
            continue
        raise ContractError(
            f"{where}: AMBIGUOUS region — two competing vocabularies. "
            f"Winner {sorted(winner[2])} from {winner[3]!r}; "
            f"rival {sorted(members)} from {text!r}. "
            "Narrow the region, or add an @anchor / a /regex/ that names the "
            "declaration's shape. Refusing to guess."
        )
    return sorted(winner[2]), winner[3]


def harvest(region: str, pattern: str) -> tuple[list[str], str]:
    """Harvest mode: union the tokens of every regex match in the region.

    Every capturing group that participated in the match contributes, so a
    pattern may branch over several statement shapes (`in {...}` vs `== "x"`)
    without the author having to key on the member names.
    """
    try:
        rx = re.compile(pattern, re.M)
    except re.error as exc:  # pragma: no cover - authoring error
        raise ContractError(f"bad marker regex {pattern!r}: {exc}") from exc
    members: set[str] = set()
    hits = 0
    for match in rx.finditer(region):
        hits += 1
        if rx.groups:
            text = " ".join(g for g in match.groups() if g)
        else:
            text = match.group(0)
        good, _bad = tokenize(text or "")
        members.update(good)
    return sorted(members), f"{hits} match(es) of /{pattern}/"


def harvest_case_arms(region: str) -> tuple[list[str], str]:
    """`!case-arm` mode: every arm head of the region's OUTERMOST shell `case`.

    Keys on the statement's shape, never on member names, so adding an arm — the
    single most likely real edit to a shell `case`, and the edit a one-line
    region cannot see — changes the extracted set.  Depth tracking (not
    indentation) excludes a NESTED case's arms: the `stale|missing)` arm of
    goal-watch's trust-signal switch sits AFTER a nested verdict-state case, so
    the region cannot simply stop short of it, and an indentation anchor would
    break on any reindent.
    """
    members: set[str] = set()
    depth = 0
    hits = 0
    for match in CASE_SCAN_RE.finditer(region):
        if match.group("case"):
            depth += 1
        elif match.group("esac"):
            depth -= 1
        elif match.group("arm") and depth == 1:
            hits += 1
            good, _bad = tokenize(match.group("arm"))
            members.update(good)
    return sorted(members), f"{hits} arm head(s) of the outermost case"


def parse_body(body: str, where: str):
    """Parse a marker body into (name, anchor, regex, minus, plus)."""
    toks: list[tuple[str, str]] = []
    i, n = 0, len(body)
    while i < n:
        ch = body[i]
        if ch.isspace():
            i += 1
            continue
        if ch == "/":
            j, buf = i + 1, []
            while j < n:
                if body[j] == "\\" and j + 1 < n:
                    buf.append(body[j])
                    buf.append(body[j + 1])
                    j += 2
                    continue
                if body[j] == "/":
                    break
                buf.append(body[j])
                j += 1
            if j >= n:
                raise ContractError(f"{where}: unterminated /regex/ in marker body {body!r}")
            toks.append(("regex", "".join(buf)))
            i = j + 1
            continue
        if ch == "@" and i + 1 < n and body[i + 1] in "'\"":
            # Quoted anchor: the anchor text may contain spaces, which a
            # bare-word anchor cannot.  Needed wherever the shortest UNIQUE
            # anchor is not a single token — `PARK_REASON_ENUM` alone occurs
            # eight times in merge-pipeline/SKILL.md.
            q = body[i + 1]
            j = body.find(q, i + 2)
            if j < 0:
                raise ContractError(f"{where}: unterminated quoted @anchor in marker body {body!r}")
            toks.append(("anchor", body[i + 2:j]))
            i = j + 1
            continue
        j = i
        while j < n and not body[j].isspace():
            j += 1
        toks.append(("word", body[i:j]))
        i = j

    if not toks or toks[0][0] != "word":
        raise ContractError(f"{where}: marker has no contract name: {body!r}")
    name = toks[0][1]
    if not NAME_RE.fullmatch(name):
        raise ContractError(f"{where}: contract name {name!r} is not kebab-case")

    anchor = None
    pattern = None
    mode = None
    minus: list[str] = []
    plus: list[str] = []
    for kind, value in toks[1:]:
        if kind == "regex":
            if pattern is not None:
                raise ContractError(f"{where}: two /regex/ terms in one marker")
            pattern = value
        elif kind == "anchor":
            if anchor is not None:
                raise ContractError(f"{where}: two @anchor terms in one marker")
            anchor = value
            if not anchor:
                raise ContractError(f"{where}: empty @anchor")
        elif value.startswith("@"):
            if anchor is not None:
                raise ContractError(f"{where}: two @anchor terms in one marker")
            anchor = value[1:]
            if not anchor:
                raise ContractError(f"{where}: empty @anchor")
        elif value.startswith("!") and len(value) > 1:
            if mode is not None:
                raise ContractError(f"{where}: two !mode terms in one marker")
            mode = value[1:]
            if mode not in BUILTIN_MODES:
                raise ContractError(
                    f"{where}: unknown !mode {mode!r} (known: {', '.join(BUILTIN_MODES)})"
                )
        elif value.startswith("-") and len(value) > 1:
            minus.append(value[1:])
        elif value.startswith("+") and len(value) > 1:
            plus.append(value[1:])
        else:
            raise ContractError(
                f"{where}: unparsable marker term {value!r} "
                "(expected @anchor, !mode, /regex/, -member or +member)"
            )
    if pattern is not None and mode is not None:
        raise ContractError(f"{where}: /regex/ and !{mode} are two extraction modes; pick one")
    return name, anchor, pattern, mode, minus, plus


def extract_file(rel: str, text: str, suffix: str | None = None) -> list[Site]:
    """Extract every marked site from one file."""
    if suffix is None:
        suffix = "." + rel.rsplit(".", 1)[1] if "." in rel.rsplit("/", 1)[-1] else ""
    lines = text.split("\n")
    marker_idx = set()
    closes: list[tuple[int, str]] = []
    opens: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        close = CLOSE_RE.match(line)
        if close:
            marker_idx.add(idx)
            closes.append((idx, close.group("name")))
            continue
        marker = MARKER_RE.match(line)
        if marker:
            marker_idx.add(idx)
            opens.append((idx, marker.group("body")))

    # Pair each `/CONTRACT: name` with the NEAREST preceding unclosed marker of
    # that name, bracket-style.  Taking "the first close of this name below me"
    # instead lets an unclosed single-line marker swallow a later sibling's
    # region — which silently widens the region to hundreds of lines.
    close_for: dict[int, int] = {}
    pending: dict[str, int] = {}
    events = sorted(
        [(i, "open", MARKER_RE.match(lines[i]).group("body")) for i, _b in opens]
        + [(i, "close", n) for i, n in closes]
    )
    for idx, kind, payload in events:
        if kind == "open":
            try:
                nm = parse_body(payload, f"{rel}:{idx + 1}")[0]
            except ContractError:
                raise
            pending[nm] = idx
        else:
            opener = pending.pop(payload, None)
            if opener is None:
                raise ContractError(
                    f"{rel}:{idx + 1}: `/CONTRACT: {payload}` closes a region that was never opened"
                )
            close_for[opener] = idx

    sites: list[Site] = []
    for idx, body in opens:
        where = f"{rel}:{idx + 1}"
        name, anchor, pattern, mode, minus, plus = parse_body(body, where)

        if anchor is None:
            # Skip any stacked marker lines: two contracts may share one
            # declaration line (SKILL.md's constants block declares several).
            start = idx + 1
            while start in marker_idx:
                start += 1
        else:
            # The anchor must resolve UNIQUELY.  A first-match scan binds to
            # whichever copy comes first, so inserting a decoy line carrying the
            # canonical set between the marker and a byte-locked declaration
            # silently re-points the marker and lets the real declaration drift.
            hits = [
                probe for probe in range(idx + 1, len(lines))
                if anchor in lines[probe] and probe not in marker_idx
            ]
            if not hits:
                raise ContractError(f"{where}: @anchor {anchor!r} matches no line at or below the marker")
            if len(hits) > 1:
                raise ContractError(
                    f"{where}: @anchor {anchor!r} is AMBIGUOUS — it matches "
                    f"{len(hits)} lines ({', '.join(str(h + 1) for h in hits)}). "
                    "An anchor must identify exactly one declaration; lengthen it "
                    '(a quoted @"..." anchor may contain spaces).'
                )
            start = hits[0]
        if start >= len(lines):
            raise ContractError(f"{where}: marker has no region (end of file)")

        end = start
        if idx in close_for:
            end = close_for[idx] - 1
        if end < start:
            raise ContractError(f"{where}: /CONTRACT: {name} closes before its region opens")

        region = strip_comments(
            "\n".join(lines[i] for i in range(start, end + 1) if i not in marker_idx),
            suffix,
        )

        if mode == "case-arm":
            members, evidence = harvest_case_arms(region)
        elif pattern is None:
            members, evidence = pick_span(region, where)
        else:
            members, evidence = harvest(region, pattern)

        if not members:
            raise ContractError(
                f"{where}: contract {name!r} region (lines {start + 1}..{end + 1}) yielded ZERO members. "
                "The marker points at the wrong line, or the declaration changed shape. "
                "This is a hard failure by design — never a skip."
            )
        if len(members) < MIN_MEMBERS:
            raise ContractError(
                f"{where}: contract {name!r} yielded only {len(members)} member(s) ({members}) "
                f"from {evidence!r}; expected at least {MIN_MEMBERS}. "
                "A one-member span means the extractor picked the wrong thing."
            )
        member_set = set(members)
        for m in plus:
            if m not in member_set:
                raise ContractError(
                    f"{where}: stale delta '+{m}' — the site does NOT declare {m!r} (declares {sorted(member_set)})"
                )
        for m in minus:
            if m in member_set:
                raise ContractError(
                    f"{where}: stale delta '-{m}' — the site DOES declare {m!r}, so it is not excluded here"
                )
        if mode:
            mode_name = f"!{mode}"
        elif pattern:
            mode_name = "harvest"
        else:
            mode_name = "span"
        sites.append(Site(name, rel, start + 1, members, minus, plus, mode_name))
    return sites


def load_json_sites(root: Path, failures: list[str]) -> list[Site]:
    sites: list[Site] = []
    for contract, entries in JSON_SITES.items():
        for rel, key in entries:
            path = root / rel
            if not path.is_file():
                failures.append(f"{rel}: declared JSON site is missing")
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                failures.append(f"{rel}: declared JSON site is unreadable/invalid ({exc})")
                continue
            value = data.get(key) if isinstance(data, dict) else None
            if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                failures.append(f"{rel}: JSON key {key!r} is not a list of strings")
                continue
            if len(value) < MIN_MEMBERS:
                failures.append(f"{rel}: JSON key {key!r} has {len(value)} member(s); expected >= {MIN_MEMBERS}")
                continue
            # Line number of the key, for an operator-usable failure message.
            line = 1
            for idx, text in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
                if f'"{key}"' in text:
                    line = idx
                    break
            sites.append(Site(contract, rel, line, value))
    return sites


def walk(root: Path) -> list[tuple[str, str]]:
    """Return [(relpath, text)] for every readable text file under the scan roots."""
    out: list[tuple[str, str]] = []
    for scan_root in SCAN_ROOTS:
        base = root / scan_root
        if not base.is_dir():
            raise ContractError(f"scan root missing: {scan_root}")
        found = 0
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            if any(part in SKIP_DIR_NAMES for part in path.parts):
                continue
            if path.suffix.lower() in BINARY_SUFFIXES:
                continue
            try:
                if path.stat().st_size > MAX_SCAN_BYTES:
                    continue
            except OSError:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            found += 1
            out.append((path.relative_to(root).as_posix(), text))
        if found == 0:
            raise ContractError(
                f"scan root {scan_root} yielded ZERO readable files — the walk is broken, "
                "and a scan that silently misses a tree is the same bug one level up."
            )
    return out


def report(sites: list[Site], failures: list[str], dump: bool) -> None:
    by_contract: dict[str, list[Site]] = {}
    for site in sites:
        by_contract.setdefault(site.contract, []).append(site)

    for name in sorted(by_contract):
        if name not in CONTRACTS:
            failures.append(
                f"contract {name!r} is marked in the tree but absent from the CONTRACTS registry "
                f"({[s.where for s in by_contract[name]]}). Add it with its exact declaration paths."
            )

    for name, expected_paths in sorted(CONTRACTS.items()):
        found = sorted(by_contract.get(name, []), key=lambda s: (s.path, s.line))
        expected_total = len(expected_paths) * len(MIRROR_PAIR)
        if expected_total < MIN_SITES:
            failures.append(
                f"contract {name!r}: registry declares {expected_total} site(s); a contract needs >= {MIN_SITES}"
            )
        if not found:
            failures.append(f"contract {name!r}: registry expects {expected_total} site(s), found NONE")
            continue
        if len(found) < MIN_SITES:
            failures.append(f"contract {name!r}: only {len(found)} site(s) — no comparator is possible")

        # Path ratchet + mirror parity in one comparison.  A per-tree path
        # MULTISET is pinned, not a bare count: a count-only ratchet passes when
        # a marker is moved off one file and duplicated onto another, which
        # leaves the abandoned declaration uncompared while every counter agrees.
        expected_counter = Counter(expected_paths)
        for tree in MIRROR_PAIR:
            prefix = tree + "/"
            actual = Counter(s.path[len(prefix):] for s in found if s.path.startswith(prefix))
            if actual == expected_counter:
                continue
            missing = expected_counter - actual
            extra = actual - expected_counter
            failures.append(
                f"contract {name!r}: declaration paths under {tree}/ do not match the registry — "
                f"expected but absent: {dict(missing) or '{}'}; "
                f"present but unregistered: {dict(extra) or '{}'}. "
                "A moved or duplicated marker must red, not silently shift which "
                "declaration is compared."
            )

        ref = found[0]
        for site in found[1:]:
            if site.normalized == ref.normalized:
                continue
            missing = sorted(ref.normalized - site.normalized)
            extra = sorted(site.normalized - ref.normalized)
            failures.append(
                f"contract {name!r} DRIFTED between {ref.where} and {site.where}\n"
                f"        {ref.where} has, {site.where} lacks : {missing or '[]'}\n"
                f"        {site.where} has, {ref.where} lacks : {extra or '[]'}\n"
                f"        (declared deltas — {ref.where}: -{sorted(ref.minus)} +{sorted(ref.plus)}; "
                f"{site.where}: -{sorted(site.minus)} +{sorted(site.plus)})"
            )

        if dump:
            print(f"  {name} ({len(found)} sites, {len(ref.normalized)} members): {sorted(ref.normalized)}")
            for site in found:
                delta = ""
                if site.minus or site.plus:
                    delta = " [" + " ".join(sorted(f"-{m}" for m in site.minus) + sorted(f"+{m}" for m in site.plus)) + "]"
                print(f"      {site.where} ({site.mode}){delta}")


# --------------------------------------------------------------------------
# Self-test — the extractor is itself a producer, so it gets its own oracle.
# --------------------------------------------------------------------------
SELFTEST_CASES = [
    (
        "shell scalar alternation",
        ".sh",
        "# CONTRACT: t\nENUM='auto|workflow|codex'\n",
        {"auto", "workflow", "codex"},
    ),
    (
        "shell case head, delta -auto",
        ".sh",
        '# CONTRACT: t -auto\ncase "$v" in workflow|codex) V="$v" ;; esac\n',
        {"auto", "workflow", "codex"},
    ),
    (
        "python set literal",
        ".py",
        '# CONTRACT: t\nif e in {"completed", "failed", "cancelled"}:\n',
        {"completed", "failed", "cancelled"},
    ),
    (
        "anchored jq alternation survives ^( and )$",
        ".sh",
        '# CONTRACT: t\nand ((.status // "") | test("^(busy|running|working)$"))\n',
        {"busy", "running", "working"},
    ),
    (
        "js enum array beats the enclosing object",
        ".js",
        '// CONTRACT: t\nsignal: { type: "string", enum: ["green", "yellow", "red"] },\n',
        {"green", "yellow", "red"},
    ),
    (
        "markdown table cell beats the prose cell",
        ".md",
        "<!-- CONTRACT: t -->\n| `E` | `refused`, `ambiguous`, `push-non-ff` | Phase 3.3 (audit-log `data.reason`) |\n",
        {"refused", "ambiguous", "push-non-ff"},
    ),
    (
        "@anchor skips ahead to the byte-locked line",
        ".md",
        "<!-- CONTRACT: t @E= -->\nfiller line\n```\nE='a|b|c'\n```\n",
        {"a", "b", "c"},
    ),
    (
        "quoted @anchor may contain spaces",
        ".md",
        '<!-- CONTRACT: t @"| `E` |" -->\n| `E` | `a`, `b`, `c` | prose (here) |\n',
        {"a", "b", "c"},
    ),
    (
        "region close + harvest over scattered assignments",
        ".sh",
        "# CONTRACT: t /REASON=([a-z_]+)/\nx REASON=lease_one\nnoise 'unrelated|words'\ny REASON=lease_two\n# /CONTRACT: t\n",
        {"lease_one", "lease_two"},
    ),
    (
        "harvest branches over two statement shapes via alternate groups",
        ".py",
        '# CONTRACT: t /(?:in \\{([^}\\n]*)\\}|== "([^"\\n]*)"):\\n[ \\t]*print\\("live"/\n'
        'if x == "idle":\n    print("blocked", end="")\n'
        'elif x in {"busy", "running"}:\n    print("live", end="")\n'
        'elif x == "paused":\n    print("live", end="")\n'
        "# /CONTRACT: t\n",
        {"busy", "running", "paused"},
    ),
    (
        "harvest capture group + delta +extra",
        ".md",
        "# CONTRACT: t +extra\n| `a`, `b`, `extra` | prose (here) |\n",
        {"a", "b"},
    ),
    (
        "!case-arm sees a NEW arm that a one-line region cannot",
        ".sh",
        '# CONTRACT: t !case-arm\ncase "$e" in\n  a|b) : ;;\n  c) : ;;\n  *) return 1 ;;\nesac\n# /CONTRACT: t\n',
        {"a", "b", "c"},
    ),
    (
        "!case-arm tokenises a QUOTED arm",
        ".sh",
        '# CONTRACT: t !case-arm\ncase "$e" in\n  a|b) : ;;\n  "c-d") : ;;\nesac\n# /CONTRACT: t\n',
        {"a", "b", "c-d"},
    ),
    (
        "!case-arm ignores a NESTED case's arms (depth, not indentation)",
        ".sh",
        '# CONTRACT: t !case-arm\ncase "$e" in\n  a|b)\n    case "$f" in\n      nested1|nested2) : ;;\n    esac\n    ;;\n  c) : ;;\nesac\n# /CONTRACT: t\n',
        {"a", "b", "c"},
    ),
    (
        "trailing comment decoy is stripped before span selection",
        ".sh",
        '# CONTRACT: t\ncase "$e" in a|b|c) ;; esac  # keep aligned with a|b|c|d\n',
        {"a", "b", "c"},
    ),
    (
        "a `#` that is not a comment leader survives stripping",
        ".sh",
        '# CONTRACT: t\nX="${row#*x}"; ENUM=\'a|b|c\'\n',
        {"a", "b", "c"},
    ),
]

SELFTEST_FAILURES = [
    (".sh", "zero-member region fails loudly", "# CONTRACT: t\nnothing_here_at_all\n", "ZERO members"),
    (".sh", "one-member region fails loudly", "# CONTRACT: t\nX='only'\n", "at least"),
    (".sh", "stale +delta fails", "# CONTRACT: t +nope\nX='a|b|c'\n", "stale delta '+nope'"),
    (".sh", "stale -delta fails", "# CONTRACT: t -a\nX='a|b|c'\n", "stale delta '-a'"),
    (".sh", "unparsable term fails", "# CONTRACT: t wat\nX='a|b|c'\n", "unparsable marker term"),
    (".sh", "unresolvable anchor fails", "# CONTRACT: t @nosuchthing\nX='a|b|c'\n", "matches no line"),
    (".sh", "unknown !mode fails", "# CONTRACT: t !nosuchmode\nX='a|b|c'\n", "unknown !mode"),
    (
        ".sh",
        "two extraction modes in one marker fail",
        "# CONTRACT: t !case-arm /x/\nX='a|b|c'\n",
        "pick one",
    ),
    (
        ".md",
        "an @anchor matching twice is AMBIGUOUS, not first-match",
        "<!-- CONTRACT: t @E= -->\nReference: E='a|b|c'\n```\nE='a|b|c|d'\n```\n",
        "AMBIGUOUS",
    ),
    (
        ".sh",
        "two competing vocabularies in one region are AMBIGUOUS",
        "# CONTRACT: t\ncase \"$e\" in a|b|c) ;; esac\nDECOY='a|b|c|d'\n# /CONTRACT: t\n",
        "AMBIGUOUS region",
    ),
    (
        ".sh",
        "commenting out the declaration but keeping the marker fails",
        "# CONTRACT: t\n# ENUM='a|b|c'\n",
        "ZERO members",
    ),
]


def selftest() -> int:
    passed = failed = 0
    for label, suffix, text, expected in SELFTEST_CASES:
        try:
            sites = extract_file("selftest" + suffix, text, suffix)
            got = sites[0].normalized
        except ContractError as exc:
            print(f"  FAIL  selftest: {label} raised {exc}")
            failed += 1
            continue
        if got == expected:
            print(f"  PASS  selftest: {label}")
            passed += 1
        else:
            print(f"  FAIL  selftest: {label} (expected {sorted(expected)}, got {sorted(got)})")
            failed += 1
    for suffix, label, text, fragment in SELFTEST_FAILURES:
        try:
            extract_file("selftest" + suffix, text, suffix)
        except ContractError as exc:
            if fragment in str(exc):
                print(f"  PASS  selftest: {label}")
                passed += 1
            else:
                print(f"  FAIL  selftest: {label} raised the wrong error: {exc}")
                failed += 1
            continue
        print(f"  FAIL  selftest: {label} did NOT raise")
        failed += 1
    print(f"contract-markers selftest: {passed} passed, {failed} failed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Closed-vocabulary drift guard (#370 Half A)")
    parser.add_argument("repo_root", nargs="?", default=None)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--dump", action="store_true", help="print every contract and its sites")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()

    root = Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parent.parent
    failures: list[str] = []
    sites: list[Site] = []
    try:
        for rel, text in walk(root):
            sites.extend(extract_file(rel, text))
        sites.extend(load_json_sites(root, failures))
    except ContractError as exc:
        print(f"  FAIL  {exc}")
        print("contract-markers: 0 passed, 1 failed")
        return 1

    report(sites, failures, args.dump)

    for failure in failures:
        print(f"  FAIL  {failure}")
    if failures:
        print(f"contract-markers: {len(sites)} sites across {len(CONTRACTS)} contracts, {len(failures)} failure(s)")
        return 1
    print(f"  PASS  {len(sites)} sites across {len(CONTRACTS)} contracts agree (both trees walked)")
    print(f"contract-markers: {len(sites)} sites across {len(CONTRACTS)} contracts, 0 failures")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
