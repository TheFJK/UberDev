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

NO NETWORK, NO GIT, NO GH. Reads one JSON document, writes three artifacts.
Every failure exits non-zero with a stable token on stderr; nothing here has a
degraded path that yields an empty finding set, because "zero findings" and
"the parse failed" must never be the same observable outcome.
"""

from __future__ import annotations

import argparse
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

        key = (entry["file"], entry["line"])
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
def _encode_aggregate(suggestions: "list[dict]", pr_number: int, run_id: str) -> bytes:
    """One line of canonical JSON inside the untrusted-input envelope.

    Byte shape is deliberately identical to `code_fixer_contract.encode_aggregate`
    (open tag + newline, one compact sorted-key JSON line, newline + close tag +
    newline) so the agent's existing envelope parser reads it with no new arm.
    Only the `source` and the per-finding key set differ, and both are declared.
    """
    findings = []
    for finding in suggestions:
        findings.append(
            {
                "detail": finding["failure_scenario"],
                "scope": {
                    "line": finding["line"] if finding["line"] is not None else 1,
                    "operation": "modify_existing",
                    "path": finding["file"],
                },
                "severity": "suggestion",
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

    classified = {
        "schema_version": SCHEMA_VERSION,
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
        },
        "blockers": blockers,
        "suggestions": suggestions,
    }
    _atomic_write(
        os.path.join(out_dir, "classified.json"),
        json.dumps(classified, indent=2, sort_keys=True).encode("utf-8") + b"\n",
    )

    waves = _fix_waves(blockers, args.max_per_wave)
    _atomic_write(
        os.path.join(out_dir, "fix-waves.json"),
        json.dumps(
            {"schema_version": SCHEMA_VERSION, "waves": waves},
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n",
    )

    _atomic_write(
        os.path.join(out_dir, "suggestions-aggregate.md"),
        _encode_aggregate(suggestions, pr_number, run_id),
    )

    # The one line the fence reads. Emitted on stdout so a caller that only
    # wants the counts never has to parse the artifacts.
    print(
        "PREMERGE_TRIAGE TOTAL=%d BLOCKER=%d SUGGESTION=%d WAVES=%d CATEGORY_BACKED=%d"
        % (
            len(findings),
            len(blockers),
            len(suggestions),
            len(waves),
            classified["counts"]["category_backed"],
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

    ci = args.ci_state
    if ci not in ("green", "no_checks", "red", "pending", "unknown"):
        fail("bad_ci_state", ci)
    if args.require_ci and ci not in ("green", "no_checks"):
        reasons.append("ci=%s" % ci)

    mergeable = args.mergeable
    if mergeable not in ("MERGEABLE", "CONFLICTING", "UNKNOWN"):
        fail("bad_mergeable", mergeable)
    if mergeable == "CONFLICTING":
        reasons.append("mergeable=CONFLICTING")

    if reasons:
        print("PREMERGE_GATE VERDICT=not_green REASONS=%s" % ",".join(reasons))
        return 1
    print("PREMERGE_GATE VERDICT=green REASONS=none")
    return 0


def main(argv: "list[str]") -> int:
    parser = argparse.ArgumentParser(prog="premerge-findings.py", add_help=True)
    sub = parser.add_subparsers(dest="verb", required=True)

    plan = sub.add_parser("plan", help="classify code-review findings and plan the fix waves")
    plan.add_argument("--input", required=True)
    plan.add_argument("--out-dir", required=True)
    plan.add_argument("--max-per-wave", type=int, default=8)
    plan.set_defaults(handler=cmd_plan)

    gate = sub.add_parser("assert-green", help="the pre-simplify clean gate")
    gate.add_argument("--classified", required=True)
    gate.add_argument("--ci-state", required=True)
    gate.add_argument("--mergeable", default="UNKNOWN")
    gate.add_argument("--require-ci", action="store_true")
    gate.set_defaults(handler=cmd_assert_green)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
