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

``/regex/``  OPTIONAL.  Switches the site from *span mode* to *harvest mode*:
             members are the union of every match of the regex in the region
             (group 1 when the pattern has one, else group 0), each match then
             tokenised exactly like a span.  Needed where the declaration is
             SCATTERED rather than a single literal — `lib/live-semaphore.sh`
             assigns its 12 failure reasons across ~20 statements, and
             `uberdev_goal_read_trust_signal` emits its 5 values from 15
             separate `printf` calls.  The regex must key on the *shape* of the
             emitting statement, never on the member names, or the site becomes
             vacuous (it would then only ever agree with itself).

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

WHY A HEURISTIC EXTRACTOR IS SAFE HERE
======================================
Span mode picks, out of every quoted string / bracketed group / bare
pipe-alternation / Markdown table cell in the region, the one span that yields
the most members and contains NO rejected token.  That is a heuristic, and it
is acceptable for exactly one reason: **its failure mode is a failing test, not
a passing one.**  Pick the wrong span at a mirror and that mirror's set will not
equal the canonical's, so the suite reds.  Pick the wrong span at the canonical
and every mirror reds.  There is no span choice that makes two genuinely
different token sets compare equal.

That property is the whole reason the design is safe, so it is protected
explicitly: every site must yield at least MIN_MEMBERS members, and a marker
whose region yields zero is a hard failure, never a skip.

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
from pathlib import Path

# --------------------------------------------------------------------------
# Registry — the ratchet.  name -> exact number of declaration sites expected
# across BOTH trees.  #370 rank in the comment.
# --------------------------------------------------------------------------
CONTRACTS: dict[str, int] = {
    # rank 6 — lib/dispatch.sh enum + the goal run-state allowlist (enum - auto)
    "dispatch-backend": 4,
    # rank 7 — `claude agents --json` row values that mean "this agent is alive"
    "agent-liveness-value": 8,
    # rank 8 — terminal `state` a per-run status FILE may legally carry (4)
    "run-terminal-status": 18,
    # rank 9 — the events uberdev_goal_audit accepts (13)
    "goal-audit-event": 4,
    # rank 10 — merge-pipeline PARK_REASON_ENUM (4)
    "park-reason": 4,
    # rank 11 — agent-lifecycle terminal EVENT set (5)
    "agent-terminal-event": 14,
    # rank 12 — live-semaphore lease_acquire_* failure reasons (12)
    "semaphore-lease-acquire-reason": 8,
    # rank 13 — TRUST_SIGNAL_ENUM (5)
    "trust-signal": 8,
    # NOT in #370's register — found by applying this convention.
    # GOAL_CIRCUIT_BREAKER_REASONS (9) vs the CIRCUIT_BREAKER_HALT run-state
    # allowlist in uberdev_goal_read_run_state (8, missing `solver_failed`).
    # Latent, not live: today only `agent_stuck_on_dialog` is ever assigned to
    # that scalar. The divergence is DECLARED at the site, not laundered.
    "goal-circuit-breaker-reason": 4,
    # rank 4 — the closed set of risk-signal names (11).  Textually comparable,
    # so it belongs to this mechanism even though #370 files it under Half B;
    # the Half B guard it still needs is a round-trip of solve_triage's
    # RISK_PATTERNS (the producer) through these validators.
    "risk-signal": 8,
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

TEXT_SUFFIXES = {".sh", ".py", ".js", ".mjs", ".cjs", ".md", ".json", ".yml", ".yaml", ".toml", ".txt"}
SKIP_DIR_NAMES = {".git", "__pycache__", "node_modules"}

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


def pick_span(region: str) -> tuple[list[str], str]:
    """Span mode: the zero-reject span yielding the most distinct members.

    Deterministic: max member count, ties broken by earliest offset.
    """
    best = None
    for start, text in candidate_spans(region):
        good, bad = tokenize(text)
        if bad or not good:
            continue
        key = (len(set(good)), -start)
        if best is None or key > best[0]:
            best = (key, sorted(set(good)), text)
    if best is None:
        return [], ""
    return best[1], best[2]


def harvest(region: str, pattern: str) -> tuple[list[str], str]:
    """Harvest mode: union the tokens of every regex match in the region."""
    try:
        rx = re.compile(pattern, re.M)
    except re.error as exc:  # pragma: no cover - authoring error
        raise ContractError(f"bad marker regex {pattern!r}: {exc}") from exc
    members: set[str] = set()
    hits = 0
    for match in rx.finditer(region):
        hits += 1
        text = match.group(1) if rx.groups else match.group(0)
        good, _bad = tokenize(text or "")
        members.update(good)
    return sorted(members), f"{hits} match(es) of /{pattern}/"


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
    minus: list[str] = []
    plus: list[str] = []
    for kind, value in toks[1:]:
        if kind == "regex":
            if pattern is not None:
                raise ContractError(f"{where}: two /regex/ terms in one marker")
            pattern = value
        elif value.startswith("@"):
            if anchor is not None:
                raise ContractError(f"{where}: two @anchor terms in one marker")
            anchor = value[1:]
            if not anchor:
                raise ContractError(f"{where}: empty @anchor")
        elif value.startswith("-") and len(value) > 1:
            minus.append(value[1:])
        elif value.startswith("+") and len(value) > 1:
            plus.append(value[1:])
        else:
            raise ContractError(
                f"{where}: unparsable marker term {value!r} "
                "(expected @anchor, /regex/, -member or +member)"
            )
    return name, anchor, pattern, minus, plus


def extract_file(rel: str, text: str) -> list[Site]:
    """Extract every marked site from one file."""
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

    sites: list[Site] = []
    for idx, body in opens:
        where = f"{rel}:{idx + 1}"
        name, anchor, pattern, minus, plus = parse_body(body, where)

        if anchor is None:
            # Skip any stacked marker lines: two contracts may share one
            # declaration line (SKILL.md's constants block declares several).
            start = idx + 1
            while start in marker_idx:
                start += 1
        else:
            start = None
            for probe in range(idx + 1, len(lines)):
                if anchor in lines[probe] and probe not in marker_idx:
                    start = probe
                    break
            if start is None:
                raise ContractError(f"{where}: @anchor {anchor!r} matches no line at or below the marker")
        if start >= len(lines):
            raise ContractError(f"{where}: marker has no region (end of file)")

        end = start
        for close_idx, close_name in closes:
            if close_idx > idx and close_name == name:
                end = close_idx - 1
                break
        if end < start:
            raise ContractError(f"{where}: /CONTRACT: {name} closes before its region opens")

        region = "\n".join(lines[i] for i in range(start, end + 1) if i not in marker_idx)

        if pattern is None:
            members, evidence = pick_span(region)
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
        sites.append(Site(name, rel, start + 1, members, minus, plus, "span" if pattern is None else "harvest"))
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
            if path.suffix not in TEXT_SUFFIXES:
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
                f"({[s.where for s in by_contract[name]]}). Add it with its exact site count."
            )

    for name, expected in sorted(CONTRACTS.items()):
        found = sorted(by_contract.get(name, []), key=lambda s: (s.path, s.line))
        if expected < MIN_SITES:
            failures.append(f"contract {name!r}: registry declares {expected} site(s); a contract needs >= {MIN_SITES}")
        if not found:
            failures.append(f"contract {name!r}: registry expects {expected} site(s), found NONE")
            continue
        if len(found) != expected:
            failures.append(
                f"contract {name!r}: registry expects {expected} site(s), found {len(found)} "
                f"({[s.where for s in found]}). A deleted marker must red, not silently shrink the comparison."
            )
        if len(found) < MIN_SITES:
            failures.append(f"contract {name!r}: only {len(found)} site(s) — no comparator is possible")

        # Mirror parity: the codex tree is a real copy of the plugin tree.
        plugin_rel = sorted(s.path[len(MIRROR_PAIR[0]) + 1:] for s in found if s.path.startswith(MIRROR_PAIR[0] + "/"))
        codex_rel = sorted(s.path[len(MIRROR_PAIR[1]) + 1:] for s in found if s.path.startswith(MIRROR_PAIR[1] + "/"))
        if plugin_rel != codex_rel:
            only_plugin = sorted(set(plugin_rel) - set(codex_rel))
            only_codex = sorted(set(codex_rel) - set(plugin_rel))
            failures.append(
                f"contract {name!r}: marker mirror drift between {MIRROR_PAIR[0]}/ and {MIRROR_PAIR[1]}/ — "
                f"only in plugins: {only_plugin or '[]'}; only in codex: {only_codex or '[]'}"
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
        "# CONTRACT: t\nENUM='auto|workflow|codex'\n",
        {"auto", "workflow", "codex"},
    ),
    (
        "shell case head, delta -auto",
        '# CONTRACT: t -auto\ncase "$v" in workflow|codex) V="$v" ;; esac\n',
        {"auto", "workflow", "codex"},
    ),
    (
        "python set literal",
        '# CONTRACT: t\nif e in {"completed", "failed", "cancelled"}:\n',
        {"completed", "failed", "cancelled"},
    ),
    (
        "anchored jq alternation survives ^( and )$",
        '# CONTRACT: t\nand ((.status // "") | test("^(busy|running|working)$"))\n',
        {"busy", "running", "working"},
    ),
    (
        "js enum array beats the enclosing object",
        '// CONTRACT: t\nsignal: { type: "string", enum: ["green", "yellow", "red"] },\n',
        {"green", "yellow", "red"},
    ),
    (
        "markdown table cell beats the prose cell",
        "<!-- CONTRACT: t -->\n| `E` | `refused`, `ambiguous`, `push-non-ff` | Phase 3.3 (audit-log `data.reason`) |\n",
        {"refused", "ambiguous", "push-non-ff"},
    ),
    (
        "@anchor skips ahead to the byte-locked line",
        "<!-- CONTRACT: t @E= -->\nfiller line\n```\nE='a|b|c'\n```\n",
        {"a", "b", "c"},
    ),
    (
        "region close + harvest over scattered assignments",
        "# CONTRACT: t /lease_acquire_[a-z_]+/\nx=lease_acquire_one\nnoise 'unrelated|words'\ny=lease_acquire_two\n# /CONTRACT: t\n",
        {"lease_acquire_one", "lease_acquire_two"},
    ),
    (
        "harvest capture group + delta +extra",
        "# CONTRACT: t +extra\n| `a`, `b`, `extra` | prose (here) |\n",
        {"a", "b"},
    ),
]

SELFTEST_FAILURES = [
    ("zero-member region fails loudly", "# CONTRACT: t\nnothing_here_at_all\n", "ZERO members"),
    ("one-member region fails loudly", "# CONTRACT: t\nX='only'\n", "at least"),
    ("stale +delta fails", "# CONTRACT: t +nope\nX='a|b|c'\n", "stale delta '+nope'"),
    ("stale -delta fails", "# CONTRACT: t -a\nX='a|b|c'\n", "stale delta '-a'"),
    ("unparsable term fails", "# CONTRACT: t wat\nX='a|b|c'\n", "unparsable marker term"),
    ("unresolvable anchor fails", "# CONTRACT: t @nosuchthing\nX='a|b|c'\n", "matches no line"),
]


def selftest() -> int:
    passed = failed = 0
    for label, text, expected in SELFTEST_CASES:
        try:
            sites = extract_file("selftest", text)
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
    for label, text, fragment in SELFTEST_FAILURES:
        try:
            extract_file("selftest", text)
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
    contracts_ok = len(CONTRACTS) - len({f.split("'")[1] for f in failures if f.startswith("contract '")})
    if failures:
        print(f"contract-markers: {len(sites)} sites across {len(CONTRACTS)} contracts, {len(failures)} failure(s)")
        return 1
    print(f"  PASS  {len(sites)} sites across {contracts_ok} contracts agree (both trees walked)")
    print(f"contract-markers: {len(sites)} sites across {len(CONTRACTS)} contracts, 0 failures")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
