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

Repo-agnostic: no organisation, repository or project id is hardcoded. Upstream
coordinates come from `plugins/uberdev/vendor.json`; the target repository comes
from `gh`'s own checkout/`GH_REPO` inference.

Usage:
    vendor-drift.py [--repo-root DIR] [--dry-run] [--issue-limit N]

Exit codes:
    0  ran to completion (drift or not)
    1  an upstream could not be resolved, or a GitHub call failed
    2  usage error, or an unreadable/unparseable register
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
# Default clone host. An upstream may override it with its own `url` field, so
# no forge is baked into the code path — only into the default.
UPSTREAM_HOST = "https://github.com/"
MARKER = "<!-- uberdev-vendor-drift-v1 -->"
FINGERPRINT_KEY = "drift-fingerprint:"
ISSUE_TITLE = "Vendored upstream drift — weekly report"
SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
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


def changed_paths(work_root, repo_url, repo_slug, base, head, fetched):
    """Changed paths between two upstream commits, via a blobless fetch.

    `fetched` is the set of (repo, base, head) triples already pulled into the
    scratch clone. Components sharing one upstream can carry DIFFERENT
    watermarks, so re-using the clone without re-fetching would ask `git diff`
    for an object that was never downloaded.
    """
    if base == head:
        return []
    mirror = work_root / repo_slug.replace("/", "__")
    if not (mirror / ".git").is_dir():
        mirror.mkdir(parents=True, exist_ok=True)
        rc, _, err = run(["git", "init", "--quiet"], cwd=str(mirror))
        if rc != 0:
            fail("could not init a scratch clone for %s: %s" % (repo_slug, err.strip()))
        run(["git", "remote", "add", "origin", repo_url], cwd=str(mirror))
    if (repo_slug, base, head) not in fetched:
        rc, _, err = run(["git", "fetch", "--quiet", "--no-tags",
                          "--filter=blob:none", "origin", base, head],
                         cwd=str(mirror))
        if rc != 0:
            # Some servers refuse arbitrary-SHA wants; fall back to a full
            # blobless fetch rather than silently reporting nothing.
            rc, _, err2 = run(["git", "fetch", "--quiet", "--no-tags",
                               "--filter=blob:none", "origin"], cwd=str(mirror))
            if rc != 0:
                fail("could not fetch %s..%s from upstream %s: %s"
                     % (base[:12], head[:12], repo_slug, (err2 or err).strip()))
        fetched.add((repo_slug, base, head))
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
    by_id = {p["id"]: p for p in register.get("permanent_divergences", [])}
    names = set()
    for entry in component.get("divergences", []):
        name = entry.get("file")
        if name is None and entry.get("ref") in by_id:
            name = by_id[entry["ref"]].get("file")
        if name:
            names.add(name)
    return names


def build_report(register, heads, changes):
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
    parser.add_argument("--dry-run", action="store_true",
                        help="render the report to stdout and touch GitHub not at all")
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

    used = sorted({c["upstream"] for c in components})
    heads = {}
    urls = {}
    for upstream_id in used:
        upstream = upstreams.get(upstream_id)
        if not upstream:
            die_usage("component references undeclared upstream %r" % upstream_id)
        slug = upstream["repo"]
        urls.setdefault(slug, upstream.get("url") or UPSTREAM_HOST + slug)
        if slug in heads:
            continue
        heads[slug] = resolve_head(urls[slug], slug)

    work_root = Path(tempfile.mkdtemp(prefix="vendor-drift."))
    try:
        cache = {}
        fetched = set()
        changes = []
        for component in components:
            slug = upstreams[component["upstream"]]["repo"]
            head = heads[slug]
            base = component["last_reviewed_upstream_commit"]
            key = (slug, base, head)
            if key not in cache:
                cache[key] = changed_paths(
                    work_root, urls[slug], slug, base, head, fetched)
            prefix = component["upstream_path"]
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

        body, fingerprint, drifting = build_report(register, heads, changes)
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
