#!/usr/bin/env python3
"""Closed authority boundary for routed review code fixers."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import posixpath
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import asdict, dataclass
from typing import Any, Literal, NoReturn

try:
    from run_manifest import (
        ArtifactIdentity,
        ManifestRejected,
        ManifestRuntimeError,
        secure_capture_published,
        secure_capture_regular,
        secure_publish_captured,
    )
except ModuleNotFoundError:
    _run_manifest_path = os.path.join(os.path.dirname(__file__), "run_manifest.py")
    _run_manifest_spec = importlib.util.spec_from_file_location(
        "_code_fixer_run_manifest", _run_manifest_path
    )
    if _run_manifest_spec is None or _run_manifest_spec.loader is None:
        raise
    _run_manifest = importlib.util.module_from_spec(_run_manifest_spec)
    sys.modules[_run_manifest_spec.name] = _run_manifest
    _run_manifest_spec.loader.exec_module(_run_manifest)
    ArtifactIdentity = _run_manifest.ArtifactIdentity
    ManifestRejected = _run_manifest.ManifestRejected
    ManifestRuntimeError = _run_manifest.ManifestRuntimeError
    secure_capture_published = _run_manifest.secure_capture_published
    secure_capture_regular = _run_manifest.secure_capture_regular
    secure_publish_captured = _run_manifest.secure_publish_captured

try:
    from atomic_move import atomic_rename_noreplace
except ModuleNotFoundError:
    _atomic_move_path = os.path.join(os.path.dirname(__file__), "atomic_move.py")
    _atomic_move_spec = importlib.util.spec_from_file_location(
        "_code_fixer_atomic_move", _atomic_move_path
    )
    if _atomic_move_spec is None or _atomic_move_spec.loader is None:
        raise
    _atomic_move = importlib.util.module_from_spec(_atomic_move_spec)
    sys.modules[_atomic_move_spec.name] = _atomic_move
    _atomic_move_spec.loader.exec_module(_atomic_move)
    atomic_rename_noreplace = _atomic_move.atomic_rename_noreplace

Phase = Literal["phase1", "phase2"]
CommitType = Literal["fix", "refactor"]
SHA256 = re.compile(r"[0-9a-f]{64}")
# Git object-id shape (40 lowercase hex). One compiled definition for the whole
# module: this validator guards every commit/tree/blob oid crossing the contract
# boundary, and an inline `re.fullmatch(r"[0-9a-f]{40}", …)` re-typed at each of
# those call sites is a literal that can silently drift at one of them.
SHA1 = re.compile(r"[0-9a-f]{40}")
SHA1_BYTES = re.compile(rb"[0-9a-f]{40}")
PROCESS_IDENTITY = re.compile(r"[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}")
LEASE_GENERATION = re.compile(r"[0-9a-f]{32}")
COMMIT_RANGE = re.compile(rb"[0-9a-f]{40}\.\.[0-9a-f]{40}\n?")
AUTHORITY_LIMIT = 1_048_576
FINDINGS_LIMIT = 16_777_216
RANGE_LIMIT = 256
DISPOSITION_LIMIT = 1_048_576
INDEX_LIMIT = 268_435_456
PERSISTENCE_RESULT_LIMIT = 1_048_576
# A reviewer/lens child writes the same provider `result.md` a detached child
# writes, so the bound-child capture uses the SAME ceiling the Phase-1 evidence
# builder already applies to that artifact (16 MiB). Deliberately not the
# 1 MiB persistence bound: that one covers findings-to-issues output, not a
# reviewer report, and reusing it here would reject long-but-legitimate reports
# as `artifact_invalid` -- an infrastructure failure wearing a proof failure's
# error class.
BOUND_CHILD_RESULT_LIMIT = 16_777_216

__all__ = (
    "Phase",
    "CommitType",
    "FindingKey",
    "RouteAuthority",
    "bind_launch_receipt",
    "bind_fixer_launch_receipt",
    "bind_persistence_launch_receipt",
    "route_authority",
    "beneath",
    "capture_standalone_snapshot",
    "capture_standalone_terminal",
    "capture_review_terminal",
    "capture_persistence_terminal",
    "capture_bound_child",
    "capture_expected",
    "consume_authority",
    "encode_aggregate",
    "parse_finding_keys",
    "prepare_authority",
    "prepare_standalone_authority",
    "publish_disposition",
    "publish_review_only_disposition",
    "publish_unapplied_terminal",
    "count_phase2_deferred_blockers",
    "project_verification_claims",
    "publish_verification",
    "validate_persistence_result",
    "commit_review",
    "commit_standalone",
    "validate_commit",
    "validate_failed_return",
    "validate_residue",
    "validate_standalone_outcome",
    "validate_review_outcome",
    "validate_staged",
)


@dataclass(frozen=True)
class FindingKey:
    finding_index: int
    location: str
    summary_sha256: str


@dataclass(frozen=True)
class RouteAuthority:
    edge_id: str
    policy_phase: str
    phase: Phase
    commit_type: CommitType


@dataclass(frozen=True)
class _ArtifactRollback:
    path: str
    identity: ArtifactIdentity
    predecessor: bytes | None


@dataclass(frozen=True)
class _IndexObservationLock:
    index_path: str
    lock_path: str
    parent_identity: tuple[int, int]
    index_payload: bytes
    index_identity: ArtifactIdentity
    lock_identity: tuple[int, int]
    descriptor: int | None
    handle: int | None


class ContractFailure(Exception):
    """A closed refusal whose token is safe to expose."""


def fail(reason: str) -> NoReturn:
    if re.fullmatch(r"[a-z][a-z0-9_]{0,95}", reason) is None:
        reason = "contract_failure"
    raise ContractFailure(reason)


def route_authority(edge_id: str, policy_phase: str) -> RouteAuthority:
    if not isinstance(edge_id, str) or not isinstance(policy_phase, str):
        fail("route_authority_invalid")
    routes: dict[tuple[str, str], tuple[Phase, CommitType]] = {
        ("review_pr.fix.phase1", "review_fix"): ("phase1", "fix"),
        ("review_pr.fix.phase2", "simplify_fix"): ("phase2", "refactor"),
        ("simplify.fix.phase2", "simplify_fix"): ("phase2", "refactor"),
    }
    derived = routes.get((edge_id, policy_phase))
    if derived is None:
        fail("route_authority_invalid")
    return RouteAuthority(edge_id, policy_phase, *derived)


def beneath(root: str, path: str) -> bool:
    try:
        root_abs = os.path.realpath(os.path.abspath(root))
        path_abs = os.path.realpath(os.path.abspath(path))
        return os.path.commonpath((root_abs, path_abs)) == root_abs
    except (TypeError, ValueError, OSError):
        return False


def _capture_regular(
    path: str, minimum: int, maximum: int
) -> tuple[bytes, ArtifactIdentity]:
    try:
        return secure_capture_regular(path, minimum, maximum)
    except ManifestRejected as error:
        reason = str(error)
        fail(reason if re.fullmatch(r"[a-z][a-z0-9_]{0,95}", reason) else "artifact_invalid")
    except ManifestRuntimeError:
        fail("artifact_capture_failed")


def capture_expected(
    path: str, expected_sha256: str, minimum: int, maximum: int
) -> bytes:
    if not isinstance(expected_sha256, str) or SHA256.fullmatch(expected_sha256) is None:
        fail("artifact_digest_invalid")
    try:
        payload, _identity = secure_capture_published(
            path, expected_sha256, minimum, maximum
        )
    except ManifestRejected as error:
        reason = str(error)
        fail(reason if re.fullmatch(r"[a-z][a-z0-9_]{0,95}", reason) else "artifact_invalid")
    except ManifestRuntimeError:
        fail("artifact_capture_failed")
    return payload


def _reject_constant(_value: str) -> NoReturn:
    fail("json_nonfinite_rejected")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail("json_duplicate_key")
        value[key] = item
    return value


def _parse_json(payload: bytes, reason: str) -> Any:
    try:
        return json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except ContractFailure:
        raise
    except (UnicodeError, TypeError, ValueError, RecursionError):
        fail(reason)


def _repo_path_from_location(location: str) -> str:
    if not isinstance(location, str):
        fail("finding_location_invalid")
    try:
        path, line = location.rsplit(":", 1)
    except ValueError:
        fail("finding_location_invalid")
    if (
        not path
        or len(path) > 4096
        or len(line) > 20
        or re.fullmatch(r"[1-9][0-9]*", line, re.ASCII) is None
        or path.startswith("/")
        or "\\" in path
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
        or re.match(r"^[A-Za-z]:", path)
    ):
        fail("finding_location_invalid")
    parts = path.split("/")
    if (
        any(part in {"", ".", ".."} for part in parts)
        or parts[0] == ".git"
        or posixpath.normpath(path) != path
    ):
        fail("finding_location_invalid")
    return path


def _enveloped_body(payload: bytes, source: str) -> bytes:
    opening = f'<external-untrusted-input source="{source}">'.encode()
    closing = b"</external-untrusted-input>"
    prefix = opening + b"\n"
    suffix = b"\n" + closing + b"\n"
    if (
        not payload.startswith(prefix)
        or not payload.endswith(suffix)
        or payload.count(opening) != 1
        or payload.count(closing) != 1
    ):
        fail("findings_envelope_invalid")
    body = payload[len(prefix) : -len(suffix)]
    if not body or b"\x00" in body or b"\r" in body or b"\n" in body:
        fail("findings_schema_invalid")
    return body


PHASE_CONTRIBUTORS = {
    "phase1": (
        "review_pr.review.correctness",
        "review_pr.review.silent_failures",
        "review_pr.review.types",
        "review_pr.review.comments",
        "review_pr.review.tests",
        "review_pr.review.general",
        "review_pr.review.convention",
    ),
    "phase2": (
        "review_pr.simplify.reuse",
        "review_pr.simplify.quality",
        "review_pr.simplify.efficiency",
    ),
}
AGGREGATE_KEYS = {"contributors", "findings", "phase", "schema_version"}
CONTRIBUTOR_KEYS = {"confidence", "id", "verdict"}
FINDING_KEYS = {"detail", "scope", "severity", "source_edges", "summary"}
SCOPE_KEYS = {"line", "operation", "path"}

# ---------------------------------------------------------------------------
# The convention lens's citation gate (#433).
#
# `review_pr.review.convention` is the one Phase 1 lens whose claim is a claim
# ABOUT A DOCUMENT: "the project's rules say X". That shape is authoritative to
# read and trivially hallucinable to write, which is why the lens is admissible
# at all only because it arrives with this filter attached. The filter is
# DETERMINISTIC on purpose: "does this byte string occur in that file, near that
# line" and "does a rule in directory D govern a file under D" are both
# decidable, so routing them through a second model would trade a decision for
# an opinion.
#
# A finding whose quote cannot be located verbatim is not a low-confidence
# finding, it is a FALSE one, and it is culled outright rather than downweighted.
CONVENTION_EDGE = "review_pr.review.convention"
# Every reason this gate can refuse a citation for. Closed on purpose: the
# aggregate writer logs one of these per cull, and an unlisted reason means a
# code path that can drop a finding without naming why.
CONVENTION_CULL_REASONS = (
    "citation-unparsable",
    "citation-not-in-allowlist",
    "citation-not-verbatim",
    "citation-out-of-scope",
    "citation-secret-shaped",
    "rule-sources-unavailable",
)
CONVENTION_DEMOTE_REASON = "citation-self-introduced"
# The `detail` grammar the convention reviewer must emit. `rsplit` on the quote
# marker, so an explanation that itself contains the marker cannot truncate the
# quote -- the LAST marker always wins.
CONVENTION_QUOTE_MARKER = " — quote: "
CONVENTION_DETAIL_GRAMMAR = re.compile(
    r"confidence: (\d{1,3}) — rule ([^ :]+(?:/[^ :]+)*):([1-9]\d*) — (.+)"
)
# A quote shorter than this cites nothing (any file contains "the"); one longer
# than this is a rule document being republished into a PR body, which the
# shared contract's redaction carve-out caps at the same number.
CONVENTION_QUOTE_MIN = 12
CONVENTION_QUOTE_MAX = 300
# How many physical lines after the cited one the quote may span. Markdown rules
# wrap, so a one-line citation of a three-line bullet must still verify; a window
# this size is generous for wrapping and far too small to make "somewhere in the
# file" pass as "at this line".
CONVENTION_RULE_WINDOW = 10
CONVENTION_REQUEST_KEYS = {
    "allowlist",
    "changed_paths",
    "detail",
    "location_path",
    "rule_lines",
}
# The CLI verb's stdin ceiling. The request carries a bounded window of one rule
# file plus two path lists, never a diff or a reviewer transcript.
CONVENTION_REQUEST_LIMIT = 262144
# Secret shapes that may never ride out in a citation even though the rule-text
# carve-out permits quoting. NAMED shapes first: each one is an issuer's own
# prefix, so it needs no statistics. Assembled at runtime rather than spelled
# contiguously: a literal AWS example key in these bytes hard-stops
# finish-branch's pre-push secret scan on the diff that introduces it.
#
# The vocabulary AND every length bound below are the ones in
# `lib/secret-scan.sh`, this repo's pre-push scanner. A shape named in one guard
# and missing -- or bounded differently -- in the other is the "one contract, N
# uncompared copies" defect: at `{8,}` the `sk-` rule here refused ordinary
# hyphenated English, and `run-risk-mismatch`, `task-manifest`, `disk-recovery`
# and `kiosk-frontend` all occur in this checkout today. The bound is what makes
# a prefix a NAME rather than a substring, so it is never loosened "to be safe":
# every one of these tuples deletes a true finding when it over-fires.
_CONVENTION_SECRET_PATTERNS = (
    # AWS access key id -- 16 characters after the prefix (secret-scan.sh:261).
    re.compile("AKIA" + r"[0-9A-Z]{16,}"),
    # Every GitHub token prefix, 36 characters (secret-scan.sh:265). The prefix
    # set is the scanner's, not just `ghp_`: an installation or refresh token
    # leaks exactly as hard as a personal one.
    re.compile("gh" + r"[pousr]_[A-Za-z0-9]{36,}"),
    # OpenAI-style (secret-scan.sh:266). See the bound argument above.
    re.compile("sk" + r"-[A-Za-z0-9]{32,}"),
    # Slack, all five issued prefixes (secret-scan.sh:267). Named rather than
    # left to the statistical rule below because a Slack token opens with two
    # blocks of digits, and a digit block holds ONE character class for its
    # whole length: the prefix drags the run's class churn under the floor, and
    # 99.8% of drawn bot tokens scored as identifiers and were let through.
    re.compile("xox" + r"[abprs]-[A-Za-z0-9-]{10,}"),
    # Stripe secret and restricted keys, at the issuer key length of 24.
    # Unreachable by the statistical rule for a different reason than Slack:
    # `sk_live_` plus a 24-character key is a 32-character run whose
    # separator-stripped core is 30, one under the core minimum, so it is
    # dropped before it is ever scored (0.0% of drawn keys culled). Publishable
    # `pk_` keys are deliberately absent -- they are public by design, so
    # refusing a citation over one would be a pure false positive.
    #
    # The only entry anchored on a word boundary, and the asymmetry is the
    # point: this is the one prefix here that is also the TAIL of everyday
    # words, so without `\b` the entry reads `sk_live_` out of the middle of
    # `task_live_DispatchConfigurationBuilder` -- measured, not hypothetical --
    # and refuses a rule quoting an ordinary identifier. `sk-` has the same
    # shape (risk-, task-, disk-, kiosk-) but inherits secret-scan.sh {32,}
    # bound, which already ends that class; there is no scanner rule to inherit
    # here, so the boundary does the work instead. An issued key never begins
    # mid-word, so the anchor costs no coverage.
    re.compile(r"\b" + "[sr]k" + r"_(?:live|test)_[A-Za-z0-9]{24,}"),
    # A JWT always opens `eyJ` (base64 of `{"`) and always carries at least two
    # `.`-separated segments. It is named because those separators chop it into
    # runs shorter than the statistical rule's minimum, and it is anchored on
    # the SECOND segment because `eyJ` plus one run alone also spells
    # `monkeyJsonSerializerFactory`.
    re.compile("eyJ" + r"[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"),
)
# The UNNAMED half: a run long enough to be a credential. Length alone is NOT a
# credential test, and treating it as one is how this gate silently deleted true
# findings -- `uberdev_command_workspace_prepare` is 33 characters and
# `REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP` is 34, a convention rule quotes its own
# constants constantly, and a culled finding is only ever logged, never surfaced
# (review-aggregate then recomputes the lens to APPROVE with nothing left in it).
# What separates a credential from an identifier is that a credential is DRAWN AT
# RANDOM: flat character frequencies and a character class that keeps changing.
# An identifier is words -- it holds one class for a word at a time.
#
# Both statistics are measured on the run's alphanumeric CORE, with `_ - / + =`
# stripped, because those separators are what an identifier is built out of and
# what a secret only sprinkles: measured raw, every `/` in a path counts as a
# class change and lifts a path over the same floor a base64 blob clears.
#
# The churn floor is set from the IDENTIFIER side, because the two errors here
# are not symmetric -- a missed secret is still only a quote out of a rule file
# the reviewer was already allowed to read, while a false positive deletes a true
# finding and says so nowhere anybody looks. Over 20k word-built identifiers
# (camelCase, embedded digits, 32-52 characters) the highest core churn observed
# is 0.375, and a credential drawn at random sits near 0.64; the floor is the gap
# between them. A hand-written example key out of a vendor's documentation can
# fall inside the identifier range and pass -- that is the deliberate side to err
# on, and issued credentials are random enough to clear the floor by a wide
# margin. Entropy cannot carry this split at all (those same identifiers reach
# 4.76 bits), so it serves only as a floor under repetitive runs.
_CONVENTION_SECRET_RUN = re.compile(r"[A-Za-z0-9+/=_-]{32,}")
_CONVENTION_SECRET_SEPARATORS = re.compile(r"[^A-Za-z0-9]")
# Stripping separators also shortens the run, and it shortens a path far more
# than a blob: a candidate has to still be credential-length once it is only
# alphanumerics, which is what keeps `CLAUDE_PLUGIN_ROOT/lib/goal-phase0` out.
_CONVENTION_SECRET_CORE_MIN = 32
_CONVENTION_SECRET_BITS = 4.0
_CONVENTION_SECRET_CHURN = 0.45
_CHAR_CLASS_LOWER, _CHAR_CLASS_UPPER, _CHAR_CLASS_DIGIT, _CHAR_CLASS_OTHER = range(4)
# Two of the three alphanumeric classes: a random token mixes them, where
# `snake_case`, `SCREAMING_SNAKE` and `camelCase` each stay inside one or two.
# Read TWICE, and it is the weaker term here and the load-bearing one in the
# base32 scan below -- raising it would silently stop that scan from reaching a
# seed drawn without an uppercase letter.
_CONVENTION_SECRET_CLASSES = 2
# Hex keys are scanned separately, against the raw quote and on a lower floor: a
# 16-symbol alphabet cannot reach the base64 floor, and no identifier this long
# spells itself in `a-f` plus digits. Raw rather than cored so a dashed UUID --
# an identifier, not a credential -- is not silently reassembled into a key, and
# floored so a padding run (`0000...`, entropy 0) is not read as one either.
_CONVENTION_SECRET_HEX = re.compile(r"[0-9a-fA-F]{32,}")
_CONVENTION_SECRET_HEX_BITS = 3.0
# base32 (RFC 4648) is how a TOTP seed is handed out, and it is the third shape
# the statistical rule cannot reach: one letter case plus six digits changes
# class rarely enough that only 10.0% of drawn 32-character seeds cleared the
# churn floor. Scanned the way hex is -- restricted alphabet, entropy floor, and
# NO churn term, which means nothing inside a single-case alphabet -- against
# the raw quote, so a separator still ends the run.
#
# The class floor carries this one on its own, and entropy cannot: the only
# thing that spells a 32-character unbroken `[A-Z2-7]` run other than a seed is
# a row of glued-together uppercase words, and over 20k synthetic ones those
# reach 4.22 bits while drawn seeds start at 3.51 -- overlapping ranges, no
# floor splits them. Glued words carry no digits at all, so the two-class floor
# does. A drawn seed misses all six digits with probability (26/32)**32 = 0.1%;
# that 0.1% is the residual, and it is the identifier-safe side to leave open.
# The entropy floor stays for the same reason hex has one: every one of the
# seven `[A-Z2-7]{32,}` runs in this checkout is a zero-entropy padding fixture.
_CONVENTION_SECRET_BASE32 = re.compile(r"[A-Z2-7]{32,}")
_CONVENTION_SECRET_BASE32_BITS = 3.0


def _character_class(char: str) -> int:
    """Which of lower / upper / digit / separator `char` belongs to."""
    if char.islower():
        return _CHAR_CLASS_LOWER
    if char.isupper():
        return _CHAR_CLASS_UPPER
    if char.isdigit():
        return _CHAR_CLASS_DIGIT
    return _CHAR_CLASS_OTHER


def _shannon_bits(run: str) -> float:
    """Shannon entropy of `run`, in bits per character. `run` must be non-empty."""
    total = len(run)
    return -sum(
        (count / total) * math.log2(count / total) for count in Counter(run).values()
    )


def _class_churn(run: str) -> float:
    """Share of `run`'s adjacent character pairs that change class.

    `run` must be at least two characters. Every caller passes a run already
    held to `_CONVENTION_SECRET_CORE_MIN`, so the pair list is never empty.
    """
    pairs = list(zip(run, run[1:]))
    return sum(
        1 for left, right in pairs if _character_class(left) != _character_class(right)
    ) / len(pairs)


def _convention_quote_is_secret_shaped(quote: str) -> bool:
    """True when `quote` carries something that could be a live credential."""
    for pattern in _CONVENTION_SECRET_PATTERNS:
        if pattern.search(quote):
            return True
    for run in _CONVENTION_SECRET_HEX.findall(quote):
        if _shannon_bits(run) >= _CONVENTION_SECRET_HEX_BITS:
            return True
    for run in _CONVENTION_SECRET_BASE32.findall(quote):
        if (
            len({_character_class(char) for char in run})
            >= _CONVENTION_SECRET_CLASSES
            and _shannon_bits(run) >= _CONVENTION_SECRET_BASE32_BITS
        ):
            return True
    for run in _CONVENTION_SECRET_RUN.findall(quote):
        core = _CONVENTION_SECRET_SEPARATORS.sub("", run)
        if len(core) < _CONVENTION_SECRET_CORE_MIN:
            continue
        if (
            len({_character_class(char) for char in core})
            >= _CONVENTION_SECRET_CLASSES
            and _shannon_bits(core) >= _CONVENTION_SECRET_BITS
            and _class_churn(core) >= _CONVENTION_SECRET_CHURN
        ):
            return True
    return False


def normalise_rule_text(text: str) -> str:
    """Collapse every whitespace run to one space and strip the ends.

    Both sides of the verbatim comparison go through this, so a rule that wraps
    across markdown lines still matches the one-line form a reviewer quotes.
    """
    if not isinstance(text, str):
        return ""
    return re.sub(r"\s+", " ", text).strip()


def parse_convention_detail(detail: str) -> dict[str, Any] | None:
    """Split a convention `detail` into its declared parts, or None."""
    if not isinstance(detail, str) or CONVENTION_QUOTE_MARKER not in detail:
        return None
    head, quote = detail.rsplit(CONVENTION_QUOTE_MARKER, 1)
    match = CONVENTION_DETAIL_GRAMMAR.fullmatch(head)
    if match is None:
        return None
    confidence = int(match.group(1))
    if confidence > 100:
        return None
    return {
        "confidence": confidence,
        "rule_path": match.group(2),
        "rule_line": int(match.group(3)),
        "explanation": match.group(4),
        "quote": quote,
    }


def _convention_rule_governs(rule_path: str, location_path: str) -> bool:
    """Nested rule scoping: a rule in D governs exactly what lives under D."""
    rule_dir = posixpath.dirname(rule_path)
    if rule_dir in ("", "."):
        return True
    return location_path.startswith(rule_dir + "/")


def classify_convention_citation(request: dict[str, Any]) -> dict[str, Any]:
    """Decide one convention finding's fate. PURE: no file I/O, no clock.

    The caller materialises everything -- the allowlist, the changed paths, and
    the bounded read of the cited rule file -- so this predicate is decidable
    from its argument alone and is therefore directly testable. It returns
    `accept`, `demote` (the finding survives as a suggestion), or `cull`, and
    the FIRST failing check names the reason.
    """
    if not isinstance(request, dict) or set(request) != CONVENTION_REQUEST_KEYS:
        return {"outcome": "cull", "reason": "citation-unparsable"}
    location_path = request["location_path"]
    allowlist = request["allowlist"]
    changed_paths = request["changed_paths"]
    rule_lines = request["rule_lines"]
    if (
        not isinstance(location_path, str)
        or not isinstance(allowlist, list)
        or not isinstance(changed_paths, list)
        or not isinstance(rule_lines, list)
    ):
        return {"outcome": "cull", "reason": "citation-unparsable"}
    parsed = parse_convention_detail(request["detail"])
    if parsed is None:
        return {"outcome": "cull", "reason": "citation-unparsable"}
    rule_path = parsed["rule_path"]
    quote = normalise_rule_text(parsed["quote"])
    verdict: dict[str, Any] = {
        "outcome": "accept",
        "reason": "citation-verified",
        "rule_path": rule_path,
        "rule_line": parsed["rule_line"],
        "quote_prefix": quote[:80],
    }

    def refuse(reason: str) -> dict[str, Any]:
        return {**verdict, "outcome": "cull", "reason": reason}

    if rule_path not in allowlist:
        return refuse("citation-not-in-allowlist")
    if not _convention_rule_governs(rule_path, location_path):
        return refuse("citation-out-of-scope")
    if not CONVENTION_QUOTE_MIN <= len(quote) <= CONVENTION_QUOTE_MAX:
        return refuse("citation-not-verbatim")
    start = parsed["rule_line"] - 1
    window = normalise_rule_text(
        " ".join(
            line
            for line in rule_lines[start : start + CONVENTION_RULE_WINDOW]
            if isinstance(line, str)
        )
    )
    if not window or quote not in window:
        return refuse("citation-not-verbatim")
    # Last, and only against text already proven to be a real rule quote: the
    # redaction guard. It is ordered here because the FIRST failing check names
    # the reason, and running the narrowest check first made
    # `citation-secret-shaped` the recorded cause of citations that were never in
    # the file to begin with. Anything refused above is culled either way, so no
    # secret survives the reordering -- only the reason gets truthful.
    if _convention_quote_is_secret_shaped(quote):
        return refuse("citation-secret-shaped")
    if rule_path in changed_paths:
        # The PR itself wrote the rule it is being judged against. That is not a
        # fabrication -- the quote IS in the file -- but it is circular, so the
        # finding survives as advice rather than as a blocker.
        return {**verdict, "outcome": "demote", "reason": CONVENTION_DEMOTE_REASON}
    return verdict


def _canonical_json(value: Any) -> bytes:
    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        )
    except (TypeError, ValueError, RecursionError):
        fail("findings_schema_invalid")
    return (
        text.replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
        .encode("utf-8")
    )


def _bounded_text(value: Any, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value.strip() != value
        or len(value) > maximum
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        fail("findings_schema_invalid")
    return value


def _validate_aggregate(value: Any, phase: Phase) -> tuple[FindingKey, ...]:
    if not isinstance(value, dict) or set(value) != AGGREGATE_KEYS:
        fail("findings_schema_invalid")
    if (
        type(value.get("schema_version")) is not int
        or value["schema_version"] != 2
        or value.get("phase") != phase
    ):
        fail("findings_schema_invalid")
    roster = PHASE_CONTRIBUTORS[phase]
    contributors = value.get("contributors")
    if not isinstance(contributors, list) or len(contributors) != len(roster):
        fail("findings_schema_invalid")
    verdicts: dict[str, str] = {}
    for contributor, edge_id in zip(contributors, roster, strict=True):
        if not isinstance(contributor, dict) or set(contributor) != CONTRIBUTOR_KEYS:
            fail("findings_schema_invalid")
        if contributor.get("id") != edge_id:
            fail("findings_schema_invalid")
        confidence = contributor.get("confidence")
        verdict = contributor.get("verdict")
        if phase == "phase1":
            if confidence not in {"low", "medium", "high"} or verdict not in {
                "APPROVE",
                "REVISIONS_REQUIRED",
                "REJECT",
            }:
                fail("findings_schema_invalid")
        elif confidence != "n/a" or verdict != "COMPLETE":
            fail("findings_schema_invalid")
        verdicts[edge_id] = verdict
    raw_findings = value.get("findings")
    if not isinstance(raw_findings, list):
        fail("findings_schema_invalid")
    findings: list[FindingKey] = []
    seen_scopes: set[tuple[str, int]] = set()
    blocker_edges: set[str] = set()
    roster_order = {edge_id: index for index, edge_id in enumerate(roster)}
    for raw in raw_findings:
        if not isinstance(raw, dict) or set(raw) != FINDING_KEYS:
            fail("findings_schema_invalid")
        severity = raw.get("severity")
        if severity not in {"blocker", "suggestion"}:
            fail("findings_schema_invalid")
        summary = _bounded_text(raw.get("summary"), 4096)
        _bounded_text(raw.get("detail"), 16384)
        scope = raw.get("scope")
        if not isinstance(scope, dict) or set(scope) != SCOPE_KEYS:
            fail("findings_schema_invalid")
        path = scope.get("path")
        line = scope.get("line")
        if (
            scope.get("operation") != "modify_existing"
            or type(line) is not int
            or line < 1
            or line > 999_999_999
            or not isinstance(path, str)
        ):
            fail("findings_schema_invalid")
        location = f"{path}:{line}"
        _repo_path_from_location(location)
        scope_key = (path, line)
        if scope_key in seen_scopes:
            fail("findings_schema_invalid")
        seen_scopes.add(scope_key)
        source_edges = raw.get("source_edges")
        if (
            not isinstance(source_edges, list)
            or not source_edges
            or len(source_edges) != len(set(source_edges))
            or any(edge_id not in roster_order for edge_id in source_edges)
            or source_edges != sorted(source_edges, key=roster_order.__getitem__)
        ):
            fail("findings_schema_invalid")
        if severity == "blocker":
            if phase == "phase1" and not any(
                verdicts[edge_id] in {"REVISIONS_REQUIRED", "REJECT"}
                for edge_id in source_edges
            ):
                fail("findings_schema_invalid")
            blocker_edges.update(source_edges)
        findings.append(
            FindingKey(
                len(findings) + 1,
                location,
                hashlib.sha256(summary.encode("utf-8")).hexdigest(),
            )
        )
    if phase == "phase1":
        for edge_id in roster:
            verdict = verdicts[edge_id]
            if (
                verdict in {"REVISIONS_REQUIRED", "REJECT"}
                and edge_id not in blocker_edges
            ):
                fail("findings_schema_invalid")
    return tuple(findings)


def _aggregate_source(phase: Phase) -> str:
    """The untrusted-input envelope source a phase's aggregate is wrapped in.

    ONE derivation (#452). This ternary used to be copied inline into every
    procedure that needed it, which is how a Phase-2-only body could sit behind
    an all-phase name: the axis was invisible at the call site.
    """
    if not isinstance(phase, str) or phase not in PHASE_CONTRIBUTORS:
        fail("findings_schema_invalid")
    return "post-impl-review-aggregate" if phase == "phase1" else "simplify-aggregate"


def encode_aggregate(value: Any, phase: Phase) -> bytes:
    if not isinstance(phase, str) or phase not in PHASE_CONTRIBUTORS:
        fail("findings_schema_invalid")
    _validate_aggregate(value, phase)
    source = _aggregate_source(phase)
    return (
        f'<external-untrusted-input source="{source}">\n'.encode("ascii")
        + _canonical_json(value)
        + b"\n</external-untrusted-input>\n"
    )


def parse_finding_keys(payload: bytes, phase: Phase) -> tuple[FindingKey, ...]:
    if (
        not isinstance(phase, str)
        or phase not in PHASE_CONTRIBUTORS
        or not isinstance(payload, bytes)
    ):
        fail("findings_schema_invalid")
    source = _aggregate_source(phase)
    body = _enveloped_body(payload, source)
    value = _parse_json(body, "findings_schema_invalid")
    findings = _validate_aggregate(value, phase)
    if encode_aggregate(value, phase) != payload:
        fail("findings_not_canonical")
    return findings


def _absolute_input(path: str, reason: str) -> str:
    if (
        not isinstance(path, str)
        or not path
        or not os.path.isabs(path)
        or "\x00" in path
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
    ):
        fail(reason)
    return os.path.realpath(path)


def _run_observational_git(
    repository: str, *arguments: str
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                repository,
                "-c",
                "core.fsmonitor=false",
                *arguments,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
            check=False,
        )
    except OSError:
        fail("git_unavailable")


def _git(repository: str, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return _run_observational_git(repository, *arguments)


def _git_io(
    repository: str,
    *arguments: str,
    payload: bytes | None = None,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    environment = _scrubbed_git_environment()
    if extra_env is not None:
        if not isinstance(extra_env, dict) or not set(extra_env).issubset(
            {"GIT_INDEX_FILE", "GIT_EDITOR"}
        ):
            fail("git_environment_invalid")
        index_path = extra_env.get("GIT_INDEX_FILE")
        if index_path is not None and (
            not isinstance(index_path, str)
            or not index_path
            or not os.path.isabs(index_path)
            or "\x00" in index_path
            or any(ord(character) < 32 or ord(character) == 127 for character in index_path)
        ):
            fail("git_environment_invalid")
        editor = extra_env.get("GIT_EDITOR")
        if editor is not None and editor != ":":
            fail("git_environment_invalid")
        environment.update(extra_env)
    try:
        return subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                repository,
                "-c",
                "core.fsmonitor=false",
                *arguments,
            ],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
        )
    except OSError:
        fail("git_unavailable")


def _index_observation_unchanged(binding: _IndexObservationLock) -> bool:
    try:
        payload, identity = _capture_regular(
            binding.index_path,
            len(binding.index_payload),
            len(binding.index_payload),
        )
    except ContractFailure:
        return False
    return (
        payload == binding.index_payload
        and identity == binding.index_identity
    )


def _cleanup_posix_index_lock(
    lock_path: str,
    descriptor: int,
    lock_identity: tuple[int, int] | None,
    parent_identity: tuple[int, int],
    *,
    require_mode: bool = True,
) -> bool:
    cleanup_succeeded = False
    parent_descriptor = -1
    quarantine_descriptor = -1
    quarantine_path = ""
    try:
        held = os.fstat(descriptor)
        expected_identity = lock_identity or (held.st_dev, held.st_ino)
        if (
            not stat.S_ISREG(held.st_mode)
            or held.st_nlink != 1
            or held.st_size != 0
            or (
                require_mode
                and stat.S_IMODE(held.st_mode) != 0o600
            )
            or (held.st_dev, held.st_ino) != expected_identity
        ):
            return False
        parent_path = os.path.dirname(lock_path)
        directory_flag = getattr(os, "O_DIRECTORY", None)
        nofollow_flag = getattr(os, "O_NOFOLLOW", None)
        if directory_flag is None or nofollow_flag is None:
            return False
        parent_descriptor = os.open(
            parent_path,
            os.O_RDONLY
            | directory_flag
            | nofollow_flag
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened_parent = os.fstat(parent_descriptor)
        visible_parent = os.lstat(parent_path)
        if (
            not stat.S_ISDIR(opened_parent.st_mode)
            or not stat.S_ISDIR(visible_parent.st_mode)
            or (opened_parent.st_dev, opened_parent.st_ino) != parent_identity
            or (visible_parent.st_dev, visible_parent.st_ino) != parent_identity
        ):
            return False
        for _ in range(128):
            candidate = os.path.join(
                parent_path,
                ".code-fixer-index-lock-retired-" + secrets.token_hex(16),
            )
            try:
                atomic_rename_noreplace(lock_path, candidate)
            except FileExistsError:
                continue
            except OSError:
                return False
            quarantine_path = candidate
            break
        if not quarantine_path:
            return False
        os.fsync(parent_descriptor)
        quarantined = os.lstat(quarantine_path)
        quarantine_descriptor = os.open(
            quarantine_path,
            os.O_RDONLY | nofollow_flag | getattr(os, "O_CLOEXEC", 0),
        )
        opened_quarantine = os.fstat(quarantine_descriptor)
        current_parent = os.lstat(parent_path)
        owned = (
            stat.S_ISREG(quarantined.st_mode)
            and stat.S_ISREG(opened_quarantine.st_mode)
            and quarantined.st_nlink == 1
            and opened_quarantine.st_nlink == 1
            and quarantined.st_size == 0
            and opened_quarantine.st_size == 0
            and (
                not require_mode
                or (
                    stat.S_IMODE(quarantined.st_mode) == 0o600
                    and stat.S_IMODE(opened_quarantine.st_mode) == 0o600
                )
            )
            and (quarantined.st_dev, quarantined.st_ino) == expected_identity
            and (opened_quarantine.st_dev, opened_quarantine.st_ino)
            == expected_identity
            and stat.S_ISDIR(current_parent.st_mode)
            and (current_parent.st_dev, current_parent.st_ino) == parent_identity
        )
        os.close(quarantine_descriptor)
        quarantine_descriptor = -1
        if owned:
            # Portable POSIX has no unlink-if-inode primitive.  Retain the
            # verified zero-byte generation under its unpredictable private
            # name so a post-verification same-UID replacement cannot be
            # deleted by this process.
            cleanup_succeeded = True
        else:
            try:
                atomic_rename_noreplace(quarantine_path, lock_path)
            except OSError:
                pass
            try:
                os.fsync(parent_descriptor)
            except OSError:
                pass
    except BaseException:
        cleanup_succeeded = False
    finally:
        for provisional in (quarantine_descriptor, parent_descriptor, descriptor):
            if provisional < 0:
                continue
            try:
                os.close(provisional)
            except BaseException:
                cleanup_succeeded = False
    return cleanup_succeeded


def _windows_index_lock_state(handle: int, reason: str) -> tuple[int, int]:
    if os.name != "nt":
        fail(reason)
    try:
        import ctypes
        from ctypes import wintypes

        class FileStandardInformation(ctypes.Structure):
            _fields_ = [
                ("allocation_size", ctypes.c_longlong),
                ("end_of_file", ctypes.c_longlong),
                ("number_of_links", wintypes.DWORD),
                ("delete_pending", ctypes.c_ubyte),
                ("directory", ctypes.c_ubyte),
            ]

        class FileId128(ctypes.Structure):
            _fields_ = [("identifier", ctypes.c_ubyte * 16)]

        class FileIdInformation(ctypes.Structure):
            _fields_ = [
                ("volume_serial_number", ctypes.c_ulonglong),
                ("file_id", FileId128),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        get_information = kernel32.GetFileInformationByHandleEx
        get_information.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            wintypes.LPVOID,
            wintypes.DWORD,
        ]
        get_information.restype = wintypes.BOOL
        standard = FileStandardInformation()
        identity = FileIdInformation()
        for information_class, information in (
            (1, standard),  # FileStandardInfo
            (18, identity),  # FileIdInfo
        ):
            if not get_information(
                wintypes.HANDLE(handle),
                information_class,
                ctypes.byref(information),
                ctypes.sizeof(information),
            ):
                fail(reason)
        file_id = int.from_bytes(bytes(identity.file_id.identifier), "little")
        volume = int(identity.volume_serial_number)
    except ContractFailure:
        raise
    except (AttributeError, OSError, TypeError, ValueError):
        fail(reason)
    if (
        standard.directory
        or standard.delete_pending
        or standard.number_of_links != 1
        or standard.end_of_file != 0
        or volume == 0
        or file_id == 0
    ):
        fail(reason)
    return volume, file_id


def _windows_create_index_lock(lock_path: str) -> int:
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        create_file = kernel32.CreateFileW
        create_file.argtypes = [
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        ]
        create_file.restype = wintypes.HANDLE
        handle = create_file(
            lock_path,
            0x80000000
            | 0x40000000
            | 0x00010000
            | 0x00000080
            | 0x00000100,  # GENERIC_READ | WRITE | DELETE | attribute access
            0,  # Exclusive sharing blocks open, rename, replacement, and delete.
            None,
            1,  # CREATE_NEW
            0x00000080 | 0x00200000,  # NORMAL | OPEN_REPARSE_POINT
            None,
        )
        invalid_handle = ctypes.c_void_p(-1).value
    except (AttributeError, OSError, TypeError, ValueError):
        fail("index_observation_lock_unavailable")
    if handle in (None, invalid_handle):
        fail("index_observation_lock_unavailable")
    return int(handle)


def _windows_dispose_index_lock(handle: int) -> bool:
    disposition_succeeded = False
    close_succeeded = False
    try:
        import ctypes
        from ctypes import wintypes

        class FileDispositionInformation(ctypes.Structure):
            _fields_ = [("delete_file", ctypes.c_ubyte)]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        set_information = kernel32.SetFileInformationByHandle
        set_information.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            wintypes.LPVOID,
            wintypes.DWORD,
        ]
        set_information.restype = wintypes.BOOL
        disposition = FileDispositionInformation(True)
        disposition_succeeded = bool(
            set_information(
                wintypes.HANDLE(handle),
                4,  # FileDispositionInfo
                ctypes.byref(disposition),
                ctypes.sizeof(disposition),
            )
        )
    except BaseException:
        disposition_succeeded = False
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        close_handle = kernel32.CloseHandle
        close_handle.argtypes = [wintypes.HANDLE]
        close_handle.restype = wintypes.BOOL
        close_succeeded = bool(close_handle(wintypes.HANDLE(handle)))
    except BaseException:
        close_succeeded = False
    return disposition_succeeded and close_succeeded


def _acquire_index_observation_lock(repository: str) -> _IndexObservationLock:
    index_path = _git_index_path(repository)
    lock_path = index_path + ".lock"
    parent_identity = _directory_identity(
        os.path.dirname(index_path), "index_observation_lock_unavailable"
    )[:2]
    if os.name == "nt":
        handle = _windows_create_index_lock(lock_path)
        try:
            lock_identity = _windows_index_lock_state(
                handle, "index_observation_lock_unavailable"
            )
            index_payload, index_identity = _capture_regular(
                index_path, 1, INDEX_LIMIT
            )
        except BaseException:
            if not _windows_dispose_index_lock(handle):
                fail("index_observation_lock_recovery_failed")
            raise
        return _IndexObservationLock(
            index_path=index_path,
            lock_path=lock_path,
            parent_identity=parent_identity,
            index_payload=index_payload,
            index_identity=index_identity,
            lock_identity=lock_identity,
            descriptor=None,
            handle=handle,
        )

    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_BINARY", 0)
    )
    descriptor = -1
    lock_identity: tuple[int, int] | None = None
    mode_normalized = False
    try:
        descriptor = os.open(lock_path, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        mode_normalized = True
        held = os.fstat(descriptor)
        if (
            not stat.S_ISREG(held.st_mode)
            or held.st_nlink != 1
            or held.st_size != 0
            or stat.S_IMODE(held.st_mode) != 0o600
        ):
            fail("index_observation_lock_unavailable")
        lock_identity = (held.st_dev, held.st_ino)
        index_payload, index_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
        return _IndexObservationLock(
            index_path=index_path,
            lock_path=lock_path,
            parent_identity=parent_identity,
            index_payload=index_payload,
            index_identity=index_identity,
            lock_identity=lock_identity,
            descriptor=descriptor,
            handle=None,
        )
    except OSError:
        if descriptor < 0:
            fail("index_observation_lock_unavailable")
        if not _cleanup_posix_index_lock(
            lock_path,
            descriptor,
            lock_identity,
            parent_identity,
            require_mode=mode_normalized,
        ):
            fail("index_observation_lock_recovery_failed")
        fail("index_observation_lock_unavailable")
    except BaseException:
        if descriptor >= 0 and not _cleanup_posix_index_lock(
            lock_path,
            descriptor,
            lock_identity,
            parent_identity,
            require_mode=mode_normalized,
        ):
            fail("index_observation_lock_recovery_failed")
        raise


def _release_index_observation_lock(binding: _IndexObservationLock) -> None:
    unchanged = False
    identity_matches = binding.handle is None
    primary_error: BaseException | None = None
    primary_traceback = None
    try:
        unchanged = _index_observation_unchanged(binding)
        if binding.handle is not None:
            identity_matches = (
                _windows_index_lock_state(
                    binding.handle, "index_observation_lock_recovery_failed"
                )
                == binding.lock_identity
            )
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__

    if binding.handle is not None:
        cleanup_succeeded = _windows_dispose_index_lock(binding.handle)
    elif binding.descriptor is not None:
        cleanup_succeeded = _cleanup_posix_index_lock(
            binding.lock_path,
            binding.descriptor,
            binding.lock_identity,
            binding.parent_identity,
        )
    else:
        cleanup_succeeded = False

    if not cleanup_succeeded:
        fail("index_observation_lock_recovery_failed")
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    if not unchanged or not identity_matches:
        fail("index_observation_lock_recovery_failed")


def _observe_worktree_with_index_lock(
    repository: str, commands: tuple[tuple[str, ...], ...]
) -> tuple[subprocess.CompletedProcess[bytes], ...]:
    binding = _acquire_index_observation_lock(repository)
    try:
        return tuple(
            _run_observational_git(repository, *command) for command in commands
        )
    finally:
        _release_index_observation_lock(binding)


def _require_repository(repository: str) -> None:
    result = _git(repository, "rev-parse", "--show-toplevel")
    if result.returncode != 0:
        fail("working_dir_invalid")
    try:
        top = os.path.realpath(os.fsdecode(result.stdout).strip())
    except UnicodeError:
        fail("working_dir_invalid")
    if top != repository:
        fail("working_dir_mismatch")


SNAPSHOT_LIMIT = 16_777_216
WORKTREE_FILE_LIMIT = 67_108_864
UNTRACKED_PATH_LIMIT = 100_000
UNTRACKED_TOTAL_BYTES_LIMIT = 1_073_741_824
UNTRACKED_LIST_LIMIT = 16_777_216
SNAPSHOT_KEYS = {
    "schema_version",
    "kind",
    "working_dir",
    "evidence_dir",
    "head_sha",
    "head_tree_sha",
    "index_path",
    "index_tree_sha",
    "index_sha256",
    "index_size",
    "index_mode",
    "index_backup_path",
    "diff_path",
    "diff_sha256",
    "target_eligible_paths",
    "tracked",
    "untracked",
}
TRACKED_KEYS = {
    "path",
    "head",
    "index",
    "worktree",
    "head_to_index",
    "index_to_worktree",
    "head_to_worktree",
}
TREE_ENTRY_KEYS = {"mode", "oid"}
INDEX_ENTRY_KEYS = {"mode", "oid", "stage"}
WORKTREE_ENTRY_KEYS = {"kind", "git_mode", "git_oid", "sha256", "size"}
UNTRACKED_ENTRY_KEYS = {"path", "kind", "git_mode", "sha256", "size"}


def _safe_repo_path(path: str) -> str:
    _repo_path_from_location(f"{path}:1")
    return path


def _head_identity(working_dir: str) -> tuple[str, str]:
    head = _git(working_dir, "rev-parse", "--verify", "HEAD")
    tree = _git(working_dir, "rev-parse", "--verify", "HEAD^{tree}")
    if head.returncode != 0 or tree.returncode != 0:
        fail("git_state_unreadable")
    try:
        head_sha = head.stdout.decode("ascii").strip()
        tree_sha = tree.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("git_state_unreadable")
    if (
        SHA1.fullmatch(head_sha) is None
        or SHA1.fullmatch(tree_sha) is None
    ):
        fail("git_state_unreadable")
    return head_sha, tree_sha


def _parse_name_status(payload: bytes, reason: str) -> dict[str, str]:
    if payload and not payload.endswith(b"\x00"):
        fail(reason)
    fields = payload[:-1].split(b"\x00") if payload else []
    if len(fields) % 2:
        fail(reason)
    values: dict[str, str] = {}
    for index in range(0, len(fields), 2):
        try:
            status_value = fields[index].decode("ascii")
            path = fields[index + 1].decode("utf-8")
        except UnicodeError:
            fail(reason)
        if status_value not in {"A", "D", "M", "T", "U"}:
            fail(reason)
        _safe_repo_path(path)
        if path in values:
            fail(reason)
        values[path] = status_value
    return values


def _changed_paths(working_dir: str, head_sha: str) -> tuple[str, ...]:
    commands = (
        ("diff", "--cached", "--name-status", "-z", "--no-renames", head_sha, "--"),
        ("diff", "--name-status", "-z", "--no-renames", "--"),
        ("diff", "--name-status", "-z", "--no-renames", head_sha, "--"),
    )
    paths: set[str] = set()
    for result in _observe_worktree_with_index_lock(working_dir, commands):
        if result.returncode != 0:
            fail("git_state_unreadable")
        paths.update(_parse_name_status(result.stdout, "tracked_path_invalid"))
    return tuple(sorted(paths))


def _tree_entry(working_dir: str, treeish: str, path: str) -> dict[str, str] | None:
    result = _git(working_dir, "ls-tree", "-z", treeish, "--", path)
    if result.returncode != 0:
        fail("git_state_unreadable")
    if not result.stdout:
        return None
    rows = result.stdout.split(b"\x00")
    if rows[-1] != b"" or len(rows) != 2:
        fail("tree_entry_invalid")
    metadata, separator, raw_path = rows[0].partition(b"\t")
    fields = metadata.split(b" ")
    if not separator or len(fields) != 3:
        fail("tree_entry_invalid")
    try:
        mode = fields[0].decode("ascii")
        kind = fields[1].decode("ascii")
        oid = fields[2].decode("ascii")
        decoded_path = raw_path.decode("utf-8")
    except UnicodeError:
        fail("tree_entry_invalid")
    if (
        decoded_path != path
        or mode not in {"100644", "100755", "120000", "160000"}
        or kind not in {"blob", "commit"}
        or (mode == "160000") != (kind == "commit")
        or SHA1.fullmatch(oid) is None
    ):
        fail("tree_entry_invalid")
    return {"mode": mode, "oid": oid}


def _index_entry(working_dir: str, path: str) -> dict[str, Any] | None:
    result = _git(working_dir, "ls-files", "--stage", "-z", "--", path)
    if result.returncode != 0:
        fail("git_state_unreadable")
    if not result.stdout:
        return None
    rows = result.stdout.split(b"\x00")
    if rows[-1] != b"" or len(rows) != 2:
        fail("index_entry_invalid")
    metadata, separator, raw_path = rows[0].partition(b"\t")
    fields = metadata.split(b" ")
    if not separator or len(fields) != 3:
        fail("index_entry_invalid")
    try:
        mode = fields[0].decode("ascii")
        oid = fields[1].decode("ascii")
        stage_text = fields[2].decode("ascii")
        decoded_path = raw_path.decode("utf-8")
    except UnicodeError:
        fail("index_entry_invalid")
    if (
        decoded_path != path
        or mode not in {"100644", "100755", "120000", "160000"}
        or SHA1.fullmatch(oid) is None
        or oid == "0" * 40
        or stage_text != "0"
    ):
        fail("index_entry_invalid")
    return {"mode": mode, "oid": oid, "stage": 0}


def _read_symlink_stable(path: str) -> bytes:
    try:
        first = os.lstat(path)
        target = os.readlink(path).encode("utf-8", "surrogateescape")
        last = os.lstat(path)
    except (OSError, UnicodeError):
        fail("worktree_capture_failed")
    def identity(value: os.stat_result) -> tuple[int, int, int, int, int, int]:
        return (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
    if not stat.S_ISLNK(first.st_mode) or identity(first) != identity(last):
        fail("worktree_replaced")
    return target


def _hash_git_blob(working_dir: str, path: str, payload: bytes) -> str:
    result = _git_io(
        working_dir,
        "hash-object",
        f"--path={path}",
        "--stdin",
        payload=payload,
    )
    if result.returncode != 0:
        fail("worktree_hash_failed")
    try:
        oid = result.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("worktree_hash_failed")
    if SHA1.fullmatch(oid) is None:
        fail("worktree_hash_failed")
    return oid


def _materialize_authenticated_blob(
    working_dir: str, row: dict[str, Any]
) -> None:
    path = row["path"]
    absolute = os.path.join(working_dir, *path.split("/"))
    payload, identity = _capture_regular(
        absolute, row["size"], row["size"]
    )
    observed_mode = "100755" if identity.mode & 0o111 else "100644"
    if (
        observed_mode != row["git_mode"]
        or hashlib.sha256(payload).hexdigest() != row["sha256"]
        or _hash_git_blob(working_dir, path, payload) != row["git_oid"]
    ):
        fail("applied_content_changed")
    result = _git_io(
        working_dir,
        "hash-object",
        "-w",
        f"--path={path}",
        "--stdin",
        payload=payload,
    )
    if result.returncode != 0:
        fail("commit_object_failed")
    try:
        materialized_oid = result.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("commit_object_failed")
    if materialized_oid != row["git_oid"]:
        fail("commit_object_failed")


def _worktree_entry(working_dir: str, path: str) -> dict[str, Any]:
    absolute = os.path.join(working_dir, *path.split("/"))
    if not beneath(working_dir, absolute):
        fail("path_traversal_blocked")
    try:
        entry = os.lstat(absolute)
    except FileNotFoundError:
        return {
            "kind": "missing",
            "git_mode": None,
            "git_oid": None,
            "sha256": None,
            "size": None,
        }
    except OSError:
        fail("worktree_capture_failed")
    if stat.S_ISREG(entry.st_mode):
        payload, _identity = _capture_regular(absolute, 0, WORKTREE_FILE_LIMIT)
        mode = "100755" if entry.st_mode & 0o111 else "100644"
        kind = "regular"
        oid = _hash_git_blob(working_dir, path, payload)
    elif stat.S_ISLNK(entry.st_mode):
        payload = _read_symlink_stable(absolute)
        mode = "120000"
        kind = "symlink"
        result = _git_io(working_dir, "hash-object", "--stdin", payload=payload)
        if result.returncode != 0:
            fail("worktree_hash_failed")
        try:
            oid = result.stdout.decode("ascii").strip()
        except UnicodeError:
            fail("worktree_hash_failed")
        if SHA1.fullmatch(oid) is None:
            fail("worktree_hash_failed")
    else:
        fail("worktree_type_unsupported")
    return {
        "kind": kind,
        "git_mode": mode,
        "git_oid": oid,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
    }


def _entry_relation(left: dict[str, Any] | None, right: dict[str, Any] | None) -> str:
    if left is not None and left.get("kind") == "missing":
        left = None
    if right is not None and right.get("kind") == "missing":
        right = None
    if left is None and right is None:
        return "UNCHANGED"
    if left is None:
        return "A"
    if right is None:
        return "D"
    left_mode = left.get("mode") or left.get("git_mode")
    right_mode = right.get("mode") or right.get("git_mode")
    left_oid = left.get("oid") or left.get("git_oid")
    right_oid = right.get("oid") or right.get("git_oid")
    if not isinstance(left_mode, str) or not isinstance(right_mode, str):
        fail("snapshot_state_invalid")
    if left_mode[:3] != right_mode[:3]:
        return "T"
    if (left_mode, left_oid) == (right_mode, right_oid):
        return "UNCHANGED"
    return "M"


def _untracked_state(working_dir: str, evidence_dir: str) -> list[dict[str, Any]]:
    """U0: the untracked state a verb must find unchanged when it returns.

    `--exclude-standard` is load-bearing, and it is the SAME exclusion
    `_require_untracked_confined_to_evidence` applies — the two spellings of
    "which untracked path is state" must agree or the baseline judges paths
    the residue check has already ruled irrelevant.

    Without it the baseline is self-invalidating. A fixer is REQUIRED to run
    the test suite between the authority mint and `publish-disposition`, and
    running it writes into ignored build and cache trees — vitest drops
    `node_modules/.vite/vitest/<hash>/results.json` on every run. The
    unfiltered scan counted that write as new untracked state and refused the
    fixer's own disposition with `review_baseline_mismatch`, leaving the edits
    unstaged. It also had to hash every ignored path through the owned-regular
    capture, so an ordinary `node_modules` — hardlinked out of the package
    manager's global cache, and holding files past `WORKTREE_FILE_LIMIT` —
    aborted the mint outright, and a clean one still cost a full walk of tens
    of thousands of paths per capture.

    Excluding them costs no guarantee: an ignored path cannot enter the commit
    under review. The diff, the target-path allowlist, and `commit-review` all
    operate on tracked content, and force-adding an ignored path to the index
    surfaces it as tracked state, which `_capture_repo_state` still judges.
    """
    result = _git(
        working_dir,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
    )
    if result.returncode != 0:
        fail("git_state_unreadable")
    if len(result.stdout) > UNTRACKED_LIST_LIMIT:
        fail("untracked_inventory_too_large")
    paths = sorted(_decode_git_paths(result.stdout, "untracked_path_invalid"))
    if len(paths) > UNTRACKED_PATH_LIMIT:
        fail("untracked_inventory_too_large")
    evidence_relative = os.path.relpath(evidence_dir, working_dir).replace(os.sep, "/")
    _safe_repo_path(evidence_relative)
    values: list[dict[str, Any]] = []
    total_size = 0
    for path in paths:
        # Evidence exclusion is lexical. Resolving an untracked symlink here
        # would let a repository-root link disappear from U0 merely because its
        # target happens to live under the evidence directory.
        if path == evidence_relative or path.startswith(evidence_relative + "/"):
            continue
        entry = _worktree_entry(working_dir, path)
        if entry["kind"] not in {"regular", "symlink"}:
            fail("untracked_state_invalid")
        total_size += entry["size"]
        if total_size > UNTRACKED_TOTAL_BYTES_LIMIT:
            fail("untracked_inventory_too_large")
        values.append(
            {
                "path": path,
                "kind": entry["kind"],
                "git_mode": entry["git_mode"],
                "sha256": entry["sha256"],
                "size": entry["size"],
            }
        )
    return values


def _capture_repo_state(working_dir: str, evidence_dir: str) -> dict[str, Any]:
    head_sha, head_tree_sha = _head_identity(working_dir)
    tracked: list[dict[str, Any]] = []
    eligible: list[str] = []
    for path in _changed_paths(working_dir, head_sha):
        head_entry = _tree_entry(working_dir, head_sha, path)
        index_entry = _index_entry(working_dir, path)
        worktree_entry = _worktree_entry(working_dir, path)
        head_to_index = _entry_relation(head_entry, index_entry)
        index_to_worktree = _entry_relation(index_entry, worktree_entry)
        head_to_worktree = _entry_relation(head_entry, worktree_entry)
        row = {
            "path": path,
            "head": head_entry,
            "index": index_entry,
            "worktree": worktree_entry,
            "head_to_index": head_to_index,
            "index_to_worktree": index_to_worktree,
            "head_to_worktree": head_to_worktree,
        }
        tracked.append(row)
        if (
            head_to_worktree == "M"
            and head_entry is not None
            and index_entry is not None
            and head_entry["mode"] in {"100644", "100755"}
            and index_entry["mode"] in {"100644", "100755"}
            and worktree_entry["kind"] == "regular"
            and worktree_entry["git_mode"] in {"100644", "100755"}
        ):
            eligible.append(path)
    untracked = _untracked_state(working_dir, evidence_dir)
    index_tree_sha = _index_tree_sha(working_dir)
    index_path = _git_index_path(working_dir)
    index_payload, index_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
    return {
        "head_sha": head_sha,
        "head_tree_sha": head_tree_sha,
        "index_path": index_path,
        "index_tree_sha": index_tree_sha,
        "index_sha256": hashlib.sha256(index_payload).hexdigest(),
        "index_size": len(index_payload),
        "index_mode": stat.S_IMODE(index_identity.mode),
        "target_eligible_paths": eligible,
        "tracked": tracked,
        "untracked": untracked,
    }


def _entry_matches_artifact_identity(
    entry: os.stat_result, identity: ArtifactIdentity
) -> bool:
    return (
        stat.S_ISREG(entry.st_mode)
        and entry.st_nlink == 1
        and entry.st_size == identity.size
        and (entry.st_dev, entry.st_ino) == (identity.device, identity.inode)
    )


def _restore_replaced_artifact(
    path: str,
    visible_identity: ArtifactIdentity,
    predecessor: bytes,
    *,
    reason: str,
) -> None:
    recovery = ""
    try:
        recovery, recovery_identity, digest = secure_publish_captured(
            path, predecessor
        )
        if digest != hashlib.sha256(predecessor).hexdigest():
            fail(reason)
        current = os.lstat(path)
        if not _entry_matches_artifact_identity(current, visible_identity):
            fail(reason)
        os.replace(recovery, path)
        recovery = ""
        _fsync_directory(os.path.dirname(path))
        captured, restored_identity = _capture_regular(
            path, len(predecessor), len(predecessor)
        )
        if (
            captured != predecessor
            or not _entry_matches_artifact_identity(
                os.lstat(path), recovery_identity
            )
            or (restored_identity.device, restored_identity.inode)
            != (recovery_identity.device, recovery_identity.inode)
        ):
            fail(reason)
    except (ContractFailure, ManifestRejected, ManifestRuntimeError, OSError):
        fail(reason)
    finally:
        if recovery:
            try:
                _cleanup_temporary_paths(recovery)
            except ContractFailure:
                fail(reason)


def _remove_published_artifact(
    path: str, visible_identity: ArtifactIdentity, *, reason: str
) -> None:
    try:
        current = os.lstat(path)
        if not _entry_matches_artifact_identity(current, visible_identity):
            fail(reason)
        os.unlink(path)
        if os.path.lexists(path):
            fail(reason)
        _fsync_directory(os.path.dirname(path))
    except (ContractFailure, OSError):
        fail(reason)


def _rollback_publications(
    rollbacks: list[_ArtifactRollback], *, reason: str
) -> None:
    recovery_failed = False
    for rollback in reversed(rollbacks):
        try:
            if rollback.predecessor is None:
                _remove_published_artifact(
                    rollback.path, rollback.identity, reason=reason
                )
            else:
                _restore_replaced_artifact(
                    rollback.path,
                    rollback.identity,
                    rollback.predecessor,
                    reason=reason,
                )
        except (ContractFailure, OSError):
            recovery_failed = True
    if recovery_failed:
        fail(reason)


def _replace_exact_artifact_record(
    path: str, expected: bytes, payload: bytes, *, maximum: int
) -> tuple[str, str, ArtifactIdentity]:
    captured, identity = _capture_regular(path, len(expected), len(expected))
    if captured != expected:
        fail("artifact_seed_mismatch")
    candidate = ""
    published = False
    completed = False
    published_identity: ArtifactIdentity | None = None
    try:
        candidate, published_identity, digest = secure_publish_captured(path, payload)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or (current.st_dev, current.st_ino) != (identity.device, identity.inode)
            or current.st_size != len(expected)
        ):
            fail("artifact_replaced")
        os.replace(candidate, path)
        published = True
        candidate = ""
        _fsync_directory(os.path.dirname(path))
        capture_expected(path, digest, len(payload), maximum)
        finalized = os.lstat(path)
        if (
            not stat.S_ISREG(finalized.st_mode)
            or finalized.st_nlink != 1
            or (finalized.st_dev, finalized.st_ino)
            != (published_identity.device, published_identity.inode)
        ):
            fail("artifact_publication_invalid")
        completed = True
    except ContractFailure:
        raise
    except (ManifestRejected, ManifestRuntimeError, OSError):
        fail("artifact_publication_failed")
    finally:
        if candidate:
            _cleanup_temporary_paths(candidate)
        if published and not completed:
            if published_identity is None:
                fail("artifact_recovery_failed")
            _restore_replaced_artifact(
                path,
                published_identity,
                expected,
                reason="artifact_recovery_failed",
            )
    if published_identity is None:
        fail("artifact_publication_invalid")
    return path, digest, published_identity


def _replace_exact_artifact(
    path: str, expected: bytes, payload: bytes, *, maximum: int
) -> tuple[str, str]:
    published_path, digest, _identity = _replace_exact_artifact_record(
        path, expected, payload, maximum=maximum
    )
    return published_path, digest


def capture_standalone_snapshot(
    *, working_dir: str, evidence_dir: str, diff_path: str, snapshot_path: str
) -> dict[str, Any]:
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_evidence = _absolute_input(evidence_dir, "evidence_dir_invalid")
    canonical_diff = _absolute_input(diff_path, "diff_path_invalid")
    canonical_snapshot = _absolute_input(snapshot_path, "snapshot_path_invalid")
    if (
        not os.path.isdir(canonical_working)
        or not os.path.isdir(canonical_evidence)
        or not beneath(canonical_working, canonical_evidence)
        or canonical_evidence == canonical_working
        or os.path.dirname(canonical_diff) != canonical_evidence
        or os.path.dirname(canonical_snapshot) != canonical_evidence
        or os.path.basename(canonical_diff) != "pr-diff.md"
        or os.path.basename(canonical_snapshot) != "standalone-snapshot.json"
    ):
        fail("snapshot_path_invalid")
    _require_repository(canonical_working)
    first = _capture_repo_state(canonical_working, canonical_evidence)
    (first_diff,) = _observe_worktree_with_index_lock(
        canonical_working,
        ((
            "diff",
            "HEAD",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
            "--binary",
            "--full-index",
            "--",
        ),),
    )
    if first_diff.returncode != 0:
        fail("diff_capture_failed")
    middle = _capture_repo_state(canonical_working, canonical_evidence)
    (second_diff,) = _observe_worktree_with_index_lock(
        canonical_working,
        ((
            "diff",
            "HEAD",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
            "--binary",
            "--full-index",
            "--",
        ),),
    )
    if second_diff.returncode != 0:
        fail("diff_capture_failed")
    second = _capture_repo_state(canonical_working, canonical_evidence)
    if first != middle or middle != second or first_diff.stdout != second_diff.stdout:
        fail("snapshot_state_drift")
    index_backup_path = os.path.join(
        canonical_evidence, "standalone-index-baseline.bin"
    )
    index_payload = capture_expected(
        first["index_path"], first["index_sha256"], first["index_size"], INDEX_LIMIT
    )
    diff_payload = (
        b'<external-untrusted-input source="pr-diff">\n'
        + first_diff.stdout
        + (
            b""
            if not first_diff.stdout or first_diff.stdout.endswith(b"\n")
            else b"\n"
        )
        + b"</external-untrusted-input>\n"
    )
    diff_sha256 = hashlib.sha256(diff_payload).hexdigest()
    snapshot = {
        "schema_version": 1,
        "kind": "standalone_simplify_baseline",
        "working_dir": canonical_working,
        "evidence_dir": canonical_evidence,
        "head_sha": first["head_sha"],
        "head_tree_sha": first["head_tree_sha"],
        "index_path": first["index_path"],
        "index_tree_sha": first["index_tree_sha"],
        "index_sha256": first["index_sha256"],
        "index_size": first["index_size"],
        "index_mode": first["index_mode"],
        "index_backup_path": index_backup_path,
        "diff_path": canonical_diff,
        "diff_sha256": diff_sha256,
        "target_eligible_paths": first["target_eligible_paths"],
        "tracked": first["tracked"],
        "untracked": first["untracked"],
    }
    snapshot_payload = _canonical_json(snapshot) + b"\n"
    diff_seed = b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        index_backup_sha256, index_backup_identity = (
            _publish_transaction_file_record(
                index_backup_path, index_payload, INDEX_LIMIT
            )
        )
        rollbacks.append(
            _ArtifactRollback(index_backup_path, index_backup_identity, None)
        )
        if index_backup_sha256 != first["index_sha256"]:
            fail("snapshot_index_publication_failed")
        _diff_path, _diff_digest, diff_identity = _replace_exact_artifact_record(
            canonical_diff, diff_seed, diff_payload, maximum=FINDINGS_LIMIT
        )
        rollbacks.append(_ArtifactRollback(canonical_diff, diff_identity, diff_seed))
        published_snapshot, snapshot_sha256, snapshot_identity = (
            _replace_exact_artifact_record(
                canonical_snapshot, b"", snapshot_payload, maximum=SNAPSHOT_LIMIT
            )
        )
        rollbacks.append(
            _ArtifactRollback(canonical_snapshot, snapshot_identity, b"")
        )
        receipt = {
            "snapshot_path": published_snapshot,
            "snapshot_sha256": snapshot_sha256,
            "diff_path": canonical_diff,
            "diff_sha256": diff_sha256,
            "head_sha": first["head_sha"],
            "diff_empty": not bool(first_diff.stdout),
            "target_eligible_paths": first["target_eligible_paths"],
        }
        completed = True
        return receipt
    finally:
        if not completed:
            _rollback_publications(
                rollbacks, reason="snapshot_transaction_recovery_failed"
            )


def _valid_tree_entry(value: Any, *, index: bool) -> bool:
    keys = INDEX_ENTRY_KEYS if index else TREE_ENTRY_KEYS
    if value is None:
        return True
    if not isinstance(value, dict) or set(value) != keys:
        return False
    if (
        value.get("mode") not in {"100644", "100755", "120000", "160000"}
        or not isinstance(value.get("oid"), str)
        or SHA1.fullmatch(value["oid"]) is None
        or value["oid"] == "0" * 40
    ):
        return False
    return not index or type(value.get("stage")) is int and value["stage"] == 0


def _valid_worktree_entry(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != WORKTREE_ENTRY_KEYS:
        return False
    kind = value.get("kind")
    if kind == "missing":
        return all(
            value.get(key) is None
            for key in ("git_mode", "git_oid", "sha256", "size")
        )
    expected_mode = "120000" if kind == "symlink" else None
    if kind == "regular":
        valid_mode = value.get("git_mode") in {"100644", "100755"}
    elif kind == "symlink":
        valid_mode = value.get("git_mode") == expected_mode
    else:
        return False
    return (
        valid_mode
        and isinstance(value.get("git_oid"), str)
        and SHA1.fullmatch(value["git_oid"]) is not None
        and isinstance(value.get("sha256"), str)
        and SHA256.fullmatch(value["sha256"]) is not None
        and type(value.get("size")) is int
        and 0 <= value["size"] <= WORKTREE_FILE_LIMIT
    )


def _load_snapshot(path: str, digest: str) -> dict[str, Any]:
    canonical_path = _absolute_input(path, "snapshot_path_invalid")
    payload = capture_expected(canonical_path, digest, 1, SNAPSHOT_LIMIT)
    value = _parse_json(payload, "snapshot_json_invalid")
    if (
        not isinstance(value, dict)
        or set(value) != SNAPSHOT_KEYS
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("kind") != "standalone_simplify_baseline"
        or _canonical_json(value) + b"\n" != payload
    ):
        fail("snapshot_schema_invalid")
    for key, reason in (
        ("working_dir", "snapshot_schema_invalid"),
        ("evidence_dir", "snapshot_schema_invalid"),
        ("diff_path", "snapshot_schema_invalid"),
    ):
        item = value.get(key)
        if not isinstance(item, str) or _absolute_input(item, reason) != item:
            fail("snapshot_schema_invalid")
    if (
        not isinstance(value.get("head_sha"), str)
        or SHA1.fullmatch(value["head_sha"]) is None
        or not isinstance(value.get("head_tree_sha"), str)
        or SHA1.fullmatch(value["head_tree_sha"]) is None
        or not isinstance(value.get("index_tree_sha"), str)
        or SHA1.fullmatch(value["index_tree_sha"]) is None
        or not isinstance(value.get("index_sha256"), str)
        or SHA256.fullmatch(value["index_sha256"]) is None
        or type(value.get("index_size")) is not int
        or value["index_size"] < 1
        or value["index_size"] > INDEX_LIMIT
        or type(value.get("index_mode")) is not int
        or value["index_mode"] < 0
        or value["index_mode"] > 0o777
        or not isinstance(value.get("diff_sha256"), str)
        or SHA256.fullmatch(value["diff_sha256"]) is None
        or value["evidence_dir"] == value["working_dir"]
        or not beneath(value["working_dir"], value["evidence_dir"])
        or os.path.dirname(value["diff_path"]) != value["evidence_dir"]
        or os.path.basename(value["diff_path"]) != "pr-diff.md"
        or os.path.dirname(canonical_path) != value["evidence_dir"]
        or os.path.basename(canonical_path) != "standalone-snapshot.json"
    ):
        fail("snapshot_schema_invalid")
    expected_index_path = _git_index_path(value["working_dir"])
    index_path = value.get("index_path")
    index_backup_path = value.get("index_backup_path")
    if (
        not isinstance(index_path, str)
        or _absolute_input(index_path, "snapshot_schema_invalid") != index_path
        or index_path != expected_index_path
        or not isinstance(index_backup_path, str)
        or _absolute_input(index_backup_path, "snapshot_schema_invalid")
        != index_backup_path
        or os.path.dirname(index_backup_path) != value["evidence_dir"]
        or os.path.basename(index_backup_path) != "standalone-index-baseline.bin"
    ):
        fail("snapshot_schema_invalid")
    tracked = value.get("tracked")
    if not isinstance(tracked, list):
        fail("snapshot_schema_invalid")
    seen: set[str] = set()
    derived_eligible: list[str] = []
    previous = ""
    for row in tracked:
        if not isinstance(row, dict) or set(row) != TRACKED_KEYS:
            fail("snapshot_schema_invalid")
        path_value = row.get("path")
        if (
            not isinstance(path_value, str)
            or path_value <= previous
            or path_value in seen
        ):
            fail("snapshot_schema_invalid")
        _safe_repo_path(path_value)
        previous = path_value
        seen.add(path_value)
        if (
            not _valid_tree_entry(row.get("head"), index=False)
            or not _valid_tree_entry(row.get("index"), index=True)
            or not _valid_worktree_entry(row.get("worktree"))
        ):
            fail("snapshot_schema_invalid")
        relations = (
            _entry_relation(row["head"], row["index"]),
            _entry_relation(row["index"], row["worktree"]),
            _entry_relation(row["head"], row["worktree"]),
        )
        if relations != (
            row.get("head_to_index"),
            row.get("index_to_worktree"),
            row.get("head_to_worktree"),
        ) or relations == ("UNCHANGED", "UNCHANGED", "UNCHANGED"):
            fail("snapshot_schema_invalid")
        if (
            row["head_to_worktree"] == "M"
            and row["head"] is not None
            and row["index"] is not None
            and row["head"]["mode"] in {"100644", "100755"}
            and row["index"]["mode"] in {"100644", "100755"}
            and row["worktree"]["kind"] == "regular"
            and row["worktree"]["git_mode"] in {"100644", "100755"}
        ):
            derived_eligible.append(path_value)
    if value.get("target_eligible_paths") != derived_eligible:
        fail("snapshot_schema_invalid")
    untracked = value.get("untracked")
    if not isinstance(untracked, list):
        fail("snapshot_schema_invalid")
    previous = ""
    for row in untracked:
        if not isinstance(row, dict) or set(row) != UNTRACKED_ENTRY_KEYS:
            fail("snapshot_schema_invalid")
        path_value = row.get("path")
        if (
            not isinstance(path_value, str)
            or path_value <= previous
            or row.get("kind") not in {"regular", "symlink"}
            or row.get("git_mode")
            != ("120000" if row.get("kind") == "symlink" else row.get("git_mode"))
            or row.get("git_mode") not in {"100644", "100755", "120000"}
            or not isinstance(row.get("sha256"), str)
            or SHA256.fullmatch(row["sha256"]) is None
            or type(row.get("size")) is not int
            or row["size"] < 0
            or row["size"] > WORKTREE_FILE_LIMIT
        ):
            fail("snapshot_schema_invalid")
        _safe_repo_path(path_value)
        previous = path_value
    capture_expected(value["diff_path"], value["diff_sha256"], 1, FINDINGS_LIMIT)
    capture_expected(
        value["index_backup_path"],
        value["index_sha256"],
        value["index_size"],
        INDEX_LIMIT,
    )
    return value


def _snapshot_state(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        key: snapshot[key]
        for key in (
            "head_sha",
            "head_tree_sha",
            "index_path",
            "index_tree_sha",
            "index_sha256",
            "index_size",
            "index_mode",
            "target_eligible_paths",
            "tracked",
            "untracked",
        )
    }


def _require_snapshot_index_current(snapshot: dict[str, Any]) -> None:
    payload, identity = _capture_regular(
        snapshot["index_path"], snapshot["index_size"], snapshot["index_size"]
    )
    if (
        hashlib.sha256(payload).hexdigest() != snapshot["index_sha256"]
        or stat.S_IMODE(identity.mode) != snapshot["index_mode"]
    ):
        fail("standalone_index_mismatch")


def _require_snapshot_current(snapshot: dict[str, Any]) -> None:
    _require_snapshot_index_current(snapshot)
    current = _capture_repo_state(snapshot["working_dir"], snapshot["evidence_dir"])
    if current != _snapshot_state(snapshot):
        fail("standalone_baseline_mismatch")
    _require_snapshot_index_current(snapshot)


def _target_paths(
    findings: tuple[FindingKey, ...], working_dir: str
) -> tuple[str, ...]:
    targets: list[str] = []
    seen: set[str] = set()
    for finding in findings:
        target = _repo_path_from_location(finding.location)
        absolute = os.path.realpath(os.path.join(working_dir, *target.split("/")))
        if not beneath(working_dir, absolute):
            fail("path_traversal_blocked")
        if target not in seen:
            targets.append(target)
            seen.add(target)
    return tuple(targets)


def _decode_git_paths(payload: bytes, reason: str) -> tuple[str, ...]:
    paths: list[str] = []
    for raw in payload.split(b"\x00"):
        if not raw:
            continue
        try:
            path = raw.decode("utf-8")
        except UnicodeError:
            fail(reason)
        _repo_path_from_location(f"{path}:1")
        paths.append(path)
    if len(paths) != len(set(paths)):
        fail(reason)
    return tuple(paths)


def _reserved_evidence_residue(path: str) -> bool:
    basename = posixpath.basename(path)
    return basename in {
        "standalone-commit-transaction.json",
        "standalone-index-backup.bin",
    } or basename.startswith(
        (
            ".standalone-index-",
            ".standalone-real-index-",
            ".standalone-message-",
            "review-commit-transaction-",
            "review-index-backup-",
        )
    )


def _require_untracked_confined_to_evidence(
    working_dir: str, evidence_dir: str, *, outside_failure: str
) -> None:
    """The ONE answer to "which untracked path is legitimate mid-verb".

    Named once because two spellings of it drift: the Phase 3 conflict judge
    started life with a bare "any untracked path at all is scope escape" scan,
    which contradicted this predicate twenty lines away and refused every
    resolver in any repository that had not ignored `.uberdev/` — the run's own
    evidence tree is untracked THERE and only masked HERE by this repository's
    own .gitignore.

    `outside_failure` is the only per-caller difference: a residue check calls
    an escapee `worktree_untracked`, the conflict judge calls it
    `ci_conflict_scope_escape`, and both mean the same thing.
    """
    untracked = _git(
        working_dir,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
    )
    if untracked.returncode != 0:
        fail("git_state_unreadable")
    evidence_relative = os.path.relpath(evidence_dir, working_dir).replace(os.sep, "/")
    _safe_repo_path(evidence_relative)
    evidence_components = tuple(evidence_relative.split("/"))
    for path in _decode_git_paths(untracked.stdout, "worktree_path_invalid"):
        path_components = tuple(path.split("/"))
        absolute = os.path.join(working_dir, *path_components)
        try:
            os.lstat(absolute)
        except OSError:
            fail(outside_failure)
        in_evidence = (
            path_components[: len(evidence_components)] == evidence_components
        )
        if not in_evidence:
            fail(outside_failure)
        if _reserved_evidence_residue(path):
            fail("temporary_residue")


def _require_worktree_residue_closed(working_dir: str, evidence_dir: str) -> None:
    (unstaged,) = _observe_worktree_with_index_lock(
        working_dir, (("diff", "--quiet", "--exit-code", "--"),)
    )
    if unstaged.returncode == 1:
        fail("worktree_unstaged")
    if unstaged.returncode != 0:
        fail("git_state_unreadable")
    _require_untracked_confined_to_evidence(
        working_dir, evidence_dir, outside_failure="worktree_untracked"
    )


def _require_clean_worktree(working_dir: str, evidence_dir: str) -> None:
    cached = _git(working_dir, "diff", "--cached", "--quiet", "--exit-code", "--")
    if cached.returncode == 1:
        fail("index_dirty")
    if cached.returncode != 0:
        fail("git_state_unreadable")
    _require_worktree_residue_closed(working_dir, evidence_dir)


def validate_residue(*, working_dir: str, evidence_dir: str) -> dict[str, str]:
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_evidence = _absolute_input(evidence_dir, "evidence_dir_invalid")
    if not os.path.isdir(canonical_working) or not os.path.isdir(canonical_evidence):
        fail("residue_directory_invalid")
    _require_repository(canonical_working)
    if (
        canonical_evidence == canonical_working
        or not beneath(canonical_working, canonical_evidence)
    ):
        fail("evidence_dir_invalid")
    _require_clean_worktree(canonical_working, canonical_evidence)
    return {"status": "clean"}


def validate_failed_return(
    *,
    working_dir: str,
    evidence_dir: str,
    head_before: str,
    snapshot_path: str | None = None,
    snapshot_sha256: str | None = None,
) -> dict[str, str]:
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_evidence = _absolute_input(evidence_dir, "evidence_dir_invalid")
    if (
        not os.path.isdir(canonical_working)
        or not os.path.isdir(canonical_evidence)
        or canonical_evidence == canonical_working
        or not beneath(canonical_working, canonical_evidence)
        or SHA1.fullmatch(head_before or "") is None
    ):
        fail("failed_return_guard_invalid")
    _require_repository(canonical_working)
    has_snapshot_path = snapshot_path is not None
    has_snapshot_digest = snapshot_sha256 is not None
    if has_snapshot_path != has_snapshot_digest:
        fail("failed_return_guard_invalid")
    initial_head, _initial_tree = _head_identity(canonical_working)
    if initial_head != head_before:
        fail("fixer_return_mutated")
    if has_snapshot_path:
        canonical_snapshot = _absolute_input(
            snapshot_path, "snapshot_path_invalid"
        )
        snapshot = _load_snapshot(canonical_snapshot, snapshot_sha256 or "")
        if (
            snapshot["working_dir"] != canonical_working
            or snapshot["evidence_dir"] != canonical_evidence
            or snapshot["head_sha"] != head_before
        ):
            fail("failed_return_guard_invalid")
        _require_snapshot_current(snapshot)
    else:
        _require_clean_worktree(canonical_working, canonical_evidence)
    final_head, _final_tree = _head_identity(canonical_working)
    if final_head != initial_head or final_head != head_before:
        fail("fixer_return_mutated")
    return {"status": "clean"}


def _commit_range_endpoints(payload: bytes) -> tuple[str, str]:
    if COMMIT_RANGE.fullmatch(payload) is None:
        fail("commit_range_invalid")
    try:
        base_raw, head_raw = payload.removesuffix(b"\n").split(b"..", 1)
        base = base_raw.decode("ascii")
        head = head_raw.decode("ascii")
    except (UnicodeError, ValueError):
        fail("commit_range_invalid")
    return base, head


def _require_targets_in_reviewed_range(
    working_dir: str,
    range_payload: bytes,
    target_paths: tuple[str, ...],
    *,
    expected_head: str | None = None,
) -> None:
    base, head = _commit_range_endpoints(range_payload)
    if expected_head is None:
        current = _git(working_dir, "rev-parse", "--verify", "HEAD")
        if current.returncode != 0:
            fail("git_state_unreadable")
        try:
            expected_head = current.stdout.decode("ascii").strip()
        except UnicodeError:
            fail("git_state_unreadable")
    if SHA1.fullmatch(expected_head) is None or head != expected_head:
        fail("commit_range_head_mismatch")
    ancestor = _git(working_dir, "merge-base", "--is-ancestor", base, head)
    if ancestor.returncode == 1:
        fail("commit_range_ancestry_invalid")
    if ancestor.returncode != 0:
        fail("git_state_unreadable")
    changed = _git(
        working_dir,
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        f"{base}..{head}",
        "--",
    )
    if changed.returncode != 0:
        fail("git_state_unreadable")
    changed_paths = set(_decode_git_paths(changed.stdout, "commit_range_path_invalid"))
    if any(path not in changed_paths for path in target_paths):
        fail("finding_outside_commit_range")


AUTHORITY_KEYS = {
    "schema_version",
    "edge_id",
    "policy_phase",
    "phase",
    "commit_type",
    "findings_path",
    "findings_sha256",
    "commit_range_path",
    "commit_range_sha256",
    "working_dir",
    "disposition_path",
    "finding_keys",
    "target_paths",
    "parent_sha",
    "parent_tree_sha",
    "index_path",
    "index_tree_sha",
    "index_sha256",
    "index_size",
    "index_mode",
    "untracked",
}
STANDALONE_AUTHORITY_KEYS = {
    "schema_version",
    "edge_id",
    "policy_phase",
    "phase",
    "commit_type",
    "findings_path",
    "findings_sha256",
    "standalone_snapshot_path",
    "standalone_snapshot_sha256",
    "working_dir",
    "disposition_path",
    "finding_keys",
    "target_paths",
}


def _publish_new_exact_record(
    path: str, payload: bytes
) -> tuple[str, str, ArtifactIdentity]:
    if os.path.lexists(path):
        fail("authority_preexists")
    candidate = ""
    published = False
    completed = False
    try:
        candidate, identity, digest = secure_publish_captured(path, payload)
        if os.path.lexists(path):
            fail("authority_preexists")
        os.link(candidate, path, follow_symlinks=False)
        published = True
        os.unlink(candidate)
        candidate = ""
        current = os.lstat(path)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or (current.st_dev, current.st_ino) != (identity.device, identity.inode)
        ):
            fail("authority_publication_invalid")
        capture_expected(path, digest, 1, AUTHORITY_LIMIT)
        _fsync_directory(os.path.dirname(path))
        completed = True
    except ContractFailure:
        raise
    except (ManifestRejected, ManifestRuntimeError, OSError):
        fail("authority_publication_failed")
    finally:
        if candidate:
            _cleanup_temporary_paths(candidate)
        if published and not completed:
            _remove_published_artifact(
                path, identity, reason="authority_cleanup_failed"
            )
    return path, digest, identity


def _publish_new_exact(path: str, payload: bytes) -> tuple[str, str]:
    published_path, digest, _identity = _publish_new_exact_record(path, payload)
    return published_path, digest


def prepare_authority(
    *,
    edge_id: str,
    policy_phase: str,
    findings_path: str,
    findings_sha256: str,
    commit_range_path: str,
    commit_range_sha256: str,
    working_dir: str,
    disposition_path: str,
    authority_output_path: str | None = None,
) -> dict[str, Any]:
    route = route_authority(edge_id, policy_phase)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if not os.path.isdir(canonical_working):
        fail("working_dir_invalid")
    _require_repository(canonical_working)
    findings_payload = capture_expected(
        findings_path, findings_sha256, 1, FINDINGS_LIMIT
    )
    range_payload = capture_expected(
        commit_range_path, commit_range_sha256, 1, RANGE_LIMIT
    )
    _capture_regular(disposition_path, 0, 0)
    canonical_findings = _absolute_input(findings_path, "findings_path_invalid")
    canonical_range = _absolute_input(commit_range_path, "commit_range_path_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    for path in (canonical_findings, canonical_range, canonical_disposition):
        if not beneath(canonical_working, path):
            fail("artifact_path_outside_working_dir")
    parent = os.path.dirname(canonical_findings)
    if (
        parent == canonical_working
        or not beneath(canonical_working, parent)
        or os.path.dirname(canonical_range) != parent
        or os.path.dirname(canonical_disposition) != parent
        or os.path.basename(canonical_disposition)
        != f"{route.phase}-disposition.json"
    ):
        fail("disposition_path_invalid")
    _commit_range_endpoints(range_payload)
    finding_keys = parse_finding_keys(findings_payload, route.phase)
    target_paths = _target_paths(finding_keys, canonical_working)
    _require_targets_in_reviewed_range(canonical_working, range_payload, target_paths)
    _require_clean_worktree(canonical_working, parent)
    baseline = _capture_repo_state(canonical_working, parent)
    if baseline["tracked"]:
        fail("review_baseline_dirty")
    authority = {
        "schema_version": 1,
        "edge_id": route.edge_id,
        "policy_phase": route.policy_phase,
        "phase": route.phase,
        "commit_type": route.commit_type,
        "findings_path": canonical_findings,
        "findings_sha256": findings_sha256,
        "commit_range_path": canonical_range,
        "commit_range_sha256": commit_range_sha256,
        "working_dir": canonical_working,
        "disposition_path": canonical_disposition,
        "finding_keys": [asdict(item) for item in finding_keys],
        "target_paths": list(target_paths),
        "parent_sha": baseline["head_sha"],
        "parent_tree_sha": baseline["head_tree_sha"],
        "index_path": baseline["index_path"],
        "index_tree_sha": baseline["index_tree_sha"],
        "index_sha256": baseline["index_sha256"],
        "index_size": baseline["index_size"],
        "index_mode": baseline["index_mode"],
        "untracked": baseline["untracked"],
    }
    payload = (
        json.dumps(authority, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        .encode()
        + b"\n"
    )
    authority_path = (
        os.path.join(parent, f"code-fixer-authority-{route.phase}.json")
        if authority_output_path is None
        else _absolute_input(authority_output_path, "authority_path_invalid")
    )
    if (
        os.path.dirname(authority_path) != parent
        or re.fullmatch(
            rf"code-fixer-authority-{route.phase}(?:-iter[1-9][0-9]{{0,8}})?\.json",
            os.path.basename(authority_path),
        )
        is None
    ):
        fail("authority_path_invalid")
    published_path, digest = _publish_new_exact(authority_path, payload)
    return {
        "authority_path": published_path,
        "authority_sha256": digest,
        "phase": route.phase,
        "commit_type": route.commit_type,
        "target_paths": list(target_paths),
    }


def prepare_standalone_authority(
    *,
    edge_id: str,
    policy_phase: str,
    findings_path: str,
    findings_sha256: str,
    snapshot_path: str,
    snapshot_sha256: str,
    working_dir: str,
    disposition_path: str,
) -> dict[str, Any]:
    route = route_authority(edge_id, policy_phase)
    if route.edge_id != "simplify.fix.phase2":
        fail("route_authority_invalid")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if not os.path.isdir(canonical_working):
        fail("working_dir_invalid")
    _require_repository(canonical_working)
    findings_payload = capture_expected(
        findings_path, findings_sha256, 1, FINDINGS_LIMIT
    )
    snapshot = _load_snapshot(snapshot_path, snapshot_sha256)
    _capture_regular(disposition_path, 0, 0)
    canonical_findings = _absolute_input(findings_path, "findings_path_invalid")
    canonical_snapshot = _absolute_input(snapshot_path, "snapshot_path_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    evidence_dir = snapshot["evidence_dir"]
    if (
        canonical_working != snapshot["working_dir"]
        or any(
            os.path.dirname(path) != evidence_dir
            for path in (canonical_findings, canonical_snapshot, canonical_disposition)
        )
        or os.path.basename(canonical_findings) != "simplify-final.md"
        or os.path.basename(canonical_snapshot) != "standalone-snapshot.json"
        or os.path.basename(canonical_disposition) != "phase2-disposition.json"
    ):
        fail("artifact_path_outside_working_dir")
    _require_snapshot_current(snapshot)
    finding_keys = parse_finding_keys(findings_payload, "phase2")
    target_paths = _target_paths(finding_keys, canonical_working)
    eligible = set(snapshot["target_eligible_paths"])
    if any(path not in eligible for path in target_paths):
        fail("finding_outside_standalone_snapshot")
    authority = {
        "schema_version": 1,
        "edge_id": route.edge_id,
        "policy_phase": route.policy_phase,
        "phase": route.phase,
        "commit_type": route.commit_type,
        "findings_path": canonical_findings,
        "findings_sha256": findings_sha256,
        "standalone_snapshot_path": canonical_snapshot,
        "standalone_snapshot_sha256": snapshot_sha256,
        "working_dir": canonical_working,
        "disposition_path": canonical_disposition,
        "finding_keys": [asdict(item) for item in finding_keys],
        "target_paths": list(target_paths),
    }
    payload = _canonical_json(authority) + b"\n"
    authority_path = os.path.join(evidence_dir, "code-fixer-authority-phase2.json")
    published_path, digest = _publish_new_exact(authority_path, payload)
    return {
        "authority_path": published_path,
        "authority_sha256": digest,
        "phase": route.phase,
        "commit_type": route.commit_type,
        "target_paths": list(target_paths),
    }


def _load_authority(path: str, digest: str) -> dict[str, Any]:
    value = _parse_json(
        capture_expected(path, digest, 1, AUTHORITY_LIMIT),
        "authority_json_invalid",
    )
    if not isinstance(value, dict) or frozenset(value) not in {
        frozenset(AUTHORITY_KEYS),
        frozenset(STANDALONE_AUTHORITY_KEYS),
    }:
        fail("authority_schema_invalid")
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        fail("authority_schema_invalid")
    route = route_authority(value.get("edge_id"), value.get("policy_phase"))
    if (value.get("phase"), value.get("commit_type")) != (
        route.phase,
        route.commit_type,
    ):
        fail("authority_route_mismatch")
    standalone = route.edge_id == "simplify.fix.phase2"
    expected_keys = STANDALONE_AUTHORITY_KEYS if standalone else AUTHORITY_KEYS
    if set(value) != expected_keys:
        fail("authority_schema_invalid")
    path_keys = ["findings_path", "working_dir", "disposition_path"]
    path_keys.append("standalone_snapshot_path" if standalone else "commit_range_path")
    for key in path_keys:
        item = value.get(key)
        if not isinstance(item, str) or _absolute_input(
            item, "authority_schema_invalid"
        ) != item:
            fail("authority_schema_invalid")
    digest_keys = ["findings_sha256"]
    digest_keys.append(
        "standalone_snapshot_sha256" if standalone else "commit_range_sha256"
    )
    for key in digest_keys:
        item = value.get(key)
        if not isinstance(item, str) or SHA256.fullmatch(item) is None:
            fail("authority_schema_invalid")
    if not standalone:
        if (
            SHA1.fullmatch(value.get("parent_sha", "")) is None
            or SHA1.fullmatch(value.get("parent_tree_sha", ""))
            is None
            or SHA1.fullmatch(value.get("index_tree_sha", ""))
            is None
            or not isinstance(value.get("index_path"), str)
            or _absolute_input(value["index_path"], "authority_schema_invalid")
            != value["index_path"]
            or not isinstance(value.get("index_sha256"), str)
            or SHA256.fullmatch(value["index_sha256"]) is None
            or type(value.get("index_size")) is not int
            or value["index_size"] < 1
            or value["index_size"] > INDEX_LIMIT
            or type(value.get("index_mode")) is not int
            or value["index_mode"] < 0
            or value["index_mode"] > 0o7777
            or not isinstance(value.get("untracked"), list)
        ):
            fail("authority_schema_invalid")
        previous_untracked = ""
        for row in value["untracked"]:
            if (
                not isinstance(row, dict)
                or set(row) != UNTRACKED_ENTRY_KEYS
                or not isinstance(row.get("path"), str)
                or row["path"] <= previous_untracked
                or row.get("kind") not in {"regular", "symlink"}
                or row.get("git_mode") not in {"100644", "100755", "120000"}
                or (row["kind"] == "symlink") != (row["git_mode"] == "120000")
                or not isinstance(row.get("sha256"), str)
                or SHA256.fullmatch(row["sha256"]) is None
                or type(row.get("size")) is not int
                or row["size"] < 0
                or row["size"] > WORKTREE_FILE_LIMIT
            ):
                fail("authority_schema_invalid")
            _safe_repo_path(row["path"])
            previous_untracked = row["path"]
    raw_keys = value.get("finding_keys")
    if not isinstance(raw_keys, list):
        fail("authority_schema_invalid")
    finding_keys: list[FindingKey] = []
    for expected_index, item in enumerate(raw_keys, 1):
        if not isinstance(item, dict) or set(item) != {
            "finding_index",
            "location",
            "summary_sha256",
        }:
            fail("authority_schema_invalid")
        if (
            type(item.get("finding_index")) is not int
            or item["finding_index"] != expected_index
            or not isinstance(item.get("location"), str)
            or not isinstance(item.get("summary_sha256"), str)
            or SHA256.fullmatch(item["summary_sha256"]) is None
        ):
            fail("authority_schema_invalid")
        _repo_path_from_location(item["location"])
        finding_keys.append(FindingKey(**item))
    target_paths = _target_paths(tuple(finding_keys), value["working_dir"])
    if value.get("target_paths") != list(target_paths):
        fail("authority_schema_invalid")
    expected_authority_name = (
        rf"code-fixer-authority-{route.phase}\.json"
        if standalone
        else rf"code-fixer-authority-{route.phase}(?:-iter[1-9][0-9]{{0,8}})?\.json"
    )
    if re.fullmatch(expected_authority_name, os.path.basename(path)) is None:
        fail("authority_path_invalid")
    evidence_dir = os.path.dirname(value["findings_path"])
    secondary_path = (
        value["standalone_snapshot_path"] if standalone else value["commit_range_path"]
    )
    expected_secondary_name = (
        "standalone-snapshot.json" if standalone else "commit-range.txt"
    )
    if (
        evidence_dir == value["working_dir"]
        or not beneath(value["working_dir"], evidence_dir)
        or os.path.dirname(secondary_path) != evidence_dir
        or os.path.basename(secondary_path) != expected_secondary_name
        or os.path.dirname(value["disposition_path"]) != evidence_dir
        or os.path.basename(value["disposition_path"])
        != f"{route.phase}-disposition.json"
        or os.path.dirname(path) != evidence_dir
        or not beneath(value["working_dir"], path)
    ):
        fail("authority_path_invalid")
    return value


def consume_authority(
    *,
    edge_id: str,
    policy_phase: str,
    authority_path: str,
    authority_sha256: str,
    findings_path: str,
    findings_sha256: str,
    working_dir: str,
    disposition_path: str,
    commit_range_path: str = "",
    commit_range_sha256: str = "",
    snapshot_path: str = "",
    snapshot_sha256: str = "",
) -> dict[str, Any]:
    route = route_authority(edge_id, policy_phase)
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_findings = _absolute_input(findings_path, "findings_path_invalid")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        authority["edge_id"] != route.edge_id
        or authority["policy_phase"] != route.policy_phase
        or authority["findings_path"] != canonical_findings
        or authority["findings_sha256"] != findings_sha256
        or authority["working_dir"] != canonical_working
        or authority["disposition_path"] != canonical_disposition
    ):
        fail("authority_input_mismatch")
    if route.edge_id == "simplify.fix.phase2":
        if commit_range_path or commit_range_sha256:
            fail("authority_input_mismatch")
        if (
            authority["standalone_snapshot_path"]
            != _absolute_input(snapshot_path, "snapshot_path_invalid")
            or authority["standalone_snapshot_sha256"] != snapshot_sha256
        ):
            fail("authority_input_mismatch")
        snapshot = _recapture_sources(authority)
        if snapshot is None:
            fail("standalone_authority_required")
        _require_snapshot_current(snapshot)
    else:
        if snapshot_path or snapshot_sha256:
            fail("authority_input_mismatch")
        if (
            authority["commit_range_path"]
            != _absolute_input(commit_range_path, "commit_range_path_invalid")
            or authority["commit_range_sha256"] != commit_range_sha256
        ):
            fail("authority_input_mismatch")
        _recapture_sources(authority, expected_range_head=authority["parent_sha"])
        _require_review_edit_state(authority, ())
    return {
        "authority_path": canonical_authority,
        "authority_sha256": authority_sha256,
        "phase": route.phase,
        "commit_type": route.commit_type,
        "target_paths": authority["target_paths"],
    }


DISPOSITION_KEYS = {
    "schema_version",
    "phase",
    "aggregate_sha256",
    "findings_disposition",
}
DISPOSITION_ROW_KEYS = {
    "finding_index",
    "location",
    "summary_sha256",
    "disposition",
    "behavior_tag",
    "reason",
}
APPLIED_CONTENT_PLAN_LIMIT = 1_048_576
APPLIED_CONTENT_PLAN_KEYS = {
    "schema_version",
    "authority_sha256",
    "disposition_sha256",
    "applied",
}
APPLIED_CONTENT_ROW_KEYS = {"path", "git_mode", "git_oid", "sha256", "size"}


def _validate_disposition(
    value: Any, authority: dict[str, Any]
) -> tuple[str, ...]:
    if not isinstance(value, dict) or set(value) != DISPOSITION_KEYS:
        fail("disposition_schema_invalid")
    if (
        type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("phase") != authority["phase"]
        or value.get("aggregate_sha256") != authority["findings_sha256"]
    ):
        fail("disposition_authority_mismatch")
    rows = value.get("findings_disposition")
    expected = authority["finding_keys"]
    if not isinstance(rows, list) or len(rows) != len(expected):
        fail("disposition_finding_mismatch")
    applied: list[str] = []
    seen_paths: set[str] = set()
    for row, finding in zip(rows, expected, strict=True):
        if not isinstance(row, dict) or set(row) != DISPOSITION_ROW_KEYS:
            fail("disposition_schema_invalid")
        triple = {
            key: row.get(key)
            for key in ("finding_index", "location", "summary_sha256")
        }
        if triple != finding:
            fail("disposition_finding_mismatch")
        disposition = row.get("disposition")
        behavior_tag = row.get("behavior_tag")
        reason = row.get("reason")
        if not isinstance(disposition, str) or disposition not in {
            "APPLIED",
            "SKIPPED",
            "REFUSED",
        }:
            fail("disposition_schema_invalid")
        if not isinstance(behavior_tag, str) or behavior_tag not in {
            "preserve",
            "change",
            "n/a",
        }:
            fail("disposition_schema_invalid")
        allowed_applied_tags = (
            {"preserve"} if authority["phase"] == "phase2" else {"preserve", "change"}
        )
        if (disposition == "APPLIED" and behavior_tag not in allowed_applied_tags) or (
            disposition != "APPLIED" and behavior_tag != "n/a"
        ):
            fail("disposition_schema_invalid")
        if (
            not isinstance(reason, str)
            or not reason
            or len(reason) > 1024
            or any(ord(character) < 32 or ord(character) == 127 for character in reason)
        ):
            fail("disposition_schema_invalid")
        if disposition == "APPLIED":
            target = _repo_path_from_location(row["location"])
            if target not in seen_paths:
                applied.append(target)
                seen_paths.add(target)
    return tuple(applied)


def _load_applied_content_plan(
    path: str,
    digest: str,
    authority: dict[str, Any],
    authority_sha256: str,
    disposition_sha256: str,
    applied_paths: tuple[str, ...],
) -> dict[str, Any]:
    canonical_path = _absolute_input(path, "applied_content_path_invalid")
    payload = capture_expected(
        canonical_path, digest, 1, APPLIED_CONTENT_PLAN_LIMIT
    )
    value = _parse_json(payload, "applied_content_json_invalid")
    expected_name = (
        "standalone-applied-content.json"
        if authority["edge_id"] == "simplify.fix.phase2"
        else os.path.basename(authority.get("authority_path", "")).replace(
            "code-fixer-authority-", "review-applied-content-"
        )
    )
    if (
        not isinstance(value, dict)
        or set(value) != APPLIED_CONTENT_PLAN_KEYS
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("authority_sha256") != authority_sha256
        or value.get("disposition_sha256") != disposition_sha256
        or _canonical_json(value) + b"\n" != payload
        or os.path.dirname(canonical_path) != os.path.dirname(authority["findings_path"])
        or os.path.basename(canonical_path) != expected_name
    ):
        fail("applied_content_schema_invalid")
    rows = value.get("applied")
    if not isinstance(rows, list) or len(rows) != len(applied_paths):
        fail("applied_content_schema_invalid")
    for row, expected_path in zip(rows, applied_paths, strict=True):
        if (
            not isinstance(row, dict)
            or set(row) != APPLIED_CONTENT_ROW_KEYS
            or row.get("path") != expected_path
            or row.get("git_mode") not in {"100644", "100755"}
            or not isinstance(row.get("git_oid"), str)
            or SHA1.fullmatch(row["git_oid"]) is None
            or not isinstance(row.get("sha256"), str)
            or SHA256.fullmatch(row["sha256"]) is None
            or type(row.get("size")) is not int
            or row["size"] < 0
            or row["size"] > WORKTREE_FILE_LIMIT
        ):
            fail("applied_content_schema_invalid")
    return value


def _require_applied_content_current(
    current: dict[str, Any], plan: dict[str, Any]
) -> None:
    current_rows = {row["path"]: row for row in current["tracked"]}
    for expected in plan["applied"]:
        worktree = current_rows.get(expected["path"], {}).get("worktree")
        if not isinstance(worktree, dict) or {
            key: worktree.get(key)
            for key in ("git_mode", "git_oid", "sha256", "size")
        } != {
            key: expected[key]
            for key in ("git_mode", "git_oid", "sha256", "size")
        }:
            fail("applied_content_changed")


def _replace_empty_exact_record(
    path: str, empty_identity: ArtifactIdentity, payload: bytes
) -> tuple[str, str, ArtifactIdentity]:
    candidate = ""
    published = False
    completed = False
    published_identity: ArtifactIdentity | None = None
    try:
        candidate, published_identity, digest = secure_publish_captured(path, payload)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or current.st_size != 0
            or (current.st_dev, current.st_ino)
            != (empty_identity.device, empty_identity.inode)
        ):
            fail("disposition_replaced")
        os.replace(candidate, path)
        published = True
        candidate = ""
        _fsync_directory(os.path.dirname(path))
        finalized = os.lstat(path)
        if (
            not stat.S_ISREG(finalized.st_mode)
            or finalized.st_nlink != 1
            or (finalized.st_dev, finalized.st_ino)
            != (published_identity.device, published_identity.inode)
        ):
            fail("disposition_publication_invalid")
        capture_expected(path, digest, 1, DISPOSITION_LIMIT)
        completed = True
    except ContractFailure:
        raise
    except (ManifestRejected, ManifestRuntimeError, OSError):
        fail("disposition_publication_failed")
    finally:
        if candidate:
            _cleanup_temporary_paths(candidate)
        if published and not completed:
            if published_identity is None:
                fail("disposition_recovery_failed")
            _restore_replaced_artifact(
                path,
                published_identity,
                b"",
                reason="disposition_recovery_failed",
            )
    if published_identity is None:
        fail("disposition_publication_invalid")
    return path, digest, published_identity


def _replace_empty_exact(
    path: str, empty_identity: ArtifactIdentity, payload: bytes
) -> tuple[str, str]:
    published_path, digest, _identity = _replace_empty_exact_record(
        path, empty_identity, payload
    )
    return published_path, digest


def _recapture_sources(
    authority: dict[str, Any], *, expected_range_head: str | None = None
) -> dict[str, Any] | None:
    findings = capture_expected(
        authority["findings_path"],
        authority["findings_sha256"],
        1,
        FINDINGS_LIMIT,
    )
    parsed = parse_finding_keys(findings, authority["phase"])
    if [asdict(item) for item in parsed] != authority["finding_keys"]:
        fail("findings_authority_mismatch")
    if authority["edge_id"] == "simplify.fix.phase2":
        snapshot = _load_snapshot(
            authority["standalone_snapshot_path"],
            authority["standalone_snapshot_sha256"],
        )
        if snapshot["working_dir"] != authority["working_dir"]:
            fail("snapshot_authority_mismatch")
        if any(
            path not in set(snapshot["target_eligible_paths"])
            for path in authority["target_paths"]
        ):
            fail("snapshot_authority_mismatch")
        return snapshot
    commit_range = capture_expected(
        authority["commit_range_path"],
        authority["commit_range_sha256"],
        1,
        RANGE_LIMIT,
    )
    _commit_range_endpoints(commit_range)
    _require_targets_in_reviewed_range(
        authority["working_dir"],
        commit_range,
        tuple(authority["target_paths"]),
        expected_head=expected_range_head,
    )
    return None


def _require_standalone_edit_state(
    authority: dict[str, Any], snapshot: dict[str, Any], applied_paths: tuple[str, ...]
) -> dict[str, Any]:
    if authority["edge_id"] != "simplify.fix.phase2":
        fail("standalone_authority_required")
    applied = set(applied_paths)
    if any(path not in authority["target_paths"] for path in applied):
        fail("standalone_applied_path_invalid")
    _require_snapshot_index_current(snapshot)
    current = _capture_repo_state(authority["working_dir"], snapshot["evidence_dir"])
    if (
        current["head_sha"] != snapshot["head_sha"]
        or current["head_tree_sha"] != snapshot["head_tree_sha"]
        or current["index_tree_sha"] != snapshot["index_tree_sha"]
        or current["untracked"] != snapshot["untracked"]
    ):
        fail("standalone_baseline_mismatch")
    _require_snapshot_index_current(snapshot)
    baseline_rows = {row["path"]: row for row in snapshot["tracked"]}
    current_rows = {row["path"]: row for row in current["tracked"]}
    if set(current_rows) != set(baseline_rows):
        fail("standalone_path_set_mismatch")
    for path, baseline in baseline_rows.items():
        row = current_rows[path]
        if path not in applied:
            if row != baseline:
                fail("standalone_nonapplied_mutated")
            continue
        if (
            row["head"] != baseline["head"]
            or row["index"] != baseline["index"]
            or row["head_to_index"] != baseline["head_to_index"]
            or row["head_to_worktree"] != "M"
            or row["worktree"]["kind"] != "regular"
            or row["worktree"]["git_mode"] not in {"100644", "100755"}
            or row["worktree"]["sha256"] == baseline["worktree"]["sha256"]
        ):
            fail("standalone_applied_state_invalid")
    return current


def _require_review_index_current(authority: dict[str, Any]) -> None:
    payload, identity = _capture_regular(
        authority["index_path"], authority["index_size"], authority["index_size"]
    )
    if (
        hashlib.sha256(payload).hexdigest() != authority["index_sha256"]
        or stat.S_IMODE(identity.mode) != authority["index_mode"]
    ):
        fail("review_index_mismatch")


def _require_review_edit_state(
    authority: dict[str, Any], applied_paths: tuple[str, ...]
) -> dict[str, Any]:
    if authority["edge_id"] == "simplify.fix.phase2":
        fail("review_authority_required")
    applied = set(applied_paths)
    if any(path not in authority["target_paths"] for path in applied):
        fail("review_applied_path_invalid")
    _require_review_index_current(authority)
    evidence_dir = os.path.dirname(authority["findings_path"])
    current = _capture_repo_state(authority["working_dir"], evidence_dir)
    if (
        current["head_sha"] != authority["parent_sha"]
        or current["head_tree_sha"] != authority["parent_tree_sha"]
        or current["index_path"] != authority["index_path"]
        or current["index_tree_sha"] != authority["index_tree_sha"]
        or current["index_sha256"] != authority["index_sha256"]
        or current["index_size"] != authority["index_size"]
        or current["index_mode"] != authority["index_mode"]
        or current["untracked"] != authority["untracked"]
    ):
        fail("review_baseline_mismatch")
    _require_review_index_current(authority)
    rows = {row["path"]: row for row in current["tracked"]}
    if set(rows) != applied:
        fail("review_applied_path_mismatch")
    for path, row in rows.items():
        if (
            row["head"] is None
            or row["index"] is None
            or {
                "mode": row["index"]["mode"],
                "oid": row["index"]["oid"],
            }
            != row["head"]
            or row["head_to_index"] != "UNCHANGED"
            or row["index_to_worktree"] != "M"
            or row["head_to_worktree"] != "M"
            or row["worktree"]["kind"] != "regular"
            or row["worktree"]["git_mode"] not in {"100644", "100755"}
        ):
            fail("review_applied_state_invalid")
    return current


def publish_disposition(
    *,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    candidate: bytes,
) -> dict[str, Any]:
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if canonical_disposition != authority["disposition_path"]:
        fail("disposition_path_invalid")
    snapshot = _recapture_sources(authority)
    _empty, empty_identity = _capture_regular(disposition_path, 0, 0)
    value = _parse_json(candidate, "disposition_json_invalid")
    applied_paths = _validate_disposition(value, authority)
    standalone_current = None
    review_current = None
    if snapshot is not None:
        standalone_current = _require_standalone_edit_state(
            authority, snapshot, applied_paths
        )
    else:
        review_current = _require_review_edit_state(authority, applied_paths)
    payload = (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        .encode()
        + b"\n"
    )
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        published_path, digest, disposition_identity = _replace_empty_exact_record(
            canonical_disposition, empty_identity, payload
        )
        rollbacks.append(
            _ArtifactRollback(canonical_disposition, disposition_identity, b"")
        )
        receipt = {
            "disposition_path": published_path,
            "disposition_sha256": digest,
            "applied_paths": list(applied_paths),
        }
        edit_current = standalone_current or review_current
        if edit_current is not None:
            current_rows = {
                row["path"]: row for row in edit_current["tracked"]
            }
            applied_content = []
            for path in applied_paths:
                worktree = current_rows[path]["worktree"]
                applied_content.append(
                    {
                        "path": path,
                        "git_mode": worktree["git_mode"],
                        "git_oid": worktree["git_oid"],
                        "sha256": worktree["sha256"],
                        "size": worktree["size"],
                    }
                )
            content_plan = {
                "schema_version": 1,
                "authority_sha256": authority_sha256,
                "disposition_sha256": digest,
                "applied": applied_content,
            }
            content_name = (
                "standalone-applied-content.json"
                if standalone_current is not None
                else os.path.basename(canonical_authority).replace(
                    "code-fixer-authority-", "review-applied-content-"
                )
            )
            content_path = os.path.join(
                os.path.dirname(authority["findings_path"]), content_name
            )
            published_content_path, content_digest, content_identity = (
                _publish_new_exact_record(
                    content_path, _canonical_json(content_plan) + b"\n"
                )
            )
            rollbacks.append(
                _ArtifactRollback(content_path, content_identity, None)
            )
            receipt.update(
                {
                    "applied_content_path": published_content_path,
                    "applied_content_sha256": content_digest,
                }
            )
        completed = True
        return receipt
    finally:
        if not completed:
            _rollback_publications(
                rollbacks, reason="disposition_transaction_recovery_failed"
            )


def publish_review_only_disposition(
    *,
    findings_path: str,
    findings_sha256: str,
    snapshot_path: str,
    snapshot_sha256: str,
    working_dir: str,
    disposition_path: str,
) -> dict[str, Any]:
    canonical_findings = _absolute_input(findings_path, "findings_path_invalid")
    canonical_snapshot = _absolute_input(snapshot_path, "snapshot_path_invalid")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    snapshot = _load_snapshot(canonical_snapshot, snapshot_sha256)
    if (
        snapshot["working_dir"] != canonical_working
        or snapshot["target_eligible_paths"]
        or not beneath(snapshot["evidence_dir"], canonical_findings)
        or not beneath(snapshot["evidence_dir"], canonical_disposition)
    ):
        fail("review_only_authority_invalid")
    findings_payload = capture_expected(
        canonical_findings, findings_sha256, 1, FINDINGS_LIMIT
    )
    finding_keys = parse_finding_keys(findings_payload, "phase2")
    _require_snapshot_current(snapshot)
    _empty, empty_identity = _capture_regular(canonical_disposition, 0, 0)
    disposition = {
        "schema_version": 1,
        "phase": "phase2",
        "aggregate_sha256": findings_sha256,
        "findings_disposition": [
            {
                **asdict(finding),
                "disposition": "REFUSED",
                "behavior_tag": "n/a",
                "reason": "no-eligible-baseline-path",
            }
            for finding in finding_keys
        ],
    }
    payload = (
        json.dumps(
            disposition,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        + b"\n"
    )
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        published_path, digest, disposition_identity = _replace_empty_exact_record(
            canonical_disposition, empty_identity, payload
        )
        rollbacks.append(
            _ArtifactRollback(canonical_disposition, disposition_identity, b"")
        )
        capture_expected(canonical_findings, findings_sha256, 1, FINDINGS_LIMIT)
        _load_snapshot(canonical_snapshot, snapshot_sha256)
        _require_snapshot_current(snapshot)
        receipt = {
            "disposition_path": published_path,
            "disposition_sha256": digest,
            "applied_paths": [],
        }
        completed = True
        return receipt
    finally:
        if not completed:
            _rollback_publications(
                rollbacks, reason="review_only_transaction_recovery_failed"
            )


def publish_unapplied_terminal(
    *,
    launch_binding: bytes,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    applied_content_path: str,
    working_dir: str,
    head_before: str,
    head_after: str,
) -> dict[str, Any]:
    """Publish AND validate the review fixer terminal that applied nothing.

    A refusing child leaves no bytes behind by design: it restores the worktree
    to HEAD and stops. It cannot write the disposition or the applied-content
    plan through `publish_disposition`, because that publisher is gated on the
    raw `.git/index` byte pin -- and the child's own authorised `git status` /
    `git diff` has already moved those bytes, which is the refusal it reported.
    Without this verb neither artifact ever exists, the terminal cannot be
    captured at all, and every finding the child refused is dropped on the floor
    instead of deferred to an issue (#556). A refusal is the one terminal where
    the findings most need to survive, because nothing was applied and every
    finding is still outstanding.

    Publisher and validator are therefore one call: the same process that proves
    nothing was applied is the one that writes the evidence of it. The receipt is
    the document `validate_review_outcome` returns for a non-APPLIED terminal, so
    the fence that promotes an outcome promotes this one unchanged.
    """
    binding = _load_review_fixer_binding(launch_binding)
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    authority["authority_path"] = canonical_authority
    if authority["edge_id"] not in {
        "review_pr.fix.phase1",
        "review_pr.fix.phase2",
    }:
        # Not independently drivable, and backstopped rather than
        # load-bearing. `_load_review_fixer_binding` already pins the
        # binding to a fix edge and `_load_fixer_launch_binding` already
        # pins the binding's OWN authority to that edge, so an authority
        # carrying any other edge is necessarily a different file at a
        # path the binding does not name -- the authority-path clause
        # below refuses it regardless. Deleting this arm would degrade
        # the token an operator reads to `validation_authority_mismatch`;
        # it would not open a publication path. The refusal is kept
        # because it names the actual problem.
        fail("review_authority_required")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    canonical_content = _absolute_input(
        applied_content_path, "applied_content_path_invalid"
    )
    expected_content = os.path.join(
        os.path.dirname(authority["findings_path"]),
        os.path.basename(canonical_authority).replace(
            "code-fixer-authority-", "review-applied-content-"
        ),
    )
    # Four of these six are drivable from a caller -- the authority path, the
    # working dir, the disposition path and the applied-content path -- and
    # each is covered by a row. The authority path is drivable because
    # `_load_authority` accepts any `code-fixer-authority-<phase>(-iterN)?`
    # name in the evidence dir, so a byte-identical copy under a second
    # accepted name satisfies every other clause and leaves this one alone to
    # refuse it.
    #
    # The other two are mirrors of equalities their loaders already enforce,
    # unreachable in a fixture by construction rather than rot:
    # `_load_authority` verifies the caller's digest against the bytes at the
    # caller's path, so once the two authority paths agree their digests
    # cannot disagree; and `_load_fixer_launch_binding` already refuses a
    # binding whose `worktree` is not its own authority's `working_dir`, which
    # with the two clauses above is `canonical_working`.
    if (
        canonical_authority != binding["authority_path"]
        or authority_sha256 != binding["authority_sha256"]
        or canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
        or canonical_content != expected_content
        or binding["worktree"] != canonical_working
    ):
        fail("validation_authority_mismatch")
    _recapture_sources(authority, expected_range_head=authority["parent_sha"])
    status_payload, _status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    result_payload, _result_identity = _capture_regular(
        binding["result_path"], 1, DISPOSITION_LIMIT
    )
    _validate_bound_child_status(binding, status_payload)
    parsed_result = _parse_fixer_result(
        result_payload, authority["phase"], authority["commit_type"]
    )
    if parsed_result["commits"]:
        fail("fixer_result_commit_mismatch")
    dispositions = [row["disposition"] for row in parsed_result["rows"]]
    derived_status = "REFUSED" if "REFUSED" in dispositions else "NO_FIXES_NEEDED"
    if "APPLIED" in dispositions or parsed_result["status"] != derived_status:
        fail("fixer_result_status_mismatch")
    _empty, empty_identity = _capture_regular(canonical_disposition, 0, 0)
    if (
        SHA1.fullmatch(head_before or "") is None
        or SHA1.fullmatch(head_after or "") is None
    ):
        fail("commit_identity_invalid")
    # The unapplied-state proof, and deliberately NOT the applied one. It omits
    # the raw `.git/index` byte pin -- `index_sha256`, `index_size`,
    # `index_mode` -- that the APPLIED and commit paths keep untouched. There
    # are no applied bytes on this terminal whose provenance that pin protects;
    # an equal index tree, an empty tracked set and an equal untracked set
    # already prove nothing is staged and nothing is modified; and the pin is
    # invalidated by the child's own authorised `git status` / `git diff`
    # (agents/code-fixer.md), which is why the refusal happened at all.
    current = _capture_repo_state(
        authority["working_dir"], os.path.dirname(authority["findings_path"])
    )
    if (
        head_before != authority["parent_sha"]
        or head_after != head_before
        or current["head_sha"] != authority["parent_sha"]
        or current["head_tree_sha"] != authority["parent_tree_sha"]
        # A mirror of the identical clause in the applied path's edit-state
        # predicate -- described rather than named, because the suite asserts
        # this function's source never mentions the two gates it must not
        # re-run. Like the loader-enforced equalities above, it is not
        # independently reachable from a fixture: the index path is derived
        # from the same working dir the authority pins, which the block above
        # already requires the caller to match.
        or current["index_path"] != authority["index_path"]
        or current["index_tree_sha"] != authority["index_tree_sha"]
        or current["tracked"] != []
        or current["untracked"] != authority["untracked"]
    ):
        fail("unapplied_terminal_state_invalid")
    disposition = {
        "schema_version": 1,
        "phase": authority["phase"],
        "aggregate_sha256": authority["findings_sha256"],
        # Verbatim from the parsed result. `validate_review_outcome` refuses
        # `fixer_result_disposition_mismatch` when the result rows and the
        # disposition rows differ; publishing FROM the parsed rows makes that
        # equality true by construction, because there is no second copy to
        # drift. `_validate_disposition` below still pins every row to the
        # authority's immutable (finding_index, location, summary_sha256)
        # triple, so a forged result cannot invent, reorder or drop a finding.
        "findings_disposition": parsed_result["rows"],
    }
    # Called for its OTHER checks -- schema, phase, aggregate digest, and the
    # authority's immutable finding triples -- which must all hold before the
    # write. Its applied set is empty while the guard above stands, since both
    # read the same rows; the refusal is kept so a future loosening of that
    # guard cannot publish an APPLIED row as an unapplied terminal.
    if _validate_disposition(disposition, authority):
        fail("fixer_result_status_mismatch")
    payload = (
        json.dumps(
            disposition, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
        + b"\n"
    )
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        published_path, disposition_digest, disposition_identity = (
            _replace_empty_exact_record(
                canonical_disposition, empty_identity, payload
            )
        )
        rollbacks.append(
            _ArtifactRollback(published_path, disposition_identity, b"")
        )
        content_plan = {
            "schema_version": 1,
            "authority_sha256": authority_sha256,
            "disposition_sha256": disposition_digest,
            "applied": [],
        }
        published_content_path, content_digest, content_identity = (
            _publish_new_exact_record(
                canonical_content, _canonical_json(content_plan) + b"\n"
            )
        )
        rollbacks.append(
            _ArtifactRollback(published_content_path, content_identity, None)
        )
        status_digest = hashlib.sha256(status_payload).hexdigest()
        result_digest = hashlib.sha256(result_payload).hexdigest()
        capture_expected(binding["status_path"], status_digest, 1, 65_536)
        capture_expected(
            binding["result_path"], result_digest, 1, DISPOSITION_LIMIT
        )
        capture_expected(published_path, disposition_digest, 1, DISPOSITION_LIMIT)
        capture_expected(
            published_content_path,
            content_digest,
            1,
            APPLIED_CONTENT_PLAN_LIMIT,
        )
        _recapture_sources(authority, expected_range_head=authority["parent_sha"])
        receipt = {
            "status": derived_status,
            "declared_tip": "",
            **_launch_identity(binding),
            "status_sha256": status_digest,
            "result_sha256": result_digest,
            "disposition_sha256": disposition_digest,
            "applied_content_sha256": content_digest,
            "commit": None,
        }
        completed = True
        return receipt
    finally:
        if not completed:
            _rollback_publications(
                rollbacks,
                reason="unapplied_terminal_transaction_recovery_failed",
            )


def count_phase2_deferred_blockers(
    *,
    findings_path: str,
    findings_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
) -> int:
    """Deferred blockers in the PHASE 2 pair -- the /simplify defer edge's count.

    The phase is a literal here, not a parameter: this verb's recount is the
    proof `review_pr.defer.findings` binds on, and a caller-declared phase would
    let an agent-authored fence bind a Phase 1 aggregate to a Phase 2 edge.
    Phase 1 reaches the same procedure through
    `_load_verification_pair(phase="phase1", ...)`, never through here.
    """
    aggregate, disposition, _finding_keys, _canonical_disposition = (
        _load_verification_pair(
            phase="phase2",
            findings_path=findings_path,
            findings_sha256=findings_sha256,
            disposition_path=disposition_path,
            disposition_sha256=disposition_sha256,
        )
    )
    return sum(
        1
        for finding, row in zip(
            aggregate["findings"],
            disposition["findings_disposition"],
            strict=True,
        )
        if finding["severity"] == "blocker" and row["disposition"] != "APPLIED"
    )


VERIFICATION_LIMIT = 1_048_576
VERIFICATION_CLAIM_LIMIT = 65_536
VERIFICATION_KEYS = {
    "schema_version",
    "phase",
    "aggregate_sha256",
    "threshold",
    "findings_verification",
}
VERIFICATION_ROW_KEYS = {
    "finding_index",
    "location",
    "summary_sha256",
    "score",
    "verdict",
    "reason",
}
CLAIM_KEYS = {"finding_index", "location", "summary"}
# The verdict vocabulary is the CONTROLLER's, never the child's: a verifier is
# never shown the threshold, so it cannot know which side of it a score lands
# on. See shared/finding-verifier-output-v1.md.
# CONTRACT: finding-verification-verdict
VERIFICATION_VERDICTS = {"SURVIVES", "CULLED"}
# /CONTRACT: finding-verification-verdict
# Emitted by a verifier child. A row carrying one of these MUST carry a score.
VERIFICATION_CHILD_REASONS = {
    "reproduced-from-diff",
    "contradicted-by-diff",
    "pre-existing",
    "out-of-scope-line",
    "linter-domain",
}
# Assigned by the controller when no child opinion exists. A row carrying one
# of these MUST NOT carry a score, and always lands SURVIVES: the gate fails
# toward keeping the finding, so "we could not verify" never culls.
VERIFICATION_CONTROLLER_REASONS = {
    "gate-disabled",
    "over-cap-unverified",
    "verifier-unavailable",
}
VERIFICATION_REASONS = VERIFICATION_CHILD_REASONS | VERIFICATION_CONTROLLER_REASONS
VERIFICATION_OPINION_KEYS = {"finding_index", "score", "reason"}
VERIFICATION_BASENAME = "phase1-verification.json"


def _load_verification_pair(
    *,
    phase: Phase,
    findings_path: str,
    findings_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
) -> tuple[dict[str, Any], dict[str, Any], tuple[FindingKey, ...], str]:
    """Re-derive a phase's aggregate/disposition pair from pinned bytes.

    ONE procedure for both phases (#452). The phase is a parameter HERE and a
    literal at every call site, so no caller-supplied value ever selects which
    phase a persistence binding proves -- and both verification verbs plus the
    Phase 2 deferred-blocker recount bind the same pair here, so "which findings
    are eligible" is decided exactly once.
    """
    canonical_findings = _absolute_input(findings_path, "findings_path_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    findings_payload = capture_expected(
        canonical_findings, findings_sha256, 1, FINDINGS_LIMIT
    )
    body = _enveloped_body(findings_payload, _aggregate_source(phase))
    aggregate = _parse_json(body, "findings_schema_invalid")
    finding_keys = _validate_aggregate(aggregate, phase)
    if encode_aggregate(aggregate, phase) != findings_payload:
        fail("findings_not_canonical")
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    authority = {
        "phase": phase,
        "findings_sha256": findings_sha256,
        "finding_keys": [asdict(item) for item in finding_keys],
    }
    _validate_disposition(disposition, authority)
    expected_disposition = (
        json.dumps(
            disposition, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        + b"\n"
    )
    if disposition_payload != expected_disposition:
        fail("disposition_not_canonical")
    return aggregate, disposition, finding_keys, canonical_disposition


def _eligible_verification_rows(
    aggregate: dict[str, Any],
    disposition: dict[str, Any],
    finding_keys: tuple[FindingKey, ...],
) -> list[tuple[FindingKey, dict[str, Any]]]:
    """The verification roster: Phase 1 blockers the fixer did not apply.

    A suggestion never becomes a GitHub issue tier the /goal loop recurses on,
    and an APPLIED blocker is already fixed in the branch -- neither is worth a
    verifier. Declared once here so the claim projection and the sidecar
    publication cannot disagree about the roster.
    """
    eligible: list[tuple[FindingKey, dict[str, Any]]] = []
    for finding, row, key in zip(
        aggregate["findings"],
        disposition["findings_disposition"],
        finding_keys,
        strict=True,
    ):
        if finding["severity"] == "blocker" and row["disposition"] != "APPLIED":
            eligible.append((key, finding))
    return eligible


def project_verification_claims(
    *,
    findings_path: str,
    findings_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    claims_dir: str,
) -> dict[str, Any]:
    """Write one claim card per eligible Phase 1 blocker finding.

    The card is the MECHANICAL half of the withholding the design turns on: it
    carries `finding_index`, `location` and `summary` and nothing else, so the
    reviewer's `detail` -- which is where the argument and the reviewer's own
    `confidence: <n>` prefix live -- never reaches the verifier as bytes. A
    prompt-level "do not look at the reasoning" would be a rule; this is an
    absence.

    The aggregate is READ, never rewritten, and FINDING_KEYS gains no member.
    """
    aggregate, disposition, finding_keys, _canonical_disposition = (
        _load_verification_pair(
            phase="phase1",
            findings_path=findings_path,
            findings_sha256=findings_sha256,
            disposition_path=disposition_path,
            disposition_sha256=disposition_sha256,
        )
    )
    canonical_claims = _absolute_input(claims_dir, "claims_dir_invalid")
    eligible = _eligible_verification_rows(aggregate, disposition, finding_keys)
    claims: list[dict[str, Any]] = []
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        if eligible:
            try:
                os.makedirs(canonical_claims, mode=0o700, exist_ok=True)
            except OSError:
                fail("claims_dir_invalid")
            directory = os.lstat(canonical_claims)
            if not stat.S_ISDIR(directory.st_mode):
                fail("claims_dir_invalid")
        for ordinal, (key, finding) in enumerate(eligible, start=1):
            card = {
                "finding_index": key.finding_index,
                "location": key.location,
                "summary": finding["summary"],
            }
            if set(card) != CLAIM_KEYS:
                fail("claim_schema_invalid")
            claim_path = os.path.join(canonical_claims, f"verify-{ordinal:02d}.json")
            published_path, claim_digest, identity = _publish_new_exact_record(
                claim_path, _canonical_json(card) + b"\n"
            )
            rollbacks.append(_ArtifactRollback(claim_path, identity, None))
            claims.append(
                {
                    "finding_index": key.finding_index,
                    "claim_path": published_path,
                    "claim_sha256": claim_digest,
                }
            )
        completed = True
        return {
            "schema_version": 1,
            "phase": "phase1",
            "aggregate_sha256": findings_sha256,
            "verify_count": len(claims),
            "claims": claims,
        }
    finally:
        if not completed:
            _rollback_publications(
                rollbacks, reason="verification_claims_recovery_failed"
            )


def _validate_verification_opinions(
    candidate: bytes,
    eligible: list[tuple[FindingKey, dict[str, Any]]],
    threshold: int,
) -> list[dict[str, Any]]:
    """Turn the controller's per-finding opinions into sidecar rows.

    This is where the threshold is applied, and the ONLY place it is applied.
    The child never receives it, so the same child bytes yield opposite
    verdicts under different thresholds -- which is what makes recorded scores
    re-thresholdable offline.
    """
    opinions = _parse_json(candidate, "verification_json_invalid")
    if not isinstance(opinions, list) or len(opinions) != len(eligible):
        fail("verification_finding_mismatch")
    rows: list[dict[str, Any]] = []
    for opinion, (key, _finding) in zip(opinions, eligible, strict=True):
        if not isinstance(opinion, dict) or not set(opinion) <= VERIFICATION_OPINION_KEYS:
            fail("verification_schema_invalid")
        if opinion.get("finding_index") != key.finding_index:
            fail("verification_finding_mismatch")
        reason = opinion.get("reason")
        if not isinstance(reason, str) or reason not in VERIFICATION_REASONS:
            fail("verification_schema_invalid")
        has_score = "score" in opinion
        score = opinion.get("score")
        if reason in VERIFICATION_CHILD_REASONS:
            if not has_score or type(score) is not int or not 0 <= score <= 100:
                fail("verification_schema_invalid")
            # Fail toward keeping: only a well-formed score STRICTLY below the
            # threshold ever culls. This is the ONLY expression in the tree that
            # can produce a CULLED verdict.
            verdict = "CULLED" if score < threshold else "SURVIVES"
        else:
            if has_score:
                fail("verification_schema_invalid")
            score = None
            verdict = "SURVIVES"
        # The kill switch is total: at threshold 0 no verifier is dispatched,
        # so a scored row could only have come from somewhere else.
        if threshold == 0 and reason != "gate-disabled":
            fail("verification_gate_disabled_mismatch")
        if verdict not in VERIFICATION_VERDICTS:
            fail("verification_schema_invalid")
        row = {
            "finding_index": key.finding_index,
            "location": key.location,
            "summary_sha256": key.summary_sha256,
            "score": score,
            "verdict": verdict,
            "reason": reason,
        }
        if set(row) != VERIFICATION_ROW_KEYS:
            fail("verification_schema_invalid")
        rows.append(row)
    return rows


def publish_verification(
    *,
    findings_path: str,
    findings_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    verification_path: str,
    threshold: int,
    candidate: bytes,
) -> dict[str, Any]:
    """Publish phase1-verification.json beside the disposition it is bound to.

    Same transaction shape as publish_disposition: the target must already
    exist as an empty regular file the caller created, the write is an
    identity-checked replace, and a mid-flight failure rolls it back to empty
    rather than leaving a half-written verdict record on disk.
    """
    if type(threshold) is not int or not 0 <= threshold <= 100:
        fail("verification_threshold_invalid")
    aggregate, disposition, finding_keys, canonical_disposition = (
        _load_verification_pair(
            phase="phase1",
            findings_path=findings_path,
            findings_sha256=findings_sha256,
            disposition_path=disposition_path,
            disposition_sha256=disposition_sha256,
        )
    )
    canonical_verification = _absolute_input(
        verification_path, "verification_path_invalid"
    )
    # Sibling of the disposition, exact basename. The sidecar's whole value is
    # that it is findable from the artifact it qualifies.
    if (
        os.path.dirname(canonical_verification)
        != os.path.dirname(canonical_disposition)
        or os.path.basename(canonical_verification) != VERIFICATION_BASENAME
    ):
        fail("verification_path_invalid")
    _empty, empty_identity = _capture_regular(canonical_verification, 0, 0)
    eligible = _eligible_verification_rows(aggregate, disposition, finding_keys)
    rows = _validate_verification_opinions(candidate, eligible, threshold)
    document = {
        "schema_version": 1,
        "phase": "phase1",
        "aggregate_sha256": findings_sha256,
        "threshold": threshold,
        "findings_verification": rows,
    }
    if set(document) != VERIFICATION_KEYS:
        fail("verification_schema_invalid")
    payload = _canonical_json(document) + b"\n"
    rollbacks: list[_ArtifactRollback] = []
    completed = False
    try:
        published_path, verification_digest, identity = _replace_empty_exact_record(
            canonical_verification, empty_identity, payload
        )
        rollbacks.append(_ArtifactRollback(canonical_verification, identity, b""))
        completed = True
        return {
            "verification_path": published_path,
            "verification_sha256": verification_digest,
            "threshold": threshold,
            "verified": len(rows),
            "culled": sum(1 for row in rows if row["verdict"] == "CULLED"),
        }
    finally:
        if not completed:
            _rollback_publications(
                rollbacks, reason="verification_transaction_recovery_failed"
            )


def _persistence_scalar(
    lines: list[str], key: str, pattern: str, reason: str
) -> str:
    prefix = f"{key}: "
    matches = [line[len(prefix) :] for line in lines if line.startswith(prefix)]
    if len(matches) != 1 or re.fullmatch(pattern, matches[0], re.ASCII) is None:
        fail(reason)
    return matches[0]


def _parse_persistence_result_document(payload: bytes) -> dict[str, Any]:
    """The findings-to-issues Return-Contract fence, parsed as a strict document.

    Extracted from validate_persistence_result (#383) so review_pr.defer.findings
    and review_pr.ci.defer_refusal share ONE parser. They deliberately do NOT
    share the blocker recount that follows it: the defer stage recounts against
    a schema-v2 aggregate, and the CI refusal stage's aggregate is the one-row
    ci-refused-synthetic envelope, which count_phase2_deferred_blockers cannot
    parse.
    """
    if b"\x00" in payload or b"\r" in payload or not payload.endswith(b"\n```\n"):
        fail("persistence_result_malformed")
    try:
        text = payload.decode("utf-8")
    except UnicodeError:
        fail("persistence_result_malformed")
    opening = "```yaml\n"
    opening_index = text.rfind("\n" + opening)
    if opening_index >= 0:
        opening_index += 1
    elif text.startswith(opening):
        opening_index = 0
    else:
        fail("persistence_result_malformed")
    body_start = opening_index + len(opening)
    body = text[body_start:-5]
    if not body or "\n```" in body or "\t" in body:
        fail("persistence_result_malformed")
    lines = body.splitlines()
    status = _persistence_scalar(
        lines,
        "status",
        r"DONE|DONE_WITH_CONCERNS|REFUSED",
        "persistence_result_malformed",
    )
    halted_text = _persistence_scalar(
        lines, "halted", r"true|false", "persistence_result_malformed"
    )
    overflow_halt_text = _persistence_scalar(
        lines,
        "halted_due_to_overflow",
        r"true|false",
        "persistence_result_malformed",
    )
    by_severity_indexes = [
        index for index, line in enumerate(lines) if line == "by_severity:"
    ]
    if len(by_severity_indexes) != 1:
        fail("persistence_result_malformed")
    by_severity_index = by_severity_indexes[0]
    expected_by_severity = lines[by_severity_index + 1 : by_severity_index + 4]
    if len(expected_by_severity) != 3:
        fail("persistence_result_malformed")
    blocker_match = re.fullmatch(r"  blocker: ([0-9]+)", expected_by_severity[0])
    if (
        blocker_match is None
        or re.fullmatch(r"  critical: [0-9]+", expected_by_severity[1]) is None
        or re.fullmatch(r"  major: [0-9]+", expected_by_severity[2]) is None
    ):
        fail("persistence_result_malformed")
    blocker_count = int(blocker_match.group(1))
    halted = halted_text == "true"
    overflow_halt = overflow_halt_text == "true"
    if (
        (blocker_count > 0 and not halted)
        or (overflow_halt and not halted)
        or (halted and blocker_count == 0 and not overflow_halt)
    ):
        fail("persistence_result_malformed")
    skipped_indexes = [
        index
        for index, line in enumerate(lines)
        if line in {"skipped_closed:", "skipped_closed: []"}
    ]
    if len(skipped_indexes) != 1:
        fail("persistence_result_malformed")
    skipped_blockers = 0
    if lines[skipped_indexes[0]] == "skipped_closed:":
        index = skipped_indexes[0] + 1
        while index < len(lines) and lines[index].startswith("  "):
            if lines[index].startswith("  - ") and 'tier: "BLOCKER"' in lines[index]:
                skipped_blockers += 1
            index += 1
    return {
        "status": status,
        "halted": halted,
        "halted_due_to_overflow": overflow_halt,
        "by_severity_blocker": blocker_count,
        "skipped_blockers": skipped_blockers,
        "created_url": _persistence_first_created_url(lines),
    }


# `created_urls: - { url: "https://github.com/<owner>/<repo>/issues/<n>", … }`.
# Deliberately narrow: the value is rendered into operator-facing halt prose and
# into the audit JSON, and it comes from a child that read untrusted CI logs.
# The owner and repo segments must START alphanumeric (owner) or
# alphanumeric/underscore (repo), so `.`/`..` can never be a path segment: a
# child that emitted `https://github.com/../../issues/1` would otherwise be
# handed straight to the operator as the issue it filed.
PERSISTENCE_ISSUE_URL = re.compile(
    r'  - \{ *url: "(https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}'
    r'/[A-Za-z0-9_][A-Za-z0-9._-]{0,99}'
    r'/issues/[1-9][0-9]{0,9})"'
)


def _persistence_first_created_url(lines: list[str]) -> str:
    """`created_urls[0].url`, or "" when the child created nothing.

    `validate-ci-persistence-result` returned status/halt/counts and the
    aggregate identity — and no URL at all — while the ci-defer arm's prose says
    "the caller captures … `CI_REFUSED_ISSUE_URL` from `created_urls[0].url`".
    Nothing assigned it on the SUCCESS path: the only two assignments were in
    the MALFORMED branches, so the halt prose's `filed issue:` line and the
    audit field `phases.phase3.ci_refused_issue_url` referenced an unbound
    variable exactly when the filing had worked.
    """
    for index, line in enumerate(lines):
        if line != "created_urls:":
            continue
        for entry in lines[index + 1:]:
            if not entry.startswith("  "):
                break
            match = PERSISTENCE_ISSUE_URL.match(entry)
            if match is not None:
                return match.group(1)
        break
    return ""


def validate_persistence_result(
    *,
    launch_binding: bytes,
    status_sha256: str,
    result_sha256: str,
) -> dict[str, Any]:
    """Judge the review_pr.defer.findings child's terminal.

    The blocker accounting below is a LOWER BOUND, not an equality, because the
    two sides count different populations and always did (#453):

    * `expected_deferred_blockers` is Phase-2-scoped. It is recounted here from
      the pinned aggregate/disposition bytes by `count_deferred_blockers`, which
      hardcodes a `simplify-aggregate` envelope and `phase2` validation, so it
      can see no Phase 1 row at all.
    * `by_severity.blocker` and `skipped_closed` are what the FILER wrote, and
      `agents/findings-to-issues.md` reads both phase aggregates: they count
      Phase 1 and Phase 2 rows together.

    An equality therefore failed every run that filed a Phase 1 blocker, and the
    RFC 0017 verification gate — which culls Phase 1 rows before they are filed
    — made that easier to hit. The relation the binding can actually prove is
    the one this asserts: the filer accounted for AT LEAST the N blockers the
    Phase 2 fixer deferred. Phase 1 rows only ever raise the observed count.

    Equality is not merely unpinned here, it is unreachable: the filer collapses
    rows across phases by `(file, line, normalised summary)`, so a Phase 1 and a
    Phase 2 blocker at one location legitimately produce a single filed row.

    The bound is not weakened by the filer's own drop paths. `require_clean` is
    true exactly when a Phase 2 blocker was deferred, and it demands `DONE` —
    which the child returns only when `blocked_by_dedupe` is empty and
    `overflow_count` is 0. So on every run this bound can fail, each deferred
    Phase 2 blocker was either filed/commented (`by_severity.blocker`) or
    matched an already-closed issue (`skipped_closed`), and an under-reporting
    child — the one that would emit a GREEN trail over an unfiled blocker — is
    still refused.

    What this does NOT assert: that the filer wrote no MORE blockers than were
    deferred. The upper bound needs a recount of the Phase 1 pair, which this
    binding does not pin (it travels as a prompt input only).
    """
    binding = _load_persistence_binding(launch_binding)
    observed_deferred_blockers = count_phase2_deferred_blockers(
        findings_path=binding["aggregate_path"],
        findings_sha256=binding["aggregate_sha256"],
        disposition_path=binding["disposition_path"],
        disposition_sha256=binding["disposition_sha256"],
    )
    if observed_deferred_blockers != binding["expected_deferred_blockers"]:
        fail("persistence_result_authority_mismatch")
    status_payload = capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    payload = capture_expected(
        binding["result_path"], result_sha256, 1, PERSISTENCE_RESULT_LIMIT
    )
    parsed = _parse_persistence_result_document(payload)
    status = parsed["status"]
    if status == "REFUSED":
        fail("persistence_result_refused")
    if binding["require_clean"] and status != "DONE":
        fail("persistence_result_concerns")
    blocker_count = parsed["by_severity_blocker"]
    accounted_blockers = blocker_count + parsed["skipped_blockers"]
    if accounted_blockers < binding["expected_deferred_blockers"]:
        fail("persistence_result_authority_mismatch")
    capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    capture_expected(
        binding["result_path"], result_sha256, 1, PERSISTENCE_RESULT_LIMIT
    )
    observed_deferred_blockers = count_phase2_deferred_blockers(
        findings_path=binding["aggregate_path"],
        findings_sha256=binding["aggregate_sha256"],
        disposition_path=binding["disposition_path"],
        disposition_sha256=binding["disposition_sha256"],
    )
    if observed_deferred_blockers != binding["expected_deferred_blockers"]:
        fail("persistence_result_authority_mismatch")
    return {
        "aggregate_path": binding["aggregate_path"],
        "aggregate_sha256": binding["aggregate_sha256"],
        "by_severity_blocker": blocker_count,
        "disposition_path": binding["disposition_path"],
        "disposition_sha256": binding["disposition_sha256"],
        "expected_deferred_blockers": binding["expected_deferred_blockers"],
        "halted": parsed["halted"],
        "halted_due_to_overflow": parsed["halted_due_to_overflow"],
        "require_clean": binding["require_clean"],
        "result_sha256": result_sha256,
        "status": status,
    }


def _staged_modified_paths(working_dir: str) -> tuple[str, ...]:
    result = _git(
        working_dir,
        "diff",
        "--cached",
        "--no-renames",
        "--name-status",
        "-z",
        "--",
    )
    if result.returncode != 0:
        fail("git_state_unreadable")
    if result.stdout and not result.stdout.endswith(b"\x00"):
        fail("staged_path_invalid")
    fields = result.stdout[:-1].split(b"\x00") if result.stdout else []
    if len(fields) % 2 != 0:
        fail("staged_path_invalid")
    paths: list[str] = []
    for index in range(0, len(fields), 2):
        status_raw, path_raw = fields[index : index + 2]
        if status_raw != b"M":
            fail("staged_change_invalid")
        decoded = _decode_git_paths(path_raw + b"\x00", "staged_path_invalid")
        if len(decoded) != 1:
            fail("staged_path_invalid")
        paths.append(decoded[0])
    if len(paths) != len(set(paths)):
        fail("staged_path_invalid")
    return tuple(paths)


def _validate_sha1_index(payload: bytes) -> None:
    if len(payload) <= 20 or hashlib.sha1(payload[:-20]).digest() != payload[-20:]:
        fail("index_tree_unreadable")


def _index_entry_layout(payload: bytes) -> tuple[int, int, bool]:
    _validate_sha1_index(payload)
    content_limit = len(payload) - 20
    if content_limit < 12 or payload[:4] != b"DIRC":
        fail("index_tree_unreadable")
    version = int.from_bytes(payload[4:8], "big")
    entry_count = int.from_bytes(payload[8:12], "big")
    if version not in {2, 3, 4}:
        fail("index_tree_unreadable")
    offset = 12
    sparse = False
    for _ in range(entry_count):
        entry_start = offset
        fixed_end = offset + 62
        if fixed_end > content_limit:
            fail("index_tree_unreadable")
        sparse = sparse or int.from_bytes(
            payload[entry_start + 24 : entry_start + 28], "big"
        ) == 0o040000
        flags = int.from_bytes(payload[fixed_end - 2 : fixed_end], "big")
        if flags & 0x8000:
            fail("index_tree_unreadable")
        offset = fixed_end
        if version >= 3 and flags & 0x4000:
            if offset + 2 > content_limit:
                fail("index_tree_unreadable")
            if int.from_bytes(payload[offset : offset + 2], "big") & 0x6000:
                fail("index_tree_unreadable")
            offset += 2
        if version in {2, 3}:
            terminator = payload.find(b"\x00", offset, content_limit)
            if terminator < 0:
                fail("index_tree_unreadable")
            consumed = terminator + 1 - entry_start
            offset = entry_start + ((consumed + 7) // 8) * 8
            if offset > content_limit:
                fail("index_tree_unreadable")
        else:
            while True:
                if offset >= content_limit:
                    fail("index_tree_unreadable")
                marker = payload[offset]
                offset += 1
                if marker & 0x80 == 0:
                    break
            terminator = payload.find(b"\x00", offset, content_limit)
            if terminator < 0:
                fail("index_tree_unreadable")
            offset = terminator + 1
    return offset, content_limit, sparse


def _decode_index_v4_offset(
    payload: bytes, offset: int, content_limit: int
) -> tuple[int, int]:
    if offset >= content_limit:
        fail("index_tree_unreadable")
    marker = payload[offset]
    offset += 1
    value = marker & 0x7F
    while marker & 0x80:
        if offset >= content_limit:
            fail("index_tree_unreadable")
        value += 1
        marker = payload[offset]
        offset += 1
        value = (value << 7) + (marker & 0x7F)
        if value > INDEX_LIMIT:
            fail("index_tree_unreadable")
    return value, offset


def _parse_raw_index(
    payload: bytes, *, split_overlay: bool
) -> tuple[list[tuple[bytes, bytes, bytes, bytes]], dict[bytes, bytes]]:
    _validate_sha1_index(payload)
    content_limit = len(payload) - 20
    if content_limit < 12 or payload[:4] != b"DIRC":
        fail("index_tree_unreadable")
    version = int.from_bytes(payload[4:8], "big")
    entry_count = int.from_bytes(payload[8:12], "big")
    if version not in {2, 3, 4}:
        fail("index_tree_unreadable")
    offset = 12
    previous_path = b""
    entries: list[tuple[bytes, bytes, bytes, bytes]] = []
    for _ in range(entry_count):
        entry_start = offset
        fixed_end = offset + 62
        if fixed_end > content_limit:
            fail("index_tree_unreadable")
        mode_value = int.from_bytes(payload[offset + 24 : offset + 28], "big")
        oid = payload[offset + 40 : offset + 60]
        flags = int.from_bytes(payload[offset + 60 : fixed_end], "big")
        if mode_value not in {0o100644, 0o100755, 0o120000, 0o160000}:
            fail("index_tree_unreadable")
        if not any(oid) or flags & 0x8000:
            fail("index_tree_unreadable")
        stage = (flags >> 12) & 3
        offset = fixed_end
        if flags & 0x4000:
            if version < 3 or offset + 2 > content_limit:
                fail("index_tree_unreadable")
            extended = int.from_bytes(payload[offset : offset + 2], "big")
            if extended != 0:
                fail("index_tree_unreadable")
            offset += 2
        if version in {2, 3}:
            terminator = payload.find(b"\x00", offset, content_limit)
            if terminator < 0:
                fail("index_tree_unreadable")
            path = payload[offset:terminator]
            consumed = terminator + 1 - entry_start
            offset = entry_start + ((consumed + 7) // 8) * 8
            if offset > content_limit or any(payload[terminator + 1 : offset]):
                fail("index_tree_unreadable")
        else:
            remove, offset = _decode_index_v4_offset(payload, offset, content_limit)
            if remove > len(previous_path):
                fail("index_tree_unreadable")
            terminator = payload.find(b"\x00", offset, content_limit)
            if terminator < 0:
                fail("index_tree_unreadable")
            path = previous_path[: len(previous_path) - remove] + payload[offset:terminator]
            offset = terminator + 1
        encoded_length = flags & 0x0FFF
        if (
            (not path and not split_overlay)
            or (path and (path.startswith(b"/") or path.endswith(b"/")))
            or (path and encoded_length < 0x0FFF and encoded_length != len(path))
            or (path and encoded_length == 0x0FFF and len(path) < 0x0FFF)
            or any(
                component in {b"", b".", b"..", b".git"}
                for component in path.split(b"/")
                if path
            )
        ):
            fail("index_tree_unreadable")
        mode = f"{mode_value:06o}".encode("ascii")
        entries.append((mode, oid.hex().encode("ascii"), str(stage).encode("ascii"), path))
        previous_path = path
    extensions: dict[bytes, bytes] = {}
    while offset < content_limit:
        if offset + 8 > content_limit:
            fail("index_tree_unreadable")
        signature = payload[offset : offset + 4]
        size = int.from_bytes(payload[offset + 4 : offset + 8], "big")
        offset += 8
        end = offset + size
        if end > content_limit or signature in extensions:
            fail("index_tree_unreadable")
        # Index-extension policy (#643). The rule is git's own, from
        # `read_index_extension`: a signature whose first byte is 'A'..'Z' is
        # OPTIONAL -- git prints "ignoring <SIG> extension" and reads on -- and
        # any other first byte marks a MANDATORY extension git refuses outright
        # ("index uses <sig> extension, which we do not understand"). Both
        # directions are measured against the installed git in
        # tests/code-fixer-contract.test.sh, so this is a pin rather than a
        # transcription.
        #
        # Optional extensions do not change what the entries mean, so they are
        # recorded and skipped. REUC is the one that used to be refused here:
        # git writes resolve-undo into .git/index the moment ANY merge conflict
        # is resolved, which made prepare-authority unusable on exactly the
        # consolidated checkouts /review-pr Phase 0 produces. `git write-tree`
        # returns the identical sha with and without it -- that is the test's
        # measurement, not a claim. EOIE and IEOT (`index.threads`,
        # `feature.manyFiles`) are the same class and must stay readable too.
        #
        # Mandatory extensions get the opposite default, because ignoring one
        # means misreading the index:
        #   link  the one mandatory extension this parser DOES implement, so
        #         it is recorded: _split_index_stage_rows resolves the overlay
        #         against the shared index, and _raw_index_stage_rows refuses a
        #         `link` that arrives through the non-split path.
        #   sdir  refused deliberately and permanently -- a sparse index lets a
        #         single entry stand for a whole subtree, so the stage rows
        #         derived below would no longer describe the same tree.
        #   any other signature is unknown to this parser by definition.
        #
        # This refuses a WELL-FORMED extension by policy; the index itself
        # parsed. It therefore does not share the parse-failure token, which
        # sent the #643 operator hunting for corruption that was never there.
        if signature == b"sdir" or (
            not signature[:1].isupper() and signature != b"link"
        ):
            fail("index_extension_refused")
        extensions[signature] = payload[offset:end]
        offset = end
    if offset != content_limit:
        fail("index_tree_unreadable")
    if not split_overlay:
        previous_key: tuple[bytes, bytes] | None = None
        for _mode, _oid_hex, stage, path in entries:
            key = path, stage
            if previous_key is not None and key <= previous_key:
                fail("index_tree_unreadable")
            previous_key = key
    return entries, extensions


def _decode_ewah_bitmap(
    payload: bytes, offset: int, maximum_bits: int
) -> tuple[set[int], int]:
    if offset + 8 > len(payload):
        fail("index_tree_unreadable")
    bit_size = int.from_bytes(payload[offset : offset + 4], "big")
    word_count = int.from_bytes(payload[offset + 4 : offset + 8], "big")
    expected_words = (bit_size + 63) // 64
    offset += 8
    words_end = offset + word_count * 8
    if bit_size > maximum_bits or words_end + 4 > len(payload):
        fail("index_tree_unreadable")
    words = [
        int.from_bytes(payload[position : position + 8], "big")
        for position in range(offset, words_end, 8)
    ]
    current_rlw = int.from_bytes(payload[words_end : words_end + 4], "big")
    if word_count == 0 or current_rlw >= word_count:
        fail("index_tree_unreadable")
    header_positions: set[int] = set()
    result: set[int] = set()
    word_index = 0
    uncompressed_word = 0
    while word_index < word_count:
        header_positions.add(word_index)
        header = words[word_index]
        word_index += 1
        repeated_bit = header & 1
        repeated_words = (header >> 1) & 0xFFFFFFFF
        literal_words = header >> 33
        remaining_words = expected_words - uncompressed_word
        if (
            remaining_words < 0
            or repeated_words > remaining_words
            or literal_words > remaining_words - repeated_words
            or word_index + literal_words > word_count
        ):
            fail("index_tree_unreadable")
        if repeated_bit:
            repeated_end = uncompressed_word + repeated_words
            if bit_size % 64 and repeated_end == expected_words:
                fail("index_tree_unreadable")
            result.update(range(uncompressed_word * 64, repeated_end * 64))
        uncompressed_word += repeated_words
        for literal_index in range(literal_words):
            literal = words[word_index + literal_index]
            base = uncompressed_word * 64
            while literal:
                low = literal & -literal
                bit = low.bit_length() - 1
                position = base + bit
                if position >= bit_size:
                    fail("index_tree_unreadable")
                result.add(position)
                literal ^= low
            uncompressed_word += 1
        word_index += literal_words
    if (
        current_rlw not in header_positions
        or current_rlw != max(header_positions)
        or uncompressed_word != expected_words
    ):
        fail("index_tree_unreadable")
    return result, words_end + 4


def _stage_rows_from_entries(
    entries: list[tuple[bytes, bytes, bytes, bytes]]
) -> bytes:
    rows = bytearray()
    previous: tuple[bytes, bytes] | None = None
    for mode, oid_hex, stage, path in entries:
        key = path, stage
        if previous is not None and key <= previous:
            fail("index_tree_unreadable")
        previous = key
        rows.extend(mode + b" " + oid_hex + b" " + stage + b"\t" + path + b"\x00")
        if len(rows) > INDEX_LIMIT:
            fail("index_tree_unreadable")
    for _row in _iter_stage_rows(bytes(rows)):
        pass
    return bytes(rows)


def _raw_index_stage_rows(index_payload: bytes) -> bytes:
    entries, extensions = _parse_raw_index(index_payload, split_overlay=False)
    if b"link" in extensions:
        fail("index_tree_unreadable")
    return _stage_rows_from_entries(entries)


def _split_index_stage_rows(index_payload: bytes, shared_payload: bytes) -> bytes:
    shared_entries, shared_extensions = _parse_raw_index(
        shared_payload, split_overlay=False
    )
    if b"link" in shared_extensions:
        fail("index_tree_unreadable")
    overlay_entries, overlay_extensions = _parse_raw_index(
        index_payload, split_overlay=True
    )
    link = overlay_extensions.get(b"link")
    if link is None or len(link) < 20 or link[:20] != shared_payload[-20:]:
        fail("index_tree_unreadable")
    delete_positions, offset = _decode_ewah_bitmap(
        link, 20, len(shared_entries)
    )
    replace_positions, offset = _decode_ewah_bitmap(
        link, offset, len(shared_entries)
    )
    if (
        offset != len(link)
        or delete_positions & replace_positions
        or len(overlay_entries) < len(replace_positions)
    ):
        fail("index_tree_unreadable")
    replacements: dict[int, tuple[bytes, bytes, bytes, bytes]] = {}
    for overlay_index, shared_index in enumerate(sorted(replace_positions)):
        mode, oid_hex, stage, path = overlay_entries[overlay_index]
        if path:
            fail("index_tree_unreadable")
        path = shared_entries[shared_index][3]
        replacements[shared_index] = (mode, oid_hex, stage, path)
    combined: list[tuple[bytes, bytes, bytes, bytes]] = []
    for shared_index, entry in enumerate(shared_entries):
        selected = replacements.get(shared_index, entry)
        if shared_index not in delete_positions:
            combined.append(selected)
    for entry in overlay_entries[len(replace_positions) :]:
        if not entry[3]:
            fail("index_tree_unreadable")
        combined.append(entry)
    additions = overlay_entries[len(replace_positions) :]
    if any(
        (additions[index - 1][3], additions[index - 1][2])
        >= (additions[index][3], additions[index][2])
        for index in range(1, len(additions))
    ):
        fail("index_tree_unreadable")
    combined.sort(key=lambda row: (row[3], row[2]))
    return _stage_rows_from_entries(combined)


def _index_shared_reference(payload: bytes) -> str | None:
    offset, content_limit, _sparse = _index_entry_layout(payload)

    link_oid: bytes | None = None
    while offset < content_limit:
        if offset + 8 > content_limit:
            fail("index_tree_unreadable")
        signature = payload[offset : offset + 4]
        extension_size = int.from_bytes(payload[offset + 4 : offset + 8], "big")
        offset += 8
        extension_end = offset + extension_size
        if extension_end > content_limit:
            fail("index_tree_unreadable")
        if signature == b"link":
            if link_oid is not None or extension_size < 20:
                fail("index_tree_unreadable")
            link_oid = payload[offset : offset + 20]
        offset = extension_end
    if offset != content_limit:
        fail("index_tree_unreadable")
    if link_oid is None or not any(link_oid):
        return None
    return "sharedindex." + link_oid.hex()


def _capture_shared_index(
    index_path: str, index_payload: bytes
) -> tuple[str, bytes, ArtifactIdentity] | None:
    reference = _index_shared_reference(index_payload)
    if reference is None:
        return None
    name = reference
    path = os.path.join(os.path.dirname(index_path), name)
    try:
        payload, identity = _capture_regular(path, 32, INDEX_LIMIT)
    except ContractFailure:
        fail("index_tree_unreadable")
    expected_oid = bytes.fromhex(name.removeprefix("sharedindex."))
    if (
        len(payload) <= 20
        or hashlib.sha1(payload[:-20]).digest() != payload[-20:]
        or payload[-20:] != expected_oid
    ):
        fail("index_tree_unreadable")
    return path, payload, identity


def _directory_identity(path: str, reason: str) -> tuple[int, int, int]:
    try:
        before = os.lstat(path)
        attributes = getattr(before, "st_file_attributes", 0)
        reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
        if (
            not stat.S_ISDIR(before.st_mode)
            or bool(attributes & reparse)
        ):
            fail(reason)
        if os.name == "nt":
            current = os.lstat(path)
            if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
                fail(reason)
            return before.st_dev, before.st_ino, stat.S_IMODE(before.st_mode)
        directory = getattr(os, "O_DIRECTORY", None)
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if directory is None or nofollow is None:
            fail(reason)
        descriptor = os.open(
            path,
            os.O_RDONLY | directory | nofollow | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            opened = os.fstat(descriptor)
            current = os.lstat(path)
        finally:
            os.close(descriptor)
    except ContractFailure:
        raise
    except OSError:
        fail(reason)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or not stat.S_ISDIR(current.st_mode)
        or (before.st_dev, before.st_ino)
        != (opened.st_dev, opened.st_ino)
        or (opened.st_dev, opened.st_ino)
        != (current.st_dev, current.st_ino)
    ):
        fail(reason)
    return opened.st_dev, opened.st_ino, stat.S_IMODE(opened.st_mode)


def _scrubbed_git_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.upper().startswith("GIT_")
    }
    environment.update(
        {
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    return environment




def _require_sha1_repository(working_dir: str) -> None:
    try:
        result = subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                working_dir,
                "rev-parse",
                "--show-object-format",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
            check=False,
        )
    except OSError:
        fail("git_unavailable")
    if result.returncode != 0 or result.stdout != b"sha1\n":
        fail("index_tree_unreadable")


def _repository_object_directory(
    working_dir: str,
) -> tuple[str, tuple[int, int, int]]:
    try:
        result = subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                working_dir,
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
            check=False,
        )
    except OSError:
        fail("git_unavailable")
    if result.returncode != 0 or not result.stdout.endswith(b"\n"):
        fail("index_tree_unreadable")
    raw = result.stdout[:-1]
    if b"\x00" in raw or b"\n" in raw or b"\r" in raw:
        fail("index_tree_unreadable")
    try:
        common = os.path.realpath(raw.decode("utf-8"))
    except UnicodeError:
        fail("index_tree_unreadable")
    objects = os.path.join(common, "objects")
    return objects, _directory_identity(objects, "index_tree_unreadable")


def _validate_normalized_index(payload: bytes) -> None:
    _validate_sha1_index(payload)
    content_limit = len(payload) - 20
    if content_limit < 12 or payload[:4] != b"DIRC":
        fail("index_tree_unreadable")
    version = int.from_bytes(payload[4:8], "big")
    entry_count = int.from_bytes(payload[8:12], "big")
    if version not in {2, 3}:
        fail("index_tree_unreadable")
    offset = 12
    for _ in range(entry_count):
        entry_start = offset
        fixed_end = offset + 62
        if fixed_end > content_limit:
            fail("index_tree_unreadable")
        oid = payload[offset + 40 : offset + 60]
        flags = int.from_bytes(payload[fixed_end - 2 : fixed_end], "big")
        if not any(oid) or flags & 0xB000:
            fail("index_tree_unreadable")
        offset = fixed_end
        if flags & 0x4000:
            if version != 3 or offset + 2 > content_limit:
                fail("index_tree_unreadable")
            extended = int.from_bytes(payload[offset : offset + 2], "big")
            if extended or extended & ~0x6000:
                fail("index_tree_unreadable")
            offset += 2
        terminator = payload.find(b"\x00", offset, content_limit)
        if terminator < 0:
            fail("index_tree_unreadable")
        path = payload[offset:terminator]
        encoded_length = flags & 0x0FFF
        if (
            not path
            or path.startswith(b"/")
            or path.endswith(b"/")
            or (encoded_length < 0x0FFF and encoded_length != len(path))
            or (encoded_length == 0x0FFF and len(path) < 0x0FFF)
            or any(component in {b"", b".", b".."} for component in path.split(b"/"))
        ):
            fail("index_tree_unreadable")
        consumed = terminator + 1 - entry_start
        offset = entry_start + ((consumed + 7) // 8) * 8
        if offset > content_limit or any(payload[terminator + 1 : offset]):
            fail("index_tree_unreadable")
    while offset < content_limit:
        if offset + 8 > content_limit:
            fail("index_tree_unreadable")
        signature = payload[offset : offset + 4]
        extension_size = int.from_bytes(payload[offset + 4 : offset + 8], "big")
        offset += 8
        extension_end = offset + extension_size
        if extension_end > content_limit or signature == b"link":
            fail("index_tree_unreadable")
        offset = extension_end
    if offset != content_limit:
        fail("index_tree_unreadable")


def _iter_stage_rows(payload: bytes):
    if len(payload) > INDEX_LIMIT or (payload and not payload.endswith(b"\x00")):
        fail("index_tree_unreadable")
    offset = 0
    previous_path: bytes | None = None
    while offset < len(payload):
        terminator = payload.find(b"\x00", offset)
        if terminator < 0:
            fail("index_tree_unreadable")
        row = payload[offset:terminator]
        offset = terminator + 1
        metadata, separator, path = row.partition(b"\t")
        fields = metadata.split(b" ")
        if not separator or len(fields) != 3:
            fail("index_tree_unreadable")
        mode, oid_hex, stage = fields
        if (
            mode not in {b"100644", b"100755", b"120000", b"160000"}
            or stage != b"0"
            or len(oid_hex) != 40
            or SHA1_BYTES.fullmatch(oid_hex) is None
            or oid_hex == b"0" * 40
            or not path
            or path.startswith(b"/")
            or path.endswith(b"/")
        ):
            fail("index_tree_unreadable")
        components = path.split(b"/")
        if any(component in {b"", b".", b".."} for component in components):
            fail("index_tree_unreadable")
        if previous_path is not None and (
            path <= previous_path or path.startswith(previous_path + b"/")
        ):
            fail("index_tree_unreadable")
        previous_path = path
        yield mode, oid_hex, path, components


def _start_index_object_verifier(working_dir: str) -> subprocess.Popen[bytes]:
    try:
        return subprocess.Popen(
            [
                "git",
                "--no-optional-locks",
                "-C",
                working_dir,
                "cat-file",
                "--batch-check=%(objectname) %(objecttype)",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
        )
    except OSError:
        fail("git_unavailable")


def _verify_index_blob(process: subprocess.Popen[bytes], oid_hex: bytes) -> None:
    if process.stdin is None or process.stdout is None:
        fail("index_tree_unreadable")
    try:
        process.stdin.write(oid_hex + b"\n")
        process.stdin.flush()
        response = process.stdout.readline(96)
    except OSError:
        fail("index_tree_unreadable")
    if response != oid_hex + b" blob\n":
        fail("index_tree_unreadable")


def _close_index_object_verifier(process: subprocess.Popen[bytes]) -> None:
    succeeded = True
    try:
        if process.stdin is not None:
            process.stdin.close()
        if process.stdout is not None:
            remainder = process.stdout.read(1)
            succeeded = remainder == b""
            process.stdout.close()
        succeeded = process.wait() == 0 and succeeded
    except OSError:
        succeeded = False
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    if not succeeded:
        fail("index_tree_unreadable")


def _abort_index_object_verifier(process: subprocess.Popen[bytes]) -> None:
    try:
        if process.stdin is not None:
            process.stdin.close()
    except OSError:
        pass
    if process.poll() is None:
        process.kill()
    try:
        process.wait()
    except OSError:
        pass
    for stream in (process.stdout,):
        try:
            if stream is not None:
                stream.close()
        except OSError:
            pass


def _tree_object_id(body: bytearray) -> bytes:
    header = f"tree {len(body)}\0".encode("ascii")
    digest = hashlib.sha1()
    digest.update(header)
    digest.update(body)
    return digest.digest()


def _append_tree_entry(
    frame: dict[str, Any], name: bytes, mode: bytes, oid: bytes, *, directory: bool
) -> None:
    key = name + (b"/" if directory else b"\x00")
    previous = frame["last_key"]
    if previous is not None and key <= previous:
        fail("index_tree_unreadable")
    frame["last_key"] = key
    frame["body"].extend(mode + b" " + name + b"\x00" + oid)


def _tree_sha_from_stage_rows(working_dir: str, payload: bytes) -> str:
    frames: list[dict[str, Any]] = [
        {"name": None, "body": bytearray(), "last_key": None}
    ]
    verifier: subprocess.Popen[bytes] | None = None
    try:
        for mode, oid_hex, _path, components in _iter_stage_rows(payload):
            directories = components[:-1]
            common = 0
            while (
                common < len(directories)
                and common + 1 < len(frames)
                and frames[common + 1]["name"] == directories[common]
            ):
                common += 1
            while len(frames) - 1 > common:
                child = frames.pop()
                _append_tree_entry(
                    frames[-1],
                    child["name"],
                    b"40000",
                    _tree_object_id(child["body"]),
                    directory=True,
                )
            for name in directories[common:]:
                frames.append({"name": name, "body": bytearray(), "last_key": None})
            if mode != b"160000":
                if verifier is None:
                    verifier = _start_index_object_verifier(working_dir)
                _verify_index_blob(verifier, oid_hex)
            _append_tree_entry(
                frames[-1],
                components[-1],
                mode,
                bytes.fromhex(oid_hex.decode("ascii")),
                directory=False,
            )
        while len(frames) > 1:
            child = frames.pop()
            _append_tree_entry(
                frames[-1],
                child["name"],
                b"40000",
                _tree_object_id(child["body"]),
                directory=True,
            )
        if verifier is not None:
            _close_index_object_verifier(verifier)
            verifier = None
        return _tree_object_id(frames[0]["body"]).hex()
    finally:
        if verifier is not None:
            _abort_index_object_verifier(verifier)


def _hold_captured_regular(path: str, expected: ArtifactIdentity) -> int:
    descriptor = -1
    try:
        if os.name == "nt":
            import ctypes
            import msvcrt
            from ctypes import wintypes

            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            create_file = kernel32.CreateFileW
            create_file.argtypes = [
                wintypes.LPCWSTR,
                wintypes.DWORD,
                wintypes.DWORD,
                wintypes.LPVOID,
                wintypes.DWORD,
                wintypes.DWORD,
                wintypes.HANDLE,
            ]
            create_file.restype = wintypes.HANDLE
            handle = create_file(
                path,
                0x80000000 | 0x00000080,  # GENERIC_READ | FILE_READ_ATTRIBUTES
                0x00000001,  # FILE_SHARE_READ: deny writes, replacement, and delete.
                None,
                3,  # OPEN_EXISTING
                0x00000080 | 0x00200000,  # NORMAL | OPEN_REPARSE_POINT
                None,
            )
            invalid_handle = ctypes.c_void_p(-1).value
            if handle in (None, invalid_handle):
                fail("index_tree_unreadable")
            try:
                descriptor = msvcrt.open_osfhandle(
                    int(handle), os.O_RDONLY | getattr(os, "O_BINARY", 0)
                )
            except BaseException:
                kernel32.CloseHandle(wintypes.HANDLE(handle))
                raise
        else:
            descriptor = os.open(
                path,
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_BINARY", 0),
            )
        observed = os.fstat(descriptor)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        fail("index_tree_unreadable")
    if (
        not stat.S_ISREG(observed.st_mode)
        or observed.st_nlink != 1
        or (observed.st_dev, observed.st_ino, observed.st_size)
        != (expected.device, expected.inode, expected.size)
        or getattr(
            observed, "st_mtime_ns", int(observed.st_mtime * 1_000_000_000)
        )
        != expected.mtime_ns
        or stat.S_IMODE(observed.st_mode) != stat.S_IMODE(expected.mode)
    ):
        os.close(descriptor)
        fail("index_tree_unreadable")
    return descriptor




def _read_bounded_process_stdout(
    process: subprocess.Popen[bytes], maximum: int, reason: str
) -> tuple[bytes, int]:
    if process.stdout is None:
        fail(reason)
    try:
        payload = process.stdout.read(maximum + 1)
        process.stdout.close()
        if len(payload) > maximum and process.poll() is None:
            process.kill()
        returncode = process.wait()
    except BaseException as error:
        try:
            process.stdout.close()
        except BaseException:
            pass
        try:
            if process.poll() is None:
                process.kill()
            process.wait()
        except BaseException:
            pass
        if isinstance(error, OSError):
            fail(reason)
        raise error.with_traceback(error.__traceback__)
    if len(payload) > maximum:
        fail(reason)
    return payload, returncode




def _captured_index_stage_rows(
    working_dir: str,
    index_path: str,
    index_payload: bytes,
    index_identity: ArtifactIdentity,
) -> bytes:
    _require_sha1_repository(working_dir)
    shared = _capture_shared_index(index_path, index_payload)
    if _index_entry_layout(index_payload)[2] or (
        shared is not None and _index_entry_layout(shared[1])[2]
    ):
        fail("index_tree_unreadable")
    source_descriptors = [_hold_captured_regular(index_path, index_identity)]
    if shared is not None:
        source_descriptors.append(_hold_captured_regular(shared[0], shared[2]))
    primary_error: BaseException | None = None
    primary_traceback = None
    rows = b""
    try:
        rows = (
            _raw_index_stage_rows(index_payload)
            if shared is None
            else _split_index_stage_rows(index_payload, shared[1])
        )
        observed_payload, observed_identity = _capture_regular(
            index_path, len(index_payload), len(index_payload)
        )
        if observed_payload != index_payload or observed_identity != index_identity:
            fail("index_tree_unreadable")
        if shared is not None:
            shared_path, shared_payload, shared_identity = shared
            observed_shared, observed_shared_identity = _capture_regular(
                shared_path, len(shared_payload), len(shared_payload)
            )
            if (
                observed_shared != shared_payload
                or observed_shared_identity != shared_identity
            ):
                fail("index_tree_unreadable")
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        close_failed = False
        for descriptor in source_descriptors:
            try:
                os.close(descriptor)
            except OSError:
                close_failed = True
        if close_failed:
            primary_error = ContractFailure("index_tree_unreadable")
            primary_traceback = primary_error.__traceback__
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    return rows


def _captured_index_tree_sha(
    working_dir: str,
    index_path: str,
    index_payload: bytes,
    index_identity: ArtifactIdentity,
) -> str:
    return _tree_sha_from_stage_rows(
        working_dir,
        _captured_index_stage_rows(
            working_dir, index_path, index_payload, index_identity
        ),
    )


def _serialize_index_v2(rows) -> bytes:
    payload = bytearray(b"DIRC" + (2).to_bytes(4, "big") + b"\x00" * 4)
    count = 0
    previous_path: bytes | None = None
    for mode, oid_hex, path in rows:
        if (
            mode not in {b"100644", b"100755", b"120000", b"160000"}
            or len(oid_hex) != 40
            or SHA1_BYTES.fullmatch(oid_hex) is None
            or oid_hex == b"0" * 40
            or not path
            or path.startswith(b"/")
            or path.endswith(b"/")
            or any(component in {b"", b".", b".."} for component in path.split(b"/"))
            or (previous_path is not None and path <= previous_path)
        ):
            fail("index_entry_invalid")
        previous_path = path
        count += 1
        if count > 0xFFFFFFFF:
            fail("index_entry_invalid")
        entry_start = len(payload)
        payload.extend(b"\x00" * 24)
        payload.extend(int(mode, 8).to_bytes(4, "big"))
        payload.extend(b"\x00" * 12)
        payload.extend(bytes.fromhex(oid_hex.decode("ascii")))
        payload.extend(min(len(path), 0x0FFF).to_bytes(2, "big"))
        payload.extend(path)
        payload.append(0)
        payload.extend(b"\x00" * ((8 - ((len(payload) - entry_start) % 8)) % 8))
        if len(payload) + 20 > INDEX_LIMIT:
            fail("index_entry_invalid")
    payload[8:12] = count.to_bytes(4, "big")
    payload.extend(hashlib.sha1(payload).digest())
    normalized = bytes(payload)
    _validate_normalized_index(normalized)
    return normalized


def _replacement_stage_rows(
    entries: dict[str, dict[str, str]],
) -> list[tuple[bytes, bytes, bytes]]:
    replacements: list[tuple[bytes, bytes, bytes]] = []
    for path, entry in entries.items():
        if (
            not isinstance(path, str)
            or not _valid_tree_entry(
                {"mode": entry.get("mode"), "oid": entry.get("oid")},
                index=False,
            )
        ):
            fail("index_entry_invalid")
        _safe_repo_path(path)
        try:
            encoded_path = path.encode("utf-8")
        except UnicodeError:
            fail("index_entry_invalid")
        replacements.append(
            (entry["mode"].encode("ascii"), entry["oid"].encode("ascii"), encoded_path)
        )
    replacements.sort(key=lambda row: row[2])
    if any(
        replacements[index - 1][2] == replacements[index][2]
        for index in range(1, len(replacements))
    ):
        fail("index_entry_invalid")
    return replacements


def _merge_stage_rows(
    baseline_rows: bytes, entries: dict[str, dict[str, str]]
):
    replacements = _replacement_stage_rows(entries)
    replacement_index = 0
    for mode, oid_hex, path, _components in _iter_stage_rows(baseline_rows):
        while (
            replacement_index < len(replacements)
            and replacements[replacement_index][2] < path
        ):
            yield replacements[replacement_index]
            replacement_index += 1
        if (
            replacement_index < len(replacements)
            and replacements[replacement_index][2] == path
        ):
            yield replacements[replacement_index]
            replacement_index += 1
        else:
            yield mode, oid_hex, path
    while replacement_index < len(replacements):
        yield replacements[replacement_index]
        replacement_index += 1


def _index_candidate_from_stage_rows(
    baseline_rows: bytes, entries: dict[str, dict[str, str]]
) -> bytes:
    return _serialize_index_v2(_merge_stage_rows(baseline_rows, entries))


def _read_tree_stage_rows(working_dir: str, treeish: str) -> bytes:
    if SHA1.fullmatch(treeish) is None:
        fail("temporary_index_failed")
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [
                "git",
                "--no-optional-locks",
                "-C",
                working_dir,
                "ls-tree",
                "-r",
                "-z",
                "--full-tree",
                treeish,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
        )
    except OSError:
        fail("git_unavailable")
    raw, returncode = _read_bounded_process_stdout(
        process, INDEX_LIMIT, "temporary_index_failed"
    )
    if returncode != 0 or (raw and not raw.endswith(b"\x00")):
        fail("temporary_index_failed")
    rows = bytearray()
    offset = 0
    while offset < len(raw):
        terminator = raw.find(b"\x00", offset)
        if terminator < 0:
            fail("temporary_index_failed")
        metadata, separator, path = raw[offset:terminator].partition(b"\t")
        fields = metadata.split(b" ")
        if not separator or len(fields) != 3:
            fail("temporary_index_failed")
        mode, object_type, oid_hex = fields
        if (mode == b"160000" and object_type != b"commit") or (
            mode != b"160000" and object_type != b"blob"
        ):
            fail("temporary_index_failed")
        rows.extend(mode + b" " + oid_hex + b" 0\t" + path + b"\x00")
        if len(rows) > INDEX_LIMIT:
            fail("temporary_index_failed")
        offset = terminator + 1
    for _row in _iter_stage_rows(bytes(rows)):
        pass
    return bytes(rows)


def _build_tree_index_candidate(
    working_dir: str, treeish: str, entries: dict[str, dict[str, str]]
) -> bytes:
    return _index_candidate_from_stage_rows(
        _read_tree_stage_rows(working_dir, treeish), entries
    )


def _run_candidate_write_tree(
    working_dir: str, index_path: str
) -> subprocess.CompletedProcess[bytes]:
    environment = _scrubbed_git_environment()
    environment["GIT_INDEX_FILE"] = index_path
    try:
        process = subprocess.Popen(
            [
                "git",
                "-C",
                working_dir,
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.splitIndex=false",
                "write-tree",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
        )
    except OSError:
        fail("git_unavailable")
    stdout, returncode = _read_bounded_process_stdout(
        process, 128, "index_tree_unreadable"
    )
    return subprocess.CompletedProcess(process.args, returncode, stdout, b"")


def _quarantine_changed_candidate(index_path: str) -> None:
    if not os.path.lexists(index_path):
        return
    parent = os.path.dirname(index_path)
    for _ in range(128):
        quarantine = os.path.join(
            parent, ".code-fixer-index-quarantine-" + secrets.token_hex(16)
        )
        try:
            atomic_rename_noreplace(index_path, quarantine)
            return
        except FileExistsError:
            continue
        except OSError:
            fail("temporary_cleanup_failed")
    fail("temporary_cleanup_failed")


def _publish_captured_index_tree(
    working_dir: str,
    index_path: str,
    expected_payload: bytes,
    expected_identity: ArtifactIdentity,
) -> str:
    observation = _acquire_index_observation_lock(working_dir)
    primary_error: BaseException | None = None
    primary_traceback = None
    tree_sha = ""
    try:
        if (
            not os.path.isabs(index_path)
            or os.path.normcase(os.path.realpath(index_path))
            == os.path.normcase(os.path.realpath(observation.index_path))
        ):
            fail("index_tree_environment_invalid")
        try:
            candidate, candidate_identity = _capture_regular(
                index_path, len(expected_payload), len(expected_payload)
            )
        except ContractFailure:
            _quarantine_changed_candidate(index_path)
            fail("index_tree_unreadable")
        if candidate != expected_payload or candidate_identity != expected_identity:
            _quarantine_changed_candidate(index_path)
            fail("index_tree_unreadable")
        if (candidate_identity.device, candidate_identity.inode) == (
            observation.index_identity.device,
            observation.index_identity.inode,
        ):
            fail("index_tree_environment_invalid")
        _validate_normalized_index(candidate)
        expected_tree = _captured_index_tree_sha(
            working_dir, index_path, candidate, candidate_identity
        )
        objects, objects_identity = _repository_object_directory(working_dir)
        result = _run_candidate_write_tree(working_dir, index_path)
        expected_stdout = expected_tree.encode("ascii") + b"\n"
        if result.returncode != 0 or result.stdout != expected_stdout:
            try:
                current, current_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
            except ContractFailure:
                current = b""
                current_identity = None
            if current_identity != candidate_identity or current != candidate:
                _quarantine_changed_candidate(index_path)
            fail("index_tree_unreadable")
        try:
            post_candidate, post_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
            _validate_normalized_index(post_candidate)
            post_tree = _captured_index_tree_sha(
                working_dir, index_path, post_candidate, post_identity
            )
        except ContractFailure:
            _quarantine_changed_candidate(index_path)
            raise
        if post_tree != expected_tree:
            _quarantine_changed_candidate(index_path)
            fail("index_tree_unreadable")
        if _directory_identity(objects, "index_tree_unreadable") != objects_identity:
            fail("index_tree_unreadable")
        tree_sha = expected_tree
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        try:
            _release_index_observation_lock(observation)
        except BaseException as release_error:
            primary_error = release_error
            primary_traceback = release_error.__traceback__
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    if not tree_sha:
        fail("index_tree_unreadable")
    return tree_sha




def _alternate_index_tree_sha(working_dir: str, index_path: str) -> str:
    try:
        observation = _acquire_index_observation_lock(working_dir)
    except ContractFailure:
        fail("index_tree_environment_invalid")
    real_index = observation.index_path
    primary_error: BaseException | None = None
    primary_traceback = None
    tree_sha = ""
    try:
        if os.path.normcase(os.path.realpath(index_path)) == os.path.normcase(
            os.path.realpath(real_index)
        ):
            fail("index_tree_environment_invalid")
        try:
            alternate_payload, alternate_identity = _capture_regular(
                index_path, 1, INDEX_LIMIT
            )
        except ContractFailure:
            fail("index_tree_environment_invalid")
        if (alternate_identity.device, alternate_identity.inode) == (
            observation.index_identity.device,
            observation.index_identity.inode,
        ):
            fail("index_tree_environment_invalid")
        try:
            current_payload, current_identity = _capture_regular(
                index_path, len(alternate_payload), len(alternate_payload)
            )
        except ContractFailure:
            fail("index_tree_environment_invalid")
        if current_payload != alternate_payload or current_identity != alternate_identity:
            fail("index_tree_environment_invalid")
        tree_sha = _captured_index_tree_sha(
            working_dir, index_path, alternate_payload, alternate_identity
        )
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        try:
            _release_index_observation_lock(observation)
        except BaseException as release_error:
            primary_error = release_error
            primary_traceback = release_error.__traceback__
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    if not tree_sha:
        fail("index_tree_unreadable")
    return tree_sha


def _publish_index_tree_sha(
    working_dir: str,
    index_path: str,
    expected_payload: bytes,
    expected_identity: ArtifactIdentity,
) -> str:
    if "GIT_INDEX_FILE" in os.environ:
        fail("index_tree_environment_invalid")
    if not isinstance(expected_payload, bytes) or not expected_payload:
        fail("index_tree_unreadable")
    return _publish_captured_index_tree(
        working_dir, index_path, expected_payload, expected_identity
    )


def _index_tree_sha(
    working_dir: str, *, extra_env: dict[str, str] | None = None
) -> str:
    if "GIT_INDEX_FILE" in os.environ:
        fail("index_tree_environment_invalid")
    if extra_env is None:
        observation = _acquire_index_observation_lock(working_dir)
        primary_error: BaseException | None = None
        primary_traceback = None
        tree_sha = ""
        try:
            tree_sha = _captured_index_tree_sha(
                working_dir,
                observation.index_path,
                observation.index_payload,
                observation.index_identity,
            )
        except BaseException as error:
            primary_error = error
            primary_traceback = error.__traceback__
        finally:
            try:
                _release_index_observation_lock(observation)
            except BaseException as release_error:
                primary_error = release_error
                primary_traceback = release_error.__traceback__
        if primary_error is not None:
            raise primary_error.with_traceback(primary_traceback)
        if not tree_sha:
            fail("index_tree_unreadable")
        return tree_sha
    if not isinstance(extra_env, dict) or not set(extra_env).issubset(
        {"GIT_INDEX_FILE", "GIT_EDITOR"}
    ):
        fail("index_tree_environment_invalid")
    index_value = extra_env.get("GIT_INDEX_FILE")
    if (
        not isinstance(index_value, str)
        or not index_value
        or not os.path.isabs(index_value)
        or "\x00" in index_value
        or any(ord(character) < 32 or ord(character) == 127 for character in index_value)
    ):
        fail("index_tree_environment_invalid")
    return _alternate_index_tree_sha(working_dir, index_value)


def _commit_message_sha256(working_dir: str, commit_sha: str) -> str:
    if SHA1.fullmatch(commit_sha) is None:
        fail("commit_identity_invalid")
    result = _git(working_dir, "cat-file", "commit", commit_sha)
    if result.returncode != 0:
        fail("commit_state_unreadable")
    _headers, separator, message = result.stdout.partition(b"\n\n")
    if not separator or not message.endswith(b"\n"):
        fail("commit_message_invalid")
    return hashlib.sha256(message[:-1]).hexdigest()


def validate_staged(
    *,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    working_dir: str,
) -> dict[str, Any]:
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
    ):
        fail("validation_authority_mismatch")
    _require_repository(canonical_working)
    snapshot = _recapture_sources(authority)
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    if snapshot is not None:
        if applied_paths:
            fail("standalone_commit_gate_required")
        _require_snapshot_current(snapshot)
        return {
            "status": "validated",
            "phase": authority["phase"],
            "commit_type": authority["commit_type"],
            "disposition_sha256": disposition_sha256,
            "staged_tree_sha": snapshot["index_tree_sha"],
        }
    _require_review_edit_state(authority, applied_paths)
    staged_paths = _staged_modified_paths(canonical_working)
    if sorted(staged_paths) != sorted(applied_paths):
        fail("staged_path_mismatch")
    staged_tree_sha = _index_tree_sha(canonical_working)
    _require_worktree_residue_closed(
        canonical_working, os.path.dirname(authority["findings_path"])
    )
    return {
        "status": "validated",
        "phase": authority["phase"],
        "commit_type": authority["commit_type"],
        "disposition_sha256": disposition_sha256,
        "staged_tree_sha": staged_tree_sha,
    }


STANDALONE_COMMIT_MESSAGE = "refactor: address authenticated fixer findings"
REVIEW_COMMIT_MESSAGES = {
    "phase1": "fix: address authenticated fixer findings",
    "phase2": "refactor: address authenticated fixer findings",
}


def _write_descriptor(descriptor: int, payload: bytes) -> None:
    offset = 0
    try:
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail("index_write_failed")
            offset += written
        os.fsync(descriptor)
    except ContractFailure:
        raise
    except OSError:
        fail("index_write_failed")


def _close_temporary_descriptor(descriptor: int) -> None:
    try:
        os.close(descriptor)
    except OSError:
        fail("temporary_cleanup_failed")


def _cleanup_temporary_paths(*paths: str) -> None:
    try:
        for path in paths:
            if not path or not os.path.lexists(path):
                continue
            entry = os.lstat(path)
            if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
                fail("temporary_cleanup_failed")
            os.unlink(path)
            if os.path.lexists(path):
                fail("temporary_cleanup_failed")
    except ContractFailure:
        raise
    except OSError:
        fail("temporary_cleanup_failed")


def _git_index_path(working_dir: str) -> str:
    try:
        result = subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                working_dir,
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "index",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_scrubbed_git_environment(),
            check=False,
        )
    except OSError:
        fail("git_unavailable")
    if result.returncode != 0:
        fail("index_path_unreadable")
    try:
        rendered = result.stdout.decode("utf-8").rstrip("\n")
    except UnicodeError:
        fail("index_path_unreadable")
    if (
        not rendered
        or "\x00" in rendered
        or any(ord(character) < 32 or ord(character) == 127 for character in rendered)
    ):
        fail("index_path_unreadable")
    candidate = rendered if os.path.isabs(rendered) else os.path.join(working_dir, rendered)
    path = os.path.abspath(candidate)
    try:
        parent = os.stat(os.path.dirname(path), follow_symlinks=False)
    except OSError:
        fail("index_path_unreadable")
    if not stat.S_ISDIR(parent.st_mode):
        fail("index_path_unreadable")
    return path


def _build_index_candidate(
    working_dir: str,
    baseline: bytes,
    baseline_mode: int,
    entries: dict[str, dict[str, str]],
) -> bytes:
    observation = _acquire_index_observation_lock(working_dir)
    primary_error: BaseException | None = None
    primary_traceback = None
    candidate = b""
    try:
        if (
            observation.index_payload != baseline
            or stat.S_IMODE(observation.index_identity.mode)
            != stat.S_IMODE(baseline_mode)
        ):
            fail("index_baseline_mismatch")
        rows = _captured_index_stage_rows(
            working_dir,
            observation.index_path,
            observation.index_payload,
            observation.index_identity,
        )
        candidate = _index_candidate_from_stage_rows(rows, entries)
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        try:
            _release_index_observation_lock(observation)
        except BaseException as release_error:
            primary_error = release_error
            primary_traceback = release_error.__traceback__
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    if not candidate:
        fail("index_update_failed")
    return candidate


def _install_index_candidate(
    index_path: str,
    expected: bytes,
    replacement: bytes,
    mode: int,
) -> None:
    lock_path = index_path + ".lock"
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_BINARY", 0)
    )
    descriptor = -1
    try:
        descriptor = os.open(lock_path, flags, stat.S_IMODE(mode))
        _write_descriptor(descriptor, replacement)
        _close_temporary_descriptor(descriptor)
        descriptor = -1
        current, _identity = _capture_regular(index_path, 1, INDEX_LIMIT)
        if current != expected:
            fail("index_baseline_mismatch")
        try:
            os.replace(lock_path, index_path)
        except OSError:
            fail("index_install_failed")
        lock_path = ""
        _fsync_directory(os.path.dirname(index_path))
    except FileExistsError:
        fail("index_locked")
    except ContractFailure:
        raise
    except OSError:
        fail("index_install_failed")
    finally:
        if descriptor >= 0:
            _close_temporary_descriptor(descriptor)
        if lock_path:
            _cleanup_temporary_paths(lock_path)


def _restore_index_baseline(
    index_path: str,
    candidate: bytes,
    baseline: bytes,
    mode: int,
) -> None:
    try:
        _install_index_candidate(index_path, candidate, baseline, mode)
        restored, _identity = _capture_regular(index_path, 1, INDEX_LIMIT)
    except ContractFailure:
        fail("standalone_recovery_failed")
    if restored != baseline:
        fail("standalone_recovery_failed")


def _cas_update_head(
    working_dir: str, new_sha: str, expected_old_sha: str, reason: str
) -> bool:
    result = _git_io(
        working_dir,
        "update-ref",
        "-m",
        reason,
        "HEAD",
        new_sha,
        expected_old_sha,
    )
    return result.returncode == 0


def _run_commit_hook(
    working_dir: str,
    hook_name: str,
    hook_arguments: tuple[str, ...],
    environment: dict[str, str],
) -> None:
    result = _git_io(
        working_dir,
        "hook",
        "run",
        "--ignore-missing",
        hook_name,
        "--",
        *hook_arguments,
        extra_env=environment,
    )
    if result.returncode != 0:
        fail("commit_hook_failed")


def _validate_standalone_commit_object(
    authority: dict[str, Any],
    snapshot: dict[str, Any],
    disposition: dict[str, Any],
    parent_sha: str,
    commit_sha: str,
    tree_sha: str,
) -> None:
    applied_paths = _validate_disposition(disposition, authority)
    parents = _git(
        authority["working_dir"], "rev-list", "--parents", "-n", "1", commit_sha
    )
    tree = _git(
        authority["working_dir"], "rev-parse", "--verify", f"{commit_sha}^{{tree}}"
    )
    if parents.returncode != 0 or tree.returncode != 0:
        fail("commit_state_unreadable")
    try:
        parent_fields = parents.stdout.decode("ascii").strip().split()
        committed_tree = tree.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("commit_state_unreadable")
    expected_message_sha256 = hashlib.sha256(
        STANDALONE_COMMIT_MESSAGE.encode("utf-8")
    ).hexdigest()
    if (
        parent_sha != snapshot["head_sha"]
        or parent_fields != [commit_sha, parent_sha]
        or committed_tree != tree_sha
        or _commit_message_sha256(authority["working_dir"], commit_sha)
        != expected_message_sha256
    ):
        fail("commit_object_invalid")
    if sorted(_committed_modified_paths(authority["working_dir"], parent_sha, commit_sha)) != sorted(applied_paths):
        fail("committed_path_mismatch")


TRANSACTION_KEYS = {
    "schema_version",
    "authority_sha256",
    "disposition_sha256",
    "applied_content_sha256",
    "parent_sha",
    "commit_sha",
    "tree_sha",
    "index_path",
    "index_mode",
    "baseline_index_sha256",
    "candidate_index_sha256",
    "backup_path",
    "backup_sha256",
    "state",
}


def _fsync_directory(path: str) -> None:
    if os.name == "nt":
        return
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        os.fsync(descriptor)
    except OSError:
        fail("transaction_sync_failed")
    finally:
        if descriptor >= 0:
            _close_temporary_descriptor(descriptor)


def _publish_transaction_file_record(
    path: str, payload: bytes, limit: int
) -> tuple[str, ArtifactIdentity]:
    if not payload or len(payload) > limit or os.path.lexists(path):
        fail("transaction_publication_failed")
    candidate = ""
    published = False
    completed = False
    identity: ArtifactIdentity | None = None
    try:
        candidate, identity, digest = secure_publish_captured(path, payload)
        if os.path.lexists(path):
            fail("transaction_publication_failed")
        os.link(candidate, path, follow_symlinks=False)
        published = True
        os.unlink(candidate)
        candidate = ""
        current = os.lstat(path)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or (current.st_dev, current.st_ino) != (identity.device, identity.inode)
        ):
            fail("transaction_publication_failed")
        capture_expected(path, digest, 1, limit)
        _fsync_directory(os.path.dirname(path))
        completed = True
        if identity is None:
            fail("transaction_publication_failed")
        return digest, identity
    except ContractFailure:
        raise
    except (ManifestRejected, ManifestRuntimeError, OSError):
        fail("transaction_publication_failed")
    finally:
        if candidate:
            _cleanup_temporary_paths(candidate)
        if published and not completed:
            if identity is None:
                fail("transaction_cleanup_failed")
            _remove_published_artifact(
                path, identity, reason="transaction_cleanup_failed"
            )


def _publish_transaction_file(path: str, payload: bytes, limit: int) -> str:
    digest, _identity = _publish_transaction_file_record(path, payload, limit)
    return digest


def _cleanup_transaction_files(*paths: str) -> None:
    parents: set[str] = set()
    try:
        for path in paths:
            if not path or not os.path.lexists(path):
                continue
            entry = os.lstat(path)
            if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
                fail("transaction_cleanup_failed")
            os.unlink(path)
            parents.add(os.path.dirname(path))
        for parent in parents:
            _fsync_directory(parent)
    except ContractFailure:
        raise
    except OSError:
        fail("transaction_cleanup_failed")


def _transaction_paths(evidence_dir: str) -> tuple[str, str]:
    return (
        os.path.join(evidence_dir, "standalone-commit-transaction.json"),
        os.path.join(evidence_dir, "standalone-index-backup.bin"),
    )


def _publish_standalone_transaction(
    *,
    evidence_dir: str,
    authority_sha256: str,
    disposition_sha256: str,
    applied_content_sha256: str,
    parent_sha: str,
    commit_sha: str,
    tree_sha: str,
    index_path: str,
    index_mode: int,
    baseline_index: bytes,
    candidate_index: bytes,
) -> tuple[str, str, dict[str, Any]]:
    journal_path, backup_path = _transaction_paths(evidence_dir)
    baseline_digest = hashlib.sha256(baseline_index).hexdigest()
    candidate_digest = hashlib.sha256(candidate_index).hexdigest()
    backup_digest = _publish_transaction_file(
        backup_path, baseline_index, INDEX_LIMIT
    )
    if backup_digest != baseline_digest:
        fail("transaction_publication_failed")
    journal = {
        "schema_version": 1,
        "authority_sha256": authority_sha256,
        "disposition_sha256": disposition_sha256,
        "applied_content_sha256": applied_content_sha256,
        "parent_sha": parent_sha,
        "commit_sha": commit_sha,
        "tree_sha": tree_sha,
        "index_path": index_path,
        "index_mode": stat.S_IMODE(index_mode),
        "baseline_index_sha256": baseline_digest,
        "candidate_index_sha256": candidate_digest,
        "backup_path": backup_path,
        "backup_sha256": backup_digest,
        "state": "prepared",
    }
    try:
        _publish_transaction_file(
            journal_path, _canonical_json(journal) + b"\n", AUTHORITY_LIMIT
        )
    except ContractFailure:
        _cleanup_transaction_files(backup_path)
        raise
    return journal_path, backup_path, journal


def _reconcile_standalone_transaction(
    *,
    authority: dict[str, Any],
    snapshot: dict[str, Any],
    disposition: dict[str, Any],
    authority_sha256: str,
    disposition_sha256: str,
    applied_content_sha256: str,
    index_path: str,
) -> dict[str, Any] | None:
    journal_path, expected_backup_path = _transaction_paths(snapshot["evidence_dir"])
    journal_exists = os.path.lexists(journal_path)
    backup_exists = os.path.lexists(expected_backup_path)
    current_index, current_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
    current_head, _current_tree = _head_identity(authority["working_dir"])
    if not journal_exists:
        if not backup_exists:
            return None
        backup, _backup_identity = _capture_regular(
            expected_backup_path, 1, INDEX_LIMIT
        )
        if current_head != snapshot["head_sha"] or current_index != backup:
            fail("standalone_recovery_ambiguous")
        _cleanup_transaction_files(expected_backup_path)
        return None
    journal_payload, _journal_identity = _capture_regular(
        journal_path, 1, AUTHORITY_LIMIT
    )
    journal = _parse_json(journal_payload, "transaction_journal_invalid")
    if (
        not isinstance(journal, dict)
        or set(journal) != TRANSACTION_KEYS
        or _canonical_json(journal) + b"\n" != journal_payload
        or journal.get("schema_version") != 1
        or journal.get("state") != "prepared"
        or journal.get("authority_sha256") != authority_sha256
        or journal.get("disposition_sha256") != disposition_sha256
        or journal.get("applied_content_sha256") != applied_content_sha256
        or journal.get("parent_sha") != snapshot["head_sha"]
        or journal.get("index_path") != index_path
        or journal.get("backup_path") != expected_backup_path
        or type(journal.get("index_mode")) is not int
        or journal["index_mode"] < 0
        or journal["index_mode"] > 0o777
        or any(
            not isinstance(journal.get(key), str)
            or SHA256.fullmatch(journal[key]) is None
            for key in (
                "authority_sha256",
                "disposition_sha256",
                "applied_content_sha256",
                "baseline_index_sha256",
                "candidate_index_sha256",
                "backup_sha256",
            )
        )
        or any(
            not isinstance(journal.get(key), str)
            or SHA1.fullmatch(journal[key]) is None
            for key in ("parent_sha", "commit_sha", "tree_sha")
        )
    ):
        fail("transaction_journal_invalid")
    _validate_standalone_commit_object(
        authority,
        snapshot,
        disposition,
        journal["parent_sha"],
        journal["commit_sha"],
        journal["tree_sha"],
    )
    current_digest = hashlib.sha256(current_index).hexdigest()
    baseline_digest = journal["baseline_index_sha256"]
    candidate_digest = journal["candidate_index_sha256"]
    backup: bytes | None = None
    if backup_exists:
        backup = capture_expected(
            expected_backup_path, journal["backup_sha256"], 1, INDEX_LIMIT
        )
        if hashlib.sha256(backup).hexdigest() != baseline_digest:
            fail("transaction_journal_invalid")
    if current_head == journal["parent_sha"] and current_digest == baseline_digest:
        _cleanup_transaction_files(expected_backup_path, journal_path)
        return None
    if current_head == journal["parent_sha"] and current_digest == candidate_digest:
        if backup is None:
            fail("standalone_recovery_ambiguous")
        _restore_index_baseline(
            index_path, current_index, backup, current_identity.mode
        )
        _cleanup_transaction_files(expected_backup_path, journal_path)
        return None
    if current_head == journal["commit_sha"] and current_digest == candidate_digest:
        receipt = _validate_standalone_commit_state(
            authority,
            snapshot,
            disposition,
            journal["parent_sha"],
            journal["commit_sha"],
        )
        receipt["disposition_sha256"] = disposition_sha256
        _cleanup_transaction_files(expected_backup_path, journal_path)
        return receipt
    fail("standalone_recovery_ambiguous")


def _committed_modified_paths(
    working_dir: str, parent_sha: str, commit_sha: str
) -> tuple[str, ...]:
    result = _git(
        working_dir,
        "diff",
        "--name-status",
        "-z",
        "--no-renames",
        f"{parent_sha}..{commit_sha}",
        "--",
    )
    if result.returncode != 0:
        fail("commit_state_unreadable")
    values = _parse_name_status(result.stdout, "committed_path_invalid")
    if any(status_value != "M" for status_value in values.values()):
        fail("committed_change_invalid")
    return tuple(values)


def _validate_standalone_commit_state(
    authority: dict[str, Any],
    snapshot: dict[str, Any],
    disposition: dict[str, Any],
    parent_sha: str,
    commit_sha: str,
) -> dict[str, Any]:
    applied_paths = _validate_disposition(disposition, authority)
    if not applied_paths:
        fail("standalone_applied_required")
    current_sha, current_tree = _head_identity(authority["working_dir"])
    parents = _git(
        authority["working_dir"], "rev-list", "--parents", "-n", "1", commit_sha
    )
    if parents.returncode != 0:
        fail("commit_state_unreadable")
    try:
        parent_fields = parents.stdout.decode("ascii").strip().split()
    except UnicodeError:
        fail("commit_state_unreadable")
    if (
        parent_sha != snapshot["head_sha"]
        or current_sha != commit_sha
        or parent_fields != [commit_sha, parent_sha]
    ):
        fail("commit_parent_mismatch")
    committed_paths = _committed_modified_paths(
        authority["working_dir"], parent_sha, commit_sha
    )
    if sorted(committed_paths) != sorted(applied_paths):
        fail("committed_path_mismatch")
    expected_message_sha256 = hashlib.sha256(
        STANDALONE_COMMIT_MESSAGE.encode("utf-8")
    ).hexdigest()
    if (
        _commit_message_sha256(authority["working_dir"], commit_sha)
        != expected_message_sha256
    ):
        fail("commit_message_mismatch")
    current = _capture_repo_state(
        authority["working_dir"], snapshot["evidence_dir"]
    )
    if current["untracked"] != snapshot["untracked"]:
        fail("standalone_untracked_mutated")
    applied = set(applied_paths)
    baseline_rows = {row["path"]: row for row in snapshot["tracked"]}
    current_rows = {row["path"]: row for row in current["tracked"]}
    if set(current_rows) != set(baseline_rows) - applied:
        fail("standalone_postcommit_path_mismatch")
    for path, row in current_rows.items():
        if row != baseline_rows[path]:
            fail("standalone_nonapplied_mutated")
    tree = _git(
        authority["working_dir"], "rev-parse", "--verify", f"{commit_sha}^{{tree}}"
    )
    if tree.returncode != 0:
        fail("commit_state_unreadable")
    try:
        commit_tree = tree.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("commit_state_unreadable")
    if commit_tree != current_tree:
        fail("commit_tree_mismatch")
    return {
        "status": "commit_validated",
        "phase": "phase2",
        "commit_type": "refactor",
        "parent_sha": parent_sha,
        "commit_sha": commit_sha,
        "tree_sha": commit_tree,
        "message_sha256": expected_message_sha256,
    }


def commit_standalone(
    *,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    applied_content_path: str,
    applied_content_sha256: str,
    working_dir: str,
) -> dict[str, Any]:
    authority = _load_authority(
        _absolute_input(authority_path, "authority_path_invalid"), authority_sha256
    )
    if authority["edge_id"] != "simplify.fix.phase2":
        fail("standalone_authority_required")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
    ):
        fail("validation_authority_mismatch")
    snapshot = _recapture_sources(authority)
    if snapshot is None:
        fail("standalone_authority_required")
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    if not applied_paths:
        fail("standalone_applied_required")
    content_plan = _load_applied_content_plan(
        applied_content_path,
        applied_content_sha256,
        authority,
        authority_sha256,
        disposition_sha256,
        applied_paths,
    )
    index_path = _git_index_path(canonical_working)
    if index_path != snapshot["index_path"]:
        fail("snapshot_index_mismatch")
    baseline_index = capture_expected(
        snapshot["index_backup_path"],
        snapshot["index_sha256"],
        snapshot["index_size"],
        INDEX_LIMIT,
    )
    recovered = _reconcile_standalone_transaction(
        authority=authority,
        snapshot=snapshot,
        disposition=disposition,
        authority_sha256=authority_sha256,
        disposition_sha256=disposition_sha256,
        applied_content_sha256=applied_content_sha256,
        index_path=index_path,
    )
    if recovered is not None:
        return recovered
    current = _require_standalone_edit_state(authority, snapshot, applied_paths)
    _require_applied_content_current(current, content_plan)
    current_rows = {row["path"]: row for row in current["tracked"]}
    final_entries = {
        path: {
            "mode": current_rows[path]["worktree"]["git_mode"],
            "oid": current_rows[path]["worktree"]["git_oid"],
        }
        for path in applied_paths
    }
    parent_sha = snapshot["head_sha"]
    current_index, baseline_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
    if (
        current_index != baseline_index
        or stat.S_IMODE(baseline_identity.mode) != snapshot["index_mode"]
    ):
        fail("index_baseline_mismatch")
    temporary_index = ""
    temporary_descriptor = -1
    message_path = ""
    message_descriptor = -1
    candidate_index = b""
    head_changed = False
    journal_path = ""
    backup_path = ""
    try:
        for row in content_plan["applied"]:
            _materialize_authenticated_blob(canonical_working, row)
        temporary_descriptor, temporary_index = tempfile.mkstemp(
            prefix=".standalone-index-", dir=snapshot["evidence_dir"]
        )
        temporary_payload = _build_tree_index_candidate(
            canonical_working, parent_sha, final_entries
        )
        if os.name != "nt":
            os.fchmod(temporary_descriptor, 0o600)
        _write_descriptor(temporary_descriptor, temporary_payload)
        _close_temporary_descriptor(temporary_descriptor)
        temporary_descriptor = -1
        observed_temporary, temporary_identity = _capture_regular(
            temporary_index, len(temporary_payload), len(temporary_payload)
        )
        if observed_temporary != temporary_payload:
            fail("temporary_index_failed")
        expected_tree_sha = _publish_index_tree_sha(
            canonical_working,
            temporary_index,
            temporary_payload,
            temporary_identity,
        )

        message_descriptor, message_path = tempfile.mkstemp(
            prefix=".standalone-message-", dir=snapshot["evidence_dir"]
        )
        if os.name != "nt":
            os.fchmod(message_descriptor, 0o600)
        message_payload = STANDALONE_COMMIT_MESSAGE.encode("utf-8") + b"\n"
        _write_descriptor(message_descriptor, message_payload)
        _close_temporary_descriptor(message_descriptor)
        message_descriptor = -1
        hook_environment = {
            "GIT_INDEX_FILE": temporary_index,
            "GIT_EDITOR": ":",
        }
        hooks = (
            ("pre-commit", ()),
            ("prepare-commit-msg", (message_path, "message")),
            ("commit-msg", (message_path,)),
        )
        for hook_name, hook_arguments in hooks:
            _run_commit_hook(
                canonical_working, hook_name, hook_arguments, hook_environment
            )
            if _index_tree_sha(
                canonical_working, extra_env=hook_environment
            ) != expected_tree_sha:
                fail("commit_hook_tree_mutated")
            observed_message, _message_identity = _capture_regular(
                message_path, 1, 65_536
            )
            if observed_message != message_payload:
                fail("commit_hook_message_mutated")
        current = _require_standalone_edit_state(
            authority, snapshot, applied_paths
        )
        _require_applied_content_current(current, content_plan)
        observed_head, _observed_tree = _head_identity(canonical_working)
        if observed_head != parent_sha:
            fail("standalone_parent_moved")
        observed_index, observed_identity = _capture_regular(
            index_path, 1, INDEX_LIMIT
        )
        if observed_index != baseline_index:
            fail("index_baseline_mismatch")
        baseline_identity = observed_identity

        commit = _git_io(
            canonical_working,
            "commit-tree",
            expected_tree_sha,
            "-p",
            parent_sha,
            payload=message_payload,
        )
        if commit.returncode != 0:
            fail("commit_object_failed")
        try:
            commit_sha = commit.stdout.decode("ascii").strip()
        except UnicodeError:
            fail("commit_object_failed")
        if SHA1.fullmatch(commit_sha) is None:
            fail("commit_object_failed")
        _validate_standalone_commit_object(
            authority,
            snapshot,
            disposition,
            parent_sha,
            commit_sha,
            expected_tree_sha,
        )
        candidate_index = _build_index_candidate(
            canonical_working,
            baseline_index,
            baseline_identity.mode,
            final_entries,
        )
        journal_path, backup_path, _journal = _publish_standalone_transaction(
            evidence_dir=snapshot["evidence_dir"],
            authority_sha256=authority_sha256,
            disposition_sha256=disposition_sha256,
            applied_content_sha256=applied_content_sha256,
            parent_sha=parent_sha,
            commit_sha=commit_sha,
            tree_sha=expected_tree_sha,
            index_path=index_path,
            index_mode=baseline_identity.mode,
            baseline_index=baseline_index,
            candidate_index=candidate_index,
        )
        _install_index_candidate(
            index_path,
            baseline_index,
            candidate_index,
            baseline_identity.mode,
        )
        if not _cas_update_head(
            canonical_working,
            commit_sha,
            parent_sha,
            "commit: authenticated standalone refactor",
        ):
            _restore_index_baseline(
                index_path,
                candidate_index,
                baseline_index,
                baseline_identity.mode,
            )
            _cleanup_transaction_files(backup_path, journal_path)
            backup_path = ""
            journal_path = ""
            fail("commit_ref_cas_failed")
        head_changed = True
        receipt = _validate_standalone_commit_state(
            authority, snapshot, disposition, parent_sha, commit_sha
        )
        receipt["disposition_sha256"] = disposition_sha256
        _cleanup_transaction_files(backup_path, journal_path)
        backup_path = ""
        journal_path = ""
        return receipt
    except ContractFailure:
        if head_changed:
            if not _cas_update_head(
                canonical_working,
                parent_sha,
                commit_sha,
                "reset: rollback failed standalone refactor",
            ):
                fail("standalone_recovery_failed")
            head_changed = False
        try:
            observed_index, _observed_identity = _capture_regular(
                index_path, 1, INDEX_LIMIT
            )
            if observed_index != baseline_index:
                _restore_index_baseline(
                    index_path,
                    observed_index,
                    baseline_index,
                    baseline_identity.mode,
                )
        except ContractFailure:
            fail("standalone_recovery_failed")
        if journal_path or backup_path:
            _cleanup_transaction_files(backup_path, journal_path)
        raise
    except BaseException:
        if not journal_path and not backup_path and not head_changed:
            try:
                observed_index, _observed_identity = _capture_regular(
                    index_path, 1, INDEX_LIMIT
                )
                if observed_index != baseline_index:
                    _restore_index_baseline(
                        index_path,
                        observed_index,
                        baseline_index,
                        baseline_identity.mode,
                    )
            except ContractFailure:
                fail("standalone_recovery_failed")
        raise
    finally:
        if temporary_descriptor >= 0:
            _close_temporary_descriptor(temporary_descriptor)
        if message_descriptor >= 0:
            _close_temporary_descriptor(message_descriptor)
        _cleanup_temporary_paths(*(
            temporary_index,
            temporary_index + ".lock" if temporary_index else "",
            message_path,
        ))


def _review_transaction_paths(authority: dict[str, Any]) -> tuple[str, str]:
    evidence_dir = os.path.dirname(authority["findings_path"])
    authority_name = os.path.basename(authority["authority_path"])
    suffix = authority_name.removeprefix("code-fixer-authority-").removesuffix(
        ".json"
    )
    if re.fullmatch(r"phase[12](?:-iter[1-9][0-9]{0,8})?", suffix) is None:
        fail("authority_path_invalid")
    return (
        os.path.join(evidence_dir, f"review-commit-transaction-{suffix}.json"),
        os.path.join(evidence_dir, f"review-index-backup-{suffix}.bin"),
    )


def _publish_review_transaction(
    *,
    authority: dict[str, Any],
    authority_sha256: str,
    disposition_sha256: str,
    applied_content_sha256: str,
    parent_sha: str,
    commit_sha: str,
    tree_sha: str,
    index_path: str,
    index_mode: int,
    baseline_index: bytes,
    candidate_index: bytes,
) -> tuple[str, str]:
    journal_path, backup_path = _review_transaction_paths(authority)
    baseline_digest = hashlib.sha256(baseline_index).hexdigest()
    candidate_digest = hashlib.sha256(candidate_index).hexdigest()
    backup_digest = _publish_transaction_file(
        backup_path, baseline_index, INDEX_LIMIT
    )
    if backup_digest != baseline_digest:
        fail("transaction_publication_failed")
    journal = {
        "schema_version": 1,
        "authority_sha256": authority_sha256,
        "disposition_sha256": disposition_sha256,
        "applied_content_sha256": applied_content_sha256,
        "parent_sha": parent_sha,
        "commit_sha": commit_sha,
        "tree_sha": tree_sha,
        "index_path": index_path,
        "index_mode": stat.S_IMODE(index_mode),
        "baseline_index_sha256": baseline_digest,
        "candidate_index_sha256": candidate_digest,
        "backup_path": backup_path,
        "backup_sha256": backup_digest,
        "state": "prepared",
    }
    try:
        _publish_transaction_file(
            journal_path, _canonical_json(journal) + b"\n", AUTHORITY_LIMIT
        )
    except ContractFailure:
        _cleanup_transaction_files(backup_path)
        raise
    return journal_path, backup_path


def _validate_review_commit_object(
    authority: dict[str, Any],
    disposition: dict[str, Any],
    content_plan: dict[str, Any],
    parent_sha: str,
    commit_sha: str,
    tree_sha: str,
) -> None:
    applied_paths = _validate_disposition(disposition, authority)
    parents = _git(
        authority["working_dir"], "rev-list", "--parents", "-n", "1", commit_sha
    )
    tree = _git(
        authority["working_dir"], "rev-parse", "--verify", f"{commit_sha}^{{tree}}"
    )
    if parents.returncode != 0 or tree.returncode != 0:
        fail("commit_state_unreadable")
    try:
        parent_fields = parents.stdout.decode("ascii").strip().split()
        committed_tree = tree.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("commit_state_unreadable")
    message = REVIEW_COMMIT_MESSAGES[authority["phase"]]
    if (
        parent_sha != authority["parent_sha"]
        or parent_fields != [commit_sha, parent_sha]
        or committed_tree != tree_sha
        or _commit_message_sha256(authority["working_dir"], commit_sha)
        != hashlib.sha256(message.encode("utf-8")).hexdigest()
        or sorted(
            _committed_modified_paths(
                authority["working_dir"], parent_sha, commit_sha
            )
        )
        != sorted(applied_paths)
    ):
        fail("commit_object_invalid")
    for row in content_plan["applied"]:
        if _tree_entry(authority["working_dir"], commit_sha, row["path"]) != {
            "mode": row["git_mode"],
            "oid": row["git_oid"],
        }:
            fail("applied_content_commit_mismatch")


def _validate_review_commit_state(
    authority: dict[str, Any],
    disposition: dict[str, Any],
    content_plan: dict[str, Any],
    parent_sha: str,
    commit_sha: str,
    tree_sha: str,
) -> dict[str, Any]:
    _validate_review_commit_object(
        authority, disposition, content_plan, parent_sha, commit_sha, tree_sha
    )
    current_sha, current_tree = _head_identity(authority["working_dir"])
    if current_sha != commit_sha or current_tree != tree_sha:
        fail("commit_head_mismatch")
    if _index_tree_sha(authority["working_dir"]) != tree_sha:
        fail("commit_index_mismatch")
    current = _capture_repo_state(
        authority["working_dir"], os.path.dirname(authority["findings_path"])
    )
    if current["tracked"] or current["untracked"] != authority["untracked"]:
        fail("review_postcommit_state_mismatch")
    message_digest = hashlib.sha256(
        REVIEW_COMMIT_MESSAGES[authority["phase"]].encode("utf-8")
    ).hexdigest()
    return {
        "status": "commit_validated",
        "phase": authority["phase"],
        "commit_type": authority["commit_type"],
        "parent_sha": parent_sha,
        "commit_sha": commit_sha,
        "tree_sha": tree_sha,
        "message_sha256": message_digest,
    }


def _reconcile_review_transaction(
    *,
    authority: dict[str, Any],
    disposition: dict[str, Any],
    content_plan: dict[str, Any],
    authority_sha256: str,
    disposition_sha256: str,
    applied_content_sha256: str,
    index_path: str,
) -> dict[str, Any] | None:
    journal_path, backup_path = _review_transaction_paths(authority)
    journal_exists = os.path.lexists(journal_path)
    backup_exists = os.path.lexists(backup_path)
    current_index, current_identity = _capture_regular(index_path, 1, INDEX_LIMIT)
    current_head, _current_tree = _head_identity(authority["working_dir"])
    if not journal_exists:
        if not backup_exists:
            return None
        backup, _backup_identity = _capture_regular(backup_path, 1, INDEX_LIMIT)
        if (
            current_head != authority["parent_sha"]
            or current_index != backup
            or hashlib.sha256(backup).hexdigest() != authority["index_sha256"]
        ):
            fail("review_recovery_ambiguous")
        _cleanup_transaction_files(backup_path)
        return None
    journal_payload, _journal_identity = _capture_regular(
        journal_path, 1, AUTHORITY_LIMIT
    )
    journal = _parse_json(journal_payload, "transaction_journal_invalid")
    if (
        not isinstance(journal, dict)
        or set(journal) != TRANSACTION_KEYS
        or _canonical_json(journal) + b"\n" != journal_payload
        or journal.get("schema_version") != 1
        or journal.get("state") != "prepared"
        or journal.get("authority_sha256") != authority_sha256
        or journal.get("disposition_sha256") != disposition_sha256
        or journal.get("applied_content_sha256") != applied_content_sha256
        or journal.get("parent_sha") != authority["parent_sha"]
        or journal.get("index_path") != index_path
        or journal.get("backup_path") != backup_path
        or type(journal.get("index_mode")) is not int
        or journal["index_mode"] < 0
        or journal["index_mode"] > 0o7777
        or any(
            not isinstance(journal.get(key), str)
            or SHA256.fullmatch(journal[key]) is None
            for key in (
                "authority_sha256",
                "disposition_sha256",
                "applied_content_sha256",
                "baseline_index_sha256",
                "candidate_index_sha256",
                "backup_sha256",
            )
        )
        or any(
            not isinstance(journal.get(key), str)
            or SHA1.fullmatch(journal[key]) is None
            for key in ("parent_sha", "commit_sha", "tree_sha")
        )
    ):
        fail("transaction_journal_invalid")
    _validate_review_commit_object(
        authority,
        disposition,
        content_plan,
        journal["parent_sha"],
        journal["commit_sha"],
        journal["tree_sha"],
    )
    current_digest = hashlib.sha256(current_index).hexdigest()
    baseline_digest = journal["baseline_index_sha256"]
    candidate_digest = journal["candidate_index_sha256"]
    backup: bytes | None = None
    if backup_exists:
        backup = capture_expected(
            backup_path, journal["backup_sha256"], 1, INDEX_LIMIT
        )
        if (
            hashlib.sha256(backup).hexdigest() != baseline_digest
            or baseline_digest != authority["index_sha256"]
        ):
            fail("transaction_journal_invalid")
    if current_head == journal["parent_sha"] and current_digest == baseline_digest:
        _cleanup_transaction_files(backup_path, journal_path)
        return None
    if current_head == journal["parent_sha"] and current_digest == candidate_digest:
        if backup is None:
            fail("review_recovery_ambiguous")
        _restore_index_baseline(
            index_path, current_index, backup, current_identity.mode
        )
        _cleanup_transaction_files(backup_path, journal_path)
        return None
    if current_head == journal["commit_sha"] and current_digest == candidate_digest:
        receipt = _validate_review_commit_state(
            authority,
            disposition,
            content_plan,
            journal["parent_sha"],
            journal["commit_sha"],
            journal["tree_sha"],
        )
        receipt["disposition_sha256"] = disposition_sha256
        _cleanup_transaction_files(backup_path, journal_path)
        return receipt
    fail("review_recovery_ambiguous")


def commit_review(
    *,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    applied_content_path: str,
    applied_content_sha256: str,
    working_dir: str,
) -> dict[str, Any]:
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    if authority["edge_id"] == "simplify.fix.phase2":
        fail("review_authority_required")
    authority["authority_path"] = canonical_authority
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
    ):
        fail("validation_authority_mismatch")
    _recapture_sources(authority, expected_range_head=authority["parent_sha"])
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    if not applied_paths:
        fail("review_applied_required")
    content_plan = _load_applied_content_plan(
        applied_content_path,
        applied_content_sha256,
        authority,
        authority_sha256,
        disposition_sha256,
        applied_paths,
    )
    index_path = _git_index_path(canonical_working)
    if index_path != authority["index_path"]:
        fail("review_index_mismatch")
    recovered = _reconcile_review_transaction(
        authority=authority,
        disposition=disposition,
        content_plan=content_plan,
        authority_sha256=authority_sha256,
        disposition_sha256=disposition_sha256,
        applied_content_sha256=applied_content_sha256,
        index_path=index_path,
    )
    if recovered is not None:
        return recovered
    current = _require_review_edit_state(authority, applied_paths)
    _require_applied_content_current(current, content_plan)
    baseline_index, baseline_identity = _capture_regular(
        index_path, authority["index_size"], authority["index_size"]
    )
    if hashlib.sha256(baseline_index).hexdigest() != authority["index_sha256"]:
        fail("review_index_mismatch")
    current_rows = {row["path"]: row for row in current["tracked"]}
    final_entries = {
        path: {
            "mode": current_rows[path]["worktree"]["git_mode"],
            "oid": current_rows[path]["worktree"]["git_oid"],
        }
        for path in applied_paths
    }
    evidence_dir = os.path.dirname(authority["findings_path"])
    temporary_index = ""
    temporary_descriptor = -1
    message_path = ""
    message_descriptor = -1
    candidate_index = b""
    commit_sha = ""
    head_changed = False
    journal_path = ""
    backup_path = ""
    try:
        for row in content_plan["applied"]:
            _materialize_authenticated_blob(canonical_working, row)
        temporary_descriptor, temporary_index = tempfile.mkstemp(
            prefix=".standalone-index-", dir=evidence_dir
        )
        temporary_payload = _build_tree_index_candidate(
            canonical_working, authority["parent_sha"], final_entries
        )
        if os.name != "nt":
            os.fchmod(temporary_descriptor, 0o600)
        _write_descriptor(temporary_descriptor, temporary_payload)
        _close_temporary_descriptor(temporary_descriptor)
        temporary_descriptor = -1
        observed_temporary, temporary_identity = _capture_regular(
            temporary_index, len(temporary_payload), len(temporary_payload)
        )
        if observed_temporary != temporary_payload:
            fail("temporary_index_failed")
        hook_environment = {"GIT_INDEX_FILE": temporary_index, "GIT_EDITOR": ":"}
        expected_tree_sha = _publish_index_tree_sha(
            canonical_working,
            temporary_index,
            temporary_payload,
            temporary_identity,
        )
        message_descriptor, message_path = tempfile.mkstemp(
            prefix=".standalone-message-", dir=evidence_dir
        )
        if os.name != "nt":
            os.fchmod(message_descriptor, 0o600)
        message_payload = (
            REVIEW_COMMIT_MESSAGES[authority["phase"]].encode("utf-8") + b"\n"
        )
        _write_descriptor(message_descriptor, message_payload)
        _close_temporary_descriptor(message_descriptor)
        message_descriptor = -1
        for hook_name, hook_arguments in (
            ("pre-commit", ()),
            ("prepare-commit-msg", (message_path, "message")),
            ("commit-msg", (message_path,)),
        ):
            _run_commit_hook(
                canonical_working, hook_name, hook_arguments, hook_environment
            )
            if (
                _index_tree_sha(canonical_working, extra_env=hook_environment)
                != expected_tree_sha
            ):
                fail("commit_hook_tree_mutated")
            observed_message, _message_identity = _capture_regular(
                message_path, 1, 65_536
            )
            if observed_message != message_payload:
                fail("commit_hook_message_mutated")
        _recapture_sources(authority, expected_range_head=authority["parent_sha"])
        current = _require_review_edit_state(authority, applied_paths)
        _require_applied_content_current(current, content_plan)
        observed_head, _observed_tree = _head_identity(canonical_working)
        if observed_head != authority["parent_sha"]:
            fail("review_parent_moved")
        observed_index, observed_identity = _capture_regular(
            index_path, authority["index_size"], authority["index_size"]
        )
        if observed_index != baseline_index:
            fail("review_index_mismatch")
        baseline_identity = observed_identity
        commit = _git_io(
            canonical_working,
            "commit-tree",
            expected_tree_sha,
            "-p",
            authority["parent_sha"],
            payload=message_payload,
        )
        if commit.returncode != 0:
            fail("commit_object_failed")
        try:
            commit_sha = commit.stdout.decode("ascii").strip()
        except UnicodeError:
            fail("commit_object_failed")
        if SHA1.fullmatch(commit_sha) is None:
            fail("commit_object_failed")
        _validate_review_commit_object(
            authority,
            disposition,
            content_plan,
            authority["parent_sha"],
            commit_sha,
            expected_tree_sha,
        )
        candidate_index = _build_index_candidate(
            canonical_working,
            baseline_index,
            baseline_identity.mode,
            final_entries,
        )
        journal_path, backup_path = _publish_review_transaction(
            authority=authority,
            authority_sha256=authority_sha256,
            disposition_sha256=disposition_sha256,
            applied_content_sha256=applied_content_sha256,
            parent_sha=authority["parent_sha"],
            commit_sha=commit_sha,
            tree_sha=expected_tree_sha,
            index_path=index_path,
            index_mode=baseline_identity.mode,
            baseline_index=baseline_index,
            candidate_index=candidate_index,
        )
        _install_index_candidate(
            index_path,
            baseline_index,
            candidate_index,
            baseline_identity.mode,
        )
        if not _cas_update_head(
            canonical_working,
            commit_sha,
            authority["parent_sha"],
            "commit: authenticated review fixes",
        ):
            _restore_index_baseline(
                index_path,
                candidate_index,
                baseline_index,
                baseline_identity.mode,
            )
            _cleanup_transaction_files(backup_path, journal_path)
            backup_path = ""
            journal_path = ""
            fail("commit_ref_cas_failed")
        head_changed = True
        receipt = _validate_review_commit_state(
            authority,
            disposition,
            content_plan,
            authority["parent_sha"],
            commit_sha,
            expected_tree_sha,
        )
        receipt["disposition_sha256"] = disposition_sha256
        _cleanup_transaction_files(backup_path, journal_path)
        backup_path = ""
        journal_path = ""
        return receipt
    except ContractFailure:
        if head_changed:
            if not _cas_update_head(
                canonical_working,
                authority["parent_sha"],
                commit_sha,
                "reset: rollback failed review commit",
            ):
                fail("review_recovery_failed")
            head_changed = False
        try:
            observed_index, _observed_identity = _capture_regular(
                index_path, 1, INDEX_LIMIT
            )
            if observed_index != baseline_index:
                _restore_index_baseline(
                    index_path,
                    observed_index,
                    baseline_index,
                    baseline_identity.mode,
                )
        except ContractFailure:
            fail("review_recovery_failed")
        if journal_path or backup_path:
            _cleanup_transaction_files(backup_path, journal_path)
        raise
    finally:
        if temporary_descriptor >= 0:
            _close_temporary_descriptor(temporary_descriptor)
        if message_descriptor >= 0:
            _close_temporary_descriptor(message_descriptor)
        _cleanup_temporary_paths(
            temporary_index,
            temporary_index + ".lock" if temporary_index else "",
            message_path,
        )


def validate_commit(
    *,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    working_dir: str,
    parent_sha: str,
    commit_sha: str,
    staged_tree_sha: str,
    expected_message_sha256: str,
) -> dict[str, Any]:
    for value in (parent_sha, commit_sha, staged_tree_sha):
        if not isinstance(value, str) or SHA1.fullmatch(value) is None:
            fail("commit_identity_invalid")
    if not isinstance(expected_message_sha256, str) or SHA256.fullmatch(
        expected_message_sha256
    ) is None:
        fail("commit_message_digest_invalid")
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
    ):
        fail("validation_authority_mismatch")
    _require_repository(canonical_working)
    current = _git(canonical_working, "rev-parse", "--verify", "HEAD")
    parents = _git(canonical_working, "rev-list", "--parents", "-n", "1", commit_sha)
    tree = _git(canonical_working, "rev-parse", "--verify", f"{commit_sha}^{{tree}}")
    if current.returncode != 0 or parents.returncode != 0 or tree.returncode != 0:
        fail("commit_state_unreadable")
    try:
        current_sha = current.stdout.decode("ascii").strip()
        parent_fields = parents.stdout.decode("ascii").strip().split()
        committed_tree_sha = tree.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("commit_state_unreadable")
    if current_sha != commit_sha:
        fail("commit_head_mismatch")
    if parent_fields != [commit_sha, parent_sha]:
        fail("commit_parent_mismatch")
    if committed_tree_sha != staged_tree_sha:
        fail("commit_tree_mismatch")
    committed_message_sha256 = _commit_message_sha256(
        canonical_working, commit_sha
    )
    if committed_message_sha256 != expected_message_sha256:
        fail("commit_message_mismatch")
    _recapture_sources(authority, expected_range_head=parent_sha)
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    committed_paths_result = _git(
        canonical_working,
        "diff",
        "--name-status",
        "-z",
        "--no-renames",
        f"{parent_sha}..{commit_sha}",
        "--",
    )
    if committed_paths_result.returncode != 0:
        fail("commit_state_unreadable")
    payload = committed_paths_result.stdout
    if payload and not payload.endswith(b"\x00"):
        fail("committed_path_invalid")
    fields = payload[:-1].split(b"\x00") if payload else []
    if len(fields) % 2 != 0:
        fail("committed_path_invalid")
    committed_paths: list[str] = []
    for index in range(0, len(fields), 2):
        status_raw, path_raw = fields[index : index + 2]
        if status_raw != b"M":
            fail("committed_change_invalid")
        decoded = _decode_git_paths(path_raw + b"\x00", "committed_path_invalid")
        if len(decoded) != 1:
            fail("committed_path_invalid")
        committed_paths.append(decoded[0])
    if len(committed_paths) != len(set(committed_paths)):
        fail("committed_path_invalid")
    if sorted(committed_paths) != sorted(applied_paths):
        fail("committed_path_mismatch")
    _require_clean_worktree(
        canonical_working, os.path.dirname(authority["findings_path"])
    )
    return {
        "status": "commit_validated",
        "phase": authority["phase"],
        "commit_type": authority["commit_type"],
        "disposition_sha256": disposition_sha256,
        "parent_sha": parent_sha,
        "commit_sha": commit_sha,
        "tree_sha": committed_tree_sha,
        "message_sha256": committed_message_sha256,
    }


LAUNCH_RECEIPT_KEYS = {
    "schema_version",
    "edge_id",
    "instance_id",
    "backend",
    "handle",
    "state",
    "result_file",
    "status_file",
}
LAUNCH_BINDING_KEYS = {
    "schema_version",
    "receipt_sha256",
    "edge_id",
    "instance_id",
    "backend",
    "handle",
    "launch_status_sha256",
    "process_identity",
    "lease_generation",
    "result_path",
    "status_path",
    "workspace_mode",
    "worktree",
    "branch",
}
# A Workflow-native child is awaited in-process, so three of the detached
# binding's members cannot exist and two more have nothing to describe:
#
#   process_identity / lease_generation / handle -- no pid, no process group,
#       no lease, no provider handle. Synthesising any of them would make the
#       binding look verified while proving nothing.
#   receipt_sha256 / launch_status_sha256 -- a Workflow() call issues no
#       dispatch receipt, and the status file does not exist yet at mint time.
#
# `run_nonce` replaces all five. The controller mints it before the Workflow
# call and the child echoes it back, which is the same binding property the
# detached triple provided: this status file belongs to THIS launch.
WORKFLOW_LAUNCH_BINDING_KEYS = {
    "schema_version",
    "edge_id",
    "instance_id",
    "backend",
    "run_nonce",
    "result_path",
    "status_path",
    "workspace_mode",
    "worktree",
    "branch",
}
# Every edge whose child the calling session's Workflow tool may dispatch as a
# BOUND child -- one that publishes a result file the controller must later
# prove. The three fixer edges arrived first; the Phase-1 and Phase-2
# contributor rosters join them because skills/review-fleet/workflow.js
# dispatches those two fanouts as bound children too, and an edge whose binding
# cannot be minted is an edge whose evidence cannot be proved.
#
# Derived from PHASE_CONTRIBUTORS rather than re-spelled, so the roster this
# binds and the roster post_review_write_aggregate_v2 re-validates can never
# drift apart. Widening it is a deliberate act: an edge listed here can carry a
# nonce-bound status file in place of the detached supervision triple.
# A fixer child additionally owes a disposition and an applied-content artifact.
# Named once so the two consumers below cannot drift: bind_workflow_launch mints
# for these, capture_bound_child REFUSES them.
WORKFLOW_FIXER_EDGE_IDS = frozenset(
    (
        "review_pr.fix.phase1",
        "review_pr.fix.phase2",
        "simplify.fix.phase2",
    )
)

# Reviewer- and lens-shaped children: one result, one status, nothing else.
WORKFLOW_REVIEWER_EDGE_IDS = frozenset(
    PHASE_CONTRIBUTORS["phase1"] + PHASE_CONTRIBUTORS["phase2"]
)

# Verifier-shaped children (#431): one result, one status, nothing else --
# structurally identical to the reviewer shape, which is why capture_bound_child
# accepts them. Its OWN frozenset rather than a member of
# WORKFLOW_REVIEWER_EDGE_IDS, because that set is DERIVED from
# PHASE_CONTRIBUTORS: it is the aggregate roster, and a verifier contributes to
# no aggregate. Folding it in there would silently make the verifier a
# contributor every _validate_aggregate call then demands a verdict from.
WORKFLOW_VERIFIER_EDGE_IDS = frozenset(("review_pr.verify.finding",))

WORKFLOW_BOUND_EDGE_IDS = (
    WORKFLOW_REVIEWER_EDGE_IDS | WORKFLOW_FIXER_EDGE_IDS | WORKFLOW_VERIFIER_EDGE_IDS
)

# The defer stage's own edge. Kept out of WORKFLOW_BOUND_EDGE_IDS on purpose:
# a persistence child carries an aggregate and a disposition pin, so it is never
# bindable through the plain (reviewer-shaped) workflow producer.
WORKFLOW_PERSISTENCE_EDGE_IDS = frozenset(("review_pr.defer.findings",))

# The exact members that make the two launch shapes mutually exclusive. Derived,
# never re-spelled: every loader below refuses a binding that carries any member
# of the OTHER shape, so a mis-declared backend can only be refused -- it can
# never be re-read as the shape it is not. Widening either base set therefore
# widens the exclusion automatically instead of silently opening a hole.
DETACHED_ONLY_BINDING_KEYS = frozenset(
    LAUNCH_BINDING_KEYS - WORKFLOW_LAUNCH_BINDING_KEYS
)
WORKFLOW_ONLY_BINDING_KEYS = frozenset(
    WORKFLOW_LAUNCH_BINDING_KEYS - LAUNCH_BINDING_KEYS
)

# The members a fixer/persistence binding adds on top of whichever launch base
# it sits on. Named once so the detached and workflow shapes cannot drift into
# owing different proofs: the ONLY difference between them is how the launch is
# identified, never what the child owes.
FIXER_BINDING_EXTRA_KEYS = frozenset(
    (
        "authority_path",
        "authority_sha256",
    )
)
PERSISTENCE_BINDING_EXTRA_KEYS = frozenset(
    (
        "aggregate_path",
        "aggregate_sha256",
        "disposition_path",
        "disposition_sha256",
        "expected_deferred_blockers",
        "require_clean",
    )
)
PERSISTENCE_BINDING_KEYS = LAUNCH_BINDING_KEYS | PERSISTENCE_BINDING_EXTRA_KEYS
FIXER_LAUNCH_BINDING_KEYS = LAUNCH_BINDING_KEYS | FIXER_BINDING_EXTRA_KEYS
WORKFLOW_PERSISTENCE_BINDING_KEYS = (
    WORKFLOW_LAUNCH_BINDING_KEYS | PERSISTENCE_BINDING_EXTRA_KEYS
)
WORKFLOW_FIXER_LAUNCH_BINDING_KEYS = (
    WORKFLOW_LAUNCH_BINDING_KEYS | FIXER_BINDING_EXTRA_KEYS
)

# The five review_pr.ci.* edges get their OWN binding producer and their OWN
# capture verb rather than joining WORKFLOW_BOUND_EDGE_IDS, because none of the
# three shipped shapes is the shape they owe. This is a fourth shape, not a
# widening, and the difference is load-bearing:
#
#   capture_bound_child freezes result + status and nothing else. That is the
#   COMPLETE debt of a reviewer, whose only authority is a diff artifact every
#   sibling reviewer read too and that the controller wrote itself. A CI child's
#   authority is a GitHub Actions log: bytes this run fetched once, that no
#   later reader can re-derive, and that the next push makes unreachable.
#   Freezing only the child's two outputs would prove it wrote something and
#   prove nothing about what it read. Adding a ci edge to
#   WORKFLOW_REVIEWER_EDGE_IDS would therefore not widen a verb -- it would
#   silently DROP a pin, and every downstream equality would still pass.
#
#   capture_review_terminal / capture_standalone_terminal freeze a disposition
#   and an applied-content plan on top. A CI fixer owes neither: its input is a
#   log line, not a schema-v2 findings row, so there is nothing to dispose of
#   per finding and no per-finding content plan to compare. Routing a ci edge
#   through _load_review_fixer_binding fails at the first _load_authority call,
#   and "making it pass" would mean minting an AUTHORITY_KEYS document with
#   fabricated finding_keys and target_paths -- a lie in the shape of a proof.
#
#   capture_persistence_terminal recounts deferred blockers from a schema-v2
#   Phase 2 aggregate. review_pr.ci.defer_refusal's aggregate is the one-row
#   ci-refused-synthetic envelope (commands/review-pr.md), which
#   count_phase2_deferred_blockers cannot parse -- so that verb refuses it
#   structurally, and correctly.
#
# What a CI child actually owes is: its two bound outputs, PLUS the exact bytes
# of the untrusted artifact it was pointed at, PLUS -- for the three mutating
# edges -- the git identity the controller pinned before dispatch (parent_sha,
# base_sha, lease_sha). Four obligations, four-shaped verb.
#
# capture_ci_terminal takes NO caller-supplied digest and compares none, for the
# same reason capture_bound_child takes none (see its docstring): a digest
# parameter is a slot an agent's arithmetic can occupy, and a verb that accepted
# one would still satisfy every equality downstream while proving that the
# controller and the agent agree rather than that the bytes are what the
# controller pinned.
# ---------------------------------------------------------------------------
# SCOPE OF THE PHASE 3 CI VERBS -- read this before the CI verbs below.
# ---------------------------------------------------------------------------
# Everything from here to the end of the Phase 3 block is the ENGINE: the
# producer, the capture verb and the judges for the five review_pr.ci.* edges,
# dispatched by skills/review-fleet/workflow.js's four ci-* stages. It is
# tested directly (tests/code-fixer-contract.test.sh drives real git
# repositories with real conflicts; tests/review-pr-workflow.test.sh section W
# executes every stage).
#
# It shipped UNCALLED in #383 half one: `commands/review-pr.md` still halted a
# red check at 6c.3 CLASSIFY with `ci_transport_unsupported`, and `--no-ci-fix`
# was the supported mode. HALF TWO RETIRED THAT GATE. Every caller fence named
# below (6c.4 ROUTE, 6c.4w.3, 6c.5 POST-FIX) now exists in
# `commands/review-pr.md`, and a red check reaches these verbs on a real run.
#
# So the obligations these comments describe are live contracts, not a
# specification for wiring still to come. Changing one changes what a
# user-facing /review-pr run does. The half-one/half-two split is preserved in
# the comments only where it explains WHY a verb enforces something its own
# caller could not have enforced at the time it was written.
WORKFLOW_CI_EDGE_IDS = frozenset(
    (
        "review_pr.ci.classify",
        "review_pr.ci.fix_code",
        "review_pr.ci.rebase",
        "review_pr.ci.defer_refusal",
        "review_pr.ci.resolve_conflict",
    )
)

# Read-only CI children: they consume the pinned artifact and write a report.
# Everything else mutates the caller's checkout and additionally owes the git
# identity the controller froze before dispatch.
CI_READ_EDGE_IDS = frozenset(
    ("review_pr.ci.classify", "review_pr.ci.defer_refusal")
)
CI_MUTATION_EDGE_IDS = frozenset(WORKFLOW_CI_EDGE_IDS - CI_READ_EDGE_IDS)

# Deliberately NOT the names authority_path / authority_sha256: those two carry
# the AUTHORITY_KEYS document shape, and _load_fixer_launch_binding would
# _load_authority() a CI authority and reject it. Distinct names make a CI
# binding structurally unreadable as a fixer binding and vice versa --
# _binding_base_keys' cross-shape discipline applied one level up.
CI_BINDING_EXTRA_KEYS = frozenset(("ci_authority_path", "ci_authority_sha256"))
WORKFLOW_CI_LAUNCH_BINDING_KEYS = (
    WORKFLOW_LAUNCH_BINDING_KEYS | CI_BINDING_EXTRA_KEYS
)

CHILD_STATUS_KEYS = {
    "issue",
    "tier",
    "backend",
    "state",
    "exit_code",
    "provider_exit_code",
    "pid",
    "log",
    "result",
    "worktree",
    "branch",
    "workspace_mode",
    "process_identity",
    "lease_generation",
    # Workflow-native children only. Mutually exclusive with the
    # pid/process_identity/lease_generation triple — see
    # _validate_bound_child_status, which enforces the exclusion in both
    # directions rather than merely permitting the key here.
    "run_nonce",
}


def bind_launch_receipt(
    *,
    receipt: bytes,
    edge_id: str,
    instance_id: str,
    result_path: str,
    status_path: str,
    working_dir: str,
) -> dict[str, Any]:
    if not isinstance(receipt, bytes) or not receipt or len(receipt) > 65_536:
        fail("launch_receipt_invalid")
    value = _parse_json(receipt, "launch_receipt_invalid")
    if (
        not isinstance(value, dict)
        or set(value) != LAUNCH_RECEIPT_KEYS
        or _canonical_json(value) != receipt
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("edge_id") != edge_id
        or value.get("instance_id") != instance_id
        or value.get("backend")
        # CONTRACT: dispatch-backend -auto
        not in {"background", "wezterm", "workflow"}
        or not isinstance(value.get("handle"), str)
        or not value["handle"]
        or value.get("state")
        # CONTRACT: run-terminal-status +running
        not in {"running", "completed", "failed", "timed_out", "cancelled"}
    ):
        fail("launch_receipt_invalid")
    canonical_result = _absolute_input(result_path, "result_path_invalid")
    canonical_status = _absolute_input(status_path, "status_path_invalid")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if (
        value.get("result_file") != canonical_result
        or value.get("status_file") != canonical_status
    ):
        fail("launch_receipt_path_mismatch")
    status_payload, _status_identity = _capture_regular(canonical_status, 1, 65_536)
    status_document = _parse_json(status_payload, "launch_status_invalid")
    if not isinstance(status_document, dict):
        fail("launch_status_invalid")
    status_handle = status_document.get("pid")
    if (
        set(status_document) - CHILD_STATUS_KEYS
        or status_document.get("backend") != value["backend"]
        or status_document.get("state") != value["state"]
        or status_document.get("state") not in {"running", "completed"}
        or type(status_handle) not in {int, str}
        or isinstance(status_handle, str)
        and not status_handle
        or value["handle"] not in {str(status_handle), f"pane:{status_handle}"}
        or not isinstance(status_document.get("process_identity"), str)
        or PROCESS_IDENTITY.fullmatch(status_document["process_identity"]) is None
        or not isinstance(status_document.get("lease_generation"), str)
        or LEASE_GENERATION.fullmatch(status_document["lease_generation"]) is None
    ):
        fail("launch_status_invalid")
    if status_document["state"] == "running":
        if status_document.get("exit_code") is not None:
            fail("launch_status_invalid")
    elif (
        type(status_document.get("exit_code")) is not int
        or status_document["exit_code"] != 0
    ):
        fail("launch_status_invalid")
    return {
        "schema_version": 1,
        "receipt_sha256": hashlib.sha256(receipt).hexdigest(),
        "edge_id": edge_id,
        "instance_id": instance_id,
        "backend": value["backend"],
        "handle": value["handle"],
        "launch_status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "process_identity": status_document["process_identity"],
        "lease_generation": status_document["lease_generation"],
        "result_path": canonical_result,
        "status_path": canonical_status,
        "workspace_mode": "caller",
        "worktree": canonical_working,
        "branch": "",
    }


def _binding_base_keys(value: Any, reason: str) -> frozenset[str]:
    """Pick the launch-binding base key set from the DECLARED backend.

    Every derived loader (fixer, persistence) used to rebuild the detached
    LAUNCH_BINDING_KEYS base unconditionally before delegating, which is why no
    workflow binding could reach the fix, simplify or defer captures at all.

    Dispatching on the DECLARED backend -- rather than on which members happen
    to be present -- is what keeps the choice honest: a binding that declares
    `workflow` and also carries the detached supervision triple is refused,
    never quietly re-read as a detached binding whose triple was never proved
    (and vice versa).

    The explicit cross-shape rejection below is defence in depth, not the sole
    barrier: each caller also compares the FULL key set for exact equality, and
    a mutation run confirmed that either check alone refuses today's smuggling
    inputs. It is kept because the equality check is the one a future edit is
    likely to relax when a third shape arrives -- with the equality relaxed to a
    subset test, this rejection is the only thing that still refuses a workflow
    binding carrying `process_identity`. It reads the two derived sets, so
    widening either base set widens the exclusion with it.
    """
    if not isinstance(value, dict):
        fail(reason)
    if value.get("backend") == "workflow":
        if DETACHED_ONLY_BINDING_KEYS & set(value):
            fail(reason)
        return frozenset(WORKFLOW_LAUNCH_BINDING_KEYS)
    if WORKFLOW_ONLY_BINDING_KEYS & set(value):
        fail(reason)
    return frozenset(LAUNCH_BINDING_KEYS)


def _mint_workflow_launch(
    *,
    edge_id: str,
    instance_id: str,
    run_nonce: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    allowed_edge_ids: frozenset[str],
    reason: str,
) -> dict[str, Any]:
    """Shared body of every workflow launch producer.

    The edge allowlist is a parameter, not a constant, because the three
    producers admit different rosters: reviewer/lens plus fixer edges for the
    plain producer, the fixer edges alone for the fixer producer, and the single
    defer edge for the persistence producer. Sharing the body keeps the nonce
    rule, the path canonicalisation and the emitted key set identical across all
    three, so no producer can mint a shape the loaders will not accept.
    """
    if (
        not isinstance(run_nonce, str)
        or re.fullmatch(r"[0-9a-f]{64}", run_nonce) is None
    ):
        fail(reason)
    if edge_id not in allowed_edge_ids:
        fail(reason)
    if not isinstance(instance_id, str) or not instance_id:
        fail(reason)
    canonical_result = _absolute_input(result_path, reason)
    canonical_status = _absolute_input(status_path, reason)
    canonical_working = _absolute_input(working_dir, reason)
    return {
        "schema_version": 1,
        "edge_id": edge_id,
        "instance_id": instance_id,
        "backend": "workflow",
        "run_nonce": run_nonce,
        "result_path": canonical_result,
        "status_path": canonical_status,
        "workspace_mode": "caller",
        "worktree": canonical_working,
        "branch": "",
    }


def bind_workflow_launch(
    *,
    edge_id: str,
    instance_id: str,
    run_nonce: str,
    result_path: str,
    status_path: str,
    working_dir: str,
) -> dict[str, Any]:
    """Mint the launch binding for a Workflow-native child.

    Deliberately NOT a variant of bind_launch_receipt. That function derives its
    binding from a dispatch receipt and a launch status file; a Workflow() call
    issues no receipt, and at mint time the status file does not exist yet --
    the controller mints the nonce BEFORE the call, which is the only moment the
    binding can be created without the child having had a chance to influence
    it. Deriving from a child-written artifact would let the child choose its
    own binding.

    The detached triple is not merely omitted here, it is unrepresentable: the
    key set has no place to put it.
    """
    return _mint_workflow_launch(
        edge_id=edge_id,
        instance_id=instance_id,
        run_nonce=run_nonce,
        result_path=result_path,
        status_path=status_path,
        working_dir=working_dir,
        allowed_edge_ids=WORKFLOW_BOUND_EDGE_IDS,
        reason="launch_binding_invalid",
    )


def _load_workflow_launch_binding(
    value: dict[str, Any], expected_edge_id: str, payload: bytes
) -> dict[str, Any]:
    if (
        set(value) != WORKFLOW_LAUNCH_BINDING_KEYS
        or _canonical_json(value) != payload
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("edge_id") != expected_edge_id
        or not isinstance(value.get("instance_id"), str)
        or not value["instance_id"]
        or not isinstance(value.get("run_nonce"), str)
        or re.fullmatch(r"[0-9a-f]{64}", value["run_nonce"]) is None
        or value.get("workspace_mode") != "caller"
        or value.get("branch") != ""
    ):
        fail("launch_binding_invalid")
    for key in ("result_path", "status_path", "worktree"):
        item = value.get(key)
        if not isinstance(item, str) or _absolute_input(
            item, "launch_binding_invalid"
        ) != item:
            fail("launch_binding_invalid")
    return value


def _load_launch_binding(payload: bytes, expected_edge_id: str) -> dict[str, Any]:
    if not isinstance(payload, bytes) or not payload or len(payload) > 65_536:
        fail("launch_binding_invalid")
    value = _parse_json(payload, "launch_binding_invalid")
    if not isinstance(value, dict):
        fail("launch_binding_invalid")
    # The two key sets are disjoint on the members that matter, so a binding
    # cannot satisfy both. Dispatching on the declared backend keeps the
    # exclusion explicit rather than letting a smuggled member decide.
    if value.get("backend") == "workflow":
        return _load_workflow_launch_binding(value, expected_edge_id, payload)
    if (
        set(value) != LAUNCH_BINDING_KEYS
        or _canonical_json(value) != payload
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("edge_id") != expected_edge_id
        or not isinstance(value.get("instance_id"), str)
        or not value["instance_id"]
        or value.get("backend")
        # CONTRACT: dispatch-backend -auto
        not in {"background", "wezterm", "workflow"}
        or not isinstance(value.get("handle"), str)
        or not value["handle"]
        or not isinstance(value.get("receipt_sha256"), str)
        or SHA256.fullmatch(value["receipt_sha256"]) is None
        or not isinstance(value.get("launch_status_sha256"), str)
        or SHA256.fullmatch(value["launch_status_sha256"]) is None
        or not isinstance(value.get("process_identity"), str)
        or PROCESS_IDENTITY.fullmatch(value["process_identity"]) is None
        or not isinstance(value.get("lease_generation"), str)
        or LEASE_GENERATION.fullmatch(value["lease_generation"]) is None
        or value.get("workspace_mode") != "caller"
        or value.get("branch") != ""
    ):
        fail("launch_binding_invalid")
    for key in ("result_path", "status_path", "worktree"):
        item = value.get(key)
        if not isinstance(item, str) or _absolute_input(
            item, "launch_binding_invalid"
        ) != item:
            fail("launch_binding_invalid")
    return value


def bind_fixer_launch_receipt(
    *,
    receipt: bytes,
    edge_id: str,
    instance_id: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    authority_path: str,
    authority_sha256: str,
) -> dict[str, Any]:
    if edge_id not in {
        "review_pr.fix.phase1",
        "review_pr.fix.phase2",
        "simplify.fix.phase2",
    }:
        fail("fixer_binding_invalid")
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if (
        authority["edge_id"] != edge_id
        or authority["working_dir"] != canonical_working
    ):
        fail("fixer_binding_invalid")
    binding = bind_launch_receipt(
        receipt=receipt,
        edge_id=edge_id,
        instance_id=instance_id,
        result_path=result_path,
        status_path=status_path,
        working_dir=canonical_working,
    )
    binding.update(
        {
            "authority_path": canonical_authority,
            "authority_sha256": authority_sha256,
        }
    )
    return binding


def bind_workflow_fixer_launch(
    *,
    edge_id: str,
    instance_id: str,
    run_nonce: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    authority_path: str,
    authority_sha256: str,
) -> dict[str, Any]:
    """Mint the fixer launch binding for a Workflow-native child.

    The workflow twin of `bind_fixer_launch_receipt`, and deliberately owing the
    SAME extra proof: the controller-created authority is pinned by path and
    digest, and it must name this edge and this worktree. A fixer child owes a
    disposition and an applied-content artifact that a reviewer never writes, so
    the reviewer-shaped `bind_workflow_launch` is not a substitute -- and the
    edge allowlist here is the fixer roster alone, so a reviewer edge cannot be
    minted into a fixer binding and skip those obligations.
    """
    if edge_id not in WORKFLOW_FIXER_EDGE_IDS:
        fail("fixer_binding_invalid")
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if (
        authority["edge_id"] != edge_id
        or authority["working_dir"] != canonical_working
    ):
        fail("fixer_binding_invalid")
    binding = _mint_workflow_launch(
        edge_id=edge_id,
        instance_id=instance_id,
        run_nonce=run_nonce,
        result_path=result_path,
        status_path=status_path,
        working_dir=canonical_working,
        allowed_edge_ids=WORKFLOW_FIXER_EDGE_IDS,
        reason="launch_binding_invalid",
    )
    binding.update(
        {
            "authority_path": canonical_authority,
            "authority_sha256": authority_sha256,
        }
    )
    return binding


def _load_fixer_launch_binding(
    payload: bytes, expected_edge_id: str
) -> dict[str, Any]:
    if not isinstance(payload, bytes) or not payload or len(payload) > 65_536:
        fail("fixer_binding_invalid")
    value = _parse_json(payload, "fixer_binding_invalid")
    base_keys = _binding_base_keys(value, "fixer_binding_invalid")
    if (
        set(value) != base_keys | FIXER_BINDING_EXTRA_KEYS
        or _canonical_json(value) != payload
        or not isinstance(value.get("authority_path"), str)
        or _absolute_input(value["authority_path"], "fixer_binding_invalid")
        != value["authority_path"]
        or not isinstance(value.get("authority_sha256"), str)
        or SHA256.fullmatch(value["authority_sha256"]) is None
    ):
        fail("fixer_binding_invalid")
    base = {key: value[key] for key in base_keys}
    _load_launch_binding(_canonical_json(base), expected_edge_id)
    authority = _load_authority(value["authority_path"], value["authority_sha256"])
    if (
        authority["edge_id"] != expected_edge_id
        or authority["working_dir"] != value["worktree"]
    ):
        fail("fixer_binding_invalid")
    return value


def bind_persistence_launch_receipt(
    *,
    receipt: bytes,
    edge_id: str,
    instance_id: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    aggregate_path: str,
    aggregate_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    expected_deferred_blockers: int,
    require_clean: bool,
) -> dict[str, Any]:
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_aggregate = _absolute_input(aggregate_path, "findings_path_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    _validate_persistence_authority(
        edge_id=edge_id,
        canonical_working=canonical_working,
        canonical_aggregate=canonical_aggregate,
        aggregate_sha256=aggregate_sha256,
        canonical_disposition=canonical_disposition,
        disposition_sha256=disposition_sha256,
        expected_deferred_blockers=expected_deferred_blockers,
        require_clean=require_clean,
    )
    binding = bind_launch_receipt(
        receipt=receipt,
        edge_id=edge_id,
        instance_id=instance_id,
        result_path=result_path,
        status_path=status_path,
        working_dir=working_dir,
    )
    binding.update(
        {
            "aggregate_path": canonical_aggregate,
            "aggregate_sha256": aggregate_sha256,
            "disposition_path": canonical_disposition,
            "disposition_sha256": disposition_sha256,
            "expected_deferred_blockers": expected_deferred_blockers,
            "require_clean": require_clean,
        }
    )
    return binding


def _validate_persistence_authority(
    *,
    edge_id: str,
    canonical_working: str,
    canonical_aggregate: str,
    aggregate_sha256: str,
    canonical_disposition: str,
    disposition_sha256: str,
    expected_deferred_blockers: int,
    require_clean: bool,
) -> None:
    """The defer stage's extra obligations, shared by both producers.

    Named once so the detached and workflow persistence bindings cannot drift
    into pinning different things: same edge, same containment rule, same digest
    shapes, and the same recount of deferred blockers against the pinned
    **Phase 2** aggregate and disposition bytes. The phase is this stage's, not
    the caller's: `count_phase2_deferred_blockers` refuses a Phase 1 pair on its
    envelope, so a fence cannot bind Phase 1 findings to the Phase 2 defer edge.
    """
    if (
        edge_id != "review_pr.defer.findings"
        or not beneath(canonical_working, canonical_aggregate)
        or not beneath(canonical_working, canonical_disposition)
        or not isinstance(aggregate_sha256, str)
        or SHA256.fullmatch(aggregate_sha256) is None
        or not isinstance(disposition_sha256, str)
        or SHA256.fullmatch(disposition_sha256) is None
        or type(expected_deferred_blockers) is not int
        or expected_deferred_blockers < 0
        or expected_deferred_blockers > 999_999_999
        or type(require_clean) is not bool
        or require_clean != (expected_deferred_blockers > 0)
    ):
        fail("persistence_binding_invalid")
    observed_deferred_blockers = count_phase2_deferred_blockers(
        findings_path=canonical_aggregate,
        findings_sha256=aggregate_sha256,
        disposition_path=canonical_disposition,
        disposition_sha256=disposition_sha256,
    )
    if observed_deferred_blockers != expected_deferred_blockers:
        fail("persistence_binding_invalid")


def bind_workflow_persistence_launch(
    *,
    instance_id: str,
    run_nonce: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    aggregate_path: str,
    aggregate_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    expected_deferred_blockers: int,
    require_clean: bool,
) -> dict[str, Any]:
    """Mint the persistence launch binding for a Workflow-native defer child.

    The workflow twin of `bind_persistence_launch_receipt`. It takes no edge id
    because there is exactly one defer edge, and it re-counts the deferred
    blockers from the pinned **Phase 2** aggregate/disposition bytes here rather
    than trusting the caller's number -- the same obligation the detached
    producer carries.
    """
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_aggregate = _absolute_input(aggregate_path, "findings_path_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    edge_id = "review_pr.defer.findings"
    _validate_persistence_authority(
        edge_id=edge_id,
        canonical_working=canonical_working,
        canonical_aggregate=canonical_aggregate,
        aggregate_sha256=aggregate_sha256,
        canonical_disposition=canonical_disposition,
        disposition_sha256=disposition_sha256,
        expected_deferred_blockers=expected_deferred_blockers,
        require_clean=require_clean,
    )
    binding = _mint_workflow_launch(
        edge_id=edge_id,
        instance_id=instance_id,
        run_nonce=run_nonce,
        result_path=result_path,
        status_path=status_path,
        working_dir=canonical_working,
        allowed_edge_ids=WORKFLOW_PERSISTENCE_EDGE_IDS,
        reason="launch_binding_invalid",
    )
    binding.update(
        {
            "aggregate_path": canonical_aggregate,
            "aggregate_sha256": aggregate_sha256,
            "disposition_path": canonical_disposition,
            "disposition_sha256": disposition_sha256,
            "expected_deferred_blockers": expected_deferred_blockers,
            "require_clean": require_clean,
        }
    )
    return binding


def _load_persistence_binding(payload: bytes) -> dict[str, Any]:
    if not isinstance(payload, bytes) or not payload or len(payload) > 65_536:
        fail("persistence_binding_invalid")
    value = _parse_json(payload, "persistence_binding_invalid")
    base_keys = _binding_base_keys(value, "persistence_binding_invalid")
    if (
        set(value) != base_keys | PERSISTENCE_BINDING_EXTRA_KEYS
        or _canonical_json(value) != payload
        or not isinstance(value.get("aggregate_sha256"), str)
        or SHA256.fullmatch(value["aggregate_sha256"]) is None
        or not isinstance(value.get("aggregate_path"), str)
        or _absolute_input(value["aggregate_path"], "persistence_binding_invalid")
        != value["aggregate_path"]
        or not isinstance(value.get("disposition_sha256"), str)
        or SHA256.fullmatch(value["disposition_sha256"]) is None
        or not isinstance(value.get("disposition_path"), str)
        or _absolute_input(value["disposition_path"], "persistence_binding_invalid")
        != value["disposition_path"]
        or type(value.get("expected_deferred_blockers")) is not int
        or value["expected_deferred_blockers"] < 0
        or value["expected_deferred_blockers"] > 999_999_999
        or type(value.get("require_clean")) is not bool
        or value["require_clean"]
        != (value["expected_deferred_blockers"] > 0)
        or not beneath(value.get("worktree"), value["aggregate_path"])
        or not beneath(value.get("worktree"), value["disposition_path"])
    ):
        fail("persistence_binding_invalid")
    base = {key: value[key] for key in base_keys}
    _load_launch_binding(
        _canonical_json(base), "review_pr.defer.findings"
    )
    return value


def capture_persistence_terminal(*, launch_binding: bytes) -> dict[str, Any]:
    binding = _load_persistence_binding(launch_binding)
    status_payload, _status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    result_payload, _result_identity = _capture_regular(
        binding["result_path"], 1, PERSISTENCE_RESULT_LIMIT
    )
    return {
        "status_path": binding["status_path"],
        "status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "result_path": binding["result_path"],
        "result_sha256": hashlib.sha256(result_payload).hexdigest(),
    }


DETACHED_SUPERVISION_KEYS = {"pid", "process_identity", "lease_generation"}


def _launch_identity(binding: dict[str, Any]) -> dict[str, str]:
    """The outcome's tie back to THE launch that produced it.

    A detached outcome is identified by the dispatch receipt's digest. A
    Workflow() call issues no receipt, so a workflow outcome is identified by
    the nonce the controller minted before the call -- a real value this process
    read out of the binding, not a synthesised digest.

    They are emitted under DIFFERENT keys deliberately. Relabelling the nonce as
    `receipt_sha256` would let a consumer written to check a dispatch receipt
    accept a workflow outcome as though a receipt had been verified; a distinct
    key makes such a consumer fail closed until it is taught the workflow shape.
    """
    if binding.get("backend") == "workflow":
        return {"run_nonce": binding["run_nonce"]}
    return {"receipt_sha256": binding["receipt_sha256"]}


def _validate_bound_workflow_child_status(
    binding: dict[str, Any], status_document: dict[str, Any]
) -> None:
    """Bind a Workflow-native child's status on a nonce instead of a PID.

    A Workflow child is awaited in-process: it owns no pid, no process group and
    no lease, so the detached triple cannot be populated. What that triple
    defends against -- a status file written by a different or recycled process,
    or by a stale detached agent -- cannot occur for an awaited call, so a
    single-use nonce the controller mints and the relay agent echoes back
    carries the same binding.

    The triple must be ABSENT, not null and not fabricated. A synthetic pid
    would leave every downstream equality check looking correct while proving
    nothing, which is strictly worse than having no check at all.
    """
    nonce = binding.get("run_nonce")
    if (
        set(status_document) - CHILD_STATUS_KEYS
        or DETACHED_SUPERVISION_KEYS & set(status_document)
        or not {
            "backend",
            "state",
            "exit_code",
            "run_nonce",
            "workspace_mode",
            "worktree",
            "branch",
        }.issubset(status_document)
        or status_document.get("backend") != "workflow"
        or status_document.get("state") != "completed"
        or type(status_document.get("exit_code")) is not int
        or status_document["exit_code"] != 0
        or not isinstance(nonce, str)
        or not re.fullmatch(r"[0-9a-f]{64}", nonce)
        or status_document.get("run_nonce") != nonce
        or status_document.get("workspace_mode") != binding["workspace_mode"]
        or status_document.get("worktree") != binding["worktree"]
        or status_document.get("branch") != binding["branch"]
        or (
            "result" in status_document
            and status_document["result"] != binding["result_path"]
        )
    ):
        fail("child_status_invalid")


def _validate_bound_child_status(
    binding: dict[str, Any], status_payload: bytes
) -> None:
    status_document = _parse_json(status_payload, "child_status_invalid")
    if not isinstance(status_document, dict):
        fail("child_status_invalid")
    if binding.get("backend") == "workflow":
        _validate_bound_workflow_child_status(binding, status_document)
        return
    status_handle = status_document.get("pid")
    if (
        set(status_document) - CHILD_STATUS_KEYS
        # A detached backend still owes the supervision triple; it must not
        # smuggle a workflow nonce in place of it.
        or "run_nonce" in status_document
        or status_document.get("backend") != binding["backend"]
        or status_document.get("state") != "completed"
        or not {
            "backend",
            "state",
            "exit_code",
            "pid",
            "process_identity",
            "lease_generation",
            "workspace_mode",
            "worktree",
            "branch",
        }.issubset(status_document)
        or type(status_document.get("exit_code")) is not int
        or status_document["exit_code"] != 0
        or type(status_document.get("pid")) not in {int, str}
        or isinstance(status_document.get("pid"), str)
        and not status_document["pid"]
        or binding["handle"] not in {str(status_handle), f"pane:{status_handle}"}
        or status_document.get("process_identity") != binding["process_identity"]
        or status_document.get("lease_generation") != binding["lease_generation"]
        or status_document.get("workspace_mode") != binding["workspace_mode"]
        or status_document.get("worktree") != binding["worktree"]
        or status_document.get("branch") != binding["branch"]
        or (
            "result" in status_document
            and status_document["result"] != binding["result_path"]
        )
    ):
        fail("child_status_invalid")


def capture_bound_child(*, launch_binding: bytes, edge_id: str) -> dict[str, Any]:
    """Freeze a bound child's artifacts and prove the binding, for ANY roster edge.

    The reviewer-shaped sibling of `capture_review_terminal`. The three existing
    `capture-*-terminal` verbs are all fixer/defer-shaped: each loads a binding
    carrying a disposition and an applied-content artifact, which a reviewer or
    a simplifier lens never writes. There was consequently NO verb that could
    consume a reviewer child of any backend, which is why a Workflow-dispatched
    review stage could not prove its own evidence.

    This verb adds no new trust surface. It is the composition of two shipped
    primitives -- `_load_launch_binding` (which already dispatches to the
    workflow loader on `backend == "workflow"`) and `_validate_bound_child_status`
    (which already dispatches to the nonce validator) -- over `_capture_regular`,
    the same bounded reader every other capture uses.

    Both digests are computed HERE, from bytes this process read off disk. No
    caller-supplied digest is accepted and none is compared: a verb that took a
    digest as input could be handed one an agent computed, which is precisely
    the degradation from *the controller proved it* to *an LLM said so* that the
    review-fleet seam exists to prevent.

    The status file is captured and validated BEFORE the result file is read, so
    a child that never bound itself costs a refusal rather than a capture.
    """
    # Enforce the contract this docstring states. bind_workflow_launch mints
    # bindings for the fixer edges too, so without this a fixer child could be
    # frozen by the reviewer-shaped verb and skip the disposition and
    # applied-content artifacts it owes -- the capture would look complete and
    # would have proved strictly less.
    if edge_id in WORKFLOW_FIXER_EDGE_IDS:
        fail("bound_child_edge_unsupported")
    # The ci edges are refused by the same door for the same reason: they carry
    # a pinned log/aggregate authority this verb has no slot for, so freezing a
    # CI child here would prove strictly less while looking complete. See
    # WORKFLOW_CI_EDGE_IDS and capture_ci_terminal (#383).
    if edge_id not in (WORKFLOW_REVIEWER_EDGE_IDS | WORKFLOW_VERIFIER_EDGE_IDS):
        fail("bound_child_edge_unsupported")
    binding = _load_launch_binding(launch_binding, edge_id)
    if binding.get("backend") != "workflow":
        fail("launch_binding_invalid")
    status_payload, status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    result_payload, result_identity = _capture_regular(
        binding["result_path"], 1, BOUND_CHILD_RESULT_LIMIT
    )
    # Two distinct artifacts, not one file reached by two names. Without this a
    # symlinked or hardlinked status.json -> result.md would satisfy every
    # equality below while carrying a single set of bytes.
    if status_identity == result_identity:
        fail("child_status_invalid")
    return {
        "edge_id": binding["edge_id"],
        "instance_id": binding["instance_id"],
        "status_path": binding["status_path"],
        "status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "result_path": binding["result_path"],
        "result_sha256": hashlib.sha256(result_payload).hexdigest(),
    }


# ---------------------------------------------------------------------------
# Phase 3 CI authority (#383) -- the fourth shape.
# ---------------------------------------------------------------------------
# The phase is pinned PER EDGE rather than taken as a free scalar. It mirrors
# policy/solve-run-tree-v1.json's `phase` for each edge; a caller cannot mint a
# rebase authority that claims to be a classify authority.
CI_AUTHORITY_PHASE_BY_EDGE = {
    "review_pr.ci.classify": "ci",
    "review_pr.ci.fix_code": "ci_fix",
    "review_pr.ci.rebase": "ci_fix",
    "review_pr.ci.defer_refusal": "defer_findings",
    "review_pr.ci.resolve_conflict": "conflict_resolution",
}

CI_READ_AUTHORITY_KEYS = {
    "schema_version",
    "edge_id",
    "phase",
    "pr_number",
    "run_id",
    "head_sha",
    "working_dir",
    "input_path",
    "input_sha256",
}
CI_MUTATION_AUTHORITY_KEYS = CI_READ_AUTHORITY_KEYS | {
    "failure_class",
    "signal_anchor",
    "parent_sha",
    "parent_tree_sha",
    "base_sha",
    # THE BASE BRANCH'S TIP, distinct from `base_sha` on purpose. `base_sha` is
    # the MERGE-BASE the controller pins before dispatch; `base_tip_sha` is
    # `refs/remotes/origin/<base_branch>` at that same moment, which is the ref
    # the child is actually told to rebase onto (agents/ci-rebase-handler.md
    # Step 4: `git rebase "origin/$base_branch"`).
    #
    # Two values because the merge-base cannot prove where a rebase LANDED once
    # the base branch has itself been rewritten: the merge-base then collapses to
    # the shared fork point, and every candidate rebase target contains the fork
    # point. See _validate_ci_rebase_outcome (#438).
    "base_tip_sha",
    "lease_sha",
    "pr_branch",
    "base_branch",
    "target_paths",
}

# Per-edge required-non-empty members. The mint refuses a missing one, so a
# rebase whose lease was never captured never reaches a Workflow call at all --
# it fails at the moment the controller could still do something about it,
# rather than after a child has already run.
CI_AUTHORITY_REQUIRED_MEMBERS = {
    # fix_code carries the lease and the branch for the SAME reason rebase does:
    # both terminals reach the ONE leased push in commands/review-pr.md 6c.4w.3,
    # and a push whose lease went missing between fences would either force
    # against an empty ref or degrade to an unleased push. Refusing here costs a
    # halt before the child runs; discovering it at the push costs a wrong ref.
    "review_pr.ci.fix_code": ("failure_class", "signal_anchor", "parent_sha",
                              "parent_tree_sha", "lease_sha", "pr_branch"),
    # `base_tip_sha` is required for the SAME reason `lease_sha` is: it is
    # captured in 6c.4 ROUTE and consumed two dead shells later (6c.4w.1's mint
    # and 6c.4w.3's push), so a `${CI_BASE_TIP_SHA:-}` default would silently
    # retire the only predicate that can tell a correct rebase from a
    # stack-detaching one. Refusing here costs a halt before the child runs.
    "review_pr.ci.rebase": ("base_sha", "base_tip_sha", "lease_sha", "pr_branch",
                            "base_branch"),
    "review_pr.ci.resolve_conflict": ("base_sha", "pr_branch", "base_branch"),
}

# The six members of CI_FAILURE_CLASS_ENUM (skills/merge-pipeline/SKILL.md
# Constants). Spelled here because an authority that named an unknown class
# would license a fixer arm nothing routes.
CI_FAILURE_CLASSES = (
    "code_bug",
    "env_drift",
    "stale_base",
    "flaky",
    "billing_quota",
    "platform_outage",
)

CI_INPUT_LIMIT = 1_048_576
CI_RESULT_LIMIT = 1_048_576
# The classifier's report is a short YAML fence, and the routed transport bounded
# it at 65,536 bytes. Keeping that bound is not cosmetic: the parser scans for the
# LAST fence in the document, so an unbounded report is an unbounded scan over
# bytes an agent chose.
CI_CLASSIFICATION_RESULT_LIMIT = 65_536

# A CI fix may touch the anchor's own file plus AT MOST ONE lockfile. The set is
# closed on purpose: `forbidden-pattern-multi-lockfile-churn` is enforced by the
# controller here rather than asked of the agent, because an agent that ignored
# the rule would still return a plausible result.
CI_LOCKFILE_BASENAMES = frozenset(
    (
        "Cargo.lock",
        "Gemfile.lock",
        "package-lock.json",
        "pnpm-lock.yaml",
        "poetry.lock",
        "uv.lock",
        "yarn.lock",
        "composer.lock",
        "go.sum",
    )
)

CI_BRANCH_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,254}")
CI_RUN_ID = re.compile(r"[1-9][0-9]{0,18}")


def _ci_edge_slug(edge_id: str) -> str:
    return edge_id.rsplit(".", 1)[-1].replace("_", "-")


def _ci_authority_shape(edge_id: str, value: dict[str, Any]) -> None:
    """Every rule the CI authority document owes, checked at mint AND at load.

    Named once because a mint-only check is a check a swapped file bypasses, and
    a load-only check is a check the controller discovers after it has already
    dispatched.
    """
    expected_keys = (
        CI_READ_AUTHORITY_KEYS
        if edge_id in CI_READ_EDGE_IDS
        else CI_MUTATION_AUTHORITY_KEYS
    )
    if set(value) != expected_keys:
        fail("ci_authority_invalid")
    if (
        type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("edge_id") != edge_id
        or value.get("phase") != CI_AUTHORITY_PHASE_BY_EDGE[edge_id]
        or type(value.get("pr_number")) is not int
        or value["pr_number"] <= 0
        or value["pr_number"] > 100_000_000
        or not isinstance(value.get("run_id"), str)
        or CI_RUN_ID.fullmatch(value["run_id"]) is None
        or not isinstance(value.get("head_sha"), str)
        or SHA1.fullmatch(value["head_sha"]) is None
        or not isinstance(value.get("input_sha256"), str)
        or SHA256.fullmatch(value["input_sha256"]) is None
    ):
        fail("ci_authority_invalid")
    for key in ("working_dir", "input_path"):
        item = value.get(key)
        if not isinstance(item, str) or _absolute_input(
            item, "ci_authority_invalid"
        ) != item:
            fail("ci_authority_invalid")
    if not beneath(value["working_dir"], value["input_path"]):
        fail("ci_authority_invalid")
    if edge_id in CI_READ_EDGE_IDS:
        return
    for key in ("parent_sha", "parent_tree_sha", "base_sha", "base_tip_sha",
                "lease_sha"):
        item = value.get(key)
        if not isinstance(item, str) or (
            item and SHA1.fullmatch(item) is None
        ):
            fail("ci_authority_invalid")
    for key in ("pr_branch", "base_branch"):
        item = value.get(key)
        if not isinstance(item, str) or (
            item and CI_BRANCH_NAME.fullmatch(item) is None
        ):
            fail("ci_authority_invalid")
    failure_class = value.get("failure_class")
    if not isinstance(failure_class, str) or (
        failure_class and failure_class not in CI_FAILURE_CLASSES
    ):
        fail("ci_authority_invalid")
    anchor = value.get("signal_anchor")
    if not isinstance(anchor, str) or len(anchor) > 512:
        fail("ci_authority_invalid")
    target_paths = value.get("target_paths")
    if not isinstance(target_paths, list) or len(target_paths) > 1:
        fail("ci_authority_invalid")
    for item in target_paths:
        if not isinstance(item, str):
            fail("ci_authority_invalid")
        _repo_path_from_location(f"{item}:1")
    # resolve_conflict names exactly the ONE path its child may resolve; the
    # other two mutating edges derive their scope from the anchor and must not
    # carry a second, competing scope declaration.
    if edge_id == "review_pr.ci.resolve_conflict":
        if len(target_paths) != 1:
            fail("ci_authority_invalid")
    elif target_paths:
        fail("ci_authority_invalid")
    for required in CI_AUTHORITY_REQUIRED_MEMBERS.get(edge_id, ()):
        if not value.get(required):
            fail("ci_authority_invalid")


def prepare_ci_authority(
    *,
    edge_id: str,
    pr_number: int,
    run_id: str,
    head_sha: str,
    working_dir: str,
    input_path: str,
    input_sha256: str,
    authority_output_path: str,
    failure_class: str = "",
    signal_anchor: str = "",
    parent_sha: str = "",
    parent_tree_sha: str = "",
    base_sha: str = "",
    base_tip_sha: str = "",
    lease_sha: str = "",
    pr_branch: str = "",
    base_branch: str = "",
    target_paths: tuple[str, ...] = (),
) -> dict[str, Any]:
    """Mint and publish the CI authority a Phase 3 child is dispatched against.

    Published through `_publish_new_exact_record`, the same no-clobber,
    identity-rechecked publisher `prepare_authority` uses: an authority a
    binding already pins can never be replaced in place.

    The pinned input bytes are captured against `input_sha256` HERE, so an
    authority can only be minted over an artifact that really exists under that
    digest at mint time. capture_ci_terminal re-captures the same pair after the
    child returns, which is what turns the pin into a proof rather than a claim.
    """
    if edge_id not in WORKFLOW_CI_EDGE_IDS:
        fail("ci_authority_invalid")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if not os.path.isdir(canonical_working):
        fail("working_dir_invalid")
    _require_repository(canonical_working)
    canonical_input = _absolute_input(input_path, "ci_authority_invalid")
    # Digest-first: the authority names bytes, not a pathname.
    capture_expected(canonical_input, input_sha256, 1, CI_INPUT_LIMIT)
    authority: dict[str, Any] = {
        "schema_version": 1,
        "edge_id": edge_id,
        "phase": CI_AUTHORITY_PHASE_BY_EDGE.get(edge_id, ""),
        "pr_number": pr_number,
        "run_id": run_id,
        "head_sha": head_sha,
        "working_dir": canonical_working,
        "input_path": canonical_input,
        "input_sha256": input_sha256,
    }
    if edge_id not in CI_READ_EDGE_IDS:
        authority.update(
            {
                "failure_class": failure_class,
                "signal_anchor": signal_anchor,
                "parent_sha": parent_sha,
                "parent_tree_sha": parent_tree_sha,
                "base_sha": base_sha,
                "base_tip_sha": base_tip_sha,
                "lease_sha": lease_sha,
                "pr_branch": pr_branch,
                "base_branch": base_branch,
                "target_paths": list(target_paths),
            }
        )
    _ci_authority_shape(edge_id, authority)
    canonical_output = _absolute_input(
        authority_output_path, "ci_authority_path_invalid"
    )
    if not beneath(canonical_working, canonical_output):
        fail("ci_authority_path_invalid")
    # The basename carries BOTH loop counters, so iteration 2 can never publish
    # over iteration 1's authority and the no-clobber publisher never has to
    # arbitrate between two live runs.
    if (
        re.fullmatch(
            rf"ci-authority-{re.escape(_ci_edge_slug(edge_id))}"
            r"-iter[0-9]{1,3}-ci[0-9]{1,3}(?:-[0-9]{1,4})?\.json",
            os.path.basename(canonical_output),
        )
        is None
    ):
        fail("ci_authority_path_invalid")
    payload = _canonical_json(authority) + b"\n"
    published_path, digest = _publish_new_exact(canonical_output, payload)
    return {
        "authority_path": published_path,
        "authority_sha256": digest,
        "edge_id": edge_id,
        "phase": authority["phase"],
    }


def _load_ci_authority(path: str, digest: str) -> dict[str, Any]:
    payload = capture_expected(path, digest, 1, AUTHORITY_LIMIT)
    value = _parse_json(payload, "ci_authority_invalid")
    if not isinstance(value, dict):
        fail("ci_authority_invalid")
    edge_id = value.get("edge_id")
    if edge_id not in WORKFLOW_CI_EDGE_IDS:
        fail("ci_authority_invalid")
    _ci_authority_shape(edge_id, value)
    if _canonical_json(value) + b"\n" != payload:
        fail("ci_authority_invalid")
    return value


def read_ci_authority_member(
    *, authority_path: str, authority_sha256: str, member: str
) -> str:
    """Read ONE member back out of a digest-pinned CI authority.

    This exists so the controller never reaches for `jq`. Reading the authority
    with jq would read it WITHOUT re-checking the digest, and the digest
    re-check is the entire point: the lease SHA the controller force-pushes
    against must be the one it minted, not whatever the file says now.
    """
    if not isinstance(member, str) or member in {"", "schema_version"}:
        fail("ci_authority_member_invalid")
    authority = _load_ci_authority(authority_path, authority_sha256)
    if member not in authority:
        fail("ci_authority_member_invalid")
    value = authority[member]
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        fail("ci_authority_member_invalid")
    return str(value)


def bind_workflow_ci_launch(
    *,
    edge_id: str,
    instance_id: str,
    run_nonce: str,
    result_path: str,
    status_path: str,
    working_dir: str,
    ci_authority_path: str,
    ci_authority_sha256: str,
) -> dict[str, Any]:
    """Mint the launch binding for a Workflow-native Phase 3 CI child.

    The CI twin of `bind_workflow_fixer_launch`, and deliberately a DIFFERENT
    producer: the extra members are `ci_authority_path`/`ci_authority_sha256`,
    not `authority_path`/`authority_sha256`, so a CI binding cannot be re-read
    as a fixer binding by a loader that would then `_load_authority()` a
    document of the wrong shape.
    """
    if edge_id not in WORKFLOW_CI_EDGE_IDS:
        fail("ci_binding_invalid")
    canonical_authority = _absolute_input(
        ci_authority_path, "ci_authority_path_invalid"
    )
    authority = _load_ci_authority(canonical_authority, ci_authority_sha256)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if (
        authority["edge_id"] != edge_id
        or authority["working_dir"] != canonical_working
    ):
        fail("ci_binding_invalid")
    binding = _mint_workflow_launch(
        edge_id=edge_id,
        instance_id=instance_id,
        run_nonce=run_nonce,
        result_path=result_path,
        status_path=status_path,
        working_dir=canonical_working,
        allowed_edge_ids=WORKFLOW_CI_EDGE_IDS,
        reason="ci_binding_invalid",
    )
    binding.update(
        {
            "ci_authority_path": canonical_authority,
            "ci_authority_sha256": ci_authority_sha256,
        }
    )
    return binding


def _load_ci_launch_binding(
    payload: bytes, expected_edge_id: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Load a CI binding AND the authority it pins, as one indivisible pair.

    Returned together rather than stashed on the binding dict: every caller
    needs both, and a loader that handed back only the binding would invite a
    second, unpinned `_load_ci_authority` call somewhere downstream.
    """
    if not isinstance(payload, bytes) or not payload or len(payload) > 65_536:
        fail("ci_binding_invalid")
    value = _parse_json(payload, "ci_binding_invalid")
    if not isinstance(value, dict):
        fail("ci_binding_invalid")
    # CI children exist only on the workflow transport -- #382 deleted the last
    # detached backend that had a provider arm for them -- so there is no
    # detached CI binding shape to dispatch on. Anything else is refused.
    if value.get("backend") != "workflow":
        fail("ci_binding_invalid")
    if (
        set(value) != WORKFLOW_CI_LAUNCH_BINDING_KEYS
        or _canonical_json(value) != payload
        or not isinstance(value.get("ci_authority_path"), str)
        or _absolute_input(value["ci_authority_path"], "ci_binding_invalid")
        != value["ci_authority_path"]
        or not isinstance(value.get("ci_authority_sha256"), str)
        or SHA256.fullmatch(value["ci_authority_sha256"]) is None
    ):
        fail("ci_binding_invalid")
    base = {key: value[key] for key in WORKFLOW_LAUNCH_BINDING_KEYS}
    _load_launch_binding(_canonical_json(base), expected_edge_id)
    authority = _load_ci_authority(
        value["ci_authority_path"], value["ci_authority_sha256"]
    )
    if (
        authority["edge_id"] != expected_edge_id
        or authority["working_dir"] != value["worktree"]
    ):
        fail("ci_binding_invalid")
    return value, authority


def capture_ci_terminal(
    *, launch_binding: bytes, edge_id: str
) -> dict[str, Any]:
    """Freeze a Phase 3 CI child's TWO outputs AND its ONE pinned input.

    The third freeze is the whole reason this verb exists rather than a widened
    `capture_bound_child`. A GH-Actions log is fetched once and is unreachable
    afterwards; without re-capturing it against the digest the authority pinned,
    the controller would prove the child wrote something and prove nothing about
    what it read.

    Status is captured and validated BEFORE the result is read, so a child that
    never bound itself costs a refusal rather than a capture. Both output
    digests are computed here from bytes this process read; no caller-supplied
    digest is accepted and none is compared.
    """
    if edge_id not in WORKFLOW_CI_EDGE_IDS:
        fail("ci_terminal_edge_unsupported")
    binding, authority = _load_ci_launch_binding(launch_binding, edge_id)
    status_payload, status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    result_payload, result_identity = _capture_regular(
        binding["result_path"], 1, CI_RESULT_LIMIT
    )
    if status_identity == result_identity:
        fail("child_status_invalid")
    # The pin. If the log bytes moved since the mint, this refuses.
    capture_expected(
        authority["input_path"], authority["input_sha256"], 1, CI_INPUT_LIMIT
    )
    return {
        "edge_id": binding["edge_id"],
        "instance_id": binding["instance_id"],
        "status_path": binding["status_path"],
        "status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "result_path": binding["result_path"],
        "result_sha256": hashlib.sha256(result_payload).hexdigest(),
        "input_path": authority["input_path"],
        "input_sha256": authority["input_sha256"],
    }


CI_CLASSIFIER_FIELDS = {
    "status",
    "failure_class",
    "signal_anchor",
    "rationale",
    "risks",
}
CI_CLASSIFIER_SCALAR = re.compile(r"[A-Za-z0-9_./:+ -]{1,256}")


def _ci_classifier_scalar(raw: str) -> str | None:
    if raw == "null":
        return None
    try:
        if raw.startswith('"'):
            parsed = json.loads(raw)
        elif re.fullmatch(r"'(?:[^']|'')*'", raw):
            parsed = raw[1:-1].replace("''", "'")
        elif CI_CLASSIFIER_SCALAR.fullmatch(raw):
            parsed = raw
        else:
            fail("ci_classification_contract_invalid")
    except (ValueError, json.JSONDecodeError):
        fail("ci_classification_contract_invalid")
    if (
        not isinstance(parsed, str)
        or not parsed
        or len(parsed) > 256
        or any(ord(character) < 32 or ord(character) == 127 for character in parsed)
    ):
        fail("ci_classification_contract_invalid")
    return parsed


def _ci_anchor_names_repository_file(working_dir: str, component: str) -> bool:
    if component.startswith("/") or "\\" in component:
        return False
    parts = component.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return False
    try:
        root_path = os.path.realpath(working_dir)
        target = os.path.realpath(os.path.join(root_path, component))
    except (OSError, TypeError, ValueError):
        return False
    return (
        target != root_path
        and beneath(root_path, target)
        and os.path.isfile(target)
    )


def _parse_ci_classification(payload: bytes, working_dir: str) -> dict[str, str]:
    """The classifier contract, moved out of the /review-pr heredoc (#383).

    commands/review-pr.md carries the same predicate as a python heredoc,
    which means the decision routing a MUTATING fixer is LLM-rendered markdown
    with no test of its own. This is that predicate as tested code; the Phase 3
    wiring deletes the heredoc when it re-points at these verbs. The rule set
    is identical: closed field set, closed status set, a legal class/anchor
    pairing, and -- for code_bug/env_drift -- an anchor that names an EXISTING
    repository file. `:121`, `file:0`, absolute and traversal anchors are
    contract violations, and an invalid result is never repaired into
    platform_outage or flaky.
    """
    try:
        text = payload.decode("utf-8")
    except UnicodeError:
        fail("ci_classification_contract_invalid")
    document = re.search(
        r"(?:^|\n)```yaml\r?\n(.*?)\r?\n```\r?\n?\Z", text, re.DOTALL
    )
    if document is None:
        fail("ci_classification_contract_invalid")
    fields: dict[str, str] = {}
    for line in document.group(1).splitlines():
        match = re.fullmatch(r"([a-z_][a-z0-9_]*):[ \t]*(.*)", line)
        if match is None:
            fail("ci_classification_contract_invalid")
        key, value = match.groups()
        if key in fields:
            fail("ci_classification_contract_invalid")
        fields[key] = value.strip()
    if set(fields) != CI_CLASSIFIER_FIELDS or fields["risks"] != "[]":
        fail("ci_classification_contract_invalid")
    status = _ci_classifier_scalar(fields["status"])
    failure_class = _ci_classifier_scalar(fields["failure_class"])
    anchor = _ci_classifier_scalar(fields["signal_anchor"])
    rationale = _ci_classifier_scalar(fields["rationale"])
    if status == "AMBIGUOUS":
        if failure_class is not None or anchor is not None:
            fail("ci_classification_contract_invalid")
        # Shipped semantics: the controller routes AMBIGUOUS to flaky AFTER
        # emitting ci_classify_ambiguous_routing_as_flaky. Reported, not halted,
        # so that audit event stays reachable.
        return {
            "status": "AMBIGUOUS",
            "failure_class": "flaky",
            "signal_anchor": "",
            "rationale": rationale or "",
        }
    if status == "REFUSED":
        if failure_class is not None or anchor is not None or not rationale:
            fail("ci_classification_contract_invalid")
        fail("ci_classification_refused")
    if status != "CLASSIFIED" or failure_class not in CI_FAILURE_CLASSES:
        fail("ci_classification_contract_invalid")
    if anchor is None:
        fail("ci_classification_contract_invalid")
    match = re.fullmatch(r"(.+):([1-9][0-9]*)", anchor)
    if match is None:
        fail("ci_classification_contract_invalid")
    component = match.group(1)
    is_run = re.fullmatch(r"gh-run-[1-9][0-9]*", component) is not None
    is_repo = _ci_anchor_names_repository_file(working_dir, component)
    if failure_class in {"code_bug", "env_drift"}:
        if not is_repo:
            fail("ci_classification_contract_invalid")
    elif not (is_run or is_repo):
        fail("ci_classification_contract_invalid")
    return {
        "status": "CLASSIFIED",
        "failure_class": failure_class,
        "signal_anchor": anchor,
        "rationale": rationale or "",
    }


def validate_ci_classification(
    *, launch_binding: bytes, status_sha256: str, result_sha256: str
) -> dict[str, Any]:
    """Judge the classifier child, from the CONTROLLER's side of the seam.

    Four things the script cannot do and must not be asked to: re-capture the
    pinned log bytes, bind the status file to the minted nonce, re-read the
    frozen result bytes, and run the classifier contract against the real
    worktree. The routing scalar the mutating arm keys on comes from HERE, never
    from the classify child's structured return.
    """
    binding, authority = _load_ci_launch_binding(
        launch_binding, "review_pr.ci.classify"
    )
    try:
        capture_expected(
            authority["input_path"], authority["input_sha256"], 1, CI_INPUT_LIMIT
        )
    except ContractFailure:
        fail("ci_classification_log_mismatch")
    status_payload = capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    result_payload = capture_expected(
        binding["result_path"], result_sha256, 1, CI_CLASSIFICATION_RESULT_LIMIT
    )
    classification = _parse_ci_classification(result_payload, binding["worktree"])
    return {
        **classification,
        "status_sha256": status_sha256,
        "result_sha256": result_sha256,
        **_launch_identity(binding),
    }


def _ci_evidence_dir(authority: dict[str, Any], working_dir: str) -> str:
    """The run's evidence directory, DERIVED from the pinned input artifact.

    Never a parameter: a caller that could name the exempt directory could
    exempt the whole worktree.

    Every Phase 3 child's input lives at the layout
    `skills/review-fleet/workflow.js:childInputPath()` mints and
    `lib/review-fleet-args.sh:review_fleet_child_dir` mirrors —

        <run_dir>/children/<slug>-iterNN/input.json

    — so the RUN directory is two levels above the input's own directory, and
    the `children` component is ASSERTED rather than assumed. Stopping at the
    child directory instead (which is what this did first) is narrower than the
    residue contract every other mutating verb answers to: `validate-residue` is
    invoked with `RESEARCH_DIR_ABS`, the run directory, everywhere else in
    `commands/review-pr.md`. Under the narrow form a sibling resolver's own
    `input.json` — a file this command wrote itself, moments earlier — counted
    as foreign untracked residue, and every CI verb refused in any repository
    that had not already ignored `.uberdev/`.

    An input that is NOT under a `children/` pair keeps the narrow reading: it
    is its own directory's evidence and nothing above it is exempt.
    """
    input_dir = os.path.dirname(authority["input_path"])
    parent = os.path.dirname(input_dir)
    evidence_dir = (
        os.path.dirname(parent) if os.path.basename(parent) == "children"
        else input_dir
    )
    if (
        not evidence_dir
        or evidence_dir == working_dir
        or not beneath(working_dir, evidence_dir)
    ):
        fail("evidence_dir_invalid")
    return evidence_dir


def _ci_require_residue_closed(authority: dict[str, Any], working_dir: str) -> None:
    """Reuse the SHIPPED residue predicate rather than inventing a CI-only one.

    `_require_clean_worktree` is what every other mutating verb in this file
    already answers to, and it carries the one piece of nuance a fresh
    `git status --porcelain` check would get wrong: the run's own evidence
    directory is legitimately untracked, and everything else is not.
    """
    _require_clean_worktree(
        working_dir, _ci_evidence_dir(authority, working_dir)
    )


CI_REBASE_STATE_DIRS = ("rebase-merge", "rebase-apply")


def _ci_rebase_dir(working_dir: str) -> str:
    """The live rebase state directory, or "" when no rebase is running.

    ONE definition, because the rebase judge and the conflict judge must agree
    about what "mid-rebase" means: the first must return CONFLICT in exactly the
    state the second is allowed to run in, and two spellings of the probe are
    two chances for them to disagree. `review_fleet_rebase_dir` in
    lib/review-fleet-args.sh is the shell half of the same definition and probes
    the same two directories in the same order.

    BOTH backends. `git rebase` has defaulted to the merge backend since 2.26,
    but `rebase.backend=apply` and an explicit `git rebase --apply` use
    `rebase-apply` instead — and a probe that knows only one of them answers
    "no rebase" for the other, which turns the mandated conflicted state into
    an `index_dirty` refusal and aborts the rebase the CONFLICT arm needs.
    """
    for component in CI_REBASE_STATE_DIRS:
        observed = _git(working_dir, "rev-parse", "--git-path", component)
        if observed.returncode != 0:
            fail("git_state_unreadable")
        try:
            rebase_dir = observed.stdout.decode("utf-8").strip()
        except UnicodeError:
            fail("git_state_unreadable")
        if not rebase_dir:
            fail("git_state_unreadable")
        absolute = (
            rebase_dir if os.path.isabs(rebase_dir)
            else os.path.join(working_dir, rebase_dir)
        )
        if os.path.isdir(absolute):
            return absolute
    return ""


def _ci_porcelain_entries(working_dir: str) -> tuple[bytes, ...]:
    """`git status --porcelain -z` STATUS records, rename origins removed.

    Porcelain v1 emits one `XY <path>` field per entry — except a rename or a
    copy, which emits TWO: `R  <new>\\0<old>\\0`. That second field is a bare
    pathname with no XY prefix, so splitting the stream on NUL alone yields it
    as if it were a status record of its own, and every consumer then reads the
    path's own first bytes as status columns.

    `_ci_worktree_dirty_paths` only required offset 2 to be a space — true of
    any path with a space there, `my file.md` among them — so a conflicted
    rebase whose replayed commit contained such a rename reported the
    nonexistent path `file.md` as worktree-dirty and failed
    `ci_rebase_conflict_scope_escape`, taking the CONFLICT-RESOLVE arm with it.
    `_ci_unmerged_paths` was not safe either, in the opposite direction: its
    filter was the two exact bytes `UU` and NO layout check, so a bare origin
    named `UUnamed.md` passed it and was emitted as the phantom path `amed.md`.
    Requiring the space at offset 2 — which it now does, because the pair test
    became a membership check that no longer implies the layout on its own —
    is what closes that one.

    What neither can distinguish is an origin whose first two bytes really are
    an unmerged pair AND whose third is a space: `AA x.txt` reads as a status
    record however carefully it is filtered. That residual is conservative in
    both callers — here it adds a path to the unmerged set, so
    `_validate_ci_rebase_outcome` takes the CONFLICT arm rather than declaring
    a clean REBASED. Both read through this one splitter, so neither can drift
    into a different answer about which shapes it is exposed to.
    """
    observed = _git(working_dir, "status", "--porcelain", "-z")
    if observed.returncode != 0:
        fail("git_state_unreadable")
    fields = observed.stdout.split(b"\x00")
    entries: list[bytes] = []
    index = 0
    while index < len(fields):
        record = fields[index]
        index += 1
        if not record:
            continue
        entries.append(record)
        # X or Y == 'R'/'C' is git's own signal that the NEXT field belongs to
        # THIS entry (the rename/copy source), not to a new one.
        if record[0:1] in (b"R", b"C") or record[1:2] in (b"R", b"C"):
            index += 1
    return tuple(entries)


def _ci_is_unmerged_pair(pair: bytes) -> bool:
    """True for every porcelain XY pair git uses to mean "unmerged".

    ONE definition, for the same reason `_ci_rebase_dir` is one: the rebase judge
    and the residue judge must agree about what an unmerged entry IS. They did
    not. `_ci_unmerged_paths` matched the two exact bytes `UU` while
    `_ci_worktree_dirty_paths` below already carried the full set, so an add/add
    rebase conflict — porcelain `AA`, not `UU` — was an unmerged path to one and
    invisible to the other. The CONFLICT guard in `_validate_ci_rebase_outcome`
    then saw no unmerged paths, fell through to `_ci_require_residue_closed`, and
    refused `index_dirty` on the exact state `agents/ci-rebase-handler.md` Step 5
    mandates — whose caller answers by running `git rebase --abort`, destroying
    the mid-rebase state the CONFLICT-RESOLVE arm needs.

    git's unmerged pairs are `DD`, `AU`, `UD`, `UA`, `DU`, `AA` and `UU`
    (`git status` "Unmerged paths"). Every one but `AA` and `DD` carries a `U`,
    so the membership test is that `U` plus those two named exceptions.
    """
    return b"U" in pair or pair in (b"AA", b"DD")


def _ci_unmerged_paths(working_dir: str) -> tuple[str, ...]:
    unmerged: list[str] = []
    for record in _ci_porcelain_entries(working_dir):
        # The space at offset 2 is porcelain's `XY <path>` separator. Required
        # explicitly now that the pair test is a membership check rather than the
        # two literal bytes `UU`, which used to imply the layout on its own.
        if len(record) < 4 or record[2:3] != b" ":
            continue
        if not _ci_is_unmerged_pair(record[0:2]):
            continue
        try:
            unmerged.append(record[3:].decode("utf-8"))
        except UnicodeError:
            fail("git_state_unreadable")
    return tuple(unmerged)


def list_ci_unmerged_paths(working_dir: str) -> str:
    """NUL-TERMINATED conflicted paths, for the shell side of the CONFLICT arm.

    The controller's Step-4 re-bind needs the same answer
    `_validate_ci_rebase_outcome` reached, and had been hand-rolling
    `git status --porcelain | awk '/^UU /'` to get it -- two exact bytes against
    this module's seven-pair membership test, so an add/add rebase conflict was
    CONFLICT to the judge and the EMPTY set to the enumerator (#398). Zero
    resolvers were dispatched, "all RESOLVED" was vacuously true, and the arm
    aborted a mid-rebase it could have finished.

    There is no second copy of the vocabulary here: this is a transport for
    `_ci_unmerged_paths`, which is a transport for `_ci_is_unmerged_pair`. The
    rename/copy-origin skipping and the offset-2 space requirement in
    `_ci_porcelain_entries` come along for free -- a shell re-implementation
    would have to reproduce both to avoid re-inventing the phantom
    `UUnamed.md` -> `amed.md` path.

    NUL-TERMINATED rather than newline-joined because a repository path may
    contain a newline (and, far more commonly, a space); TERMINATED rather than
    JOINED so that the empty set is the empty payload rather than one empty
    record. Byte-identical to what `review_fleet_write_conflict_paths` writes,
    so both are read back by the same `read -r -d ''` loop.
    """
    return "".join(entry + "\x00" for entry in _ci_unmerged_paths(working_dir))


def _ci_changed_paths(working_dir: str, before: str, after: str) -> tuple[str, ...]:
    # `--no-renames`, for the same reason `_changed_paths` passes it on all three
    # of its invocations: rename detection is ON by default, and it collapses a
    # rename to its DESTINATION path only. The scope check in
    # `_validate_ci_fix_code_outcome` is built entirely on this tuple, so a fixer
    # that did `git mv src/security_guard.py Cargo.lock` alongside a legitimate
    # anchor edit reported one anchor plus one lockfile — the permitted shape —
    # and `ci_fix_scope_escape` never fired on the deletion. Enumerating both
    # sides of the rename is what gives the loop a path to refuse.
    observed = _git(
        working_dir, "diff", "--name-only", "-z", "--no-renames", f"{before}..{after}", "--"
    )
    if observed.returncode != 0:
        fail("git_state_unreadable")
    return _decode_git_paths(observed.stdout, "git_state_unreadable")


# The documented ci-code-fixer refusal rationales (`agents/ci-code-fixer.md`
# "Forbidden patterns" and "Refusal triggers") are all lowercase kebab-case
# tokens. The controller renders the value into
# `data.subreason=ci_fixer_refused_<rationale>`, so anything outside this shape
# is recorded as `unspecified` rather than smuggled into an audit field.
CI_FIXER_RATIONALE = re.compile(r"[a-z][a-z0-9-]{0,63}")


def _ci_fix_code_declared_refusal(result_payload: bytes) -> str:
    """The child's own REFUSED declaration, from its FROZEN result bytes.

    Everything else about this terminal is derived from git, and rightly so: a
    child cannot be trusted to claim it committed. A REFUSAL is the opposite
    kind of claim — the child declining to act — and git cannot express it at
    all. A refusing `ci-code-fixer` makes no commit, so `head_after ==
    head_before` and the git-derived terminal was `NO_CHANGE`, byte-identical to
    a fixer that found nothing to change. 6c.5 branches on the validated
    terminal only ("never on the agent's self-report"), so with the two
    conflated the entire ci-defer stage — four fences, an authority edge and a
    Workflow arm — was unreachable and a REFUSED fixer halted `ci_fix_no_change`
    with no CRITICAL issue filed.

    Reading it here does not weaken that rule: the declaration is taken from the
    result bytes the controller already pinned by digest, and it can only ever
    DOWNGRADE a no-commit terminal into a halt. It can never turn an unmoved
    HEAD into a push, and it is not consulted at all once HEAD has moved.

    Returns the sanitised rationale, or "" when the child did not declare a
    refusal in the canonical trailing fence.
    """
    try:
        text = result_payload.decode("utf-8")
    except UnicodeError:
        return ""
    document = re.search(
        r"(?:^|\n)```yaml\r?\n(.*?)\r?\n```\r?\n?\Z", text, re.DOTALL
    )
    if document is None:
        return ""
    fields: dict[str, str] = {}
    for line in document.group(1).splitlines():
        match = re.fullmatch(r"([a-z_][a-z0-9_]*):[ \t]*(.*)", line)
        if match is not None:
            fields.setdefault(match.group(1), match.group(2).strip())
    if fields.get("status") != "REFUSED":
        return ""
    rationale = fields.get("rationale", "").strip("\"'")
    if CI_FIXER_RATIONALE.fullmatch(rationale) is None:
        return "unspecified"
    return rationale


def _validate_ci_fix_code_outcome(
    authority: dict[str, Any],
    working_dir: str,
    head_before: str,
    head_after: str,
    result_payload: bytes,
) -> tuple[str, str]:
    if head_before != authority["parent_sha"]:
        fail("ci_fix_head_moved_unexpectedly")
    if head_after == head_before:
        _ci_require_residue_closed(authority, working_dir)
        rationale = _ci_fix_code_declared_refusal(result_payload)
        return ("REFUSED", rationale) if rationale else ("NO_CHANGE", "")
    count = _git(working_dir, "rev-list", "--count", f"{head_before}..{head_after}")
    parent = _git(working_dir, "rev-parse", "--verify", f"{head_after}^")
    if count.returncode != 0 or parent.returncode != 0:
        fail("git_state_unreadable")
    try:
        commit_count = count.stdout.decode("ascii").strip()
        parent_sha = parent.stdout.decode("ascii").strip()
    except UnicodeError:
        fail("git_state_unreadable")
    if commit_count != "1" or parent_sha != head_before:
        fail("ci_fix_head_moved_unexpectedly")
    subject = _git(working_dir, "log", "-1", "--format=%s", head_after)
    if subject.returncode != 0:
        fail("git_state_unreadable")
    try:
        subject_text = subject.stdout.decode("utf-8").strip()
    except UnicodeError:
        fail("git_state_unreadable")
    if re.match(r"^(?:fix\(ci\)|chore\(deps\)): \S", subject_text) is None:
        fail("ci_fix_commit_subject_invalid")
    anchor_path = authority["signal_anchor"].rsplit(":", 1)[0]
    changed = _ci_changed_paths(working_dir, head_before, head_after)
    lockfiles = [
        path
        for path in changed
        if posixpath.basename(path) in CI_LOCKFILE_BASENAMES
    ]
    for path in changed:
        if path == anchor_path or path in lockfiles:
            continue
        fail("ci_fix_scope_escape")
    if len(lockfiles) > 1:
        fail("ci_fix_multi_lockfile")
    _ci_require_residue_closed(authority, working_dir)
    return ("APPLIED", "")


def _ci_worktree_dirty_paths(working_dir: str) -> tuple[str, ...]:
    """Tracked paths the WORKTREE has diverged on, excluding unmerged entries.

    Porcelain v1 `XY <path>`: X is the index-vs-HEAD column and Y the
    worktree-vs-index column. Mid-rebase, git stages every cleanly-replayed path
    (`M `, `A `, `D `) and marks the conflicted ones unmerged (`UU`, and the
    `AA`/`DD`/`AU`/`UA`/`DU`/`UD` variants). What it never produces is a tracked
    path whose WORKTREE differs from the index — so a non-space Y outside the
    unmerged set is an edit somebody made by hand.

    Reads through `_ci_porcelain_entries`, never the raw NUL split: the filter
    below accepts any record with a space at offset 2, and a rename ORIGIN
    field is exactly such a bare pathname.
    """
    dirty: list[str] = []
    for record in _ci_porcelain_entries(working_dir):
        if len(record) < 4 or record[2:3] != b" ":
            continue
        index_column = record[0:1]
        worktree_column = record[1:2]
        if index_column == b"?" or index_column == b"!":
            continue  # untracked/ignored: _require_untracked_confined_to_evidence
        if _ci_is_unmerged_pair(record[0:2]):
            continue  # a legitimate unmerged entry
        if worktree_column == b" ":
            continue
        try:
            dirty.append(record[3:].decode("utf-8"))
        except UnicodeError:
            fail("git_state_unreadable")
    return tuple(dirty)


def _ci_require_conflict_residue_closed(
    authority: dict[str, Any], working_dir: str
) -> None:
    """The residue proof the CONFLICT terminal CAN answer.

    `_ci_require_residue_closed` cannot run here: a conflicted rebase has
    unmerged index entries by construction, and demanding a clean index judged
    the very state `agents/ci-rebase-handler.md` Step 5 mandates. But returning
    CONFLICT with NO residue proof at all made this the one mutating CI terminal
    with none — and the CONFLICT path ends in the same leased force-push as the
    other two. A ci-rebase-handler that, alongside the conflicted rebase, wrote
    an unrelated tracked file or dropped a new untracked one passed as CONFLICT,
    rode `rebase --continue` onto the remote, and every downstream equality
    check still read as verified.

    Two halves, both sound mid-rebase and neither of them the index:
      - untracked paths confined to the run's evidence tree. `git rebase` does
        not create untracked files, so anything else came from the child.
      - no tracked path whose WORKTREE differs from the index outside the
        unmerged set (see `_ci_worktree_dirty_paths`).
    """
    _require_untracked_confined_to_evidence(
        working_dir,
        _ci_evidence_dir(authority, working_dir),
        outside_failure="ci_rebase_conflict_scope_escape",
    )
    if _ci_worktree_dirty_paths(working_dir):
        fail("ci_rebase_conflict_scope_escape")


def _validate_ci_rebase_outcome(
    authority: dict[str, Any],
    working_dir: str,
    head_before: str,
    head_after: str,
    remote_head_sha: str,
) -> str:
    # THE LEASE CHECK. The child was demoted from pusher to preparer
    # (agents/ci-rebase-handler.md), and this is what makes the demotion
    # enforceable rather than aspirational: if the child pushed anyway, the
    # remote tip no longer equals the lease the controller pinned before
    # dispatch, and the controller refuses BEFORE its own force-push.
    if (
        not isinstance(remote_head_sha, str)
        or SHA1.fullmatch(remote_head_sha) is None
        or remote_head_sha != authority["lease_sha"]
    ):
        fail("ci_rebase_remote_moved_during_child")
    if head_after == head_before:
        fail("ci_rebase_head_did_not_move")
    ancestry = _git(
        working_dir, "merge-base", "--is-ancestor", authority["base_sha"], head_after
    )
    if ancestry.returncode != 0:
        fail("ci_rebase_base_not_ancestor")
    # ...AND the base branch's TIP, which is a strictly stronger claim and the
    # only one that survives the base branch being rewritten (#438).
    #
    # `base_sha` is a MERGE-BASE. Once the base branch is force-pushed — the
    # state Phase 3 itself used to be able to manufacture, before the
    # dependent-PR gate in commands/review-pr.md 6c.4w.3 — that merge-base
    # collapses to the shared fork point with `main`. EVERY candidate rebase
    # target contains the fork point, so the check above passes unconditionally:
    # a rebase onto `main` (which detaches the PR from its stack and duplicates
    # the base branch's commits into its own diff) is accepted identically to a
    # rebase onto the branch the PR is actually stacked on.
    #
    # The tip is what the child was told to rebase onto, so it is what the
    # result must contain. Two consequences, both correct and both intended:
    # a base branch that merely FAST-FORWARDED during the child still contains
    # the pinned tip and passes; a base branch force-pushed during the child does
    # not, and this refuses rather than pushing a head built on a base that no
    # longer exists.
    #
    # Kept ALONGSIDE the merge-base check, never in place of it: the two answer
    # different questions, and the pair is cheaper than arguing about which one
    # subsumes the other. Ordered before the CONFLICT short-circuit for the same
    # reason the merge-base check is — a mid-rebase state must not buy an
    # exemption from ancestry — and sound there because `git rebase` checks out
    # the onto-target before replaying anything, so the pinned tip is an ancestor
    # of HEAD even when the FIRST commit conflicts (`--is-ancestor` is reflexive).
    tip_ancestry = _git(
        working_dir, "merge-base", "--is-ancestor",
        authority["base_tip_sha"], head_after,
    )
    if tip_ancestry.returncode != 0:
        fail("ci_rebase_base_tip_not_ancestor")
    # THE CONFLICT TERMINAL. `agents/ci-rebase-handler.md` Step 5 REQUIRES the
    # child to leave a conflicted rebase IN PROGRESS ("do NOT abort it") so the
    # controller can enumerate the unmerged paths from its own `git status`
    # rather than from the child's return. That state has unmerged index
    # entries by construction, so falling through to `_ci_require_residue_closed`
    # judged the mandated state `index_dirty` — and the caller's failure branch
    # then ran `git rebase --abort`, destroying the exact rebase the
    # CONFLICT-RESOLVE arm needs. The arm was unreachable in every run: this
    # function could only ever return "REBASED".
    #
    # Ordered AFTER the lease and ancestry checks on purpose. A conflicted
    # rebase relaxes the residue requirement and NOTHING else: a child that
    # pushed anyway is still refused before the controller's own push, and a
    # HEAD that is not descended from the pinned base is still not a rebase.
    if _ci_rebase_dir(working_dir) and _ci_unmerged_paths(working_dir):
        _ci_require_conflict_residue_closed(authority, working_dir)
        return "CONFLICT"
    _ci_require_residue_closed(authority, working_dir)
    return "REBASED"


# git writes conflict hunks with `conflict-marker-size` repeats of `<`, `|`, `=`
# and `>` at the start of a line. Runs of `<` and `>` are the two that
# essentially never occur in real content — a run of `=` is a markdown underline
# and a run of `|` is a table row — so those two alone are the predicate. Either
# one surviving means the hunk was never finished.
#
# A RUN of the character, NOT a fixed-width literal. `conflict-marker-size` is a
# per-path gitattribute and 7 is only its default: at size 10 git writes
# `<<<<<<<<<< HEAD`, and a boundary test anchored at offset 7 read the eighth `<`
# as the byte that had to be a space or a newline. The predicate answered "no
# markers" for a file still holding a raw conflict hunk, so
# `_validate_ci_conflict_outcome` returned RESOLVED and the controller staged it
# and force-pushed it.
#
# 7 is the floor rather than 1 because git honours a CONFIGURED size below the
# default too, and a shorter run is not distinguishable from ordinary content:
# `>>> ` opens every Python doctest line and `<<<` a shell here-string, so a
# lower floor would refuse the whole CONFLICT-RESOLVE arm on file shapes that
# carry no conflict at all. A sub-default `conflict-marker-size` therefore stays
# outside what this scan can see; anything at the default or above is caught.
CI_CONFLICT_MARKER_CHARS = (b"<", b">")
CI_CONFLICT_MARKER_MIN_RUN = 7


def _has_conflict_markers(path: str) -> bool:
    """True when the file still carries an unfinished git conflict hunk.

    Streamed line by line rather than read whole: the file is a repository
    source file of unbounded size, and a size cap here would have to choose
    between refusing a large legitimate file and skipping the scan on one.
    """
    try:
        with open(path, "rb") as handle:
            for line in handle:
                stripped = line.lstrip(b"\xef\xbb\xbf")
                for character in CI_CONFLICT_MARKER_CHARS:
                    # The run's own length, measured rather than assumed, so the
                    # boundary is tested AFTER however many repeats git wrote.
                    run = len(stripped) - len(stripped.lstrip(character))
                    if run < CI_CONFLICT_MARKER_MIN_RUN:
                        continue
                    if (
                        len(stripped) == run
                        or stripped[run:run + 1] in (b" ", b"\n", b"\r")
                    ):
                        return True
    except OSError:
        fail("git_state_unreadable")
    return False


# git's own binary heuristic (`buffer_is_binary`): a NUL byte anywhere in the
# leading 8000 bytes. Same constant, so "binary" means here what it means to the
# merge driver that produced the conflict.
CI_BINARY_SNIFF_BYTES = 8000


def _is_binary_worktree_file(path: str) -> bool:
    try:
        with open(path, "rb") as handle:
            return b"\x00" in handle.read(CI_BINARY_SNIFF_BYTES)
    except OSError:
        fail("git_state_unreadable")


def _validate_ci_conflict_outcome(
    authority: dict[str, Any], working_dir: str
) -> str:
    if not _ci_rebase_dir(working_dir):
        fail("ci_conflict_not_mid_rebase")
    target = authority["target_paths"][0]
    # NOT "is the path still `UU`". The resolver is forbidden `git add` — both
    # agents/conflict-resolver.md and the ci-conflicts prompt say so, and the
    # controller stages only AFTER this judgement returns, one fence later — so
    # the index legitimately still carries the unmerged entry for every resolver
    # that obeyed its instructions. Refusing on that made a correct resolution
    # indistinguishable from no resolution at all, and the arm could never reach
    # a green terminal.
    #
    # The observable that actually separates resolved from unresolved, given the
    # resolver may not touch the index, is the WORKTREE bytes. Deliberately
    # index-state agnostic: it judges the same whether the caller stages before
    # or after, so moving the `git add` can never silently vacate the check.
    target_absolute = os.path.join(working_dir, *target.split("/"))
    if not beneath(working_dir, target_absolute):
        fail("ci_conflict_scope_escape")
    if not os.path.isfile(target_absolute) or os.path.islink(target_absolute):
        # A `UU` path that no longer exists was deleted, not resolved.
        fail("ci_conflict_unresolved")
    # THE MARKER SCAN HAS NO ANSWER FOR A BINARY. For a binary path git records
    # `UU` in the index but writes the "ours" blob to the worktree with no
    # `<<<<<<<`/`>>>>>>>` in it, so a resolver that did nothing at all is
    # byte-for-byte indistinguishable from one that resolved — and
    # `agents/conflict-resolver.md` cannot meaningfully merge a binary either.
    # Passing it RESOLVED staged the "ours" side, committed it on
    # `rebase --continue`, and force-pushed the base branch's version of the
    # binary silently discarded. There is no liveness signal to recover here, so
    # the honest terminal is a refusal: a binary conflict is a human's job.
    if _is_binary_worktree_file(target_absolute):
        fail("ci_conflict_binary_unresolvable")
    if _has_conflict_markers(target_absolute):
        fail("ci_conflict_unresolved")
    # A conflict resolver rewrites conflicted files in place. It never creates
    # one, so a new untracked path is scope escape by construction — with the
    # single exemption every other verb in this file already grants, the run's
    # own evidence tree (`_require_untracked_confined_to_evidence`). Without
    # that exemption this refused every resolver in any repository that has not
    # ignored `.uberdev/`, because the controller's own per-child `input.json`
    # documents are untracked there.
    _require_untracked_confined_to_evidence(
        working_dir,
        _ci_evidence_dir(authority, working_dir),
        outside_failure="ci_conflict_scope_escape",
    )
    return "RESOLVED"


def validate_ci_mutation_outcome(
    *,
    launch_binding: bytes,
    status_sha256: str,
    result_sha256: str,
    working_dir: str,
    head_before: str,
    head_after: str,
    remote_head_sha: str = "",
) -> dict[str, Any]:
    """Judge one of the three MUTATING CI children against real git state.

    The edge is read from the binding, never taken as a parameter: a caller that
    could name the arm could name the cheap one. `head_before` crosses the
    Workflow boundary in the controller's sidecar, exactly as FIXER_HEAD_BEFORE
    does, so the child can never be the source of the value it is judged
    against.
    """
    value = _parse_json(launch_binding, "ci_binding_invalid")
    edge_id = value.get("edge_id") if isinstance(value, dict) else None
    if edge_id not in CI_MUTATION_EDGE_IDS:
        fail("ci_mutation_edge_unsupported")
    binding, authority = _load_ci_launch_binding(launch_binding, edge_id)
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    if (
        canonical_working != authority["working_dir"]
        or binding["worktree"] != canonical_working
    ):
        fail("validation_authority_mismatch")
    if (
        SHA1.fullmatch(head_before or "") is None
        or SHA1.fullmatch(head_after or "") is None
    ):
        fail("commit_identity_invalid")
    status_payload = capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    result_payload = capture_expected(
        binding["result_path"], result_sha256, 1, CI_RESULT_LIMIT
    )
    capture_expected(
        authority["input_path"], authority["input_sha256"], 1, CI_INPUT_LIMIT
    )
    rationale = ""
    if edge_id == "review_pr.ci.fix_code":
        status, rationale = _validate_ci_fix_code_outcome(
            authority, canonical_working, head_before, head_after, result_payload
        )
    elif edge_id == "review_pr.ci.rebase":
        status = _validate_ci_rebase_outcome(
            authority, canonical_working, head_before, head_after, remote_head_sha
        )
    else:
        status = _validate_ci_conflict_outcome(authority, canonical_working)
    return {
        "status": status,
        # Empty on every terminal but fix_code REFUSED. It is what the caller
        # renders into `data.subreason=ci_fixer_refused_<rationale>`.
        "rationale": rationale,
        "edge_id": edge_id,
        "head_before": head_before,
        "head_after": head_after,
        "status_sha256": status_sha256,
        "result_sha256": result_sha256,
        **_launch_identity(binding),
    }


def validate_ci_persistence_result(
    *, launch_binding: bytes, status_sha256: str, result_sha256: str
) -> dict[str, Any]:
    """Judge the review_pr.ci.defer_refusal child's terminal.

    It reuses `validate_persistence_result`'s fence parser and NOT its
    `count_phase2_deferred_blockers` recount: this stage's aggregate is the
    one-row `ci-refused-synthetic` envelope, which that recount cannot parse, and
    forcing it to would mean minting a schema-v2 document with fabricated
    findings just so a number could be compared to itself.
    """
    binding, authority = _load_ci_launch_binding(
        launch_binding, "review_pr.ci.defer_refusal"
    )
    capture_expected(
        authority["input_path"], authority["input_sha256"], 1, CI_INPUT_LIMIT
    )
    status_payload = capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    _validate_bound_child_status(binding, status_payload)
    result_payload = capture_expected(
        binding["result_path"], result_sha256, 1, PERSISTENCE_RESULT_LIMIT
    )
    parsed = _parse_persistence_result_document(result_payload)
    if parsed["status"] == "REFUSED":
        fail("persistence_result_refused")
    return {
        "status": parsed["status"],
        "halted": parsed["halted"],
        "halted_due_to_overflow": parsed["halted_due_to_overflow"],
        "by_severity_blocker": parsed["by_severity_blocker"],
        # The filed issue's URL, which the ci-defer arm records as
        # CI_REFUSED_ISSUE_URL. Empty when the child filed nothing.
        "created_url": parsed["created_url"],
        "aggregate_path": authority["input_path"],
        "aggregate_sha256": authority["input_sha256"],
        "status_sha256": status_sha256,
        "result_sha256": result_sha256,
        **_launch_identity(binding),
    }


def capture_standalone_terminal(
    *,
    launch_binding: bytes,
    disposition_path: str,
    applied_content_path: str,
) -> dict[str, Any]:
    """Freeze the waited child artifacts before semantic outcome validation."""

    binding = _load_fixer_launch_binding(launch_binding, "simplify.fix.phase2")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    canonical_content = _absolute_input(
        applied_content_path, "applied_content_path_invalid"
    )
    status_payload, _status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    result_payload, _result_identity = _capture_regular(
        binding["result_path"], 1, DISPOSITION_LIMIT
    )
    disposition_payload, _disposition_identity = _capture_regular(
        canonical_disposition, 1, DISPOSITION_LIMIT
    )
    content_payload, _content_identity = _capture_regular(
        canonical_content, 1, APPLIED_CONTENT_PLAN_LIMIT
    )
    return {
        "status_path": binding["status_path"],
        "status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "result_path": binding["result_path"],
        "result_sha256": hashlib.sha256(result_payload).hexdigest(),
        "disposition_path": canonical_disposition,
        "disposition_sha256": hashlib.sha256(disposition_payload).hexdigest(),
        "applied_content_path": canonical_content,
        "applied_content_sha256": hashlib.sha256(content_payload).hexdigest(),
    }


def _load_review_fixer_binding(payload: bytes) -> dict[str, Any]:
    value = _parse_json(payload, "fixer_binding_invalid")
    edge_id = value.get("edge_id") if isinstance(value, dict) else None
    if edge_id not in {"review_pr.fix.phase1", "review_pr.fix.phase2"}:
        fail("fixer_binding_invalid")
    return _load_fixer_launch_binding(payload, edge_id)


def capture_review_terminal(
    *,
    launch_binding: bytes,
    disposition_path: str,
    applied_content_path: str,
) -> dict[str, Any]:
    binding = _load_review_fixer_binding(launch_binding)
    authority = _load_authority(
        binding["authority_path"], binding["authority_sha256"]
    )
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    canonical_content = _absolute_input(
        applied_content_path, "applied_content_path_invalid"
    )
    expected_content = os.path.join(
        os.path.dirname(authority["findings_path"]),
        os.path.basename(binding["authority_path"]).replace(
            "code-fixer-authority-", "review-applied-content-"
        ),
    )
    if (
        canonical_disposition != authority["disposition_path"]
        or canonical_content != expected_content
    ):
        fail("validation_authority_mismatch")
    status_payload, _status_identity = _capture_regular(
        binding["status_path"], 1, 65_536
    )
    result_payload, _result_identity = _capture_regular(
        binding["result_path"], 1, DISPOSITION_LIMIT
    )
    disposition_payload, _disposition_identity = _capture_regular(
        canonical_disposition, 1, DISPOSITION_LIMIT
    )
    content_payload, _content_identity = _capture_regular(
        canonical_content, 1, APPLIED_CONTENT_PLAN_LIMIT
    )
    return {
        "status_path": binding["status_path"],
        "status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "result_path": binding["result_path"],
        "result_sha256": hashlib.sha256(result_payload).hexdigest(),
        "disposition_path": canonical_disposition,
        "disposition_sha256": hashlib.sha256(disposition_payload).hexdigest(),
        "applied_content_path": canonical_content,
        "applied_content_sha256": hashlib.sha256(content_payload).hexdigest(),
    }


def _parse_fixer_result(
    payload: bytes, expected_phase: Phase, expected_type: CommitType
) -> dict[str, Any]:
    try:
        text = payload.decode("utf-8")
    except UnicodeError:
        fail("fixer_result_invalid")
    document = re.fullmatch(r"```yaml\n(.*)\n```\n?", text, re.DOTALL)
    if document is None or "\r" in document.group(1):
        fail("fixer_result_invalid")
    lines = document.group(1).split("\n")
    if len(lines) < 5:
        fail("fixer_result_invalid")
    status_match = re.fullmatch(
        r"status: (APPLIED|NO_FIXES_NEEDED|REFUSED)", lines[0]
    )
    if status_match is None or lines[1] != f"phase: {expected_phase}":
        fail("fixer_result_invalid")
    status_value = status_match.group(1)
    index = 2
    commits: list[dict[str, str]] = []
    if status_value == "APPLIED":
        if index + 3 >= len(lines) or lines[index] != "commits:":
            fail("fixer_result_invalid")
        sha_match = re.fullmatch(r"  - sha: ([0-9a-f]{40})", lines[index + 1])
        summary_line = lines[index + 3]
        if (
            sha_match is None
            or lines[index + 2] != f"    type: {expected_type}"
            or not summary_line.startswith("    summary: ")
            or not summary_line.removeprefix("    summary: ")
        ):
            fail("fixer_result_invalid")
        commits.append(
            {
                "sha": sha_match.group(1),
                "type": expected_type,
                "summary": summary_line.removeprefix("    summary: "),
            }
        )
        index += 4
    else:
        if lines[index] != "commits: []":
            fail("fixer_result_invalid")
        index += 1
    rows: list[dict[str, Any]] = []
    if index >= len(lines):
        fail("fixer_result_invalid")
    if lines[index] == "findings_disposition: []":
        index += 1
    elif lines[index] == "findings_disposition:":
        index += 1
        while index < len(lines) and lines[index].startswith("  - finding_index: "):
            if index + 5 >= len(lines):
                fail("fixer_result_invalid")
            finding_match = re.fullmatch(
                r"  - finding_index: ([1-9][0-9]{0,8})", lines[index]
            )
            summary_match = re.fullmatch(
                r"    summary_sha256: ([0-9a-f]{64})", lines[index + 2]
            )
            if (
                finding_match is None
                or int(finding_match.group(1)) != len(rows) + 1
                or not lines[index + 1].startswith("    location: ")
                or summary_match is None
                or not lines[index + 3].startswith("    disposition: ")
                or not lines[index + 4].startswith("    behavior_tag: ")
                or not lines[index + 5].startswith("    reason: ")
            ):
                fail("fixer_result_invalid")
            location = lines[index + 1].removeprefix("    location: ")
            _repo_path_from_location(location)
            disposition = lines[index + 3].removeprefix("    disposition: ")
            behavior = lines[index + 4].removeprefix("    behavior_tag: ")
            reason = lines[index + 5].removeprefix("    reason: ")
            applied_behaviors = (
                {"preserve", "change"} if expected_phase == "phase1" else {"preserve"}
            )
            if (
                disposition not in {"APPLIED", "SKIPPED", "REFUSED"}
                or (disposition == "APPLIED" and behavior not in applied_behaviors)
                or (disposition != "APPLIED" and behavior != "n/a")
                or not reason
                or reason.strip() != reason
                or len(reason) > 1024
                or any(ord(character) < 32 or ord(character) == 127 for character in reason)
            ):
                fail("fixer_result_invalid")
            rows.append(
                {
                    "finding_index": int(finding_match.group(1)),
                    "location": location,
                    "summary_sha256": summary_match.group(1),
                    "disposition": disposition,
                    "behavior_tag": behavior,
                    "reason": reason,
                }
            )
            index += 6
    else:
        fail("fixer_result_invalid")
    if index >= len(lines) or lines[index] != "risks: []" or index + 1 != len(lines):
        fail("fixer_result_invalid")
    if (status_value == "APPLIED") != bool(commits):
        fail("fixer_result_invalid")
    return {"status": status_value, "commits": commits, "rows": rows}


def validate_standalone_outcome(
    *,
    launch_binding: bytes,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    applied_content_path: str,
    applied_content_sha256: str,
    status_sha256: str,
    result_sha256: str,
    working_dir: str,
    head_before: str,
    head_after: str,
) -> dict[str, Any]:
    binding = _load_fixer_launch_binding(launch_binding, "simplify.fix.phase2")
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    if authority["edge_id"] != "simplify.fix.phase2":
        fail("standalone_authority_required")
    if (
        canonical_authority != binding["authority_path"]
        or authority_sha256 != binding["authority_sha256"]
    ):
        fail("fixer_binding_authority_mismatch")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
        or binding["worktree"] != canonical_working
    ):
        fail("validation_authority_mismatch")
    snapshot = _recapture_sources(authority)
    if snapshot is None:
        fail("standalone_authority_required")
    status_payload = capture_expected(binding["status_path"], status_sha256, 1, 65_536)
    result_payload = capture_expected(
        binding["result_path"], result_sha256, 1, DISPOSITION_LIMIT
    )
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    _validate_bound_child_status(binding, status_payload)
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    content_plan = _load_applied_content_plan(
        applied_content_path,
        applied_content_sha256,
        authority,
        authority_sha256,
        disposition_sha256,
        applied_paths,
    )
    parsed_result = _parse_fixer_result(result_payload, "phase2", "refactor")
    if parsed_result["rows"] != disposition["findings_disposition"]:
        fail("fixer_result_disposition_mismatch")
    dispositions = [row["disposition"] for row in disposition["findings_disposition"]]
    derived_status = (
        "APPLIED"
        if applied_paths
        else "REFUSED"
        if "REFUSED" in dispositions
        else "NO_FIXES_NEEDED"
    )
    if parsed_result["status"] != derived_status:
        fail("fixer_result_status_mismatch")
    if (
        SHA1.fullmatch(head_before or "") is None
        or SHA1.fullmatch(head_after or "") is None
        or head_before != snapshot["head_sha"]
    ):
        fail("commit_identity_invalid")
    if derived_status == "APPLIED":
        if (
            len(parsed_result["commits"]) != 1
            or parsed_result["commits"][0]["sha"] != head_after
        ):
            fail("fixer_result_commit_mismatch")
        commit_receipt = _validate_standalone_commit_state(
            authority, snapshot, disposition, head_before, head_after
        )
        for row in content_plan["applied"]:
            committed = _tree_entry(canonical_working, head_after, row["path"])
            if committed != {"mode": row["git_mode"], "oid": row["git_oid"]}:
                fail("applied_content_commit_mismatch")
        declared_tip = head_after
    else:
        if parsed_result["commits"] or head_after != head_before:
            fail("fixer_result_commit_mismatch")
        _require_snapshot_current(snapshot)
        commit_receipt = None
        declared_tip = ""
    return {
        "status": derived_status,
        "declared_tip": declared_tip,
        **_launch_identity(binding),
        "status_sha256": status_sha256,
        "result_sha256": result_sha256,
        "disposition_sha256": disposition_sha256,
        "applied_content_sha256": applied_content_sha256,
        "commit": commit_receipt,
    }


def validate_review_outcome(
    *,
    launch_binding: bytes,
    authority_path: str,
    authority_sha256: str,
    disposition_path: str,
    disposition_sha256: str,
    applied_content_path: str,
    applied_content_sha256: str,
    status_sha256: str,
    result_sha256: str,
    working_dir: str,
    head_before: str,
    head_after: str,
) -> dict[str, Any]:
    binding = _load_review_fixer_binding(launch_binding)
    canonical_authority = _absolute_input(authority_path, "authority_path_invalid")
    authority = _load_authority(canonical_authority, authority_sha256)
    authority["authority_path"] = canonical_authority
    if authority["edge_id"] not in {
        "review_pr.fix.phase1",
        "review_pr.fix.phase2",
    }:
        fail("review_authority_required")
    canonical_working = _absolute_input(working_dir, "working_dir_invalid")
    canonical_disposition = _absolute_input(
        disposition_path, "disposition_path_invalid"
    )
    if (
        canonical_authority != binding["authority_path"]
        or authority_sha256 != binding["authority_sha256"]
        or canonical_working != authority["working_dir"]
        or canonical_disposition != authority["disposition_path"]
        or binding["worktree"] != canonical_working
    ):
        fail("validation_authority_mismatch")
    _recapture_sources(authority, expected_range_head=authority["parent_sha"])
    status_payload = capture_expected(
        binding["status_path"], status_sha256, 1, 65_536
    )
    result_payload = capture_expected(
        binding["result_path"], result_sha256, 1, DISPOSITION_LIMIT
    )
    disposition_payload = capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    _validate_bound_child_status(binding, status_payload)
    disposition = _parse_json(disposition_payload, "disposition_json_invalid")
    applied_paths = _validate_disposition(disposition, authority)
    content_plan = _load_applied_content_plan(
        applied_content_path,
        applied_content_sha256,
        authority,
        authority_sha256,
        disposition_sha256,
        applied_paths,
    )
    parsed_result = _parse_fixer_result(
        result_payload, authority["phase"], authority["commit_type"]
    )
    if parsed_result["rows"] != disposition["findings_disposition"]:
        fail("fixer_result_disposition_mismatch")
    dispositions = [
        row["disposition"] for row in disposition["findings_disposition"]
    ]
    derived_status = (
        "APPLIED"
        if applied_paths
        else "REFUSED"
        if "REFUSED" in dispositions
        else "NO_FIXES_NEEDED"
    )
    if parsed_result["status"] != derived_status:
        fail("fixer_result_status_mismatch")
    if (
        SHA1.fullmatch(head_before or "") is None
        or SHA1.fullmatch(head_after or "") is None
        or head_before != authority["parent_sha"]
    ):
        fail("commit_identity_invalid")
    if derived_status == "APPLIED":
        if (
            len(parsed_result["commits"]) != 1
            or parsed_result["commits"][0]["sha"] != head_after
        ):
            fail("fixer_result_commit_mismatch")
        current_sha, current_tree = _head_identity(canonical_working)
        if current_sha != head_after:
            fail("commit_head_mismatch")
        commit_receipt = _validate_review_commit_state(
            authority,
            disposition,
            content_plan,
            head_before,
            head_after,
            current_tree,
        )
        declared_tip = head_after
    else:
        if parsed_result["commits"] or head_after != head_before:
            fail("fixer_result_commit_mismatch")
        _require_review_edit_state(authority, ())
        commit_receipt = None
        declared_tip = ""
    capture_expected(binding["status_path"], status_sha256, 1, 65_536)
    capture_expected(binding["result_path"], result_sha256, 1, DISPOSITION_LIMIT)
    capture_expected(
        canonical_disposition, disposition_sha256, 1, DISPOSITION_LIMIT
    )
    capture_expected(
        applied_content_path,
        applied_content_sha256,
        1,
        APPLIED_CONTENT_PLAN_LIMIT,
    )
    _recapture_sources(authority, expected_range_head=authority["parent_sha"])
    return {
        "status": derived_status,
        "declared_tip": declared_tip,
        **_launch_identity(binding),
        "status_sha256": status_sha256,
        "result_sha256": result_sha256,
        "disposition_sha256": disposition_sha256,
        "applied_content_sha256": applied_content_sha256,
        "commit": commit_receipt,
    }


class _ContractArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> NoReturn:
        fail("arguments_invalid")


def _parser() -> argparse.ArgumentParser:
    parser = _ContractArgumentParser(add_help=False)
    commands = parser.add_subparsers(dest="command", required=True)
    digest = commands.add_parser("digest", add_help=False)
    digest.add_argument("--path", required=True)
    digest.add_argument("--minimum", type=int, required=True)
    digest.add_argument("--maximum", type=int, required=True)
    encode = commands.add_parser("encode-aggregate", add_help=False)
    encode.add_argument("--phase", choices=("phase1", "phase2"), required=True)
    # No arguments: the whole request is one JSON object on stdin, so a rule
    # window never crosses the platform argv-size boundary.
    commands.add_parser("classify-convention-citation", add_help=False)
    snapshot = commands.add_parser("snapshot-standalone", add_help=False)
    snapshot.add_argument("--working-dir", required=True)
    snapshot.add_argument("--evidence-dir", required=True)
    snapshot.add_argument("--diff-path", required=True)
    snapshot.add_argument("--snapshot-path", required=True)
    prepare = commands.add_parser("prepare-authority", add_help=False)
    prepare.add_argument("--edge-id", required=True)
    prepare.add_argument("--policy-phase", required=True)
    prepare.add_argument("--findings-path", required=True)
    prepare.add_argument("--findings-sha256", required=True)
    prepare.add_argument("--commit-range-path", required=True)
    prepare.add_argument("--commit-range-sha256", required=True)
    prepare.add_argument("--working-dir", required=True)
    prepare.add_argument("--disposition-path", required=True)
    prepare.add_argument("--authority-output-path")
    prepare_standalone = commands.add_parser(
        "prepare-standalone-authority", add_help=False
    )
    prepare_standalone.add_argument("--edge-id", required=True)
    prepare_standalone.add_argument("--policy-phase", required=True)
    prepare_standalone.add_argument("--findings-path", required=True)
    prepare_standalone.add_argument("--findings-sha256", required=True)
    prepare_standalone.add_argument("--snapshot-path", required=True)
    prepare_standalone.add_argument("--snapshot-sha256", required=True)
    prepare_standalone.add_argument("--working-dir", required=True)
    prepare_standalone.add_argument("--disposition-path", required=True)
    consume = commands.add_parser("consume-authority", add_help=False)
    consume.add_argument("--edge-id", required=True)
    consume.add_argument("--policy-phase", required=True)
    consume.add_argument("--authority-path", required=True)
    consume.add_argument("--authority-sha256", required=True)
    consume.add_argument("--findings-path", required=True)
    consume.add_argument("--findings-sha256", required=True)
    consume.add_argument("--working-dir", required=True)
    consume.add_argument("--disposition-path", required=True)
    consume.add_argument("--commit-range-path", default="")
    consume.add_argument("--commit-range-sha256", default="")
    consume.add_argument("--snapshot-path", default="")
    consume.add_argument("--snapshot-sha256", default="")
    publish = commands.add_parser("publish-disposition", add_help=False)
    publish.add_argument("--authority-path", required=True)
    publish.add_argument("--authority-sha256", required=True)
    publish.add_argument("--disposition-path", required=True)
    review_only = commands.add_parser(
        "publish-review-only-disposition", add_help=False
    )
    review_only.add_argument("--findings-path", required=True)
    review_only.add_argument("--findings-sha256", required=True)
    review_only.add_argument("--snapshot-path", required=True)
    review_only.add_argument("--snapshot-sha256", required=True)
    review_only.add_argument("--working-dir", required=True)
    review_only.add_argument("--disposition-path", required=True)
    deferred_blockers = commands.add_parser(
        "count-phase2-deferred-blockers", add_help=False
    )
    deferred_blockers.add_argument("--findings-path", required=True)
    deferred_blockers.add_argument("--findings-sha256", required=True)
    deferred_blockers.add_argument("--disposition-path", required=True)
    deferred_blockers.add_argument("--disposition-sha256", required=True)
    verification_claims = commands.add_parser(
        "project-verification-claims", add_help=False
    )
    verification_claims.add_argument("--findings-path", required=True)
    verification_claims.add_argument("--findings-sha256", required=True)
    verification_claims.add_argument("--disposition-path", required=True)
    verification_claims.add_argument("--disposition-sha256", required=True)
    verification_claims.add_argument("--claims-dir", required=True)
    publish_verification_parser = commands.add_parser(
        "publish-verification", add_help=False
    )
    publish_verification_parser.add_argument("--findings-path", required=True)
    publish_verification_parser.add_argument("--findings-sha256", required=True)
    publish_verification_parser.add_argument("--disposition-path", required=True)
    publish_verification_parser.add_argument("--disposition-sha256", required=True)
    publish_verification_parser.add_argument("--verification-path", required=True)
    publish_verification_parser.add_argument("--threshold", required=True)
    persistence = commands.add_parser(
        "validate-persistence-result", add_help=False
    )
    persistence.add_argument("--launch-binding-json", required=True)
    persistence.add_argument("--status-sha256", required=True)
    persistence.add_argument("--result-sha256", required=True)
    validate = commands.add_parser("validate-staged", add_help=False)
    validate.add_argument("--authority-path", required=True)
    validate.add_argument("--authority-sha256", required=True)
    validate.add_argument("--disposition-path", required=True)
    validate.add_argument("--disposition-sha256", required=True)
    validate.add_argument("--working-dir", required=True)
    standalone_commit = commands.add_parser("commit-standalone", add_help=False)
    standalone_commit.add_argument("--authority-path", required=True)
    standalone_commit.add_argument("--authority-sha256", required=True)
    standalone_commit.add_argument("--disposition-path", required=True)
    standalone_commit.add_argument("--disposition-sha256", required=True)
    standalone_commit.add_argument("--applied-content-path", required=True)
    standalone_commit.add_argument("--applied-content-sha256", required=True)
    standalone_commit.add_argument("--working-dir", required=True)
    review_commit = commands.add_parser("commit-review", add_help=False)
    review_commit.add_argument("--authority-path", required=True)
    review_commit.add_argument("--authority-sha256", required=True)
    review_commit.add_argument("--disposition-path", required=True)
    review_commit.add_argument("--disposition-sha256", required=True)
    review_commit.add_argument("--applied-content-path", required=True)
    review_commit.add_argument("--applied-content-sha256", required=True)
    review_commit.add_argument("--working-dir", required=True)
    commit = commands.add_parser("validate-commit", add_help=False)
    commit.add_argument("--authority-path", required=True)
    commit.add_argument("--authority-sha256", required=True)
    commit.add_argument("--disposition-path", required=True)
    commit.add_argument("--disposition-sha256", required=True)
    commit.add_argument("--working-dir", required=True)
    commit.add_argument("--parent-sha", required=True)
    commit.add_argument("--commit-sha", required=True)
    commit.add_argument("--staged-tree-sha", required=True)
    commit.add_argument("--expected-message-sha256", required=True)
    message_digest = commands.add_parser("commit-message-digest", add_help=False)
    message_digest.add_argument("--working-dir", required=True)
    message_digest.add_argument("--commit-sha", required=True)
    residue = commands.add_parser("validate-residue", add_help=False)
    residue.add_argument("--working-dir", required=True)
    residue.add_argument("--evidence-dir", required=True)
    failed_return = commands.add_parser("validate-failed-return", add_help=False)
    failed_return.add_argument("--working-dir", required=True)
    failed_return.add_argument("--evidence-dir", required=True)
    failed_return.add_argument("--head-before", required=True)
    failed_return.add_argument("--snapshot-path")
    failed_return.add_argument("--snapshot-sha256")
    bind = commands.add_parser("bind-launch-receipt", add_help=False)
    bind.add_argument("--edge-id", required=True)
    bind.add_argument("--instance-id", required=True)
    bind.add_argument("--result-path", required=True)
    bind.add_argument("--status-path", required=True)
    bind.add_argument("--working-dir", required=True)
    bind_fixer = commands.add_parser("bind-fixer-launch-receipt", add_help=False)
    bind_fixer.add_argument("--edge-id", required=True)
    bind_fixer.add_argument("--instance-id", required=True)
    bind_fixer.add_argument("--result-path", required=True)
    bind_fixer.add_argument("--status-path", required=True)
    bind_fixer.add_argument("--working-dir", required=True)
    bind_fixer.add_argument("--authority-path", required=True)
    bind_fixer.add_argument("--authority-sha256", required=True)
    # A Workflow() call issues no dispatch receipt, so this verb takes no stdin
    # and derives its binding entirely from controller-supplied scalars. The
    # nonce is minted by the caller BEFORE the Workflow call -- the only moment
    # a binding can be created that the child had no chance to influence.
    bind_workflow = commands.add_parser("bind-workflow-launch", add_help=False)
    bind_workflow.add_argument("--edge-id", required=True)
    bind_workflow.add_argument("--instance-id", required=True)
    bind_workflow.add_argument("--run-nonce", required=True)
    bind_workflow.add_argument("--result-path", required=True)
    bind_workflow.add_argument("--status-path", required=True)
    bind_workflow.add_argument("--working-dir", required=True)
    # The fixer and defer twins of bind-workflow-launch. Same no-stdin rule:
    # there is no dispatch receipt to read, and the nonce is minted before the
    # Workflow call. Each still pins everything its detached twin pins.
    bind_workflow_fixer = commands.add_parser(
        "bind-workflow-fixer-launch", add_help=False
    )
    bind_workflow_fixer.add_argument("--edge-id", required=True)
    bind_workflow_fixer.add_argument("--instance-id", required=True)
    bind_workflow_fixer.add_argument("--run-nonce", required=True)
    bind_workflow_fixer.add_argument("--result-path", required=True)
    bind_workflow_fixer.add_argument("--status-path", required=True)
    bind_workflow_fixer.add_argument("--working-dir", required=True)
    bind_workflow_fixer.add_argument("--authority-path", required=True)
    bind_workflow_fixer.add_argument("--authority-sha256", required=True)
    bind_workflow_persistence = commands.add_parser(
        "bind-workflow-persistence-launch", add_help=False
    )
    bind_workflow_persistence.add_argument("--instance-id", required=True)
    bind_workflow_persistence.add_argument("--run-nonce", required=True)
    bind_workflow_persistence.add_argument("--result-path", required=True)
    bind_workflow_persistence.add_argument("--status-path", required=True)
    bind_workflow_persistence.add_argument("--working-dir", required=True)
    bind_workflow_persistence.add_argument("--aggregate-path", required=True)
    bind_workflow_persistence.add_argument("--aggregate-sha256", required=True)
    bind_workflow_persistence.add_argument("--disposition-path", required=True)
    bind_workflow_persistence.add_argument("--disposition-sha256", required=True)
    bind_workflow_persistence.add_argument(
        "--expected-deferred-blockers", type=int, required=True
    )
    bind_workflow_persistence.add_argument(
        "--require-clean", choices=("0", "1"), required=True
    )
    bind_persistence = commands.add_parser(
        "bind-persistence-launch-receipt", add_help=False
    )
    bind_persistence.add_argument("--edge-id", required=True)
    bind_persistence.add_argument("--instance-id", required=True)
    bind_persistence.add_argument("--result-path", required=True)
    bind_persistence.add_argument("--status-path", required=True)
    bind_persistence.add_argument("--working-dir", required=True)
    bind_persistence.add_argument("--aggregate-path", required=True)
    bind_persistence.add_argument("--aggregate-sha256", required=True)
    bind_persistence.add_argument("--disposition-path", required=True)
    bind_persistence.add_argument("--disposition-sha256", required=True)
    bind_persistence.add_argument(
        "--expected-deferred-blockers", type=int, required=True
    )
    bind_persistence.add_argument(
        "--require-clean", choices=("0", "1"), required=True
    )
    terminal = commands.add_parser("capture-standalone-terminal", add_help=False)
    terminal.add_argument("--launch-binding-json", required=True)
    terminal.add_argument("--disposition-path", required=True)
    terminal.add_argument("--applied-content-path", required=True)
    review_terminal = commands.add_parser("capture-review-terminal", add_help=False)
    review_terminal.add_argument("--launch-binding-json", required=True)
    review_terminal.add_argument("--disposition-path", required=True)
    review_terminal.add_argument("--applied-content-path", required=True)
    unapplied_terminal = commands.add_parser(
        "publish-unapplied-terminal", add_help=False
    )
    unapplied_terminal.add_argument("--launch-binding-json", required=True)
    unapplied_terminal.add_argument("--authority-path", required=True)
    unapplied_terminal.add_argument("--authority-sha256", required=True)
    unapplied_terminal.add_argument("--disposition-path", required=True)
    unapplied_terminal.add_argument("--applied-content-path", required=True)
    unapplied_terminal.add_argument("--working-dir", required=True)
    unapplied_terminal.add_argument("--head-before", required=True)
    unapplied_terminal.add_argument("--head-after", required=True)
    persistence_terminal = commands.add_parser(
        "capture-persistence-terminal", add_help=False
    )
    persistence_terminal.add_argument("--launch-binding-json", required=True)
    bound_child = commands.add_parser("capture-bound-child", add_help=False)
    bound_child.add_argument("--launch-binding-json", required=True)
    bound_child.add_argument("--edge-id", required=True)
    # ---- Phase 3 CI (#383) -------------------------------------------------
    ci_authority = commands.add_parser("prepare-ci-authority", add_help=False)
    ci_authority.add_argument("--edge-id", required=True)
    ci_authority.add_argument("--pr-number", type=int, required=True)
    ci_authority.add_argument("--run-id", required=True)
    ci_authority.add_argument("--head-sha", required=True)
    ci_authority.add_argument("--working-dir", required=True)
    ci_authority.add_argument("--input-path", required=True)
    ci_authority.add_argument("--input-sha256", required=True)
    ci_authority.add_argument("--authority-output-path", required=True)
    ci_authority.add_argument("--failure-class", default="")
    ci_authority.add_argument("--signal-anchor", default="")
    ci_authority.add_argument("--parent-sha", default="")
    ci_authority.add_argument("--parent-tree-sha", default="")
    ci_authority.add_argument("--base-sha", default="")
    ci_authority.add_argument("--base-tip-sha", default="")
    ci_authority.add_argument("--lease-sha", default="")
    ci_authority.add_argument("--pr-branch", default="")
    ci_authority.add_argument("--base-branch", default="")
    # At most one target path (resolve_conflict's single conflicted file), so
    # `append` cannot smuggle a wider scope than the authority shape permits.
    ci_authority.add_argument("--target-path", action="append", default=[])
    read_ci_member = commands.add_parser("read-ci-authority-member", add_help=False)
    read_ci_member.add_argument("--authority-path", required=True)
    read_ci_member.add_argument("--authority-sha256", required=True)
    read_ci_member.add_argument("--member", required=True)
    list_unmerged = commands.add_parser("list-ci-unmerged-paths", add_help=False)
    list_unmerged.add_argument("--working-dir", required=True)
    bind_ci = commands.add_parser("bind-workflow-ci-launch", add_help=False)
    bind_ci.add_argument("--edge-id", required=True)
    bind_ci.add_argument("--instance-id", required=True)
    bind_ci.add_argument("--run-nonce", required=True)
    bind_ci.add_argument("--result-path", required=True)
    bind_ci.add_argument("--status-path", required=True)
    bind_ci.add_argument("--working-dir", required=True)
    bind_ci.add_argument("--ci-authority-path", required=True)
    bind_ci.add_argument("--ci-authority-sha256", required=True)
    ci_terminal = commands.add_parser("capture-ci-terminal", add_help=False)
    ci_terminal.add_argument("--launch-binding-json", required=True)
    ci_terminal.add_argument("--edge-id", required=True)
    ci_classification = commands.add_parser(
        "validate-ci-classification", add_help=False
    )
    ci_classification.add_argument("--launch-binding-json", required=True)
    ci_classification.add_argument("--status-sha256", required=True)
    ci_classification.add_argument("--result-sha256", required=True)
    ci_mutation = commands.add_parser(
        "validate-ci-mutation-outcome", add_help=False
    )
    ci_mutation.add_argument("--launch-binding-json", required=True)
    ci_mutation.add_argument("--status-sha256", required=True)
    ci_mutation.add_argument("--result-sha256", required=True)
    ci_mutation.add_argument("--working-dir", required=True)
    ci_mutation.add_argument("--head-before", required=True)
    ci_mutation.add_argument("--head-after", required=True)
    ci_mutation.add_argument("--remote-head-sha", default="")
    ci_persistence = commands.add_parser(
        "validate-ci-persistence-result", add_help=False
    )
    ci_persistence.add_argument("--launch-binding-json", required=True)
    ci_persistence.add_argument("--status-sha256", required=True)
    ci_persistence.add_argument("--result-sha256", required=True)
    outcome = commands.add_parser("validate-standalone-outcome", add_help=False)
    outcome.add_argument("--launch-binding-json", required=True)
    outcome.add_argument("--authority-path", required=True)
    outcome.add_argument("--authority-sha256", required=True)
    outcome.add_argument("--disposition-path", required=True)
    outcome.add_argument("--disposition-sha256", required=True)
    outcome.add_argument("--applied-content-path", required=True)
    outcome.add_argument("--applied-content-sha256", required=True)
    outcome.add_argument("--status-sha256", required=True)
    outcome.add_argument("--result-sha256", required=True)
    outcome.add_argument("--working-dir", required=True)
    outcome.add_argument("--head-before", required=True)
    outcome.add_argument("--head-after", required=True)
    review_outcome = commands.add_parser("validate-review-outcome", add_help=False)
    review_outcome.add_argument("--launch-binding-json", required=True)
    review_outcome.add_argument("--authority-path", required=True)
    review_outcome.add_argument("--authority-sha256", required=True)
    review_outcome.add_argument("--disposition-path", required=True)
    review_outcome.add_argument("--disposition-sha256", required=True)
    review_outcome.add_argument("--applied-content-path", required=True)
    review_outcome.add_argument("--applied-content-sha256", required=True)
    review_outcome.add_argument("--status-sha256", required=True)
    review_outcome.add_argument("--result-sha256", required=True)
    review_outcome.add_argument("--working-dir", required=True)
    review_outcome.add_argument("--head-before", required=True)
    review_outcome.add_argument("--head-after", required=True)
    return parser


def _compact(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _write_raw_stream(stream: Any, payload: bytes) -> bool:
    previous_mode: int | None = None
    succeeded = False
    try:
        descriptor = stream.fileno()
        if (
            not isinstance(descriptor, int)
            or isinstance(descriptor, bool)
            or descriptor < 0
        ):
            raise ValueError("invalid stream descriptor")
        if os.name == "nt":
            import msvcrt

            previous_mode = msvcrt.setmode(descriptor, os.O_BINARY)
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if (
                not isinstance(written, int)
                or isinstance(written, bool)
                or written <= 0
                or written > len(remaining)
            ):
                raise OSError("incomplete stream write")
            remaining = remaining[written:]
        succeeded = True
    except (AttributeError, OSError, TypeError, ValueError):
        succeeded = False
    finally:
        if previous_mode is not None:
            try:
                msvcrt.setmode(descriptor, previous_mode)
            except (AttributeError, OSError, TypeError, ValueError):
                succeeded = False
    return succeeded


def _write_cli_diagnostic(reason: str) -> None:
    try:
        payload = (reason + "\n").encode("ascii")
    except (AttributeError, UnicodeError):
        payload = b"contract_failure\n"
    _write_raw_stream(sys.stderr, payload)


def main() -> int:
    try:
        arguments = _parser().parse_args()
        if arguments.command == "digest":
            payload, _identity = _capture_regular(
                arguments.path, arguments.minimum, arguments.maximum
            )
            output = hashlib.sha256(payload).hexdigest()
        elif arguments.command == "encode-aggregate":
            candidate = sys.stdin.buffer.read(FINDINGS_LIMIT + 1)
            if len(candidate) > FINDINGS_LIMIT:
                fail("findings_size_invalid")
            output = encode_aggregate(
                _parse_json(candidate, "findings_schema_invalid"), arguments.phase
            ).decode("utf-8")
        elif arguments.command == "classify-convention-citation":
            candidate = sys.stdin.buffer.read(CONVENTION_REQUEST_LIMIT + 1)
            if len(candidate) > CONVENTION_REQUEST_LIMIT:
                fail("convention_request_size_invalid")
            output = _compact(
                classify_convention_citation(
                    _parse_json(candidate, "convention_request_invalid")
                )
            )
        elif arguments.command == "snapshot-standalone":
            output = _compact(
                capture_standalone_snapshot(
                    working_dir=arguments.working_dir,
                    evidence_dir=arguments.evidence_dir,
                    diff_path=arguments.diff_path,
                    snapshot_path=arguments.snapshot_path,
                )
            )
        elif arguments.command == "prepare-authority":
            output = _compact(
                prepare_authority(
                    edge_id=arguments.edge_id,
                    policy_phase=arguments.policy_phase,
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    commit_range_path=arguments.commit_range_path,
                    commit_range_sha256=arguments.commit_range_sha256,
                    working_dir=arguments.working_dir,
                    disposition_path=arguments.disposition_path,
                    authority_output_path=arguments.authority_output_path,
                )
            )
        elif arguments.command == "prepare-standalone-authority":
            output = _compact(
                prepare_standalone_authority(
                    edge_id=arguments.edge_id,
                    policy_phase=arguments.policy_phase,
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    snapshot_path=arguments.snapshot_path,
                    snapshot_sha256=arguments.snapshot_sha256,
                    working_dir=arguments.working_dir,
                    disposition_path=arguments.disposition_path,
                )
            )
        elif arguments.command == "consume-authority":
            output = _compact(
                consume_authority(
                    edge_id=arguments.edge_id,
                    policy_phase=arguments.policy_phase,
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    working_dir=arguments.working_dir,
                    disposition_path=arguments.disposition_path,
                    commit_range_path=arguments.commit_range_path,
                    commit_range_sha256=arguments.commit_range_sha256,
                    snapshot_path=arguments.snapshot_path,
                    snapshot_sha256=arguments.snapshot_sha256,
                )
            )
        elif arguments.command == "publish-disposition":
            candidate = sys.stdin.buffer.read(DISPOSITION_LIMIT + 1)
            if len(candidate) > DISPOSITION_LIMIT:
                fail("disposition_size_invalid")
            output = _compact(
                publish_disposition(
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    candidate=candidate,
                )
            )
        elif arguments.command == "publish-review-only-disposition":
            output = _compact(
                publish_review_only_disposition(
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    snapshot_path=arguments.snapshot_path,
                    snapshot_sha256=arguments.snapshot_sha256,
                    working_dir=arguments.working_dir,
                    disposition_path=arguments.disposition_path,
                )
            )
        elif arguments.command == "count-phase2-deferred-blockers":
            output = str(
                count_phase2_deferred_blockers(
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                )
            )
        elif arguments.command == "project-verification-claims":
            output = _compact(
                project_verification_claims(
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    claims_dir=arguments.claims_dir,
                )
            )
        elif arguments.command == "publish-verification":
            if re.fullmatch(r"0|[1-9][0-9]{0,2}", arguments.threshold) is None:
                fail("verification_threshold_invalid")
            candidate = sys.stdin.buffer.read(VERIFICATION_LIMIT + 1)
            if len(candidate) > VERIFICATION_LIMIT:
                fail("verification_size_invalid")
            output = _compact(
                publish_verification(
                    findings_path=arguments.findings_path,
                    findings_sha256=arguments.findings_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    verification_path=arguments.verification_path,
                    threshold=int(arguments.threshold),
                    candidate=candidate,
                )
            )
        elif arguments.command == "validate-persistence-result":
            output = _compact(
                validate_persistence_result(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                )
            )
        elif arguments.command == "validate-staged":
            output = _compact(
                validate_staged(
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    working_dir=arguments.working_dir,
                )
            )
        elif arguments.command == "commit-standalone":
            output = _compact(
                commit_standalone(
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    applied_content_path=arguments.applied_content_path,
                    applied_content_sha256=arguments.applied_content_sha256,
                    working_dir=arguments.working_dir,
                )
            )
        elif arguments.command == "commit-review":
            output = _compact(
                commit_review(
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    applied_content_path=arguments.applied_content_path,
                    applied_content_sha256=arguments.applied_content_sha256,
                    working_dir=arguments.working_dir,
                )
            )
        elif arguments.command == "validate-commit":
            output = _compact(
                validate_commit(
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    working_dir=arguments.working_dir,
                    parent_sha=arguments.parent_sha,
                    commit_sha=arguments.commit_sha,
                    staged_tree_sha=arguments.staged_tree_sha,
                    expected_message_sha256=arguments.expected_message_sha256,
                )
            )
        elif arguments.command == "commit-message-digest":
            canonical_working = _absolute_input(
                arguments.working_dir, "working_dir_invalid"
            )
            _require_repository(canonical_working)
            output = _commit_message_sha256(
                canonical_working, arguments.commit_sha
            )
        elif arguments.command == "bind-launch-receipt":
            receipt = sys.stdin.buffer.read(65_537)
            output = _compact(
                bind_launch_receipt(
                    receipt=receipt,
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                )
            )
        elif arguments.command == "bind-fixer-launch-receipt":
            receipt = sys.stdin.buffer.read(65_537)
            output = _compact(
                bind_fixer_launch_receipt(
                    receipt=receipt,
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                )
            )
        elif arguments.command == "bind-workflow-launch":
            output = _compact(
                bind_workflow_launch(
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    run_nonce=arguments.run_nonce,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                )
            )
        elif arguments.command == "bind-workflow-fixer-launch":
            output = _compact(
                bind_workflow_fixer_launch(
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    run_nonce=arguments.run_nonce,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                )
            )
        elif arguments.command == "bind-workflow-persistence-launch":
            output = _compact(
                bind_workflow_persistence_launch(
                    instance_id=arguments.instance_id,
                    run_nonce=arguments.run_nonce,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                    aggregate_path=arguments.aggregate_path,
                    aggregate_sha256=arguments.aggregate_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    expected_deferred_blockers=arguments.expected_deferred_blockers,
                    require_clean=arguments.require_clean == "1",
                )
            )
        elif arguments.command == "bind-persistence-launch-receipt":
            receipt = sys.stdin.buffer.read(65_537)
            output = _compact(
                bind_persistence_launch_receipt(
                    receipt=receipt,
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                    aggregate_path=arguments.aggregate_path,
                    aggregate_sha256=arguments.aggregate_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    expected_deferred_blockers=arguments.expected_deferred_blockers,
                    require_clean=arguments.require_clean == "1",
                )
            )
        elif arguments.command == "capture-standalone-terminal":
            output = _compact(
                capture_standalone_terminal(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    disposition_path=arguments.disposition_path,
                    applied_content_path=arguments.applied_content_path,
                )
            )
        elif arguments.command == "capture-review-terminal":
            output = _compact(
                capture_review_terminal(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    disposition_path=arguments.disposition_path,
                    applied_content_path=arguments.applied_content_path,
                )
            )
        elif arguments.command == "capture-persistence-terminal":
            output = _compact(
                capture_persistence_terminal(
                    launch_binding=arguments.launch_binding_json.encode("utf-8")
                )
            )
        elif arguments.command == "capture-bound-child":
            output = _compact(
                capture_bound_child(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    edge_id=arguments.edge_id,
                )
            )
        elif arguments.command == "prepare-ci-authority":
            output = _compact(
                prepare_ci_authority(
                    edge_id=arguments.edge_id,
                    pr_number=arguments.pr_number,
                    run_id=arguments.run_id,
                    head_sha=arguments.head_sha,
                    working_dir=arguments.working_dir,
                    input_path=arguments.input_path,
                    input_sha256=arguments.input_sha256,
                    authority_output_path=arguments.authority_output_path,
                    failure_class=arguments.failure_class,
                    signal_anchor=arguments.signal_anchor,
                    parent_sha=arguments.parent_sha,
                    parent_tree_sha=arguments.parent_tree_sha,
                    base_sha=arguments.base_sha,
                    base_tip_sha=arguments.base_tip_sha,
                    lease_sha=arguments.lease_sha,
                    pr_branch=arguments.pr_branch,
                    base_branch=arguments.base_branch,
                    target_paths=tuple(arguments.target_path),
                )
            )
        elif arguments.command == "read-ci-authority-member":
            output = read_ci_authority_member(
                authority_path=arguments.authority_path,
                authority_sha256=arguments.authority_sha256,
                member=arguments.member,
            )
        elif arguments.command == "list-ci-unmerged-paths":
            output = list_ci_unmerged_paths(working_dir=arguments.working_dir)
        elif arguments.command == "bind-workflow-ci-launch":
            output = _compact(
                bind_workflow_ci_launch(
                    edge_id=arguments.edge_id,
                    instance_id=arguments.instance_id,
                    run_nonce=arguments.run_nonce,
                    result_path=arguments.result_path,
                    status_path=arguments.status_path,
                    working_dir=arguments.working_dir,
                    ci_authority_path=arguments.ci_authority_path,
                    ci_authority_sha256=arguments.ci_authority_sha256,
                )
            )
        elif arguments.command == "capture-ci-terminal":
            output = _compact(
                capture_ci_terminal(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    edge_id=arguments.edge_id,
                )
            )
        elif arguments.command == "validate-ci-classification":
            output = _compact(
                validate_ci_classification(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                )
            )
        elif arguments.command == "validate-ci-mutation-outcome":
            output = _compact(
                validate_ci_mutation_outcome(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                    working_dir=arguments.working_dir,
                    head_before=arguments.head_before,
                    head_after=arguments.head_after,
                    remote_head_sha=arguments.remote_head_sha,
                )
            )
        elif arguments.command == "validate-ci-persistence-result":
            output = _compact(
                validate_ci_persistence_result(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                )
            )
        elif arguments.command == "validate-standalone-outcome":
            output = _compact(
                validate_standalone_outcome(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    applied_content_path=arguments.applied_content_path,
                    applied_content_sha256=arguments.applied_content_sha256,
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                    working_dir=arguments.working_dir,
                    head_before=arguments.head_before,
                    head_after=arguments.head_after,
                )
            )
        elif arguments.command == "publish-unapplied-terminal":
            output = _compact(
                publish_unapplied_terminal(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    applied_content_path=arguments.applied_content_path,
                    working_dir=arguments.working_dir,
                    head_before=arguments.head_before,
                    head_after=arguments.head_after,
                )
            )
        elif arguments.command == "validate-review-outcome":
            output = _compact(
                validate_review_outcome(
                    launch_binding=arguments.launch_binding_json.encode("utf-8"),
                    authority_path=arguments.authority_path,
                    authority_sha256=arguments.authority_sha256,
                    disposition_path=arguments.disposition_path,
                    disposition_sha256=arguments.disposition_sha256,
                    applied_content_path=arguments.applied_content_path,
                    applied_content_sha256=arguments.applied_content_sha256,
                    status_sha256=arguments.status_sha256,
                    result_sha256=arguments.result_sha256,
                    working_dir=arguments.working_dir,
                    head_before=arguments.head_before,
                    head_after=arguments.head_after,
                )
            )
        elif arguments.command == "validate-failed-return":
            output = _compact(
                validate_failed_return(
                    working_dir=arguments.working_dir,
                    evidence_dir=arguments.evidence_dir,
                    head_before=arguments.head_before,
                    snapshot_path=arguments.snapshot_path,
                    snapshot_sha256=arguments.snapshot_sha256,
                )
            )
        else:
            output = _compact(
                validate_residue(
                    working_dir=arguments.working_dir,
                    evidence_dir=arguments.evidence_dir,
                )
            )
    except ContractFailure as error:
        _write_cli_diagnostic(str(error))
        return 74
    except Exception:
        _write_cli_diagnostic("contract_failure")
        return 74
    try:
        payload = output.encode("utf-8")
    except (AttributeError, UnicodeError):
        _write_cli_diagnostic("contract_failure")
        return 74
    if not _write_raw_stream(sys.stdout, payload):
        _write_cli_diagnostic("contract_failure")
        return 74
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
