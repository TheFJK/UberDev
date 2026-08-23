#!/usr/bin/env python3
"""premerge-findings.py -- the triage half of /uberdev:premerge (RFC 0021).

WHY THIS FILE EXISTS. `/premerge` Phase 1 runs the BUILT-IN `code-review` skill,
which is not an uberdev component and whose output contract this repo does not
own. That contract has two shapes in the wild and NEITHER carries a severity:

  fork contract           [{file,line,summary,failure_scenario}]        (4 keys)
  ReportFindings contract [{file,line,summary,short_summary,
                            failure_scenario,category,verdict}]         (7 keys)

Which one arrives depends on `CLAUDE_CODE_REPORT_FINDINGS` and on the resolved
model x level cell, and `/premerge` cannot set either. So the pipeline must read
both, and must derive the blocker-vs-suggestion split that the rest of uberdev
(`agents/code-fixer.md`, `agents/findings-to-issues.md`) is built around.

WHY THE CONTROLLER ASSIGNS THE SEVERITY AND THIS FILE ONLY CHECKS IT. On the
4-key contract there is nothing mechanical to derive a severity FROM -- only the
prose of `summary` and `failure_scenario`. A regex over prose would be a
confident-looking guess, which is worse than an honest judgement, so the
judgement is the controller's and it is written down in
`skills/premerge-pipeline/SKILL.md` (`## The severity rule`).

But a judgement nobody can contradict is a judgement that drifts. So: whenever
the finding DOES carry a `category`, the category is authoritative and a
controller severity that disagrees with it is a hard failure, not a warning.
That is the whole anti-drift design -- the free-judgement path exists only where
no machine-checkable signal exists, and it collapses to the checked path the
moment one appears.

NO NETWORK, NO GIT, NO GH. Reads JSON documents, writes artifacts, decides.
Every failure exits non-zero with a stable token on stderr; nothing here has a
degraded path that yields an empty finding set, because "zero findings" and
"the parse failed" must never be the same observable outcome.

FOUR VERBS.

  plan          classify one review pass, plan its fix waves, write that
                attempt's evidence
  assert-green  the clean gate the simplify phase is allowed through
  converge      decide whether the fix loop takes another attempt, and record
                why -- see `CONVERGE_DECISIONS`
  defer         encode everything the run could not fix, for issue filing --
                the only verb that may put a `blocker` in the envelope

READ THE TOKEN, NOT THE EXIT STATUS, when you need to know WHICH outcome you
got. Exit status answers one question per verb and no more:

  plan          0 planned          | 74 refused
  assert-green  0 green            |  1 not green | 74 refused
  converge      0 loop again       |  1 stop  | 74 refused
  defer         0 encoded          | 74 refused

`converge` exiting 1 is the NORMAL end of a successful run -- STOP_GREEN is a
stop. A caller that reads a non-zero status as failure will report every
converged stack as a broken one. Branch on `DECISION=` on stdout.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import posixpath
import re
import sys
import tempfile

SCHEMA_VERSION = 1

# The envelope source `/premerge` publishes its deferred findings under.
# Registered in `lib/report_primitives.py` ACCEPTED_SOURCES and in the closed
# set at `agents/findings-to-issues.md` Step 1; a cross-consistency row in
# tests/premerge.test.sh asserts the three agree.
AGGREGATE_SOURCE = "premerge-aggregate"

# WHO RAISED A ROW -- the only attribution `agents/findings-to-issues.md` is
# allowed to read.
#
# Its Step 5 derives the issue body's `**Agent:**` and `**Also flagged by:**`
# lines, and the display `agent_name`, from `source_edges`; its Step-1 rules
# state outright that `summary` and `detail` are "context-only prose and never
# path, phase, contributor, or operation authority". So an edge is not decoration
# -- it is the row's identity of origin, and stamping every row with the built-in
# reviewer's edge made a filed issue claim the code-review pass had raised a
# Reuse/Quality/Efficiency refactor suggestion it never saw.
#
# One edge per producer, and `_encode_aggregate` publishes exactly the
# contributors its rows actually cite.
REVIEW_SOURCE_EDGE = "premerge.review.code_review"
SIMPLIFY_SOURCE_EDGE_PREFIX = "premerge.simplify."
# A lens row whose `lens` field is absent or unusable. Still a simplify edge:
# "we do not know which lens" must never collapse back onto "the code reviewer".
SIMPLIFY_SOURCE_EDGE_FALLBACK = SIMPLIFY_SOURCE_EDGE_PREFIX + "unattributed"

# The cleanup half of the built-in reviewer's own angle vocabulary. Its prompt
# states the precedence this set encodes, verbatim: "Correctness bugs always
# outrank cleanup, altitude, and conventions findings when the output cap forces
# a cut." So the mapping below is not an uberdev invention layered on top -- it
# is that sentence, made executable.
#
# Membership, not exhaustiveness, is what this set claims. A slug the reviewer
# invents that is NOT listed here DERIVES as correctness-class (blocker), and
# `_normalise_findings` then refuses any controller severity that disagrees.
#
# SO SAY WHAT THAT ACTUALLY COSTS. It is not "one needless fixer dispatch" -- a
# dispatch only happens when the controller also called the finding a blocker.
# The likely case is the opposite one: the controller applies `## The severity
# rule` correctly, writes `severity: suggestion` for a cleanup finding filed
# under a slug this set has never heard of (`maintainability`, `cleanup`,
# `dead-code`), and the derived `blocker` contradicts it. That is
# `severity_contradicts_category`, exit 74, `plan` writing nothing, and -- per
# SKILL.md `## Phase 2 — TRIAGE`, "a refused `plan` is a hard stop for the
# attempt" -- the whole attempt dying because the reviewer used a synonym.
#
# The asymmetry itself is still right, and still the fail-loud direction: a novel
# correctness slug silently demoted to `suggestion` would ship the bug, and a
# refusal is at least visible. What keeps it cheap is KEEPING THIS SET CURRENT,
# not an assumption that the reviewer only ever emits the slugs listed below.
CLEANUP_CATEGORIES = frozenset(
    {
        "reuse",
        "simplification",
        "simplify",
        "efficiency",
        "performance",
        "altitude",
        "conventions",
        "convention",
        "style",
        "documentation",
        "docs",
        "test-coverage",
        "tests",
        "naming",
        "readability",
    }
)

SEVERITIES = frozenset({"blocker", "suggestion"})
VERDICTS = frozenset({"CONFIRMED", "PLAUSIBLE"})
LEVELS = frozenset({"low", "medium", "high", "xhigh", "max"})

# ---------------------------------------------------------------------------
# the convergence loop's closed decision vocabulary
# ---------------------------------------------------------------------------
# WHY A LOOP AT ALL, WHEN RFC 0021 REFUSED ONE. The original refusal was right
# about the hazard and wrong about the remedy. Its words: "the third automatic
# attempt is where a fixer starts 'fixing' the test instead of the code." What
# actually prevents that is not a small counter -- it is noticing that fixing has
# STOPPED WORKING. A counter set to 1 also stops a loop that was converging
# perfectly well, and leaves the stack parked with a live blocker in it.
#
# So the counter survives as a runaway backstop and the real stop condition is
# evidence-based: STOP_NO_PROGRESS when an attempt changed nothing, and
# STOP_REGRESSED when our own fixes made it worse. Both are computed from
# fingerprints, not from prose.
#
# CLOSED SET. Every member is emitted by `cmd_converge` and read by the
# `## Phase 3b — CONVERGE` decision table in skills/premerge-pipeline/SKILL.md;
# tests/premerge-findings.test.sh compares the two by EXECUTING this module
# rather than transcribing it.
CONVERGE_DECISIONS = (
    "CONTINUE",         # something is still fixable and something changed last time
    "WAIT_CI",          # the only complaint is a build that has not answered yet
    "STOP_GREEN",       # the gate passed -- the loop's whole purpose
    "STOP_NO_PROGRESS",  # an attempt changed neither the blockers nor the CI reason
    "STOP_REGRESSED",   # our own fixes grew the blocker set
    "STOP_EXHAUSTED",   # the runaway backstop
    "STOP_UNREADABLE",  # evidence we could not read -- never reported as green
)
CONVERGE_CONTINUE = frozenset({"CONTINUE", "WAIT_CI"})

# The runaway backstops.
#
# The budget counts REPAIRS, not reviews, and the difference is not cosmetic.
# An attempt is one review+gate; a repair is what happens when that gate says
# not green. So N repairs always cost N+1 reviews -- the last review exists to
# verify the last repair, and nothing this loop writes ever ships ungated.
# Counting reviews instead would make `--converge=1` mean "gate once and stop",
# i.e. zero repairs: strictly worse than the pipeline this loop replaced, under
# a flag documented as reproducing it.
CONVERGE_REPAIR_CEILING = 6
CONVERGE_WAIT_CI_CEILING = 8

# `plan` and `defer` legally run ONE ATTEMPT PAST the loop's last attempt.
#
# `converge` stops at `CONVERGE_REPAIR_CEILING + 1`, because that review is the
# one verifying the final repair. But the loop is not the last thing that
# triages: SKILL.md `### 4c — VERIFY` runs a full review -> triage -> gate cycle
# at `PREMERGE_ATTEMPT + 1` after the simplify commit, deliberately NOT routed
# through `converge` (the repair budget may already be spent, and `converge`
# would refuse). `PREMERGE_ATTEMPT` then stays advanced, so Phase 5's `defer`
# fence runs at that index too.
#
# So a `--converge=6` run that converges on its last legal attempt (7) triages
# and defers at 8. Capping these two verbs at the loop's ceiling refused both:
# the re-stamp 4c calls "fatal to skip" never happened, and `defer --attempt 8`
# then exited 74 behind `|| exit 74`, filing NO issues at all -- the
# surviving-findings guarantee dying on the one run that used the whole budget.
#
# `converge` keeps the tighter bound. This one is only for the verbs 4c and
# Phase 5 reach after the loop has ended.
CONVERGE_VERIFY_CEILING = CONVERGE_REPAIR_CEILING + 2

# The closed set of gate terms this loop knows how to route.
#
# `cmd_assert_green` is not the only producer of a `--reasons` value. The Phase 3
# gate fence (SKILL.md `## Phase 3 — CLEAN GATE`) maps a non-verdict exit -- 74,
# unreadable or malformed evidence -- onto its own fail-closed
# `reasons=gate_unreadable`, and any future fence may invent another term. A term
# with no entry here used to fall through to CONTINUE: with no blockers there are
# no fix waves, the commit fence reports `no-edits`, and the loop re-reviews until
# reasons and fingerprints repeat and it reports STOP_NO_PROGRESS -- "the fixers
# are stuck, a human should look" about a run whose gate never produced a verdict
# at all. SKILL.md `### 3c` states the rule this makes executable: a term with no
# route is a `STOP_UNREADABLE`, not a shrug.
#
# `blockers_remaining=<n>` is deliberately NOT a member: it is the one term the
# fingerprint multisets represent far more precisely, and `cmd_converge` strips it
# before routing.
GATE_REASONS_REPAIRABLE = frozenset({"ci=red", "mergeable=CONFLICTING"})
# A gate term the loop cannot fix by fixing code, only by waiting.
GATE_REASONS_WAITABLE = frozenset(
    {"ci=pending", "ci=unknown", "ci=no_checks_after_push", "mergeable=unknown"}
)
GATE_REASONS_ROUTABLE = GATE_REASONS_REPAIRABLE | GATE_REASONS_WAITABLE

# NO `_ATTEMPT_RE` COMPANION HERE, DELIBERATELY. There was one -- a
# `\A[0-9]{2}\Z` that nothing ever matched against -- and its only effect was to
# tell a reader that the `-NN` attempt suffix is parsed and validated somewhere.
# It is not: the suffix is FORMATTED (`"%02d" % attempt`) and never read back,
# and the attempt number itself arrives as an int that `cmd_plan`, `cmd_defer`
# and `cmd_converge` each bound numerically against their own ceiling. A
# validator with no call site is a claim nobody can contradict, which is the
# defect class this module's own docstring is about.
_SHA1_RE = re.compile(r"\A[0-9a-f]{40}\Z")

# Bounds mirrored from lib/code_fixer_contract.py so a document that passes here
# cannot be rejected downstream for a length the two files disagree about.
MAX_SUMMARY_BYTES = 4096
MAX_DETAIL_BYTES = 16384
MAX_PATH_CHARS = 4096
MAX_LINE = 999_999_999
# The digit COUNT is bounded before `int()` is ever called on a line string.
# CPython 3.11+ raises `ValueError` converting a string of more than 4300
# digits, and an uncaught ValueError is exit 1 with a traceback -- not the
# contracted exit 74 with a stable token that every calling fence branches on.
# Nine is `MAX_LINE`'s own width, so anything longer was out of range anyway.
MAX_LINE_DIGITS = len(str(MAX_LINE))
MAX_FINDINGS = 64

_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


class Refusal(SystemExit):
    """What `fail()` raises.

    A SystemExit subclass, so every existing caller and the process exit code
    are unchanged -- but a caller that means to TOLERATE one refusal can catch
    exactly this and nothing else. A bare `except SystemExit` would also swallow
    argparse's `--help` exit and any deliberate `raise SystemExit(2)`, which is
    how a tolerant read turns into a silent one.

    The token travels on the exception so the tolerating caller can say which
    refusal it absorbed rather than reporting a bare count.
    """

    def __init__(self, token: str, detail: str) -> None:
        super().__init__(74)
        self.token = token
        self.detail = detail


def fail(token: str, detail: str = "") -> "NoReturn":  # type: ignore[valid-type]
    message = f"premerge-findings: {token}"
    if detail:
        message = f"{message}: {detail}"
    print(message, file=sys.stderr)
    raise Refusal(token, detail)


def _canonical_json(value: object) -> bytes:
    """Compact, sorted-key JSON with every markup character \\u-escaped.

    JSON does not normally escape `<`, and this encoder's output is written
    INSIDE an `<external-untrusted-input>` spotlighting envelope. So reviewer
    prose containing the literal close tag -- which is ordinary prose in a repo
    that documents the envelope, and is trivially plantable by anything that
    reaches the reviewer's context -- ended the envelope early and put whatever
    followed it outside the untrusted region, where `findings-to-issues` reads it
    as trusted. That is an injection breakout, not a formatting nit.

    Both sibling encoders already prevent it and this one did not, while
    `_encode_aggregate`'s docstring claimed byte-identical shape to one of them:
    `report_primitives.canonical_json` rewrites the close marker, and
    `code_fixer_contract._canonical_json` escapes `<`, `>` and `&`. The wider set
    is the one adopted here, because the envelope's OPEN tag and any HTML-comment
    marker downstream are breakable by the same trick, and because matching the
    sibling exactly is what makes the "no new arm in the agent's parser" claim
    true rather than merely asserted.

    `\\u003c` is JSON's own escape for `<`, so `json.loads` restores the original
    prose byte-for-byte -- nothing is lost, only the structural reading is.

    `ensure_ascii=True` stays: it also \\u-escapes every non-ASCII byte, which
    keeps the payload pure ASCII (so `.encode("ascii")` cannot raise) and closes
    the unicode-lookalike variant of the same trick.
    """
    rendered = json.dumps(
        value, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    )
    return (
        rendered.replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
        .encode("ascii")
    )


def _bounded_text(value: object, limit: int, token: str, what: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(token, f"{what} must be a non-empty string")
    if _CONTROL.search(value):
        fail(token, f"{what} carries a control character")
    collapsed = " ".join(value.split())
    if len(collapsed.encode("utf-8")) > limit:
        fail(token, f"{what} exceeds {limit} bytes")
    return collapsed


def _repo_path(value: object) -> str:
    """Normalise a repo-relative POSIX path, or refuse.

    Same predicate as `code_fixer_contract.py`'s scope validator, restated here
    only because this file must reject BEFORE the aggregate is written -- a path
    that escapes the repo has to die at parse time, not at publish time.
    """
    if not isinstance(value, str) or not value:
        fail("finding_schema_invalid", "file must be a non-empty string")
    if len(value) > MAX_PATH_CHARS:
        fail("finding_schema_invalid", "file path too long")
    if "\\" in value:
        fail("finding_schema_invalid", f"file must be POSIX-separated: {value}")
    if value.startswith("/"):
        fail("finding_schema_invalid", f"file must be repo-relative: {value}")
    if posixpath.normpath(value) != value:
        fail("finding_schema_invalid", f"file is not normalised: {value}")
    first = value.split("/", 1)[0]
    if first in ("..", ".git"):
        fail("finding_schema_invalid", f"file escapes the repository: {value}")
    return value


_RUN_ID_RE = re.compile(r"\A[0-9]{8}-[0-9]{6}-[0-9a-f]+\Z")


def _pr_number(value: object, what: str) -> int:
    """The two identity fields, validated ONCE and reused.

    `cmd_plan` checked these on the way in and nothing checked them on the way
    back out, so `cmd_defer` indexing `document["pr_number"]` on an artifact that
    lacked it died with a `KeyError`, a traceback and exit status 1 -- against a
    module whose docstring promises "every failure exits non-zero with a stable
    token on stderr" and a verb table that promises `defer 0 encoded | 74
    refused`. An uncaught exception is neither, and a fence branching on 74
    cannot see it.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail("input_schema_invalid", f"{what} pr_number must be a positive integer")
    return value


def _run_id_value(value: object, what: str) -> str:
    if not isinstance(value, str) or not _RUN_ID_RE.match(value):
        fail("input_schema_invalid", f"{what} run_id must match YYYYMMDD-HHMMSS-<hex>")
    return value


def _optional_line(value: object) -> "int | None":
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        fail("finding_schema_invalid", "line must be an integer when present")
    if not 1 <= value <= MAX_LINE:
        fail("finding_schema_invalid", f"line out of range: {value}")
    return value


def _category(value: object) -> "str | None":
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        fail("finding_schema_invalid", "category must be a non-empty string when present")
    slug = value.strip().lower()
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", slug):
        fail("finding_schema_invalid", f"category is not a kebab slug: {value}")
    return slug


def _verdict(value: object) -> "str | None":
    if value is None:
        return None
    if value not in VERDICTS:
        fail("finding_schema_invalid", f"verdict must be one of {sorted(VERDICTS)}")
    return value


def _severity_from_category(category: str) -> str:
    return "suggestion" if category in CLEANUP_CATEGORIES else "blocker"


_FINGERPRINT_STRIP = re.compile(r"[`'\"]")


def _fold_summary(summary: str) -> str:
    """Line-independent, punctuation-independent identity text for a finding.

    Deliberately AGGRESSIVE, and deliberately NOT the uniqueness predicate. This
    fold answers "is this the same complaint I already tried to fix?" across
    re-reviews that re-word punctuation, quoting and case, so it has to erase
    exactly those. `_normalised_summary` answers the different question of
    whether two rows are one row -- see the comment on the uniqueness key in
    `_normalise_findings` for why conflating the two cost a whole attempt.
    """
    folded = " ".join(_FINGERPRINT_STRIP.sub("", summary).split()).casefold()
    return folded.rstrip(".!?;:, ")


def _normalised_summary(summary: str) -> str:
    """The DOWNSTREAM dedupe text, restated: `agents/findings-to-issues.md`.

    Its Step 5 defines `normalised_summary` as the summary "lowercased,
    whitespace-runs collapsed to single space, leading/trailing whitespace
    trimmed, code-fence backticks stripped" -- and that is the whole list. No
    quote stripping, no trailing-punctuation strip, `lower()` rather than
    `casefold()`.

    This exists so this file's uniqueness refusal can be keyed on the predicate
    it CLAIMS to mirror instead of on `_fold_summary`, which is strictly coarser.
    The direction that costs a run is the one the old comment did not cover: two
    rows the downstream agent would file as two issues, folded together here,
    refused as `findings_not_unique`, `plan` exiting before it writes, and -- per
    SKILL.md `## Phase 2` -- the attempt dying over how the reviewer punctuated
    its output. The built-in reviewer's xhigh prompt explicitly asks for two rows
    when two angles flag one line, so `the 'lock' is released early` alongside
    `the lock is released early.` is output it was INSTRUCTED to produce.
    """
    return " ".join(summary.replace("`", "").split()).lower()


def _fingerprint(file_path: str, summary: str) -> str:
    """A finding's identity ACROSS re-reviews.

    The convergence loop has to answer one question honestly -- "is this the same
    blocker I already tried to fix?" -- and none of the fields the reviewer gives
    us answers it:

      * `rank` is a position in one output array. Re-review reorders it.
      * `line` moves the instant any fix lands, including a fix in another
        finding's hunk. An identity keyed on it reports every survivor as new,
        so the loop would see infinite progress and never stop.
      * `failure_scenario` is prose the reviewer rewrites freely between passes.

    Path plus folded summary is the narrowest pair that is present in BOTH
    reviewer output contracts and stable under the edits the loop itself makes.

    DELIBERATELY NOT either of the two fingerprints `agents/findings-to-issues.md`
    computes, even though Step 8a's container key is now path-based too
    (`sha256(finding_marker_slug:file_path)`, #722) and so shares this one's
    insensitivity to line movement. Different material, and a different question:
    that one keys the file-level ISSUE CONTAINER, so every finding in a file
    collapses onto it by design; this one keys ONE FINDING across re-reviews, so
    two findings in a file must stay apart or the loop reads a survivor as fixed.
    The per-MEMBER key alongside it is `path:line:normalised_summary`, which is
    keyed on exactly the line movement this one has to survive. Same 16-hex
    width, three different questions -- never substitute one for another.
    """
    material = "%s\x1f%s" % (file_path, _fold_summary(summary))
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def _load(path: str) -> object:
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        fail("input_unreadable", f"{path}: {exc}")
    if not raw.strip():
        fail("input_empty", path)
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail("input_not_json", f"{path}: {exc}")


def _atomic_write(path: str, payload: bytes) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    if not os.path.isdir(directory):
        fail("output_unsafe", f"parent directory does not exist: {directory}")
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".premerge-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail("output_failed", f"{path}: {exc}")


# --------------------------------------------------------------------------
# normalise -- read either code-review contract into one shape
# --------------------------------------------------------------------------
def _normalise_findings(records: object) -> "list[dict]":
    if not isinstance(records, list):
        fail("findings_schema_invalid", "findings must be a JSON array")
    if len(records) > MAX_FINDINGS:
        fail("findings_schema_invalid", f"more than {MAX_FINDINGS} findings")

    seen: "set[tuple[str, int | None, str]]" = set()
    out: "list[dict]" = []
    for index, record in enumerate(records, start=1):
        if not isinstance(record, dict):
            fail("finding_schema_invalid", f"finding {index} is not an object")

        # `rank` is the finding's position in the reviewer's own output, which
        # its contract guarantees is "ranked most-severe first". Carried through
        # so a later reader can reconstruct the reviewer's ordering after this
        # file has re-grouped everything by severity.
        entry = {
            "rank": index,
            "file": _repo_path(record.get("file")),
            "line": _optional_line(record.get("line")),
            "summary": _bounded_text(
                record.get("summary"), MAX_SUMMARY_BYTES, "finding_schema_invalid",
                f"finding {index} summary",
            ),
            "failure_scenario": _bounded_text(
                record.get("failure_scenario"), MAX_DETAIL_BYTES,
                "finding_schema_invalid", f"finding {index} failure_scenario",
            ),
            "category": _category(record.get("category")),
            "verdict": _verdict(record.get("verdict")),
        }

        # Identity across re-reviews. Computed here, once, so every consumer of
        # classified.json reads the same answer to "have I seen this before?".
        entry["fingerprint"] = _fingerprint(entry["file"], entry["summary"])

        # Uniqueness is (file, line, normalised summary) -- ONE key, whether or
        # not the reviewer gave us a line. Two properties have to hold at once,
        # and neither branch of a line-conditional key delivers both.
        #
        # NOT the loop fingerprint, which is what this used to be. `_fold_summary`
        # is strictly coarser than the downstream `normalised_summary` -- it also
        # strips `'` and `"` and trailing `.!?;:,` and casefolds -- so a pair of
        # rows that findings-to-issues would file as TWO issues collided here and
        # killed the attempt. Refusing more than the collapse you claim to mirror
        # is not the safe direction: it is the unrecoverable one. `_fingerprint`
        # keeps the coarse fold, because surviving a re-wording is exactly what
        # cross-attempt identity needs; the two questions are now asked by two
        # functions instead of one.
        #
        # TWO FINDINGS AT ONE LOCATION ARE TWO FINDINGS. The built-in reviewer's
        # xhigh prompt instructs it, in as many words, that if two angles flag
        # the same line for different reasons it must record both, and its own
        # dedup pass only collapses "same defect, same location, same reason". A
        # key of (file, line) refuses exactly the document that prompt asks for.
        # Under the loop that refusal is unrecoverable: `plan` exits before
        # writing, the gate then reads the PREVIOUS attempt's artifact, and the
        # run dies because the reviewer did what it was told. The line-LESS half
        # of this collision was fixed first; the with-line half is the likelier
        # one by far, because a line number is the normal case.
        #
        # TWO LINES ARE TWO PLACES, EVEN UNDER ONE SUMMARY. Two genuinely
        # distinct blockers at different lines of one file, phrased identically
        # ("the return value of write() is never checked"), normalise to the same
        # text. Keying on (file, summary) alone would refuse that pair -- the very
        # case `_blocker_fingerprints` counts as a multiset in order to keep
        # visible.
        #
        # So `line` separates locations, the normalised summary separates
        # reasons, and only a row matching an earlier one in BOTH -- same place,
        # same complaint, i.e. a finding the reviewer emitted twice -- collides.
        # That is now literally the triple `agents/findings-to-issues.md` Step 5
        # dedupes on (`(file_path, line, sha256(normalised_summary)[:16])`),
        # computed by `_normalised_summary` rather than asserted in prose, so
        # this file refuses a pair if and only if that agent would merge it. The
        # unhashed text is compared instead of its 16-hex truncation: same
        # answer, minus a truncation collision that would refuse a real pair.
        key = (entry["file"], entry["line"], _normalised_summary(entry["summary"]))
        if key in seen:
            where = (
                entry["file"]
                if entry["line"] is None
                else "%s:%d" % (entry["file"], entry["line"])
            )
            fail(
                "findings_not_unique",
                f"finding {index} repeats an earlier finding at {where}",
            )
        seen.add(key)

        severity = record.get("severity")
        if severity not in SEVERITIES:
            fail(
                "severity_missing",
                f"finding {index} must carry severity in {sorted(SEVERITIES)}",
            )

        # The anti-drift gate. Where the reviewer told us the angle, the angle
        # decides and the controller does not get a vote.
        if entry["category"] is not None:
            derived = _severity_from_category(entry["category"])
            if derived != severity:
                fail(
                    "severity_contradicts_category",
                    f"finding {index} ({entry['file']}) is category="
                    f"{entry['category']} which is {derived}, but was classified "
                    f"{severity}; category is authoritative",
                )
            entry["severity_source"] = "category"
        else:
            entry["severity_source"] = "controller"
        entry["severity"] = severity
        out.append(entry)
    return out


# --------------------------------------------------------------------------
# fix waves -- group blockers into disjoint per-file batches
# --------------------------------------------------------------------------
def _fix_waves(blockers: "list[dict]", max_per_wave: int) -> "list[list[dict]]":
    """One agent per FILE, never one per finding.

    Two agents editing the same file in the same wave is the file-collision
    class this repo has already been bitten by (`/turbo` disjoint-file waves,
    RFC 0020). Grouping by file makes every agent in a wave provably
    non-overlapping, so no worktree isolation is needed for the fix stage.
    """
    if max_per_wave < 1:
        fail("bad_wave_size", "max-per-wave must be >= 1")
    by_file: "dict[str, list[dict]]" = {}
    for finding in blockers:
        by_file.setdefault(finding["file"], []).append(finding)

    # Deterministic: files in first-appearance rank order, so a re-run over the
    # same findings plans the same waves. Sorting by name instead would reorder
    # the whole plan when one filename changes.
    ordered = sorted(by_file.items(), key=lambda kv: min(f["rank"] for f in kv[1]))
    waves: "list[list[dict]]" = []
    for start in range(0, len(ordered), max_per_wave):
        waves.append(
            [
                {"file": path, "findings": findings}
                for path, findings in ordered[start : start + max_per_wave]
            ]
        )
    return waves


# A `file` value that cannot serve as a group key -- not a string at all, or the
# empty string that `_repo_path` refuses. Paired with the row's own index it is
# unique per row and never equal to any path, which is the entire contract:
# `_defer_groups` must not merge two such rows into one group, and `cmd_defer`
# must be able to tell them from a real path in order to drop them.
_UNUSABLE_FILE = object()


def _defer_groups(rows: "list[dict]") -> "list[tuple[object, list[int]]]":
    """The deferred rows, grouped by owning file, in first-appearance order.

    The same decision `_fix_waves` makes for the FIXER, made for the FILER: the
    downstream agent now opens one issue per file (#722), so an envelope carrying
    half of a file's findings produces an issue that reads as complete and is not.

    Groups carry row INDICES rather than the rows themselves, because the caller
    admits most groups whole and row-fills exactly one of them. A positional key
    is what lets it rebuild the kept list in the rows' ORIGINAL relative order --
    the property `cmd_defer` has always promised -- without leaning on dict
    identity or equality to tell two rows apart.

    The key is the row's own `file` value and NOT `_repo_path(...)`. Most rows
    reach this function unvalidated by design: `cmd_defer` reads this attempt's
    `suggestions` and `blockers` and every earlier attempt's carried suggestions
    straight off disk, checked for nothing beyond "it is a dict". On an
    overflowing run most of them are about to be discarded.
    Validating here made one malformed row in the DROPPED tail cost the entire
    envelope: exit 74 behind `defer "$@" || exit 74`, a fence with no recovery
    arm, so a run holding 64 filable findings filed nothing over a row no
    consumer would ever have seen. `_encode_aggregate` therefore stays the single
    gate, and because it runs after the cut it still refuses a malformed row that
    SURVIVES, with the same token it always did.

    Any `file` that is not a NON-EMPTY string gets a sentinel key instead, which
    is what keeps the sharpest case out of the dict: an object or an array is
    unhashable, and the `TypeError` a bare `.get` would raise on it is neither of
    the two answers this verb is contracted to give.

    THE EMPTINESS HALF IS NOT A NICETY, and it used to be missing. `""` is
    hashable, so an empty-`file` row grouped like a real path, sorted among the
    real paths, survived the cut -- and then cost the ENTIRE envelope at
    `_encode_aggregate`, whose `_repo_path` refuses it with `file must be a
    non-empty string`. 64 filable findings lost to one row is the precise trade
    this function exists to refuse, and `""` walked straight through it. Two
    empty-`file` rows also shared one group, which is the other half of the
    sentinel's contract.

    Being unique per row, the sentinel also stops two such rows sharing a group.
    The caller drops these groups outright -- on EVERY run, not only an
    overflowing one -- because a row with no usable path cannot become an issue
    under any ranking.
    """
    by_file: "dict[object, list[int]]" = {}
    order: "list[object]" = []
    for index, row in enumerate(rows):
        value = row.get("file")
        key = value if isinstance(value, str) and value else (_UNUSABLE_FILE, index)
        if key not in by_file:
            by_file[key] = []
            order.append(key)
        by_file[key].append(index)
    return [(key, by_file[key]) for key in order]


def _drop_unfilable(rows: "list[dict]") -> "tuple[list[dict], int]":
    """The rows a file-keyed filer could open an issue for, and how many could not.

    ONE implementation, two callers, for the same reason `_union_suggestions` is:
    `cmd_defer` drops these rows into `OVERFLOW=` and `cmd_plan` has to skip
    exactly the same ones before it validates the union. A `plan` that refused on
    a row `defer` is going to discard would abort an attempt that was going to
    succeed -- the same maximal-loss trade the drop itself exists to refuse -- and
    an equivalence between two hand-written predicates is a thing this file has
    watched drift rather than a thing that stays true.

    The decision is `_defer_groups`' KEY, never the row's `file` read a second
    time: that function is where "not a string, or the empty string `_repo_path`
    refuses" is defined, and re-deriving it here would be the second copy.
    """
    unfilable = {
        index
        for key, members in _defer_groups(rows)
        if not isinstance(key, str)
        for index in members
    }
    if not unfilable:
        return rows, 0
    return (
        [row for index, row in enumerate(rows) if index not in unfilable],
        len(unfilable),
    )


# --------------------------------------------------------------------------
# the deferred-findings envelope handed to agents/findings-to-issues.md
# --------------------------------------------------------------------------
def _encode_aggregate(
    rows: "list[dict]", pr_number: int, run_id: str, allow_blockers: bool = False
) -> bytes:
    """One line of canonical JSON inside the untrusted-input envelope.

    Byte shape is deliberately identical to `code_fixer_contract.encode_aggregate`
    (open tag + newline, one compact sorted-key JSON line, newline + close tag +
    newline) so the agent's existing envelope parser reads it with no new arm.
    Only the `source` and the per-finding key set differ, and both are declared.

    EVERY ROW IS RE-VALIDATED, even one that "came from" `_normalise_findings`.
    Not all of them did: `cmd_defer` feeds this function rows read straight off
    disk (`document["blockers"]`, `document["suggestions"]`, and every earlier
    attempt's carried suggestions), which nothing had checked beyond "it is a
    dict". A row missing `failure_scenario` or `line` therefore raised `KeyError`
    -- exit 1 and a traceback -- from a verb contracted to answer `0 encoded | 74
    refused`. Re-validating is cheap (the validators are idempotent on rows that
    already passed) and it is what makes the exit-status contract true for the
    disk path as well as the in-memory one.
    """
    findings = []
    # Contributor-ordered, and the built-in reviewer always leads it: an empty
    # findings array still publishes an envelope (a clean run and a broken one
    # must not look alike), and `source_edges` is documented as a subset of the
    # declared contributors, so the roster can never be empty either.
    edges_present = [REVIEW_SOURCE_EDGE]
    for index, finding in enumerate(rows, start=1):
        if not isinstance(finding, dict):
            fail("finding_schema_invalid", f"aggregate row {index} is not an object")
        # Read through the validators, never by bare index -- see the docstring.
        path = _repo_path(finding.get("file"))
        line = _optional_line(finding.get("line"))
        summary = _bounded_text(
            finding.get("summary"), MAX_SUMMARY_BYTES, "finding_schema_invalid",
            f"aggregate row {index} summary",
        )
        detail = _bounded_text(
            finding.get("failure_scenario"), MAX_DETAIL_BYTES,
            "finding_schema_invalid", f"aggregate row {index} failure_scenario",
        )
        # The row's OWN severity, not a hardcoded one.
        #
        # It used to be pinned to "suggestion". That meant `/premerge` had no way
        # to file the one finding that matters most -- a blocker the loop could
        # not clear -- so that finding was printed into a summary and lost. A
        # promise with no producer is the defect this command already shipped
        # once; the fix is a producer, not a louder promise.
        #
        # `allow_blockers` DEFAULTS CLOSED and `cmd_defer` is the one caller that
        # opens it. Not a vestige of a second caller: the default is the opt-in
        # gate itself, so a future caller that has no business filing blockers
        # gets the refusal by writing nothing, and admitting them stays a
        # deliberate act at the call site.
        severity = finding.get("severity", "suggestion")
        if severity not in SEVERITIES:
            fail("aggregate_severity_invalid", str(severity))
        if severity == "blocker" and not allow_blockers:
            fail("aggregate_blocker_not_allowed", path)
        # The row's OWN producer, not a hardcoded one -- see REVIEW_SOURCE_EDGE.
        # Rows that came through `_normalise_findings` carry no `source_edge` and
        # are the built-in reviewer's by construction; `_normalise_lens_findings`
        # stamps the simplify lens onto every row it makes.
        edge = finding.get("source_edge", REVIEW_SOURCE_EDGE)
        if not isinstance(edge, str) or not edge:
            fail("aggregate_source_edge_invalid", str(edge))
        if edge not in edges_present:
            edges_present.append(edge)
        findings.append(
            {
                "detail": detail,
                "scope": {
                    "line": line if line is not None else 1,
                    "operation": "modify_existing",
                    "path": path,
                },
                "severity": severity,
                "source_edges": [edge],
                "summary": summary,
            }
        )
    document = {
        "contributors": [
            {"confidence": "n/a", "id": edge_id, "verdict": "COMPLETE"}
            for edge_id in edges_present
        ],
        "findings": findings,
        "phase": "premerge",
        "pr_number": pr_number,
        "run_id": run_id,
        "schema_version": 2,
    }
    body = _canonical_json(document)
    if b"\x00" in body or b"\r" in body or b"\n" in body:
        fail("aggregate_not_canonical", "envelope body carries a control byte")
    # The envelope's structural characters must not survive into its own body.
    # `_canonical_json` escapes them; this asserts it, so a future edit that
    # loosens the encoder fails here instead of shipping a breakout. `<` alone is
    # enough to open or close a tag, and it is the only one either sibling
    # encoder treats as load-bearing.
    if b"<" in body:
        fail("aggregate_not_canonical", "envelope body carries an unescaped '<'")
    return (
        f'<external-untrusted-input source="{AGGREGATE_SOURCE}">\n'.encode("ascii")
        + body
        + b"\n</external-untrusted-input>\n"
    )


# --------------------------------------------------------------------------
# loop state -- reading one attempt's evidence back off disk
# --------------------------------------------------------------------------
def _attempt_path(out_dir: str, attempt: int) -> str:
    return os.path.join(out_dir, "classified-%02d.json" % attempt)


def _read_attempt(out_dir: str, attempt: int, required: bool) -> "dict | None":
    """Load one attempt's classified.json, or None when it legitimately absent.

    `required=True` is a refusal, never a default. An attempt whose evidence
    cannot be read must not be summarised as "nothing to compare against" --
    that reads as progress and would let the loop run on.

    EVERY FIELD A CALLER DEREFERENCES IS CHECKED HERE, not just the two arrays.
    This is the designated fail-closed reader, so a field it waves through is a
    field that crashes somewhere downstream instead of refusing here: `cmd_defer`
    indexes `pr_number` and `run_id` unconditionally, and on an artifact missing
    either it raised `KeyError` -- exit 1 with a traceback, not the contracted
    exit 74 with a stable token.
    """
    target = _attempt_path(out_dir, attempt)
    if not os.path.exists(target):
        if required:
            fail("attempt_evidence_missing", target)
        return None
    document = _load(target)
    if not isinstance(document, dict) or document.get("schema_version") != SCHEMA_VERSION:
        fail("input_schema_invalid", f"{target} is not a v1 document")
    for key in ("blockers", "suggestions"):
        if not isinstance(document.get(key), list):
            fail("input_schema_invalid", f"{target} has no {key} array")
    _pr_number(document.get("pr_number"), target)
    _run_id_value(document.get("run_id"), target)
    return document


def _object_rows(values: "list", what: str) -> "list[dict]":
    """A stored findings array whose elements are all objects, or a refusal."""
    out: "list[dict]" = []
    for index, value in enumerate(values, start=1):
        if not isinstance(value, dict):
            fail("finding_schema_invalid", f"{what} {index} is not an object")
        out.append(value)
    return out


def _blocker_fingerprints(document: "dict") -> "collections.Counter[str]":
    """The attempt's blockers as a MULTISET of fingerprints.

    A multiset and not a set, because the fingerprint is deliberately
    line-independent: two genuinely distinct blockers at different lines of one
    file, reported with the same summary ("the return value of write() is never
    checked"), share a fingerprint. As a set they collapse to one element, so
    fixing one of them leaves the set unchanged and the loop answers
    STOP_NO_PROGRESS on an attempt that removed a real blocker -- stopping early,
    with budget unspent, on exactly the success it was built to keep going for.
    Counting them keeps that visible.
    """
    prints: "collections.Counter[str]" = collections.Counter()
    for finding in document["blockers"]:
        value = finding.get("fingerprint") if isinstance(finding, dict) else None
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{16}", value):
            # Pre-loop artifacts carry no fingerprint. Refusing is the only
            # honest answer: a missing identity cannot be compared, and treating
            # it as "no match" would report a survivor as newly fixed.
            fail("fingerprint_missing", "a blocker carries no 16-hex fingerprint")
        prints[value] += 1
    return prints


def _carry_prior_suggestions(out_dir: str, attempt: int) -> "list[dict]":
    """Every earlier attempt's suggestions, oldest first.

    AN UNREADABLE EARLIER ATTEMPT IS SKIPPED AND REPORTED, NOT FATAL.

    The absent-file branch was already tolerant and the unreadable-file branch
    was fatal, so one truncated `classified-01.json` -- an interrupted run, a
    full disk -- refused every later `plan --carry-prior` AND the Phase 5
    `defer`, and the run filed nothing at all. On a step whose whole purpose is
    that findings outlive the run, losing every surviving finding to one corrupt
    byte range is the wrong trade; it is the same one the OVERFLOW arm already
    declines to make.

    The skip is announced on stderr with its refusal token, so a run that
    carried less than it should is visible rather than silently short. Only
    `Refusal` is caught -- see its docstring for why the exception is not a bare
    SystemExit.
    """
    carried: "list[dict]" = []
    for earlier in range(1, attempt):
        try:
            document = _read_attempt(out_dir, earlier, required=False)
        except Refusal as refusal:
            print(
                "premerge-findings: attempt_unreadable_skipped: "
                f"attempt {earlier} ({refusal.token}); its suggestions are not carried",
                file=sys.stderr,
            )
            continue
        if document is None:
            continue
        for record in document["suggestions"]:
            if isinstance(record, dict) and isinstance(record.get("fingerprint"), str):
                carried.append(record)
    return carried


# The tag that fronts an unhashable field's stand-in. A one-off object, so the
# stand-in is a TUPLE and can therefore never compare equal to the string or the
# integer a well-formed row puts in the same slot.
_UNHASHABLE_FIELD = object()


def _hashable_field(value: object) -> object:
    """One row field, as something a `set` can hold.

    `_suggestion_key` reads `file` and `line` straight off disk: `cmd_defer`
    unions this attempt's `suggestions` with every earlier attempt's carried
    rows, and nothing has checked any of them beyond "it is a dict". A JSON
    OBJECT or ARRAY in either field is unhashable, so building the dedupe set
    raised `TypeError` -- exit 1 with a full traceback, out of a verb contracted
    to answer `0 encoded | 74 refused`, and raised BEFORE the cut that was going
    to discard the row had even run.

    That is the same defect `_defer_groups` keeps out of its dict with a
    sentinel, arriving one function earlier and on the path most rows take:
    `_defer_groups` only ever sees rows this union has already returned, so its
    sentinel could not protect the common case at all.

    The stand-in is the value's canonical JSON behind a tuple tag, which keeps
    the dedupe honest in BOTH directions -- two rows carrying the same malformed
    value are still one finding, two carrying different ones are still two --
    where collapsing every unusable value onto one marker would silently merge
    them. `dict` and `list` are the only unhashable values `json.loads` can
    produce, and every row here came from it, so the two arms are exhaustive.
    """
    if isinstance(value, (dict, list)):
        return (_UNHASHABLE_FIELD, _canonical_json(value))
    return value


def _suggestion_key(row: "dict") -> "tuple":
    """The identity the cross-attempt suggestion union dedupes on.

    NOT the fingerprint. `_fingerprint` is deliberately line-independent (file +
    summary), which is right for the blocker-progress comparison and wrong here:
    two genuinely distinct suggestions in one file that the reviewer summarised
    the same way ("the return value of write() is never checked") share it, so
    the second collapsed into the first and never reached
    `deferred-aggregate.md` -- never filed, never seen, on the step whose stated
    purpose is that findings outlive the run.

    This is the exact case `_blocker_fingerprints` keeps a Counter for on the
    blocker path ("TWO LINES ARE TWO PLACES, EVEN UNDER ONE SUMMARY"). The
    suggestion path now keys on the same three fields `_normalise_findings`
    already keys its duplicate check on, so the two paths agree about what makes
    two findings the same finding.

    `file` and `line` go through `_hashable_field` because neither has been
    validated when this runs -- see that function for the traceback it ends. A
    well-formed row's values pass through untouched, so the dedupe every real
    finding gets is byte-for-byte the one it always got.
    """
    return (
        _hashable_field(row.get("file")),
        _hashable_field(row.get("line")),
        _normalised_summary(row["summary"]) if isinstance(row.get("summary"), str) else None,
    )


def _union_suggestions(base: "list[dict]", carried: "list[dict]") -> "list[dict]":
    """The cross-attempt suggestion union -- ONE implementation, two callers.

    `cmd_plan` builds it to report `CARRIED=` and `cmd_defer` builds it to write
    `deferred-aggregate.md`, and the second one's comment used to assert the two
    were "byte-for-byte" the same ordering. An equivalence between two copies,
    held by a sentence, is a thing this repo has watched drift rather than a thing
    that stays true; one function makes the claim structural instead -- which is
    what lets `plan` report a count for a union it does not itself write out.

    Latest attempt's rows first, then earlier attempts oldest-first, deduped by
    `_suggestion_key` with the first occurrence winning -- so a suggestion raised
    on attempt 1 and not repeated on attempt 3 is still filed. Unmentioned is not
    resolved.
    """
    out = list(base)
    seen = {_suggestion_key(row) for row in out}
    for record in carried:
        key = _suggestion_key(record)
        if key not in seen:
            seen.add(key)
            out.append(record)
    return out


def _converge_ledger(run_dir: str) -> str:
    return os.path.join(run_dir, "converge.jsonl")


def _append_converge_row(run_dir: str, row: "dict") -> None:
    """One line per decision, append-only.

    Append rather than rewrite: this ledger is the run's account of what the
    loop believed at each step, and a rewriter that lost attempt 2 would leave a
    story where attempt 3 followed attempt 1. O_APPEND with a single write() of a
    line that carries no newline of its own is atomic for this size on every
    platform this repo targets.
    """
    payload = _canonical_json(row) + b"\n"
    if b"\n" in payload[:-1]:  # pragma: no cover - canonical json cannot embed one
        fail("output_failed", "a ledger row would span two lines")
    try:
        handle = os.open(_converge_ledger(run_dir), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(handle, payload)
        finally:
            os.close(handle)
    except OSError as exc:
        fail("output_failed", f"{_converge_ledger(run_dir)}: {exc}")


def _count_wait_rows(rows: "list[dict]", attempt: int) -> int:
    """How many WAIT_CI decisions this attempt has already recorded.

    Takes the ALREADY-READ rows. Both this reducer and `_last_converge_row`
    used to open and re-parse `converge.jsonl` themselves, so one `converge`
    invocation ran `json.loads` over every row of the ledger twice -- and the
    ledger is longest (dozens of rows) on exactly the runs that spent their
    WAIT_CI budget, i.e. the ones already waiting on something slow. One read,
    two reductions.
    """
    return sum(
        1
        for row in rows
        if row.get("attempt") == attempt and row.get("decision") == "WAIT_CI"
    )


def _read_converge_rows(run_dir: str) -> "list[dict]":
    """Every ledger row, in order. Refuses rather than degrading.

    A ledger we cannot parse is NOT an empty ledger. Returning `[]` on a parse
    error would make "no history recorded" indistinguishable from "the history
    says nothing changed" -- the difference between CONTINUE and
    STOP_NO_PROGRESS, and between a bounded WAIT_CI and an unbounded one.

    A ROW WE CANNOT READ IS NOT AN ABSENT ROW EITHER, and that half used to be
    missing: `json.JSONDecodeError` refused, but a line of `null`, `[]`, `0` or
    `"x"` -- valid JSON, wrong shape -- was dropped by an `isinstance` filter
    with no complaint. `_count_wait_rows` then under-counted the WAIT_CI history
    it is the backstop for: a partially-corrupted ledger reports fewer waits than
    were recorded, `wait_passes` stays below `CONVERGE_WAIT_CI_CEILING`, and the
    loop this function's own docstring says is bounded is not. Silently
    discarding evidence is the same defect as silently discarding the file.
    """
    ledger = _converge_ledger(run_dir)
    if not os.path.exists(ledger):
        return []
    try:
        with open(ledger, "rb") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
    except OSError as exc:
        fail("input_unreadable", f"{ledger}: {exc}")
    rows: "list[dict]" = []
    for index, line in enumerate(lines, start=1):
        try:
            row = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail("input_not_json", f"{ledger}: {exc}")
        if not isinstance(row, dict):
            fail("input_schema_invalid", f"{ledger}: row {index} is not an object")
        rows.append(row)
    return rows


def _last_converge_row(rows: "list[dict]", attempt: int) -> "dict | None":
    """The last ledger row recorded for one attempt.

    A SCAN, not a peek at the tail. `WAIT_CI` deliberately does not consume a
    repair, so it appends further rows under the SAME attempt number -- and a
    tail-only reader would then see attempt N where it expected N-1, conclude
    that no previous reasons were recorded, and lose the ability to ever answer
    STOP_NO_PROGRESS. The loop would run to its backstop on every CI hiccup.

    Named for what it does now: it reduces rows the caller already read. It was
    `_read_converge_row`, and it did its own read -- the second full parse of the
    ledger in one `converge` invocation. See `_count_wait_rows`.
    """
    found = None
    for row in rows:
        if row.get("attempt") == attempt:
            found = row
    return found


def _lens_source_edge(lens: "str | None") -> str:
    """The `source_edges` value that says a simplify lens raised this row.

    Mirrors `/review-pr`'s own `review_pr.simplify.{reuse,quality,efficiency}`
    edges. A lens we cannot slugify still gets a SIMPLIFY edge -- "we do not know
    which lens" must never fall back onto the code reviewer's edge, which is the
    misattribution this function exists to end.
    """
    if not isinstance(lens, str) or not lens.strip():
        return SIMPLIFY_SOURCE_EDGE_FALLBACK
    slug = re.sub(r"[^a-z0-9]+", "-", lens.strip().lower()).strip("-")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", slug):
        return SIMPLIFY_SOURCE_EDGE_FALLBACK
    return SIMPLIFY_SOURCE_EDGE_PREFIX + slug


def _normalise_lens_findings(records: object) -> "list[dict]":
    """Translate `code-simplifier` lens output into the aggregate's row shape.

    The lens contract is `{location: "path:line", severity, lens, summary,
    detail}` — no `failure_scenario`, which is why routing lens findings through
    `plan` is impossible rather than merely inconvenient. `detail` carries the
    rationale, so it becomes the row's detail, and the lens name is prefixed onto
    the summary so the issue says which of the three raised it.

    THE PREFIX IS THE DISPLAY, NOT THE ATTRIBUTION. `agents/findings-to-issues.md`
    reads contributor identity from `source_edges` alone and is forbidden from
    inferring it from prose, so each row also carries its own simplify edge --
    without which a deferred lens finding files as the built-in code reviewer's.
    And the prefix is skipped when the summary already opens with it: Phase 4b
    joins a location two lenses both hit as `<Lens>: <text> | <Lens>: <text>`
    (SKILL.md `### 4b`), and prefixing that again reads `Reuse: Reuse: …`.

    IT IS ALSO THE PART THAT GIVES WAY AT THE BOUND. The prefix used to be added
    AFTER `MAX_SUMMARY_BYTES` was checked, so a maximal lens summary emitted a
    row `len(lens) + 2` bytes over a limit whose own comment says it exists "so a
    document that passes here cannot be rejected downstream for a length the two
    files disagree about" -- and one such row makes the whole
    `deferred-aggregate.md` refusable, costing every deferred finding in the run.
    The bound is now measured on the string that is actually emitted, and when
    the prefix is what breaches it the PREFIX is dropped, not the prose: the
    attribution it duplicates is already carried, machine-readably, in
    `source_edges`, so dropping it loses a label while truncating the summary
    would lose the finding's own words.

    Every lens row files as a `suggestion` regardless of the lens's own severity
    field: these are the findings the simplify pass DECLINED to apply, on a stack
    that already passed the clean gate. Filing one as a blocker would halt a run
    over a refactor suggestion.
    """
    if not isinstance(records, list):
        fail("findings_schema_invalid", "lens findings must be a JSON array")
    out: "list[dict]" = []
    for index, record in enumerate(records, start=1):
        if not isinstance(record, dict):
            fail("finding_schema_invalid", f"lens finding {index} is not an object")
        location = record.get("location")
        if not isinstance(location, str) or ":" not in location:
            fail("finding_schema_invalid", f"lens finding {index} has no path:line location")
        raw_path, _, raw_line = location.rpartition(":")
        # A RESIDUAL COLON IS REFUSED, NOT ABSORBED INTO THE PATH.
        #
        # `rpartition` splits at the LAST colon, so a `path:line:col` location
        # yielded file=`path:line` and line=col. `_repo_path` accepts that,
        # because a colon is a legal POSIX path byte -- so nothing refused, and
        # the run filed an issue whose location names a file that does not
        # exist. A location this consumer cannot parse unambiguously is a
        # refusal; guessing which colon was the separator is how the finding
        # gets lost rather than reported.
        if ":" in raw_path:
            fail(
                "finding_schema_invalid",
                f"lens finding {index} location {location!r} has more than one colon",
            )
        line = None
        # `str.isdigit()` IS TRUE FOR '²', AND `int('²')` RAISES.
        # The ASCII check excludes the Unicode digit classes isdigit() accepts,
        # and MAX_LINE_DIGITS keeps the conversion clear of CPython's int-str
        # limit -- both before `int()` is reached, so an unparseable line
        # degrades to None (which this row already supports) instead of exiting
        # 1 with a traceback the fences cannot branch on.
        if raw_line.isascii() and raw_line.isdigit() and len(raw_line) <= MAX_LINE_DIGITS:
            value = int(raw_line)
            if 1 <= value <= MAX_LINE:
                line = value
        lens = record.get("lens")
        if lens is not None and not isinstance(lens, str):
            fail("finding_schema_invalid", f"lens finding {index} has a non-string lens")
        summary = _bounded_text(
            record.get("summary"), MAX_SUMMARY_BYTES, "finding_schema_invalid",
            f"lens finding {index} summary",
        )
        prefix = f"{lens}: " if lens else ""
        if prefix and summary[: len(prefix)].casefold() == prefix.casefold():
            prefix = ""
        # The bound is on what is EMITTED. `summary` already fits on its own
        # (`_bounded_text` above), so dropping the prefix is always a legal
        # answer, and it is the right one -- see the docstring.
        if prefix and len((prefix + summary).encode("utf-8")) > MAX_SUMMARY_BYTES:
            prefix = ""
        out.append(
            {
                "file": _repo_path(raw_path),
                "line": line,
                "summary": prefix + summary,
                "failure_scenario": _bounded_text(
                    record.get("detail"), MAX_DETAIL_BYTES, "finding_schema_invalid",
                    f"lens finding {index} detail",
                ),
                "severity": "suggestion",
                "source_edge": _lens_source_edge(lens),
            }
        )
    return out


def _reason_tokens(raw: str) -> "list[str]":
    if raw.strip() in ("", "none"):
        return []
    tokens = [token.strip() for token in raw.split(",")]
    if any(not token for token in tokens):
        fail("bad_reasons", f"empty reason token in {raw!r}")
    return tokens


# --------------------------------------------------------------------------
# verbs
# --------------------------------------------------------------------------
def cmd_plan(args: argparse.Namespace) -> int:
    document = _load(args.input)
    if not isinstance(document, dict):
        fail("input_schema_invalid", "the plan input must be a JSON object")
    if document.get("schema_version") != SCHEMA_VERSION:
        fail("input_schema_invalid", f"schema_version must be {SCHEMA_VERSION}")

    level = document.get("level")
    if level not in LEVELS:
        fail("input_schema_invalid", f"level must be one of {sorted(LEVELS)}")

    pr_number = _pr_number(document.get("pr_number"), "the plan input's")
    run_id = _run_id_value(document.get("run_id"), "the plan input's")

    findings = _normalise_findings(document.get("findings"))
    blockers = [f for f in findings if f["severity"] == "blocker"]
    suggestions = [f for f in findings if f["severity"] == "suggestion"]

    out_dir = args.out_dir
    if not os.path.isdir(out_dir):
        fail("output_unsafe", f"out-dir does not exist: {out_dir}")

    attempt = args.attempt
    # Wider than `converge`'s bound on purpose -- see CONVERGE_VERIFY_CEILING.
    # Phase 4c re-triages at `PREMERGE_ATTEMPT + 1` after the simplify commit,
    # and that re-stamp is the step SKILL.md calls fatal to skip.
    if not 1 <= attempt <= CONVERGE_VERIFY_CEILING:
        fail("bad_attempt", f"attempt must be 1..{CONVERGE_VERIFY_CEILING}")

    head_sha = args.head_sha
    if head_sha is not None and not _SHA1_RE.match(head_sha):
        fail("bad_head_sha", "head-sha must be 40 lowercase hex characters")

    # Suggestions accumulate across attempts; blockers do not.
    #
    # A blocker is a thing the loop is actively removing, so only the LATEST
    # review's blocker set is meaningful. A suggestion is never fixed by the
    # loop, so a suggestion the reviewer mentioned on attempt 1 and did not
    # repeat on attempt 3 is not resolved -- it is unmentioned, and filing only
    # the last pass's list would silently drop it.
    #
    # COUNTED HERE, FILED BY `defer`. This verb builds the union to report
    # `CARRIED=` and `counts.suggestion_carried` -- the numbers that tell an
    # operator "we filed 9" apart from "this review found 9" -- and writes no
    # aggregate of its own. `cmd_defer` rebuilds the same union from the same
    # `classified-NN.json` evidence, through the same `_union_suggestions`, and
    # that one is the file Phase 5 dispatches.
    carried = _carry_prior_suggestions(out_dir, attempt) if args.carry_prior else []
    union = _union_suggestions(suggestions, carried)
    carried_count = len(union) - len(suggestions)

    # THE UNION IS CHECKED HERE AND WRITTEN NOWHERE.
    #
    # Deleting the `suggestions-aggregate.md` write (see below) also deleted the
    # only per-attempt validation the CARRIED rows ever got. `_encode_aggregate`
    # ran on this union on every attempt, so a carried suggestion with an absolute
    # path or an over-long summary refused at the attempt that produced it.
    # Nothing replaced it, which moved every such refusal to the Phase 5 `defer`
    # -- after the whole repair budget has been spent, on the one step whose
    # entire purpose is that findings outlive the run. A refused `plan` is a hard
    # stop for the attempt with the previous attempt's artifacts intact (SKILL.md
    # `## Phase 2`); a refused `defer` is the run's findings, gone. Same
    # malformation, and the two timings are nowhere near the same cost.
    #
    # So the check comes back and the FILE does not. The encoder is called for its
    # refusals and its bytes are dropped on the floor: calling the REAL one is
    # what makes this equivalent to what `defer` will do, where restating the
    # validators here would be one more "two copies that cannot disagree" claim
    # held up by a sentence. Nothing is published, so `## Phase 2`'s "no aggregate
    # at all" and the run's one-aggregate property are both untouched.
    #
    # NOT STRICTER THAN THE STEP IT STANDS IN FOR, in either place `defer`
    # deliberately tolerates something:
    #
    #   * `_drop_unfilable` first, because `defer` drops a row with no usable
    #     `file` into `OVERFLOW=` rather than refusing the envelope. Refusing here
    #     on a row that is going to be discarded there would kill attempts that
    #     were going to succeed -- the exact trade that drop exists to refuse.
    #   * `allow_blockers=True`, matching the one caller that writes the envelope.
    #     This union carries no blocker by construction, so the flag changes
    #     nothing today; it is here so a stored `severity` this verb never wrote
    #     cannot make `plan` refuse a document `defer` would happily encode.
    #
    # The one cut it does NOT mirror is the MAX_FINDINGS truncation, which can
    # also discard a malformed row before `_encode_aggregate` sees it. That one is
    # not reproducible at plan time -- its membership depends on the surviving
    # blockers and the un-applied lens rows, and neither exists yet -- and the row
    # it would have hidden is malformed either way. Refusing loudly on attempt N
    # beats being saved by a ranking accident at the end of the run.
    _encode_aggregate(_drop_unfilable(union)[0], pr_number, run_id, allow_blockers=True)

    classified = {
        "schema_version": SCHEMA_VERSION,
        "attempt": attempt,
        # The SHA this review actually looked at. Without it a stale
        # classified.json -- one a refused re-plan left behind -- is
        # indistinguishable from a fresh one, and the gate would answer for code
        # that no longer exists. `assert-green --head-sha` refuses on mismatch.
        "head_sha": head_sha,
        "level": level,
        "pr_number": pr_number,
        "run_id": run_id,
        "counts": {
            "total": len(findings),
            "blocker": len(blockers),
            "suggestion": len(suggestions),
            # How many severities were machine-checked rather than judged. The
            # run summary prints this so an operator can see at a glance whether
            # the reviewer gave us categories on this invocation or not.
            "category_backed": sum(
                1 for f in findings if f["severity_source"] == "category"
            ),
            # Suggestions this attempt inherited from earlier ones. Reported so
            # "we filed 9 suggestions" can be told apart from "this review found
            # 9 suggestions" -- under a loop those are different numbers.
            "suggestion_carried": carried_count,
        },
        "blockers": blockers,
        "suggestions": suggestions,
    }
    classified_bytes = (
        json.dumps(classified, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    )
    waves = _fix_waves(blockers, args.max_per_wave)
    waves_bytes = (
        json.dumps(
            {"schema_version": SCHEMA_VERSION, "waves": waves},
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )

    # Two writes of the same bytes, on purpose.
    #
    # The unsuffixed name is the CURRENT pointer every fence and the gate already
    # read; the `-NN` name is that attempt's evidence, and it is what makes the
    # loop's progress claim checkable after the fact. Overwriting one file per
    # attempt -- which is what the pre-loop pipeline did -- destroys the only
    # record of what the previous attempt actually saw.
    #
    # NOT an `attempt-NN/` subdirectory: agents/findings-to-issues.md derives the
    # run id from the aggregate's PARENT directory basename and validates it
    # against the run-id shape, so an aggregate one level deeper is refused.
    suffix = "%02d" % attempt
    for name, payload in (
        ("classified.json", classified_bytes),
        ("classified-%s.json" % suffix, classified_bytes),
        ("fix-waves.json", waves_bytes),
        ("fix-waves-%s.json" % suffix, waves_bytes),
    ):
        _atomic_write(os.path.join(out_dir, name), payload)

    # NO `suggestions-aggregate.md`. This verb used to encode the cross-attempt
    # union into one, on every attempt -- up to eight rewrites per run of a file
    # with no reader anywhere: `defer` never opens it, the SKILL's Phase 5
    # dispatch names `deferred-aggregate.md`, and tests/premerge.test.sh asserts
    # the SKILL can never name this one as an `aggregate_path`.
    #
    # It was worse than idle. The one time a run DID dispatch it, it filed only
    # the suggestion rows: surviving blockers and un-applied simplify-lens rows
    # do not exist yet when `plan` runs, and those two losses are the whole
    # reason `cmd_defer` was written. A published file that looks like the
    # aggregate and is missing the rows that matter is a trap, and the cheapest
    # way to disarm it is to not publish it. Nothing is lost: every attempt's
    # suggestions stay on disk in its own `classified-NN.json`, which is what
    # `_carry_prior_suggestions` reads, and that is what makes the union
    # reconstructible at defer time.
    #
    # WHAT STOPPED IS THE PUBLISHING, NOT THE VALIDATION. The union still goes
    # through `_encode_aggregate` on every attempt, above, with its bytes
    # discarded -- see that comment for why moving that check to Phase 5 was the
    # maximal-loss timing and why the plan-side copy is deliberately no stricter.
    #
    # `defer` writes the run's ONE aggregate, once, after the loop settles --
    # which is also what keeps `agents/findings-to-issues.md` happy: it re-checks
    # its input's (device, inode, size, mtime) between parsing and its first
    # GitHub write, and `os.replace` under a dispatch in flight changes the inode
    # and makes it refuse.

    # The one line the fence reads. Emitted on stdout so a caller that only
    # wants the counts never has to parse the artifacts.
    #
    # The first five fields are a pinned prefix (tests/premerge-findings.test.sh
    # matches on it): append, never reorder or insert.
    print(
        "PREMERGE_TRIAGE TOTAL=%d BLOCKER=%d SUGGESTION=%d WAVES=%d CATEGORY_BACKED=%d"
        " ATTEMPT=%d CARRIED=%d"
        % (
            len(findings),
            len(blockers),
            len(suggestions),
            len(waves),
            classified["counts"]["category_backed"],
            attempt,
            carried_count,
        )
    )
    return 0


def cmd_assert_green(args: argparse.Namespace) -> int:
    """The gate that stands between the fix loop and the simplify fanout.

    Fails CLOSED on every unreadable or unrecognised input. A gate that answers
    "green" when it could not read its evidence is not a gate.
    """
    document = _load(args.classified)
    if not isinstance(document, dict) or document.get("schema_version") != SCHEMA_VERSION:
        fail("input_schema_invalid", "classified.json is not a v1 document")
    blockers = document.get("blockers")
    if not isinstance(blockers, list):
        fail("input_schema_invalid", "classified.json has no blockers array")

    reasons = []
    if blockers:
        reasons.append("blockers_remaining=%d" % len(blockers))

    # ---- is this evidence about the code that is on the branch RIGHT NOW? ----
    # A refused re-plan (a >64-finding review, a finding the reviewer emitted
    # twice, any schema refusal) exits before writing anything, leaving the
    # PREVIOUS attempt's classified.json in place. Without this check the gate
    # answers for code that no longer exists, and can call a stack green whose
    # latest review it never managed to read. Opt-in so pre-loop callers are
    # unaffected; once opted in an unstamped document is a refusal, not a pass.
    if args.head_sha is not None:
        if not _SHA1_RE.match(args.head_sha):
            fail("bad_head_sha", "head-sha must be 40 lowercase hex characters")
        recorded = document.get("head_sha")
        if not isinstance(recorded, str) or not _SHA1_RE.match(recorded):
            fail("evidence_unstamped", "classified.json records no head_sha to check")
        if recorded != args.head_sha:
            reasons.append("stale_evidence")

    ci = args.ci_state
    if ci not in ("green", "no_checks", "red", "pending", "unknown"):
        fail("bad_ci_state", ci)
    if args.require_ci and ci not in ("green", "no_checks"):
        reasons.append("ci=%s" % ci)
    # `no_checks` means green ONLY when nothing has just been pushed.
    #
    # A push restarts checks and test.yml fires on both `push` and
    # `pull_request` with nothing cancelling the loser, so for ~10-30s after a
    # push `gh pr checks` legitimately answers with no checks at all. Reading
    # that as green is a pass on a build that has not started -- the race RFC
    # 0021 §9 documented in prose and deferred a structural fix for. Under the
    # loop it stops being an edge case: every attempt ends in a push.
    elif args.require_ci and ci == "no_checks" and args.after_push:
        reasons.append("ci=no_checks_after_push")

    mergeable = args.mergeable
    if mergeable not in ("MERGEABLE", "CONFLICTING", "UNKNOWN"):
        fail("bad_mergeable", mergeable)
    if mergeable == "CONFLICTING":
        reasons.append("mergeable=CONFLICTING")
    elif mergeable == "UNKNOWN":
        # UNKNOWN is not a pass -- it is "we could not read this".
        #
        # The fence maps a FAILED `gh pr view` onto UNKNOWN, so accepting it made
        # a probe error indistinguishable from a clean stack: the one
        # unreadable-evidence state this gate answered green on, contradicting
        # its own docstring. The loop widens the window rather than narrowing it,
        # because every attempt pushes and GitHub recomputes mergeability after
        # each push.
        #
        # Waitable, not fatal: `converge` routes it to WAIT_CI, which re-probes
        # without spending a repair and is bounded, so a mergeability that never
        # resolves ends the run not-green instead of passing.
        reasons.append("mergeable=unknown")

    if reasons:
        print("PREMERGE_GATE VERDICT=not_green REASONS=%s" % ",".join(reasons))
        return 1
    print("PREMERGE_GATE VERDICT=green REASONS=none")
    return 0


def cmd_defer(args: argparse.Namespace) -> int:
    """Write the ONE aggregate Phase 5 files, covering everything left unfixed.

    THE PRODUCER THAT DID NOT EXIST. Two `/premerge` promises had no writer
    behind them, and both failed silently rather than loudly:

      * Phase 4 said un-applied simplify-lens findings were filed. Nothing could
        encode them -- `plan` reads the built-in reviewer's contract and requires
        a `failure_scenario` that a `code-simplifier` lens never emits.
      * A blocker the loop stopped on was printed in the run summary and lost.
        The one finding the machine could NOT handle was the one finding that
        did not outlive the run.

    Both are the same shape as the bug this file's own docstring is about: a
    claim nobody could contradict. So this verb exists, and it is the only
    caller allowed to put a `blocker` row in a `premerge-aggregate` envelope.

    `agents/findings-to-issues.md` already anticipates that row --
    `severity_rank(blocker)=3` sorts it above every cleanup row so a `max_new`
    overflow can never displace it, and its Step 8d gives it the @author-mention
    shape. Nothing there needed changing; it was waiting for a producer.
    """
    run_dir = args.run_dir
    if not os.path.isdir(run_dir):
        fail("output_unsafe", f"run-dir does not exist: {run_dir}")
    attempt = args.attempt
    # Same widened bound as `plan`: Phase 5 defers at the index Phase 4c
    # advanced to, so a run that spent its whole repair budget defers at
    # CONVERGE_REPAIR_CEILING + 2. See CONVERGE_VERIFY_CEILING.
    if not 1 <= attempt <= CONVERGE_VERIFY_CEILING:
        fail("bad_attempt", f"attempt must be 1..{CONVERGE_VERIFY_CEILING}")

    # FALL BACK TO THE NEWEST READABLE ATTEMPT RATHER THAN FILING NOTHING.
    #
    # `## Phase 2` makes a refused `plan` a hard stop for the attempt while
    # leaving PREMERGE_ATTEMPT at N, so `classified-0N.json` is legitimately
    # absent at the index Phase 5 defers from -- and a required read there exits
    # 74 behind the fence's `|| exit 74`, costing every surviving blocker and
    # every cleanup finding the run had already classified. That is the maximal
    # loss the `#### When the envelope overflows` arm exists to prevent,
    # arriving through a different door.
    #
    # The walk is tolerant on the way down for the same reason
    # `_carry_prior_suggestions` is: one corrupt artifact must not cost the
    # readable ones behind it. It refuses only when NO attempt at or below the
    # index can be read -- there is genuinely nothing to file then.
    document = None
    defer_attempt = attempt
    for candidate in range(attempt, 0, -1):
        try:
            document = _read_attempt(run_dir, candidate, required=False)
        except Refusal:
            document = None
        if document is not None:
            defer_attempt = candidate
            break
    if document is None:
        fail("attempt_evidence_missing", _attempt_path(run_dir, attempt))
    if defer_attempt != attempt:
        print(
            "premerge-findings: attempt_fallback: "
            f"{_attempt_path(run_dir, attempt)} is unusable; "
            f"deferring from attempt {defer_attempt}",
            file=sys.stderr,
        )

    # THE SAME UNION `plan --carry-prior` COMPUTES, because this is the aggregate
    # that actually gets dispatched.
    #
    # `plan` used to union every attempt's cleanup findings into a
    # `suggestions-aggregate.md` of its own while this verb read one attempt's
    # `suggestions` array into `deferred-aggregate.md` -- and SKILL.md
    # `### 5-file` hands findings-to-issues the `defer` PATH. So the union was
    # computed, tested, and then filed from the wrong file: a suggestion raised
    # on attempt 1 and not repeated on attempt 3 is unmentioned, not resolved,
    # and it was silently dropped -- the exact loss `--carry-prior` exists to
    # prevent.
    #
    # `_union_suggestions` is now the ONE implementation both verbs call, and
    # there is only ONE aggregate file left -- this one. "The aggregates cannot
    # disagree about which findings survived the run" is a property of the code
    # rather than a sentence asking you to believe two copies still match.
    #
    # `_read_attempt` proves these are ARRAYS; nothing proved their elements were
    # objects, and every line below calls `.get()` on them. Same class as the
    # unchecked `pr_number`: an `AttributeError` is not the contracted exit 74.
    rows = _union_suggestions(
        _object_rows(document["suggestions"], "suggestion"),
        _carry_prior_suggestions(run_dir, attempt),
    )

    if args.include_blockers:
        rows.extend(_object_rows(document["blockers"], "blocker"))

    if args.lens_findings is not None:
        rows.extend(_normalise_lens_findings(_load(args.lens_findings)))

    # A ROW WITH NO USABLE PATH IS DROPPED ON EVERY RUN, NOT ONLY AN OVERFLOWING
    # ONE.
    #
    # This cut used to live inside the `len(rows) > MAX_FINDINGS` branch below,
    # so the ORDINARY under-cap run -- the common case, and the one Phase 5
    # reaches on nearly every stack -- had no protection whatsoever: five
    # suggestions plus one blocker whose `file` is an object exited 74 out of
    # `_encode_aggregate`, behind the fence's `defer "$@" || exit 74` with no
    # recovery arm, and the run filed NOTHING. `_defer_groups`' docstring
    # asserted unconditionally that such a row "cannot become an issue under any
    # ranking", but ranking only ever happened above 64 rows, so the guarantee
    # read as covered while the common path lost everything.
    #
    # A row the filer cannot turn into an issue is worth exactly as little at 6
    # rows as it is at 70, and the envelope it takes down with it is worth
    # exactly as much. So the cut is unconditional, which is also what makes the
    # ranking below simpler: no group reaching it can be keyed on a sentinel.
    #
    # DROPPED AND COUNTED. These rows land in `OVERFLOW=`, so an under-cap run
    # that discarded something still says so on its output line -- the same
    # "dropped and reported" the truncation below owes.
    #
    # `_encode_aggregate` is untouched by this and stays the single gate: a row
    # whose `file` IS a usable string but is still malformed (an absolute path, a
    # missing `failure_scenario`) survives here and refuses there, exactly as it
    # always did.
    rows, overflow = _drop_unfilable(rows)
    # Grouped AFTER the cut, never before it: the cut renumbered every row behind
    # the first drop, and the ranking below indexes `rows` by exactly these
    # positions.
    groups = _defer_groups(rows)

    # OVERFLOW IS SURVIVABLE, BECAUSE THIS IS THE STEP THAT MUST NOT LOSE THINGS.
    #
    # This used to `fail(...)` above MAX_FINDINGS, and the Phase 5 fence is
    # `defer "$@" || exit 74` with no recovery arm -- so a long run reached the
    # one step whose entire purpose is "a thing the machine could not fix must
    # outlive the run" and filed NOTHING. Refusing to drop 5 rows by dropping all
    # 69 is not the conservative choice; it is the maximal-loss one, and it is
    # reachable by ordinary means (up to 8 attempts each contributing new unique
    # fingerprints, plus surviving blockers, plus every un-applied lens row --
    # `cmd_plan` caps one review's `findings` array and caps the cross-attempt
    # union not at all).
    #
    # So: keep the rows that matter most, say how many did not fit, and exit 0 so
    # the caller can still dispatch. Blocker-bearing FILES first -- a surviving
    # blocker is the single row this verb exists to preserve, and
    # `findings-to-issues` ranks it above every cleanup row for the same reason.
    #
    # The unit is the FILE rather than the row (#722) because that agent now
    # opens one issue per file, so a cleanup file is displaced before any part of
    # a blocker file is. What the file unit no longer promises is that a blocker
    # always survives: blocker-bearing files whose rows together exceed the
    # envelope now cost each other, where a row cut would have kept every blocker
    # and dropped only cleanup. That is the price of not filing an issue that
    # reads as complete and is not, and `OVERFLOW=` reports it either way.
    #
    # NOT silent: `OVERFLOW=<n>` is on the output line, always, and the fence is
    # required to surface it. "Dropped and reported" is a different thing from
    # "dropped"; what the old refusal actually protected was the appearance of
    # rigour, at the cost of the guarantee.
    #
    # Kept rows stay in their ORIGINAL relative order, so the only observable
    # difference from an under-cap run is which rows are absent -- downstream's
    # first-occurrence-wins dedupe sees the same ordering it always did.
    if len(rows) > MAX_FINDINGS:
        # No sentinel term here: the unusable-path cut above already removed
        # every group the filer could open no issue for, on this run and on an
        # under-cap one alike. A term for them here would be permanently dead,
        # and a dead guard carrying a comment that says it is load-bearing is
        # how the under-cap hole stayed invisible in the first place.
        ranked = sorted(
            range(len(groups)),
            key=lambda i: (
                0
                if any(rows[j].get("severity") == "blocker" for j in groups[i][1])
                else 1,
                i,
            ),
        )
        # WHOLE FILES WHILE THEY FIT, THEN ONE SPLIT FILE -- NOT A HARD STOP.
        #
        # Row-filling the first file that does not fit is what makes file-atomic
        # truncation affordable. Stop dead at that file instead and a 4-row file,
        # two 30-row files and a 5-row blocker file -- 69 rows against a 64-row
        # envelope -- file 39 rows where the row cut this replaces files 64.
        # Losing 25 more findings to avoid splitting one file is the same
        # maximal-loss trade the refusal this branch replaced was making, wearing
        # a better argument.
        #
        # So exactly ONE file is ever split, it is the highest-priority file that
        # did not fit, and no lower-priority file jumps the cut: the fill spends
        # the rest of the budget, so the `break` is arithmetic rather than policy.
        # One file bigger than the whole envelope needs no arm of its own -- it is
        # this same rule with no whole file admitted ahead of it.
        keep: "set[int]" = set()
        used = 0
        for index in ranked:
            members = groups[index][1]
            if used + len(members) <= MAX_FINDINGS:
                keep.update(members)
                used += len(members)
                continue
            room = MAX_FINDINGS - used
            if room:
                # Blockers first WITHIN the split file, for the same reason they
                # come first between files: blockers are appended to `rows` last,
                # so a plain leading run of a mixed file would keep its cleanup
                # and drop the one row this verb exists to preserve. This orders
                # the SELECTION only; the rebuild below restores original order.
                fill = sorted(
                    members,
                    key=lambda j: (
                        0 if rows[j].get("severity") == "blocker" else 1,
                        j,
                    ),
                )
                keep.update(fill[:room])
            break
        # `+=`, not `=`: `rows` is already the post-unusable-cut list, so the
        # rows that cut discarded are counted once here and never recounted.
        overflow += len(rows) - len(keep)
        rows = [row for index, row in enumerate(rows) if index in keep]

    out_path = os.path.join(run_dir, "deferred-aggregate.md")
    _atomic_write(
        out_path,
        _encode_aggregate(rows, document["pr_number"], document["run_id"], allow_blockers=True),
    )
    blockers = sum(1 for r in rows if r.get("severity") == "blocker")
    # This re-derivation stays BELOW the write on purpose, and hoisting it is a
    # regression even though it looks like a hardening. `_encode_aggregate` is
    # the gate: it is evaluated as `_atomic_write`'s argument, so it refuses a
    # malformed surviving row BEFORE the write is entered and nothing lands on
    # disk. Move this line above the write and it becomes a SECOND gate that can
    # refuse first -- which sounds safer and is not, because it means weakening
    # `_encode_aggregate` no longer changes anything observable and the "refused
    # before publishing" property stops being testable. Left here, it is a
    # backstop that guarantees rc != 0 either way, and B31 pins the order by
    # asserting no aggregate exists after the refusal.
    files = len({_repo_path(r.get("file")) for r in rows})
    # TOTAL/BLOCKER/SUGGESTION count what is IN the file; FILES is how many
    # distinct owning files those rows cover -- the file GROUPS the downstream
    # dispatch will consider now that it groups by file. It gets to at most
    # `max_new` (10) of them in a run: a group it takes either opens a new issue
    # or is commented onto an existing issue carrying the same container
    # fingerprint, and the groups past that cap are not filed AT ALL -- the filer
    # records them as its own `overflow_count`, they wait for a later run, and a
    # blocker- or critical-tier group stranded in that tail escalates to
    # `halted_due_to_overflow`. So FILES is an upper bound on the issues the
    # dispatch touches and never a count of them, and a FILES above `max_new`
    # says outright that some of these files do not get filed today.
    # OVERFLOW is this command's OWN cut -- rows that did not fit MAX_FINDINGS,
    # dropped before the filer ever sees them, and a different number from the
    # filer's `overflow_count` -- so TOTAL+OVERFLOW is everything the run had to
    # file.
    # `PATH=` stays LAST because a run dir may contain spaces -- a field appended
    # after it makes the path unparseable, so new fields are inserted before it,
    # never appended. FILES= specifically goes BEFORE OVERFLOW= so the fence's
    # existing `${HEAD##* OVERFLOW=}` suffix read stays exact.
    print(
        "PREMERGE_DEFER TOTAL=%d BLOCKER=%d SUGGESTION=%d FILES=%d OVERFLOW=%d PATH=%s"
        % (len(rows), blockers, len(rows) - blockers, files, overflow, out_path)
    )
    return 0


def cmd_converge(args: argparse.Namespace) -> int:
    """Decide whether the fix loop takes another attempt, and record why.

    This verb is the whole difference between "keep fixing until it is green"
    and a machine that grinds a stack into rubble. It never looks at code and it
    never guesses: it compares this attempt's blocker fingerprints against the
    previous attempt's, compares the non-blocker gate reasons against the ones
    the previous attempt recorded, and answers from the closed
    `CONVERGE_DECISIONS` vocabulary.

    Exit status is the branch a shell fence needs and nothing more:
    0 -- take another attempt (`CONTINUE` or `WAIT_CI`); 1 -- stop, and read
    `DECISION=` on stdout to find out whether stopping was the good kind.
    """
    run_dir = args.run_dir
    if not os.path.isdir(run_dir):
        fail("output_unsafe", f"run-dir does not exist: {run_dir}")

    attempt = args.attempt
    max_repairs = args.max_repairs
    # N repairs cost N+1 reviews, so the last legal attempt index is one past the
    # repair budget: that review is the one that verifies the final repair.
    if not 1 <= attempt <= CONVERGE_REPAIR_CEILING + 1:
        fail("bad_attempt", f"attempt must be 1..{CONVERGE_REPAIR_CEILING + 1}")
    if not 1 <= max_repairs <= CONVERGE_REPAIR_CEILING:
        fail("bad_max_repairs", f"max-repairs must be 1..{CONVERGE_REPAIR_CEILING}")
    if attempt > max_repairs + 1:
        fail("bad_attempt", f"attempt {attempt} is past the {max_repairs}-repair budget")
    if args.verdict not in ("green", "not_green"):
        fail("bad_verdict", args.verdict)
    if not 0 <= args.wait_passes <= CONVERGE_WAIT_CI_CEILING:
        fail("bad_wait_passes", f"wait-passes must be 0..{CONVERGE_WAIT_CI_CEILING}")

    reasons = _reason_tokens(args.reasons)
    if args.verdict == "green" and reasons:
        # The two halves of the gate's own output must agree. A caller that
        # reports green while forwarding failing reasons has mis-parsed the gate,
        # and resolving that disagreement by picking one is how a red stack ships.
        fail("verdict_contradicts_reasons", ",".join(reasons))

    current = _read_attempt(run_dir, attempt, required=True)
    # REQUIRED, exactly as `_read_attempt`'s docstring demands.
    #
    # This used to pass `required=False`, so a predecessor whose evidence was
    # absent or unreadable -- a truncated write, a cleaned run dir, an interrupted
    # attempt -- summarised as `previous_prints = None`, i.e. `fixed=0` and
    # `appeared=current_total`. Both STOP_REGRESSED and STOP_NO_PROGRESS are then
    # structurally unreachable for that attempt and the loop runs to its counter
    # backstop instead of noticing that repairing stopped working: precisely the
    # "reads as progress and would let the loop run on" outcome the docstring
    # forbids. Attempt 1 legitimately has no predecessor; every later attempt has
    # one, because `plan` wrote it before the gate could run.
    previous = _read_attempt(run_dir, attempt - 1, required=True) if attempt > 1 else None

    current_prints = _blocker_fingerprints(current)
    previous_prints = _blocker_fingerprints(previous) if previous is not None else None

    current_total = sum(current_prints.values())
    if previous_prints is None:
        previous_total = None
        fixed, appeared = 0, current_total
    else:
        previous_total = sum(previous_prints.values())
        fixed = sum((previous_prints - current_prints).values())
        appeared = sum((current_prints - previous_prints).values())

    # Everything the gate complained about EXCEPT the blocker count. The blocker
    # term is already represented, far more precisely, by the fingerprint sets;
    # keeping it here too would make an unchanged CI reason look changed every
    # time one blocker of five got fixed.
    other = frozenset(t for t in reasons if not t.startswith("blockers_remaining="))
    # How many times THIS attempt has already been told to wait.
    #
    # DERIVED from the ledger, not trusted from the caller. `--wait-passes` is a
    # floor, not the source of truth: every fence is a fresh shell, so a
    # controller that forgets to thread the counter across the boundary passes 0
    # forever, `wait_passes < CEILING` stays true forever, and WAIT_CI -- which
    # deliberately does not consume a repair -- spins with no reachable backstop.
    # That is an unbounded autonomous loop under a command that promises it will
    # not loop forever. The ledger already records every WAIT_CI row, so the
    # bound can enforce itself rather than depending on caller discipline.
    #
    # ONE read, both reductions. This verb needs two different one-pass answers
    # out of `converge.jsonl` -- this attempt's WAIT_CI count and the previous
    # attempt's last row -- and each reducer used to open and re-parse the whole
    # ledger for itself. Read it here, where the argument validation and the
    # attempt-evidence reads above have already had their chance to refuse, so
    # the order in which failures surface is unchanged.
    ledger_rows = _read_converge_rows(run_dir)
    observed_waits = _count_wait_rows(ledger_rows, attempt)
    wait_passes = max(args.wait_passes, observed_waits)

    last_row = _last_converge_row(ledger_rows, attempt - 1) if attempt > 1 else None
    previous_other = (
        frozenset(last_row.get("reasons_other") or []) if isinstance(last_row, dict) else None
    )

    # Every gate term this loop has no route for: `stale_evidence`, which is
    # unrepairable by definition, plus anything a fence invented that
    # GATE_REASONS_ROUTABLE has never heard of -- `gate_unreadable` above all,
    # which the Phase 3 fence writes whenever `assert-green` exits non-0/1. A term
    # with no route is a STOP_UNREADABLE, never a fall-through to CONTINUE.
    unroutable = frozenset(t for t in other if t not in GATE_REASONS_ROUTABLE)

    if args.verdict == "green":
        decision = "STOP_GREEN"
    elif unroutable:
        decision = "STOP_UNREADABLE"
    elif not current_prints and other and other <= GATE_REASONS_WAITABLE:
        # Nothing to fix and the only complaint is a build that has not answered.
        # Waiting deliberately does NOT consume an attempt -- a slow CI must not
        # eat the fix budget -- so it needs its own bound or a check that never
        # settles would spin forever.
        decision = "WAIT_CI" if wait_passes < CONVERGE_WAIT_CI_CEILING else "STOP_UNREADABLE"
    elif previous_total is not None and appeared > 0 and fixed == 0:
        # REGRESSION = "new blockers appeared and we cleared none", not "the
        # count went up".
        #
        # The built-in reviewer's output is capped and ranked most-severe-first,
        # so clearing the top blockers routinely surfaces ones the cap had cut.
        # A raw `current > previous` test reads that as "our own fixes made it
        # worse" and stops a loop that just succeeded, with budget unspent --
        # telling the operator the machine broke the stack at the exact moment it
        # removed a blocker. Requiring `fixed == 0` keeps the honest case (we
        # fixed nothing and broke something) and drops the cap-churn false
        # positive.
        decision = "STOP_REGRESSED"
    elif (
        previous_prints is not None
        and current_prints == previous_prints
        and previous_other is not None
        and other == previous_other
    ):
        decision = "STOP_NO_PROGRESS"
    elif attempt > max_repairs:
        # Strictly greater: attempt N is the review that verifies repair N-1, so
        # the budget is spent only once we are past it. `>=` here is the
        # off-by-one that makes --converge=1 buy zero repairs.
        decision = "STOP_EXHAUSTED"
    else:
        decision = "CONTINUE"

    if decision not in CONVERGE_DECISIONS:  # pragma: no cover - structural guard
        fail("bad_decision", decision)

    _append_converge_row(
        run_dir,
        {
            "attempt": attempt,
            "blockers": current_total,
            "decision": decision,
            "fixed": fixed,
            "head_sha": current.get("head_sha"),
            "max_repairs": max_repairs,
            "new": appeared,
            "previous_blockers": previous_total,
            "reasons": reasons,
            "reasons_other": sorted(other),
            "schema_version": SCHEMA_VERSION,
            "wait_passes": wait_passes,
        },
    )

    print(
        "PREMERGE_CONVERGE ATTEMPT=%d DECISION=%s BLOCKERS=%d PREV=%s FIXED=%d NEW=%d"
        " WAIT=%d MAXREPAIRS=%d REASONS=%s"
        % (
            attempt,
            decision,
            current_total,
            "-" if previous_total is None else str(previous_total),
            fixed,
            appeared,
            wait_passes,
            max_repairs,
            ",".join(reasons) if reasons else "none",
        )
    )
    return 0 if decision in CONVERGE_CONTINUE else 1


def main(argv: "list[str]") -> int:
    parser = argparse.ArgumentParser(prog="premerge-findings.py", add_help=True)
    sub = parser.add_subparsers(dest="verb", required=True)

    plan = sub.add_parser("plan", help="classify code-review findings and plan the fix waves")
    plan.add_argument("--input", required=True)
    plan.add_argument("--out-dir", required=True)
    plan.add_argument("--max-per-wave", type=int, default=8)
    plan.add_argument("--attempt", type=int, default=1)
    plan.add_argument("--head-sha", default=None)
    plan.add_argument("--carry-prior", action="store_true")
    plan.set_defaults(handler=cmd_plan)

    gate = sub.add_parser("assert-green", help="the pre-simplify clean gate")
    gate.add_argument("--classified", required=True)
    gate.add_argument("--ci-state", required=True)
    gate.add_argument("--mergeable", default="UNKNOWN")
    gate.add_argument("--require-ci", action="store_true")
    gate.add_argument("--head-sha", default=None)
    gate.add_argument("--after-push", action="store_true")
    gate.set_defaults(handler=cmd_assert_green)

    defer = sub.add_parser("defer", help="encode everything the run could not fix, for issue filing")
    defer.add_argument("--run-dir", required=True)
    defer.add_argument("--attempt", type=int, required=True)
    defer.add_argument("--include-blockers", action="store_true")
    defer.add_argument("--lens-findings", default=None)
    defer.set_defaults(handler=cmd_defer)

    loop = sub.add_parser("converge", help="decide whether the fix loop takes another attempt")
    loop.add_argument("--run-dir", required=True)
    loop.add_argument("--attempt", type=int, required=True)
    loop.add_argument("--max-repairs", type=int, required=True)
    loop.add_argument("--verdict", required=True)
    loop.add_argument("--reasons", default="none")
    loop.add_argument("--wait-passes", type=int, default=0)
    loop.set_defaults(handler=cmd_converge)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
