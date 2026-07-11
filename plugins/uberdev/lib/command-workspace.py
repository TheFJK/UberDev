#!/usr/bin/env python3
"""Allocate one carrier-bound private command workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from typing import Any

PRIVATE_DIR = 0o700
PRIVATE_FILE = 0o600
RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")
IDENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
CALLERS = {
    "review-pr": {
        "workflows": {"review-pr", "solve", "turbo"},
        "artifacts": {
            "diff": ("pr-diff.md", b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'),
            "criteria": ("review-criteria.md", b""),
            "commit_range": ("commit-range.txt", b""),
            "phase1_disposition": ("phase1-disposition.json", b"{}\n"),
            "phase2_disposition": ("phase2-disposition.json", b"{}\n"),
        },
    },
    "simplify": {
        "workflows": {"simplify"},
        "artifacts": {
            "diff": ("pr-diff.md", b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'),
            "aggregate": ("simplify-final.md", b""),
            "commit_range": ("commit-range.txt", b""),
            "phase1_disposition": ("phase1-disposition.json", b"{}\n"),
            "phase2_disposition": ("phase2-disposition.json", b"{}\n"),
        },
    },
    "post-impl-review": {
        "workflows": {"review-pr", "solve", "turbo"},
        "artifacts": {
            "diff": ("pr-diff.md", None),
            "criteria": ("review-criteria.md", None),
        },
    },
}
DESCRIPTOR_KEYS = {
    "schema_version", "caller", "carrier_workflow", "carrier_run_id",
    "context_file", "context_sha256", "repository_root", "carrier_run_dir",
    "research_dir", "artifacts",
}


class Failure(Exception):
    pass


def fail(reason: str) -> None:
    raise Failure(reason)


def beneath(root: str, path: str) -> bool:
    try:
        return os.path.commonpath((root, path)) == root
    except ValueError:
        return False


def open_directory(path: str, private: bool = False) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    entry = os.fstat(fd)
    if (not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.geteuid()
            or (private and stat.S_IMODE(entry.st_mode) != PRIVATE_DIR)):
        os.close(fd)
        fail("unsafe_directory")
    return fd


def load_carrier(
    raw: str, caller: str
) -> tuple[dict[str, Any], dict[str, Any], str, str, tuple[int, int]]:
    try:
        carrier = json.loads(raw)
    except Exception:
        fail("invalid_carrier")
    keys = {"schema_version", "run_id", "workflow", "issue_num", "context_file", "context_sha256"}
    if not isinstance(carrier, dict) or set(carrier) != keys or carrier.get("schema_version") != 1:
        fail("invalid_carrier")
    workflow = carrier.get("workflow")
    if workflow not in CALLERS[caller]["workflows"]:
        fail("workflow_not_allowed")
    issue = carrier.get("issue_num")
    if type(issue) is not int or issue < 0 or (workflow != "simplify" and issue == 0):
        fail("invalid_carrier")
    if not IDENT.fullmatch(carrier.get("run_id", "")):
        fail("invalid_carrier")
    context_path = carrier.get("context_file")
    digest = carrier.get("context_sha256")
    if not isinstance(context_path, str) or not os.path.isabs(context_path) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("invalid_context")
    state = os.path.dirname(context_path)
    if os.path.basename(state) != f".agent-state-{os.geteuid()}":
        fail("invalid_context")
    state_fd = open_directory(state, private=True)
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        context_fd = os.open(os.path.basename(context_path), flags, dir_fd=state_fd)
        try:
            opened = os.fstat(context_fd)
            current = os.stat(os.path.basename(context_path), dir_fd=state_fd, follow_symlinks=False)
            raw_context = os.read(context_fd, 1048577)
        finally:
            os.close(context_fd)
    finally:
        os.close(state_fd)
    if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
            or len(raw_context) > 1048576 or hashlib.sha256(raw_context).hexdigest() != digest):
        fail("invalid_context")
    try:
        context = json.loads(raw_context)
        metadata = context["metadata"]
    except Exception:
        fail("invalid_context")
    if (metadata.get("run_id"), metadata.get("workflow"), metadata.get("issue_num")) != (carrier["run_id"], workflow, issue):
        fail("context_mismatch")
    repo_raw = metadata.get("repository_id")
    if not isinstance(repo_raw, str) or not os.path.isabs(repo_raw):
        fail("invalid_repository")
    repo = os.path.realpath(repo_raw)
    if repo != repo_raw:
        fail("invalid_repository")
    repo_fd = open_directory(repo)
    try:
        verified_repo = os.fstat(repo_fd)
        repo_identity = (verified_repo.st_dev, verified_repo.st_ino)
        git_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        git_env.update({
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        git_toplevel = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--show-toplevel"],
            check=True,
            env=git_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.rstrip("\n")
        current_repo = os.stat(repo, follow_symlinks=False)
    except (OSError, subprocess.CalledProcessError):
        fail("invalid_repository")
    finally:
        os.close(repo_fd)
    if git_toplevel != repo or (current_repo.st_dev, current_repo.st_ino) != repo_identity:
        fail("invalid_repository")
    carrier_run_dir = os.path.realpath(os.path.dirname(state))
    run_fd = open_directory(carrier_run_dir)
    os.close(run_fd)
    return carrier, context, repo, carrier_run_dir, repo_identity


def open_or_create_dir(parent_fd: int, name: str, private: bool) -> tuple[int, bool]:
    created = False
    try:
        os.mkdir(name, PRIVATE_DIR, dir_fd=parent_fd)
        created = True
    except FileExistsError:
        pass
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=parent_fd)
    entry = os.fstat(fd)
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.geteuid()
            or (entry.st_dev, entry.st_ino) != (current.st_dev, current.st_ino)
            or (private and stat.S_IMODE(entry.st_mode) != PRIVATE_DIR)):
        os.close(fd)
        fail("unsafe_directory")
    if created:
        os.fchmod(fd, PRIVATE_DIR)
    return fd, created


def allocate_workspace(
    repo: str,
    run_id: str,
    artifacts: dict[str, tuple[str, bytes | None]],
    expected_repo_identity: tuple[int, int],
) -> tuple[str, dict[str, str]]:
    repo_fd = open_directory(repo)
    opened_repo = os.fstat(repo_fd)
    if (opened_repo.st_dev, opened_repo.st_ino) != expected_repo_identity:
        os.close(repo_fd)
        fail("repository_changed")
    opened: list[int] = [repo_fd]
    created_dirs: list[tuple[int, str]] = []
    created_files: list[str] = []
    workspace_fd = -1
    try:
        parent_fd = repo_fd
        for index, name in enumerate((".uberdev", "research", run_id)):
            fd, created = open_or_create_dir(parent_fd, name, private=index == 2)
            opened.append(fd)
            if created:
                created_dirs.append((parent_fd, name))
            parent_fd = fd
        workspace_fd = parent_fd
        paths: dict[str, str] = {}
        workspace = os.path.join(repo, ".uberdev", "research", run_id)
        for key, (name, initial) in artifacts.items():
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            try:
                fd = os.open(name, flags, PRIVATE_FILE, dir_fd=workspace_fd)
                created_files.append(name)
                os.fchmod(fd, PRIVATE_FILE)
                if initial is None:
                    os.close(fd)
                    fail("required_artifact_missing")
                with os.fdopen(fd, "wb") as stream:
                    stream.write(initial)
                    stream.flush()
                    os.fsync(stream.fileno())
            except FileExistsError:
                fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=workspace_fd)
                try:
                    entry = os.fstat(fd)
                    current = os.stat(name, dir_fd=workspace_fd, follow_symlinks=False)
                finally:
                    os.close(fd)
                if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.geteuid() or entry.st_nlink != 1
                        or stat.S_IMODE(entry.st_mode) != PRIVATE_FILE
                        or (entry.st_dev, entry.st_ino) != (current.st_dev, current.st_ino)):
                    fail("unsafe_artifact")
            paths[key] = os.path.join(workspace, name)
        try:
            os.fsync(workspace_fd)
        except OSError:
            pass
        return workspace, paths
    except Exception:
        if workspace_fd >= 0:
            for name in reversed(created_files):
                try:
                    os.unlink(name, dir_fd=workspace_fd)
                except OSError:
                    pass
        for parent_fd, name in reversed(created_dirs):
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
        raise
    finally:
        for fd in reversed(opened):
            try:
                os.close(fd)
            except OSError:
                pass


def validate_presets(presets: dict[str, Any], expected: dict[str, str], repo: str, workspace: str) -> None:
    mapping = {"WORKTREE_ROOT": repo, "RESEARCH_DIR_ABS": workspace, **expected}
    for key, value in presets.items():
        if value and mapping.get(key) != value:
            fail("preset_mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--caller", required=True, choices=tuple(CALLERS))
    parser.add_argument("--carrier-json", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--requested-root", default="")
    parser.add_argument("--parent-workspace-json", default="")
    parser.add_argument("--presets-json", required=True)
    args = parser.parse_args()
    if not RUN_ID.fullmatch(args.run_id):
        fail("invalid_run_id")
    carrier, _context, repo, carrier_run_dir, repo_identity = load_carrier(args.carrier_json, args.caller)
    if args.requested_root:
        if not os.path.isabs(args.requested_root) or os.path.realpath(args.requested_root) != repo:
            fail("repository_mismatch")
    expected_workspace = os.path.join(repo, ".uberdev", "research", args.run_id)
    if args.caller == "post-impl-review":
        if not args.parent_workspace_json:
            fail("parent_workspace_required")
        try:
            parent = json.loads(args.parent_workspace_json)
        except Exception:
            fail("invalid_parent_workspace")
        if (not isinstance(parent, dict) or set(parent) != DESCRIPTOR_KEYS or parent.get("schema_version") != 1
                or parent.get("caller") != "review-pr" or parent.get("carrier_workflow") != carrier["workflow"]
                or parent.get("carrier_run_id") != carrier["run_id"] or parent.get("context_file") != carrier["context_file"]
                or parent.get("context_sha256") != carrier["context_sha256"] or parent.get("repository_root") != repo
                or parent.get("carrier_run_dir") != carrier_run_dir or parent.get("research_dir") != expected_workspace):
            fail("invalid_parent_workspace")
        expected_parent_artifacts = {
            key: os.path.join(expected_workspace, name)
            for key, (name, _initial) in CALLERS["review-pr"]["artifacts"].items()
        }
        if parent.get("artifacts") != expected_parent_artifacts:
            fail("invalid_parent_workspace")
    artifacts = CALLERS[args.caller]["artifacts"]
    expected_globals = {}
    name_to_global = {
        "diff": "DIFF_ARTIFACT_PATH", "criteria": "CRITERIA_PATH", "commit_range": "COMMIT_RANGE_PATH",
        "phase1_disposition": "PHASE1_DISPOSITION_PATH", "phase2_disposition": "PHASE2_DISPOSITION_PATH",
        "aggregate": "AGG_PATH",
    }
    for key, (name, _initial) in artifacts.items():
        expected_globals[name_to_global[key]] = os.path.join(expected_workspace, name)
    if args.caller == "post-impl-review":
        for key, path in parent["artifacts"].items():
            global_name = name_to_global.get(key)
            if global_name:
                expected_globals[global_name] = path
    try:
        presets = json.loads(args.presets_json)
    except Exception:
        fail("invalid_presets")
    if not isinstance(presets, dict):
        fail("invalid_presets")
    validate_presets(presets, expected_globals, repo, expected_workspace)
    workspace, paths = allocate_workspace(repo, args.run_id, artifacts, repo_identity)
    descriptor = {
        "schema_version": 1, "caller": args.caller, "carrier_workflow": carrier["workflow"],
        "carrier_run_id": carrier["run_id"], "context_file": carrier["context_file"],
        "context_sha256": carrier["context_sha256"], "repository_root": repo,
        "carrier_run_dir": carrier_run_dir, "research_dir": workspace, "artifacts": paths,
    }
    print(json.dumps(descriptor, sort_keys=True, separators=(",", ":")), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"uberdev command workspace: {error}", file=sys.stderr)
        raise SystemExit(2)
