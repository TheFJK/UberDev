#!/usr/bin/env python3
"""tools/vendor/vendor-drift.py — the weekly upstream-drift reporter.

WHY THIS EXISTS (#434, RFC 0019 §8). RFC 0019 decides to keep vendoring rather
than peer-depend on the now-officially-distributed upstream plugins. That
decision forfeits upstream's fixes-for-free, and #430 is the receipt: upstream
fixed `find-polluter.sh` and this repo shipped the broken copy for months.

This script is the compensating control. Once a week it diffs each vendored
component's recorded watermark against its upstream's current HEAD and keeps
exactly ONE issue up to date with the result.

Two properties are load-bearing, and both are the kind that rot quietly:

  * An unreachable upstream FAILS LOUDLY. A `git ls-remote` that errors, prints
    nothing, or prints a non-40-hex ref makes this script exit non-zero and
    mutate nothing. Rendering "unreachable" as "no drift" would put the exact
    silent-green failure mode this feature exists to kill inside the detector.
  * Exactly one issue, edited in place. A weekly job that opens a fresh issue
    per run gets muted, and a muted control is not a control.

Declared divergences (RFC 0019 §6) are reported separately from raw drift, so
the five never-reconcile items do not resurface in every report as noise.

`--verify-bases` is the script's second, independent mode (#505). It answers a
different question from drift: not "has upstream moved since we last looked?"
but "is the base this register claims to have copied from the base those bytes
actually came from?". `vendor-check.py`'s `C-BASE` cannot answer it — that guard
is offline by policy, so the strongest thing it can demand is that the claim be
restated in an in-file header, which costs two coordinated lies instead of one.
`base_evidence` records the blob oid each file had at `vendored_ref`, a commit
of THIS repository; the offline half of the proof (that the oid matches what git
says here) is asserted in `tests/vendor-provenance.test.sh`. This mode owns the
upstream half, because resolving upstream's blob is a network operation and must
never run inside the offline guard.

Repo-agnostic: no organisation, repository or project id is hardcoded. Upstream
coordinates come from `plugins/uberdev/vendor.json`; the target repository comes
from `gh`'s own checkout/`GH_REPO` inference.

Usage:
    vendor-drift.py [--repo-root DIR] [--dry-run] [--issue-limit N]
    vendor-drift.py [--repo-root DIR] --verify-bases

Exit codes:
    0  ran to completion (drift or not; every recorded base verified)
    1  an upstream could not be resolved, a recorded base did not verify, or a
       GitHub call failed
    2  usage error, or a register that is unreadable, unparseable, or missing a
       field this script would otherwise subscript
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REGISTER_REL = "plugins/uberdev/vendor.json"
# Every field the diff loop subscripts unconditionally. Checked up front so a
# malformed register exits 2 ("unreadable register") rather than dying on an
# uncaught KeyError, whose rc 1 is indistinguishable from `fail()`'s documented
# "an upstream could not be resolved" — i.e. a broken register would read as an
# outage, and re-reading it as one every week is how a control gets ignored.
REQUIRED_COMPONENT_KEYS = ("id", "upstream", "upstream_path", "stance",
                           "last_reviewed_upstream_commit")
# Default clone host. An upstream may override it with its own `url` field, so
# no forge is baked into the code path — only into the default.
UPSTREAM_HOST = "https://github.com/"
MARKER = "<!-- uberdev-vendor-drift-v1 -->"
FINGERPRINT_KEY = "drift-fingerprint:"
ISSUE_TITLE = "Vendored upstream drift — weekly report"
SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
# `git ls-remote --tags <url>` prints `refs/tags/<name>` for every tag and, for
# an ANNOTATED tag, a SECOND `refs/tags/<name>^{}` line carrying the commit the
# tag object peels to. The register records peeled commits, so the peel line is
# the one that has to win — and `--refs`, the obvious-looking way to tidy the
# output, DROPS that line entirely, which is why the query below deliberately
# does not pass it.
TAG_REF_RE = re.compile(r"^refs/tags/(.+?)(\^\{\})?$")
# Bounds on an UNTRUSTED tag name. Each exists because the parse does ARITHMETIC
# on what it matches: CPython refuses `int()` on a digit run past
# `sys.get_int_max_str_digits()` (4300 by default since 3.11), so an unbounded
# quantifier anywhere upstream of an `int()` is an uncaught ValueError wearing
# `fail()`'s "an upstream could not be resolved" exit code — a malformed tag
# name reported as an outage, weekly, until somebody mutes the job. The
# whole-name cap also bounds the prefix-stripping retry loop, which is
# O(hyphens). Each bound has exactly ONE spelling: the pattern is BUILT from
# these constants, never from a literal that could be raised in one place and
# left behind in the other.
MAX_TAG_NAME_CHARS = 256
MAX_VERSION_COMPONENT_DIGITS = 18
MAX_PRERELEASE_IDENT_CHARS = 32
MAX_DOTTED_TAIL_COMPONENTS = 8
_NUMERIC = r"\d{1,%d}" % MAX_VERSION_COMPONENT_DIGITS
_IDENT = r"[0-9A-Za-z-]{1,%d}" % MAX_PRERELEASE_IDENT_CHARS
_TAIL = r"{0,%d}" % MAX_DOTTED_TAIL_COMPONENTS
# `[v]<core>[-<pre>]`, anchored at both ends. No quantifier is ambiguous with
# its neighbour — `.` is in neither `\d` nor the identifier class — so there is
# no catastrophic-backtracking shape here, and the whole-name cap bounds the
# worst case regardless.
VERSION_RE = re.compile(
    r"^[vV]?(?P<core>%(n)s(?:\.%(n)s)%(t)s)"
    r"(?:-(?P<pre>%(i)s(?:\.%(i)s)%(t)s))?$"
    % {"n": _NUMERIC, "i": _IDENT, "t": _TAIL})
# `release_key`'s pre-release field, named at both ends so the rule it encodes
# stays legible: SemVer §11 ranks a pre-release BELOW the release it precedes,
# so `v6.4.0-rc1` sorts under `v6.4.0`. `is_prerelease` reads the same field
# back out, which is what keeps "is this a pre-release?" from becoming a second
# answer — spelled, inevitably, as a substring test for `-`. That test can only
# ever OVER-report against this one: every name ranked here as a pre-release
# carries a hyphen anyway, so the substring test never misses one. It only
# invents extras, and WHERE an invented one lands decides which way the answer
# then goes wrong. Landing on a candidate, with `allow_pre` off, it is filtered
# out of a set it belongs in and an upstream's newest release goes unreported.
# Landing on the recorded review point, it turns `allow_pre` ON — that flag is
# computed by this very test — and the genuine pre-releases the flag exists to
# exclude are admitted instead, one of which wins `max()`. D-REL13(e) executes
# both. What the key those ranks sit inside LOOKS like is stated once, in
# `release_key`'s own docstring; restating it here is how a third copy of the
# shape came to describe a tuple the module had stopped returning.
PRERELEASE_RANK = 0
FINAL_RANK = 1
RELEASE_KEY_PRERELEASE_FIELD = 1
FINGERPRINT_RE = re.compile(r"drift-fingerprint:\s*([0-9a-f]+)")
# The one verdict field the fingerprint payload leaves out: `id` is the KEY each
# entry is stored under, so carrying it inside the entry as well would hash the
# same fact twice. Everything else the verdict carries goes in — see
# `build_report`.
#
# `actionable` used to sit beside it, on the rationale that it "cannot vary
# within the payload". That held only while `releases` carried the ACTIONABLE
# verdicts alone. #604 widened it to EVERY verdict, because
# `Recorded release review points` renders every one of them, so `actionable`
# now varies entry to entry and the exception has lost its premise: the field
# falls back under the rule its neighbours already follow — the whole verdict,
# minus its key, never a hand-picked subset. Hashing it costs nothing, since it
# is a total function of `state`, which is hashed anyway; skipping it would buy
# only the return of a comment describing a filter this module no longer
# applies.
#
# Do not re-skip it on the grounds that `state` already determines it. The
# adjudication bucket — which verdicts get a finding block — is a function of
# THIS field, so an entry without it could not be the only thing a render reads
# to rebuild that bucket.
FINGERPRINT_VERDICT_SKIP = frozenset({"id"})
# The same rule for a change record. Spelled separately because it is a
# different record: the two sets coincide today, and nothing says a field added
# to one would have to be added to the other.
FINGERPRINT_COMPONENT_SKIP = frozenset({"id"})
# Cap the per-component file list so one large upstream release cannot turn the
# issue body into an unreadable wall; the residual count is still reported.
MAX_LISTED_FILES = 25


def die_usage(message):
    print("vendor-drift: %s" % message, file=sys.stderr)
    raise SystemExit(2)


def fail(message):
    print("vendor-drift: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def run(argv, cwd=None):
    """Run a command, returning (rc, stdout, stderr). Never raises on rc."""
    try:
        proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    except OSError as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def load_register(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        die_usage("cannot read register %s: %s" % (path, exc))
    except ValueError as exc:
        die_usage("register %s is not valid JSON: %s" % (path, exc))


def resolve_head(repo_url, repo_slug):
    """Resolve a remote HEAD, failing loudly on every ambiguous outcome.

    `repo_url` is register-supplied, so it reaches this line as data and must
    not be allowed to arrive as an option: `--` ends git's own option list, and
    everything after it is a repository however it is spelled. Without the
    separator a url beginning with `-` is parsed as a flag — `--upload-pack=`
    names a command git runs — so one edited string in `vendor.json` would
    execute code inside the unattended weekly job.
    """
    rc, out, err = run(["git", "ls-remote", "--", repo_url, "HEAD"])
    if rc != 0:
        fail("git ls-remote failed for upstream %s (rc=%d): %s"
             % (repo_slug, rc, (err or out).strip()))
    line = out.strip()
    if not line:
        fail("git ls-remote returned no output for upstream %s — refusing to "
             "report 'no drift' from an unresolved upstream" % repo_slug)
    sha = line.split()[0].strip()
    if not SHA40_RE.match(sha):
        fail("git ls-remote returned a non-40-hex ref for upstream %s: %r"
             % (repo_slug, sha))
    return sha


def _pre_ids(pre):
    """SemVer §11 identifier order for one pre-release string.

    A numeric identifier compares numerically and ranks BELOW an alphanumeric
    one, so a numeric identifier becomes `(0, <int>, "")` and any other becomes
    `(1, 0, <text>)`. A shorter identifier list ranks below a longer one whose
    earlier identifiers are equal, which tuple comparison already gives.
    """
    ids = []
    for ident in pre.split("."):
        if ident.isdigit():
            ids.append((0, int(ident), ""))
        else:
            ids.append((1, 0, ident))
    return tuple(ids)


def release_key(name):
    """A tag name's precedence, or None if it names no version at all.

    THE ONLY statement of the returned shape; every other site in this module
    defers here. It is the triple `(nums, rank, pre_ids)`: `nums` is the dotted
    version core as ints, `rank` is `PRERELEASE_RANK` for a pre-release and
    `FINAL_RANK` otherwise, and `pre_ids` orders the pre-release identifiers per
    SemVer §11 — empty for a final release, whose rank field has already decided
    the comparison.

    The parse, stated once: strip build metadata at the first `+` (SemVer §10 —
    it is not part of the version, so it cannot decide precedence); then read
    what remains as `[v]<core>[-<pre>]`, and while that fails drop everything up
    to and including the first `-` and try again. That retry is what reads
    `release-1.2.3` and `pr-review-toolkit-v1.2.0`, whose leading words are a
    NAME: the `-` in front of the digits separates words, not a pre-release. A
    name no attempt parses carries no version — the same answer `latest` gets.

    Precedence ONLY. `v6.4.0+build1` and `v6.4.0` are one release under §10, so
    neither outranks the other here, and choosing deterministically between two
    names of equal precedence is `release_sort_key`'s job. A tiebreak carried
    inside this key would be a tiebreak that outranks, which is the §10
    violation itself.

    The shape exists to prevent one specific inversion, so do not "simplify" it
    into the digits alone: read as digits, `v6.4.0-rc1` yields (6, 4, 0, 1) and
    sorts ABOVE its own final release `v6.4.0` at (6, 4, 0) — `max()` would then
    report a release CANDIDATE as the newest release, and the weekly job would
    demand adjudication of something RFC 0019 §7 gives nobody a way to clear.
    SemVer §11 ranks a pre-release BELOW the version it precedes, and the rank
    field is what encodes that.

    TOTAL over every input, by construction rather than by example: a non-`str`
    and an over-long name are refused up front, and every `int()` below consumes
    a group `VERSION_RE` has already bounded to `MAX_VERSION_COMPONENT_DIGITS`
    or `MAX_PRERELEASE_IDENT_CHARS` characters, so no `int()` here can reach
    CPython's conversion limit. A name that breaches a bound fails the parse and
    answers None rather than raising inside a job whose non-zero exit means "an
    upstream could not be resolved".

    `ls-remote` prints tags in lexical refname order, where `v6.0.10` precedes
    `v6.0.2`; ordering is therefore always computed here, never taken from the
    order the remote happened to print.
    """
    if not isinstance(name, str) or len(name) > MAX_TAG_NAME_CHARS:
        return None
    rest = name.split("+", 1)[0]           # SemVer §10
    while True:
        match = VERSION_RE.match(rest)
        if match:
            nums = tuple(int(n) for n in match.group("core").split("."))
            pre = match.group("pre")
            if pre is None:
                return (nums, FINAL_RANK, ())
            return (nums, PRERELEASE_RANK, _pre_ids(pre))
        if "-" not in rest:
            return None
        rest = rest.split("-", 1)[1]


def release_sort_key(name):
    """A TOTAL order over tag names, for `max()` and `sorted()`.

    SemVer §10 leaves two spellings of one release EQUAL under `release_key`,
    and `max()` over an equal pair would otherwise fall back to the order
    `ls-remote` printed — the one thing `release_key` is written to never take
    an answer from. The raw name breaks that tie, and it lives here rather than
    inside the precedence key, so breaking a tie can never become outranking.

    Total for every name, including one carrying no version: the leading flag
    decides before the key tuple is reached, so None never meets a tuple under
    `<`, and every unkeyed name sorts below every keyed one. The
    `() if key is None else key` spelling tests presence against `None` rather
    than truthiness, matching the rest of this module — and `()` is a legitimate
    key component that happens to be falsy. Both call sites do pre-filter on
    `release_key(n) is not None`; this function does not rely on their
    remembering to, because a helper whose totality lives in its callers is the
    same partial-function bug one indirection out.
    """
    key = release_key(name)
    return (key is not None, () if key is None else key, name)


def is_prerelease(name):
    """True when `name` names a version that PRECEDES its own final release.

    Delegates the parse to `release_key` rather than testing the raw string for
    a `-`, because the substring test OVER-reports and cannot under-report:
    every name this function calls a pre-release already carries a hyphen in
    its version core, so the two answers only ever disagree in the one
    direction. Both of these are final releases the substring test misreads —
    `release-1.2.3`, whose hyphen is a word separator, and `v6.4.0+build-7`,
    where SemVer §10 puts the build metadata outside the version entirely.

    WHERE a misread name lands is what decides how `release_candidates` then
    goes wrong, and the two landings fail differently. Misread as a CANDIDATE
    it is dropped from a set it belongs in, leaving an upstream whose newest
    release is invisible to the control that exists to notice it. Misread as
    the RECORDED review point it turns `allow_pre` on — that flag is computed
    by the very test being hypothesised about — so the genuine pre-releases the
    flag exists to exclude are admitted instead, and one of them wins `max()`
    and is reported as the newest release: the inversion `release_key`'s
    pre-release field exists to prevent. Note it is not the misread name itself
    that is reported there; it is a real pre-release the misreading let in.
    D-REL13(e) executes both directions, each against the answer the real rule
    gives for the same upstream.
    """
    key = release_key(name)
    return key is not None and key[RELEASE_KEY_PRERELEASE_FIELD] == PRERELEASE_RANK


def validate_release_metadata(upstream_id, upstream):
    """Refuse a release review point this script would otherwise mis-read.

    Runs beside the `REQUIRED_COMPONENT_KEYS` loop, before the first subprocess
    and before either mode branches, for the reason D13/D13b pin: a register
    somebody broke exits 2, never the rc 1 `fail()` reserves for "an upstream
    could not be resolved". A weekly job that reports a typo as an outage is one
    that gets muted, and a muted control is not a control.

    The orderability requirement is not decoration. `release_key` returns None
    for a label naming no version, and None is not orderable against another
    key's tuple — so a recorded `"latest"` would pass any presence-only check,
    survive the whole tag resolution, and only THEN die at the comparison with
    an uncaught TypeError: rc 1, mid-run, after the network cost, wearing an
    outage's exit code. Demanding a KEY up front — from `release_key` itself,
    never from a restatement of what it accepts — is what makes
    `release_key(recorded)` total by the time any comparison runs.

    The check is a BICONDITIONAL over every used upstream: exactly one of
    `last_reviewed_release` and `head_only` must be declared. The two halves are
    not symmetric in how they used to fail, which is why both are checked here.
    A label without a commit already died at rc 2. Its mirror image — no label
    at all — returned silently and rendered as a non-actionable `head-only`, so
    deleting one line from the register disabled the release control for that
    upstream while every other check in the repo stayed green, and the report
    went on attributing its own silence to a declaration nobody had made (#604
    defect 3). "No release vocabulary" is a DECISION, and a decision inferred
    from an absent key is indistinguishable from an accident.

    `head_only` must be exactly JSON `true`, by identity rather than by
    truthiness: a placeholder, a `"yes"`, or the `1` a hand-edit leaves behind
    would otherwise stand in for the decision. Presence is tested with `in` for
    the same reason the label's own clauses are — a present-but-empty label is a
    BROKEN review point and must reach the orderability clause below, never be
    read here as an upstream that declared nothing.
    """
    label_declared = "last_reviewed_release" in upstream
    optout_declared = "head_only" in upstream

    if optout_declared and upstream["head_only"] is not True:
        die_usage("upstream %s declares head_only %r — the HEAD-only opt-out "
                  "records a decision, not a note, so it must be exactly JSON "
                  "true. Accepting any truthy value would let a placeholder or "
                  "a typo stand in for the decision, and this tool would go on "
                  "reporting the upstream as deliberately release-free on the "
                  "strength of it" % (upstream_id, upstream["head_only"]))
    if label_declared and optout_declared:
        die_usage("upstream %s declares both last_reviewed_release %r and "
                  "head_only — a HEAD-only upstream is one with no release "
                  "vocabulary to record, so the two declarations contradict "
                  "each other and nothing here can decide which one the "
                  "register meant"
                  % (upstream_id, upstream["last_reviewed_release"]))
    if not label_declared and not optout_declared:
        die_usage("upstream %s declares neither last_reviewed_release nor "
                  "head_only — every used upstream must state its release "
                  "standing positively: either the release review point that "
                  "was adjudicated, or head_only: true to record that this "
                  "upstream publishes no releases to adjudicate. Silence is "
                  "indistinguishable from a review point deleted by accident, "
                  "and this tool would report the deletion as a settled "
                  "decision" % upstream_id)
    if not label_declared:
        # Declared HEAD-only, positively. `release_verdict` renders it as
        # `head-only` and not actionable — RFC 0019's #511 amendment: a plugin
        # inside a monorepo with no release vocabulary has no tag to name, and
        # inventing a label for it would be exactly the fabrication this
        # register exists to prevent.
        return
    label = upstream["last_reviewed_release"]
    # The predicate IS the function whose totality it guarantees. Any restatement
    # of what `release_key` accepts — "carries at least one digit", say — is a
    # second source of truth that can drift from the first, and this one already
    # does: SemVer §10 puts build metadata outside the version, so `release_key`
    # strips it BEFORE looking for one, and `"stable+2026"` carries digits, would
    # satisfy a digit test, and still keys to None. Asking `release_key` itself
    # is the only predicate that cannot disagree with it.
    #
    # Two clauses, not three: `""` and `"latest"` both key to None, so a separate
    # emptiness test would be a clause no test could ever red — the dead-contract
    # shape this repo audits for.
    if not isinstance(label, str) or release_key(label) is None:
        die_usage("upstream %s declares last_reviewed_release %r — a recorded "
                  "release review point must be a STRING that names a version "
                  "this tool can order against what upstream publishes. "
                  "Anything else has no key to compare, and would surface only "
                  "at the comparison, as an uncaught TypeError wearing an "
                  "unreachable upstream's exit code" % (upstream_id, label))
    commit = upstream.get("last_reviewed_commit")
    if not isinstance(commit, str) or not SHA40_RE.match(commit):
        die_usage("upstream %s declares last_reviewed_release %r but no 40-hex "
                  "last_reviewed_commit — half a review point is a broken "
                  "register: the label records WHICH release was adjudicated "
                  "and the commit records which bytes that was, and neither is "
                  "checkable against upstream without the other"
                  % (upstream_id, label))


def resolve_tags(repo_url, repo_slug):
    """Every tag a remote publishes, as {name: commit}. Loud on a failed query.

    Mirrors `resolve_head`'s contract with ONE deliberate divergence: empty
    output is DATA here, never a failure. `resolve_head` treats silence as fatal
    because every remote has a HEAD, so an empty answer can only mean the query
    did not really run. Tags are different — a plugin vendored out of a monorepo
    really does have an upstream that publishes zero tags — so copying the
    empty-is-fatal rule would take the weekly job red every week forever for an
    upstream behaving exactly as the register describes it.

    An annotated tag's `^{}` peel line OVERWRITES the tag object's own oid for
    the same name: the register records the commit a release points at, and a
    tag object's oid would never compare equal to it.

    `--` separates git's options from the register-supplied url for the same
    reason it does in `resolve_head`, and it is needed independently: the two
    functions build their argv separately, so a separator on one of them leaves
    the other reachable.
    """
    rc, out, err = run(["git", "ls-remote", "--tags", "--", repo_url])
    if rc != 0:
        fail("git ls-remote --tags failed for upstream %s (rc=%d): %s"
             % (repo_slug, rc, (err or out).strip()))
    tags = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) < 2:
            fail("git ls-remote --tags returned a line with no ref for upstream "
                 "%s: %r" % (repo_slug, line.strip()))
        sha, ref = fields[0].strip(), fields[1].strip()
        if not SHA40_RE.match(sha):
            fail("git ls-remote --tags returned a non-40-hex object id for "
                 "upstream %s: %r" % (repo_slug, sha))
        match = TAG_REF_RE.match(ref)
        if not match:
            fail("git ls-remote --tags returned %r for upstream %s, which is not "
                 "under refs/tags — refusing to read an answer to a question "
                 "this script did not ask" % (ref, repo_slug))
        name, peeled = match.group(1), bool(match.group(2))
        if peeled or name not in tags:
            tags[name] = sha
    return tags


def release_candidates(published, recorded):
    """The names eligible to BE "the newest release", given the recorded vocabulary.

    Two filters, and each exists to keep a finding from becoming unclearable
    noise — the failure that trains a reader to mute the weekly issue, which
    costs the same as not running it:

      * a name that keys to None names no version at all (`latest`, `stable`,
        `nightly`), so there is nothing to order it by and it is not a release;
      * a pre-release counts only when the RECORDED review point is itself a
        pre-release. An upstream that has published `v6.4.0-rc1` has not cut a
        release anybody is obliged to adjudicate, and a finding that only
        clears when the final lands is a weekly reminder with no permitted
        action behind it. Where the register records a pre-release the
        vocabulary is already pre-release-shaped, and the obligation is real.
    """
    allow_pre = recorded is not None and is_prerelease(recorded)
    return [n for n in published
            if release_key(n) is not None
            and (allow_pre or not is_prerelease(n))]


def release_verdict(upstream_id, meta, published):
    """One upstream's release standing: what the register recorded, against what
    upstream publishes.

    Evaluation order is load-bearing:

      1. no `last_reviewed_release`      -> `head-only`, not actionable. RFC
         0019's #511 amendment: a plugin inside a monorepo with no release
         vocabulary has no tag to name, and inventing one is the fabrication
         the register exists to prevent. The absence reaching here is a
         DECLARED one: `validate_release_metadata` refuses any used upstream
         that does not carry `head_only: true` beside it, so this branch can no
         longer be reached by a review point somebody deleted by accident.
      2. the recorded label is not published (INCLUDING an empty published set)
         -> `vanished`, actionable.
      3. it is published, at a different commit -> `moved`, actionable.
      4. the newest candidate outranks it -> `newer`, actionable. This is the
         verdict #535 is about.
      5. otherwise -> `level`, not actionable.

    Rows 2 and 3 look the recorded label up by exact name over the FULL
    published set, never over the candidate list, so an unusually shaped
    recorded label is still FOUND rather than reported as vanished.

    That last choice is DEFENSIVE, and deliberately unobservable: while
    `validate_release_metadata` refuses every recorded label `release_key`
    cannot order, a recorded label is admitted to the candidate list either
    because it is final or because it is a pre-release and therefore turns
    `allow_pre` on — so `recorded in candidates` and `recorded in published`
    agree for every register this tool accepts, and no test can tell the two
    spellings apart. Spelling it over `published` is what keeps that true if the
    validation is ever loosened; do not read the absence of a row for it as
    evidence the clause is dead.

    THE RC DISCRIMINATOR, stated here so it is not rediscovered: rc 1 means the
    query could not be ANSWERED. A published set that merely disagrees with the
    register is reported at rc 0. A vanished `upstream_path` is rc 1 because
    every changed-file count downstream of it is fabricated; a vanished or
    re-tagged release is not — the HEAD diff is still exactly correct, and
    exiting 1 here would abort before `gh issue edit` and suppress the very
    finding this function just made.
    """
    recorded = meta.get("last_reviewed_release")
    candidates = release_candidates(published, recorded)
    newest = max(candidates, key=release_sort_key) if candidates else None

    if recorded is None:
        state, actionable = "head-only", False
    elif recorded not in published:
        state, actionable = "vanished", True
    elif published[recorded] != meta.get("last_reviewed_commit"):
        state, actionable = "moved", True
    # `release_key(recorded)` is total here: `validate_release_metadata` refused
    # the register up front unless the recorded label has a key, precisely so
    # this comparison can never put a tuple against None.
    elif newest is not None and release_key(newest) > release_key(recorded):
        state, actionable = "newer", True
    else:
        state, actionable = "level", False

    return {
        "id": upstream_id,
        "slug": meta.get("repo"),
        "recorded": recorded,
        "recorded_commit": meta.get("last_reviewed_commit"),
        "published_commit": published.get(recorded) if recorded else None,
        "newest": newest,
        "newest_commit": published.get(newest) if newest else None,
        "state": state,
        "actionable": actionable,
    }


def ensure_mirror(work_root, repo_url, repo_slug, refs, fetched):
    """A blobless scratch clone with `refs` fetched into it.

    `fetched` is the set of (repo, *refs) keys already pulled. Components sharing
    one upstream can carry DIFFERENT watermarks, so re-using the clone without
    re-fetching would ask `git` for an object that was never downloaded.
    """
    mirror = work_root / repo_slug.replace("/", "__")
    if not (mirror / ".git").is_dir():
        mirror.mkdir(parents=True, exist_ok=True)
        rc, _, err = run(["git", "init", "--quiet"], cwd=str(mirror))
        if rc != 0:
            fail("could not init a scratch clone for %s: %s" % (repo_slug, err.strip()))
        run(["git", "remote", "add", "origin", repo_url], cwd=str(mirror))
    key = (repo_slug,) + tuple(refs)
    if key not in fetched:
        rc, _, err = run(["git", "fetch", "--quiet", "--no-tags",
                          "--filter=blob:none", "origin"] + list(refs),
                         cwd=str(mirror))
        if rc != 0:
            # Some servers refuse arbitrary-SHA wants; fall back to a full
            # blobless fetch rather than silently reporting nothing.
            rc, _, err2 = run(["git", "fetch", "--quiet", "--no-tags",
                               "--filter=blob:none", "origin"], cwd=str(mirror))
            if rc != 0:
                fail("could not fetch %s from upstream %s: %s"
                     % (", ".join(r[:12] for r in refs), repo_slug,
                        (err2 or err).strip()))
        fetched.add(key)
    return mirror


def assert_upstream_path_exists(mirror, repo_slug, head, path):
    """A declared upstream_path that resolves to nothing upstream is NEWS.

    Without this, a typo'd or upstream-renamed path yields an empty changed-file
    list, which renders as a confident "no drift" every week forever — the exact
    silent-green failure this whole feature exists to detect. Caught by a real
    dry-run against upstream, not by a stub.
    """
    rc, out, err = run(["git", "ls-tree", "--name-only", head, "--", path],
                       cwd=str(mirror))
    if rc != 0:
        fail("git ls-tree failed for %s@%s -- %s: %s"
             % (repo_slug, head[:12], path, err.strip()))
    if not out.strip():
        fail("upstream_path %r does not exist in %s@%s — the register describes "
             "a path upstream has renamed or deleted. That is a finding, not "
             "'no drift'; fix the register before trusting this report."
             % (path, repo_slug, head[:12]))


def evidence_git_paths(register, repo_root, component):
    """`(upstream-relative path, recorded oid)` for each evidenced file.

    The join mirrors `vendor-check.py`'s `component_files_on_disk`: a component
    whose path is a FILE (an agent) *is* that file, so its `files[]` entry is a
    basename and the upstream path is already complete; a directory component
    owns paths relative to its own root. Deciding it from disk rather than from
    the id's shape is what makes this generalise to the multi-file skill
    components #503/#504 will pin.
    """
    root_rel = register.get("root") or "plugins/uberdev"
    upstream_path = component["upstream_path"]
    is_file = (repo_root / root_rel / (component.get("path") or "")).is_file()
    blobs = component["base_evidence"]["blobs"]
    return [(upstream_path if is_file else "%s/%s" % (upstream_path, name), oid)
            for name, oid in sorted(blobs.items())]


def verify_bases(register, repo_root, components, slugs, urls):
    """Re-derive every recorded base against upstream. Never certifies silence.

    Deliberately taken BEFORE `resolve_head`: a base check has no use for
    upstream HEAD, and skipping it keeps this mode cheap and its failure modes
    narrow — an outage while resolving HEAD would otherwise be reported as a
    base that could not be verified.

    A component whose `base_evidence` is malformed exits 2, not 1. That is the
    same separation the drift path keeps: rc 2 means somebody broke the
    register, rc 1 means upstream is unreachable or a base genuinely does not
    verify. `vendor-check.py`'s `C-EVIDENCE` reports the shape defect offline
    with the field named; re-diagnosing it here would be a second, vaguer copy,
    but SKIPPING it would let "unverifiable" render as "verified", which is the
    silent-green class this whole tool exists to refuse.
    """
    work_root = Path(tempfile.mkdtemp(prefix="vendor-bases."))
    verified_files = 0
    verified_components = 0
    try:
        fetched = set()
        for component in components:
            evidence = component.get("base_evidence")
            if evidence is None:
                continue
            cid = component["id"]
            base = component.get("vendored_at_commit")
            # Shape is validated UP FRONT, including every recorded oid. A
            # malformed oid that reached the comparison below would be reported
            # as "upstream holds a different blob" — a confident, wrong
            # diagnosis of a broken register, and on the wrong exit code.
            usable = (isinstance(evidence, dict)
                      and isinstance(evidence.get("blobs"), dict)
                      and evidence["blobs"]
                      and SHA40_RE.match(base or "")
                      and all(isinstance(v, str) and SHA40_RE.match(v)
                              for v in evidence["blobs"].values()))
            if not usable:
                die_usage("component %s declares base_evidence that cannot be "
                          "verified (a non-empty blobs map of 40-hex object ids "
                          "and a 40-hex vendored_at_commit are all required) — "
                          "run tools/vendor/vendor-check.py, whose C-EVIDENCE "
                          "names the offending field" % cid)
            slug = slugs[component["upstream"]]
            mirror = ensure_mirror(work_root, urls[slug], slug, (base,), fetched)
            for upstream_path, recorded in evidence_git_paths(register,
                                                              repo_root,
                                                              component):
                rc, out, err = run(["git", "rev-parse",
                                    "%s:%s" % (base, upstream_path)],
                                   cwd=str(mirror))
                if rc != 0:
                    fail("%s: upstream_path %r does not resolve in %s@%s (rc=%d): "
                         "%s — the recorded base cannot be the base those bytes "
                         "came from, or the path is wrong"
                         % (cid, upstream_path, slug, base[:12], rc,
                            (err or out).strip()))
                found = out.strip()
                if not SHA40_RE.match(found):
                    fail("%s: git rev-parse %s:%s returned %r, which is not an "
                         "object id — refusing to read an unparseable answer as "
                         "a verified base"
                         % (cid, base[:12], upstream_path, found))
                if found != recorded:
                    fail("%s: upstream %s@%s holds blob %s for %s, but "
                         "base_evidence records %s — the recorded base is not "
                         "where these bytes came from"
                         % (cid, slug, base[:12], found, upstream_path,
                            recorded))
                verified_files += 1
            verified_components += 1
            print("vendor-drift: %s verified against %s@%s (%d file(s))"
                  % (cid, slug, base[:12], len(evidence["blobs"])))
    finally:
        shutil.rmtree(work_root, ignore_errors=True)
    if verified_components == 0:
        die_usage("no component declares base_evidence — there is nothing to "
                  "verify, and printing a clean verdict over an empty set would "
                  "be the silent-green failure this mode exists to detect")
    print("vendor-drift: %d component(s), %d file(s) — every recorded base "
          "matches upstream" % (verified_components, verified_files))
    return 0


def changed_paths(mirror, repo_slug, base, head):
    """Changed paths between two upstream commits inside a prepared mirror."""
    if base == head:
        return []
    rc, out, err = run(["git", "diff", "--name-only", "%s..%s" % (base, head)],
                       cwd=str(mirror))
    if rc != 0:
        fail("git diff %s..%s failed for upstream %s: %s"
             % (base[:12], head[:12], repo_slug, err.strip()))
    return [line.strip() for line in out.splitlines() if line.strip()]


def under(prefix, path):
    return path == prefix or path.startswith(prefix.rstrip("/") + "/")


def declared_files(register, component):
    """Component-relative file names whose divergence is explicitly declared."""
    by_id = {p["id"]: p for p in register.get("permanent_divergences", [])
             if p.get("id")}
    names = set()
    for entry in component.get("divergences", []):
        name = entry.get("file")
        if name is None and entry.get("ref") in by_id:
            name = by_id[entry["ref"]].get("file")
        if name:
            names.add(name)
    return names


def release_summary(verdict):
    """One upstream's standing, for the per-id block. Every state renders."""
    state = verdict["state"]
    if state == "head-only":
        # Points at its evidence. The older wording — "as the register declares"
        # — was derived from an ABSENT key, so it affirmed a decision nobody had
        # made and read identically whether the upstream had opted out or had
        # its review point deleted by accident (#604 defect 3). Naming the key
        # makes the sentence earned.
        return ("no recorded release; HEAD-only upstream, as `head_only` in "
                "the register declares")
    recorded = "recorded `%s`" % verdict["recorded"]
    if state == "level":
        return "%s; level with the newest published release" % recorded
    if state == "newer":
        return "%s; upstream has since published `%s`" % (recorded,
                                                          verdict["newest"])
    if state == "vanished":
        return "%s; not published upstream at all" % recorded
    if state == "moved":
        return "%s; published upstream at a different commit" % recorded
    # Unreachable while `release_verdict` is the only producer, and loud rather
    # than silently blank if that ever stops being true: a standing this
    # function cannot describe must not render as an upstream with no standing.
    raise ValueError("unhandled release state %r for upstream %s"
                     % (state, verdict["id"]))


def release_finding_lines(verdict):
    """One `###` block for an actionable verdict: what disagrees, and the edit
    that settles it. A finding with no remedy is one no reader can clear."""
    state = verdict["state"]
    review_point = ("- recorded review point: `%s` (`%s`)"
                    % (verdict["recorded"],
                       (verdict["recorded_commit"] or "")[:12]))
    upstream = "- upstream: `%s`" % verdict["slug"]
    if state == "newer":
        return [
            "### `%s`: upstream published a newer release than the recorded "
            "review point" % verdict["id"],
            "",
            upstream,
            review_point,
            "- newest published release: `%s` (`%s`)"
            % (verdict["newest"], (verdict["newest_commit"] or "")[:12]),
            "- adjudicate that delta under RFC 0019 §7, then advance "
            "`last_reviewed_release` and `last_reviewed_commit` on "
            "`upstreams.%s`. That is the recorded act of having looked."
            % verdict["id"],
            "",
        ]
    if state == "vanished":
        return [
            "### `%s`: the recorded release review point is not published "
            "upstream" % verdict["id"],
            "",
            upstream,
            review_point,
            "- upstream publishes no tag by that name, so the review point "
            "names a release that has been deleted, renamed, or never "
            "existed.",
            "- reconcile `upstreams.%s.last_reviewed_release` with what "
            "upstream publishes; until then no release verdict for this "
            "upstream means anything." % verdict["id"],
            "",
        ]
    if state == "moved":
        return [
            "### `%s`: the recorded release review point is published at a "
            "different commit" % verdict["id"],
            "",
            upstream,
            review_point,
            "- upstream publishes `%s` at `%s`"
            % (verdict["recorded"], (verdict["published_commit"] or "")[:12]),
            "- a release re-tagged in place is not the release that was "
            "reviewed. Re-adjudicate it under RFC 0019 §7 before advancing "
            "anything.",
            "",
        ]
    raise ValueError("release state %r is actionable but has no finding block "
                     "(upstream %s)" % (state, verdict["id"]))


def jsonable(value):
    """One record field, in a form `json.dumps` can serialise deterministically.

    The collection-valued fields a change record carries are `raw` and
    `declared`, the file lists the body renders SORTED. Ordering them here is
    what keeps the fingerprint a function of what the body shows rather than of
    the order `git diff --name-only` happened to print. That ordering is the
    whole reason this function is called. Scalars pass through untouched.

    It exists so that "copy the whole record" can stay literal: the alternative
    is a hand-picked list of the fields that happen to serialise, which is the
    subset that #604 defect 2 is about.

    `set` and `frozenset` are named in the isinstance tuple DEFENSIVELY, and
    nothing reaches them: `main()` builds `raw` and `declared` as lists, and the
    one set this module does build (`declared_files`' component-relative names)
    is membership-tested at the call site and never stored on a record. So
    "`json.dumps` refuses a set outright" is a hazard this module cannot
    currently produce, and it is not why the helper exists; the two names are
    there so a set arriving later is ordered like every other collection
    instead of ending the run in a TypeError. Do not read the absence of a test
    for that arm as evidence the arm is the point.
    """
    if isinstance(value, (set, frozenset, list, tuple)):
        return sorted(value)
    return value


def tag_observation(published):
    """What the `Upstream tags resolved this run` line says about one slug.

    Exactly three facts — how many tags the remote publishes, which published
    name is the newest version, and the commit that one points at — so the line
    and the fingerprint payload are two spellings of ONE triple instead of two
    traversals of the raw tag map that can quietly disagree. `newest` is None
    when nothing published keys to a version, which is the case the line reports
    as "none of them names a version"; `count` is 0 when the remote publishes
    nothing at all, which is the case it reports as "no published tags".

    The raw `{name: commit}` map is deliberately NOT what gets hashed: the line
    never shows a per-tag sha, so hashing them would move the fingerprint for a
    re-tag the body cannot express, and the payload would be reporting a fact
    the report does not carry.

    That is a rule about WHICH facts, not about how precisely each one is
    carried. `newest_commit` goes into the payload at full length even though
    the line renders only its first twelve hex — D-REL20's `oc3` is that gap,
    declared over-covered rather than trimmed. Hash what the body mentions, at
    whatever precision this function has; do not hash what it never mentions.

    `newest` is chosen over every name that keys to a version, pre-releases
    INCLUDED. This block is a neutral observation of what a remote publishes,
    not a verdict; `release_candidates`' pre-release policy exists to keep an
    unclearable FINDING out of the report, and applying it here would make the
    observation misreport what upstream has actually published.
    """
    named = [name for name in published if release_key(name) is not None]
    newest = max(named, key=release_sort_key) if named else None
    return {"count": len(published), "newest": newest,
            "newest_commit": published[newest] if newest is not None else None}


def build_report(register, heads, tags, verdicts, changes):
    """Render the markdown body plus a stable fingerprint of its drift payload."""
    drifting = [c for c in changes if c["raw"]]
    declared_only = [c for c in changes if not c["raw"] and c["declared"]]
    actionable = sorted([v for v in verdicts if v["actionable"]],
                        key=lambda v: v["id"])

    # ONE observations object, hashed whole. Every fact the body renders below
    # has to be reachable from here, because the fingerprint is what decides
    # whether an ALREADY-OPEN issue gets a comment — and main() edits the body
    # FIRST, then compares. So a fact the body renders and this object omits is
    # a body that gets rewritten under every subscriber in total silence.
    #
    # That is #604 defect 2, and its reproduction is quiet enough to have gone
    # unnoticed for a release: upstream deletes an old tag without moving HEAD.
    # No watermark moves, no file changes, the verdict stays `level` — only the
    # published-tag count in the body moves, and the payload never carried it.
    #
    # OVER-COVERAGE IS THE ACCEPTED DIRECTION, stated here because the pressure
    # runs the other way. A payload wider than the body costs at most one
    # redundant comment; a payload narrower than the body costs a silent
    # rewrite. D-REL20's `oc*` rows name ONE case in each class where this
    # object is deliberately wider — a declared-only component's fields, a
    # `raw` path past the listed cap, a sha past the twelve hex the body
    # renders, a non-actionable verdict's field — so a narrowing that lands on
    # one of them reds.
    #
    # They are EXAMPLES, not an enumeration, and the difference is not laziness:
    # a differential row can only pin a field that MOVES while its record's
    # class holds still, and a field that is constant across its whole class —
    # a head-only verdict's `recorded` and, with it, its `published_commit`,
    # both None for every upstream that stands that way — cannot be pinned that
    # way at all. Narrowing this object is therefore a decision to take
    # deliberately and to argue for HERE; the suite reds some narrowings, not
    # every one, and is not the backstop.
    observations = {
        "heads": heads,
        # The `Upstream tags resolved this run` block, carried as the triple
        # that line is a pure function of rather than as the raw tag map — see
        # `tag_observation`. Without this key the deleted-tag scenario above has
        # no representation in the payload at all.
        "tags": {slug: tag_observation(published)
                 for slug, published in tags.items()},
        # The whole change record, minus its key — never a hand-picked subset.
        # `{head, raw, declared}` left `stance`, `base`, `repo` and
        # `upstream_path` uncovered, and the component block renders EVERY one
        # of the four: `stance` in the `### <id> — stance` heading, `repo` and
        # `upstream_path` on the `- upstream:` line, `base` on the `- watermark`
        # line. So advancing a watermark, re-stating a stance or re-pointing an
        # upstream moved the body and nothing else. D-REL20 executes that list
        # field by field — rows d, e, g and h are those four — rather than
        # leaving it to be re-read off the render. The `raw or declared` filter
        # STAYS: a component that renders nothing must not move the fingerprint.
        "components": {c["id"]: {key: jsonable(value)
                                 for key, value in c.items()
                                 if key not in FINGERPRINT_COMPONENT_SKIP}
                       for c in changes if c["raw"] or c["declared"]},
        # EVERY verdict, not the actionable ones alone: `Recorded release review
        # points` renders all of them, so a move between two NON-actionable
        # standings — `head-only` -> `level`, the transition #604 names —
        # rewrote that block while the payload stayed byte-identical. The
        # actionable ones still have to be here for the original reason: without
        # them a freshly cut release with an unchanged file set fingerprints
        # identically to last week, the body is refreshed, the comparison
        # matches, and the news lands where nobody is watching.
        #
        # Each entry is the VERDICT ITSELF, minus its key — never a hand-picked
        # subset of its fields. A finding can only render what the verdict
        # carries, so copying the whole thing is what keeps "the body changed,
        # the fingerprint did not" unreachable; a subset re-opens that hole the
        # moment a finding renders a datum nobody remembered to list.
        # `published_commit` is the one that proved it: it is the `moved`
        # finding's only variable line, and `newest_commit` stops covering it as
        # soon as a newer release sits above the re-tagged review point — which
        # is exactly when a re-tag is worth telling somebody about.
        "releases": {v["id"]: {key: value for key, value in v.items()
                               if key not in FINGERPRINT_VERDICT_SKIP}
                     for v in verdicts},
    }
    payload = json.dumps(observations, sort_keys=True)
    fingerprint = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:32]

    lines = [MARKER, ""]
    lines.append("# Vendored upstream drift")
    lines.append("")
    lines.append("Generated by `tools/vendor/vendor-drift.py` from "
                 "`plugins/uberdev/vendor.json`. Policy: "
                 "`docs/rfc/0019-vendored-upstream-policy.md`.")
    lines.append("")
    lines.append("Upstream HEADs resolved this run:")
    lines.append("")
    for slug in sorted(heads):
        lines.append("- `%s` @ `%s`" % (slug, heads[slug]))
    lines.append("")

    # The second observable (#535). HEAD drift and release drift disagree in both
    # directions — unreleased commits are drift the register has no obligation to
    # chase, and a freshly cut release can land on a HEAD that has not moved since
    # the last run — so what each remote PUBLISHES is reported in its own right.
    # This block is a neutral OBSERVATION, keyed by slug because a tag query is
    # answered by a repository, not by a vendored component.
    lines.append("Upstream tags resolved this run:")
    lines.append("")
    # Rendered from `tag_observation` — the same call the payload above hashes —
    # so the three spellings below and the hashed triple cannot come apart. A
    # second `max(..., key=release_sort_key)` here would be a second answer to
    # "which tag is newest", and the report and its own fingerprint would then
    # be able to disagree about it.
    for slug in sorted(tags):
        seen = tag_observation(tags[slug])
        if not seen["count"]:
            lines.append("- `%s`: no published tags" % slug)
        elif seen["newest"] is None:
            lines.append("- `%s`: %d published tag(s); none of them names a "
                         "version" % (slug, seen["count"]))
        else:
            lines.append("- `%s`: %d published tag(s); newest `%s` (`%s`)"
                         % (slug, seen["count"], seen["newest"],
                            seen["newest_commit"][:12]))
    lines.append("")

    # The verdicts, keyed by upstream ID and never by slug. Two ids can name two
    # plugins inside ONE monorepo — they share a slug, and therefore a tag list
    # — so slug-keying would attach that repository's releases to an upstream
    # the register deliberately refuses to invent a label for. Every used
    # upstream appears, including the HEAD-only ones: "this upstream has no
    # release vocabulary" is a standing the report states, not a silence.
    lines.append("Recorded release review points:")
    lines.append("")
    for verdict in sorted(verdicts, key=lambda v: v["id"]):
        lines.append("- `%s` (`%s`): %s"
                     % (verdict["id"], verdict["slug"],
                        release_summary(verdict)))
    lines.append("")

    # Above the component diff: RFC 0019 §7 adjudicates releases, so a release
    # awaiting adjudication is the more actionable of the two findings, and
    # rendered only when there is one — an empty standing heading every week is
    # the noise that gets an issue muted.
    if actionable:
        lines.append("## Releases awaiting adjudication")
        lines.append("")
        lines.append("RFC 0019 §7 adjudicates releases rather than individual "
                     "commits, so these come before the component diff below.")
        lines.append("")
        for verdict in actionable:
            lines.extend(release_finding_lines(verdict))

    if not drifting:
        # The component-scoped sentence is true either way; the `**No drift.**`
        # lead is not. A report carrying a release finding has drift — of the
        # kind RFC 0019 §7 cares most about — so leading with "no drift" would
        # contradict the section directly above it.
        settled = ("Every vendored component is level with its recorded "
                   "watermark, or its only changes are declared divergences.")
        lines.append(settled if actionable else "**No drift.** " + settled)
    else:
        lines.append("## Components with upstream changes since their watermark")
        lines.append("")
        for c in sorted(drifting, key=lambda x: x["id"]):
            lines.append("### `%s` — stance `%s`" % (c["id"], c["stance"]))
            lines.append("")
            lines.append("- upstream: `%s` (`%s`)" % (c["repo"], c["upstream_path"]))
            lines.append("- watermark `%s` -> HEAD `%s`" % (c["base"], c["head"]))
            shown = sorted(c["raw"])[:MAX_LISTED_FILES]
            residual = len(c["raw"]) - len(shown)
            lines.append("- changed upstream files (%d):" % len(c["raw"]))
            for path in shown:
                lines.append("  - `%s`" % path)
            if residual > 0:
                lines.append("  - …and %d more" % residual)
            if c["declared"]:
                lines.append("- declared divergences also touched upstream "
                             "(review, do not merge blindly): %s"
                             % ", ".join("`%s`" % p for p in sorted(c["declared"])))
            lines.append("")

    if declared_only:
        lines.append("## Changed only inside declared divergences")
        lines.append("")
        lines.append("These components saw upstream changes confined to files "
                     "RFC 0019 §6 records as never-reconcile. Reported as "
                     "**declared**, not as raw drift.")
        lines.append("")
        for c in sorted(declared_only, key=lambda x: x["id"]):
            lines.append("- `%s` — declared: %s"
                         % (c["id"], ", ".join("`%s`" % p for p in sorted(c["declared"]))))
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("%s %s" % (FINGERPRINT_KEY, fingerprint))
    lines.append("")
    lines.append("Advance a component's `last_reviewed_upstream_commit` in "
                 "`plugins/uberdev/vendor.json` once its delta has been triaged. "
                 "That is the recorded act of having looked.")
    # The third value is what main() gates issue creation on, so it has to cover
    # BOTH findings. Reporting only component drift here would render a release
    # finding into a body no issue is ever opened for — #535's failure moved one
    # layer down, and invisible in exactly the same way.
    return "\n".join(lines) + "\n", fingerprint, bool(drifting) or bool(actionable)


def find_tracking_issue(limit):
    rc, out, err = run(["gh", "issue", "list", "--state", "open",
                        "--limit", str(limit), "--json", "number,body"])
    if rc != 0:
        fail("gh issue list failed (rc=%d): %s" % (rc, (err or out).strip()))
    try:
        issues = json.loads(out or "[]")
    except ValueError as exc:
        fail("gh issue list returned unparseable JSON: %s" % exc)
    for issue in issues:
        if MARKER in (issue.get("body") or ""):
            if not issue.get("number"):
                fail("gh issue list returned a marker-carrying issue with no "
                     "number — refusing to guess which issue to edit")
            return issue
    return None


def existing_fingerprint(issue):
    match = FINGERPRINT_RE.search(issue.get("body") or "")
    return match.group(1) if match else None


def write_body(body):
    handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False,
                                         encoding="utf-8")
    handle.write(body)
    handle.close()
    return handle.name


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=None,
                        help="repository root to read the register from")
    # The two modes are mutually exclusive through argparse rather than through
    # a hand-rolled guard, so passing both is a usage error argparse reports
    # itself (rc 2) instead of one flag being silently ignored by the other.
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="render the report to stdout and touch GitHub not at all")
    mode.add_argument("--verify-bases", action="store_true",
                      help="re-derive every recorded base_evidence blob against "
                           "upstream and exit; touches GitHub not at all")
    parser.add_argument("--issue-limit", type=int, default=100,
                        help="how many open issues to scan for the marker")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve() if args.repo_root \
        else Path(__file__).resolve().parents[2]
    register_path = repo_root / REGISTER_REL
    if not register_path.is_file():
        die_usage("no register at %s" % register_path)
    register = load_register(register_path)

    upstreams = register.get("upstreams", {})
    components = [c for c in register.get("components", [])
                  if c.get("origin") == "third-party"]
    if not components:
        die_usage("the register declares no third-party components — nothing to "
                  "diff, which is a broken register rather than a clean tree")
    # Before the first network call, so a malformed register can never be
    # mistaken for — or spend the clone budget of — an unreachable upstream.
    for component in components:
        absent = [k for k in REQUIRED_COMPONENT_KEYS if not component.get(k)]
        if absent:
            die_usage("component %s declares no %s — the register is malformed, "
                      "which is not the same as an unreachable upstream"
                      % (component.get("id") or component.get("path") or "<no id>",
                         ", ".join(absent)))

    used = sorted({c["upstream"] for c in components})
    slugs = {}
    urls = {}
    for upstream_id in used:
        upstream = upstreams.get(upstream_id)
        if not upstream:
            die_usage("component references undeclared upstream %r" % upstream_id)
        slug = upstream.get("repo")
        if not slug:
            die_usage("upstream %r declares no repo — there is nothing to clone"
                      % upstream_id)
        slugs[upstream_id] = slug
        urls.setdefault(slug, upstream.get("url") or UPSTREAM_HOST + slug)
        # In the same pass as the coordinates, and on the same side of the
        # --verify-bases return, so both modes reach one register verdict
        # instead of two that can disagree about whether it is readable.
        validate_release_metadata(upstream_id, upstream)

    # Base verification needs coordinates and nothing else, so it returns before
    # a single HEAD is resolved (see verify_bases' docstring).
    if args.verify_bases:
        return verify_bases(register, repo_root, components, slugs, urls)

    heads = {}
    for upstream_id in used:
        slug = slugs[upstream_id]
        if slug in heads:
            continue
        heads[slug] = resolve_head(urls[slug], slug)

    # One tag query per distinct SLUG, not per upstream id and not per component:
    # two upstream ids can name two plugins inside ONE monorepo, and asking that
    # remote twice would double the network cost to answer the same question.
    tags = {}
    for upstream_id in used:
        slug = slugs[upstream_id]
        if slug in tags:
            continue
        tags[slug] = resolve_tags(urls[slug], slug)

    # One verdict per upstream ID, off the tag list its slug published. The
    # query is answered per repository; the REVIEW POINT is recorded per
    # upstream, and two upstream ids sharing a monorepo record different ones
    # (or none at all).
    verdicts = [release_verdict(upstream_id, upstreams[upstream_id],
                                tags[slugs[upstream_id]])
                for upstream_id in used]

    work_root = Path(tempfile.mkdtemp(prefix="vendor-drift."))
    try:
        cache = {}
        checked_paths = set()
        fetched = set()
        changes = []
        for component in components:
            slug = upstreams[component["upstream"]]["repo"]
            head = heads[slug]
            base = component["last_reviewed_upstream_commit"]
            refs = (head,) if base == head else (base, head)
            mirror = ensure_mirror(work_root, urls[slug], slug, refs, fetched)
            prefix = component["upstream_path"]
            if (slug, head, prefix) not in checked_paths:
                assert_upstream_path_exists(mirror, slug, head, prefix)
                checked_paths.add((slug, head, prefix))
            key = (slug, base, head)
            if key not in cache:
                cache[key] = changed_paths(mirror, slug, base, head)
            touched = [p for p in cache[key] if under(prefix, p)]
            declared = declared_files(register, component)
            raw, dec = [], []
            for path in touched:
                # A component that IS a file (an agent) declares divergences by
                # basename; a directory component declares them relative to its
                # own root.
                rel = (path.rsplit("/", 1)[-1] if path == prefix
                       else path[len(prefix):].lstrip("/"))
                (dec if rel in declared else raw).append(path)
            changes.append({
                "id": component["id"], "repo": slug, "stance": component["stance"],
                "upstream_path": prefix, "base": base, "head": head,
                "raw": raw, "declared": dec,
            })

        body, fingerprint, reportable = build_report(register, heads, tags,
                                                     verdicts, changes)
    finally:
        shutil.rmtree(work_root, ignore_errors=True)

    if args.dry_run:
        sys.stdout.write(body)
        return 0

    issue = find_tracking_issue(args.issue_limit)

    # `reportable` covers component drift AND an actionable release verdict: a
    # release nobody has adjudicated is news even in a week when not one
    # vendored file changed, which is the whole of #535.
    if not reportable and issue is None:
        print("vendor-drift: no drift, no release awaiting adjudication, and "
              "no open tracking issue — nothing to do.")
        return 0

    body_file = write_body(body)
    try:
        if issue is None:
            rc, out, err = run(["gh", "issue", "create", "--title", ISSUE_TITLE,
                                "--body-file", body_file])
            if rc != 0:
                fail("gh issue create failed (rc=%d): %s" % (rc, (err or out).strip()))
            print("vendor-drift: opened the tracking issue: %s" % out.strip())
            return 0

        number = issue["number"]
        rc, out, err = run(["gh", "issue", "edit", str(number),
                            "--body-file", body_file])
        if rc != 0:
            fail("gh issue edit failed for #%s (rc=%d): %s"
                 % (number, rc, (err or out).strip()))
        if existing_fingerprint(issue) == fingerprint:
            print("vendor-drift: refreshed #%s; fingerprint unchanged, no comment."
                  % number)
            return 0
        rc, out, err = run(["gh", "issue", "comment", str(number),
                            "--body", "Drift set changed. New fingerprint `%s`."
                                      % fingerprint])
        if rc != 0:
            fail("gh issue comment failed for #%s (rc=%d): %s"
                 % (number, rc, (err or out).strip()))
        print("vendor-drift: refreshed #%s and flagged the changed drift set."
              % number)
        return 0
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
