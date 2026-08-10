#!/usr/bin/env python3
"""tools/prkit/published-check.py — the prkit publication currency register.

WHY THIS EXISTS (#410). `tools/prkit/manifest.txt` names the files this repo
copies into a SECOND repository, `TheFJK/prkit`. Every other gate in this repo
certifies the SOURCE; nothing recorded what the published artifact was built
from, so the shipped copy could drift arbitrarily far behind and no test could
tell. It did: the published prkit carried the `trap … RETURN` bug #401 fixed
here, was five files short of the manifest, and still tracked the `codex/` tree
#381 retired — three divergences, zero red tests.

`published.json` records the prkit version last published plus the sha256 of
every copy-set source file at that moment. This script compares the record
against the live tree and fails when they disagree without an explicit
declaration. `tests/prkit-publish.test.sh` is the gate that runs it in CI.

Deliberately NOT wired into `generate.sh`: regenerating from a stale record is
precisely how staleness gets FIXED, so a build-time gate would block the cure.
The register belongs in the test suite.

Usage:
    published-check.py [--source-root DIR] [--manifest FILE] [--record FILE]
    published-check.py --refresh --prkit-version X.Y.Z [...]

Exit codes:
    0  the tree and the record agree (modulo declared divergences)
    1  a check failed
    2  usage error, or an unreadable/unparseable input
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
# Check D's shape: a `/` (path-ish) and a long lowercase-hex run on ONE line.
# 32 rather than 64 so a truncated-digest "simplification" is caught as well.
COLOCATION_RE = re.compile(r"/.*[0-9a-f]{32,}|[0-9a-f]{32,}.*/")

PREFIX = "published:"


def emit(message):
    print(f"{PREFIX} {message}")


def die_usage(message):
    print(f"{PREFIX} {message}", file=sys.stderr)
    raise SystemExit(2)


def read_manifest(path):
    """Manifest entries, comments and blanks dropped.

    Trailing `\\r` is stripped for the same reason tests/prkit-manifest.test.sh:20
    does it: Git-Bash checks out with autocrlf on Windows.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        die_usage(f"cannot read manifest {path}: {exc}")
    entries = []
    for line in raw.splitlines():
        line = line.rstrip("\r").strip()
        if not line or line.startswith("#"):
            continue
        entries.append(line)
    return entries


def read_record(path):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        die_usage(f"cannot read record {path}: {exc}")
    try:
        return json.loads(raw), raw
    except json.JSONDecodeError as exc:
        die_usage(f"record {path} is not valid JSON: {exc}")


def digest_of(path):
    """sha256 over the exact file bytes (the run_manifest.py precedent)."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def check_shape(record):
    """A. The record is structurally what every later check assumes.

    Emptiness is NOT judged here — check B owns it, so a vacuous record reports
    the vacuity diagnostic rather than a generic shape complaint.
    """
    problems = []
    if not isinstance(record, dict):
        return ["record is not a JSON object"]
    version = record.get("prkit_version")
    if not isinstance(version, str) or not SEMVER_RE.match(version):
        problems.append(f"prkit_version is not SemVer: {version!r}")
    copyset = record.get("copyset")
    if not isinstance(copyset, list):
        problems.append(
            "copyset is not a list of {path, sha256} objects — this layout is "
            "load-bearing, see check D"
        )
        return problems
    seen = set()
    for entry in copyset:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
            problems.append(f"copyset entry is not {{path, sha256}}: {entry!r}")
            continue
        path, sha = entry["path"], entry["sha256"]
        if not isinstance(path, str) or not path:
            problems.append(f"copyset entry has an empty path: {entry!r}")
            continue
        if not isinstance(sha, str) or not DIGEST_RE.match(sha):
            problems.append(f"copyset entry has a malformed sha256: {path}")
        if path in seen:
            problems.append(f"copyset lists {path} more than once")
        seen.add(path)
    pending = record.get("pending")
    if not isinstance(pending, list) or not all(isinstance(p, str) for p in pending):
        problems.append("pending is not a list of strings")
    else:
        for path in pending:
            if path not in seen:
                problems.append(f"pending names a path that is not in copyset: {path}")
    return problems


def check_vacuity(manifest_entries, copyset_paths):
    """B. Nothing is certified off an empty scan (verify.sh's own discipline)."""
    problems = []
    if not manifest_entries:
        problems.append("refusing to certify — the manifest is empty")
    if not copyset_paths:
        problems.append("refusing to certify — the copyset is empty")
    return problems


def check_identity(manifest_entries, copyset_paths):
    """C. Key-set identity, BOTH directions.

    One direction alone lets a manifest entry drop silently out of digest
    enforcement, or a record key outlive the manifest line that justified it.
    """
    problems = []
    manifest = set(manifest_entries)
    # A duplicated manifest line collapses into one set member, so the two sides
    # could agree while `prkit-manifest.test.sh` M2's line count says otherwise.
    # Name it here rather than let the counts drift apart silently.
    if len(manifest) != len(manifest_entries):
        seen = set()
        dupes = sorted({p for p in manifest_entries if p in seen or seen.add(p)})
        problems.append(f"manifest lists path(s) more than once: {dupes}")
    for path in sorted(manifest - copyset_paths):
        problems.append(f"missing from record: {path}")
    for path in sorted(copyset_paths - manifest):
        problems.append(f"not in manifest: {path}")
    return problems


def check_layout(record_text):
    """D. Path and digest must never share a line.

    MEASURED, not theoretical. With `copyset` as a map, the line
    `"lib/secret-scan.sh": "<64 hex>"` is scored `generic-api-key` by gitleaks —
    the keyword `secret` next to a high-entropy hex run. `finish-branch`'s
    pre-push scan then HARD-STOPS the push with no --turbo override, so a
    map-shaped record could never be pushed at all (the
    secret-fixture-self-trip class). Keeping `copyset` a list of objects splits
    the two across lines and makes the safety property STRUCTURAL rather than a
    formatting accident.
    """
    offenders = [
        number
        for number, line in enumerate(record_text.splitlines(), start=1)
        if COLOCATION_RE.search(line)
    ]
    if not offenders:
        return []
    where = f"line {offenders[0]}"
    if len(offenders) > 1:
        where += f" (and {len(offenders) - 1} more)"
    return [
        f"digest and path share a line — {where} — this trips the pre-push "
        "secret scan (issue #410); keep copyset a list of {path, sha256} objects"
    ]


def check_resolution(source_root, copyset_paths):
    """E. Every recorded path is still a readable regular file."""
    problems = []
    for path in sorted(copyset_paths):
        target = source_root / path
        if not target.is_file():
            problems.append(f"recorded path is not a regular file: {path}")
        else:
            try:
                with target.open("rb"):
                    pass
            except OSError as exc:
                problems.append(f"recorded path is unreadable: {path}: {exc}")
    return problems


def check_divergence(source_root, recorded, pending):
    """F. Recompute every digest; declared and actual divergence must match."""
    problems = []
    diverged = set()
    for path, expected in sorted(recorded.items()):
        target = source_root / path
        if not target.is_file():
            continue  # already reported by check E
        try:
            actual = digest_of(target)
        except OSError as exc:
            problems.append(f"cannot hash {path}: {exc}")
            continue
        if actual != expected:
            diverged.add(path)
    declared = set(pending)
    for path in sorted(diverged - declared):
        problems.append(f"undeclared divergence: {path}")
    for path in sorted(declared - diverged):
        problems.append(f"stale declaration, path does not diverge: {path}")
    if problems:
        problems.append(f"corrected pending: {json.dumps(sorted(diverged))}")
    return problems, diverged


def build_record(source_root, manifest_entries, version):
    copyset = []
    for path in sorted(manifest_entries):
        target = source_root / path
        if not target.is_file():
            die_usage(f"cannot refresh — manifest path is not a file: {path}")
        try:
            copyset.append({"path": path, "sha256": digest_of(target)})
        except OSError as exc:
            die_usage(f"cannot refresh — unreadable manifest path {path}: {exc}")
    return {"prkit_version": version, "copyset": copyset, "pending": []}


def do_refresh(args, source_root, manifest_entries):
    if not args.prkit_version:
        die_usage("--refresh requires --prkit-version X.Y.Z")
    if not SEMVER_RE.match(args.prkit_version):
        die_usage(f"--prkit-version is not SemVer: {args.prkit_version}")
    if not manifest_entries:
        die_usage("refusing to refresh — the manifest is empty")
    record = build_record(source_root, manifest_entries, args.prkit_version)
    text = json.dumps(record, indent=2) + "\n"
    # The producer re-runs check D on its OWN output: a refresh that emitted an
    # unpushable record would hand the operator a file the pre-push scan rejects.
    layout = check_layout(text)
    if layout:
        for problem in layout:
            print(f"{PREFIX} {problem}", file=sys.stderr)
        die_usage("refusing to write a record that trips the pre-push secret scan")
    try:
        args.record.write_text(text, encoding="utf-8")
    except OSError as exc:
        die_usage(f"cannot write record {args.record}: {exc}")
    emit(
        f"refreshed {args.record} — {len(record['copyset'])} files at prkit "
        f"{args.prkit_version}, pending cleared"
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Verify (or refresh) the prkit publication currency register.",
    )
    parser.add_argument("--source-root", type=Path,
                        default=REPO_ROOT / "plugins" / "uberdev")
    parser.add_argument("--manifest", type=Path,
                        default=REPO_ROOT / "tools" / "prkit" / "manifest.txt")
    parser.add_argument("--record", type=Path,
                        default=REPO_ROOT / "tools" / "prkit" / "published.json")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--prkit-version", default=None)
    args = parser.parse_args(argv)

    source_root = args.source_root
    if not source_root.is_dir():
        die_usage(f"source root is not a directory: {source_root}")
    manifest_entries = read_manifest(args.manifest)

    if args.refresh:
        return do_refresh(args, source_root, manifest_entries)
    if args.prkit_version:
        die_usage("--prkit-version is only meaningful with --refresh")

    record, record_text = read_record(args.record)

    # Check D runs FIRST and on the raw text, because it is the only check that
    # needs no parsed structure — and because the map-shaped record it exists to
    # reject is ALSO a shape error. Ordering it after check_shape would report
    # "copyset is not a list" and swallow the actionable reason (the pre-push
    # secret scan) exactly when a reformat re-armed the trap.
    layout_problems = check_layout(record_text)

    shape_problems = check_shape(record)
    if shape_problems:
        for problem in layout_problems + shape_problems:
            emit(problem)
        emit("record shape is wrong — nothing further can be checked")
        return 1

    recorded = {entry["path"]: entry["sha256"] for entry in record["copyset"]}
    copyset_paths = set(recorded)
    pending = record["pending"]

    problems = list(layout_problems)
    problems += check_vacuity(manifest_entries, copyset_paths)
    problems += check_identity(manifest_entries, copyset_paths)
    problems += check_resolution(source_root, copyset_paths)
    divergence_problems, diverged = check_divergence(source_root, recorded, pending)
    problems += divergence_problems

    if problems:
        for problem in problems:
            emit(problem)
        return 1

    plural = "" if len(diverged) == 1 else "s"
    emit(
        f"OK — {len(copyset_paths)} files, {len(diverged)} declared "
        f"divergence{plural} (prkit {record['prkit_version']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
