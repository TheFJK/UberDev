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
FINGERPRINT_RE = re.compile(r"drift-fingerprint:\s*([0-9a-f]+)")
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
    """Resolve a remote HEAD, failing loudly on every ambiguous outcome."""
    rc, out, err = run(["git", "ls-remote", repo_url, "HEAD"])
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


def release_key(name):
    """A SemVer-ish ordering key for a tag name, or None if it names no version.

    The shape exists to prevent one specific inversion, so do not "simplify" it
    into the digits alone: `v6.4.0-rc1` yields the digit run (6, 4, 0, 1), which
    sorts ABOVE its own final release `v6.4.0` at (6, 4, 0) — `max()` would then
    report a release CANDIDATE as the newest release. SemVer §11 ranks a
    pre-release BELOW the version it precedes, and the `0 if sep else 1` field
    is what encodes that.

    `ls-remote` prints tags in lexical refname order, where `v6.0.10` precedes
    `v6.0.2`; ordering is therefore always computed here, never taken from the
    order the remote happened to print.
    """
    # SemVer §10: build metadata is not part of the version, so it is stripped
    # before comparison. The trailing `name` field below is only a deterministic
    # tiebreak, so `max()` over two names that differ ONLY in build metadata is
    # still stable rather than arbitrary.
    core = name.split("+", 1)[0]
    stem, sep, pre = core.partition("-")
    if not re.search(r"\d", stem):         # e.g. `release-1.2.3`: that "-" is a
        stem, sep, pre = core, "", ""      # word separator, not a pre-release one
    nums = tuple(int(n) for n in re.findall(r"\d+", stem))
    if not nums:
        return None
    pre_nums = tuple(int(n) for n in re.findall(r"\d+", pre))
    return (nums, 0 if sep else 1, pre_nums, pre, name)


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
    """
    if "last_reviewed_release" not in upstream:
        # A missing label is not an error. An upstream can be a plugin inside a
        # monorepo with no release vocabulary at all (RFC 0019, the #511
        # amendment), and inventing a label for it would be exactly the
        # fabrication this register exists to prevent.
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
    """
    rc, out, err = run(["git", "ls-remote", "--tags", repo_url])
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


def build_report(register, heads, tags, changes):
    """Render the markdown body plus a stable fingerprint of its drift payload."""
    drifting = [c for c in changes if c["raw"]]
    declared_only = [c for c in changes if not c["raw"] and c["declared"]]

    payload = json.dumps(
        {
            "heads": heads,
            "components": {c["id"]: {"head": c["head"], "raw": sorted(c["raw"]),
                                     "declared": sorted(c["declared"])}
                           for c in changes if c["raw"] or c["declared"]},
        },
        sort_keys=True,
    )
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
    for slug in sorted(tags):
        published = tags[slug]
        named = [n for n in published if release_key(n) is not None]
        if not published:
            lines.append("- `%s`: no published tags" % slug)
        elif not named:
            lines.append("- `%s`: %d published tag(s); none of them names a "
                         "version" % (slug, len(published)))
        else:
            newest = max(named, key=release_key)
            lines.append("- `%s`: %d published tag(s); newest `%s` (`%s`)"
                         % (slug, len(published), newest, published[newest][:12]))
    lines.append("")

    if not drifting:
        lines.append("**No drift.** Every vendored component is level with its "
                     "recorded watermark, or its only changes are declared "
                     "divergences.")
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
    return "\n".join(lines) + "\n", fingerprint, bool(drifting)


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

        body, fingerprint, drifting = build_report(register, heads, tags, changes)
    finally:
        shutil.rmtree(work_root, ignore_errors=True)

    if args.dry_run:
        sys.stdout.write(body)
        return 0

    issue = find_tracking_issue(args.issue_limit)

    if not drifting and issue is None:
        print("vendor-drift: no drift and no open tracking issue — nothing to do.")
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
