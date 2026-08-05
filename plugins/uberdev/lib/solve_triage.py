#!/usr/bin/env python3
"""Deterministic, bounded /solve issue triage (RFC 0013 section 6)."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any

MAX_SNAPSHOT_BYTES = 1_048_576
MAX_ISSUES = 50
MAX_TITLE = 256
MAX_BODY = 65_536
MAX_LABELS = 100
MAX_LABEL = 128
MAX_COMPONENTS = 64
MAX_FILES = 256
TIERS = ("trivial", "small", "medium", "large")

FILE_RE = re.compile(
    r"(?<![\w.-])(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\."
    r"(?:sh|md|ts|tsx|js|jsx|py|json|ya?ml|go|rs|java|rb|c|h|cpp|css|html)\b",
    re.IGNORECASE,
)
STACK_RE = re.compile(
    r"Traceback \(most recent call last\)|^\s+at .+\(.+:\d+|^\s*File \"|"
    r"panic:|stack[ -]?trace",
    re.IGNORECASE | re.MULTILINE,
)
REPRO_RE = re.compile(
    r"\b(?:repro(?:duce|duction)?|steps to reproduce|expected|actual|error|exception|fails?|failure)\b",
    re.IGNORECASE,
)
CROSS_CUTTING_RE = re.compile(
    r"\b(?:cross[- ]cutting|repo[- ]wide|whole[- ]repo|across (?:the )?(?:codebase|repository|modules?|components?)|"
    r"multiple (?:modules?|components?|packages?|services?))\b",
    re.IGNORECASE,
)

RISK_PATTERNS: dict[str, re.Pattern[str]] = {
    "authentication": re.compile(r"\b(?:authentication|authenticate|login|sign[- ]?in)\b", re.I),
    "authorization": re.compile(r"\b(?:authorization|authorisation|permissions?|access control|rbac|acl)\b", re.I),
    "concurrency": re.compile(r"\b(?:concurren(?:cy|t)|race condition|locking|deadlock|atomicity)\b", re.I),
    "cryptography": re.compile(r"\b(?:cryptograph|encrypt|decrypt|cipher|private key|signature)\w*\b", re.I),
    "data-loss": re.compile(r"\b(?:data loss|data corruption|truncate|irreversible deletion)\b", re.I),
    "destructive-operations": re.compile(r"\b(?:destructive|drop database|delete all|wipe|purge)\b", re.I),
    "force-push": re.compile(r"\b(?:force[- ]push|push --force|force-with-lease)\b", re.I),
    "public-api-compatibility": re.compile(r"\b(?:public api|backward compatibility|breaking change|semver)\b", re.I),
    "release-infrastructure": re.compile(r"\b(?:release infrastructure|publishing pipeline|deployment pipeline|marketplace release)\b", re.I),
    "schema-migration": re.compile(r"\b(?:schema migration|database migration|migrate schema)\b", re.I),
    "security": re.compile(r"\b(?:security|vulnerabilit|exploit|xss|csrf|injection|owasp)\w*\b", re.I),
}
LARGE_LABELS = {"epic", "needs-discussion", "architectural", "architecture", "infrastructure"}
TRIVIAL_LABELS = {"typo", "docs", "documentation", "chore", "good-first-issue"}
TRIVIAL_TITLE_RE = re.compile(r"\b(?:typo|rename|bump|version|readme)\b", re.I)


class TriageError(ValueError):
    pass


def fail(code: str) -> "None":
    raise TriageError(code)


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def load_snapshot(path: str, secure_root: str | None = None) -> dict[str, Any]:
    target = Path(path)
    try:
        if secure_root is not None:
            root = Path(secure_root)
            root_entry = root.lstat()
            target_entry = target.lstat()
            uid = os.geteuid() if hasattr(os, "geteuid") else None
            posix_security = os.name != "nt"
            if (root.is_symlink() or not root.is_dir()
                    or (uid is not None and root_entry.st_uid != uid)
                    or (posix_security and stat.S_IMODE(root_entry.st_mode) != 0o700)):
                fail("triage_snapshot_unsafe")
            if not target.is_absolute() or target.is_symlink() or target.parent.resolve() != root.resolve():
                fail("triage_snapshot_unsafe")
            if (not stat.S_ISREG(target_entry.st_mode)
                    or (uid is not None and target_entry.st_uid != uid)
                    or target_entry.st_nlink != 1
                    or (posix_security and stat.S_IMODE(target_entry.st_mode) != 0o600)):
                fail("triage_snapshot_unsafe")
        if target.stat().st_size > MAX_SNAPSHOT_BYTES:
            fail("triage_snapshot_too_large")
        raw = target.read_bytes()
        if len(raw) > MAX_SNAPSHOT_BYTES:
            fail("triage_snapshot_too_large")
        value = json.loads(raw)
    except TriageError:
        raise
    except Exception:
        fail("triage_snapshot_invalid")
    if not isinstance(value, dict):
        fail("triage_snapshot_invalid")
    return value


def markdown_text(body: str) -> str:
    body = re.sub(r"```.*?```", " ", body, flags=re.S)
    body = re.sub(r"`([^`]*)`", r"\1", body)
    body = re.sub(r"!?(?:\[([^]]*)\])\([^)]*\)", r"\1", body)
    body = re.sub(r"<[^>]+>", " ", body)
    body = re.sub(r"^[>#*+\-]+\s*", "", body, flags=re.M)
    return re.sub(r"\s+", " ", body).strip()


def validate_snapshot(value: dict[str, Any]) -> tuple[int, str, str, list[str]]:
    number, title, state, body, labels = (
        value.get("number"), value.get("title"), value.get("state"), value.get("body", ""), value.get("labels", [])
    )
    if type(number) is not int or number <= 0:
        fail("triage_invalid_issue")
    if not isinstance(title, str) or len(title) > MAX_TITLE:
        fail("triage_limit_title")
    if state != "OPEN":
        fail("triage_closed_issue")
    if body is None:
        body = ""
    if not isinstance(body, str) or len(body) > MAX_BODY:
        fail("triage_limit_body")
    if not isinstance(labels, list) or len(labels) > MAX_LABELS:
        fail("triage_limit_labels")
    names: list[str] = []
    for row in labels:
        name = row.get("name") if isinstance(row, dict) else row
        if not isinstance(name, str) or not name or len(name) > MAX_LABEL:
            fail("triage_limit_label")
        names.append(name.casefold())
    return number, title, body, sorted(set(names))


# `triage_decision.files` is validated by the routing-context schema in
# lib/agent-dispatch.sh with this exact shape. FILE_RE is deliberately permissive
# (it scrapes free-form issue prose), so the two DISAGREE unless the emitter
# filters: a markdown code span `-foo.sh` yields a leading `-`, a pasted
# stack-trace path exceeds 255 chars, and a non-ASCII name survives casefold().
# Any one of those makes uberdev_agent_context_create fail with
# route_context_create_failed, which aborts the ENTIRE batch — every sibling
# issue in the same /solve, /turbo or /ubergoal run dies with it. Same class as
# the component-token bug, one field over.
FILES_TOKEN_RE = re.compile(r"[a-z0-9_.][a-z0-9_./-]{0,255}")


def named_files(body: str) -> list[str]:
    # Drop anything the schema would refuse rather than emit a token that
    # refuses the dispatch: losing one filename from a triage heuristic is
    # strictly better than declining to work the issue — and its siblings.
    files = sorted({
        token for token in (
            match.group(0).strip("./").casefold() for match in FILE_RE.finditer(body)
        ) if FILES_TOKEN_RE.fullmatch(token)
    })
    if len(files) > MAX_FILES:
        fail("triage_limit_files")
    return files


# A component token is embedded in the routing-context metadata, which validates
# every entry against this exact shape (lib/agent-dispatch.sh
# _uberdev_agent_context_schema_validate). The two MUST agree: a token this
# module emits but that validator rejects makes `uberdev_agent_context_create`
# fail, which surfaces as `route_context_create_failed` and refuses the dispatch
# outright — /solve, /turbo and /goal all decline the issue with no PR and no
# retry. Keep this literal in lockstep with the schema; tests/solve-triage.test.sh
# asserts the two regexes are identical.
COMPONENT_TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,127}")


def component_tokens(files: list[str]) -> list[str]:
    # `rsplit(".", 1)` stripped only the LAST extension, so `foo.test.sh` became
    # the token `foo.test` — a dot, which the context schema forbids. Every
    # issue body naming a `*.test.sh` (or `*.test.py`, `*.d.ts`, `*.tar.gz`)
    # was therefore undispatchable. Split on the FIRST dot instead: it yields
    # the real component (`foo`), and it correctly collapses `foo.sh` and
    # `foo.test.sh` into ONE component rather than counting them as two.
    tokens = set()
    for name in files:
        head = name.split("/", 1)[0] if "/" in name else name.split(".", 1)[0]
        # Leading punctuation is not a legal first character (`_workflow_harness`,
        # and any dot-segment `named_files` did not already strip).
        head = head.lstrip("._-")
        # Drop anything still non-conforming rather than emitting a token that
        # would fail the schema: losing one coarse component from a heuristic
        # count is strictly better than refusing to work the issue at all.
        if head and COMPONENT_TOKEN_RE.fullmatch(head):
            tokens.add(head)
    result = sorted(tokens)
    if len(result) > MAX_COMPONENTS:
        fail("triage_limit_components")
    return result


def named_modules(text: str) -> list[str]:
    """Extract only grammatically named extensionless module lists."""
    found: set[str] = set()
    list_pattern = re.compile(
        r"\b(?:the\s+)?([a-z][a-z0-9_-]*(?:\s*,\s*[a-z][a-z0-9_-]*)*"
        r"(?:\s*,?\s+(?:and|&)\s+[a-z][a-z0-9_-]*)?)\s+"
        r"(?:modules?|components?|services?|packages?)\b",
        re.I,
    )
    for match in list_pattern.finditer(text):
        phrase = re.sub(r"\s+(?:and|&)\s+", ",", match.group(1), flags=re.I)
        for token in phrase.split(","):
            normalized = token.strip().casefold()
            if normalized and normalized not in {"multiple", "several", "many", "other"}:
                found.add(normalized)
    return sorted(found)


def clamp(tier: str, floor: str | None, ceiling: str | None) -> str:
    if floor and ceiling and TIERS.index(floor) > TIERS.index(ceiling):
        return tier
    rank = TIERS.index(tier)
    if floor:
        rank = max(rank, TIERS.index(floor))
    if ceiling:
        rank = min(rank, TIERS.index(ceiling))
    return TIERS[rank]


def classify(value: dict[str, Any], floor: str | None, ceiling: str | None, override: str | None, expected_issue: int | None = None) -> dict[str, Any]:
    number, title, body, labels = validate_snapshot(value)
    if expected_issue is not None and number != expected_issue:
        fail("triage_issue_mismatch")
    files = named_files(body)
    # `components` has TWO producers — component_tokens (already filtered) and
    # named_modules (was NOT). Filtering at the UNION means exactly one choke
    # point governs the field however many producers ever feed it; filtering
    # inside each producer is what let the second one drift unnoticed while the
    # field looked guarded.
    components = sorted({
        token for token in (
            set(component_tokens(files)) | set(named_modules("\n".join((title, body))))
        ) if COMPONENT_TOKEN_RE.fullmatch(token)
    })
    if len(components) > MAX_COMPONENTS:
        fail("triage_limit_components")
    combined = "\n".join((title, body, " ".join(labels)))
    risks = sorted(name for name, pattern in RISK_PATTERNS.items() if pattern.search(combined))
    stack = bool(STACK_RE.search(body))
    cross_cutting = bool(CROSS_CUTTING_RE.search(combined))
    matched: list[str] = []

    large = False
    large_labels = sorted(set(labels) & LARGE_LABELS)
    if large_labels:
        large = True
        matched.extend(f"large-label:{label}" for label in large_labels)
    if len(files) >= 3:
        large = True
        matched.append("large:three-files")
    if risks and len(components) > 1:
        large = True
        matched.append("large:multi-component-high-risk")
    if "refactor" in labels and (len(components) >= 2 or cross_cutting):
        large = True
        matched.append("large:cross-cutting-refactor")

    stripped_length = len(markdown_text(body))
    if large:
        raw = "large"
    elif not risks and not stack and len(files) <= 1 and stripped_length < 300 and (
        bool(set(labels) & TRIVIAL_LABELS) or bool(TRIVIAL_TITLE_RE.search(title))
    ):
        raw = "trivial"
        matched.append("trivial:bounded-explicit-signal")
    elif not risks and len(files) <= 2 and len(body) < 4_000 and (
        stack or "bug" in labels or bool(REPRO_RE.search(body))
    ):
        raw = "small"
        matched.append("small:concrete-reproduction")
    else:
        raw = "medium"
        matched.append("medium:fallback")

    clamps_valid = not (floor and ceiling and TIERS.index(floor) > TIERS.index(ceiling))
    clamped = clamp(raw, floor, ceiling)
    source = "computed"
    if clamps_valid and floor and TIERS.index(raw) < TIERS.index(floor):
        source = "floor"
        matched.append(f"floor:{floor}")
    if clamps_valid and ceiling and TIERS.index(raw) > TIERS.index(ceiling):
        source = "ceiling"
        matched.append(f"ceiling:{ceiling}")
    effective = clamped
    if override:
        effective, source = override, "override"
        matched.append(f"override:{override}")
    return {
        "clamped_tier": clamped,
        "component_count": len(components),
        "components": components,
        "effective_tier": effective,
        "file_count": len(files),
        "files": files,
        "issue": number,
        "matched_rules": list(dict.fromkeys(matched)),
        "raw_tier": raw,
        "risk_signals": risks,
        "schema_version": 1,
        "source": source,
        "tier": effective,
    }


def finalize_decision(value: dict[str, Any], clamped: str, override: str | None) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("raw_tier") not in TIERS or clamped not in TIERS:
        fail("triage_decision_invalid")
    result = dict(value); matched = list(result.get("matched_rules", [])); raw = result["raw_tier"]
    result["clamped_tier"] = clamped
    source = "computed"
    if TIERS.index(clamped) > TIERS.index(raw): source = "floor"; matched.append(f"floor:{clamped}")
    elif TIERS.index(clamped) < TIERS.index(raw): source = "ceiling"; matched.append(f"ceiling:{clamped}")
    effective = clamped
    if override: effective=override; source="override"; matched.append(f"override:{override}")
    result["effective_tier"]=effective; result["tier"]=effective; result["source"]=source
    result["matched_rules"]=list(dict.fromkeys(matched))
    return result


def tier_arg(value: str) -> str:
    if value not in TIERS:
        raise argparse.ArgumentTypeError("expected trivial|small|medium|large")
    return value


def parse_cli(tokens: list[str]) -> dict[str, Any]:
    tokens = [token for raw in tokens for token in raw.split()]
    policy_path = Path(__file__).resolve().parent.parent / "policy" / "model-routing-v1.json"
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        routes = set(policy["routes"]) | set(policy["aliases"])
    except Exception:
        fail("routing_cli_policy_unavailable")
    result: dict[str, Any] = {
        "auto": False,
        "backend": None,
        "effort": None,
        "force": False,
        "issues": [],
        "model": None,
        "route": None,
        "routing_mode": None,
        "service_tier": None,
        "terminal": None,
        "tier_override": None,
    }
    seen: set[str] = set()

    def assign(key: str, value: Any) -> None:
        if key in seen:
            fail("routing_cli_duplicate")
        seen.add(key)
        result[key] = value

    for token in tokens:
        if re.fullmatch(r"[1-9][0-9]*", token):
            number = int(token)
            if number not in result["issues"]:
                result["issues"].append(number)
            continue
        if re.fullmatch(r"[+-]?[0-9]+", token):
            fail("routing_cli_invalid_issue")
        if token in {"--trivial", "--small", "--full"}:
            assign("tier_override", {"--trivial": "trivial", "--small": "small", "--full": "medium"}[token])
        elif token == "--auto":
            assign("auto", True)
        elif token in {"--force", "-f"}:
            assign("force", True)
        elif token == "--fast":
            assign("fast", True)
        elif token.startswith("--routing-mode="):
            value = token.split("=", 1)[1]
            if value not in {"adaptive", "inherit"}: fail("routing_cli_invalid")
            assign("routing_mode", value)
        elif token.startswith("--route="):
            value = token.split("=", 1)[1]
            if value not in routes: fail("routing_cli_invalid")
            assign("route", value)
        elif token.startswith("--model="):
            value = token.split("=", 1)[1]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value): fail("routing_cli_invalid")
            assign("model", value)
        elif token.startswith("--effort="):
            value = token.split("=", 1)[1]
            if value not in {"low", "medium", "high", "xhigh", "max", "ultra"}: fail("routing_cli_invalid")
            assign("effort", value)
        elif token.startswith("--service-tier="):
            value = token.split("=", 1)[1]
            if value not in {"default", "fast", "flex"}: fail("routing_cli_invalid")
            assign("service_tier", value)
        elif token.startswith("--backend="):
            value = token.split("=", 1)[1]
            # Keep in lockstep with _UBERDEV_DISPATCH_BACKEND_ENUM in lib/dispatch.sh.
            # `workflow` (RFC 0015, the default `auto` resolves to) was added there and
            # NOT here, so an explicit --backend=workflow died at this gate — which is
            # the very first thing lib/solve-launcher.sh runs, and the exact flag
            # /goal's driver passes, so every /goal cycle failed at dispatch.
            # CONTRACT: dispatch-backend
            if value not in {"auto", "workflow", "wezterm", "background", "codex"}: fail("routing_cli_invalid")
            assign("backend", value)
        elif token.startswith("--terminal="):
            assign("terminal", token.split("=", 1)[1])
        else:
            fail("routing_cli_unrecognized")
    if not result["issues"]:
        fail("routing_cli_invalid_issue")
    if len(result["issues"]) > MAX_ISSUES:
        fail("triage_limit_issues")
    concrete = any(result[key] is not None for key in ("route", "model", "effort"))
    if result["routing_mode"] is not None and concrete:
        fail("routing_cli_conflict")
    if result["route"] is not None and (result["model"] is not None or result["effort"] is not None):
        fail("routing_cli_conflict")
    if result.get("fast") and result["service_tier"] not in {None, "fast"}:
        fail("routing_cli_conflict")
    if result.get("fast"):
        result["service_tier"] = "fast"
    result.pop("fast", None)
    return result


def main(argv: list[str]) -> int:
    # Public launcher flags may precede issue numbers. Bypass argparse's
    # option parser for this opaque-token subcommand so `--backend=codex 12`
    # and `12 --backend=codex` are equivalent.
    if argv and argv[0] == "parse-cli":
        print(canonical(parse_cli(argv[1:])))
        return 0
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    classify_parser = commands.add_parser("classify")
    classify_parser.add_argument("--snapshot", required=True)
    classify_parser.add_argument("--floor", type=tier_arg)
    classify_parser.add_argument("--ceiling", type=tier_arg)
    classify_parser.add_argument("--override", type=tier_arg)
    classify_parser.add_argument("--expected-issue", type=int)
    classify_parser.add_argument("--secure-root")
    validate_parser = commands.add_parser("validate-issues")
    validate_parser.add_argument("issues", nargs="+")
    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("--decision", required=True)
    finalize_parser.add_argument("--clamped", required=True, type=tier_arg)
    finalize_parser.add_argument("--override", type=tier_arg)
    args = parser.parse_args(argv)
    if args.command == "validate-issues":
        issues: list[int] = []
        for raw in args.issues:
            if not re.fullmatch(r"[1-9][0-9]*", raw):
                fail("triage_invalid_issue")
            number = int(raw)
            if number not in issues:
                issues.append(number)
        if len(issues) > MAX_ISSUES:
            fail("triage_limit_issues")
        print(canonical(issues))
        return 0
    if args.command == "finalize":
        try: decision=json.loads(args.decision)
        except Exception: fail("triage_decision_invalid")
        print(canonical(finalize_decision(decision,args.clamped,args.override)))
        return 0
    print(canonical(classify(load_snapshot(args.snapshot, args.secure_root), args.floor, args.ceiling, args.override, args.expected_issue)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except TriageError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
