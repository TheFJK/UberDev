#!/usr/bin/env python3
"""tests/schema_property_reads.py — the generic "declared, requested, never read"
guard for the Workflow schema registries (issue #513).

THE CLASS. A `const S = { ... }` registry declares a property, a prompt string
asks the child to return it, and no line of the script ever reads it. The
contract looks enforced, the child spends tokens producing the value, and the
value is dropped on the floor. Seven instances were found by hand across four
subsystems before this guard existed; every one of them was found the same
mechanical way — grep the property name, count the read sites, notice the count
is zero — which is exactly the kind of work a test can do.

WHAT IT DOES. For every `plugins/uberdev/skills/*/workflow.js`:

  1. normalise the source (comments and string interiors blanked, length- and
     line-preserving) so a `.name` inside a prompt string is never mistaken for
     a read;
  2. locate the `const S = {` registry span by brace balance;
  3. harvest every property declared directly inside a `properties: { … }`
     object, with its dotted schema path;
  4. classify each one READ / CARRIED / MARKED / DEAD;
  5. exit non-zero naming every DEAD property that carries no exemption marker.

DECLARED LIMITS — read these before trusting a green run. A guard whose name
promises more than its predicate delivers is the #370 shape, so the gap is
written down rather than left implied.

  * NAME-SCOPED, PER FILE. A property is READ if the token `.<name>` appears
    anywhere outside the registry in the same file. It is not type-aware: a
    `.rc` read off an unrelated object marks every `rc` in that file live. The
    guard therefore under-reports (misses some dead properties) and never
    over-reports a read that does not exist in the file at all.
  * ONE-HOP, FILE-WIDE CARRY. When a schema's result object escapes the script
    (returned, pushed, stored, assigned), every property of that schema is
    exempted wholesale — the reader is in a calling session this script cannot
    see. The escape search is file-wide, so a same-named variable in an
    unrelated function can false-exempt a schema.
  * INVISIBLE READERS. A property read only in `SKILL.md` prose, in an agent
    markdown file, or by the human reading the run log is invisible here and
    reds. That is intended: such a "reader" is documentation, not code.
  * CORPUS. `plugins/uberdev/skills/*/workflow.js` only. `lib/*.py`,
    `skills/*/SKILL.md` and `agents/*.md` are NOT scanned.
  * COVERAGE OF THE ISSUE'S TABLE. Issue #513 cites seven instances. This guard
    covers **2 of the 7**: `solve-fleet` `S.reviewed.blockingFindings` and
    `review-fleet` `S.ciClassify.failureClass`. The other five are out of
    reach — `review-fleet`'s severed note round-trip was a config key outside
    `const S = {` and has since been DELETED outright by #514 rather than
    wired up (its name is now banned tree-wide by that change's own guard, so
    it is deliberately not spelled here), the `S.verify`
    defect is a required-list-versus-prompt inversion rather than an unread
    property, and `lib/run_manifest.py`, `subagent-driven-dev/SKILL.md` and
    `agents/spec-writer.md` are outside the corpus. The class is not killed;
    one mechanical slice of it is now locked.

EXIT CODES.  0 = clean · 1 = findings · 2 = FATAL (bad input, corpus floor
breach, missing anchor, tripwire).

Portable: standard library only, no third-party imports, no `tempfile` (the
scratch-tree convention in tests/test-harness-source-guards.test.sh A4 governs
tests/*.py; this file simply never creates one — the shell wrapper owns
`mktemp -d`). Runs under ubuntu-latest `python3` and Git Bash `python`.
"""

import pathlib
import re
import sys

# ---------------------------------------------------------------------------
# Self-test harness.
#
# The extractor is a producer, and a producer with no oracle is the hole #361
# fell through. Every case below is a fixture the detector must classify
# exactly; `--selftest` runs them all and exits non-zero on the first
# disagreement. The CI wrapper calls it as row S1.
# ---------------------------------------------------------------------------

SELFTEST_CASES = []


def case(name):
    """Register a self-test case. The body returns None on success, or a string
    describing the disagreement on failure."""

    def register(fn):
        SELFTEST_CASES.append((name, fn))
        return fn

    return register


def run_selftest(stream):
    failures = 0
    for name, fn in SELFTEST_CASES:
        try:
            problem = fn()
        except Exception as exc:  # noqa: BLE001 — a raising case is a failing case
            problem = "raised %s: %s" % (type(exc).__name__, exc)
        if problem is None:
            stream.write("  ok    %s\n" % name)
        else:
            stream.write("  FAIL  %s: %s\n" % (name, problem))
            failures += 1
    stream.write("selftest: %d case(s), %d failure(s)\n" % (len(SELFTEST_CASES), failures))
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# The JavaScript normaliser.
#
# WHY NOT REUSE tests/contract_markers.py. That module ships `strip_comments`
# and `mask_strings`, and both are wrong for JavaScript in ways that are live in
# this corpus, not hypothetical:
#
#   * its block-comment pass is a non-greedy `/\*.*?\*/` applied to the WHOLE
#     file before any string awareness. In uberthink-pipeline/workflow.js the
#     `/*` inside the string "/composites/*.yaml" pairs with the `*/` inside a
#     later glob string and the substitution blanks 145 lines of real code.
#   * `mask_strings` carries a shell `case`-arm carve-out that deliberately
#     leaves a quoted string intact when it is followed by `)` or `|`. JS call
#     arguments end in `")` constantly, so dozens of prompt strings survive
#     unmasked — every `.name` inside one becomes a false READ, which is the
#     silent-miss direction.
#
# So this file carries its own single-pass state machine instead. It is
# length-preserving (so byte offsets stay comparable) and newline-preserving (so
# line numbers stay exact), and it emits two views:
#
#   t_code    — comment bodies AND string interiors blanked. This is the view
#               the read predicate and the span/harvest logic run over.
#   t_bracket — comment bodies blanked, string interiors INTACT. This is the
#               view that can still see `ret["prUrl"]`, the computed-read shape.
#
# Template-literal substitutions (`${ … }`) return to CODE state, because real
# reads live inside them. Regex literals are treated as ordinary code; the
# tripwire in `check_tripwires` pins the assumption that no regex literal in the
# corpus contains a quote, `/*` or `//`.
# ---------------------------------------------------------------------------

_CODE, _LINE, _BLOCK, _SQ, _DQ, _TQ = range(6)


def normalise(text):
    """Return (t_code, t_bracket) — see the block comment above."""
    n = len(text)
    out_code = list(text)
    out_bracket = list(text)

    def blank_both(index):
        if text[index] != "\n":
            out_code[index] = " "
            out_bracket[index] = " "

    def blank_code(index):
        if text[index] != "\n":
            out_code[index] = " "

    state = _CODE
    # One entry per open `${` inside a template literal, holding the brace depth
    # reached inside that substitution. A nested template literal pushes its own
    # entry, so `` `a${`b${c}`}d` `` unwinds correctly.
    substitution_depths = []
    index = 0
    while index < n:
        char = text[index]

        if state == _CODE:
            if char == "/" and index + 1 < n and text[index + 1] == "/":
                blank_both(index)
                blank_both(index + 1)
                index += 2
                state = _LINE
                continue
            if char == "/" and index + 1 < n and text[index + 1] == "*":
                blank_both(index)
                blank_both(index + 1)
                index += 2
                state = _BLOCK
                continue
            if char == "'":
                state = _SQ
                index += 1
                continue
            if char == '"':
                state = _DQ
                index += 1
                continue
            if char == "`":
                state = _TQ
                index += 1
                continue
            if substitution_depths:
                if char == "{":
                    substitution_depths[-1] += 1
                elif char == "}":
                    if substitution_depths[-1] == 0:
                        substitution_depths.pop()
                        state = _TQ
                        index += 1
                        continue
                    substitution_depths[-1] -= 1
            index += 1
            continue

        if state == _LINE:
            if char == "\n":
                state = _CODE
                index += 1
                continue
            blank_both(index)
            index += 1
            continue

        if state == _BLOCK:
            if char == "*" and index + 1 < n and text[index + 1] == "/":
                blank_both(index)
                blank_both(index + 1)
                index += 2
                state = _CODE
                continue
            blank_both(index)
            index += 1
            continue

        if state in (_SQ, _DQ):
            closer = "'" if state == _SQ else '"'
            if char == "\\" and index + 1 < n:
                blank_code(index)
                blank_code(index + 1)
                index += 2
                continue
            if char == closer:
                state = _CODE
                index += 1
                continue
            if char == "\n":
                # A single-quoted or double-quoted JS string cannot span a raw
                # newline. Recovering here keeps one malformed line from
                # swallowing the rest of the file.
                state = _CODE
                index += 1
                continue
            blank_code(index)
            index += 1
            continue

        # state == _TQ
        if char == "\\" and index + 1 < n:
            blank_code(index)
            blank_code(index + 1)
            index += 2
            continue
        if char == "`":
            state = _CODE
            index += 1
            continue
        if char == "$" and index + 1 < n and text[index + 1] == "{":
            substitution_depths.append(0)
            state = _CODE
            index += 2
            continue
        blank_code(index)
        index += 1

    return "".join(out_code), "".join(out_bracket)


# ---------------------------------------------------------------------------
# Span, harvest, predicates.
# ---------------------------------------------------------------------------


class Fatal(Exception):
    """A detector assumption broke. Never downgraded to a finding — a guard that
    cannot see its own corpus must not report it clean."""


class Prop(object):
    """One property declared directly inside a `properties: { … }` object."""

    __slots__ = ("name", "path", "line", "raw_line", "top")

    def __init__(self, name, path, line, raw_line):
        self.name = name
        self.path = path
        self.line = line
        self.raw_line = raw_line
        self.top = path.split(".")[0] if path else name

    @property
    def qualified(self):
        return (self.path + "." + self.name) if self.path else self.name


_SPAN_ANCHOR = re.compile(r"^const S = \{", re.M)


def find_span(t_code, label):
    """Return [start, end) of the `const S = { … }` registry, brace-balanced."""
    anchor = _SPAN_ANCHOR.search(t_code)
    if anchor is None:
        raise Fatal(
            "%s: no column-0 `const S = {` schema registry anchor. Either the file "
            "stopped declaring one (drop it from the corpus deliberately) or the "
            "registry was renamed and this guard now covers nothing." % label
        )
    open_index = t_code.index("{", anchor.start())
    depth = 0
    for index in range(open_index, len(t_code)):
        char = t_code[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return (anchor.start(), index + 1)
    raise Fatal("%s: the `const S = {` registry never closes — brace imbalance" % label)


# `ident:` at a key position, or a structural bracket. Strings and comments are
# already blanked in t_code, so a colon inside prose can never reach this.
_HARVEST_TOKEN = re.compile(r"([A-Za-z_$][A-Za-z0-9_$]*)[ \t\r\n]*:|[{}\[\]]")
_OPEN_VALUE = re.compile(r"[ \t\r\n]*true\b")


class _Frame(object):
    __slots__ = ("key", "ident", "open_object")

    def __init__(self, key, ident):
        self.key = key
        self.ident = ident
        self.open_object = False


def harvest(text, t_code, span):
    """Return the list of Prop declared inside the registry span.

    A key is harvested iff its IMMEDIATELY-enclosing brace was introduced by a
    key named `properties`. The dotted path is the frame stack with `properties`
    frames and anonymous frames (array literals, the registry object itself)
    dropped.

    `additionalProperties: true` is decided at each object's OWN depth: the flag
    is attached to the frame whose body literally contains it, so a nested open
    sub-object excludes only its own members. A body-substring test instead
    marks every schema in the file open — measured on
    testers-pipeline/workflow.js, that returns zero properties for the whole
    file, which is a total silent vacuity.
    """
    body = t_code[span[0]:span[1]]
    offset = span[0]
    line_starts = _line_index(text)

    stack = []
    frame_counter = 0
    pending_key = None
    candidates = []  # (name, path, absolute_index, tuple-of-frame-ids)
    # Frames marked open by `additionalProperties: true` at their own depth.
    # Collected during the walk and consumed after it, because the flag may
    # appear either before or after the `properties` block it governs.
    open_frames = set()

    for token in _HARVEST_TOKEN.finditer(body):
        matched = token.group(0)
        ident = token.group(1)
        if ident is not None:
            if stack and stack[-1].key == "properties":
                path = ".".join(
                    frame.key for frame in stack
                    if frame.key is not None and frame.key != "properties"
                )
                candidates.append(
                    (ident, path, offset + token.start(), tuple(f.ident for f in stack))
                )
            if ident == "additionalProperties" and stack:
                if _OPEN_VALUE.match(body, token.end()):
                    stack[-1].open_object = True
            pending_key = ident
            continue
        if matched == "{":
            frame_counter += 1
            stack.append(_Frame(pending_key, frame_counter))
            pending_key = None
            continue
        if matched == "[":
            frame_counter += 1
            stack.append(_Frame(None, frame_counter))
            pending_key = None
            continue
        # `}` or `]`
        if stack:
            frame = stack.pop()
            if frame.open_object:
                open_frames.add(frame.ident)
        pending_key = None

    props = []
    for name, path, index, frame_ids in candidates:
        if any(ident in open_frames for ident in frame_ids):
            continue
        line = _line_of(line_starts, index)
        props.append(Prop(name, path, line, _raw_line(text, line_starts, line)))
    return props


def _line_index(text):
    starts = [0]
    for index, char in enumerate(text):
        if char == "\n":
            starts.append(index + 1)
    return starts


def _line_of(starts, index):
    low, high = 0, len(starts) - 1
    while low < high:
        mid = (low + high + 1) // 2
        if starts[mid] <= index:
            low = mid
        else:
            high = mid - 1
    return low + 1


def _raw_line(text, starts, line):
    start = starts[line - 1]
    end = text.find("\n", start)
    return text[start:] if end == -1 else text[start:end]


def build_remainder(view, span):
    """`view` with the registry span blanked, same length, newlines preserved."""
    body = view[span[0]:span[1]]
    return view[:span[0]] + "".join(" " if c != "\n" else "\n" for c in body) + view[span[1]:]


def is_read(name, remainder_code, remainder_bracket):
    """True iff the property name is read outside the registry.

    Two shapes only: the dotted read `.<name>` in the code view (strings blanked,
    so a prompt asking for `.verdict` is not a read), and the computed read
    `["<name>"]` / `['<name>']` in the bracket view (string interiors intact,
    because that shape lives inside a string literal by construction).
    """
    escaped = re.escape(name)
    if re.search(r"\." + escaped + r"\b", remainder_code):
        return True
    if re.search(r"\[[ \t]*['\"]" + escaped + r"['\"][ \t]*\]", remainder_bracket):
        return True
    return False


# The dispatch calls whose result object a schema describes.
_AWAIT_CALL = re.compile(r"\bawait[ \t\r\n]+(?:agent|parallel)[ \t\r\n]*\(")
_SCHEMA_SITE = re.compile(r"\bschema[ \t\r\n]*:[ \t\r\n]*S\.([A-Za-z_$][A-Za-z0-9_$]*)")
_BINDING_TAIL = re.compile(r"\b(?:const|let|var)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*=[ \t\r\n]*$")


def _paren_extent(text, open_index):
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


_IDENT = r"[A-Za-z_$][A-Za-z0-9_$]*"
# The value must sit in a terminal position — otherwise `const ok = v && v.rc`
# reads as an assignment of `v` when it is an inspection of it.
_TERMINATOR = r"[ \t]*(?=[;,)\]}\n])"
_DECL_KEYWORD_TAIL = re.compile(r"\b(?:const|let|var)[ \t]+$")


def escapes(variable, remainder):
    """True iff `variable` leaves this script in one of exactly FIVE shapes.

    Deliberately exhaustive and deliberately short. `v === null`, `v &&`, `!v`,
    `typeof v` and `if (v)` are INSPECTIONS of the result, not consumers of it,
    and treating an inspection as a reader is precisely how a dead property
    looks alive — it is the defect solve-fleet's `blockingFindings` sits in.
    """
    v = re.escape(variable)
    simple = [
        # 1. returned, or the whole body of an arrow function
        r"\breturn[ \t]+" + v + r"\b(?![.\[])" + _TERMINATOR,
        r"=>[ \t\r\n]*" + v + r"\b(?![.\[])" + _TERMINATOR,
        # 2. accumulated into a collection
        r"\.push\([ \t\r\n]*" + v + r"\b(?![.\[])",
        # 3. stored as an object-literal value (not a property read off it)
        _IDENT + r"[ \t]*:[ \t]*" + v + r"\b(?![.\[])" + _TERMINATOR,
        # 4. wrapped in an array literal (not a computed index `arr[v]`)
        r"(?<![A-Za-z0-9_$\]])\[[ \t\r\n]*" + v + r"[ \t\r\n]*\]",
    ]
    for pattern in simple:
        if re.search(pattern, remainder):
            return True
    # 5. assigned into something that outlives the call. A `const`/`let`/`var`
    #    DECLARATION is not that — it is a rename, and this analysis is one-hop.
    assignment = re.compile(
        r"(?<![A-Za-z0-9_$])" + _IDENT + r"(?:\." + _IDENT + r"|\[[^\]\n]*\])*"
        + r"[ \t]*(?<![=!<>+\-*/%&|^])=(?!=)[ \t]*" + v + r"\b(?![.\[(])" + _TERMINATOR
    )
    for match in assignment.finditer(remainder):
        if _DECL_KEYWORD_TAIL.search(remainder[:match.start()]):
            continue
        return True
    return False


def carried_schema_names(t_code, span):
    """Top-level `S.<name>` keys whose result object escapes this script.

    Binding is by CONTAINING CALL, not by nearest-preceding declaration: the
    schema site is attributed to the innermost `await agent(` / `await parallel(`
    whose paren-balanced extent covers it, and the receiving variable is the
    `const|let|var <v> =` that opens that same statement. A site with no such
    binding is NOT carried — the failure direction is noisy, never silent.
    """
    calls = []
    for match in _AWAIT_CALL.finditer(t_code):
        open_index = t_code.index("(", match.end() - 1)
        calls.append((match.start(), open_index, _paren_extent(t_code, open_index)))

    remainder = build_remainder(t_code, span)
    carried = set()
    for site in _SCHEMA_SITE.finditer(t_code):
        if span[0] <= site.start() < span[1]:
            continue
        containing = [c for c in calls if c[1] <= site.start() < c[2]]
        if not containing:
            continue
        call_start = max(containing, key=lambda c: c[0])[0]
        binding = _BINDING_TAIL.search(t_code[:call_start])
        if binding is None:
            continue
        variable = binding.group(1)
        if escapes(variable, remainder):
            carried.add(site.group(1))
    return carried


# The exemption marker. Token and matcher are kept in SEPARATE variables so the
# definition itself never registers as a marker — the convention the zsh
# tied-parameter guard established.
_MARKER_TOKEN = "schema-prop" "-unread"
_MARKER_RE = re.compile(r"//[ \t]*" + _MARKER_TOKEN + r":[ \t]*(.*?)[ \t]*$")
MARKER_MIN_REASON = 20


def marker_reason(raw_line):
    """The exemption reason on this source line, or None. A reason shorter than
    MARKER_MIN_REASON characters is not an exemption — it is a shrug."""
    match = _MARKER_RE.search(raw_line)
    if match is None:
        return None
    reason = match.group(1).strip()
    if len(reason) < MARKER_MIN_REASON:
        return None
    return reason


def marker_present(raw_line):
    """True iff the line carries the marker token at all, however short its
    reason. Distinguishes 'no marker' from 'a marker whose reason is too thin',
    which must be reported rather than silently ignored."""
    return _MARKER_RE.search(raw_line) is not None


# ---------------------------------------------------------------------------
# Detector-assumption tripwires.
#
# Every one of these is pinned at ZERO against the corpus as it stands today.
# They exist because the read detector is NAME-SHAPED: it looks for `.name` and
# `["name"]` and nothing else. The day a workflow script destructures a result,
# spreads it, or merges it with Object.assign, that detector stops seeing real
# reads and starts inventing dead properties — loudly here rather than silently
# in the verdict.
# ---------------------------------------------------------------------------

_TRIPWIRES = (
    (
        re.compile(r"\b(?:const|let|var)[ \t\r\n]*\{"),
        "destructuring binding",
        "the name-shaped read detector cannot see `const { a } = result` — extend it "
        "(bind each destructured name as a read) before this shape may ship",
    ),
    (
        re.compile(r"\.\.\.[A-Za-z_$]"),
        "spread of an identifier",
        "the name-shaped read detector cannot see `{ ...result }` — extend it before "
        "this shape may ship",
    ),
    (
        re.compile(r"Object\.assign\("),
        "Object.assign merge",
        "the name-shaped read detector cannot see a merged result object — extend it "
        "before this shape may ship",
    ),
)

# A quoted key inside the registry (`"foo": { … }`) would be skipped by the
# bare-identifier harvest and its property would vanish from the ledger.
_QUOTED_KEY = re.compile(r"['\"][ \t]*:")

_REGEX_START_CONTEXT = re.compile(r"(?:[(,=:\[!&|?{;+\-*%~^]|\breturn|\btypeof|\bcase)[ \t]*$")
_REGEX_BANNED = ("'", '"', "`", "/*", "//")


def find_regex_literals(text, t_code):
    """Regex-literal bodies in live code. The normaliser treats a regex literal
    as ordinary code, which is only safe while no literal contains a quote or a
    comment opener; this is what pins that assumption."""
    literals = []
    index = 0
    length = len(text)
    while index < length - 1:
        if text[index] != "/" or t_code[index] != "/":
            index += 1
            continue
        if text[index + 1] in ("/", "*"):
            index += 1
            continue
        # A bounded lookbehind window, not `text[:index]`: the trigger pattern
        # is anchored at its end and can only reach back a token plus spaces, so
        # slicing the whole prefix at every candidate would make this quadratic
        # in file size for no extra reach.
        if not _REGEX_START_CONTEXT.search(text[max(0, index - 64):index]):
            index += 1
            continue
        scan = index + 1
        in_class = False
        body_end = -1
        while scan < length and text[scan] != "\n":
            char = text[scan]
            if char == "\\":
                scan += 2
                continue
            if char == "[":
                in_class = True
            elif char == "]":
                in_class = False
            elif char == "/" and not in_class:
                body_end = scan
                break
            scan += 1
        if body_end == -1:
            index += 1
            continue
        literals.append((index, text[index + 1:body_end]))
        index = body_end + 1
    return literals


def check_tripwires(label, text, t_code, span):
    """Raise Fatal on any breach. These are assumption failures, not findings:
    a detector that cannot see the code it is judging must not report a verdict
    on it."""
    for pattern, what, guidance in _TRIPWIRES:
        match = pattern.search(t_code)
        if match is not None:
            line = _line_of(_line_index(text), match.start())
            raise Fatal(
                "%s:%d: %s is present — %s" % (label, line, what, guidance)
            )
    span_code = t_code[span[0]:span[1]]
    quoted = _QUOTED_KEY.search(span_code)
    if quoted is not None:
        line = _line_of(_line_index(text), span[0] + quoted.start())
        raise Fatal(
            "%s:%d: the registry declares a QUOTED key — the harvest reads bare "
            "identifiers only, so that property would silently vanish from the ledger. "
            "Extend the harvest tokeniser before this shape may ship." % (label, line)
        )
    for start, body in find_regex_literals(text, t_code):
        for banned in _REGEX_BANNED:
            if banned in body:
                line = _line_of(_line_index(text), start)
                raise Fatal(
                    "%s:%d: a regex literal contains %r — the normaliser treats regex "
                    "literals as ordinary code, so this one opens a spurious string or "
                    "comment state and every verdict below it is unsound. Teach the "
                    "normaliser about regex literals before this shape may ship."
                    % (label, line, banned)
                )


# ---------------------------------------------------------------------------
# Per-file analysis.
# ---------------------------------------------------------------------------

READ, CARRIED, MARKED, DEAD = "READ", "CARRIED", "MARKED", "DEAD"


class FileReport(object):
    __slots__ = ("label", "props", "verdicts", "findings", "shadowed", "exempt")

    def __init__(self, label):
        self.label = label
        self.props = []
        self.verdicts = {}
        self.findings = []
        self.shadowed = []
        self.exempt = []


def analyse(label, text):
    """Classify every harvested property in one workflow script."""
    report = FileReport(label)
    t_code, t_bracket = normalise(text)
    span = find_span(t_code, label)
    check_tripwires(label, text, t_code, span)

    props = harvest(text, t_code, span)
    report.props = props
    remainder_code = build_remainder(t_code, span)
    remainder_bracket = build_remainder(t_bracket, span)
    carried = carried_schema_names(t_code, span)

    marked_lines = {}
    for prop in props:
        if is_read(prop.name, remainder_code, remainder_bracket):
            verdict = READ
        elif prop.top in carried:
            verdict = CARRIED
        elif marker_reason(prop.raw_line) is not None:
            verdict = MARKED
        else:
            verdict = DEAD
        report.verdicts[prop.qualified] = verdict
        if marker_present(prop.raw_line):
            marked_lines.setdefault(prop.line, []).append(prop)

    # Honesty row B — a marker on a property that is demonstrably live.
    for prop in props:
        if not marker_present(prop.raw_line):
            continue
        verdict = report.verdicts[prop.qualified]
        if verdict in (READ, CARRIED):
            report.findings.append(
                "%s:%d: %s carries an exemption marker but is %s — the property is live "
                "now; drop the marker." % (label, prop.line, prop.qualified, verdict)
            )
        elif marker_reason(prop.raw_line) is None:
            report.findings.append(
                "%s:%d: %s carries an exemption marker whose reason is shorter than %d "
                "characters — name the consumer or the decision, not a shrug."
                % (label, prop.line, prop.qualified, MARKER_MIN_REASON)
            )

    # Honesty row A — a marker on a line the harvest produced no property from,
    # or produced more than one from (which makes the marker unattributable).
    line_starts = _line_index(text)
    for number in range(1, len(line_starts) + 1):
        raw = _raw_line(text, line_starts, number)
        if not marker_present(raw):
            continue
        owners = marked_lines.get(number, [])
        if not owners:
            report.findings.append(
                "%s:%d: an exemption marker sits on a line the harvest produced no "
                "property from — a marker may not decorate an innocent line."
                % (label, number)
            )
        elif len(owners) > 1:
            report.findings.append(
                "%s:%d: an exemption marker sits on a line declaring %d properties (%s) "
                "— it is unattributable; put one property per line."
                % (label, number, len(owners), ", ".join(p.qualified for p in owners))
            )

    for prop in props:
        if report.verdicts[prop.qualified] == DEAD:
            report.findings.append(
                "%s:%d: %s is declared and never read — wire it, delete it, or mark it "
                "`// %s: <reason>`." % (label, prop.line, prop.qualified, _MARKER_TOKEN)
            )
        elif report.verdicts[prop.qualified] == MARKED:
            report.exempt.append("%s:%s" % (label, prop.qualified))

    by_name = {}
    for prop in props:
        by_name.setdefault(prop.name, set()).add(prop.path)
    report.shadowed = sorted(name for name, paths in by_name.items() if len(paths) > 1)
    return report


# ---------------------------------------------------------------------------
# Corpus. Pinned in Task 14 from a measured `--dump`, never hand-typed.
# ---------------------------------------------------------------------------

CORPUS_GLOB = "plugins/uberdev/skills/*/workflow.js"
CORPUS_MIN_FILES = 6

# Per-file minimum harvested-property counts. A count that DROPS below its floor
# means the harvest stopped seeing a registry it used to see — the vacuity
# failure mode, which a findings-only guard reports as a clean run.
# DERIVED from `--dump`, never hand-typed.
FILE_FLOORS = {
    "plugins/uberdev/skills/goal-pipeline/workflow.js": 23,
    "plugins/uberdev/skills/review-fleet/workflow.js": 49,
    "plugins/uberdev/skills/scan-fleet/workflow.js": 37,
    "plugins/uberdev/skills/solve-fleet/workflow.js": 25,
    "plugins/uberdev/skills/testers-pipeline/workflow.js": 19,
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js": 52,
}

# Exact exempt inventory: every property carrying a marker today. PAIRS, not a
# count — RFC 0016 ratchet 1: a count survives a marker being MOVED to a
# different property, and moving a marker is exactly how an exemption gets
# reused for something it was never argued for.
EXEMPT_LEDGER = [
    "plugins/uberdev/skills/review-fleet/workflow.js:ciClassify.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:ciClassify.failureClass",
    "plugins/uberdev/skills/review-fleet/workflow.js:ciConflict.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:ciFix.conflictCount",
    "plugins/uberdev/skills/review-fleet/workflow.js:ciFix.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:fixer.dispositionPath",
    "plugins/uberdev/skills/review-fleet/workflow.js:fixer.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:lens.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:reviewer.edgeId",
    "plugins/uberdev/skills/review-fleet/workflow.js:verify.edgeId",
    "plugins/uberdev/skills/scan-fleet/workflow.js:aggFixer.mergedCount",
    "plugins/uberdev/skills/scan-fleet/workflow.js:area.areaId",
    "plugins/uberdev/skills/scan-fleet/workflow.js:fixer.areaId",
    "plugins/uberdev/skills/scan-fleet/workflow.js:fixer.commitSha",
    "plugins/uberdev/skills/scan-fleet/workflow.js:fixer.dispositionPath",
    "plugins/uberdev/skills/scan-fleet/workflow.js:global.coveragePath",
    "plugins/uberdev/skills/scan-fleet/workflow.js:global.semgrepPath",
    "plugins/uberdev/skills/scan-fleet/workflow.js:pr.commitCount",
    "plugins/uberdev/skills/scan-fleet/workflow.js:pr.prUrl",
    "plugins/uberdev/skills/solve-fleet/workflow.js:intake.issues.items.contextFile",
    "plugins/uberdev/skills/solve-fleet/workflow.js:research.headline",
    "plugins/uberdev/skills/solve-fleet/workflow.js:reviewed.blockingFindings",
    "plugins/uberdev/skills/solve-fleet/workflow.js:reviewed.headline",
    "plugins/uberdev/skills/solve-fleet/workflow.js:written.headline",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:aggregate.stderrTail",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:monitorDA.rejected",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:monitorDA.scratchPath",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:monitorPrimary.scratchPath",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:monitorPrimary.verifiedAdded",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:persona.findingCount",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:persona.scratchPath",
    "plugins/uberdev/skills/testers-pipeline/workflow.js:report.aggregatePath",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:arbiter.culledCount",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:arbiter.rankedPath",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:falsify.compositeId",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:falsify.lens",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:frameLens.lens",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:mod.gapCount",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:scope.framePath",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:scope.scopeVerdictPath",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:synth.lens",
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js:synth.outDir",
]

# Property names declared in two or more schemas of the same file. A name-scoped
# read detector cannot tell those apart, so the set is pinned: growing it widens
# the blind spot and must be a reviewable diff.
SHADOWED_NAMES = {
    "plugins/uberdev/skills/goal-pipeline/workflow.js": ["note", "rc"],
    "plugins/uberdev/skills/review-fleet/workflow.js": [
        "edgeId", "findingCount", "note", "resultPath", "status", "statusPath",
    ],
    "plugins/uberdev/skills/scan-fleet/workflow.js": [
        "aggregatePath", "areaId", "branch", "outPath", "rc",
    ],
    "plugins/uberdev/skills/solve-fleet/workflow.js": ["headline", "issue", "rc"],
    "plugins/uberdev/skills/testers-pipeline/workflow.js": ["findings", "scratchPath"],
    "plugins/uberdev/skills/uberthink-pipeline/workflow.js": [
        "donors", "islandIndex", "lens", "outPath", "rc", "verdict",
    ],
}


def discover(root):
    """The corpus, as an explicit glob — never a repository-root walk, so a
    scratch checkout under `.claude/worktrees/` or `.worktrees/` can never enter
    it (the #445 class, tests/test-harness-source-guards.test.sh A3)."""
    base = pathlib.Path(root)
    matches = sorted(base.glob(CORPUS_GLOB))
    return [(str(p.relative_to(base)).replace("\\", "/"), p) for p in matches]


def load_sources(root):
    found = discover(root)
    if len(found) < CORPUS_MIN_FILES:
        raise Fatal(
            "corpus floor breach: found %d file(s) matching %s under %s, expected at "
            "least %d. A shrunken corpus is how this guard would pass while covering "
            "nothing." % (len(found), CORPUS_GLOB, root, CORPUS_MIN_FILES)
        )
    sources = []
    for label, path in found:
        try:
            sources.append((label, path.read_text(encoding="utf-8")))
        except OSError as exc:
            raise Fatal("%s: unreadable (%s)" % (label, exc))
    return sources


def scan_sources(sources, floors=None, minimum_files=None):
    """Analyse an explicit (label, text) list. The injection point exists so the
    self-test can drive the FATAL arms in-process, with no scratch tree at all."""
    if floors is None:
        floors = FILE_FLOORS
    if minimum_files is None:
        minimum_files = CORPUS_MIN_FILES
    if len(sources) < minimum_files:
        raise Fatal(
            "corpus floor breach: %d source(s), expected at least %d"
            % (len(sources), minimum_files)
        )
    reports = []
    for label, text in sources:
        report = analyse(label, text)
        floor = floors.get(label)
        if floor is not None and len(report.props) < floor:
            raise Fatal(
                "%s: harvested %d propert(ies), floor is %d. The harvest stopped seeing "
                "declarations it used to see — fix the extractor, or lower the floor "
                "deliberately in the same diff that removes them."
                % (label, len(report.props), floor)
            )
        reports.append(report)
    return reports


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

USAGE = (
    "usage: schema_property_reads.py --selftest\n"
    "       schema_property_reads.py --scan <repo-root>\n"
    "       schema_property_reads.py --dump <repo-root>\n"
    "       schema_property_reads.py --check-pins <repo-root>"
)


def _run_scan(root, stream):
    reports = scan_sources(load_sources(root))
    findings = []
    for report in reports:
        findings.extend(report.findings)
    for line in findings:
        stream.write(line + "\n")
    total = sum(len(r.props) for r in reports)
    stream.write(
        "scanned %d file(s), %d propert(ies), %d finding(s)\n"
        % (len(reports), total, len(findings))
    )
    return 1 if findings else 0


def _run_dump(root, stream):
    reports = scan_sources(load_sources(root))
    stream.write("== per-file property counts ==\n")
    for report in reports:
        counts = {}
        for verdict in report.verdicts.values():
            counts[verdict] = counts.get(verdict, 0) + 1
        stream.write(
            "%s %d  read=%d carried=%d marked=%d dead=%d\n"
            % (
                report.label,
                len(report.props),
                counts.get(READ, 0),
                counts.get(CARRIED, 0),
                counts.get(MARKED, 0),
                counts.get(DEAD, 0),
            )
        )
    stream.write("== exempt inventory ==\n")
    for entry in sorted(entry for report in reports for entry in report.exempt):
        stream.write(entry + "\n")
    stream.write("== shadowed names ==\n")
    for report in reports:
        stream.write("%s %s\n" % (report.label, ",".join(report.shadowed)))
    return 0


def _run_check_pins(root, stream):
    reports = scan_sources(load_sources(root))
    problems = []

    expected_paths = sorted(FILE_FLOORS)
    actual_paths = sorted(r.label for r in reports)
    if expected_paths != actual_paths:
        problems.append(
            "corpus drifted:\n  expected: %s\n  actual:   %s"
            % (", ".join(expected_paths), ", ".join(actual_paths))
        )

    actual_ledger = sorted(entry for report in reports for entry in report.exempt)
    expected_ledger = sorted(EXEMPT_LEDGER)
    if actual_ledger != expected_ledger:
        added = [e for e in actual_ledger if e not in expected_ledger]
        removed = [e for e in expected_ledger if e not in actual_ledger]
        direction = []
        if added:
            direction.append("GREW by %d" % len(added))
        if removed:
            direction.append("SHRANK by %d" % len(removed))
        problems.append(
            "the exempt ledger %s\n  expected %d row(s), actual %d row(s)\n"
            "  added:   %s\n  removed: %s"
            % (
                " and ".join(direction) if direction else "drifted",
                len(expected_ledger),
                len(actual_ledger),
                ", ".join(added) if added else "(none)",
                ", ".join(removed) if removed else "(none)",
            )
        )

    for report in reports:
        expected_shadow = SHADOWED_NAMES.get(report.label)
        if expected_shadow is None:
            continue
        if sorted(expected_shadow) != report.shadowed:
            problems.append(
                "%s shadowed-name set drifted:\n  expected: %s\n  actual:   %s"
                % (report.label, ",".join(sorted(expected_shadow)), ",".join(report.shadowed))
            )

    for line in problems:
        stream.write(line + "\n")
    stream.write("check-pins: %d problem(s)\n" % len(problems))
    return 1 if problems else 0


_MODES = {"--scan": _run_scan, "--dump": _run_dump, "--check-pins": _run_check_pins}


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(USAGE + "\n")
        return 2
    mode = argv[1]
    if mode == "--selftest":
        return run_selftest(sys.stdout)
    if mode not in _MODES:
        sys.stderr.write(USAGE + "\n")
        return 2
    if len(argv) < 3:
        sys.stderr.write("FATAL: %s needs a repository root\n" % mode)
        return 2
    root = argv[2]
    if not pathlib.Path(root).is_dir():
        sys.stderr.write("FATAL: not a directory: %s\n" % root)
        return 2
    try:
        return _MODES[mode](root, sys.stdout)
    except Fatal as exc:
        sys.stderr.write("FATAL: %s\n" % exc)
        return 2


# ---------------------------------------------------------------------------
# Self-test cases — the normaliser (P1a-P1f).
# ---------------------------------------------------------------------------


def _expect(condition, message):
    return None if condition else message


@case("P1a-star-slash-inside-string-opens-no-block-comment")
def _p1a():
    # The shipped shape from uberthink-pipeline/workflow.js: a glob string
    # containing `/*` far above a glob string containing `*/`. A whole-file
    # non-greedy block-comment regex blanks everything between them.
    src = (
        'const a = "/composites/*.yaml";\n'
        'const live = other.artifactPath;\n'
        'const b = "runs/island-*/frame.json";\n'
    )
    t_code, _ = normalise(src)
    return _expect(
        ".artifactPath" in t_code,
        "code between two glob strings was blanked — the block-comment pass is string-blind",
    )


@case("P1b-quote-inside-line-comment-opens-no-string")
def _p1b():
    src = "// don't read this \" quote\nconst live = other.verdict;\n"
    t_code, _ = normalise(src)
    return _expect(
        ".verdict" in t_code and "don't" not in t_code,
        "an apostrophe or quote inside a line comment leaked into string state",
    )


@case("P1c-string-ending-in-close-paren-is-masked")
def _p1c():
    # `mask_strings` in contract_markers.py deliberately spares a quoted string
    # followed by `)`. In JS that is the single commonest shape there is.
    src = 'log("a .verdict b");\n'
    t_code, _ = normalise(src)
    return _expect(
        ".verdict" not in t_code,
        "a string argument ending in `\")` was left unmasked",
    )


@case("P1d-block-comment-blanked-and-lines-preserved")
def _p1d():
    src = "const a = 1;\n/* dead .prop\n   more .prop\n*/\nconst b = other.tail;\n"
    t_code, t_bracket = normalise(src)
    problems = []
    if ".prop" in t_code:
        problems.append("block comment body survived in t_code")
    if ".prop" in t_bracket:
        problems.append("block comment body survived in t_bracket")
    if len(t_code) != len(src) or len(t_bracket) != len(src):
        problems.append("length not preserved")
    if t_code.count("\n") != src.count("\n"):
        problems.append("newline count not preserved")
    if ".tail" not in t_code:
        problems.append("code after the block comment was lost")
    return _expect(not problems, "; ".join(problems))


@case("P1e-bracket-view-keeps-string-interiors")
def _p1e():
    src = 'const u = ret["prUrl"];\n'
    t_code, t_bracket = normalise(src)
    problems = []
    if '["prUrl"]' not in t_bracket:
        problems.append("t_bracket lost the computed-read literal")
    if "prUrl" in t_code:
        problems.append("t_code kept a string interior")
    return _expect(not problems, "; ".join(problems))


@case("P1f-regex-literal-is-ordinary-code")
def _p1f():
    src = 'const s = text.replace(/\\s*\\n\\s*/g, " ");\nconst live = other.headline;\n'
    t_code, _ = normalise(src)
    return _expect(
        ".headline" in t_code and ".replace" in t_code,
        "a regex literal opened a comment or a string state",
    )


@case("P1g-template-substitution-returns-to-code")
def _p1g():
    # Reads genuinely live inside `${ … }`; blanking them would invent DEAD
    # properties, which is the loud-but-wrong direction.
    src = "const s = `path: ${rec.contextFile} end`;\n"
    t_code, _ = normalise(src)
    problems = []
    if ".contextFile" not in t_code:
        problems.append("a read inside a template substitution was blanked")
    if "path:" in t_code:
        problems.append("template literal text survived")
    return _expect(not problems, "; ".join(problems))


@case("P1h-unterminated-quote-recovers-at-eol")
def _p1h():
    src = "const a = 'it;\nconst live = other.branch;\n"
    t_code, _ = normalise(src)
    return _expect(
        ".branch" in t_code,
        "an unterminated single quote swallowed the rest of the file",
    )


# ---------------------------------------------------------------------------
# Self-test cases — span, harvest, predicates (P2-P12b).
# ---------------------------------------------------------------------------


def _analyse(src, label="fixture.js"):
    """Fixture driver. Delegates to the PRODUCTION `analyse` rather than
    reimplementing the classification: a self-test that carries its own copy of
    the logic it is checking can stay green while the shipped path drifts, which
    is the #370 shape this whole guard exists to police."""
    report = analyse(label, src)
    return report.props, report.verdicts


def _names(props):
    return sorted(p.qualified for p in props)


@case("P2a-brace-in-a-masked-string-does-not-close-the-span")
def _p2a():
    src = (
        "const S = {\n"
        '  a: { type: "object", additionalProperties: false, properties: {\n'
        '    weird: { type: "string", description: "a } brace in prose" },\n'
        "    tail: { type: \"string\" },\n"
        "  } },\n"
        "};\n"
        "const x = other.tail;\n"
    )
    props, _ = _analyse(src)
    return _expect(
        _names(props) == ["a.tail", "a.weird"],
        "harvested %r — a `}` inside a string closed the span early" % (_names(props),),
    )


@case("P2b-missing-anchor-is-FATAL-not-a-silent-skip")
def _p2b():
    try:
        find_span("const Schemas = {\n};\n", "fixture.js")
    except Fatal as exc:
        return _expect("fixture.js" in str(exc), "the FATAL does not name the file: %s" % exc)
    return "an unanchored file returned a span instead of raising Fatal"


@case("P2c-nested-items-properties-leaf-gets-the-dotted-path")
def _p2c():
    src = (
        "const S = {\n"
        '  intake: { type: "object", additionalProperties: false, properties: {\n'
        '    issues: { type: "array", items: { type: "object", additionalProperties: false,\n'
        '      properties: { contextFile: { type: "string" } } } },\n'
        "  } },\n"
        "};\n"
    )
    props, _ = _analyse(src)
    return _expect(
        _names(props) == ["intake.issues", "intake.issues.items.contextFile"],
        "harvested %r — expected the dotted nested path" % (_names(props),),
    )


@case("P3-nested-additionalProperties-true-excludes-only-that-sub-object")
def _p3():
    # The shipped shape from testers-pipeline/workflow.js: the `true` sits on a
    # nested `items` object. An implementation that substring-searches the
    # ENCLOSING object's whole body marks the entire registry open and harvests
    # nothing — a silent, total vacuity.
    src = (
        "const S = {\n"
        '  persona: { type: "object", additionalProperties: false, properties: {\n'
        '    scratchPath: { type: "string" },\n'
        '    findings: { type: "array", items: { type: "object", additionalProperties: true,\n'
        '      properties: { location: { type: "string" }, severity: { type: "string" } } } },\n'
        "  } },\n"
        "};\n"
    )
    props, _ = _analyse(src)
    got = _names(props)
    problems = []
    if got != ["persona.findings", "persona.scratchPath"]:
        problems.append("harvested %r" % (got,))
    if "persona.findings.items.location" in got:
        problems.append("the open sub-object's members were not excluded")
    return _expect(not problems, "; ".join(problems))


@case("P4-a-CONTRACT-comment-inside-properties-yields-no-property")
def _p4():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false, properties: {\n'
        "    // CONTRACT: trust-signal v1 — the label vocabulary lives in goal-state.sh\n"
        '    note: { type: "string" },\n'
        "  } },\n"
        "};\n"
        "const x = other.note;\n"
    )
    props, _ = _analyse(src)
    return _expect(
        _names(props) == ["claim.note"],
        "harvested %r — a comment inside a properties block became a property" % (_names(props),),
    )


@case("P5-a-block-commented-key-is-not-harvested")
def _p5():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false, properties: {\n'
        '    live: { type: "string" },\n'
        '    /* retired: { type: "string" }, */\n'
        "  } },\n"
        "};\n"
        "const x = other.live;\n"
    )
    props, _ = _analyse(src)
    return _expect(
        _names(props) == ["claim.live"],
        "harvested %r — a commented-out key was harvested" % (_names(props),),
    )


@case("P6-a-required-list-inside-the-span-is-not-a-read")
def _p6():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        '    required: ["ghost"],\n'
        '    properties: { ghost: { type: "string" } } },\n'
        "};\n"
    )
    _, verdicts = _analyse(src)
    return _expect(
        verdicts.get("claim.ghost") == "DEAD",
        "claim.ghost classified %r — the registry span was not blanked before the read scan"
        % (verdicts.get("claim.ghost"),),
    )


@case("P7-a-prompt-string-mentioning-the-property-is-not-a-read")
def _p7():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        '    properties: { ghost: { type: "string" } } },\n'
        "};\n"
        'const prompt = "Return .ghost as a JSON string; set .ghost to the branch name.";\n'
    )
    _, verdicts = _analyse(src)
    return _expect(
        verdicts.get("claim.ghost") == "DEAD",
        "claim.ghost classified %r — a prompt string counted as a read"
        % (verdicts.get("claim.ghost"),),
    )


@case("P8-dot-and-computed-reads-count-object-literal-keys-do-not")
def _p8():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        "    properties: {\n"
        '      dotted: { type: "string" },\n'
        '      dq: { type: "string" },\n'
        '      sq: { type: "string" },\n'
        '      literalKey: { type: "string" },\n'
        "    } },\n"
        "};\n"
        "const a = ret.dotted;\n"
        'const b = ret["dq"];\n'
        "const c = ret['sq'];\n"
        'const d = { literalKey: "" };\n'
    )
    _, verdicts = _analyse(src)
    problems = []
    for name in ("claim.dotted", "claim.dq", "claim.sq"):
        if verdicts.get(name) != "READ":
            problems.append("%s classified %r" % (name, verdicts.get(name)))
    if verdicts.get("claim.literalKey") != "DEAD":
        problems.append("claim.literalKey classified %r" % (verdicts.get("claim.literalKey"),))
    return _expect(not problems, "; ".join(problems))


_CARRY_PRELUDE = (
    "const S = {\n"
    '  x: { type: "object", additionalProperties: false,\n'
    '    properties: { ghost: { type: "string" } } },\n'
    "};\n"
)


def _carry_verdict(escape_line):
    src = _CARRY_PRELUDE + "const v = await agent(p, { schema: S.x });\n" + escape_line
    _, verdicts = _analyse(src)
    return verdicts.get("x.ghost")


@case("P9-all-five-escape-shapes-carry")
def _p9():
    shapes = [
        ("return", "return v;\n"),
        ("arrow", "const f = () => v;\n"),
        ("push", "acc.push(v);\n"),
        ("object-value", "emit({ result: v });\n"),
        ("array-literal", "emit([v]);\n"),
        ("assignment", "store.slot = v;\n"),
    ]
    problems = []
    for label, line in shapes:
        got = _carry_verdict(line)
        if got != "CARRIED":
            problems.append("%s -> %r" % (label, got))
    return _expect(not problems, "escape shapes not recognised: " + "; ".join(problems))


@case("P10-inspection-only-uses-do-not-carry")
def _p10():
    shapes = [
        ("null-compare", "if (v === null) fail();\n"),
        ("truthy-and", "const ok = v && v.rc;\n"),
        ("negation", "if (!v) fail();\n"),
        ("typeof", "if (typeof v === 'object') fail();\n"),
        ("if-guard", "if (v) fail();\n"),
    ]
    problems = []
    for label, line in shapes:
        got = _carry_verdict(line)
        if got != "DEAD":
            problems.append("%s -> %r" % (label, got))
    return _expect(not problems, "inspection shapes falsely carried: " + "; ".join(problems))


@case("P12-shipped-shape-review-object-inspected-but-never-escaping")
def _p12():
    src = (
        "const S = {\n"
        '  reviewed: { type: "object", additionalProperties: false,\n'
        "    properties: {\n"
        '      verdict: { type: "string" },\n'
        '      blockingFindings: { type: "array", items: { type: "string" } },\n'
        "    } },\n"
        "};\n"
        "const review = await agent(specReviewPrompt(n), { schema: S.reviewed });\n"
        'if (review === null) noteNull("design");\n'
        'const verdict = (review && review.verdict) ? review.verdict : "APPROVE";\n'
    )
    _, verdicts = _analyse(src)
    problems = []
    if verdicts.get("reviewed.verdict") != "READ":
        problems.append("reviewed.verdict -> %r" % (verdicts.get("reviewed.verdict"),))
    if verdicts.get("reviewed.blockingFindings") != "DEAD":
        problems.append(
            "reviewed.blockingFindings -> %r" % (verdicts.get("reviewed.blockingFindings"),)
        )
    return _expect(not problems, "; ".join(problems))


@case("P12b-binding-is-by-containing-call-not-nearest-preceding")
def _p12b():
    # Two sequential dispatches; only the SECOND result escapes. A "nearest
    # preceding declaration" binder attributes both schemas to `b` and exempts
    # S.x wholesale.
    src = (
        "const S = {\n"
        '  x: { type: "object", additionalProperties: false,\n'
        '    properties: { ghost: { type: "string" } } },\n'
        '  y: { type: "object", additionalProperties: false,\n'
        '    properties: { shade: { type: "string" } } },\n'
        "};\n"
        "const a = await agent(p1, { schema: S.x });\n"
        "const b = await agent(p2, { schema: S.y });\n"
        "return b;\n"
    )
    _, verdicts = _analyse(src)
    problems = []
    if verdicts.get("x.ghost") != "DEAD":
        problems.append("x.ghost -> %r (S.x must NOT be carried)" % (verdicts.get("x.ghost"),))
    if verdicts.get("y.shade") != "CARRIED":
        problems.append("y.shade -> %r" % (verdicts.get("y.shade"),))
    return _expect(not problems, "; ".join(problems))


@case("P12c-a-schema-inside-a-parallel-call-binds-to-the-parallel-result")
def _p12c():
    src = (
        "const S = {\n"
        '  r: { type: "object", additionalProperties: false,\n'
        '    properties: { ghost: { type: "string" } } },\n'
        "};\n"
        "const researched = await parallel(lenses.map(function (lens) {\n"
        "  return function () {\n"
        "    return agent(researchPrompt(lens), { phase: \"research\", schema: S.r });\n"
        "  };\n"
        "}));\n"
        "log(researched.length);\n"
    )
    _, verdicts = _analyse(src)
    return _expect(
        verdicts.get("r.ghost") == "DEAD",
        "r.ghost -> %r — the inner `return agent(...)` must not count as an escape "
        "of the parallel result" % (verdicts.get("r.ghost"),),
    )


# ---------------------------------------------------------------------------
# Self-test cases — markers and the two honesty rows (P11).
# ---------------------------------------------------------------------------

_MARKER = "// " + _MARKER_TOKEN + ": "
_GOOD_REASON = "the caller reads it from the run log, not from this script"


def _marker_fixture(prop_line, extra=""):
    return (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        "    properties: {\n"
        "      " + prop_line + "\n"
        "    } },\n"
        "};\n"
    ) + extra


@case("P11a-a-reason-shorter-than-the-floor-is-not-an-exemption")
def _p11a():
    problems = []
    long_reason = _marker_fixture('ghost: { type: "string" }, ' + _MARKER + _GOOD_REASON)
    if analyse("fx.js", long_reason).findings:
        problems.append("a well-reasoned marker was rejected")
    short_reason = _marker_fixture('ghost: { type: "string" }, ' + _MARKER + "later")
    findings = analyse("fx.js", short_reason).findings
    if not any("shorter than" in f for f in findings):
        problems.append("a five-character reason was accepted: %r" % (findings,))
    empty_reason = _marker_fixture('ghost: { type: "string" }, // ' + _MARKER_TOKEN + ":")
    if not any("shorter than" in f for f in analyse("fx.js", empty_reason).findings):
        problems.append("an empty reason was accepted")
    return _expect(not problems, "; ".join(problems))


@case("P11b-honesty-A-a-marker-on-a-non-harvested-line-reds")
def _p11b():
    src = _marker_fixture(
        'ghost: { type: "string" }, ' + _MARKER + _GOOD_REASON,
        extra="const unrelated = 1; " + _MARKER + _GOOD_REASON + "\n",
    )
    findings = analyse("fx.js", src).findings
    return _expect(
        any("produced no property from" in f and ":7:" in f for f in findings),
        "a marker decorating an innocent line was accepted: %r" % (findings,),
    )


@case("P11c-honesty-B-a-marker-on-a-live-property-reds")
def _p11c():
    src = _marker_fixture(
        'ghost: { type: "string" }, ' + _MARKER + _GOOD_REASON,
        extra="const a = ret.ghost;\n",
    )
    findings = analyse("fx.js", src).findings
    return _expect(
        any("is live now" in f and "READ" in f for f in findings),
        "a marker on a READ property was accepted: %r" % (findings,),
    )


@case("P11d-honesty-B-fires-on-a-CARRIED-property-too")
def _p11d():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        "    properties: {\n"
        '      ghost: { type: "string" }, ' + _MARKER + _GOOD_REASON + "\n"
        "    } },\n"
        "};\n"
        "const v = await agent(p, { schema: S.claim });\n"
        "return v;\n"
    )
    findings = analyse("fx.js", src).findings
    return _expect(
        any("is live now" in f and "CARRIED" in f for f in findings),
        "a marker on a CARRIED property was accepted: %r" % (findings,),
    )


@case("P11e-an-unmarked-dead-property-reds-and-names-its-line")
def _p11e():
    src = _marker_fixture('ghost: { type: "string" },')
    findings = analyse("fx.js", src).findings
    return _expect(
        len(findings) == 1 and "fx.js:4: claim.ghost is declared and never read" in findings[0],
        "expected exactly one located finding, got %r" % (findings,),
    )


# ---------------------------------------------------------------------------
# Self-test cases — detector-assumption tripwires (P13).
# ---------------------------------------------------------------------------


def _tripwire_message(extra):
    src = _marker_fixture('ghost: { type: "string" },', extra=extra)
    try:
        analyse("fx.js", src)
    except Fatal as exc:
        return str(exc)
    return None


@case("P13a-destructuring-reds-with-the-extend-the-detector-message")
def _p13a():
    message = _tripwire_message("const { a } = ret;\n")
    return _expect(
        message is not None and "destructuring" in message and "extend it" in message,
        "destructuring did not trip the tripwire: %r" % (message,),
    )


@case("P13b-spread-and-Object-assign-red")
def _p13b():
    problems = []
    spread = _tripwire_message("emit({ ...ret });\n")
    if spread is None or "spread" not in spread:
        problems.append("spread -> %r" % (spread,))
    assign = _tripwire_message("Object.assign(target, ret);\n")
    if assign is None or "assign" not in assign.lower():
        problems.append("Object.assign -> %r" % (assign,))
    return _expect(not problems, "; ".join(problems))


@case("P13c-a-regex-literal-containing-a-quote-reds")
def _p13c():
    message = _tripwire_message('const bad = text.split(/["]/);\n')
    return _expect(
        message is not None and "regex literal" in message,
        "a quote-bearing regex literal did not trip the tripwire: %r" % (message,),
    )


@case("P13d-a-clean-regex-literal-does-not-red")
def _p13d():
    message = _tripwire_message('const s = text.replace(/\\s*\\n\\s*/g, " ");\n')
    return _expect(message is None, "a clean regex literal tripped the tripwire: %r" % (message,))


@case("P13e-a-quoted-registry-key-reds")
def _p13e():
    src = (
        "const S = {\n"
        '  claim: { type: "object", additionalProperties: false,\n'
        '    properties: { "ghost": { type: "string" } } },\n'
        "};\n"
    )
    try:
        analyse("fx.js", src)
    except Fatal as exc:
        return _expect("QUOTED key" in str(exc), "wrong FATAL: %s" % exc)
    return "a quoted registry key was silently skipped"


# ---------------------------------------------------------------------------
# Self-test cases — corpus FATAL arms and the shadowed-name inventory.
#
# Driven through the `scan_sources` injection point: entirely in-process, with
# no scratch tree at all, so nothing here can leave residue under tests/ (the
# convention tests/test-harness-source-guards.test.sh A4 governs).
# ---------------------------------------------------------------------------

_MINIMAL = (
    "const S = {\n"
    '  claim: { type: "object", additionalProperties: false,\n'
    '    properties: { ghost: { type: "string" } } },\n'
    "};\n"
    "const a = ret.ghost;\n"
)


@case("P14a-a-shrunken-corpus-is-FATAL")
def _p14a():
    try:
        scan_sources([("a.js", _MINIMAL)], floors={}, minimum_files=6)
    except Fatal as exc:
        return _expect("corpus floor breach" in str(exc), "wrong FATAL: %s" % exc)
    return "a one-file corpus was accepted where six were required"


@case("P14b-a-missing-registry-anchor-is-FATAL")
def _p14b():
    try:
        scan_sources([("a.js", "const Schemas = {};\n")], floors={}, minimum_files=1)
    except Fatal as exc:
        return _expect("anchor" in str(exc) and "a.js" in str(exc), "wrong FATAL: %s" % exc)
    return "a file with no registry anchor was silently skipped"


@case("P14c-a-property-count-below-its-floor-is-FATAL")
def _p14c():
    try:
        scan_sources([("a.js", _MINIMAL)], floors={"a.js": 2}, minimum_files=1)
    except Fatal as exc:
        return _expect("floor is 2" in str(exc), "wrong FATAL: %s" % exc)
    return "a harvest below its pinned floor was accepted"


@case("P14d-a-corpus-at-its-floor-is-accepted")
def _p14d():
    reports = scan_sources([("a.js", _MINIMAL)], floors={"a.js": 1}, minimum_files=1)
    return _expect(
        len(reports) == 1 and not reports[0].findings,
        "a clean at-floor corpus was rejected: %r" % ([r.findings for r in reports],),
    )


@case("P15-shadowed-names-are-those-declared-in-two-or-more-schemas")
def _p15():
    src = (
        "const S = {\n"
        '  one: { type: "object", additionalProperties: false,\n'
        '    properties: { rc: { type: "integer" }, only: { type: "string" } } },\n'
        '  two: { type: "object", additionalProperties: false,\n'
        '    properties: { rc: { type: "integer" } } },\n'
        "};\n"
        "const a = ret.rc + ret.only;\n"
    )
    report = analyse("fx.js", src)
    return _expect(
        report.shadowed == ["rc"],
        "shadowed set was %r, expected ['rc']" % (report.shadowed,),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
