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
# The ceremony ladder, cheapest first. THREE rungs, not four (#619): a fourth
# `large` name existed for a while and resolved to the same behaviour as
# `medium` at every consumer — lib/solve-launcher.sh branches trivial / small /
# catch-all with no `large)` arm, and skills/solve-fleet/workflow.js gave both
# names the same design phases — so the extra name bought a split nothing acted
# on while costing a rung's worth of rules, a closed validator alternation, a
# policy row and a fixture corpus. `medium` is the ceiling.
#
# Collapsing the RUNG is not the same as deleting its RULES. Two of the eight
# were genuinely redundant and went (see _FIXED_RULE_TOKENS); the other six
# express a floor nothing else expresses and were re-pointed at `medium` (see
# the design-floor block in classify()). Deleting those would have moved a
# labelled issue two rungs, not one.
TIERS = ("trivial", "small", "medium")

FILE_RE = re.compile(
    r"(?<![\w.-])(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\."
    r"(?:sh|md|ts|tsx|js|jsx|py|json|ya?ml|go|rs|java|rb|c|h|cpp|css|html)\b",
    re.IGNORECASE,
)
# Fenced blocks are QUOTATION, not prose: repro transcripts, pasted diffs, and
# format examples all live there. Both readers below strip them, so one literal
# governs — markdown_text() for the length signal, declared_scope() for the
# marker (an issue documenting the scope block must not declare a scope by
# showing one).
#
# The fence is matched the way CommonMark — and the renderer a reader actually
# looks at — closes one: an opener is a run of THREE OR MORE backticks starting
# its own line, and only a line whose own backtick run is AT LEAST AS LONG
# closes it. A flat lazy pair of three-backtick runs got this wrong in the one
# shape that matters for the trust boundary in declared_scope() below.
# agents/findings-to-issues.md wraps untrusted reviewer prose in a FOUR-backtick
# `finding` fence, and its sanitiser deliberately leaves a bare three-backtick
# run inside that prose unescaped on the grounds that the wider wrapper
# neutralises it. Against a flat pair it did the opposite: the run re-paired the
# opener, the strip ended INSIDE the finding, and every byte after it — a forged
# `uberdev-scope` marker included — survived into declared_scope() as
# producer-authored fact, which is a reviewer pricing its own issue. Matching
# the fence by LENGTH makes that four-backtick block strip whole, which is what
# makes that file's forgery-inertness claim true rather than merely stated.
#
# An UNCLOSED fence runs to the end of the body, again as the renderer shows it:
# bytes a reader sees as quoted code must not read as prose here.
FENCE_RE = re.compile(
    r"^[ \t]{0,3}(`{3,})[^\n`]*(?:\n|\Z)"       # opener line: run + info string
    r".*?"                                       # quoted body
    r"(?:^[ \t]{0,3}\1`*[ \t]*(?:\n|\Z)|\Z)",    # closer at least as long, or EOF
    re.S | re.M,
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
# Breadth stated in prose rather than counted. Pairs with `refactor` below: the
# label alone is not scope (half the backlog's cleanups carry it), and a narrow
# rename that says "across the codebase" is not one either, but the two together
# are the shape that needs a design pass.
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
# Labels that mean "this needs a design pass", whatever the body's other signals
# say. Named LARGE_LABELS while a fourth rung existed; #619 collapsed the rung,
# NOT the predicate — see the design-floor block in classify().
DESIGN_LABELS = {"epic", "needs-discussion", "architectural", "architecture", "infrastructure"}
TRIVIAL_LABELS = {"typo", "docs", "documentation", "chore", "good-first-issue"}
TRIVIAL_TITLE_RE = re.compile(r"\b(?:typo|rename|bump|version|readme)\b", re.I)

# The one-way tier ratchet (#532). Tier is computed ONCE, at dispatch, from
# issue-body signals; a solver that opens the code and discovers the issue is
# structurally larger than triage said had no way to say so, and ran the lighter
# workflow to the end. It cannot re-classify itself mid-run either — the tier is
# already baked into a signed, immutable routing context by the time it starts.
# So the channel is the issue itself: the solver applies `uberdev:tier-<tier>`
# and the NEXT classification reads it.
#
# UPGRADE-ONLY BY CONSTRUCTION, in two independent ways, because a downgrade path
# here would be a label-shopping hatch for skipping brainstorm and plan review:
#   * `trivial` is excluded (TIERS[1:]) — escalating *to* trivial is an upgrade
#     from nothing, so the tier the ceremony bottoms out at is not addressable;
#   * the comparison below only ever RAISES `raw`, so a label naming a tier at or
#     below the computed one is inert rather than an error.
# Both matter: the first makes the vocabulary unable to express a downgrade, the
# second makes an expressible-but-lower one a no-op.
ESCALATION_LABEL_PREFIX = "uberdev:tier-"
ESCALATION_LABELS = {ESCALATION_LABEL_PREFIX + tier: tier for tier in TIERS[1:]}
# MIGRATION SHIM (#619). The ratchet writes a DURABLE label onto a live issue, so
# retiring a rung does not retire the labels already out there: any issue a
# pre-#619 solver escalated still carries `uberdev:tier-large` and nothing else.
# Derived straight from TIERS this name would be an unknown tier and get dropped,
# which silently discards a recorded mis-triage and re-dispatches the issue at
# whatever its body computes — a DOWNGRADE, and the one thing this channel is
# built not to express. Alias it onto the new ceiling instead. The emitted token
# is still `escalation-label:medium`, so the declared vocabulary is unchanged.
ESCALATION_LABELS[ESCALATION_LABEL_PREFIX + "large"] = "medium"

# The FOUR rule tokens that are not derived from TIERS or DESIGN_LABELS. It was
# six until #619 collapsed the `large` rung, and the two that went are the two
# that were genuinely redundant: `large:three-files` fired on `len(files) >= 3`,
# which fails `small`'s `<= 2` and `trivial`'s `<= 1` outright, and
# `large:multi-component-high-risk` needed a risk signal, which fails both arms'
# `not risks`. Either way the issue lands on the fallback rung with no rule
# required, so deleting them moves nothing.
#
# `cross-cutting-refactor` is NOT in that class and was kept, renamed onto the
# rung it now targets: `refactor` plus breadth is orthogonal to both lighter
# arms' bounds, so an issue carrying it can — and does — satisfy the `small` arm
# on its own. Deleting it would have dropped such an issue TWO rungs rather than
# collapsing one.
_FIXED_RULE_TOKENS = frozenset({
    "medium:cross-cutting-refactor",
    "trivial:bounded-explicit-signal", "small:concrete-reproduction", "medium:fallback",
})
# `matched_rules` is validated entry-by-entry against a CLOSED alternation
# (`allowed_rule` in lib/agent-dispatch.sh). A token this module emits but that
# validator refuses makes uberdev_agent_context_create fail with
# route_context_create_failed — which does not decline one issue, it aborts the
# ENTIRE batch: every sibling issue in the same /solve, /turbo or /ubergoal run
# dies with it. Same class as COMPONENT_TOKEN_RE below, one field over.
# Declaring the vocabulary here does NOT spare the siblings — solve-launcher.sh
# aborts the batch on a classification error too. What it buys is that the drift
# reds CI at the producer, before it can ship: tests/triage-rule-vocabulary.py
# keeps this set a subset of the validator's alternation, a superset of
# everything classify() emits over the fixture corpus, and both
# assert_rule_tokens call sites wired. An emitter on an unfixtured path is
# outside that corpus — add a fixture with the rule. Should one ever reach a
# user, an undeclared token also surfaces as `triage_rule_unknown` against the
# offending issue number — for every offending issue, where route-prepare exits
# on the first one.
TRIAGE_RULE_TOKENS = frozenset(
    {f"{kind}:{tier}" for kind in ("floor", "ceiling", "override") for tier in TIERS}
    | {f"medium-label:{label}" for label in DESIGN_LABELS}
    | {f"escalation-label:{tier}" for tier in ESCALATION_LABELS.values()}
    | _FIXED_RULE_TOKENS
)


class TriageError(ValueError):
    pass


def fail(code: str) -> "None":
    raise TriageError(code)


def assert_rule_tokens(rules: list[str]) -> None:
    if any(rule not in TRIAGE_RULE_TOKENS for rule in rules):
        fail("triage_rule_unknown")


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
    body = FENCE_RE.sub(" ", body)
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


# ---------------------------------------------------------------------------
# SCOPE, NOT CITATION DENSITY (#614)
#
# This used to be `named_files()`: scrape every filename-shaped token out of the
# issue prose and call the count the size of the work. It could not tell a file
# cited as EVIDENCE from a file the fix will edit, and three of them crossed the
# rung that decides between one solver agent and a full design fleet.
#
# That is not an edge case here, it is the house style. Every writer that files
# issues into this repo (`/uberscan`, `findings-to-issues`, `/issue` plus the
# codebase scout) is REQUIRED to anchor its claims with `path:line` evidence, so
# the better-evidenced an issue was, the larger it was priced. Measured against
# the live backlog the rule pushed EVERY open issue to the top rung — 40 of 40
# when #614 was filed, 43 of 43 when this landed: a cost gate with no
# discriminating power, and one that taxed exactly the issues that did their
# homework. Re-measured on the same corpus after this landed, the file returned
# 10 small / 13 medium / 20 large; re-measured again on 44 open issues after
# #619 collapsed the top two rungs into one, 11 small / 33 medium.
#
# The replacement asks a different question — not "which files does this text
# mention" but "which files is this issue going to CHANGE":
#
#   1. A producer-declared scope block is read as FACT. The agent that writes
#      the issue already knows what it intends to touch, so it says so, and
#      triage stops guessing. Declaration always wins, INCLUDING an empty one —
#      `files=` with nothing after it is a recorded "no scope declared yet",
#      never a licence to fall back to the guess (the `edges=` convention in
#      agents/findings-to-issues.md, one marker over).
#   2. Absent a declaration, only paths a clause MARKS as a change target
#      count. A `path:line` citation is evidence; "update lib/a.sh" is scope.
#      An explicit exclusion clause ("do not touch lib/b.sh") suppresses its own
#      paths, because a bare verb scan reads "do not touch" as change intent.
#
# The heuristic under-counts by design: an issue whose prose marks nothing lands
# on `medium`, which since #619 is both the fallback and the ceiling. That makes
# the count's remaining job the DOWNWARD one — it is what keeps a two-file issue
# eligible for `small` and holds a three-file one at the design rung — so a
# scope extractor that always returned nothing would gut the ladder rather than
# sharpen it. tests/solve-triage.test.sh S7 pins that with a positive control.
# ---------------------------------------------------------------------------

# Clause, not sentence: an exclusion rides in on `but` far more often than after
# a full stop ("fix lib/a.sh but leave lib/b.sh alone"). `:` is deliberately NOT
# a boundary — "files to change: a.sh, b.sh" would lose its verb to the split.
CLAUSE_SPLIT_RE = re.compile(
    r"(?<=[.!?;])\s+|\s+(?:but|however|though|although|whereas)\s+", re.IGNORECASE
)
# Spelled out rather than stem-matched: `alter\w*` also swallows "alternative",
# and `add\w*` swallows "address" — both of which appear in ordinary bug prose
# and would quietly restore the citation-counting behaviour.
_CHANGE_VERBS = (
    "add", "adds", "added", "adding",
    "change", "changes", "changed", "changing",
    "delete", "deletes", "deleted", "deleting",
    "drop", "drops", "dropped", "dropping",
    "edit", "edits", "edited", "editing",
    "extend", "extends", "extended", "extending",
    "fix", "fixes", "fixed", "fixing",
    "implement", "implements", "implemented", "implementing",
    "introduce", "introduces", "introduced", "introducing",
    "migrate", "migrates", "migrated", "migrating",
    "modify", "modifies", "modified", "modifying",
    "move", "moves", "moved", "moving",
    "patch", "patches", "patched", "patching",
    "refactor", "refactors", "refactored", "refactoring",
    "remove", "removes", "removed", "removing",
    "rename", "renames", "renamed", "renaming",
    "replace", "replaces", "replaced", "replacing",
    "rewrite", "rewrites", "rewrote", "rewriting",
    "rework", "reworks", "reworked", "reworking",
    "touch", "touches", "touched", "touching",
    "update", "updates", "updated", "updating",
    "wire", "wires", "wired", "wiring",
)
CHANGE_INTENT_RE = re.compile(r"\b(?:" + "|".join(_CHANGE_VERBS) + r")\b", re.IGNORECASE)
# Only phrasings that are unambiguously about NOT changing something. A bare
# "unchanged" or a generic negation is deliberately absent: "update lib/a.sh so
# the output does not truncate" is a change target, and suppressing it would
# under-price real work — the one direction this heuristic must never move in.
EXCLUSION_RE = re.compile(
    r"\b(?:"
    r"(?:do(?:es)?\s+not|don'?t|doesn'?t|must\s+not|mustn'?t|should\s+not|shouldn'?t"
    r"|cannot|can'?t|no\s+need\s+to|never)\s+(?:be\s+)?"
    r"(?:touch|chang|modif|edit|alter|updat|patch|rewrit)\w*"
    r"|without\s+(?:touching|changing|modifying|editing|altering|updating)"
    r"|(?:fine|safe|ok|okay|happy)\s+to\s+leave"
    r"|leave\s+(?:\w+\s+){0,3}?(?:alone|as[- ]is|unchanged|untouched)"
    r"|(?:out\s+of|not\s+in)\s+scope"
    r"|no\s+changes?\s+(?:needed|required)"
    r"|not\s+to\s+be\s+(?:touched|changed|modified|edited)"
    r"|for\s+reference\s+only"
    r")\b", re.IGNORECASE
)
# The producer-declared scope block. Same shape as the `uberdev-finding-meta`
# trailer this repo's issue writers already emit: an HTML comment, a version, a
# comma-joined value. HTML comments survive `gh issue view --json body` and
# render invisibly, so the declaration costs the reader nothing.
SCOPE_BLOCK_RE = re.compile(r"<!--\s*uberdev-scope\s+v=1\s+files=([^>]*?)\s*-->", re.IGNORECASE)


def _schema_safe_files(tokens: set[str]) -> list[str]:
    # Drop anything the routing-context schema would refuse rather than emit a
    # token that refuses the dispatch: losing one filename from a triage signal
    # is strictly better than declining to work the issue — and its siblings.
    files = sorted(token for token in tokens if FILES_TOKEN_RE.fullmatch(token))
    if len(files) > MAX_FILES:
        fail("triage_limit_files")
    return files


def declared_scope(body: str) -> list[str] | None:
    """The producer's own change set, or None when the body declares nothing.

    Returns a list — possibly EMPTY — whenever any scope block is present, so
    the caller can tell "declared nothing" from "declared no scope".

    A declaration the schema filter cannot read IN FULL is neither: it is an
    UNREADABLE declaration, and it must not be reported as a complete one. The
    guard is on the COUNT, not on emptiness — losing one token out of three is
    the same lie as losing all three, just quieter, because the survivors come
    back byte-indistinguishable from an honest declaration of that size. `_schema_safe_files` drops a non-conforming token silently and by
    design, so `files=lib/a.sh:42,lib/b.sh:71` — the shape a producer writes the
    moment it forgets to strip the `:line` suffix both issue writers are told in
    prose to strip — arrives here byte-identical to a deliberate `files=`. Bound
    as an empty declaration it becomes a decision of zero files, which prices
    the issue at the cheapest rung of the very gate this block exists to make
    accurate, with nothing on the triage line to distinguish it from an honest
    empty one. Report it as UNDECLARED instead, so the prose heuristic still
    runs: a heuristic guess is a far better answer than a fabricated zero, and
    it keeps the failure on the never-under-price side the module holds
    everywhere else.
    """
    matches = SCOPE_BLOCK_RE.findall(FENCE_RE.sub(" ", body))
    if not matches:
        return None
    # Two blocks are a producer bug, and the two ways to resolve it are not
    # symmetric: taking the first can silently HALVE a declared scope, while the
    # union only ever over-prices. Union, for the same reason the heuristic
    # refuses to under-count.
    declared = {
        token for raw in matches
        for token in (piece.strip("`'\"").strip("./").casefold()
                      for piece in re.split(r"[,\s]+", raw))
        if token
    }
    files = _schema_safe_files(declared)
    # COUNT, not emptiness. `_schema_safe_files` is a pure filter over this
    # already-deduped set, so a shortfall means tokens were dropped -- and a
    # PARTLY unreadable declaration under-prices exactly the way a wholly
    # unreadable one does. Three paths answered as two crosses the rung that
    # decides between one solver agent and thirty-three, in the never-under-price
    # direction this module holds everywhere else. A genuinely empty declaration
    # still answers [] (0 == 0), so "declared no scope" stays distinguishable
    # from "declared nothing".
    if len(files) != len(declared):
        return None
    return files


def scope_files(body: str) -> list[str]:
    """Files this issue says it will change — declaration first, prose second."""
    declared = declared_scope(body)
    if declared is not None:
        return declared
    tokens: set[str] = set()
    # A LINE BREAK IS A CLAUSE BOUNDARY, and reading the body as one string
    # loses that: markdown_text() collapses every newline to a single space, and
    # CLAUSE_SPLIT_RE breaks only on sentence punctuation or a contrast
    # conjunction, so a bullet list — the shape commands/issue.md's own templates
    # emit — arrives as ONE clause. A single "do not touch X" bullet then
    # suppresses every change target standing beside it, which is the
    # under-pricing direction EXCLUSION_RE's own note says this heuristic must
    # never move in. Fences are stripped from the WHOLE body first: they span
    # lines, and a newline inside quoted code is not a clause boundary the
    # reader was ever meant to see.
    for line in FENCE_RE.sub(" ", body).splitlines():
        for clause in CLAUSE_SPLIT_RE.split(markdown_text(line)):
            if not clause or EXCLUSION_RE.search(clause) or not CHANGE_INTENT_RE.search(clause):
                continue
            tokens.update(
                match.group(0).strip("./").casefold() for match in FILE_RE.finditer(clause)
            )
    return _schema_safe_files(tokens)


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
        # and any dot-segment `scope_files` did not already strip).
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
    files = scope_files(body)
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

    # THE DESIGN FLOOR. Signals that say "this needs a design pass" no matter what
    # else the body looks like. They are checked BEFORE the two lighter arms and
    # pre-empt them, because they are orthogonal to those arms' bounds rather than
    # excluded by them: an `epic` can carry a `bug` label, and a cross-cutting
    # `refactor` can ship a clean reproduction, so on the arms alone either would
    # be priced `small`.
    #
    # These rules used to force a fourth `large` rung. #619 collapsed that rung
    # into `medium`; it did NOT collapse the predicate. Dropping them here rather
    # than re-pointing them would not merge two rungs, it would let a labelled
    # issue fall TWO — `needs-discussion` on a short `docs` body falls THREE, all
    # the way to `trivial` — which is the opposite of what collapsing a rung means.
    #
    # The two rules that WERE deleted are the ones the arms below genuinely
    # subsume: see _FIXED_RULE_TOKENS. tests/solve-triage.test.sh L3/L4 pin those
    # as positive controls, and L5/L8 pin the floor established here.
    design = False
    design_labels = sorted(set(labels) & DESIGN_LABELS)
    if design_labels:
        design = True
        matched.extend(f"medium-label:{label}" for label in design_labels)
    # The `refactor` label is not breadth on its own — it is the most common label
    # in a cleanup backlog. It needs a second, independent breadth signal: two or
    # more named components, or an explicit cross-cutting phrase.
    if "refactor" in labels and (len(components) >= 2 or cross_cutting):
        design = True
        matched.append("medium:cross-cutting-refactor")

    stripped_length = len(markdown_text(body))
    # THREE arms, checked cheapest-first, with `medium` as both the fallback and
    # the ceiling (#619). The design floor above pre-empts the two lighter ones.
    if design:
        raw = "medium"
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

    # The ratchet, applied to `raw` and nothing else. Moving the RAW tier is what
    # makes the rest compose untouched: `source` stays "computed" for a pure
    # escalation (it IS a computed tier, just from a signal the last run left),
    # the floor/ceiling/override machinery below clamps the escalated value, and
    # solve-launcher.sh reads `raw_tier` off this call before its own shell-side
    # clamp, so no launcher change is needed. The computed rule token is left in
    # `matched` beside the escalation one, so the trail reads "computed trivial,
    # escalated to medium" rather than "was always medium".
    labelled = [ESCALATION_LABELS[name] for name in labels if name in ESCALATION_LABELS]
    if labelled:
        # Exactly one token, ever: `matched_rules` is length-capped and
        # duplicate-checked by the routing-context validator, so emitting one per
        # label would be a dispatch failure rather than merely noisy.
        highest = max(labelled, key=TIERS.index)
        if TIERS.index(highest) > TIERS.index(raw):
            raw = highest
            matched.append(f"escalation-label:{highest}")

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
    rules = list(dict.fromkeys(matched))
    assert_rule_tokens(rules)
    return {
        "clamped_tier": clamped,
        "component_count": len(components),
        "components": components,
        "effective_tier": effective,
        "file_count": len(files),
        "files": files,
        "issue": number,
        "matched_rules": rules,
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
    assert_rule_tokens(result["matched_rules"])
    return result


def tier_arg(value: str) -> str:
    if value not in TIERS:
        raise argparse.ArgumentTypeError("expected trivial|small|medium")
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
            if value not in {"auto", "workflow", "wezterm", "background"}: fail("routing_cli_invalid")
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
    # option parser for this opaque-token subcommand so `--backend=workflow 12`
    # and `12 --backend=workflow` are equivalent.
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
