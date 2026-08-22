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

# The cleanup half of the built-in reviewer's own angle vocabulary. Its prompt
# states the precedence this set encodes, verbatim: "Correctness bugs always
# outrank cleanup, altitude, and conventions findings when the output cap forces
# a cut." So the mapping below is not an uberdev invention layered on top -- it
# is that sentence, made executable.
#
# Membership, not exhaustiveness, is what this set claims. A slug the reviewer
# invents that is NOT listed here is treated as correctness-class (blocker
# eligible), which is the fail-loud direction: a novel cleanup slug costs one
# needless fixer dispatch, whereas a novel correctness slug silently demoted to
# `suggestion` would ship the bug.
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

_SHA1_RE = re.compile(r"\A[0-9a-f]{40}\Z")
_ATTEMPT_RE = re.compile(r"\A[0-9]{2}\Z")

# Bounds mirrored from lib/code_fixer_contract.py so a document that passes here
# cannot be rejected downstream for a length the two files disagree about.
MAX_SUMMARY_BYTES = 4096
MAX_DETAIL_BYTES = 16384
MAX_PATH_CHARS = 4096
MAX_LINE = 999_999_999
MAX_FINDINGS = 64

_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def fail(token: str, detail: str = "") -> "NoReturn":  # type: ignore[valid-type]
    message = f"premerge-findings: {token}"
    if detail:
        message = f"{message}: {detail}"
    print(message, file=sys.stderr)
    raise SystemExit(74)


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("ascii")


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
    """Line-independent, punctuation-independent identity text for a finding."""
    folded = " ".join(_FINGERPRINT_STRIP.sub("", summary).split()).casefold()
    return folded.rstrip(".!?;:, ")


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

    DELIBERATELY NOT the same fingerprint `agents/findings-to-issues.md` Step 8a
    computes. That one is `file:line:summary` because an ISSUE is about a
    location, and two bugs on two lines of one file deserve two issues. This one
    must survive exactly the line movement that one is keyed on. Same 16-hex
    width, different question -- never substitute one for the other.
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

    seen: "set[tuple[str, int | None]]" = set()
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

        # Uniqueness is (file, line) when there IS a line, and (file,
        # fingerprint) when there is not.
        #
        # `line` is optional in both reviewer contracts, so two line-less
        # findings in one file used to collide on `(path, None)` and refuse the
        # whole document. Under the loop that refusal is unrecoverable: `plan`
        # exits before writing, the gate then reads a missing artifact, and
        # `converge` aborts on `attempt_evidence_missing` -- the entire run dies
        # because the reviewer omitted a line number. Two line-less findings with
        # different summaries are two findings; only genuine duplicates collide.
        key = (
            (entry["file"], entry["line"])
            if entry["line"] is not None
            else (entry["file"], entry["fingerprint"])
        )
        if key in seen:
            fail(
                "findings_not_unique",
                f"two findings share {entry['file']}:{entry['line']}",
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
    """
    findings = []
    for finding in rows:
        # The row's OWN severity, not a hardcoded one.
        #
        # It used to be pinned to "suggestion", which is correct for the
        # per-attempt cleanup aggregate and is why `plan` still passes
        # `allow_blockers=False`. But it also meant `/premerge` had no way to
        # file the one finding that matters most -- a blocker the loop could not
        # clear -- so that finding was printed into a summary and lost. A promise
        # with no producer is the defect this command already shipped once; the
        # fix is a producer, not a louder promise.
        severity = finding.get("severity", "suggestion")
        if severity not in SEVERITIES:
            fail("aggregate_severity_invalid", str(severity))
        if severity == "blocker" and not allow_blockers:
            fail("aggregate_blocker_not_allowed", finding["file"])
        findings.append(
            {
                "detail": finding["failure_scenario"],
                "scope": {
                    "line": finding["line"] if finding["line"] is not None else 1,
                    "operation": "modify_existing",
                    "path": finding["file"],
                },
                "severity": severity,
                "source_edges": ["premerge.review.code_review"],
                "summary": finding["summary"],
            }
        )
    document = {
        "contributors": [
            {
                "confidence": "n/a",
                "id": "premerge.review.code_review",
                "verdict": "COMPLETE",
            }
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
    return document


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
    """Every earlier attempt's suggestions, oldest first."""
    carried: "list[dict]" = []
    for earlier in range(1, attempt):
        document = _read_attempt(out_dir, earlier, required=False)
        if document is None:
            continue
        for record in document["suggestions"]:
            if isinstance(record, dict) and isinstance(record.get("fingerprint"), str):
                carried.append(record)
    return carried


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


def _count_wait_rows(run_dir: str, attempt: int) -> int:
    """How many WAIT_CI decisions this attempt has already recorded."""
    return sum(
        1
        for row in _read_converge_rows(run_dir)
        if row.get("attempt") == attempt and row.get("decision") == "WAIT_CI"
    )


def _read_converge_rows(run_dir: str) -> "list[dict]":
    """Every ledger row, in order. Refuses rather than degrading.

    A ledger we cannot parse is NOT an empty ledger. Returning `[]` on a parse
    error would make "no history recorded" indistinguishable from "the history
    says nothing changed" -- the difference between CONTINUE and
    STOP_NO_PROGRESS, and between a bounded WAIT_CI and an unbounded one.
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
    for line in lines:
        try:
            row = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail("input_not_json", f"{ledger}: {exc}")
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _read_converge_row(run_dir: str, attempt: int) -> "dict | None":
    """The last ledger row recorded for one attempt.

    A SCAN, not a peek at the tail. `WAIT_CI` deliberately does not consume a
    repair, so it appends further rows under the SAME attempt number -- and a
    tail-only reader would then see attempt N where it expected N-1, conclude
    that no previous reasons were recorded, and lose the ability to ever answer
    STOP_NO_PROGRESS. The loop would run to its backstop on every CI hiccup.
    """
    found = None
    for row in _read_converge_rows(run_dir):
        if row.get("attempt") == attempt:
            found = row
    return found


def _normalise_lens_findings(records: object) -> "list[dict]":
    """Translate `code-simplifier` lens output into the aggregate's row shape.

    The lens contract is `{location: "path:line", severity, lens, summary,
    detail}` — no `failure_scenario`, which is why routing lens findings through
    `plan` is impossible rather than merely inconvenient. `detail` carries the
    rationale, so it becomes the row's detail, and the lens name is prefixed onto
    the summary so the issue says which of the three raised it.

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
        line = None
        if raw_line.isdigit() and 1 <= int(raw_line) <= MAX_LINE:
            line = int(raw_line)
        lens = record.get("lens")
        if lens is not None and not isinstance(lens, str):
            fail("finding_schema_invalid", f"lens finding {index} has a non-string lens")
        summary = _bounded_text(
            record.get("summary"), MAX_SUMMARY_BYTES, "finding_schema_invalid",
            f"lens finding {index} summary",
        )
        out.append(
            {
                "file": _repo_path(raw_path),
                "line": line,
                "summary": f"{lens}: {summary}" if lens else summary,
                "failure_scenario": _bounded_text(
                    record.get("detail"), MAX_DETAIL_BYTES, "finding_schema_invalid",
                    f"lens finding {index} detail",
                ),
                "severity": "suggestion",
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

    pr_number = document.get("pr_number")
    if isinstance(pr_number, bool) or not isinstance(pr_number, int) or pr_number <= 0:
        fail("input_schema_invalid", "pr_number must be a positive integer")

    run_id = document.get("run_id")
    if not isinstance(run_id, str) or not re.fullmatch(
        r"[0-9]{8}-[0-9]{6}-[0-9a-f]+", run_id
    ):
        fail("input_schema_invalid", "run_id must match YYYYMMDD-HHMMSS-<hex>")

    findings = _normalise_findings(document.get("findings"))
    blockers = [f for f in findings if f["severity"] == "blocker"]
    suggestions = [f for f in findings if f["severity"] == "suggestion"]

    out_dir = args.out_dir
    if not os.path.isdir(out_dir):
        fail("output_unsafe", f"out-dir does not exist: {out_dir}")

    attempt = args.attempt
    if not 1 <= attempt <= CONVERGE_REPAIR_CEILING + 1:
        fail("bad_attempt", f"attempt must be 1..{CONVERGE_REPAIR_CEILING + 1}")

    head_sha = args.head_sha
    if head_sha is not None and not _SHA1_RE.match(head_sha):
        fail("bad_head_sha", "head-sha must be 40 lowercase hex characters")

    # Suggestions accumulate across attempts; blockers do not.
    #
    # A blocker is a thing the loop is actively removing, so only the LATEST
    # review's blocker set is meaningful. A suggestion is never fixed by the
    # loop, so a suggestion the reviewer mentioned on attempt 1 and did not
    # repeat on attempt 3 is not resolved -- it is unmentioned, and filing only
    # the last pass's list would silently drop it. Union by fingerprint.
    carried = _carry_prior_suggestions(out_dir, attempt) if args.carry_prior else []
    aggregate_suggestions = list(suggestions)
    seen_fp = {s["fingerprint"] for s in aggregate_suggestions}
    for record in carried:
        if record["fingerprint"] not in seen_fp:
            seen_fp.add(record["fingerprint"])
            aggregate_suggestions.append(record)
    carried_count = len(aggregate_suggestions) - len(suggestions)

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

    # The aggregate keeps its single stable name: it is an INPUT to a
    # findings-to-issues dispatch that happens once, after the loop settles, and
    # that agent re-checks the file's (device, inode, size, mtime) between
    # parsing and its first GitHub write. Re-planning while a dispatch is in
    # flight changes the inode and the agent refuses -- which is why the SKILL
    # dispatches it after the last attempt, never inside the loop.
    _atomic_write(
        os.path.join(out_dir, "suggestions-aggregate.md"),
        _encode_aggregate(aggregate_suggestions, pr_number, run_id),
    )

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
    # A refused re-plan (a >64-finding review, a duplicate location, any schema
    # refusal) exits before writing anything, leaving the PREVIOUS attempt's
    # classified.json in place. Without this check the gate answers for code that
    # no longer exists, and can call a stack green whose latest review it never
    # managed to read. Opt-in so pre-loop callers are unaffected; once opted in
    # an unstamped document is a refusal, not a pass.
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
    if not 1 <= attempt <= CONVERGE_REPAIR_CEILING + 1:
        fail("bad_attempt", f"attempt must be 1..{CONVERGE_REPAIR_CEILING + 1}")

    document = _read_attempt(run_dir, attempt, required=True)
    rows = list(document["suggestions"])

    if args.include_blockers:
        rows.extend(document["blockers"])

    if args.lens_findings is not None:
        rows.extend(_normalise_lens_findings(_load(args.lens_findings)))

    if len(rows) > MAX_FINDINGS:
        # Truncating here would silently drop the rows that sorted last, which
        # after `plan`'s union across attempts is arbitrary. Refuse; the caller
        # reports the real count.
        fail("findings_schema_invalid", f"more than {MAX_FINDINGS} deferred rows")

    out_path = os.path.join(run_dir, "deferred-aggregate.md")
    _atomic_write(
        out_path,
        _encode_aggregate(rows, document["pr_number"], document["run_id"], allow_blockers=True),
    )
    blockers = sum(1 for r in rows if r.get("severity") == "blocker")
    print(
        "PREMERGE_DEFER TOTAL=%d BLOCKER=%d SUGGESTION=%d PATH=%s"
        % (len(rows), blockers, len(rows) - blockers, out_path)
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
    previous = _read_attempt(run_dir, attempt - 1, required=False) if attempt > 1 else None

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
    observed_waits = _count_wait_rows(run_dir, attempt)
    wait_passes = max(args.wait_passes, observed_waits)

    last_row = _read_converge_row(run_dir, attempt - 1) if attempt > 1 else None
    previous_other = (
        frozenset(last_row.get("reasons_other") or []) if isinstance(last_row, dict) else None
    )

    # A gate term the loop cannot fix by fixing code, only by waiting.
    waitable = frozenset(
        {"ci=pending", "ci=unknown", "ci=no_checks_after_push", "mergeable=unknown"}
    )

    if args.verdict == "green":
        decision = "STOP_GREEN"
    elif "stale_evidence" in other:
        decision = "STOP_UNREADABLE"
    elif not current_prints and other and other <= waitable:
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
