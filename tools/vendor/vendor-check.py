#!/usr/bin/env python3
"""tools/vendor/vendor-check.py — the offline guard for the vendored register.

WHY THIS EXISTS (#434). UberDev vendors 20 third-party components: 14 skill
directories derived from `obra/superpowers` and 6 reviewer/simplifier agents
derived from `anthropics/claude-plugins-official`. Their provenance was spelled
three incompatible ways — in-file `Vendored from …@<sha>` headers on 20 files
across 3 directories, a README table naming upstreams but no commits, and three
licence texts with no versions — and nothing compared any spelling to any other
or to disk. Undeclared drift was the result: upstream fixed `find-polluter.sh`
in v6.2.0 and this repo shipped the broken copy for months (#430).

`plugins/uberdev/vendor.json` is now the single register. This script is its
OFFLINE guard: it reads only the working tree, never the network. Comparing
against upstream is `tools/vendor/vendor-drift.py`'s job, and mixing the two
would make a network outage look like a clean tree.

Every failure prints its own check id so a test can assert *why* the guard went
red. "Red for the wrong reason" is not coverage. C-SCHEMA reports a malformed
register but deliberately does NOT abort — the Failures collector exists so one
run names every broken invariant — so every later check reads register fields
defensively. A missing key must surface as a named `FAIL`, never as a KeyError
traceback that suppresses the checks queued behind it.

    C-SCHEMA     register shape: schema literal, required keys, unique ids,
                 commits are 40-hex or the explicit literal "unknown", no
                 duplicate JSON keys
    C-COVER      on-disk skill dirs + agent files == declared component paths,
                 both directions; aborts rather than passing if either side is
                 empty
    C-FILES      per component: recorded file list == disk. For DIGEST-LOCKED
                 components — `stance: track`, or any component that records a
                 real `vendored_at_commit` (#503) — the sha256 must match too,
                 unless the change is declared in divergences[]
    C-HEADER     every in-file provenance header agrees with its component's
                 upstream repo and vendored_at_commit; asserts >= 1 header was
                 found before reporting agreement
    C-BASE       the converse of C-HEADER: every recorded vendored_at_commit is
                 witnessed by a matching in-file provenance header on one of the
                 component's own files; fails rather than passing over an empty
                 pinned set
    C-EVIDENCE   every declared base_evidence object is well-formed: a known
                 method, a 40-hex vendored_ref, a blobs map keyed exactly by the
                 component's own files[] with 40-hex values, and a pinned
                 component behind it; fails rather than passing over an empty set
    C-README     README Bundled-table third-party slugs == third-party
                 component slugs, both directions
    C-LICENSE    every declared licence file exists, and every file under
                 licenses/ is referenced by some upstream
    C-STANCE     stance in {track, fork} with a non-empty reason, or
                 origin == "uberdev" and no stance; never "undecided"
    C-WATERMARK  40-hex last_reviewed_upstream_commit + ISO last_reviewed_on on
                 every third-party component
    C-REFS       every relative sibling file a declared markdown document points
                 at (`@ref` or `](link)`, outside code) resolves on disk;
                 aborts rather than passing if it found no reference at all
    C-DIVREF     every components[].divergences[].ref resolves to a declared
                 permanent_divergences[].id, for every component regardless of
                 stance

Repo-agnostic: no organisation, project id or repository name is hardcoded. All
upstream coordinates come from the register.

Usage:
    vendor-check.py [--repo-root DIR] [--only CHECK-ID ...]
    vendor-check.py --refresh [--repo-root DIR]

`--refresh` recomputes file lists and digest-locked digests from disk. It NEVER
invents a `vendored_at_commit`, and no test may call it: a producer must not be
its own oracle.

Exit codes:
    0  the tree and the register agree
    1  a check failed
    2  usage error, or an unreadable/unparseable input
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SCHEMA = "uberdev-vendor-v1"
PLUGIN_REL = "plugins/uberdev"
REGISTER_REL = PLUGIN_REL + "/vendor.json"
LICENSES_REL = "licenses"

SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ISO_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
UNKNOWN = "unknown"

# Leader-agnostic on purpose. The 20 header-carrying files use three comment
# leaders (`<!--`, `#`, `//`) and five distinct trailing-clause spellings, so
# anchoring on `<!--` would silently skip the shell and JavaScript copies — the
# exact "the guard cannot see half its corpus" failure this repo keeps hitting.
HEADER_RE = re.compile(r"Vendored from ([^@\s]+)@([0-9a-f]{40})")

# C-REFS. A shipped document that tells an agent to read a sibling file is a
# claim about disk that no register field carries, so nothing else here can
# check it. Fenced blocks AND inline code spans are stripped before scanning:
# skills/writing-skills documents the `@`-ref convention by quoting a BAD
# example inside backticks, and a scan that read it would report a dangling
# reference against a file that is deliberately describing what not to write.
FENCE_RE = re.compile(r"^\s*(?:```|~~~)")
CODESPAN_RE = re.compile(r"`[^`]*`")
# The lookbehind is what separates a REFERENCE from an ADDRESS. An `@`-ref is a
# standalone token (`See @graphviz-conventions.dot`); an email, a package pin
# (`pkg@1.2.3`) and a tag pin (`obra/superpowers@v6.2.0`) all carry a local part
# immediately before the `@`. Without it every one of those parses as a sibling
# file — `x@y.com` yields `y.com` — and reds this check against a document that
# references nothing at all.
AT_REF_RE = re.compile(r"(?<![A-Za-z0-9._-])@([A-Za-z0-9._][A-Za-z0-9._/-]*\.[A-Za-z0-9]+)")
MD_LINK_RE = re.compile(r"\]\(([^)\s]+)")

# The CLOSED component key set (C-SCHEMA). Every member value already had a
# validator; the RECORD itself did not, so an unrecognised key passed silently
# and a misspelling was indistinguishable from an omission. That mattered most
# on the optional sub-record: `check_evidence` skips any component whose
# `base_evidence` lookup yields None, and its vacuity arm fires only when ZERO
# components declare evidence — so one mistyped key dropped that component out of
# the measurement while the whole register stayed green, which is precisely the
# unfalsifiable-claim state `base_evidence` was added to eliminate. Mirrors the
# `additionalProperties: false` discipline the sibling JS schemas already use.
#
# Add a member here when the register grows one. That is the point: growing the
# record is a decision, and an undeclared key is a typo until somebody says
# otherwise.
COMPONENT_KEYS = frozenset({
    "id", "path", "origin",
    "upstream", "upstream_path", "vendored_at_commit", "vendored_on",
    "last_reviewed_upstream_commit", "last_reviewed_on",
    "stance", "stance_reason",
    "measured_diff_lines", "measured_diff_basis",
    "divergences", "files", "base_evidence",
})

# Files whose bytes are never text we can scan for a provenance header.
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip",
                   ".woff", ".woff2", ".ttf", ".otf", ".mp4", ".webp"}

ALL_CHECKS = ("C-SCHEMA", "C-COVER", "C-FILES", "C-HEADER", "C-BASE",
              "C-EVIDENCE", "C-README", "C-LICENSE", "C-STANCE", "C-WATERMARK",
              "C-REFS", "C-DIVREF")

# The only recovery method this register knows how to state. A second method
# would need its own required fields, so an unrecognised literal is refused
# rather than waved through: "evidenced by something we cannot check" is exactly
# the unfalsifiable claim `base_evidence` exists to replace.
EVIDENCE_METHODS = ("blob-identity",)


class Failures:
    """Collects failures so one run reports every broken invariant at once."""

    def __init__(self):
        self.items = []

    def add(self, check, message):
        self.items.append((check, message))
        print("FAIL %s: %s" % (check, message))

    def __bool__(self):
        return bool(self.items)


def die_usage(message):
    print("vendor-check: %s" % message, file=sys.stderr)
    raise SystemExit(2)


def no_duplicate_keys(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError("duplicate JSON key: %r" % key)
        seen[key] = value
    return seen


def load_register(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die_usage("cannot read register %s: %s" % (path, exc))
    try:
        return json.loads(text, object_pairs_hook=no_duplicate_keys)
    except ValueError as exc:
        die_usage("register %s is not valid JSON: %s" % (path, exc))


def sha256_of(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def disk_paths(plugin_dir):
    """The two on-disk component sets, as `skills/<dir>` and `agents/<file>`."""
    skills_dir = plugin_dir / "skills"
    agents_dir = plugin_dir / "agents"
    if not skills_dir.is_dir():
        die_usage("no skills directory under %s" % plugin_dir)
    if not agents_dir.is_dir():
        die_usage("no agents directory under %s" % plugin_dir)
    skills = {"skills/%s" % p.name for p in skills_dir.iterdir() if p.is_dir()}
    agents = {"agents/%s" % p.name for p in agents_dir.iterdir() if p.is_file()}
    return skills, agents


def component_files_on_disk(plugin_dir, component):
    path = component.get("path")
    if not path:
        # A pathless entry is C-SCHEMA's finding. Reporting it as "absent" here
        # lets every caller keep its own named failure instead of dying on a key
        # the register never proved was there.
        return None
    root = plugin_dir / path
    if root.is_file():
        return [root.name]
    if not root.is_dir():
        return None
    found = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            found.append(path.relative_to(root).as_posix())
    return sorted(found)


def declared_file_paths(component):
    out = []
    for entry in component.get("files", []):
        name = entry.get("path") if isinstance(entry, dict) else entry
        # A files[] entry with no usable path is malformed. "" keeps the sort
        # total and can never equal a disk name, so the comparison in C-FILES
        # disagrees and reports it by check id instead of raising here.
        out.append(name if isinstance(name, str) else "")
    return sorted(out)


def divergence_files(component):
    """Files whose byte-level change is explicitly declared for this component."""
    out = set()
    for entry in component.get("divergences", []):
        name = entry.get("file")
        if name:
            out.add(name)
    return out


def third_party(register):
    return [c for c in register.get("components", [])
            if c.get("origin") == "third-party"]


def is_pinned(component):
    """True when the component records a real base commit rather than "unknown"."""
    return bool(SHA40_RE.match(component.get("vendored_at_commit") or ""))


def digest_locked(component):
    """Whether C-FILES must hold this component's bytes to a recorded sha256.

    RFC 0019 §2.3 originally tied the lock to `stance: track` alone. #503 found
    what that coupling costs: honestly re-adjudicating a component to `fork` —
    which §4.1 obliges the moment a real local divergence is declared — deleted
    its digest lock at the same instant its provenance improved. A pinned `fork`
    was then a component whose shipped bytes claimed a base, in an in-file header
    C-HEADER validates, with nothing holding the bytes to that claim: edit the
    file and every check stayed green.

    `stance` answers a policy question (do we re-baseline from upstream?).
    The digest answers an evidence question (have our bytes moved since we
    recorded them?). They are different questions, so the lock follows the PIN as
    well as the stance: recording a base is the act that puts bytes under it.
    An unpinned `fork` stays unlocked — we own those bytes and edits are expected.
    """
    return component.get("stance") == "track" or is_pinned(component)


def component_id(component):
    """The name to report a component by, even when it declares no `id`.

    Every check runs after C-SCHEMA has merely *reported* a malformed register,
    so each one must be able to name a component it has not been proven
    well-formed. Deliberately does NOT fall back to `path`: C-SCHEMA detects a
    missing id by comparing this against `path`, and a path-shaped fallback
    would make that comparison agree with itself.
    """
    return component.get("id") or "<no id>"


def slug_of(component):
    """The README slug for a component, or None when it declares no path."""
    path = component.get("path")
    if not path:
        return None
    name = path.rsplit("/", 1)[-1]
    return name[:-3] if name.endswith(".md") else name


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_schema(register, failures):
    if register.get("schema") != SCHEMA:
        failures.add("C-SCHEMA", "schema is %r, expected %r"
                     % (register.get("schema"), SCHEMA))
    for key in ("upstreams", "components", "permanent_divergences"):
        if key not in register:
            failures.add("C-SCHEMA", "register has no %r key" % key)
    components = register.get("components", [])
    if not isinstance(components, list):
        failures.add("C-SCHEMA", "components is not a list")
        return
    # Id-less entries are reported per-component below, and are excluded here so
    # two of them cannot masquerade as a duplicate-id finding — and so the sort
    # never compares None against a string, which raises TypeError.
    ids = [c.get("id") for c in components if c.get("id")]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        failures.add("C-SCHEMA", "duplicate component ids: %s" % dupes)
    upstreams = register.get("upstreams", {})
    for component in components:
        cid = component_id(component)
        if not component.get("id"):
            failures.add("C-SCHEMA", "a component declares no id (path %r)"
                         % component.get("path"))
        elif component.get("path") != cid:
            failures.add("C-SCHEMA", "%s: id and path disagree" % cid)
        # Reported for EVERY component, before the origin arms below start
        # `continue`-ing: an unrecognised key on an `uberdev` component is the
        # same defect and would otherwise never be looked at.
        #
        # No isinstance() guard here: a non-dict component has already raised on
        # `.get` in the id sweep above, so a guard at this point can never be
        # false and would only read as protection this loop does not have.
        # Moving a real guard to the top of the loop — check_divref's idiom —
        # would SWALLOW the AttributeError C-SCHEMA currently dies on, so that
        # belongs in a change that owns the decision.
        unknown = sorted(set(component) - COMPONENT_KEYS)
        if unknown:
            failures.add("C-SCHEMA", "%s: unrecognised component key(s) %s "
                                     "— a misspelled optional record must "
                                     "not read as an absent one" % (cid, unknown))
        origin = component.get("origin")
        if origin not in ("third-party", "uberdev"):
            failures.add("C-SCHEMA", "%s: origin is %r, expected 'third-party' "
                                     "or 'uberdev'" % (cid, origin))
            continue
        if origin == "uberdev":
            continue
        upstream = component.get("upstream")
        if upstream not in upstreams:
            failures.add("C-SCHEMA", "%s: upstream %r has no upstreams entry"
                         % (cid, upstream))
        if not component.get("upstream_path"):
            failures.add("C-SCHEMA", "%s: no upstream_path" % cid)
        vendored = component.get("vendored_at_commit")
        if vendored != UNKNOWN and not SHA40_RE.match(vendored or ""):
            failures.add("C-SCHEMA", "%s: vendored_at_commit is neither 40-hex "
                                     "nor the literal %r" % (cid, UNKNOWN))
        if not ISO_DATE_RE.match(component.get("vendored_on") or ""):
            failures.add("C-SCHEMA", "%s: vendored_on is not an ISO date" % cid)
    for upstream_id, upstream in upstreams.items():
        repo = upstream.get("repo", "")
        if repo.count("/") != 1 or not all(repo.split("/")):
            failures.add("C-SCHEMA", "upstream %r repo is not owner/name: %r"
                         % (upstream_id, repo))


def check_cover(register, plugin_dir, failures):
    skills, agents = disk_paths(plugin_dir)
    if not skills:
        failures.add("C-COVER", "no skill directories found on disk — the scan "
                                "is misrooted, not the tree empty")
        return
    if not agents:
        failures.add("C-COVER", "no agent files found on disk — the scan is "
                                "misrooted, not the tree empty")
        return
    disk = skills | agents
    # A pathless entry contributes nothing here (C-SCHEMA reports it); keeping
    # None out also keeps the two sorts below from comparing it against a str.
    declared = {c.get("path") for c in register.get("components", []) if c.get("path")}
    if not declared:
        failures.add("C-COVER", "the register declares no components while %d "
                                "exist on disk" % len(disk))
        return
    undeclared = sorted(disk - declared)
    phantom = sorted(declared - disk)
    if undeclared:
        failures.add("C-COVER", "on disk but not declared: %s" % undeclared)
    if phantom:
        failures.add("C-COVER", "declared but not on disk: %s" % phantom)


def check_files(register, plugin_dir, failures):
    for component in third_party(register):
        cid = component_id(component)
        on_disk = component_files_on_disk(plugin_dir, component)
        if on_disk is None:
            # Absence — a missing directory, or an entry with no `path` at all —
            # is C-COVER's and C-SCHEMA's finding; do not double-report it here.
            continue
        declared = declared_file_paths(component)
        if declared != on_disk:
            missing = sorted(set(on_disk) - set(declared))
            phantom = sorted(set(declared) - set(on_disk))
            failures.add("C-FILES", "%s: file list disagrees with disk "
                                    "(undeclared=%s declared-but-absent=%s)"
                         % (cid, missing, phantom))
            continue
        if not digest_locked(component):
            continue
        why = "stance is track" if component.get("stance") == "track" \
            else "it records base %s" % str(component.get("vendored_at_commit"))[:12]
        excused = divergence_files(component)
        root = plugin_dir / component["path"]  # non-None: on_disk proved it
        for entry in component.get("files", []):
            if not isinstance(entry, dict):
                failures.add("C-FILES", "%s: %s but files[] carries a bare path "
                                        "(%r) with no digest" % (cid, why, entry))
                continue
            # Non-None: the equality against `on_disk` above already proved every
            # declared path is a real disk name.
            rel = entry.get("path")
            recorded = entry.get("sha256", "")
            if not SHA256_RE.match(recorded):
                failures.add("C-FILES", "%s: %s has no valid sha256" % (cid, rel))
                continue
            actual = sha256_of(root / rel if root.is_dir() else root)
            if actual != recorded and rel not in excused:
                failures.add("C-FILES", "%s: %s changed on disk and the change "
                                        "is not declared in divergences[] "
                                        "(recorded %s, disk %s)"
                             % (cid, rel, recorded[:12], actual[:12]))


def check_header(register, plugin_dir, failures):
    by_path = {c["path"]: c for c in register.get("components", []) if c.get("path")}
    upstreams = register.get("upstreams", {})
    found = 0
    for path in sorted(plugin_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() in BINARY_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        match = HEADER_RE.search(text)
        if not match:
            continue
        found += 1
        rel = path.relative_to(plugin_dir).as_posix()
        owner_repo, sha = match.group(1), match.group(2)
        # Longest-prefix walk: an agent component IS the file (`agents/x.md`),
        # a skill component OWNS arbitrarily nested files under its directory.
        component = None
        parts = rel.split("/")
        for depth in range(len(parts), 0, -1):
            candidate = "/".join(parts[:depth])
            if candidate in by_path:
                component = by_path[candidate]
                break
        if component is None:
            failures.add("C-HEADER", "%s carries a provenance header but belongs "
                                     "to no declared component" % rel)
            continue
        upstream = upstreams.get(component.get("upstream"), {})
        if upstream.get("repo") != owner_repo:
            failures.add("C-HEADER", "%s says it came from %s, register says %s"
                         % (rel, owner_repo, upstream.get("repo")))
        recorded = component.get("vendored_at_commit")
        if recorded != sha:
            failures.add("C-HEADER", "%s pins %s, register records %s for %s"
                         % (rel, sha[:12], str(recorded)[:12],
                            component_id(component)))
    if found == 0:
        failures.add("C-HEADER", "no in-file provenance header found anywhere "
                                 "under %s — the scan is vacuous" % plugin_dir)


def check_base(register, plugin_dir, failures):
    """Every recorded base commit must be witnessed in the shipped bytes (#462).

    C-HEADER validates the headers that EXIST — it walks the tree, finds a
    header, and demands the register agree. Nothing validated the other
    direction: a component that CLAIMS a base while shipping no header at all
    was invisible to all eight checks that existed before this one. Measured on
    the tree that motivated it (62afcc5, 17 components reading "unknown"):
    setting all 17 to a 40-hex literal left the checker at exit 0 with every
    check green, so fabricating provenance for the whole register was one
    unreviewable field edit per component.

    C-BASE closes that direction. It cannot prove a copy really happened at that
    SHA — this guard is offline by policy, and comparing against upstream is
    `vendor-drift.py`'s job. What it buys is that the claim must be restated in
    the shipped bytes, where a reader and a reviewer both see it, and (for
    `track` components) locked by the C-FILES sha256 as well.

    First match wins, exactly as in `check_header`: `skills/systematic-debugging`
    deliberately cites two SHAs on one header line — the base first, then the
    single upstream hunk adopted later — and `find-polluter.sh:2` depends on that
    ordering. Reading the first match keeps the base authoritative.
    """
    upstreams = register.get("upstreams", {})
    pinned = 0
    for component in third_party(register):
        cid = component_id(component)
        recorded = component.get("vendored_at_commit")
        if not recorded or recorded == UNKNOWN:
            continue
        pinned += 1
        on_disk = component_files_on_disk(plugin_dir, component)
        if on_disk is None:
            # Absence — a missing directory, or an entry with no `path` at all —
            # is C-COVER's and C-SCHEMA's finding; do not double-report it here.
            continue
        root = plugin_dir / component["path"]  # non-None: on_disk proved it
        want_repo = upstreams.get(component.get("upstream"), {}).get("repo")
        if not want_repo:
            # An unresolvable upstream is C-SCHEMA's finding, and it names it
            # precisely ("upstream %r has no upstreams entry"). Reporting the
            # same entry here as "unwitnessed" would be a second, vaguer
            # diagnosis of one defect — and the tree is red either way.
            continue
        witnessed = False
        for rel in on_disk:
            path = root / rel if root.is_dir() else root
            if path.suffix.lower() in BINARY_SUFFIXES:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            match = HEADER_RE.search(text)
            if match and match.group(1) == want_repo and match.group(2) == recorded:
                witnessed = True
                break
        if not witnessed:
            failures.add("C-BASE", "%s records base %s but no file under it "
                                   "carries a matching provenance header — the "
                                   "pin is unwitnessed"
                         % (cid, str(recorded)[:12]))
    if pinned == 0:
        failures.add("C-BASE", "no third-party component records a base commit — "
                               "the register has lost all its provenance, or the "
                               "scan is misrooted. Refusing to pass over an empty "
                               "set.")

def check_evidence(register, failures):
    """Every declared `base_evidence` object must be checkable (#505).

    C-BASE makes a recorded base cost two coordinated lies instead of one: the
    register's claim has to be restated in an in-file header. Both halves are
    still writable by hand, and §2.2 says so in its own words — offline, nothing
    could prove a copy really happened at that SHA. For the six
    `claude-plugins-official` agents that was not survivable: no clone of that
    upstream exists anywhere in this repo, so no reviewer could have compared
    the bytes even by hand.

    `base_evidence` replaces the assertion with a MEASUREMENT: per component,
    the blob oid each declared file had at `vendored_ref`, a commit of THIS
    repository. Recovery proved that oid equal to upstream's blob at
    `vendored_at_commit`, so the pin is re-derivable from two independent trees.

    This check owns the SHAPE of that record and nothing else. Re-deriving the
    oids is deliberately elsewhere, split by what it costs: the offline half in
    `tests/vendor-provenance.test.sh` V35/V36 (git, no network), the upstream half
    in `vendor-drift.py --verify-bases` (network). This file stays a pure file
    reader — no `git`, no `subprocess`, no socket — because that is what makes
    RFC 0019 §2.3's offline guarantee structural instead of a convention, and
    because a network outage inside the offline guard would render as fabricated
    provenance.

    SCOPE. It validates every object that is DECLARED and refuses over an empty
    set. It does NOT demand universal coverage, and the boundary is stated as a
    RULE rather than a count because a count goes stale the next time the
    register moves: the record exists exactly where the base had to be measured
    to exist at all — the `claude-plugins-official` agent components above — and
    no `obra/superpowers` component declares one. Extending the record to those
    is a separate change (RFC 0019 §7 and its amendments); a check that reds on
    somebody else's unstarted work gets suppressed, and a suppressed check is
    not a check. Coverage of what #505 itself pinned is ratcheted in the test
    suite, beside the other register-derived assertions.
    """
    declared = 0
    for component in register.get("components", []):
        cid = component_id(component)
        evidence = component.get("base_evidence")
        if evidence is None:
            continue
        if component.get("origin") != "third-party":
            failures.add("C-EVIDENCE", "%s carries base_evidence but is not a "
                                       "third-party component — there is no "
                                       "upstream it could have been copied from"
                         % cid)
            continue
        if not isinstance(evidence, dict):
            failures.add("C-EVIDENCE", "%s: base_evidence is %s, expected an "
                                       "object" % (cid, type(evidence).__name__))
            continue
        declared += 1
        method = evidence.get("method")
        if method not in EVIDENCE_METHODS:
            failures.add("C-EVIDENCE", "%s: base_evidence method is %r, expected "
                                       "one of %s" % (cid, method,
                                                      list(EVIDENCE_METHODS)))
        ref = evidence.get("vendored_ref")
        if not SHA40_RE.match(ref or ""):
            failures.add("C-EVIDENCE", "%s: base_evidence vendored_ref is not "
                                       "40-hex (%r) — nothing can resolve the "
                                       "blobs it records" % (cid, ref))
        recorded = component.get("vendored_at_commit")
        if not SHA40_RE.match(recorded or ""):
            failures.add("C-EVIDENCE", "%s: carries base_evidence but its "
                                       "vendored_at_commit is %r — evidence for "
                                       "a base it does not claim"
                         % (cid, recorded))
        blobs = evidence.get("blobs")
        if not isinstance(blobs, dict):
            failures.add("C-EVIDENCE", "%s: base_evidence blobs is %s, expected "
                                       "an object keyed by the component's "
                                       "files[]"
                         % (cid, type(blobs).__name__))
            continue
        # Key set EQUALITY, not containment. A subset silently narrows what the
        # re-derivation covers while still looking like evidence, and a superset
        # records an oid for a file the component does not declare — which
        # nothing else would ever visit.
        want = declared_file_paths(component)
        got = sorted(blobs)
        if got != want:
            failures.add("C-EVIDENCE", "%s: base_evidence blobs keys %s do not "
                                       "match the component's files[] %s"
                         % (cid, got, want))
        for name in got:
            if not SHA40_RE.match(blobs[name] if isinstance(blobs[name], str)
                                  else ""):
                failures.add("C-EVIDENCE", "%s: base_evidence blob for %s is not "
                                           "a 40-hex object id (%r)"
                             % (cid, name, blobs[name]))
    if declared == 0:
        failures.add("C-EVIDENCE", "no component declares base_evidence — every "
                                   "recorded base is back to an assertion "
                                   "nothing can re-derive, or the register was "
                                   "misread. Refusing to pass over an empty "
                                   "set.")


def sibling_refs(text):
    """Relative sibling references in a markdown body, deduped and sorted.

    Fenced blocks and inline code spans are removed first — see CODESPAN_RE's
    note. Absolute paths, bare anchors, `mailto:` and anything carrying a URL
    scheme are not claims about this repository's disk, so they are dropped.
    """
    body, in_fence = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            body.append(CODESPAN_RE.sub(" ", line))
    joined = "\n".join(body)
    out = set()
    for target in set(AT_REF_RE.findall(joined)) | set(MD_LINK_RE.findall(joined)):
        if "://" in target or target.startswith(("/", "#", "mailto:")):
            continue
        out.add(target)
    return sorted(out)


def check_refs(register, plugin_dir, failures):
    seen = 0
    for component in third_party(register):
        cid = component_id(component)
        path = component.get("path")
        if not path:
            # A pathless entry is C-SCHEMA's finding; do not double-report it.
            continue
        root = plugin_dir / path
        for rel in declared_file_paths(component):
            if not rel.endswith(".md"):
                continue
            # A single-file component (an agent) IS `root`; a skill component's
            # recorded paths are relative to its directory — same idiom as
            # check_files/refresh.
            source = root / rel if root.is_dir() else root
            try:
                text = source.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                # A declared file that is missing or unreadable is C-FILES'
                # finding, reported there with the register-vs-disk delta.
                continue
            for ref in sibling_refs(text):
                seen += 1
                if not (source.parent / ref).exists():
                    failures.add("C-REFS", "%s: %s references %s, which is not "
                                           "on disk" % (cid, rel, ref))
    # Counts references SEEN, not references RESOLVED — mirroring check_header's
    # `found`. A tree whose references all dangle already produces N named
    # failures above; the arm that has to exist is the one for regexes that
    # stopped matching at all, which would otherwise report agreement.
    if seen == 0:
        failures.add("C-REFS", "no sibling reference found across the register "
                               "— the scan is vacuous")


def readme_third_party_slugs(readme_path, failures):
    """Slugs on Skills/Agents rows of the Bundled table that cite an upstream."""
    try:
        lines = readme_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        die_usage("cannot read README %s: %s" % (readme_path, exc))
    slugs = set()
    rows = 0
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        kind, slug_cell, source = cells[0], cells[1], cells[2]
        if kind not in ("Skills", "Agents"):
            continue
        if "UberDev original" in source:
            continue
        rows += 1
        slugs.update(re.findall(r"`([^`]+)`", slug_cell))
    if rows == 0:
        failures.add("C-README", "no third-party Skills/Agents row found in the "
                                 "Bundled table — the parse is vacuous")
    return slugs


def check_readme(register, repo_root, failures):
    declared = {s for s in (slug_of(c) for c in third_party(register)) if s}
    if not declared:
        failures.add("C-README", "the register declares no third-party component")
        return
    documented = readme_third_party_slugs(repo_root / "README.md", failures)
    undocumented = sorted(declared - documented)
    unregistered = sorted(documented - declared)
    if undocumented:
        failures.add("C-README", "vendored but absent from the README Bundled "
                                 "table: %s" % undocumented)
    if unregistered:
        failures.add("C-README", "on a third-party README row but not in the "
                                 "register: %s" % unregistered)


def check_license(register, plugin_dir, failures):
    licenses_dir = plugin_dir / LICENSES_REL
    if not licenses_dir.is_dir():
        failures.add("C-LICENSE", "no licences directory at %s" % licenses_dir)
        return
    on_disk = {p.name for p in licenses_dir.iterdir() if p.is_file()}
    if not on_disk:
        failures.add("C-LICENSE", "%s is empty" % licenses_dir)
        return
    referenced = set()
    for upstream_id, upstream in register.get("upstreams", {}).items():
        rel = upstream.get("license_file")
        if not rel:
            failures.add("C-LICENSE", "upstream %r declares no license_file"
                         % upstream_id)
            continue
        if not (plugin_dir / rel).is_file():
            failures.add("C-LICENSE", "upstream %r cites a missing licence file: "
                                      "%s" % (upstream_id, rel))
            continue
        referenced.add(rel.rsplit("/", 1)[-1])
    orphans = sorted(on_disk - referenced)
    if orphans:
        failures.add("C-LICENSE", "shipped but referenced by no upstream: %s"
                     % orphans)


def check_stance(register, failures):
    seen = set()
    for component in register.get("components", []):
        cid = component_id(component)
        origin = component.get("origin")
        if origin == "uberdev":
            if "stance" in component:
                failures.add("C-STANCE", "%s is an UberDev original but carries "
                                         "a stance" % cid)
            continue
        stance = component.get("stance")
        if stance not in ("track", "fork"):
            failures.add("C-STANCE", "%s: stance is %r, expected 'track' or "
                                     "'fork'" % (cid, stance))
            continue
        seen.add(stance)
        if not (component.get("stance_reason") or "").strip():
            failures.add("C-STANCE", "%s: stance %r has an empty stance_reason"
                         % (cid, stance))
    if not seen:
        failures.add("C-STANCE", "no third-party component carries a stance — "
                                 "the check would be vacuous")


def check_divref(register, failures):
    """Every `divergences[].ref` must name a real `permanent_divergences[].id`.

    The channel this closes (#509). `check_files` short-circuits every component
    whose stance is not `track`, so a `fork`'s `divergences[]` is never read at
    all — and no check anywhere resolved a ref against a record. The only such
    resolution in the repo was `tests/finish-branch.test.sh` F14, scoped to one
    component, so a dangling ref on any of the other 74 passed every gate. The
    register's divergence records are what RFC 0019 §6 adjudicates and what
    `vendor-drift.py` `declared_files()` subtracts from raw drift, so a ref
    pointing at nothing silently un-declares a divergence in both directions.

    Runs over EVERY component, not just third-party and not just `track`: the
    pointer is a register-internal invariant and does not depend on origin or
    stance.

    A `ref` is MANDATORY on every entry, which tightens RFC 0019 §2.4's "plus
    any component-local entries" — that phrase could be read as licensing an
    entry carrying only a `file`, which `declared_files()` would still subtract
    from raw drift while pointing at no adjudicated record. A component-local
    `file` is still welcome; it rides on a `ref`. Measured at adoption: all 27
    entries in the register already carry one.

    Deliberately carries NO vacuity arm, unlike C-HEADER / C-BASE / C-REFS. For
    those, finding zero means the scan broke. Here an empty `divergences[]`
    corpus is a legal register state — a repo that has declared no permanent
    divergence yet — and a `found == 0` failure would red a clean tree.
    """
    ids = {p.get("id") for p in register.get("permanent_divergences", [])
           if isinstance(p, dict) and p.get("id")}
    for component in register.get("components", []):
        if not isinstance(component, dict):
            # A non-object component is C-SCHEMA's finding; reading it here
            # would raise and suppress every check queued behind this one.
            continue
        cid = component_id(component)
        declared = component.get("divergences", [])
        if not isinstance(declared, list):
            failures.add("C-DIVREF", "%s: divergences is not a list" % cid)
            continue
        for entry in declared:
            if not isinstance(entry, dict):
                failures.add("C-DIVREF", "%s: a divergences[] entry is not an "
                                         "object (%r)" % (cid, entry))
                continue
            ref = entry.get("ref")
            if not ref:
                failures.add("C-DIVREF", "%s: a divergences[] entry declares no "
                                         "ref" % cid)
                continue
            if ref not in ids:
                failures.add("C-DIVREF", "%s: divergence ref %r resolves to no "
                                         "permanent_divergences[].id" % (cid, ref))


def check_watermark(register, failures):
    for component in third_party(register):
        cid = component_id(component)
        watermark = component.get("last_reviewed_upstream_commit")
        if not SHA40_RE.match(watermark or ""):
            failures.add("C-WATERMARK", "%s: last_reviewed_upstream_commit is "
                                        "not 40-hex (%r) — the weekly diff has "
                                        "no 'from'" % (cid, watermark))
        if not ISO_DATE_RE.match(component.get("last_reviewed_on") or ""):
            failures.add("C-WATERMARK", "%s: last_reviewed_on is not an ISO date"
                         % cid)


# --------------------------------------------------------------------------
# --refresh
# --------------------------------------------------------------------------

def refresh(register, register_path, plugin_dir):
    """Recompute file lists and digest-locked digests. Never invents a commit SHA."""
    for component in third_party(register):
        on_disk = component_files_on_disk(plugin_dir, component)
        if on_disk is None:
            die_usage("%s: cannot refresh, path missing on disk"
                      % component_id(component))
        root = plugin_dir / component["path"]  # non-None: on_disk proved it
        if digest_locked(component):
            # A single-file component (an agent) IS `root`; a skill component's
            # recorded paths are relative to its directory. The predicate is
            # shared with check_files on purpose: a producer that wrote bare
            # paths where the checker demands digests would make `--refresh`
            # itself the thing that reds the tree.
            component["files"] = [
                {"path": rel,
                 "sha256": sha256_of(root / rel if root.is_dir() else root)}
                for rel in on_disk
            ]
        else:
            component["files"] = on_disk
        if component.get("vendored_at_commit") in (None, ""):
            component["vendored_at_commit"] = UNKNOWN
    register_path.write_text(
        json.dumps(register, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")
    print("vendor-check: refreshed file lists and digest-locked digests in %s"
          % register_path)
    print("vendor-check: vendored_at_commit values are NOT touched — a real "
          "re-baseline sets those by hand.")


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=None,
                        help="repository root to check (default: this script's repo)")
    parser.add_argument("--only", action="append", default=None, metavar="CHECK-ID",
                        help="run only the named check (repeatable)")
    parser.add_argument("--refresh", action="store_true",
                        help="recompute file lists and digest-locked digests, then exit")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve() if args.repo_root \
        else Path(__file__).resolve().parents[2]
    plugin_dir = repo_root / PLUGIN_REL
    register_path = repo_root / REGISTER_REL
    if not plugin_dir.is_dir():
        die_usage("no plugin tree at %s" % plugin_dir)
    if not register_path.is_file():
        die_usage("no register at %s" % register_path)

    register = load_register(register_path)

    if args.refresh:
        refresh(register, register_path, plugin_dir)
        return 0

    selected = ALL_CHECKS
    if args.only:
        unknown = [c for c in args.only if c not in ALL_CHECKS]
        if unknown:
            die_usage("unknown check id(s): %s (known: %s)"
                      % (unknown, ", ".join(ALL_CHECKS)))
        selected = tuple(args.only)

    failures = Failures()
    if "C-SCHEMA" in selected:
        check_schema(register, failures)
    if "C-COVER" in selected:
        check_cover(register, plugin_dir, failures)
    if "C-FILES" in selected:
        check_files(register, plugin_dir, failures)
    if "C-HEADER" in selected:
        check_header(register, plugin_dir, failures)
    if "C-BASE" in selected:
        check_base(register, plugin_dir, failures)
    if "C-EVIDENCE" in selected:
        check_evidence(register, failures)
    if "C-README" in selected:
        check_readme(register, repo_root, failures)
    if "C-LICENSE" in selected:
        check_license(register, plugin_dir, failures)
    if "C-STANCE" in selected:
        check_stance(register, failures)
    if "C-WATERMARK" in selected:
        check_watermark(register, failures)
    if "C-REFS" in selected:
        check_refs(register, plugin_dir, failures)
    if "C-DIVREF" in selected:
        check_divref(register, failures)

    if failures:
        print("vendor-check: %d failure(s) across %s"
              % (len(failures.items), ", ".join(sorted({c for c, _ in failures.items}))),
              file=sys.stderr)
        return 1
    print("vendor-check: OK — %d components, %d third-party, checks: %s"
          % (len(register.get("components", [])), len(third_party(register)),
             ", ".join(selected)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
