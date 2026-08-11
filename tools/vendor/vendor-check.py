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
red. "Red for the wrong reason" is not coverage.

    C-SCHEMA     register shape: schema literal, required keys, unique ids,
                 commits are 40-hex or the explicit literal "unknown", no
                 duplicate JSON keys
    C-COVER      on-disk skill dirs + agent files == declared component paths,
                 both directions; aborts rather than passing if either side is
                 empty
    C-FILES      per component: recorded file list == disk. For `track`
                 components the sha256 must match too, unless the change is
                 declared in divergences[]
    C-HEADER     every in-file provenance header agrees with its component's
                 upstream repo and vendored_at_commit; asserts >= 1 header was
                 found before reporting agreement
    C-README     README Bundled-table third-party slugs == third-party
                 component slugs, both directions
    C-LICENSE    every declared licence file exists, and every file under
                 licenses/ is referenced by some upstream
    C-STANCE     stance in {track, fork} with a non-empty reason, or
                 origin == "uberdev" and no stance; never "undecided"
    C-WATERMARK  40-hex last_reviewed_upstream_commit + ISO last_reviewed_on on
                 every third-party component

Repo-agnostic: no organisation, project id or repository name is hardcoded. All
upstream coordinates come from the register.

Usage:
    vendor-check.py [--repo-root DIR] [--only CHECK-ID ...]
    vendor-check.py --refresh [--repo-root DIR]

`--refresh` recomputes file lists and `track` digests from disk. It NEVER
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

# Files whose bytes are never text we can scan for a provenance header.
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip",
                   ".woff", ".woff2", ".ttf", ".otf", ".mp4", ".webp"}

ALL_CHECKS = ("C-SCHEMA", "C-COVER", "C-FILES", "C-HEADER", "C-README",
              "C-LICENSE", "C-STANCE", "C-WATERMARK")


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
    root = plugin_dir / component["path"]
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
        out.append(entry["path"] if isinstance(entry, dict) else entry)
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


def slug_of(component):
    name = component["path"].rsplit("/", 1)[-1]
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
    ids = [c.get("id") for c in components]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        failures.add("C-SCHEMA", "duplicate component ids: %s" % dupes)
    upstreams = register.get("upstreams", {})
    for component in components:
        cid = component.get("id", "<no id>")
        if component.get("path") != cid:
            failures.add("C-SCHEMA", "%s: id and path disagree" % cid)
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
    declared = {c.get("path") for c in register.get("components", [])}
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
        cid = component["id"]
        on_disk = component_files_on_disk(plugin_dir, component)
        if on_disk is None:
            # Absence is C-COVER's finding; do not double-report it here.
            continue
        declared = declared_file_paths(component)
        if declared != on_disk:
            missing = sorted(set(on_disk) - set(declared))
            phantom = sorted(set(declared) - set(on_disk))
            failures.add("C-FILES", "%s: file list disagrees with disk "
                                    "(undeclared=%s declared-but-absent=%s)"
                         % (cid, missing, phantom))
            continue
        if component.get("stance") != "track":
            continue
        excused = divergence_files(component)
        root = plugin_dir / component["path"]
        for entry in component.get("files", []):
            if not isinstance(entry, dict):
                failures.add("C-FILES", "%s: stance is track but files[] carries "
                                        "a bare path (%r) with no digest"
                             % (cid, entry))
                continue
            recorded = entry.get("sha256", "")
            if not SHA256_RE.match(recorded):
                failures.add("C-FILES", "%s: %s has no valid sha256"
                             % (cid, entry.get("path")))
                continue
            actual = sha256_of(root / entry["path"] if root.is_dir() else root)
            if actual != recorded and entry["path"] not in excused:
                failures.add("C-FILES", "%s: %s changed on disk and the change "
                                        "is not declared in divergences[] "
                                        "(recorded %s, disk %s)"
                             % (cid, entry["path"], recorded[:12], actual[:12]))


def check_header(register, plugin_dir, failures):
    by_path = {c["path"]: c for c in register.get("components", [])}
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
                         % (rel, sha[:12], str(recorded)[:12], component["id"]))
    if found == 0:
        failures.add("C-HEADER", "no in-file provenance header found anywhere "
                                 "under %s — the scan is vacuous" % plugin_dir)


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
    declared = {slug_of(c) for c in third_party(register)}
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
        cid = component["id"]
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


def check_watermark(register, failures):
    for component in third_party(register):
        cid = component["id"]
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
    """Recompute file lists and `track` digests. Never invents a commit SHA."""
    for component in third_party(register):
        on_disk = component_files_on_disk(plugin_dir, component)
        if on_disk is None:
            die_usage("%s: cannot refresh, path missing on disk"
                      % component["id"])
        root = plugin_dir / component["path"]
        if component.get("stance") == "track":
            # A single-file component (an agent) IS `root`; a skill component's
            # recorded paths are relative to its directory.
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
    print("vendor-check: refreshed file lists and track digests in %s"
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
                        help="recompute file lists and track digests, then exit")
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
    if "C-README" in selected:
        check_readme(register, repo_root, failures)
    if "C-LICENSE" in selected:
        check_license(register, plugin_dir, failures)
    if "C-STANCE" in selected:
        check_stance(register, failures)
    if "C-WATERMARK" in selected:
        check_watermark(register, failures)

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
