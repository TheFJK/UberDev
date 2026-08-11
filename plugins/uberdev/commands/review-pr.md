---
description: "Comprehensive PR review using specialized agents"
argument-hint: "[review-aspects] [--no-simplify] [--no-ci-fix] [--no-defer-issues] [--turbo]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Workflow", "Write"]
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality.

**Review Aspects (optional):** "$ARGUMENTS"

`/uberdev:review-pr` is a true **two-phase** command. Both phases run by default — flow: **post-impl-review fanout (6 agents via `uberdev:post-impl-review` skill) → fix loop → simplify fanout (3 lenses) → final aggregation**.

## Routed child builder

<!-- BEGIN child-callsite-contracts-v1 -->
```json
{
  "review_pr.fix.phase1":{"inputs":["findings_path","findings_sha256","commit_range_path","commit_range_sha256","working_dir","pr_number","disposition_path","authority_path","authority_sha256"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.simplify.reuse":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.simplify.quality":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.simplify.efficiency":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.fix.phase2":{"inputs":["findings_path","findings_sha256","commit_range_path","commit_range_sha256","working_dir","pr_number","disposition_path","authority_path","authority_sha256"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.defer.findings":{"inputs":["phase1_path","phase2_path","phase1_disposition_path","phase2_disposition_path","working_dir","pr_number"],"optional_inputs":["verification_path"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.classify":{"inputs":["pr_number","run_id","head_sha","log_content","log_sha256"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.ci.fix_code":{"inputs":["failure_class","signal_anchor","run_id","head_sha","working_dir","pr_number"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.rebase":{"inputs":["working_dir","pr_number","head_sha","base_sha"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.defer_refusal":{"inputs":["phase1_path","working_dir","pr_number"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.resolve_conflict":{"inputs":["file_path","working_dir","pr_branch","integration_branch","base_sha"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.verify.finding":{"inputs":["claim_path","diff_path","pr_context_path","rubric_path","working_dir"],"optional_inputs":["claude_md_paths","format_example_path","format_retry"],"allowed_workflows":["review-pr"],"risk_scope":"subtask","risk_argument":"subtask"}
}
```
<!-- END child-callsite-contracts-v1 -->

All provider calls in this command use the runtime-owned carrier and handoff builder; native agent-dispatch shortcuts are forbidden. A chained solve run inherits `UBERDEV_RUN_CARRIER_JSON`; when it is absent, a standalone run calls `uberdev_prepare_run_carrier review-pr "$PR_NUMBER" medium "$RISK_JSON"`, which validates repository/PR identity and exports the prepared request plus the same carrier without pretending to be `/solve`.

### Executable setup (run before any builder or child edge)

```bash uberdev-executable setup=review-pr
set -u
UBERDEV_REVIEW_PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
. "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh"
CODE_FIXER_CONTRACT="$UBERDEV_REVIEW_PLUGIN_ROOT/lib/code_fixer_contract.py"
PR_NUMBER="${PR_NUMBER:-$(gh pr view --json number -q .number)}"
RISK_JSON="${UBERDEV_AGENT_RISK_SIGNALS_JSON:-[]}"
RUN_ID_WAS_EXPLICIT=0
if [ "${RUN_ID+x}" = x ] && [ -n "${RUN_ID:-}" ]; then
  RUN_ID_WAS_EXPLICIT=1
fi
RUN_ID_RESERVATION_MAX_ATTEMPTS=16
# Age after which an unpublished reservation's `locked` marker is treated as
# abandoned and reaped. Default 7200 = 2 x REVIEW_GRACE_SECS (goal-state.sh's
# `_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS=3600`): the reaper must never race the
# reader, so it only removes markers that are already well past the window
# `/uberdev:goal` itself uses to call a marker stale. No live `/review-pr` run
# reaches this age — the per-child timeout defaults to 600s, MONITOR is capped at
# 1200s, and the CI-fix loop is capped at 3 iterations.
REVIEW_RESERVATION_REAP_SECS="${REVIEW_RESERVATION_REAP_SECS:-7200}"
REVIEW_RUN_MANIFEST="$UBERDEV_REVIEW_PLUGIN_ROOT/lib/run_manifest.py"
review_prepare_run_root() {
  local repository_root="${@:1:1}"
  [ "$#" -eq 1 ] || return 2
  python3 -I -B - "$repository_root" "$REVIEW_RUN_MANIFEST" <<'PY'
import importlib.util
import json
import os
import stat
import sys

repository_root, module_path = sys.argv[1:]
repository_root = os.path.abspath(repository_root)
spec = importlib.util.spec_from_file_location("uberdev_review_run_manifest", module_path)
# `spec` itself is None when the pathname is unloadable; `module_from_spec(None)`
# then raises AttributeError BEFORE the loader guard below could ever run, and an
# import-time failure inside exec_module escapes as an uncaught traceback. Both
# leave the caller with an opaque rc instead of one stable diagnostic.
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)

def owned_directory(entry):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    return (
        stat.S_ISDIR(entry.st_mode)
        and not stat.S_ISLNK(entry.st_mode)
        and not getattr(entry, "st_reparse_tag", 0)
        and (uid is None or entry.st_uid == uid)
    )

def require_directory(entry, expected=None):
    if not owned_directory(entry):
        raise module.ManifestRejected("review_run_root_not_owned_directory")
    if expected is not None and (entry.st_dev, entry.st_ino) != expected:
        raise module.ManifestRejected("review_run_root_identity_changed")

try:
    module._reject_symlinked_ancestors(repository_root)
    module._reject_windows_reparse_ancestors(repository_root)
    repository_before = os.lstat(repository_root)
    require_directory(repository_before)
    repository_identity = (repository_before.st_dev, repository_before.st_ino)
    components = (".uberdev", "runs")
    if module._uses_native_windows_filesystem():
        parent_path = repository_root
        parent_identity = repository_identity
        for component in components:
            module._reject_symlinked_ancestors(parent_path)
            module._reject_windows_reparse_ancestors(parent_path)
            parent_before = os.lstat(parent_path)
            require_directory(parent_before, parent_identity)
            child_path = os.path.join(parent_path, component)
            try:
                os.mkdir(child_path, 0o700)
            except FileExistsError:
                pass
            child = os.lstat(child_path)
            require_directory(child)
            parent_after = os.lstat(parent_path)
            require_directory(parent_after, parent_identity)
            parent_path = child_path
            parent_identity = (child.st_dev, child.st_ino)
        runs_root = parent_path
        runs_identity = parent_identity
    else:
        descriptor = module._open_directory_fd(repository_root)
        try:
            opened_repository = os.fstat(descriptor)
            require_directory(opened_repository, repository_identity)
            parent_path = repository_root
            for component in components:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    os.fsync(descriptor)
                except FileExistsError:
                    pass
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                child_descriptor = os.open(component, flags, dir_fd=descriptor)
                child_opened = os.fstat(child_descriptor)
                child_path = os.path.join(parent_path, component)
                child_current = os.lstat(child_path)
                require_directory(child_opened)
                require_directory(
                    child_current, (child_opened.st_dev, child_opened.st_ino)
                )
                os.close(descriptor)
                descriptor = child_descriptor
                parent_path = child_path
            repository_after = os.lstat(repository_root)
            require_directory(repository_after, repository_identity)
            runs_opened = os.fstat(descriptor)
            require_directory(runs_opened)
            runs_root = parent_path
            runs_identity = (runs_opened.st_dev, runs_opened.st_ino)
        finally:
            os.close(descriptor)
    print(
        json.dumps(
            {"identity": list(runs_identity), "path": runs_root},
            sort_keys=True,
            separators=(",", ":"),
        ),
        end="",
    )
except (OSError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    print(f"error: could not prepare private review run root: {error}", file=sys.stderr)
    raise SystemExit(2)
PY
}
review_publish_local_ignore() {
  local runs_root="${@:1:1}" runs_identity_json="${@:2:1}"
  [ "$#" -eq 2 ] || return 2
  python3 -I -B - "$runs_root" "$runs_identity_json" "$REVIEW_RUN_MANIFEST" <<'PY'
import importlib.util
import json
import os
import sys

runs_root, identity_json, module_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("uberdev_review_ignore_manifest", module_path)
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)
ignore_path = os.path.join(os.path.abspath(runs_root), ".gitignore")
try:
    identity = json.loads(identity_json)
    module.secure_publish_exact_no_clobber(ignore_path, b"*\n", identity)
except (OSError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    # The publisher is exact-name/no-clobber by contract: it never truncates or
    # unlinks an existing pathname, so a crash residue (typically a 0-byte
    # carrier from an interrupted earlier run) wedges every later run here. The
    # bare `{error}` this used to print ("artifact_target_exists") named neither
    # the file nor the way out, so the operator had nothing to act on.
    print(
        f"error: could not install private review ignore policy at {ignore_path}: {error}",
        file=sys.stderr,
    )
    print(
        f"hint: inspect {ignore_path}. This publisher never clobbers or truncates it. "
        "If it is crash residue from an interrupted run, remove that one file and "
        "re-run /uberdev:review-pr; adding '.uberdev/' to the repository's ignore "
        "stack also removes the need for this publication entirely.",
        file=sys.stderr,
    )
    raise SystemExit(2)
PY
}
review_reserve_run_directory() {
  local runs_root="${@:1:1}" runs_identity_json="${@:2:1}" requested_run_id="${@:3:1}"
  local explicit_run_id="${@:4:1}" pr_number="${@:5:1}"
  [ "$#" -eq 5 ] || return 2
  python3 -I -B - "$runs_root" "$runs_identity_json" "$requested_run_id" \
    "$explicit_run_id" "$pr_number" "$RUN_ID_RESERVATION_MAX_ATTEMPTS" \
    "$REVIEW_RUN_MANIFEST" <<'PY'
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import secrets
import stat
import sys

(
    runs_root,
    runs_identity_json,
    requested_run_id,
    explicit_text,
    pr_text,
    attempts_text,
    module_path,
) = sys.argv[1:]
runs_root = os.path.abspath(runs_root)
spec = importlib.util.spec_from_file_location("uberdev_review_reserve_manifest", module_path)
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)
RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")
created = False
created_candidate = None
run_descriptor = None
runs_descriptor = None
# `attempted` is appended BEFORE the publisher is invoked, `published` only
# after it returns. The publisher deliberately never unlinks a failed attempt
# (see secure_publish_exact_no_clobber), so a name that is attempted-but-not-
# published may still exist on disk as untrusted crash residue whose identity we
# were never able to record. Rollback can safely unlink only the `published`
# names; the difference is reported, never silently dropped.
attempted = []
published = []

def require_identity(value):
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in value)
    ):
        raise module.ManifestRejected("review_directory_identity_invalid")
    return tuple(value)

def require_owned_directory(entry, expected):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    if (
        not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or getattr(entry, "st_reparse_tag", 0)
        or (entry.st_dev, entry.st_ino) != expected
        or (uid is not None and entry.st_uid != uid)
    ):
        raise module.ManifestRejected("review_directory_identity_changed")

def report_rollback_failure(what, error):
    # Rollback runs on an error path, so it stays best-effort — but every step
    # that fails is NAMED on stderr. The two `except: pass` blocks this replaces
    # made an un-reclaimable reservation indistinguishable from a clean one, and
    # the leftover directory then permanently poisons the explicit-RUN_ID
    # "refusing reuse" path with no trace of why.
    print(f"warning: review reservation rollback could not {what}: {error}", file=sys.stderr)

def rollback_reservation(name):
    run_dir = os.path.join(runs_root, name)
    try:
        current = os.lstat(run_dir)
        run_identity = (current.st_dev, current.st_ino)
        require_owned_directory(current, run_identity)
    except (OSError, module.ManifestRejected) as error:
        report_rollback_failure(f"re-stat the reserved directory {run_dir}", error)
        return
    for marker_name, identity in reversed(published):
        try:
            marker = os.lstat(os.path.join(run_dir, marker_name))
            if module._artifact_identity(marker) != identity:
                report_rollback_failure(
                    f"retire {marker_name}", "identity changed since publication"
                )
                continue
            if module._uses_native_windows_filesystem():
                os.unlink(os.path.join(run_dir, marker_name))
            elif run_descriptor is not None:
                relative = os.stat(marker_name, dir_fd=run_descriptor, follow_symlinks=False)
                if module._artifact_identity(relative) != identity:
                    report_rollback_failure(
                        f"retire {marker_name}", "identity changed since publication"
                    )
                    continue
                os.unlink(marker_name, dir_fd=run_descriptor)
            else:
                report_rollback_failure(f"retire {marker_name}", "no run directory descriptor")
                continue
        except OSError as error:
            report_rollback_failure(f"retire {marker_name}", error)
    for marker_name in attempted:
        if any(marker_name == published_name for published_name, _ in published):
            continue
        # secure_publish_exact_no_clobber never unlinks a failed attempt, and we
        # hold no identity for it, so removing it by name could destroy a file we
        # did not create. Surface it instead of pretending the slot is clean.
        if os.path.lexists(os.path.join(run_dir, marker_name)):
            report_rollback_failure(
                f"retire {marker_name}",
                "unconfirmed publication left crash residue; inspect and remove it manually",
            )
    try:
        if module._uses_native_windows_filesystem():
            if not os.listdir(run_dir):
                current = os.lstat(run_dir)
                require_owned_directory(current, run_identity)
                os.rmdir(run_dir)
        elif runs_descriptor is not None:
            if run_descriptor is not None and os.listdir(run_descriptor):
                return
            if run_descriptor is None and os.listdir(run_dir):
                return
            current = os.stat(name, dir_fd=runs_descriptor, follow_symlinks=False)
            require_owned_directory(current, run_identity)
            os.rmdir(name, dir_fd=runs_descriptor)
            os.fsync(runs_descriptor)
    except (OSError, module.ManifestRejected) as error:
        report_rollback_failure(f"remove the reserved directory {run_dir}", error)

try:
    explicit = int(explicit_text)
    attempts = int(attempts_text)
    if explicit not in (0, 1) or attempts < 1 or attempts > 128:
        raise module.ManifestRejected("review_reservation_policy_invalid")
    if re.fullmatch(r"[1-9][0-9]*", pr_text) is None:
        raise module.ManifestRejected("review_pr_number_invalid")
    pr_number = int(pr_text)
    runs_identity = require_identity(json.loads(runs_identity_json))
    module._reject_symlinked_ancestors(runs_root)
    module._reject_windows_reparse_ancestors(runs_root)
    runs_path = os.lstat(runs_root)
    require_owned_directory(runs_path, runs_identity)
    if not module._uses_native_windows_filesystem():
        runs_descriptor = module._open_directory_fd(runs_root)
        require_owned_directory(os.fstat(runs_descriptor), runs_identity)

    candidate = None
    for attempt in range(attempts):
        if explicit:
            candidate = requested_run_id
        else:
            candidate = requested_run_id + secrets.token_hex(4)
        if RUN_ID.fullmatch(candidate) is None:
            raise module.ManifestRejected(
                f"BUG: run-id {candidate} does not match "
                "^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ — file an issue"
            )
        try:
            # `created` must flip the instant mkdir returns, BEFORE the parent
            # fsync. The directory already exists at that point; the fsync only
            # makes the parent entry durable. Recording ownership afterwards
            # meant an fsync OSError left created=False, so the failure handler
            # skipped rollback entirely and orphaned the directory — and with an
            # explicit RUN_ID that orphan permanently poisons the run id through
            # the "caller-supplied RUN_ID collision; refusing reuse" arm.
            if module._uses_native_windows_filesystem():
                os.mkdir(os.path.join(runs_root, candidate), 0o700)
                created = True
                created_candidate = candidate
            else:
                os.mkdir(candidate, 0o700, dir_fd=runs_descriptor)
                created = True
                created_candidate = candidate
                os.fsync(runs_descriptor)
            break
        except FileExistsError:
            if explicit:
                raise module.ManifestRejected(
                    "caller-supplied RUN_ID collision; refusing reuse"
                )
            if attempt + 1 == attempts:
                raise module.ManifestRejected(
                    "exhausted bounded review run-id reservation attempts"
                )
    if not created or candidate is None:
        raise module.ManifestRuntimeError("review_run_reservation_failed")

    run_dir = os.path.join(runs_root, candidate)
    run_path = os.lstat(run_dir)
    run_identity = (run_path.st_dev, run_path.st_ino)
    require_owned_directory(run_path, run_identity)
    if not module._uses_native_windows_filesystem():
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        run_descriptor = os.open(candidate, flags, dir_fd=runs_descriptor)
        require_owned_directory(os.fstat(run_descriptor), run_identity)

    started_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )
    context = (
        json.dumps(
            {"issue": 0, "pr": pr_number, "started_at": started_at},
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode()
    marker_records = {}
    for name, payload in (("locked", b""), ("pr-context.json", context)):
        # Register the attempt BEFORE the call: a publisher that fails after
        # creating the carrier leaves residue this reservation is responsible
        # for reporting. Registering only on success made that residue invisible
        # to rollback, which then silently failed to reclaim the directory.
        attempted.append(name)
        _path, identity, digest = module.secure_publish_exact_no_clobber(
            os.path.join(run_dir, name), payload, run_identity
        )
        published.append((name, identity))
        marker_records[name] = {
            "identity": list(identity),
            "sha256": digest,
            "size": len(payload),
        }
    receipt = {
        "markers": marker_records,
        "run_dir": run_dir,
        "run_dir_identity": list(run_identity),
        "run_id": candidate,
        "runs_root": runs_root,
        "runs_root_identity": list(runs_identity),
        "schema": "review-run-reservation-v1",
    }
    raw = json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()
    token = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
    # `end=""` suppresses only the TRAILING newline; the two embedded separators
    # are still translated to \r\n under native-Windows text mode. The shell splits
    # this triple on $'\n', so a translated separator leaves a trailing CR on the
    # receipt and on RUN_ID -- failing the receipt regex and leaking into marker
    # paths. Disable newline translation on the text layer rather than dropping to
    # sys.stdout.buffer: writing bytes while other code in this interpreter uses
    # print() mixes two buffering layers and can reorder output.
    sys.stdout.reconfigure(newline="")
    print(f"v1:{token}\n{candidate}\n{run_dir}", end="")
except (OSError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    # Keyed off the candidate recorded at mkdir time, not off locals() that are
    # only bound several statements later — a failure between mkdir and the
    # run_dir/run_identity assignments used to skip rollback altogether.
    if created and created_candidate is not None:
        rollback_reservation(created_candidate)
    print(f"error: could not reserve private review run: {error}", file=sys.stderr)
    raise SystemExit(2)
finally:
    if run_descriptor is not None:
        os.close(run_descriptor)
    if runs_descriptor is not None:
        os.close(runs_descriptor)
PY
}
# Owner of last resort for abandoned reservation markers (#344). The EXIT trap
# that used to retire them was replaced by a receipt that ONLY the final
# publication fence can redeem, and every `review_abandon_run_reservation` call
# site sits inside the setup fence — so any abandonment after setup (SIGKILL, a
# crashed reviewer wave, a harness timeout, an operator ^C) leaves `locked` +
# `pr-context.json` behind with nobody to remove them, and `/uberdev:goal`
# Phase 2b then treats the PR as in-flight for a full REVIEW_GRACE_SECS. This
# reaper gives them an owner: it runs once per `/review-pr`, immediately before
# this run reserves its own directory. It NEVER installs an EXIT trap (the
# receipt design forbids one) and never removes a directory or a verdict — only
# the two receipt-shaped markers of a run that is demonstrably abandoned.
review_reap_stale_run_reservations() {
  local runs_root="${@:1:1}" runs_identity_json="${@:2:1}" reap_secs="${@:3:1}"
  [ "$#" -eq 3 ] || return 2
  python3 -I -B - "$runs_root" "$runs_identity_json" "$reap_secs" "$REVIEW_RUN_MANIFEST" <<'PY'
import importlib.util
import json
import os
import re
import stat
import sys
import time

runs_root, runs_identity_json, reap_text, module_path = sys.argv[1:]
runs_root = os.path.abspath(runs_root)
spec = importlib.util.spec_from_file_location("uberdev_review_reap_manifest", module_path)
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)

RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")
MARKERS = ("locked", "pr-context.json")
VERDICT = "review-pr-verdict.json"
KNOWN = set(MARKERS) | {VERDICT}

def require_identity(value):
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in value)
    ):
        raise module.ManifestRejected("review_directory_identity_invalid")
    return tuple(value)

def require_owned_directory(entry, expected):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    if (
        not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or getattr(entry, "st_reparse_tag", 0)
        or (entry.st_dev, entry.st_ino) != expected
        or (uid is not None and entry.st_uid != uid)
    ):
        raise module.ManifestRejected("review_directory_identity_changed")

def owned_plain_file(entry):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    return (
        stat.S_ISREG(entry.st_mode)
        and not stat.S_ISLNK(entry.st_mode)
        and not getattr(entry, "st_reparse_tag", 0)
        and entry.st_nlink == 1
        and (uid is None or entry.st_uid == uid)
    )

def note(message):
    # Never silent: a reaper that cannot do its job must say so, or #344 comes
    # back as an unexplained /goal stall.
    print(f"notice: review reservation reaper: {message}", file=sys.stderr)

def marker_stat(run_dir, run_descriptor, name):
    if run_descriptor is None:
        return os.lstat(os.path.join(run_dir, name))
    return os.stat(name, dir_fd=run_descriptor, follow_symlinks=False)

def reap_run_directory(run_dir, run_descriptor, entries):
    # The two routine paths below stay SILENT on purpose: a runs root
    # accumulates one directory per completed review, and every one of those
    # either holds a verdict or has already had its markers retired by the final
    # fence. Announcing them would emit a line per historical run and bury the
    # ones an operator actually needs. Every path that leaves a LIVE-looking
    # reservation in place is announced.
    if VERDICT in entries:
        return False
    if "locked" not in entries:
        return False
    unexpected = entries - KNOWN
    if unexpected:
        note(f"{run_dir} holds unrecognized entries {sorted(unexpected)}; leaving it untouched")
        return False
    locked = marker_stat(run_dir, run_descriptor, "locked")
    if not owned_plain_file(locked):
        note(f"{run_dir}/locked is not a plain single-linked owned file; leaving it untouched")
        return False
    if (now - locked.st_mtime) <= reap_secs:
        # This is the ONE skip an operator chasing a `/uberdev:goal` stall needs
        # named: the directory still looks like an in-flight run, so the reaper
        # deliberately kept its hands off and the PR stays "in review" until the
        # marker ages past the policy.
        note(
            f"{run_dir}/locked is {int(now - locked.st_mtime)}s old, "
            f"under the {reap_secs}s reap policy; leaving it untouched"
        )
        return False
    removed = 0
    for name in MARKERS:
        if name not in entries:
            continue
        try:
            current = marker_stat(run_dir, run_descriptor, name)
            if not owned_plain_file(current):
                note(f"{run_dir}/{name} is not a plain single-linked owned file; leaving it untouched")
                continue
            if run_descriptor is None:
                os.unlink(os.path.join(run_dir, name))
            else:
                os.unlink(name, dir_fd=run_descriptor)
            removed += 1
        except OSError as error:
            note(f"could not retire {run_dir}/{name}: {error}")
    if removed and run_descriptor is not None:
        try:
            os.fsync(run_descriptor)
        except OSError as error:
            note(f"could not fsync {run_dir} after retiring markers: {error}")
    return removed > 0

try:
    if re.fullmatch(r"[0-9]+", reap_text) is None:
        raise module.ManifestRejected("review_reservation_reap_policy_invalid")
    reap_secs = int(reap_text)
    if reap_secs < 60 or reap_secs > 604800:
        raise module.ManifestRejected("review_reservation_reap_policy_invalid")
    runs_identity = require_identity(json.loads(runs_identity_json))
    module._reject_symlinked_ancestors(runs_root)
    module._reject_windows_reparse_ancestors(runs_root)
    require_owned_directory(os.lstat(runs_root), runs_identity)
except (OSError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    print(f"error: could not inspect the private review run root: {error}", file=sys.stderr)
    raise SystemExit(2)

now = time.time()
reaped = 0
native = module._uses_native_windows_filesystem()
runs_descriptor = None
try:
    if native:
        names = os.listdir(runs_root)
    else:
        runs_descriptor = module._open_directory_fd(runs_root)
        require_owned_directory(os.fstat(runs_descriptor), runs_identity)
        names = os.listdir(runs_descriptor)
    for name in sorted(names):
        if RUN_ID.fullmatch(name) is None:
            continue
        run_dir = os.path.join(runs_root, name)
        run_descriptor = None
        try:
            if native:
                current = os.lstat(run_dir)
                identity = (current.st_dev, current.st_ino)
                require_owned_directory(current, identity)
                entries = set(os.listdir(run_dir))
            else:
                current = os.stat(name, dir_fd=runs_descriptor, follow_symlinks=False)
                identity = (current.st_dev, current.st_ino)
                require_owned_directory(current, identity)
                flags = (
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                run_descriptor = os.open(name, flags, dir_fd=runs_descriptor)
                # Identity re-stat: the descriptor we will unlink through and the
                # name we resolved must still be the same directory object.
                require_owned_directory(os.fstat(run_descriptor), identity)
                entries = set(os.listdir(run_descriptor))
            if reap_run_directory(run_dir, run_descriptor, entries):
                reaped += 1
                note(f"retired abandoned reservation markers in {run_dir}")
        except (OSError, module.ManifestRejected) as error:
            note(f"skipped {run_dir}: {error}")
        finally:
            if run_descriptor is not None:
                os.close(run_descriptor)
    if reaped and runs_descriptor is not None:
        try:
            os.fsync(runs_descriptor)
        except OSError as error:
            note(f"could not fsync {runs_root} after reaping: {error}")
finally:
    if runs_descriptor is not None:
        os.close(runs_descriptor)
print(reaped, end="")
PY
}
review_abandon_run_reservation() {
  local reservation_receipt="${@:1:1}"
  [ "$#" -eq 1 ] && [ -n "$reservation_receipt" ] || return 2
  python3 -I -B - "$reservation_receipt" "$REVIEW_RUN_MANIFEST" <<'PY'
import base64
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys

receipt_text, module_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("uberdev_review_abandon_manifest", module_path)
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)

def decode_receipt(value):
    if not value.startswith("v1:") or re.fullmatch(r"v1:[A-Za-z0-9_-]+", value) is None:
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    token = value[3:]
    raw = base64.b64decode(
        token + "=" * (-len(token) % 4), altchars=b"-_", validate=True
    )
    receipt = json.loads(raw)
    if not isinstance(receipt, dict) or set(receipt) != {
        "markers", "run_dir", "run_dir_identity", "run_id", "runs_root",
        "runs_root_identity", "schema",
    }:
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    if (
        receipt["schema"] != "review-run-reservation-v1"
        or json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode() != raw
        or re.fullmatch(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+", receipt["run_id"] or "") is None
    ):
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    for key in ("runs_root_identity", "run_dir_identity"):
        identity = receipt[key]
        if (
            not isinstance(identity, list)
            or len(identity) != 2
            or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in identity)
        ):
            raise module.ManifestRejected("review_reservation_receipt_invalid")
    runs_root = os.path.abspath(receipt["runs_root"])
    run_dir = os.path.abspath(receipt["run_dir"])
    if (
        runs_root != receipt["runs_root"]
        or run_dir != receipt["run_dir"]
        or run_dir != os.path.join(runs_root, receipt["run_id"])
        or os.path.basename(runs_root) != "runs"
        or os.path.basename(os.path.dirname(runs_root)) != ".uberdev"
        or set(receipt["markers"]) != {"locked", "pr-context.json"}
    ):
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    for marker in receipt["markers"].values():
        if (
            not isinstance(marker, dict)
            or set(marker) != {"identity", "sha256", "size"}
            or not isinstance(marker["identity"], list)
            or len(marker["identity"]) != 6
            or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in marker["identity"])
            or re.fullmatch(r"[0-9a-f]{64}", marker["sha256"] or "") is None
            or isinstance(marker["size"], bool)
            or not isinstance(marker["size"], int)
            or marker["size"] < 0
            or marker["identity"][2] != marker["size"]
        ):
            raise module.ManifestRejected("review_reservation_receipt_invalid")
    return receipt

def require_directory(entry, identity):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    if (
        not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or getattr(entry, "st_reparse_tag", 0)
        or (entry.st_dev, entry.st_ino) != tuple(identity)
        or (uid is not None and entry.st_uid != uid)
    ):
        raise module.ManifestRejected("review_reservation_directory_changed")

try:
    receipt = decode_receipt(receipt_text)
    runs_root = receipt["runs_root"]
    run_dir = receipt["run_dir"]
    module._reject_symlinked_ancestors(run_dir)
    module._reject_windows_reparse_ancestors(run_dir)
    require_directory(os.lstat(runs_root), receipt["runs_root_identity"])
    require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
    for name, marker in receipt["markers"].items():
        _payload, identity = module.secure_capture_published(
            os.path.join(run_dir, name),
            marker["sha256"],
            marker["size"],
            marker["size"],
        )
        if list(identity) != marker["identity"]:
            raise module.ManifestRejected("review_reservation_marker_changed")

    if module._uses_native_windows_filesystem():
        if set(os.listdir(run_dir)) != set(receipt["markers"]):
            raise module.ManifestRejected("review_reservation_directory_not_empty")
        for name, marker in receipt["markers"].items():
            current = os.lstat(os.path.join(run_dir, name))
            if list(module._artifact_identity(current)) != marker["identity"]:
                raise module.ManifestRejected("review_reservation_marker_changed")
            os.unlink(os.path.join(run_dir, name))
        require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
        os.rmdir(run_dir)
    else:
        runs_descriptor = module._open_directory_fd(runs_root)
        run_descriptor = None
        try:
            require_directory(os.fstat(runs_descriptor), receipt["runs_root_identity"])
            flags = (
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            run_descriptor = os.open(
                receipt["run_id"], flags, dir_fd=runs_descriptor
            )
            require_directory(os.fstat(run_descriptor), receipt["run_dir_identity"])
            if set(os.listdir(run_descriptor)) != set(receipt["markers"]):
                raise module.ManifestRejected("review_reservation_directory_not_empty")
            for name, marker in receipt["markers"].items():
                current = os.stat(name, dir_fd=run_descriptor, follow_symlinks=False)
                if list(module._artifact_identity(current)) != marker["identity"]:
                    raise module.ManifestRejected("review_reservation_marker_changed")
                os.unlink(name, dir_fd=run_descriptor)
            os.fsync(run_descriptor)
            require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
            os.rmdir(receipt["run_id"], dir_fd=runs_descriptor)
            os.fsync(runs_descriptor)
        finally:
            if run_descriptor is not None:
                os.close(run_descriptor)
            os.close(runs_descriptor)
except (OSError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    print(f"error: could not abandon private review reservation: {error}", file=sys.stderr)
    raise SystemExit(2)
PY
}
# Standalone carrier preparation owns the clean-worktree gate. Run it before
# the checkout-local reservation so our own `.uberdev/runs/<RUN_ID>` evidence
# cannot appear as pre-existing untracked input in repositories that do not
# yet ignore `.uberdev/`. The workspace allocator below sees this inherited
# carrier and therefore does not repeat the preparation.
if [ -z "${UBERDEV_RUN_CARRIER_JSON:-}" ]; then
  uberdev_prepare_run_carrier review-pr "$PR_NUMBER" medium "$RISK_JSON" >/dev/null || {
    rc=$?; return "$rc" 2>/dev/null || exit "$rc"
  }
fi
REVIEW_RUN_REPO_ROOT="$(git -C "${WORKTREE_ROOT:-.}" rev-parse --show-toplevel)" || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
if [ "$RUN_ID_WAS_EXPLICIT" -eq 1 ]; then
  REVIEW_RUN_ID_REQUEST="$RUN_ID"
else
  REVIEW_RUN_ID_REQUEST="$(date -u +%Y%m%d-%H%M%S)-$(git -C "$REVIEW_RUN_REPO_ROOT" rev-parse --short HEAD)" || {
    rc=$?; return "$rc" 2>/dev/null || exit "$rc"
  }
fi
REVIEW_RUN_ROOT_RECORD="$(review_prepare_run_root "$REVIEW_RUN_REPO_ROOT")" || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
REVIEW_RUNS_ROOT="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["path"],end="")' "$REVIEW_RUN_ROOT_RECORD")" || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
REVIEW_RUNS_ROOT_IDENTITY_JSON="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["identity"],separators=(",",":")),end="")' "$REVIEW_RUN_ROOT_RECORD")" || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
# `check-ignore -q` exits 1 for a NOT-ignored path — the expected first-run
# state this case arm handles, not an error. The probe must therefore be
# guarded: bare, it aborts the fence under `set -e` before `$?` is ever read,
# so the 0|1|* triage below becomes unreachable.
REVIEW_IGNORE_RC=0
git -C "$REVIEW_RUN_REPO_ROOT" check-ignore -q -- ".uberdev/runs/.review-probe" || REVIEW_IGNORE_RC=$?
case "$REVIEW_IGNORE_RC" in
  0)
    # The repository's effective ignore stack already covers private evidence.
    ;;
  1)
    review_publish_local_ignore "$REVIEW_RUNS_ROOT" "$REVIEW_RUNS_ROOT_IDENTITY_JSON" || {
      rc=$?; return "$rc" 2>/dev/null || exit "$rc"
    }
    REVIEW_IGNORE_RC=0
    git -C "$REVIEW_RUN_REPO_ROOT" check-ignore -q -- ".uberdev/runs/.review-probe" || REVIEW_IGNORE_RC=$?
    if [ "$REVIEW_IGNORE_RC" -ne 0 ]; then
      echo "error: installed review ignore policy is not effective" >&2
      return 2 2>/dev/null || exit 2
    fi
    ;;
  *)
    echo "error: could not inspect the effective review ignore policy" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac
# Retire any abandoned predecessor's markers BEFORE reserving our own directory
# (#344). Ordering matters: the reaper must not see this run's own fresh
# `locked` marker, and a stalled `/uberdev:goal` should be unblocked by the very
# next `/review-pr` rather than waiting out REVIEW_GRACE_SECS.
review_reap_stale_run_reservations \
  "$REVIEW_RUNS_ROOT" "$REVIEW_RUNS_ROOT_IDENTITY_JSON" "$REVIEW_RESERVATION_REAP_SECS" >/dev/null || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
REVIEW_RESERVATION_OUTPUT="$(
  review_reserve_run_directory \
    "$REVIEW_RUNS_ROOT" "$REVIEW_RUNS_ROOT_IDENTITY_JSON" \
    "$REVIEW_RUN_ID_REQUEST" "$RUN_ID_WAS_EXPLICIT" "$PR_NUMBER"
)" || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
# BEGIN review-reservation-triple-guard-v1
REVIEW_RUN_RESERVATION_RECEIPT="${REVIEW_RESERVATION_OUTPUT%%$'\n'*}"
REVIEW_RESERVATION_REMAINDER="${REVIEW_RESERVATION_OUTPUT#*$'\n'}"
RUN_ID="${REVIEW_RESERVATION_REMAINDER%%$'\n'*}"
MARKER_DIR="${REVIEW_RESERVATION_REMAINDER#*$'\n'}"
# The three-way split degenerates when the helper emits NO newline at all:
# `${v%%$'\n'*}` and `${v#*$'\n'}` both return the whole string, so RECEIPT ==
# RUN_ID == MARKER_DIR and a pure non-emptiness guard passes — exporting the
# base64 receipt blob AS the RUN_ID and using it as a marker pathname. Validate
# each component's SHAPE, not just its length.
#
# Both pathnames are compared SEPARATOR-NORMALISED, because the two sides are
# produced by different worlds. `MARKER_DIR` comes from Python
# (`os.path.join(os.path.abspath(runs_root), run_id)`), which on native Windows
# emits `C:\...\.uberdev\runs\<RUN_ID>` — drive letter, backslashes — while this
# shell builds `$REVIEW_RUNS_ROOT/$RUN_ID` with a forward slash. A `/*`-only
# absoluteness test plus a raw string equality therefore rejected every
# legitimate Windows reservation: the guard fired on the HAPPY path and
# abandoned the directory it had just reserved. Normalising `\` to `/` on both
# sides keeps the assertion exact on POSIX and correct on Windows.
REVIEW_RESERVATION_VALID=1
REVIEW_MARKER_DIR_NORMALIZED="${MARKER_DIR//\\//}"
REVIEW_MARKER_DIR_EXPECTED="${REVIEW_RUNS_ROOT//\\//}/$RUN_ID"
[[ "$REVIEW_RUN_RESERVATION_RECEIPT" =~ ^v1:[A-Za-z0-9_-]+$ ]] || REVIEW_RESERVATION_VALID=0
[[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] || REVIEW_RESERVATION_VALID=0
case "$REVIEW_MARKER_DIR_NORMALIZED" in
  /*) ;;               # POSIX absolute (and UNC `\\server\share`, once normalised)
  [A-Za-z]:/*) ;;      # native Windows absolute (`C:\...`)
  *) REVIEW_RESERVATION_VALID=0 ;;
esac
[ "$REVIEW_MARKER_DIR_NORMALIZED" = "$REVIEW_MARKER_DIR_EXPECTED" ] || REVIEW_RESERVATION_VALID=0
if [ "$REVIEW_RESERVATION_VALID" -ne 1 ]; then
  echo "error: review run reservation returned an incomplete or malformed receipt triple" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" 2>/dev/null || true
  return 2 2>/dev/null || exit 2
fi
# END review-reservation-triple-guard-v1
export RUN_ID MARKER_DIR REVIEW_RUN_RESERVATION_RECEIPT
uberdev_command_workspace_prepare review-pr "$PR_NUMBER" medium "$RISK_JSON" "$RUN_ID" "${WORKTREE_ROOT:-}" >/dev/null || {
  rc=$?
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || rc=2
  return "$rc" 2>/dev/null || exit "$rc"
}
if [ "$(cd "$WORKTREE_ROOT" && pwd -P)" != "$(cd "$REVIEW_RUN_REPO_ROOT" && pwd -P)" ]; then
  echo "error: reserved review run root does not match the validated workspace" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || true
  return 2 2>/dev/null || exit 2
fi
uberdev_dispatch_preflight_backend "$UBERDEV_CARRIER_BACKEND" review-pr || {
  rc=$?
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || rc=2
  return "$rc" 2>/dev/null || exit "$rc"
}
# BEGIN review-run-handoff-v1
# Everything below exists so that the NEXT fence -- a different process, with an
# empty environment -- can find this run again (#427). Placed after the backend
# preflight on purpose: a setup that abandons its reservation above must never
# leave a pointer to a run that no longer exists.
#
# 1. The workspace descriptor. uberdev_command_workspace_prepare already
#    computed every artifact pathname and this fence used to throw the JSON
#    away, forcing 47 later fences to read scalars nobody re-bound. Persisting
#    it makes lib/command-workspace.py the SINGLE implementation of that path
#    algebra -- review_fleet_rehydrate reads these bytes instead of re-deriving
#    "<run>/pr-diff.md" a second time.
#
#    Written from the shell variable, never by re-running the helper and never
#    by capturing the call above in a command substitution: that call must stay
#    a direct call, because the exported path globals are what the rest of this
#    fence uses.
. "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-fleet-args.sh" || {
  echo "error: review setup could not load the review fleet args library" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || true
  return 2 2>/dev/null || exit 2
}
REVIEW_WORKSPACE_DESCRIPTOR="$RESEARCH_DIR_ABS/command-workspace.json"
( umask 077 && printf '%s\n' "$UBERDEV_COMMAND_WORKSPACE_JSON" >"$REVIEW_WORKSPACE_DESCRIPTOR.tmp.$$" ) && \
  mv -f "$REVIEW_WORKSPACE_DESCRIPTOR.tmp.$$" "$REVIEW_WORKSPACE_DESCRIPTOR" || {
  rm -f "$REVIEW_WORKSPACE_DESCRIPTOR.tmp.$$" 2>/dev/null || true
  echo "error: review setup could not persist the run workspace descriptor" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || true
  return 2 2>/dev/null || exit 2
}
# 2. The active-run pointer -- the ONE value that is not derivable from the
#    filesystem, written where the runs root's own `*` .gitignore already covers
#    it so the reviewed working tree stays clean.
REVIEW_HEAD_SHA_FOR_POINTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || {
  echo "error: review setup could not resolve HEAD for the active-run pointer" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || true
  return 2 2>/dev/null || exit 2
}
review_fleet_write_active_run_pointer "$WORKTREE_ROOT" "$RUN_ID" "$PR_NUMBER" "$REVIEW_HEAD_SHA_FOR_POINTER" || {
  echo "error: review setup could not publish the active-run pointer" >&2
  review_abandon_run_reservation "$REVIEW_RUN_RESERVATION_RECEIPT" || true
  return 2 2>/dev/null || exit 2
}
# 3. The carry line. The orchestrator reads this and MUST prefix every later
#    /review-pr Bash call with it; the pointer above is the recovery path for
#    when that context is lost, not the primary channel.
#
#    On STDERR, with every other notice this command emits. Setup's stdout is
#    consumed by callers that source this fence and then capture the stdout of
#    what they run next; a line on stdout would land in the middle of their
#    payload.
printf 'REVIEW_CARRY RUN_ID=%s\n' "$RUN_ID" >&2
# END review-run-handoff-v1
REVIEW_ITERATION="${REVIEW_ITERATION:-1}"
REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT:-600}"
CI_FIX_LOOP_ITER="${CI_FIX_LOOP_ITER:-1}"
# Phase 3 derives run authority from the selected failed check's immutable
# metadata. Setup has no sentinel default; 6c.1 clears any inherited tuple
# before every probe so caller state can never become classification authority.
CI_RUN_ID="${CI_RUN_ID:-}"
CI_RUN_EVENT="${CI_RUN_EVENT:-}"
CI_RUN_CHECK_LINK="${CI_RUN_CHECK_LINK:-}"
FOCUS="${FOCUS:-${ARGUMENTS:-}}"
review_json_string() {
  [ "$#" -ge 1 ] || return 2
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "${@:1:1}"
}
```

### Carrying the run across fences (read this before running any later fence)

Every `bash` block below is a **fresh shell**. The setup fence above is the only
one that reserves a run, and its shell exits before the next block starts, so no
shell variable it bound is reachable from any later block.

The setup fence therefore prints exactly one line, on **stderr**:

```
REVIEW_CARRY RUN_ID=<run id>
```

**The orchestrator MUST prefix every later `/review-pr` Bash call with
`RUN_ID=<that value>`.** That is the primary channel and the only one that is
unambiguous when more than one review is in flight against the same checkout.

When that context is lost — a compacted session, a resumed run, an operator
re-entering mid-pipeline — every fence recovers on its own through
`<repo>/.uberdev/runs/.review-active-run.json`, the pointer the setup fence
publishes alongside the reservation. Recovery is guarded, not best-effort: the
named run must still hold its `locked` and `pr-context.json` markers, must not
already have published a verdict, must be for the PR this fence is reviewing,
and must be younger than `REVIEW_RESERVATION_REAP_SECS`. Any guard that fails is
`rc 2` with its own message — never a silent fallback to some other run.

Both paths land in `review_fleet_rehydrate` (`lib/review-fleet-args.sh`), which
is the first call of every executed fence below.

<!-- BEGIN review-child-builder-v1 -->
```bash
review_child_record() {
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" record_path="${@:5:1}"
  [ "$#" -ge 5 ] || return 2
  if command -v uberdev_child_inputs_validate >/dev/null 2>&1; then
    inputs="$(uberdev_child_inputs_validate "$edge" "$inputs")" || return 2
  fi
  python3 -I -B - "$edge" "$instance" "$inputs" "$risks" "$record_path" <<'PY'
import json,sys
edge,instance,inputs,risks,path=sys.argv[1:]
with open(path,'a') as f: f.write(json.dumps({'edge':edge,'instance':instance,'inputs':json.loads(inputs),'risks':json.loads(risks)},sort_keys=True,separators=(',',':'))+'\n')
PY
}
review_child_fanout() {
  local records="${@:1:1}" descriptors="${@:2:1}" launched="${@:3:1}" timeout_s="${@:4:1}" row edge instance inputs risks handoff handoff_sha256 result child_status receipt dispatch_rc ledger_rc cleanup_rc index
  [ "$#" -ge 4 ] || return 2
  local preflight_refs=()
  local launch_edges=() launch_instances=() launch_handoffs=()
  local launch_handoff_sha256s=() launch_results=() launch_statuses=()
  : >"$descriptors"; : >"$launched"
  while IFS= read -r row; do
    edge="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["edge"])' "$row")"
    instance="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["instance"])' "$row")"
    inputs="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["inputs"],separators=(",",":")))' "$row")"
    risks="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["risks"],separators=(",",":")))' "$row")"
    uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks" >/dev/null || return $?
    python3 -I -B - "$edge" "$instance" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" "$descriptors" <<'PY'
import json,sys
edge,instance,handoff,handoff_sha256,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'instance':instance,'handoff':handoff,'handoff_sha256':handoff_sha256,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    preflight_refs+=("$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256")
    launch_edges+=("$edge"); launch_instances+=("$instance")
    launch_handoffs+=("$UBERDEV_CHILD_HANDOFF")
    launch_handoff_sha256s+=("$UBERDEV_CHILD_HANDOFF_SHA256")
    launch_results+=("$UBERDEV_CHILD_RESULT"); launch_statuses+=("$UBERDEV_CHILD_STATUS")
  done <"$records"
  uberdev_preflight_child_batch "${preflight_refs[@]}" || return $?
  for ((index=0; index<${#launch_handoffs[@]}; index++)); do
    edge="${launch_edges[$index]}"; instance="${launch_instances[$index]}"
    handoff="${launch_handoffs[$index]}"
    handoff_sha256="${launch_handoff_sha256s[$index]}"
    result="${launch_results[$index]}"; child_status="${launch_statuses[$index]}"
    if uberdev_dispatch_child_capture "$edge" "$handoff" "$handoff_sha256" "$result" "$child_status"; then
      receipt="$UBERDEV_CHILD_DISPATCH_RECEIPT"
    else
      dispatch_rc=$?; cleanup_rc=0
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: prior child cleanup failed after dispatch edge=$edge" >&2
      return "$dispatch_rc"
    fi
    if python3 -I -B - "$edge" "$instance" "$receipt" "$result" "$child_status" "$launched" <<'PY'
import json,sys
edge,instance,receipt,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'instance':instance,'receipt':receipt,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    then
      :
    else
      ledger_rc=$?; cleanup_rc=0
      uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: current child cleanup failed after receipt ledger write edge=$edge" >&2
      return "$ledger_rc"
    fi
  done
}
review_child_wait_all() {
  local launched="${@:1:1}" timeout_s="${@:2:1}" row result child_status wait_rc first_rc=0 cleanup_rc=0
  [ "$#" -ge 2 ] || return 2
  while IFS= read -r row; do
    result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
    child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
    if uberdev_wait_child "$child_status" "$result" "$timeout_s"; then
      continue
    else
      wait_rc=$?
    fi
    [ "$first_rc" -ne 0 ] || first_rc="$wait_rc"
    uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
  done <"$launched"
  if [ "$first_rc" -ne 0 ]; then
    [ "$cleanup_rc" -eq 0 ] || echo "error: cleanup failed after child wait" >&2
    return "$first_rc"
  fi
  return 0
}
review_child_result_path() {
  local launched="${@:1:1}" edge="${@:2:1}"
  [ "$#" -ge 2 ] || return 2
  python3 -I -B - "$launched" "$edge" "$UBERDEV_REVIEW_PLUGIN_ROOT" "$UBERDEV_CARRIER_RUN_DIR" \
    "$_UBERDEV_DISPATCH_BACKEND_ENUM" "$UBERDEV_CARRIER_BACKEND" <<'PY'
import hashlib,importlib.util,json,os,stat,sys
ledger,edge,plugin_root,carrier_run_dir,backend_policy,expected_backend=sys.argv[1:]
def fail(reason):
    print(reason,end='')
    raise SystemExit(2)
policy_backends=backend_policy.split('|')
if (not policy_backends or any(not item for item in policy_backends)
        or len(policy_backends)!=len(set(policy_backends)) or 'auto' not in policy_backends):
    fail('classification_carrier_mismatch')
allowed_backends=set(policy_backends); allowed_backends.remove('auto')
if expected_backend not in allowed_backends:
    fail('classification_carrier_mismatch')
spec=importlib.util.spec_from_file_location('uberdev_review_artifacts',os.path.join(plugin_root,'lib','run_manifest.py'))
if spec is None or spec.loader is None: fail('classification_ledger_unreadable')
artifacts=importlib.util.module_from_spec(spec); sys.modules[spec.name]=artifacts
try: spec.loader.exec_module(artifacts)
except Exception: fail('classification_ledger_unreadable')
if not os.path.lexists(ledger): fail('classification_ledger_missing')
try:
    ledger_bytes,_=artifacts.secure_capture_regular(ledger,1,1048576)
    rows=[json.loads(line) for line in ledger_bytes.decode('utf-8').splitlines() if line.strip()]
except Exception:
    fail('classification_ledger_malformed')
if any(not isinstance(row,dict) for row in rows):
    fail('classification_ledger_malformed')
matches=[row for row in rows if row.get('edge')==edge]
if not matches:
    fail('classification_ledger_edge_missing')
if len(matches)>1:
    fail('classification_ledger_duplicate')
row=matches[0]
if set(row)!={'edge','instance','receipt','result','status'}:
    fail('classification_ledger_malformed')
path=row.get('result'); status=row.get('status'); instance=row.get('instance')
expected_child=os.path.join(os.path.realpath(carrier_run_dir),'children',instance) if isinstance(instance,str) else ''
if (not os.path.isabs(carrier_run_dir) or os.path.realpath(carrier_run_dir)!=carrier_run_dir
        or not isinstance(path,str) or not os.path.isabs(path)
        or os.path.basename(path)!='result.md'
        or not isinstance(instance,str) or os.path.basename(os.path.dirname(path))!=instance
        or os.path.dirname(path)!=expected_child):
    fail('classification_result_path_invalid')
if (not isinstance(status,str) or not os.path.isabs(status)
        or os.path.basename(status)!='status.json'
        or os.path.dirname(status)!=os.path.dirname(path)):
    fail('classification_status_path_invalid')
try:
    receipt=json.loads(row['receipt'])
except (TypeError,json.JSONDecodeError):
    fail('classification_receipt_malformed')
receipt_keys={'schema_version','edge_id','instance_id','backend','handle','state','result_file','status_file'}
if (not isinstance(receipt,dict) or set(receipt)!=receipt_keys or receipt.get('schema_version')!=1
        or receipt.get('edge_id')!=edge or receipt.get('instance_id')!=instance
        or receipt.get('result_file')!=path or receipt.get('status_file')!=status
        or receipt.get('backend')!=expected_backend
        or not isinstance(receipt.get('handle'),str) or not receipt['handle']
        or receipt.get('state') not in {'running','completed'}):
    fail('classification_receipt_mismatch')
try:
    status_bytes,_=artifacts.secure_capture_regular(status,1,65536)
    status_value=json.loads(status_bytes.decode('utf-8'))
except Exception:
    fail('classification_status_unreadable')
if (not isinstance(status_value,dict) or status_value.get('state')!='completed'
        or type(status_value.get('exit_code')) is not int or status_value['exit_code']!=0
        or status_value.get('backend')!=receipt['backend']):
    fail('classification_child_not_completed_zero')
status_handle=status_value.get('pid')
if (status_handle is None or receipt['handle'] not in {str(status_handle),'pane:'+str(status_handle)}):
    fail('classification_receipt_mismatch')
if not os.path.lexists(path): fail('classification_artifact_missing')
try:
    payload,_=artifacts.secure_capture_regular(path,1,16777216)
except artifacts.ManifestRejected:
    fail('classification_artifact_unsafe')
except Exception:
    fail('classification_artifact_unreadable')
digest=hashlib.sha256(payload).hexdigest()
instance_digest=hashlib.sha256(instance.encode()).hexdigest()[:16]
snapshot=os.path.join(os.path.dirname(os.path.abspath(ledger)),f'ci-classification-{instance_digest}-{digest}.trusted.md')
try:
    parent=os.lstat(os.path.dirname(snapshot))
    uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
    if (stat.S_ISLNK(parent.st_mode) or not stat.S_ISDIR(parent.st_mode)
            or (uid is not None and parent.st_uid!=uid)):
        fail('classification_snapshot_failed')
    published,_,published_digest=artifacts.secure_publish_captured(snapshot,payload)
    captured,_=artifacts.secure_capture_published(published,published_digest,1,16777216)
    if captured!=payload or published_digest!=digest:
        fail('classification_snapshot_failed')
except SystemExit:
    raise
except Exception:
    fail('classification_snapshot_failed')
print(published,end='')
PY
}
review_child_single() {
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" prefix="${@:5:1}" timeout_s="${@:6:1}"
  [ "$#" -ge 6 ] || return 2
  : >"$prefix.records"
  review_child_record "$edge" "$instance" "$inputs" "$risks" "$prefix.records"
  review_child_fanout "$prefix.records" "$prefix.descriptors" "$prefix.launched" "$timeout_s" || return $?
  review_child_wait_all "$prefix.launched" "$timeout_s"
}
# BEGIN review-fixer-child-bound-v2
# BEGIN review-failed-return-guard-v1
review_guard_failed_fixer_return() {
  [ "$#" -eq 2 ] || return 2
  local head_before="${@:1:1}" original_rc="${@:2:1}" guard_receipt
  case "$original_rc" in ''|*[!0-9]*|0) return 2 ;; esac
  guard_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-failed-return \
    --working-dir "$WORKTREE_ROOT" \
    --evidence-dir "$RESEARCH_DIR_ABS" \
    --head-before "$head_before")" || {
    echo "error: MUTATED_BLOCKED — fixer failure left unvalidated repository mutation" >&2
    return 79
  }
  [ "$guard_receipt" = '{"status":"clean"}' ] || {
    echo "error: MUTATED_BLOCKED — fixer failure residue receipt is malformed" >&2
    return 79
  }
  return "$original_rc"
}
# END review-failed-return-guard-v1
review_fixer_child_bound() {
  [ "$#" -eq 10 ] || return 2
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" prefix="${@:5:1}" timeout_s="${@:6:1}"
  local authority_path="${@:7:1}" authority_sha256="${@:8:1}" disposition_path="${@:9:1}" applied_content_path="${@:10:1}"
  local receipt wait_rc
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks" >/dev/null || return $?
  uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" || return $?
  REVIEW_FIXER_RESULT_PATH="$UBERDEV_CHILD_RESULT"
  REVIEW_FIXER_STATUS_PATH="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child_capture "$edge" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" "$REVIEW_FIXER_RESULT_PATH" "$REVIEW_FIXER_STATUS_PATH" || return $?
  receipt="$UBERDEV_CHILD_DISPATCH_RECEIPT"
  REVIEW_FIXER_LAUNCH_BINDING="$(printf '%s' "$receipt" | python3 -I -B "$CODE_FIXER_CONTRACT" bind-fixer-launch-receipt \
    --edge-id "$edge" --instance-id "$instance" \
    --result-path "$REVIEW_FIXER_RESULT_PATH" \
    --status-path "$REVIEW_FIXER_STATUS_PATH" \
    --working-dir "$WORKTREE_ROOT" \
    --authority-path "$authority_path" \
    --authority-sha256 "$authority_sha256")" || {
    wait_rc=$?
    uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
    return "$wait_rc"
  }
  # Diagnostics only; authorization retains the exact in-memory binding above.
  python3 -I -B - "$edge" "$instance" "$REVIEW_FIXER_LAUNCH_BINDING" "$prefix.launched" <<'PY' || {
import json,sys
edge,instance,binding,path=sys.argv[1:]
value=json.loads(binding)
with open(path,"w",encoding="utf-8") as stream:
    json.dump({"edge":edge,"instance":instance,"receipt_sha256":value["receipt_sha256"]},stream,sort_keys=True,separators=(",",":"))
    stream.write("\n")
PY
    wait_rc=$?
    uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
    return "$wait_rc"
  }
  if uberdev_wait_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s"; then
    REVIEW_FIXER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-review-terminal \
      --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
      --disposition-path "$disposition_path" \
      --applied-content-path "$applied_content_path")" || return 74
    return 0
  fi
  wait_rc=$?
  uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
  return "$wait_rc"
}
# END review-fixer-child-bound-v2
```
<!-- END review-child-builder-v1 -->

- **Phase 1 — Review + Fix loop**: invoke `Skill(uberdev:post-impl-review)` to run the 7 reviewer agents in one or more cap-controlled waves, with every child in each wave dispatched before its first wait; read the resulting findings aggregate from `.uberdev/research/<RUN_ID>/post-impl-review-final.md`, then dispatch a fresh `code-fixer` subagent to auto-apply fixes from the findings.
- **Phase 2 — Simplify pass**: parallel fanout of the three simplify lenses (reuse / quality / efficiency) defined in `/uberdev:simplify`, with auto-applied edits committed separately. Single-message dispatch per the `uberdev:post-impl-review` contract.

Pass `--no-simplify` (anywhere in the arguments) to skip Phase 2 and preserve the legacy single-pass behavior. Cost trade-off: Phase 2 adds three extra agent invocations per run; opt out for fast feedback loops on iterative review (e.g. when you've already run `/uberdev:simplify` separately).

Pass `--turbo` (anywhere in the arguments) to acknowledge invocation from `finish-branch`'s turbo-mode auto-chain. `/review-pr` accepts `--turbo` for forwarder-compatibility and parses it without error, but its presence does NOT alter Phase 1 or Phase 2. **Phase 3 halt classes (`billing_quota`, `platform_outage`) suppress the AskUserQuestion prompt under `--turbo` and exit 1 without emitting a trust signal** — under `--turbo`, neither halt class can prompt because the queue would block silently. Phases 1 and 2 still produce an identical Phase 2 simplify commit, identical trailer payload, identical artifact triplet (label + trailer + JSON). Single code path → deterministic SHA binding for the `Reviewed-by:` trailer. The flag is documented here so the producer-defines-its-API contract is explicit (no LLM interpretation latitude).

## Review Workflow:

1. **Determine Review Scope**
   - Check git status to identify changed files
   - Parse arguments to see if user requested specific review aspects
   - Detect `--no-simplify` token in `$ARGUMENTS` and strip it from the aspect list — sets `SIMPLIFY_PHASE=0`, otherwise `SIMPLIFY_PHASE=1` (default).
   - Detect `--turbo` token in `$ARGUMENTS` AND/OR inherited env var `${UBERDEV_TURBO:-0} == "1"` (#97 — hybrid OR detector). Strip the `--turbo` token from the aspect list. Set `TURBO=1` if either source signals turbo; else `TURBO=0`. The detection result feeds the Phase 3 halt-class carve-out (6c.6 HALT) — it does NOT mutate `SIMPLIFY_PHASE` or any other phase variable. Hybrid form (mirrors `orchestrator/SKILL.md`):
     ```bash
     TURBO=0
     if [[ "${ARGUMENTS:-}" == *"--turbo"* ]] || [[ "${UBERDEV_TURBO:-0}" == "1" ]]; then
       TURBO=1
     fi
     ```
     `${ARGUMENTS:-}` is defense-in-depth against `set -u` and mirrors the `${UBERDEV_TURBO:-0}` half of the OR for symmetry (#97 follow-up).
     Rationale: `merge-pipeline` invokes `Skill("uberdev:review-pr", args: "${PR} --turbo")` (out-of-scope for #97) — arg form must remain accepted. `finish-branch` chains via `Skill("uberdev:review-pr")` with no flag (env-var inheritance, #97) — env form must also be accepted. The hybrid OR detector closes both call sites.
   - Detect `--no-ci-fix` token in `$ARGUMENTS` and strip it from the aspect list — sets `CI_FIX_PHASE=0` (probe-only mode), otherwise `CI_FIX_PHASE=1` (default). Mirrors `--no-simplify` shape. When `CI_FIX_PHASE=0`, Phase 3 6c.1 PROBE + 6c.2 MONITOR + 6c.3 CLASSIFY still run for audit telemetry; 6c.4 ROUTE / 6c.5 POST-FIX / 6c.6 HALT are skipped. Outcome is forced to `green` if probe was green; otherwise `halted` (still gates trust signal). The decision is **persisted**, not merely bound:
     ```bash
     . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
     review_fleet_rehydrate || return 2
     CI_FIX_PHASE=1
     if [[ "${ARGUMENTS:-}" == *"--no-ci-fix"* ]]; then
       CI_FIX_PHASE=0
     fi
     # THE FLAG HAS TO CROSS TO 6c.4 ROUTE (#399), which is a different harness
     # shell thousands of lines later. Held only in this scalar it was gone
     # before ROUTE's `${CI_FIX_PHASE:-1}` ever ran, so the documented default
     # won every invocation and `--no-ci-fix` silently mutated code and
     # force-pushed. Same run-dir carrier as ci-loop-state.json; ROUTE refuses
     # to run the mutating phase at all if this file is missing or unreadable,
     # so a failure to record it must abort HERE rather than be discovered as a
     # halt three phases in.
     CI_FIX_PHASE_RUN_DIR="${RESEARCH_DIR_ABS:?RESEARCH_DIR_ABS must be bound before the --no-ci-fix decision is recorded}"
     mkdir -p "$CI_FIX_PHASE_RUN_DIR" || { return 2 2>/dev/null || exit 2; }
     CI_FIX_PHASE_RUN_DIR="$(cd "$CI_FIX_PHASE_RUN_DIR" && pwd -P)" || { return 2 2>/dev/null || exit 2; }
     ( umask 077 && printf '%s\n' "$CI_FIX_PHASE" >"$CI_FIX_PHASE_RUN_DIR/ci-fix-phase.txt" ) || {
       echo "error: /uberdev:review-pr — could not record the --no-ci-fix decision to $CI_FIX_PHASE_RUN_DIR/ci-fix-phase.txt" >&2
       return 2 2>/dev/null || exit 2
     }
     ```
   - Detect `--no-defer-issues` token in `$ARGUMENTS` and strip it from the aspect list — sets `DEFER_ISSUES_PHASE=0` (skip findings-to-issues sub-phase), otherwise `DEFER_ISSUES_PHASE=1` (default). Mirrors `--no-ci-fix` / `--no-simplify` shape. When `DEFER_ISSUES_PHASE=0`, the Phase 2.5 dispatch is skipped entirely and the Step 7 Final Aggregation "Issues filed" row shows `(skipped: --no-defer-issues)`.
   - Default: Run all applicable reviews + Phase 2 simplify pass
   - **Capture aspect tokens.** Tokenise the remaining arguments (after the `--no-simplify` and `--turbo` flags are stripped) into `ASPECT_LIST` (an array). Example: `/uberdev:review-pr tests errors` → `ASPECT_LIST=("tests" "errors")`. Empty arguments → `ASPECT_LIST=()`. The `all` token is treated as "no emphasis" (i.e., default behavior — every reviewer's brief receives no emphasis section).
   - **Detect `sequential` token.** If `$ARGUMENTS` contains the bare token `sequential` (anywhere; case-sensitive), strip it from `ASPECT_LIST` and set `SEQUENTIAL=1`. Otherwise `SEQUENTIAL=0`.
   - **If `SEQUENTIAL=1`,** emit the user-visible stderr notice and bind the cap that Step 4 forwards as the `fanout_cap` **Skill input**:
     ```bash
     echo "notice: running post-impl-review sequentially via fanout_cap=1" >&2
     POST_IMPL_FANOUT_CAP=1
     ```
     **Why an input and not an `export` (#302).** Every `bash` block in this command is a FRESH shell — no `export`, trap, PID, or array survives to the next block. The previous `export UBERDEV_FANOUT_POST_IMPL_REVIEW=1` here was therefore already gone by the time `post-impl-review`'s own executable fence resolved its cap, which made the whole `sequential` token a silent no-op: the user got the stderr notice and the default 6-wide fanout anyway. The cap must travel as a declared Skill input, which the skill resolves inside the same fence that uses it. The skill's Step 2 cap resolution prefers a caller-supplied `fanout_cap` over the `uberdev_read_int_in_range` config/env/default answer, so `1` yields `ceil(6/1) = 6` sequential one-child waves. The dispatch-before-wait invariant is preserved within each wave.

   ### Argument Parsing Summary

   | Variable | Source | Default | Effect |
   |---|---|---|---|
   | `SIMPLIFY_PHASE` | `--no-simplify` token | `1` | `0` skips Phase 2 |
   | `SEQUENTIAL` | `sequential` token | `0` | `1` binds `POST_IMPL_FANOUT_CAP=1`, forwarded to `Skill(uberdev:post-impl-review)` as the `fanout_cap` input (stderr notice emitted) |
   | `CI_FIX_PHASE` | `--no-ci-fix` token, recorded to `$RESEARCH_DIR_ABS/ci-fix-phase.txt` | `1` | `0` runs PROBE+MONITOR+CLASSIFY (audit-only) but skips ROUTE+POST-FIX+HALT — outcome forced to `green` if probe was green, otherwise `halted` (still gates trust signal). ROUTE reads the recorded value, not the variable; an unreadable record halts `ci_fix_phase_unreadable` rather than defaulting the mutating phase on. "Probe was green" is read the same way — off `ci-probe-verdict.txt`, written by 6c.1 — because `${PROBE_VERDICT:-unknown}` was bound in another shell and answered `unknown` on every probe-only run (#418); an unreadable verdict halts `ci_probe_verdict_unreadable` rather than reporting a halt for CI it never saw. |
   | `TURBO` | `--turbo` token OR `UBERDEV_TURBO=1` env (hybrid OR, #97) | `0` | `1` activates the Phase 3 halt-class carve-out (6c.6 HALT — no AskUserQuestion, exit 1, no trust signal). Phases 1+2 unchanged in either mode. |
   | `ASPECT_LIST` | remaining tokens | `()` | passed as `aspect_emphasis` input to `Skill(uberdev:post-impl-review)` Step 4 |
   | `DEFER_ISSUES_PHASE` | `--no-defer-issues` token | `1` | `0` skips Phase 2.5 (findings-to-issues sub-phase); the effective enable is AND-of-flag-and-config — `defer_issues_enabled=false` in `.claude/uberdev.local.md` short-circuits identically. |

2. **Available Review Aspects:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable reviews (default)

   Note: aspect filters are captured into `ASPECT_LIST` in Step 1 and passed to `Skill(uberdev:post-impl-review)` as the `aspect_emphasis` input (Step 4). The skill appends a `## Emphasis` section to every reviewer's brief, listing the requested aspects verbatim. The 6 agents always run; cap-controlled wave membership is independent of emphasis, so emphasis is advisory and never gates dispatch. `/uberdev:review-pr tests` produces a measurably different brief from `/uberdev:review-pr all` — the former includes `## Emphasis: tests`, the latter omits the section entirely.

3. **Identify Changed Files**
   - Run `git diff --name-only` to see modified files
   - Resolve the selected PR explicitly in the current repository; never rely
     on branch inference from a bare `gh pr view`.
   - Identify file types and what reviews apply

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   review_assert_selected_pr_head() {
     local repo_slug="${@:1:1}" pr_number="${@:2:1}" expected_head="${@:3:1}" worktree_root="${@:4:1}"
     local live_head local_head
     [ "$#" -ge 4 ] || return 2
     [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
     [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
     [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || return 2
     live_head="$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq .headRefOid 2>/dev/null)" || return 2
     local_head="$(git -C "$worktree_root" rev-parse HEAD 2>/dev/null)" || return 2
     [ "$live_head" = "$expected_head" ] && [ "$local_head" = "$expected_head" ]
   }

   review_publish_same_repo_pr_head() {
     [ "$#" -eq 7 ] || return 2
     local repo_slug="${@:1:1}" pr_number="${@:2:1}" expected_remote_head_sha="${@:3:1}" publish_sha="${@:4:1}"
     local worktree_root="${@:5:1}" contract_helper="${@:6:1}" evidence_dir="${@:7:1}"
     local live_identity live_head live_branch live_cross_repository live_head_repo extra
     local remote_identity remote_head remote_ref remote_extra observed_head residue_receipt
     [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
     [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
     [[ "$expected_remote_head_sha" =~ ^[0-9a-f]{40}$ && "$publish_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
     [[ "$worktree_root" = /* && "$contract_helper" = /* && "$evidence_dir" = /* ]] || return 2
     # The head-repository identity is `headRepositoryOwner.login` +
     # `headRepository.name`, NEVER `headRepository.nameWithOwner` (#429).
     # gh DECLARES that last field and never populates it -- gh 2.83.1:
     #
     #     gh pr view 422 --repo TheFJK/UberDev --json headRepository
     #     {"headRepository":{"id":"R_kgDOSOF5tw","name":"UberDev","nameWithOwner":""}}
     #
     # A gate keyed on the empty string can never pass, which turned "refuse
     # forks" into "refuse everything": every /review-pr run exited 2 here and
     # at the trust-trail anchor push below, so no PR could ever obtain a trail
     # and /merge gated all of them out. The owner/name composite is populated
     # for every PR, fork and same-repo alike. Same resolution as
     # `lib/review-push-target.sh`, which had this fix from the start and was
     # wired into ONE call site only -- keep the two in step.
     #
     # One field per LINE, not one tab-separated line. Tab is IFS whitespace, so
     # a tab-joined projection with an empty field COLLAPSES under `read`: the
     # fields shift left and a malformed identity parses as a well-formed
     # DIFFERENT one. Line-per-field cannot shift -- git refuses a ref name
     # containing a newline, so a stray newline can only make the projection
     # over-long, which the trailing read refuses.
     live_identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
       --json headRefOid,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
       --jq '.headRefOid, .headRefName, (.isCrossRepository | tostring),
             ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
       2>/dev/null)" || return 79
     {
       IFS= read -r live_head || return 79
       IFS= read -r live_branch || return 79
       IFS= read -r live_cross_repository || return 79
       IFS= read -r live_head_repo || return 79
       if IFS= read -r extra; then return 79; fi
     } <<<"$live_identity"
     [ "$live_head" = "$expected_remote_head_sha" ] || return 79
     # No `[ -z "$extra" ]` here, and its absence is not an oversight: with
     # line-per-field, over-length is refused INSIDE the read block above, which
     # returns 79 the moment a fifth line exists. A trailing emptiness test on
     # `extra` is therefore unreachable-false -- it can only ever be reached
     # when `extra` is already empty. The tab-joined form it replaced DID need
     # it, because there a fifth field arrived on the same single line and the
     # read could not refuse it.
     [ -n "$live_branch" ] && [ "$live_cross_repository" = false ] && [ "$live_head_repo" = "$repo_slug" ] || return 79
     git -C "$worktree_root" check-ref-format --branch "$live_branch" >/dev/null 2>&1 || return 79
     observed_head="$(git -C "$worktree_root" rev-parse HEAD)" || return 79
     [ "$observed_head" = "$publish_sha" ] || return 79
     # BRACES ARE LOAD-BEARING. These fences run under /bin/zsh, where an
     # unbraced `$publish_sha:refs/...` parses `:r` as the remove-extension
     # MODIFIER: the refspec silently becomes `<sha>efs/heads/<branch>` and the
     # push dies with "src refspec ... does not match any". Proven with
     # `zsh -c 'V=abc; print "$V:refs/x"'` -> `abcefs/x`.
     git -C "$worktree_root" push origin "${publish_sha}:refs/heads/${live_branch}" || return 79
     remote_identity="$(git -C "$worktree_root" ls-remote --exit-code --heads origin "refs/heads/$live_branch")" || return 79
     [[ "$remote_identity" != *$'\n'* ]] || return 79
     IFS=$'\t' read -r remote_head remote_ref remote_extra <<<"$remote_identity" || return 79
     [ "$remote_head" = "$publish_sha" ] && [ "$remote_ref" = "refs/heads/$live_branch" ] && [ -z "$remote_extra" ] || return 79
     # Post-push re-projection. Same owner/name composite and same
     # line-per-field read as the pre-push probe above (#429) -- the two must
     # never drift, since this one is what proves the ref we just wrote is still
     # the PR's head in the repository we think it is.
     live_identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
       --json headRefOid,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
       --jq '.headRefOid, .headRefName, (.isCrossRepository | tostring),
             ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
       2>/dev/null)" || return 79
     {
       IFS= read -r live_head || return 79
       IFS= read -r live_branch || return 79
       IFS= read -r live_cross_repository || return 79
       IFS= read -r live_head_repo || return 79
       if IFS= read -r extra; then return 79; fi
     } <<<"$live_identity"
     [ "$live_head" = "$publish_sha" ] || return 79
     # See the pre-push probe: `extra` is intentionally unassigned on success.
     [ "$remote_ref" = "refs/heads/$live_branch" ] && [ "$live_cross_repository" = false ] && [ "$live_head_repo" = "$repo_slug" ] || return 79
     observed_head="$(git -C "$worktree_root" rev-parse HEAD)" || return 79
     [ "$observed_head" = "$publish_sha" ] || return 79
     residue_receipt="$(python3 -I -B "$contract_helper" validate-residue --working-dir "$worktree_root" --evidence-dir "$evidence_dir")" || return 79
     [ "$residue_receipt" = '{"status":"clean"}' ] || return 79
   }
   REVIEW_REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
   REVIEW_PR_METADATA="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" \
     --json number,baseRefOid,baseRefName,headRefOid)"
   REVIEWED_HEAD_SHA="$(printf '%s' "$REVIEW_PR_METADATA" | jq -er '.headRefOid')"
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" \
     "$REVIEWED_HEAD_SHA" "$WORKTREE_ROOT" || {
       echo "error: selected PR head does not equal local HEAD; refusing review dispatch" >&2
       OUTCOME=halted
       exit 2
     }
   ```

   This assertion runs before the first Phase 1 dispatch. On every Phase 1
   re-entry, re-read the live `headRefOid` with the same explicit repository and
   PR number, require it to equal local HEAD, then replace
   `REVIEWED_HEAD_SHA`. A mismatch halts before reviewer/fixer dispatch, push,
   or trust emission.

4. **Phase 1 — Dispatch `Skill(uberdev:post-impl-review)`**

   The executable setup has already reserved this invocation's `RUN_ID` with
   one plain `mkdir` before any reviewer dispatch. An explicitly supplied
   `RUN_ID` is accepted only when that exact directory can be created; a
   collision exits 2. A standalone invocation mints one timestamp/HEAD prefix
   and retries a bounded number of cryptographic hex discriminators. In both
   cases the resulting ID is validated against
   `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` before path use.

   **Locked-marker write (issue #220, AC ❶):** Before invoking the post-impl-review skill, write a sibling `.uberdev/runs/<RUN_ID>/locked` zero-byte marker + `pr-context.json` so a concurrent `/uberdev:goal` Phase 2b knows this PR's `/review-pr` is in-flight (avoids re-dispatching ours while the leaf solver's own is still running):

   The marker write also ran in that same executable setup fence. Setup exports
   one opaque, identity-bound `REVIEW_RUN_RESERVATION_RECEIPT`; it does not
   install or replace an `EXIT` trap. The receipt survives the setup shell and
   is the only authority accepted by the self-contained final publication
   fence. Explicit setup failures abandon the reservation through that receipt.
   Normal or signal exits leave the markers for `/goal` to observe; even on
   SIGKILL the reader's grace-window check bounds staleness. Final publication
   removes only the two receipt-bound markers, and only after the exact verdict
   pathname has been published durably.

   **Reservation reaper (#344).** Retirement therefore has exactly two owners:
   the receipt-authorized final publication fence, and — for runs that never
   reach it — `review_reap_stale_run_reservations`, which every `/review-pr`
   invocation runs immediately before reserving its own directory. Without it no
   component owns an abandoned marker at all: all four
   `review_abandon_run_reservation` call sites live inside the setup fence, so a
   SIGKILL, harness timeout, crashed reviewer wave, or operator `^C` after setup
   strands `locked` + `pr-context.json` and stalls `/uberdev:goal` Phase 2b for a
   full `REVIEW_GRACE_SECS`. The reaper walks the runs root under the same
   identity-checked directory descriptor the reservation uses, and unlinks
   `locked` + `pr-context.json` from a run directory only when ALL of the
   following hold: the directory name matches the run-ID format, it holds no
   `review-pr-verdict.json`, it holds no unrecognized entry, its `locked` marker
   is a plain single-linked file owned by this user, and that marker's mtime is
   older than `REVIEW_RESERVATION_REAP_SECS` (default `7200` = 2 x the
   `REVIEW_GRACE_SECS` window `/goal` itself uses). It never removes a
   directory, never touches a verdict, and never installs an `EXIT` trap.

   It prints a `notice:` line for every directory it reaps, and for every
   directory that still looks like a live reservation but was left alone anyway
   — `locked` younger than the reap policy, `locked` not a plain single-linked
   owned file, unrecognized entries present, or an `OSError` on the unlink or
   fsync. Those are the lines an operator chasing a `/goal` stall needs, and a
   reaper that failed quietly would reproduce the very stall it exists to
   prevent. The two routine skips are deliberately silent: a directory holding a
   `review-pr-verdict.json`, and a directory with no `locked` marker, are the
   normal end state of every completed review, so announcing them would emit one
   line per historical run and bury the actionable ones.

   The locked marker is read by `/uberdev:goal` Phase 2b via `_uberdev_goal_locked_marker_for_pr_fresh "$pr_num" "$REVIEW_GRACE_SECS"` (lib/goal-state.sh). The contract is additive — `/review-pr` runs identically whether `/goal` is the caller or a human is. The marker remains truthful across shell boundaries until the receipt-authorized final fence publishes the verdict and retires it. If the producer exits before finalization, `/goal`'s grace-window check (REVIEW_GRACE_SECS, default 3600s) bounds staleness without an operator or an `EXIT`-trap race. See RFC 0005 §9 D220b for the cross-component design rationale.

   Compute Phase 1 inputs from the PR:
   - `changed_paths` — normalized, non-empty POSIX repository-relative paths from the same fixed local `git diff <merge-base>..<head> --name-only` snapshot used for the Phase 1 diff artifact and commit range. The GitHub server-side path list is not authoritative on entry or re-entry. Preserve deleted or otherwise missing entries as path strings; absolute paths, traversal, dot components, backslashes, control characters, and unsafe names are rejected by the `repo_path_array` handoff contract before provider launch.
   - `commit_range` — `<merge-base>..<reviewed-head-sha>`, where `<merge-base>` is the computed merge-base commit between the PR base ref and the captured reviewed head. Never substitute moving `HEAD` after this snapshot is captured.
   - `tier` — passed through from `$ARGUMENTS` if present (forwarded by `finish-branch`'s chain), else default `medium`.

   Recompute the review scope from one fixed local base-to-HEAD snapshot on
   every Phase 1 entry, including CI-fix re-entry. This keeps the path list,
   diff artifact, and commit range bound to the same post-fix HEAD:

   ```bash
   review_resolve_phase1_base() {
     [ "$#" -ge 3 ] || return 2
     python3 -I -B - "${@:1:1}" "${@:2:1}" "${@:3:1}" <<'PY'
import json,re,subprocess,sys
pr,root,repo=sys.argv[1:]
if re.fullmatch(r'[1-9][0-9]*',pr) is None: raise SystemExit(2)
metadata=json.loads(subprocess.check_output(
    ['gh','pr','view',pr,'--repo',repo,'--json','baseRefOid,baseRefName'],text=True))
base_oid=metadata.get('baseRefOid'); base_name=metadata.get('baseRefName')
if re.fullmatch(r'[0-9a-f]{40}',base_oid or '') is None or not isinstance(base_name,str) or not base_name:
    raise SystemExit(2)
try:
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    subprocess.run(['git','-C',root,'fetch','--no-tags','origin',base_name],check=True)
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
base=subprocess.check_output(['git','-C',root,'merge-base',head,base_oid],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
print(base,end='')
PY
   }
   review_refresh_phase1_scope() {
     local base="${@:1:1}"
     [ "$#" -ge 1 ] || return 2
     CHANGED_PATHS_JSON="$(python3 -I -B - "$WORKTREE_ROOT" "$base" "$DIFF_ARTIFACT_PATH" "$COMMIT_RANGE_PATH" <<'PY'
import json,os,re,stat,subprocess,sys,tempfile
root,base,diff_path,range_path=sys.argv[1:]
MAX_DIFF_LINES=2000
MAX_DIFF_BYTES=8*1024*1024
MAX_WRAPPED_DIFF_BYTES=16*1024*1024
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',head) is None: raise SystemExit(2)
subprocess.run(['git','-C',root,'merge-base','--is-ancestor',base,head],check=True)
raw_paths=subprocess.check_output(['git','-C',root,'diff','--name-only','-z',f'{base}..{head}'])
paths=[item.decode('utf-8','strict') for item in raw_paths.split(b'\0') if item]
if not paths: raise SystemExit(2)
for path in paths:
    parts=path.split('/')
    if (path.startswith('/') or '\\' in path or any(part in ('','.','..') for part in parts)
            or any(ord(char)<32 or ord(char)==127 for char in path)):
        raise SystemExit(2)
def escape_untrusted_diff_payload(payload):
    return payload.replace(b'&',b'&amp;').replace(b'<',b'&lt;')
def wrap_untrusted_diff(payload):
    escaped=escape_untrusted_diff_payload(payload)
    opening=b'<external-untrusted-input source="pr-diff">'
    closing=b'</external-untrusted-input>'
    wrapped=opening+b'\n'+escaped+closing+b'\n'
    if wrapped.count(opening)!=1 or wrapped.count(closing)!=1: raise ValueError()
    return wrapped
def build_diff_summary():
    summary=['[diff summarized: full binary diff exceeded the 2000-line, 8-MiB raw, or 16-MiB wrapped review artifact limit]']
    summary_bytes=len((summary[0]+'\n').encode())
    summary_wrapped_bytes=len(wrap_untrusted_diff((summary[0]+'\n').encode()))
    omission_reserve=128
    stats=subprocess.Popen(['git','-C',root,'diff','--numstat','--no-renames',f'{base}..{head}'],
                           stdout=subprocess.PIPE,text=True,encoding='utf-8',errors='strict')
    omitted=0
    for line in stats.stdout:
        fields=line.rstrip('\n').split('\t',2)
        if len(fields)!=3: raise SystemExit(2)
        added,deleted,path=fields
        detail='binary change' if added==deleted=='-' else f'{added} additions, {deleted} deletions'
        row=f'{path} — {detail}'
        encoded=(row+'\n').encode()
        escaped_size=len(escape_untrusted_diff_payload(encoded))
        if (summary_bytes+len(encoded)>MAX_DIFF_BYTES
                or summary_wrapped_bytes+escaped_size+omission_reserve>MAX_WRAPPED_DIFF_BYTES):
            omitted+=1
            continue
        summary.append(row)
        summary_bytes+=len(encoded)
        summary_wrapped_bytes+=escaped_size
    if stats.wait()!=0: raise SystemExit(2)
    if omitted: summary.append(f'[{omitted} additional file summaries omitted to preserve the artifact limit]')
    return ('\n'.join(summary)+'\n').encode()
def select_bounded_wrapped_diff(payload, summary_factory):
    wrapped=wrap_untrusted_diff(payload)
    if len(wrapped)<=MAX_WRAPPED_DIFF_BYTES: return wrapped
    wrapped=wrap_untrusted_diff(summary_factory())
    if len(wrapped)>MAX_WRAPPED_DIFF_BYTES: raise ValueError()
    return wrapped
process=subprocess.Popen(['git','-C',root,'diff','--binary','--no-ext-diff',f'{base}..{head}'],stdout=subprocess.PIPE)
diff_buffer=bytearray(); diff_lines=0; summarized=False
while True:
    chunk=process.stdout.read(65536)
    if not chunk: break
    diff_buffer.extend(chunk); diff_lines+=chunk.count(b'\n')
    if len(diff_buffer)>MAX_DIFF_BYTES or diff_lines>MAX_DIFF_LINES:
        summarized=True; process.kill(); break
process.stdout.close(); process.wait()
if not summarized and process.returncode!=0: raise SystemExit(2)
diff=build_diff_summary() if summarized else bytes(diff_buffer)
wrapped_diff=select_bounded_wrapped_diff(diff,(lambda: diff) if summarized else build_diff_summary)
def replace_private(path,payload):
    parent=os.path.dirname(path) or '.'
    fd,tmp=tempfile.mkstemp(prefix='.review-scope.',dir=parent)
    try:
        if os.name!='nt': os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp,path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
replace_private(diff_path,wrapped_diff)
expected_range=f'{base}..{head}\n'.encode()
replace_private(range_path,expected_range)
if open(range_path,'rb').read()!=expected_range: raise SystemExit(2)
print(json.dumps(paths,separators=(',',':')),end='')
PY
)" || return 2
   }
   BASE_SHA="$(review_resolve_phase1_base "$PR_NUMBER" "$WORKTREE_ROOT" "$REVIEW_REPO_SLUG")" || return 2
   BASE_REF_NAME="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" --json baseRefName --jq .baseRefName)" || return 2
   REENTRY_HEAD_SHA="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" --json headRefOid --jq .headRefOid)" || return 2
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$REENTRY_HEAD_SHA" "$WORKTREE_ROOT" || return 2
   REVIEWED_HEAD_SHA="$REENTRY_HEAD_SHA"
   VALIDATED_FIXER_HEAD_SHA="$REVIEWED_HEAD_SHA"
   review_refresh_phase1_scope "$BASE_SHA" || return 2
   # THE ONLY WRITER of the reviewed-base identity (#440). This fence is the one
   # place in the run where the pair is live: `review_resolve_phase1_base` just
   # computed the merge-base the whole review is scoped to, and `baseRefName`
   # names the branch that merge-base was taken against. Every consumer -- the
   # two Phase 2 scope refreshes, the trust-trail anchor's `Reviewed-base:`
   # trailer, the audit JSON's `base` member -- runs in a DIFFERENT harness
   # shell, 48 and 52 bash fences downstream, where `$BASE_SHA` is the empty
   # string. Same run-dir carrier idiom as ci-push-target.tsv / ci-fix-phase.txt,
   # through the typed lib pair so neither half can record or return a value the
   # other would refuse.
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-fleet-args.sh" || return 2
   REVIEW_BASE_RUN_DIR=
   if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
     REVIEW_BASE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || REVIEW_BASE_RUN_DIR=
   fi
   if [ -n "$REVIEW_BASE_RUN_DIR" ]; then
     # A run dir that IS bound and still cannot take the carrier halts HERE, not
     # at the anchor: the base has already been resolved and the whole review is
     # about to be scoped to it, so a silent non-write would produce a trust
     # signal nobody can attribute to a base.
     review_fleet_write_review_base "$REVIEW_BASE_RUN_DIR/review-base-identity.tsv" "$BASE_SHA" "$BASE_REF_NAME" || {
       echo "error: /uberdev:review-pr — resolved PR #$PR_NUMBER's review base ($BASE_SHA on $BASE_REF_NAME) but could not persist it to $REVIEW_BASE_RUN_DIR/review-base-identity.tsv; refusing to review a delta whose base no later fence can name." >&2
       audit review_base_uncarried data.reason=write_failed
       return 2
     }
   else
     # No run dir bound => this fence is running OUTSIDE a real review run. The
     # pair is still bound for a same-shell caller and the miss is TYPED rather
     # than silent; every downstream reader then halts `review_base_unreadable`
     # because the carrier is absent, so the failure is closed either way.
     audit review_base_uncarried data.reason=no_run_dir
   fi
   ```

   Invoke the post-impl-review skill through the context-only run-tree edge
   `review_pr.post_impl_review` (skill handoff, never a provider dispatch):

   > Invoke `uberdev:post-impl-review` via the `Skill` tool with `changed_paths`, `commit_range`, `tier`, `RUN_ID`, `aspect_emphasis=$ASPECT_LIST`, and — only when `SEQUENTIAL=1` — `fanout_cap=$POST_IMPL_FANOUT_CAP` (so the skill writes to the same `RUN_ID`-keyed directory `/review-pr` will read, the brief includes the emphasis section when aspects were requested, and the sequential override reaches the cap resolution that actually uses it).

   The skill runs its 7 reviewer agents in one or more cap-controlled waves, with every child in each wave dispatched before its first wait — see `plugins/uberdev/skills/post-impl-review/SKILL.md` for the canonical agent list, cap, and YAML return contract. The skill is the single source of truth for which agents fan out; this prose deliberately does not enumerate them.

   **Sequential mode** (only when explicitly requested via the `sequential` argument): if `SEQUENTIAL=1` was set in Step 1, the user-visible stderr notice has already been emitted (`notice: running post-impl-review sequentially via fanout_cap=1`) and `POST_IMPL_FANOUT_CAP=1` is bound. Pass it through as the `fanout_cap` Skill input above; the skill's Step 2 cap resolution honours it over config/env/default and splits the 7-agent fanout into `ceil(7/1) = 7` sequential one-child waves. The warning surface is the user's terminal — never `/dev/null`, never an internal log file — so the override is visible. Omit the input entirely when `SEQUENTIAL=0`; there is nothing to unset afterwards, because the override never becomes ambient shell state. An `export` here would be dead on arrival: this command's `bash` blocks are separate shells, so the skill's own executable fence never sees a variable exported from `/review-pr`'s Step 1.

   **4w. Phase 1 on the Workflow-native transport** (run this INSTEAD of the
   `Skill(uberdev:post-impl-review)` invocation above, and only when
   `UBERDEV_CARRIER_BACKEND=workflow`)

   `lib/dispatch.sh` has no `workflow` provider arm by construction, so on that
   backend the seven reviewers are dispatched by the session's Workflow tool
   through `skills/review-fleet/workflow.js` instead of by the routed child
   adapter. Everything else is unchanged: the same seven edges, the same enveloped
   diff artifact read BY PATH, the same `uberdev_child_validate_phase1_review_result`
   boundary, the same trusted ledger, and the same
   `post_review_write_aggregate_v2` writer. **Do not also invoke
   `Skill(uberdev:post-impl-review)` on this path** — that would dispatch the
   same roster twice and produce two ledgers for one wave.

   Run 4w.1, then the mandated `Workflow` call, then 4w.2. The three are one
   proof: 4w.1 mints a binding per child BEFORE anything is dispatched, and 4w.2
   is the only thing that decides whether the wave produced evidence.

   **4w.1 — existence guard, per-child layout, nonce mint, bindings, envelope.**

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # RFC 0012 §4.1: validate the on-disk Workflow script BEFORE mandating the
   # call. A missing or misnamed workflow.js on a target install must refuse
   # here, not at the runtime layer after the RUN_ID is already reserved.
   REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
   [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
   # The script derives every child path from runDirAbs and every capture verb
   # canonicalises the same paths afterwards, so both sides must start from the
   # realpath rather than from a symlinked or relative spelling of it.
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
   mkdir -p "$REVIEW_FLEET_RUN_DIR/children" "$REVIEW_FLEET_RUN_DIR/post-review" || return 2
   # The convention lens's rule-source ALLOWLIST (#433), discovered ONCE here and
   # persisted next to the run. The children receive the PATH, never the bytes;
   # 4w.2 re-reads THIS file rather than re-deriving the list, because two
   # derivations can disagree and the gate has to judge citations against the
   # same allowlist the reviewer was handed. The resolved root and the
   # changed-path set travel the same way, and for the same reason: 4w.2 is a
   # fresh shell.
   REVIEW_RULE_SOURCES="$REVIEW_FLEET_RUN_DIR/post-review/rule-sources.txt"
   printf '%s\n' "$REVIEW_FLEET_WORKTREE" >"$REVIEW_FLEET_RUN_DIR/post-review/rule-root.txt" || return 2
   uberdev_review_rule_sources "$REVIEW_FLEET_WORKTREE" >"$REVIEW_RULE_SOURCES" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   REVIEW_FLEET_LAUNCHED="$REVIEW_FLEET_RUN_DIR/review-fleet-review.launched"
   REVIEW_FLEET_CAP="$(uberdev_read_int_in_range fanout_concurrency.post_impl_review UBERDEV_FANOUT_POST_IMPL_REVIEW 1 50 7)" || return 2
   [ "${SEQUENTIAL:-0}" != 1 ] || REVIEW_FLEET_CAP=1
   # Resolved HERE so an invalid value warns once, at the top of the run, rather
   # than mid-Phase-1. Step 6b.0 re-derives it from the same call because every
   # bash block in this command is a FRESH shell (#427) -- this binding does not
   # survive to the fence that actually applies it.
   REVIEW_CONFIDENCE_THRESHOLD="$(uberdev_read_int_in_range review.confidence_threshold UBERDEV_REVIEW_THRESHOLD 0 100 80)" || return 2
   REVIEW_FLEET_ASPECTS="$(printf '%s' "${ASPECT_LIST[*]:-}" | tr ' ' ',')"
   # mkdir -p per child, one CSPRNG nonce per child in the roster order the
   # script consumes, one bind-workflow-launch per child — all BEFORE dispatch,
   # the only moment a binding can be minted that the child could not influence.
   review_fleet_bind_roster review "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
     "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" "$REVIEW_FLEET_LAUNCHED" || return 2
   # The Workflow composer is a courier with no filesystem, so the output
   # contract the policy manifest binds to every review_pr.review.* edge travels
   # BY PATH -- the diffPathAbs way. Resolved HERE from
   # policy/solve-run-tree-v1.json so the Workflow path and the routed path read
   # ONE declaration instead of the routed path reading it and this one
   # re-declaring it as prose (#403).
   REVIEW_FLEET_CONTRACT_PATH="$(review_fleet_contract_path "$UBERDEV_REVIEW_PLUGIN_ROOT" phase1-reviewer-v1)" || return 2
   uberdev_emit_workflow_args review-fleet \
     mode=review-pr \
     stage=review \
     run_id="$RUN_ID" \
     runId="$RUN_ID" \
     runDirAbs="$REVIEW_FLEET_RUN_DIR" \
     pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
     repoRootAbs="$REVIEW_FLEET_WORKTREE" \
     workingDirAbs="$REVIEW_FLEET_WORKTREE" \
     prNumber="$PR_NUMBER" \
     repoSlug="$REVIEW_REPO_SLUG" \
     reviewIteration="$REVIEW_ITERATION" \
     diffPathAbs="$DIFF_ARTIFACT_PATH" \
     phase1ContractPathAbs="$REVIEW_FLEET_CONTRACT_PATH" \
     aspects="$REVIEW_FLEET_ASPECTS" \
     fanoutCap="$REVIEW_FLEET_CAP" \
     maxAgents=40 \
     workspaceMode=caller \
     worktreeAbs="$REVIEW_FLEET_WORKTREE" \
     branchName= \
     ruleSourcesPathAbs="$REVIEW_RULE_SOURCES" \
     runNonces="$REVIEW_FLEET_NONCE_POOL" || return 2
   ```

   `branchName` is emitted EMPTY on purpose. `bind-workflow-launch` records
   `branch: ""`, and `_validate_bound_workflow_child_status` requires the
   child's `status.json` branch to equal the binding's — a non-empty value here
   would make every child's status refuse.

   **Workflow mandate:** the fence above validated
   `[ -f "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js" ]`. Relay the JSON
   between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2 — no
   LLM-composed handoffs) into:

   ```
   Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
   ```

   **4w.2 — the capture verbs, in the calling session's Bash.** The script's
   return is a report, not evidence: this fence re-derives every path itself and
   judges the artifacts on disk. A child the script reported `BLOCKED` simply has
   no valid artifacts, and the evidence builder fails closed on it.

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # child-dispatch.sh for uberdev_child_validate_phase1_review_result, and for
   # the backend-policy enum the evidence builder reads; review-aggregate.sh for
   # the three builders themselves. Both are sourced HERE because this fence is
   # a fresh shell and neither survives from the setup fence.
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-aggregate.sh" || return 2
   REVIEW_EDGES=(
     review_pr.review.correctness review_pr.review.silent_failures
     review_pr.review.types review_pr.review.comments
     review_pr.review.tests review_pr.review.general
     review_pr.review.convention
   )
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_LAUNCHED="$REVIEW_FLEET_RUN_DIR/review-fleet-review.launched"
   REVIEW_EXPECTED_COUNT="${#REVIEW_EDGES[@]}"
   # The changed-path set the citation gate keys its self-introduced-rule
   # demotion on, persisted HERE rather than in 4w.1: this is the fence that
   # already owns CHANGED_PATHS_JSON, and the writer below is a fresh shell away
   # from wherever it was computed.
   printf '%s' "$CHANGED_PATHS_JSON" >"$REVIEW_FLEET_RUN_DIR/post-review/changed-paths.json" || return 2
   POST_REVIEW_VALIDATED_LEDGER="$REVIEW_FLEET_RUN_DIR/review-fleet-review.validated"
   : >"$POST_REVIEW_VALIDATED_LEDGER" || return 2
   REVIEW_WAVE_BLOCKED=0
   while IFS= read -r REVIEW_FLEET_ROW; do
     [ -n "$REVIEW_FLEET_ROW" ] || continue
     REVIEW_FLEET_EDGE="$(jq -er .edge <<<"$REVIEW_FLEET_ROW")" || { REVIEW_WAVE_BLOCKED=1; break; }
     REVIEW_FLEET_INDEX="$(jq -er .index <<<"$REVIEW_FLEET_ROW")" || { REVIEW_WAVE_BLOCKED=1; break; }
     REVIEW_FLEET_INSTANCE="$(jq -er .instance <<<"$REVIEW_FLEET_ROW")" || { REVIEW_WAVE_BLOCKED=1; break; }
     REVIEW_FLEET_RESULT="$(jq -er .result <<<"$REVIEW_FLEET_ROW")" || { REVIEW_WAVE_BLOCKED=1; break; }
     REVIEW_FLEET_VALIDATED="$(dirname "$REVIEW_FLEET_RESULT")/validated-result.md"
     # No child of ANY backend writes validated-result.md. The controller does,
     # through the canonical boundary that also rejects an APPROVE carrying a
     # blocker, and it publishes the artifact 0o400.
     if REVIEW_FLEET_DIGEST="$(uberdev_child_validate_phase1_review_result "$REVIEW_FLEET_RESULT" "$CHANGED_PATHS_JSON" "$REVIEW_FLEET_VALIDATED")" \
        && [[ "$REVIEW_FLEET_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
       jq -cn --arg edge "$REVIEW_FLEET_EDGE" --argjson index "$REVIEW_FLEET_INDEX" \
         --arg instance "$REVIEW_FLEET_INSTANCE" --arg result "$REVIEW_FLEET_VALIDATED" \
         --arg sha256 "$REVIEW_FLEET_DIGEST" \
         '{edge:$edge,index:$index,instance:$instance,result:$result,sha256:$sha256}' \
         >>"$POST_REVIEW_VALIDATED_LEDGER" || REVIEW_WAVE_BLOCKED=1
     else
       REVIEW_WAVE_BLOCKED=1
     fi
   done <"$REVIEW_FLEET_LAUNCHED"
   if [ "$REVIEW_WAVE_BLOCKED" -eq 0 ] \
       && POST_REVIEW_TRUSTED_LEDGER="$(post_review_validated_evidence_complete \
            "$POST_REVIEW_VALIDATED_LEDGER" "$REVIEW_EXPECTED_COUNT" \
            "$REVIEW_FLEET_LAUNCHED" '' "$REVIEW_FLEET_RUN_DIR")" \
       && POST_REVIEW_AGGREGATION_INPUT="$(post_review_capture_aggregation_inputs \
            "$POST_REVIEW_TRUSTED_LEDGER" "$REVIEW_EXPECTED_COUNT")" \
       && post_review_write_aggregate_v2 "$POST_REVIEW_AGGREGATION_INPUT" "$AGG_PATH" \
            "$REVIEW_FLEET_RUN_DIR/post-review/rule-sources.txt" \
            "$(cat "$REVIEW_FLEET_RUN_DIR/post-review/rule-root.txt")" \
            "$REVIEW_FLEET_RUN_DIR/post-review/changed-paths.json" \
            "$REVIEW_FLEET_RUN_DIR/post-review/convention-citations.md"; then
     POST_REVIEW_AGGREGATION_INPUT=
     unset POST_REVIEW_AGGREGATION_INPUT
   else
     # Identical fail-closed boundary to the skill's: a missing or empty
     # aggregate is infrastructure failure, never a zero-finding review. Any
     # BLOCKED reviewer lands here, and nothing downstream runs.
     rm -f -- "$AGG_PATH"
     echo "error: review-fleet Phase 1 evidence incomplete; aggregate suppressed" >&2
     return 70
   fi
   ```

   The binding rows in `review-fleet-review.launched` are the
   `{edge,index,instance,binding,result,status}` shape
   `post_review_validated_evidence_complete` proves through
   `code_fixer_contract.py capture-bound-child` — a verb that takes no
   caller-supplied digest and computes both itself. One wave may not mix that
   shape with the detached `receipt` shape, so a workflow wave and a detached
   wave can never be aggregated together.

5. **Apply Phase 1 Fixes — dispatch `code-fixer` subagent**

   Read the findings aggregate from the canonical path:
   ```
   .uberdev/research/<RUN_ID>/post-impl-review-final.md
   ```
   **The artifact already carries the `<external-untrusted-input source="post-impl-review-aggregate">…</external-untrusted-input>` envelope as its own LEADING/TRAILING file bytes** (written by `uberdev:post-impl-review` Step 4 — #302 / RFC 0012 §3.1 do-first). Pass the artifact PATH (`findings_path`) or its already-enveloped bytes VERBATIM into the apply-loop prompt — **do NOT re-wrap** (a read-time second wrap nests envelopes while leaving the on-disk file bare, which is exactly what made `findings-to-issues.md` Step 1's first-128-bytes validation refuse every Phase 2.5 dispatch `input-malformed`). The file-bytes envelope is the single envelope of record, per the orchestrator trust-boundary convention (`plugins/uberdev/skills/orchestrator/SKILL.md` "Trust boundary" section). Threat model unchanged: second-order injection where issue-author text → diff hunk → reviewer agent's report → aggregate findings file → fixer prompt. The envelope is required, not advisory — it is simply written once, by the writer.

   Dispatch a fresh routed `code-fixer` child (`subagent_type: uberdev:code-fixer`) to apply the findings. The edge and manifest phase are the only phase/type authority; the payload carries only immutable artifact authority:

   ```bash
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
   PHASE1_FINDINGS_PATH="$RESEARCH_DIR_ABS/post-impl-review-final.md"
   PHASE1_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE1_FINDINGS_PATH" --minimum 1 --maximum 16777216)" || return 74
   FIXER_COMMIT_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$COMMIT_RANGE_PATH" --minimum 1 --maximum 256)" || return 74
   PHASE1_AUTHORITY_PATH="$RESEARCH_DIR_ABS/code-fixer-authority-phase1-iter${REVIEW_ITERATION}.json"
   PHASE1_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
     --edge-id review_pr.fix.phase1 --policy-phase review_fix \
     --findings-path "$PHASE1_FINDINGS_PATH" --findings-sha256 "$PHASE1_FINDINGS_SHA256" \
     --commit-range-path "$COMMIT_RANGE_PATH" --commit-range-sha256 "$FIXER_COMMIT_RANGE_SHA256" \
     --working-dir "$WORKTREE_ROOT" --disposition-path "$PHASE1_DISPOSITION_PATH" \
     --authority-output-path "$PHASE1_AUTHORITY_PATH")" || return 74
   PHASE1_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1]); expected={"authority_path","authority_sha256","phase","commit_type","target_paths"}
if set(value)!=expected or value["authority_path"]!=sys.argv[2] or value["phase"]!="phase1" or value["commit_type"]!="fix" or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None: raise SystemExit(74)
print(value["authority_sha256"],end="")' "$PHASE1_AUTHORITY_RECEIPT" "$PHASE1_AUTHORITY_PATH")" || return 74
   PHASE1_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase1-iter${REVIEW_ITERATION}.json"
   PHASE1_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase1 \
     findings_path "$(review_json_string "$PHASE1_FINDINGS_PATH")" \
     findings_sha256 "$(review_json_string "$PHASE1_FINDINGS_SHA256")" \
     commit_range_path "$(review_json_string "$COMMIT_RANGE_PATH")" \
     commit_range_sha256 "$(review_json_string "$FIXER_COMMIT_RANGE_SHA256")" \
     working_dir "$(review_json_string "$WORKTREE_ROOT")" \
     pr_number "$PR_NUMBER" \
     disposition_path "$(review_json_string "$PHASE1_DISPOSITION_PATH")" \
     authority_path "$(review_json_string "$PHASE1_AUTHORITY_PATH")" \
     authority_sha256 "$(review_json_string "$PHASE1_AUTHORITY_SHA256")")"
   FIXER_HEAD_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
   REVIEW_FIXER_TERMINAL=
   # builder dispatch: uberdev_dispatch_child review_pr.fix.phase1
   if review_fixer_child_bound review_pr.fix.phase1 "$(uberdev_child_instance_id "review-pr-${RUN_ID}-fix-phase1-iter${REVIEW_ITERATION}-attempt01")" "$PHASE1_INPUTS" null "$RESEARCH_DIR_ABS/phase1-fixer" "$REVIEW_PR_TIMEOUT" "$PHASE1_AUTHORITY_PATH" "$PHASE1_AUTHORITY_SHA256" "$PHASE1_DISPOSITION_PATH" "$PHASE1_APPLIED_CONTENT_PATH"; then :; else
     REVIEW_FIXER_RC=$?
     review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"
     return $?
   fi
   FIXER_HEAD_AFTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   [ -n "${REVIEW_FIXER_TERMINAL:-}" ] || {
     review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" 74; return $?
   }
   FIXER_STATUS_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_RESULT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_DISPOSITION_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_APPLIED_CONTENT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   PHASE1_FIXER_OUTCOME="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-review-outcome \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --authority-path "$PHASE1_AUTHORITY_PATH" --authority-sha256 "$PHASE1_AUTHORITY_SHA256" \
     --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$FIXER_DISPOSITION_SHA256" \
     --applied-content-path "$PHASE1_APPLIED_CONTENT_PATH" --applied-content-sha256 "$FIXER_APPLIED_CONTENT_SHA256" \
     --status-sha256 "$FIXER_STATUS_SHA256" --result-sha256 "$FIXER_RESULT_SHA256" \
     --working-dir "$WORKTREE_ROOT" --head-before "$FIXER_HEAD_BEFORE" --head-after "$FIXER_HEAD_AFTER")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   ```

   **5w. The Phase 1 fixer on the Workflow-native transport** (run this INSTEAD
   of the `review_fixer_child_bound` dispatch above, and only when
   `UBERDEV_CARRIER_BACKEND=workflow`)

   The authority is prepared exactly as above — the transport changes, the proof
   does not. The fixer child is bound with `bind-workflow-fixer-launch`, never
   with `bind-workflow-launch`: only the fixer producer pins the
   controller-created authority by path and digest, and a fixer owes a
   disposition and an applied-content artifact that a reviewer does not.

   **5w.1 — authority, binding, envelope.**

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
   [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
   mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   PHASE1_FINDINGS_PATH="$RESEARCH_DIR_ABS/post-impl-review-final.md"
   PHASE1_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE1_FINDINGS_PATH" --minimum 1 --maximum 16777216)" || return 74
   FIXER_COMMIT_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$COMMIT_RANGE_PATH" --minimum 1 --maximum 256)" || return 74
   PHASE1_AUTHORITY_PATH="$RESEARCH_DIR_ABS/code-fixer-authority-phase1-iter${REVIEW_ITERATION}.json"
   PHASE1_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
     --edge-id review_pr.fix.phase1 --policy-phase review_fix \
     --findings-path "$PHASE1_FINDINGS_PATH" --findings-sha256 "$PHASE1_FINDINGS_SHA256" \
     --commit-range-path "$COMMIT_RANGE_PATH" --commit-range-sha256 "$FIXER_COMMIT_RANGE_SHA256" \
     --working-dir "$WORKTREE_ROOT" --disposition-path "$PHASE1_DISPOSITION_PATH" \
     --authority-output-path "$PHASE1_AUTHORITY_PATH")" || return 74
   PHASE1_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1]); expected={"authority_path","authority_sha256","phase","commit_type","target_paths"}
if set(value)!=expected or value["authority_path"]!=sys.argv[2] or value["phase"]!="phase1" or value["commit_type"]!="fix" or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None: raise SystemExit(74)
print(value["authority_sha256"],end="")' "$PHASE1_AUTHORITY_RECEIPT" "$PHASE1_AUTHORITY_PATH")" || return 74
   PHASE1_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase1-iter${REVIEW_ITERATION}.json"
   REVIEW_FLEET_FIX_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-fix-phase1-iter${REVIEW_ITERATION}.launch.json"
   FIXER_HEAD_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
   review_fleet_bind_fixer review_pr.fix.phase1 "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
     "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
     "$PHASE1_AUTHORITY_PATH" "$PHASE1_AUTHORITY_SHA256" \
     "$FIXER_HEAD_BEFORE" "$REVIEW_FLEET_FIX_SIDECAR" || return 74
   uberdev_emit_workflow_args review-fleet \
     mode=review-pr \
     stage=fix \
     run_id="$RUN_ID" \
     runId="$RUN_ID" \
     runDirAbs="$REVIEW_FLEET_RUN_DIR" \
     pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
     repoRootAbs="$REVIEW_FLEET_WORKTREE" \
     workingDirAbs="$REVIEW_FLEET_WORKTREE" \
     prNumber="$PR_NUMBER" \
     repoSlug="$REVIEW_REPO_SLUG" \
     reviewIteration="$REVIEW_ITERATION" \
     fixerEdgeId=review_pr.fix.phase1 \
     commitType=fix \
     findingsPathAbs="$PHASE1_FINDINGS_PATH" \
     findingsSha256="$PHASE1_FINDINGS_SHA256" \
     commitRangePathAbs="$COMMIT_RANGE_PATH" \
     commitRangeSha256="$FIXER_COMMIT_RANGE_SHA256" \
     authorityPathAbs="$PHASE1_AUTHORITY_PATH" \
     authoritySha256="$PHASE1_AUTHORITY_SHA256" \
     dispositionPathAbs="$PHASE1_DISPOSITION_PATH" \
     appliedContentPathAbs="$PHASE1_APPLIED_CONTENT_PATH" \
     maxAgents=40 \
     workspaceMode=caller \
     worktreeAbs="$REVIEW_FLEET_WORKTREE" \
     branchName= \
     runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
   ```

   **Workflow mandate:** relay the JSON between
   `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

   ```
   Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
   ```

   **5w.2 — capture the terminal, validate the outcome, promote the head.** The
   script's `fixerStatus` is a hint for logging only; the disposition artifact
   and the head movement are the truth.

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   REVIEW_FLEET_FIX_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-fix-phase1-iter${REVIEW_ITERATION}.launch.json"
   REVIEW_FIXER_LAUNCH_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_FIX_SIDECAR" binding)" || return 74
   FIXER_HEAD_BEFORE="$(review_fleet_read_sidecar "$REVIEW_FLEET_FIX_SIDECAR" head_before)" || return 74
   # Read the authority pins OUT OF THE BINDING rather than recomputing them:
   # validate-review-outcome re-reads the authority file and requires it to
   # match this digest, so a file swapped after the mint fails closed.
   PHASE1_AUTHORITY_PATH="$(printf '%s' "$REVIEW_FIXER_LAUNCH_BINDING" | jq -er .authority_path)" || return 74
   PHASE1_AUTHORITY_SHA256="$(printf '%s' "$REVIEW_FIXER_LAUNCH_BINDING" | jq -er .authority_sha256)" || return 74
   PHASE1_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase1-iter${REVIEW_ITERATION}.json"
   REVIEW_FIXER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-review-terminal \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --disposition-path "$PHASE1_DISPOSITION_PATH" \
     --applied-content-path "$PHASE1_APPLIED_CONTENT_PATH")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_HEAD_AFTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_STATUS_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_RESULT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_DISPOSITION_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_APPLIED_CONTENT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   PHASE1_FIXER_OUTCOME="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-review-outcome \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --authority-path "$PHASE1_AUTHORITY_PATH" --authority-sha256 "$PHASE1_AUTHORITY_SHA256" \
     --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$FIXER_DISPOSITION_SHA256" \
     --applied-content-path "$PHASE1_APPLIED_CONTENT_PATH" --applied-content-sha256 "$FIXER_APPLIED_CONTENT_SHA256" \
     --status-sha256 "$FIXER_STATUS_SHA256" --result-sha256 "$FIXER_RESULT_SHA256" \
     --working-dir "$WORKTREE_ROOT" --head-before "$FIXER_HEAD_BEFORE" --head-after "$FIXER_HEAD_AFTER")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   review_promote_validated_fixer_outcome "$PHASE1_FIXER_OUTCOME" "$FIXER_HEAD_BEFORE" "$FIXER_HEAD_AFTER" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   ```

   A workflow outcome carries `run_nonce` where a detached outcome carries
   `receipt_sha256` — deliberately different keys, so a consumer written to check
   a dispatch receipt fails closed instead of accepting a nonce as though a
   receipt had been verified. `review_promote_validated_fixer_outcome` accepts
   exactly one of the two and nothing else.

   The agent applies edits and creates exactly one routed `fix:` conventional commit when any Phase 1 finding is APPLIED, returning that SHA in its YAML. This **review-phase commit** stays distinct from the Phase 2 simplify commit (separate-commit invariant — see `tests/review-pr.test.sh` for the assertion that locks this boundary). Capture the agent's `commits[].sha` for the final aggregation table's "Auto-applied" column. Surface every `findings_disposition` row where `disposition != APPLIED` in the aggregation table's "Advisory findings" column so they are never silently dropped.

   Capture `FIXER_HEAD_BEFORE` immediately before dispatch,
   `FIXER_HEAD_AFTER` immediately after return, and the final declared
   `commits[].sha` as `FIXER_DECLARED_TIP`. The controller applies:

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   review_track_validated_fixer_head() {
     local child_status="${@:1:1}" before="${@:2:1}" after="${@:3:1}" declared_tip="${@:4:1}" commit_count residue_receipt
     [ "$#" -ge 3 ] || return 2
     residue_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-residue --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS")" || { echo "error: MUTATED_BLOCKED — fixer returned residual repository state" >&2; return 79; }
     [ "$residue_receipt" = '{"status":"clean"}' ] || { echo "error: MUTATED_BLOCKED — fixer residue receipt is malformed" >&2; return 79; }
     [[ "$before" =~ ^[0-9a-f]{40}$ && "$after" =~ ^[0-9a-f]{40}$ ]] || return 2
     [ "$before" = "${VALIDATED_FIXER_HEAD_SHA:-}" ] || return 76
     case "$child_status" in
       APPLIED)
         [ "$before" != "$after" ] || return 77
         [ "$declared_tip" = "$after" ] || return 77
         git -C "$WORKTREE_ROOT" merge-base --is-ancestor "$before" "$after" || return 78
         commit_count="$(git -C "$WORKTREE_ROOT" rev-list --count "$before..$after")" || return 78
         [ "$commit_count" = 1 ] || return 77
         VALIDATED_FIXER_HEAD_SHA="$after"
         ;;
       NO_FIXES_NEEDED|REFUSED)
         [ -z "$declared_tip" ] && [ "$before" = "$after" ] || return 75
         ;;
       *) return 2 ;;
     esac
   }
   review_promote_validated_fixer_outcome() {
     [ "$#" -eq 3 ] || return 2
     local outcome="${@:1:1}" before="${@:2:1}" after="${@:3:1}" parsed child_status declared_tip extra
     parsed="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
base={"status","declared_tip","status_sha256","result_sha256","disposition_sha256","applied_content_sha256","commit"}
if not isinstance(value,dict): raise SystemExit(74)
# EXACTLY ONE launch-identity key, chosen by the backend, never by the child:
# a detached outcome is tied to its dispatch receipt, a workflow outcome to the
# nonce the controller minted before the call (code_fixer_contract.py
# _launch_identity). Accepting both is not a relaxation -- the set equality is
# still exact for each shape, both keys are still required 64-hex below, and a
# document carrying BOTH, NEITHER, or any extra key is still refused.
launch=set(value)-base
if launch not in ({"receipt_sha256"},{"run_nonce"}) or set(value)-launch!=base: raise SystemExit(74)
status=value["status"]; tip=value["declared_tip"]
if status not in {"APPLIED","NO_FIXES_NEEDED","REFUSED"} or not isinstance(tip,str): raise SystemExit(74)
if any(not isinstance(value[key],str) or re.fullmatch(r"[0-9a-f]{64}",value[key]) is None for key in (*launch,"status_sha256","result_sha256","disposition_sha256","applied_content_sha256")): raise SystemExit(74)
if (status=="APPLIED") != (re.fullmatch(r"[0-9a-f]{40}",tip) is not None) or (status=="APPLIED") != isinstance(value["commit"],dict): raise SystemExit(74)
print(status+"\t"+tip,end="")' "$outcome")" || return 74
     IFS=$'\t' read -r child_status declared_tip extra <<<"$parsed"
     [ -z "${extra:-}" ] || return 74
     review_track_validated_fixer_head "$child_status" "$before" "$after" "$declared_tip"
   }
   ```

   Promote the exact authenticated Phase 1 outcome immediately:

   ```bash
   review_promote_validated_fixer_outcome "$PHASE1_FIXER_OUTCOME" "$FIXER_HEAD_BEFORE" "$FIXER_HEAD_AFTER" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   ```

   Initialize `VALIDATED_FIXER_HEAD_SHA="$REVIEWED_HEAD_SHA"` on every Phase 1
   entry, including mandatory CI-fix re-entry. Call
   `review_track_validated_fixer_head` after each Phase 1 and Phase 2 fixer
   return. Run the residue check even when result parsing fails; malformed
   result plus residual state is still `MUTATED_BLOCKED`, never an ordinary
   parser refusal. Any status/head/declaration/ancestry/residue mismatch is
   `MUTATED_BLOCKED`: stop before publication and re-enter Phase 1 only after
   the unexpected history is resolved. A CI fixer never advances this variable
   directly; its successful push must take the mandatory Phase 1 re-entry path,
   which rebinds both head variables from the live/local equality gate.

   A returned `REFUSED` is publishable only when HEAD is unchanged. If the
   defensive gate observes mutation, normalize the state to
   `MUTATED_BLOCKED`, retain the exact post-return SHA, halt ordinary refusal
   publication, and re-enter Phase 1 against that SHA. Never emit trust or a
   terminal refusal for unreviewed mutated history.

   **Fail-closed boundary:** if the artifact file is missing or empty (e.g., a reviewer remained `BLOCKED`, supervision failed, or the skill crashed), record a supervisory failure and terminate `/review-pr` immediately. Do NOT dispatch the fixer, enter Phase 2, defer findings, or emit trust. The ordinary aggregate is produced only after all seven reviewer slots have valid evidence; a missing aggregate is therefore infrastructure failure, never a zero-finding review result.

   If `code-fixer` returns `status: REFUSED` and the mutation gate confirms
   HEAD is unchanged, log the rationale and continue to Phase 2 with zero
   auto-applied Phase 1 fixes. The aggregation table notes "Phase 1 fixer
   refused: <reason>" in the Advisory findings column.

   **Green-run predicate (Phase 1 contribution):** Phase 1 contributes to a green run iff after auto-apply convergence the verdict is `APPROVE`. `REVISIONS_REQUIRED` and `REJECT` end Phase 1 with no trust-signal emission and `/review-pr` exits with code 1 (see step 8 exit-code contract). The full green predicate combines this with Phase 2's status (defined in step 6) — only `(Phase 1 == APPROVE) AND (Phase 2 status ∈ {ran/APPROVE, skipped})` triggers trust-signal emission.

6. **Phase 2 — Mandatory Simplify Pass** (skip iff `SIMPLIFY_PHASE=0`)

   After Phase 1 fixes land, dispatch the three simplify lenses (**Code Reuse Review**, **Code Quality Review**, **Code Efficiency Review**) through the routed adapter — issue all three dispatches before the first wait. The stable edges are `review_pr.simplify.reuse`, `review_pr.simplify.quality`, and `review_pr.simplify.efficiency`; all map to `code-simplifier` and differ only by the trusted `lens` scalar in their context-only handoffs.

   Pass only the diff artifact path in each handoff. The artifact itself owns
   the `pr-diff` envelope; never copy or re-wrap its bytes in a child prompt.

   **The post-Phase-1 diff is attacker-controllable** and MUST be persisted at `DIFF_ARTIFACT_PATH` with literal leading `<external-untrusted-input source="pr-diff">` and trailing `</external-untrusted-input>` bytes. Concrete dispatch uses three immutable instances and issues the whole wave before waiting:

   ```bash
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
   # Phase 1 may have advanced HEAD. Rebuild both the enveloped diff and the
   # commit-range artifact from that exact post-fix snapshot before any Phase 2
   # lens or fixer receives authority.
   #
   # BASE_SHA comes off the carrier Phase 1 wrote, never from this shell (#440).
   # It was bound 48 fences ago and had NO producer here: every real run passed
   # the empty string into `review_refresh_phase1_scope`, whose own `40-hex`
   # guard then failed the whole Phase 2 scope rebuild. Same #418/#419 class as
   # CI_FIX_PHASE and PROBE_VERDICT, sitting in the Phase 2 refresh.
   REVIEW_BASE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_BASE_IDENTITY="$(review_fleet_read_review_base "$REVIEW_BASE_RUN_DIR/review-base-identity.tsv")" || {
     echo "error: /uberdev:review-pr — Phase 2 cannot read the reviewed-base identity from $REVIEW_BASE_RUN_DIR/review-base-identity.tsv; refusing to rebuild the review scope against a base it cannot name." >&2
     audit review_base_unreadable data.phase=phase2_routed
     return 2
   }
   BASE_SHA="${REVIEW_BASE_IDENTITY%%$(printf '\t')*}"
   BASE_REF_NAME="${REVIEW_BASE_IDENTITY#*$(printf '\t')}"
   review_refresh_phase1_scope "$BASE_SHA" || return 2
   # routed-provider-edge: review_pr.simplify.reuse
   # routed-provider-edge: review_pr.simplify.quality
   # routed-provider-edge: review_pr.simplify.efficiency
   SIMPLIFY_RECORDS="$RESEARCH_DIR_ABS/simplify.records"
   SIMPLIFY_DESCRIPTORS="$RESEARCH_DIR_ABS/simplify.descriptors"
   SIMPLIFY_LAUNCHED="$RESEARCH_DIR_ABS/simplify.launched"
   : >"$SIMPLIFY_RECORDS"
   for LENS in reuse quality efficiency; do
     EDGE_ID="review_pr.simplify.$LENS"
     INSTANCE="$(uberdev_child_instance_id "review-pr-${RUN_ID}-simplify-$LENS-iter${REVIEW_ITERATION}-attempt01")"
     if [ -n "$FOCUS" ]; then
       INPUTS_JSON="$(uberdev_child_inputs_build "$EDGE_ID" \
         diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
         lens "$(review_json_string "$LENS")" \
         focus "$(review_json_string "$FOCUS")")"
     else
       INPUTS_JSON="$(uberdev_child_inputs_build "$EDGE_ID" \
         diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
         lens "$(review_json_string "$LENS")")"
     fi
     review_child_record "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" '[]' "$SIMPLIFY_RECORDS"
   done
   review_child_fanout "$SIMPLIFY_RECORDS" "$SIMPLIFY_DESCRIPTORS" "$SIMPLIFY_LAUNCHED" "$REVIEW_PR_TIMEOUT"
   review_child_wait_all "$SIMPLIFY_LAUNCHED" "$REVIEW_PR_TIMEOUT"
   ```

   **6w. The three lenses on the Workflow-native transport** (run this INSTEAD
   of the `review_child_fanout` above, and only when
   `UBERDEV_CARRIER_BACKEND=workflow`)

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
   [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
   # Phase 1 may have advanced HEAD. Rebuild the enveloped diff and the
   # commit-range artifact from that exact post-fix snapshot first, exactly as
   # the routed path does — including taking BASE_SHA off the Phase 1 carrier
   # rather than from a name this shell never bound (#440).
   REVIEW_BASE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_BASE_IDENTITY="$(review_fleet_read_review_base "$REVIEW_BASE_RUN_DIR/review-base-identity.tsv")" || {
     echo "error: /uberdev:review-pr — Phase 2 cannot read the reviewed-base identity from $REVIEW_BASE_RUN_DIR/review-base-identity.tsv; refusing to rebuild the review scope against a base it cannot name." >&2
     audit review_base_unreadable data.phase=phase2_workflow
     return 2
   }
   BASE_SHA="${REVIEW_BASE_IDENTITY%%$(printf '\t')*}"
   BASE_REF_NAME="${REVIEW_BASE_IDENTITY#*$(printf '\t')}"
   review_refresh_phase1_scope "$BASE_SHA" || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
   mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   REVIEW_FLEET_LENS_LAUNCHED="$REVIEW_FLEET_RUN_DIR/review-fleet-simplify.launched"
   review_fleet_bind_roster simplify "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
     "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" "$REVIEW_FLEET_LENS_LAUNCHED" || return 2
   uberdev_emit_workflow_args review-fleet \
     mode=review-pr \
     stage=simplify \
     run_id="$RUN_ID" \
     runId="$RUN_ID" \
     runDirAbs="$REVIEW_FLEET_RUN_DIR" \
     pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
     repoRootAbs="$REVIEW_FLEET_WORKTREE" \
     workingDirAbs="$REVIEW_FLEET_WORKTREE" \
     prNumber="$PR_NUMBER" \
     repoSlug="$REVIEW_REPO_SLUG" \
     reviewIteration="$REVIEW_ITERATION" \
     diffPathAbs="$DIFF_ARTIFACT_PATH" \
     focus="$FOCUS" \
     maxAgents=40 \
     workspaceMode=caller \
     worktreeAbs="$REVIEW_FLEET_WORKTREE" \
     branchName= \
     runNonces="$REVIEW_FLEET_NONCE_POOL" || return 2
   ```

   **Workflow mandate:** relay the JSON between
   `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

   ```
   Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
   ```

   `lensConcurrency` is deliberately omitted: the script clamps it to 3, which
   is one wave of three — byte-for-byte the routed path's behaviour, which has
   no lens cap either.

   Then capture every lens child before reading a single finding. `capture-bound-child`
   takes no caller-supplied digest: it binds the child on the nonce, freezes
   `status.json` and `result.md`, and computes both digests itself.

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_LENS_LAUNCHED="$REVIEW_FLEET_RUN_DIR/review-fleet-simplify.launched"
   REVIEW_FLEET_LENS_CAPTURED="$REVIEW_FLEET_RUN_DIR/review-fleet-simplify.captured"
   : >"$REVIEW_FLEET_LENS_CAPTURED" || return 2
   REVIEW_FLEET_LENS_COUNT=0
   while IFS= read -r REVIEW_FLEET_ROW; do
     [ -n "$REVIEW_FLEET_ROW" ] || continue
     REVIEW_FLEET_EDGE="$(jq -er .edge <<<"$REVIEW_FLEET_ROW")" || return 2
     REVIEW_FLEET_BINDING="$(jq -er .binding <<<"$REVIEW_FLEET_ROW")" || return 2
     python3 -I -B "$CODE_FIXER_CONTRACT" capture-bound-child \
       --edge-id "$REVIEW_FLEET_EDGE" \
       --launch-binding-json "$REVIEW_FLEET_BINDING" >>"$REVIEW_FLEET_LENS_CAPTURED" || {
       echo "error: review-fleet Phase 2 lens $REVIEW_FLEET_EDGE produced no bound evidence" >&2
       return 2
     }
     printf '\n' >>"$REVIEW_FLEET_LENS_CAPTURED"
     REVIEW_FLEET_LENS_COUNT=$((REVIEW_FLEET_LENS_COUNT + 1))
   done <"$REVIEW_FLEET_LENS_LAUNCHED"
   [ "$REVIEW_FLEET_LENS_COUNT" -eq 3 ] || {
     echo "error: review-fleet Phase 2 captured $REVIEW_FLEET_LENS_COUNT of 3 lenses; Phase 2 is blocked" >&2
     return 2
   }
   ```

   A lens that returned nothing, wrote outside the derived layout, or echoed a
   nonce this controller never minted has no captured row, so Phase 2 is
   `blocked` (step 8 exit-code 2) rather than silently aggregating two lenses
   into a three-lens document.

   The lens-by-lens checklist (what each lens looks for) is the canonical definition in `/uberdev:simplify` Phase 2 — refer there rather than restate.

   **Brief preparation** (mirrors `uberdev:post-impl-review` Step 1):

   - Compute the post-Phase-1 diff once via `git diff <base>..HEAD` and pass the same artifact path to all three routed calls.
   - Truncation rule: if the diff exceeds 2000 lines, summarise per-file (path + 1-line summary) and inline only the files where per-line scrutiny matters for that lens. Same rule as `uberdev:post-impl-review` SKILL Step 1.

   Each lens preserves the iron rule from `/uberdev:simplify`: **behavior preservation is non-negotiable.**

   **Auto-apply simplify edits — Step 6b: dispatch `code-fixer` subagent.** After the three lenses return their advisory findings, aggregate them to `.uberdev/research/<RUN_ID>/simplify-final.md` — **written with `<external-untrusted-input source="simplify-aggregate">` as the file's LEADING bytes and `</external-untrusted-input>` as its TRAILING bytes** (envelope-as-file-bytes, #302 / RFC 0012 §3.1 do-first; first-128-bytes contract per `agents/findings-to-issues.md` Step 1; dedup + write recipe per `commands/simplify.md` Phase 3 — byte-shape oracle `tests/fixtures/findings-to-issues/simplify-final.sample.md`). Then dispatch the `code-fixer`; `review_pr.fix.phase2` plus manifest phase `simplify_fix` derives the `phase2/refactor` authority:

   ```bash
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
   PHASE2_FINDINGS_PATH="$RESEARCH_DIR_ABS/simplify-final.md"
   PHASE2_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE2_FINDINGS_PATH" --minimum 1 --maximum 16777216)" || return 74
   FIXER_COMMIT_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$COMMIT_RANGE_PATH" --minimum 1 --maximum 256)" || return 74
   PHASE2_AUTHORITY_PATH="$RESEARCH_DIR_ABS/code-fixer-authority-phase2-iter${REVIEW_ITERATION}.json"
   PHASE2_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
     --edge-id review_pr.fix.phase2 --policy-phase simplify_fix \
     --findings-path "$PHASE2_FINDINGS_PATH" --findings-sha256 "$PHASE2_FINDINGS_SHA256" \
     --commit-range-path "$COMMIT_RANGE_PATH" --commit-range-sha256 "$FIXER_COMMIT_RANGE_SHA256" \
     --working-dir "$WORKTREE_ROOT" --disposition-path "$PHASE2_DISPOSITION_PATH" \
     --authority-output-path "$PHASE2_AUTHORITY_PATH")" || return 74
   PHASE2_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1]); expected={"authority_path","authority_sha256","phase","commit_type","target_paths"}
if set(value)!=expected or value["authority_path"]!=sys.argv[2] or value["phase"]!="phase2" or value["commit_type"]!="refactor" or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None: raise SystemExit(74)
print(value["authority_sha256"],end="")' "$PHASE2_AUTHORITY_RECEIPT" "$PHASE2_AUTHORITY_PATH")" || return 74
   PHASE2_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase2-iter${REVIEW_ITERATION}.json"
   PHASE2_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase2 \
     findings_path "$(review_json_string "$PHASE2_FINDINGS_PATH")" \
     findings_sha256 "$(review_json_string "$PHASE2_FINDINGS_SHA256")" \
     commit_range_path "$(review_json_string "$COMMIT_RANGE_PATH")" \
     commit_range_sha256 "$(review_json_string "$FIXER_COMMIT_RANGE_SHA256")" \
     working_dir "$(review_json_string "$WORKTREE_ROOT")" \
     pr_number "$PR_NUMBER" \
     disposition_path "$(review_json_string "$PHASE2_DISPOSITION_PATH")" \
     authority_path "$(review_json_string "$PHASE2_AUTHORITY_PATH")" \
     authority_sha256 "$(review_json_string "$PHASE2_AUTHORITY_SHA256")")"
   FIXER_HEAD_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
   REVIEW_FIXER_TERMINAL=
   # subagent_type: uberdev:code-fixer
   # builder dispatch: uberdev_dispatch_child review_pr.fix.phase2
   if review_fixer_child_bound review_pr.fix.phase2 "$(uberdev_child_instance_id "review-pr-${RUN_ID}-fix-phase2-iter${REVIEW_ITERATION}-attempt01")" "$PHASE2_INPUTS" null "$RESEARCH_DIR_ABS/phase2-fixer" "$REVIEW_PR_TIMEOUT" "$PHASE2_AUTHORITY_PATH" "$PHASE2_AUTHORITY_SHA256" "$PHASE2_DISPOSITION_PATH" "$PHASE2_APPLIED_CONTENT_PATH"; then :; else
     REVIEW_FIXER_RC=$?
     review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"
     return $?
   fi
   FIXER_HEAD_AFTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   [ -n "${REVIEW_FIXER_TERMINAL:-}" ] || {
     review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" 74; return $?
   }
   FIXER_STATUS_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_RESULT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_DISPOSITION_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_APPLIED_CONTENT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   PHASE2_FIXER_OUTCOME="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-review-outcome \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --authority-path "$PHASE2_AUTHORITY_PATH" --authority-sha256 "$PHASE2_AUTHORITY_SHA256" \
     --disposition-path "$PHASE2_DISPOSITION_PATH" --disposition-sha256 "$FIXER_DISPOSITION_SHA256" \
     --applied-content-path "$PHASE2_APPLIED_CONTENT_PATH" --applied-content-sha256 "$FIXER_APPLIED_CONTENT_SHA256" \
     --status-sha256 "$FIXER_STATUS_SHA256" --result-sha256 "$FIXER_RESULT_SHA256" \
     --working-dir "$WORKTREE_ROOT" --head-before "$FIXER_HEAD_BEFORE" --head-after "$FIXER_HEAD_AFTER")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   review_promote_validated_fixer_outcome "$PHASE2_FIXER_OUTCOME" "$FIXER_HEAD_BEFORE" "$FIXER_HEAD_AFTER" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   ```

   **6bw. The Phase 2 fixer on the Workflow-native transport** (run this INSTEAD
   of the `review_fixer_child_bound review_pr.fix.phase2` dispatch above, and
   only when `UBERDEV_CARRIER_BACKEND=workflow`)

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
   [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
   mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   PHASE2_FINDINGS_PATH="$RESEARCH_DIR_ABS/simplify-final.md"
   PHASE2_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE2_FINDINGS_PATH" --minimum 1 --maximum 16777216)" || return 74
   FIXER_COMMIT_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$COMMIT_RANGE_PATH" --minimum 1 --maximum 256)" || return 74
   PHASE2_AUTHORITY_PATH="$RESEARCH_DIR_ABS/code-fixer-authority-phase2-iter${REVIEW_ITERATION}.json"
   PHASE2_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
     --edge-id review_pr.fix.phase2 --policy-phase simplify_fix \
     --findings-path "$PHASE2_FINDINGS_PATH" --findings-sha256 "$PHASE2_FINDINGS_SHA256" \
     --commit-range-path "$COMMIT_RANGE_PATH" --commit-range-sha256 "$FIXER_COMMIT_RANGE_SHA256" \
     --working-dir "$WORKTREE_ROOT" --disposition-path "$PHASE2_DISPOSITION_PATH" \
     --authority-output-path "$PHASE2_AUTHORITY_PATH")" || return 74
   PHASE2_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1]); expected={"authority_path","authority_sha256","phase","commit_type","target_paths"}
if set(value)!=expected or value["authority_path"]!=sys.argv[2] or value["phase"]!="phase2" or value["commit_type"]!="refactor" or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None: raise SystemExit(74)
print(value["authority_sha256"],end="")' "$PHASE2_AUTHORITY_RECEIPT" "$PHASE2_AUTHORITY_PATH")" || return 74
   PHASE2_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase2-iter${REVIEW_ITERATION}.json"
   REVIEW_FLEET_FIX2_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-fix-phase2-iter${REVIEW_ITERATION}.launch.json"
   FIXER_HEAD_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
   review_fleet_bind_fixer review_pr.fix.phase2 "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
     "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
     "$PHASE2_AUTHORITY_PATH" "$PHASE2_AUTHORITY_SHA256" \
     "$FIXER_HEAD_BEFORE" "$REVIEW_FLEET_FIX2_SIDECAR" || return 74
   uberdev_emit_workflow_args review-fleet \
     mode=review-pr \
     stage=fix \
     run_id="$RUN_ID" \
     runId="$RUN_ID" \
     runDirAbs="$REVIEW_FLEET_RUN_DIR" \
     pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
     repoRootAbs="$REVIEW_FLEET_WORKTREE" \
     workingDirAbs="$REVIEW_FLEET_WORKTREE" \
     prNumber="$PR_NUMBER" \
     repoSlug="$REVIEW_REPO_SLUG" \
     reviewIteration="$REVIEW_ITERATION" \
     fixerEdgeId=review_pr.fix.phase2 \
     commitType=refactor \
     findingsPathAbs="$PHASE2_FINDINGS_PATH" \
     findingsSha256="$PHASE2_FINDINGS_SHA256" \
     commitRangePathAbs="$COMMIT_RANGE_PATH" \
     commitRangeSha256="$FIXER_COMMIT_RANGE_SHA256" \
     authorityPathAbs="$PHASE2_AUTHORITY_PATH" \
     authoritySha256="$PHASE2_AUTHORITY_SHA256" \
     dispositionPathAbs="$PHASE2_DISPOSITION_PATH" \
     appliedContentPathAbs="$PHASE2_APPLIED_CONTENT_PATH" \
     maxAgents=40 \
     workspaceMode=caller \
     worktreeAbs="$REVIEW_FLEET_WORKTREE" \
     branchName= \
     runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
   ```

   **Workflow mandate:** relay the JSON between
   `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

   ```
   Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
   ```

   ```bash uberdev-executable origin=review-pr
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
   # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
   # fence advances and persists it; this fresh shell's `:-1` default would
   # otherwise re-key pass 2 onto pass 1's already-published artifact names.
   review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
   REVIEW_FLEET_FIX2_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-fix-phase2-iter${REVIEW_ITERATION}.launch.json"
   REVIEW_FIXER_LAUNCH_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_FIX2_SIDECAR" binding)" || return 74
   FIXER_HEAD_BEFORE="$(review_fleet_read_sidecar "$REVIEW_FLEET_FIX2_SIDECAR" head_before)" || return 74
   PHASE2_AUTHORITY_PATH="$(printf '%s' "$REVIEW_FIXER_LAUNCH_BINDING" | jq -er .authority_path)" || return 74
   PHASE2_AUTHORITY_SHA256="$(printf '%s' "$REVIEW_FIXER_LAUNCH_BINDING" | jq -er .authority_sha256)" || return 74
   PHASE2_APPLIED_CONTENT_PATH="$RESEARCH_DIR_ABS/review-applied-content-phase2-iter${REVIEW_ITERATION}.json"
   REVIEW_FIXER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-review-terminal \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --disposition-path "$PHASE2_DISPOSITION_PATH" \
     --applied-content-path "$PHASE2_APPLIED_CONTENT_PATH")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_HEAD_AFTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   FIXER_STATUS_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_RESULT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_DISPOSITION_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   FIXER_APPLIED_CONTENT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$REVIEW_FIXER_TERMINAL")" || return 74
   PHASE2_FIXER_OUTCOME="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-review-outcome \
     --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
     --authority-path "$PHASE2_AUTHORITY_PATH" --authority-sha256 "$PHASE2_AUTHORITY_SHA256" \
     --disposition-path "$PHASE2_DISPOSITION_PATH" --disposition-sha256 "$FIXER_DISPOSITION_SHA256" \
     --applied-content-path "$PHASE2_APPLIED_CONTENT_PATH" --applied-content-sha256 "$FIXER_APPLIED_CONTENT_SHA256" \
     --status-sha256 "$FIXER_STATUS_SHA256" --result-sha256 "$FIXER_RESULT_SHA256" \
     --working-dir "$WORKTREE_ROOT" --head-before "$FIXER_HEAD_BEFORE" --head-after "$FIXER_HEAD_AFTER")" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   review_promote_validated_fixer_outcome "$PHASE2_FIXER_OUTCOME" "$FIXER_HEAD_BEFORE" "$FIXER_HEAD_AFTER" || {
     REVIEW_FIXER_RC=$?; review_guard_failed_fixer_return "$FIXER_HEAD_BEFORE" "$REVIEW_FIXER_RC"; return $?
   }
   ```

   `PHASE2_HANDOFF` passes the already-enveloped `simplify-final.md` path; its
   bytes are consumed verbatim and are never re-wrapped.

   The agent creates ONE `refactor:` commit (R8.6 separate-commit invariant locks Phase 2 to a single `refactor:` per run; the agent's contract enforces this on the apply side, the test enforces it on the prose side). Reviewers must be able to tell "review fixes" apart from "simplify pass" by commit boundary alone — this distinct commit boundary is mandatory, not stylistic. Capture the agent's `commits[0].sha` for the final aggregation table's "Auto-applied" column for the Phase 2 row.

   Capture the Phase 2 `FIXER_HEAD_BEFORE`, `FIXER_HEAD_AFTER`, and declared
   `commits[0].sha`, then pass them through
   `review_promote_validated_fixer_outcome`. Phase 2 uses the same fail-closed
   mutation and ancestry rules as Phase 1; a refusal is non-mutating or blocked.

   If `code-fixer` returns `status: REFUSED` for Phase 2, log the rationale, continue to trust-signal evaluation (the Phase 2 row in the aggregation table reads `Auto-applied: ∅` and "Phase 2 fixer refused: <reason>" surfaces in Advisory findings). Phase 2 status is `blocked` if and only if the lens fanout itself failed (timeout / parse error / aggregator crash); a fixer refusal does NOT make Phase 2 `blocked` — the lenses' findings are advisory.

   **On green Phase 2 (status ∈ {ran/APPROVE, skipped}), defer trust-signal emission to the dedicated end-of-run step** (see "Trust-Signal Emission" below). Phase 2's simplify commit body itself does **NOT** carry the `Reviewed-by:` trailer — the trailer is emitted as a separate trust-trail-anchor empty commit at the very end of `/review-pr`. This guarantees the trailer's referenced SHA always anchors the actual end-of-run HEAD regardless of how many Phase 1 / Phase 2 commits land, sidestepping the parent-vs-self SHA-mismatch class of bugs that per-simplify-commit-trailer patterns produce when Phase 2 makes a real commit on top of Phase 1's last commit. The trailer payload format is unchanged — `Reviewed-by: uberdev/review-pr@<40-char-sha>` — only the carrier-commit choice changes (anchor commit, not simplify commit).

   **Advisory-only findings** (where a lens declines to edit because the change carries behavior risk, or the agent flags a concern outside the iron-rule envelope) are **never silently dropped** — they surface in the Phase 2 row of the final aggregation table (step 7) so the human reviewer sees them.

   **Non-blocking but exit-coded.** Phase 2 status governs the exit code (see step 8 exit-code contract):

   - `ran/APPROVE` or `skipped` → eligible for green; exit 0 if Phase 1 was APPROVE.
   - `blocked` (timeout, agent error, parse failure, aggregator crash) → exit 2. Phase 1 review-fix work is **not undone** — those commits land normally — but no trust-signal artifacts (label / trailer / JSON) are emitted, and the exit code surfaces the silent-failure mode that previously got swallowed. The Phase 2 row's Status is `blocked` (lowercase). Fix the aggregator before re-running.

   Phase 2 verdict ≠ Phase 2 status: an APPROVE verdict with `ran` status counts toward green; REVISIONS_REQUIRED or REJECT verdicts do NOT block trust-signal emission (they surface as advisory findings in the final aggregation table — see step 7). The trust-signal predicate is rooted in *status* (did the fanout complete cleanly?), not *verdict*.

6a. **Post-fixer push — publish fix commits before Phase 3 (#302, RFC 0012 §3.1 do-first)**

   After the LAST fixer returns — the Step 6b Phase-2 fixer, or the Step 5 Phase-1 fixer when `SIMPLIFY_PHASE=0` (`--no-simplify` skips Step 6 entirely, so Step 5's fixer is the last one) — push the accumulated Phase 1 + Phase 2 fix commits so the Phase 3 PROBE (6c.1) and MONITOR (6c.2) validate the **post-fix remote SHA**. Without this push the remote head stays pre-fix until the trust-trail anchor push at end-of-run, so Phase 3 probes CI that never ran on the fixed code and a GREEN trust signal can describe code CI never built. **Exactly ONE push per review cycle — after the last fixer, never one per fixer**: each push spawns a full duplicate CI check set while `test.yml` has no concurrency group (#309 — the CI-concurrency PR lands only after this one; see the 6c.1 benign-cancel dedupe it depends on).

   ```bash
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # Mirrors the trust-trail anchor push guard (Trust-Signal Emission artifact 1):
   # a silently-failed push here would let Phase 3 probe a stale remote SHA and
   # emit a trust signal for code CI never ran on. exit 2 = blocked-equivalent
   # per the artifact-emission-failure prose (trust-signal contract broken).
   POST_FIXER_HEAD_SHA="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || exit 2
   if [ "$POST_FIXER_HEAD_SHA" != "${VALIDATED_FIXER_HEAD_SHA:-}" ]; then
     echo "error: HEAD changed outside the validated review fixers; refusing publication" >&2
     exit 2
   fi
   if ! review_publish_same_repo_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$REVIEWED_HEAD_SHA" "$POST_FIXER_HEAD_SHA" "$WORKTREE_ROOT" "$CODE_FIXER_CONTRACT" "$RESEARCH_DIR_ABS"; then
     echo "error: immutable post-fixer publication, same-repository authority, equality, or residue proof failed — Phase 3 would probe an unauthenticated SHA. Re-run /review-pr after resolving." >&2
     exit 2
   fi
   REVIEWED_HEAD_SHA="$POST_FIXER_HEAD_SHA"
   ```

   The shared publication gate rejects fork PRs and authenticates the PR head
   repository, branch, pre-push remote head, immutable pushed object, remote
   ref, post-push live PR head, local HEAD, and clean repository residue. Only
   after every proof succeeds does the controller promote `REVIEWED_HEAD_SHA`
   to the validated fixer tip. When
   neither fixer produced a commit, the candidate remains the entry snapshot
   and the push is an `Everything up-to-date` no-op (exit 0). On Phase 1
   re-entry iterations (6c.5) this full tracking/publication sequence re-runs
   after the re-entered Step 5/6b fixers — still exactly one push per iteration.
   This step is NOT gated by `SIMPLIFY_PHASE`, `CI_FIX_PHASE`, or
   `DEFER_ISSUES_PHASE` — it runs on every path that reaches Phase 2.5/Phase 3.

6b.0. **Phase 1 verification gate** (RFC 0017 / #431)

    Between the Phase 1 disposition publish and the Phase 2.5 filing gate, every
    Phase 1 **blocker** finding the fixer did not APPLY is independently scored
    by a fresh-context `finding-verifier` child. A finding that scores below
    `review.confidence_threshold` is recorded `CULLED` in
    `.uberdev/research/<RUN_ID>/phase1-verification.json` and is never filed as
    a GitHub issue — which is also how it stops being a `/goal` recursion
    target, with **no `/goal` code change**: `lib/goal-phase3.sh` selects on the
    `review-pr-finding` label plus a `**Tier:** BLOCKER|CRITICAL` body line, and
    a row that is never filed carries neither.

    **What the verifier is not given.** The claim card
    `project-verification-claims` writes carries `finding_index`, `location` and
    `summary` and nothing else. The reviewer's `detail` — where the argument and
    the reviewer's own `confidence: <n>` prefix live — is withheld *mechanically*
    for the card: the bytes are simply not there. The threshold is withheld too,
    and is applied entirely controller-side in `publish-verification`, so the
    recorded score stays an opinion about the claim rather than a vote about the
    gate (and can be re-thresholded offline without re-running anything).

    **Fail toward keeping.** A blocked child, a malformed result, and a row past
    the dispatch cap each land `SURVIVES` with reason `verifier-unavailable`,
    `verifier-unavailable` and `over-cap-unverified` respectively. Only a
    well-formed score strictly below the threshold ever culls. A threshold of
    `0` disables the gate entirely: every eligible row is recorded `SURVIVES` /
    `gate-disabled` and **no verifier agent is dispatched at all**.

    Every scalar below is re-derived inside each fence because every `bash`
    block in this command is a FRESH shell (#427) — no `export`, array or
    counter from the Phase 1 fences survives to here, and none survives from
    this fence to the next one.

    ```bash uberdev-executable origin=review-pr
    REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
    [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-fleet-args.sh" || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
    mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
    # REVIEW_ITERATION off disk BEFORE anything is keyed on it — Phase 3's
    # re-entry fence advances and persists it, and this fresh shell's default
    # would otherwise re-key pass 2 onto pass 1's artifact names.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    # The gate's cutoff. Same call the Phase 1 preflight fence resolves, on
    # purpose: fences are fresh shells, so this is a RE-DERIVATION and not a
    # second declaration of the bounds.
    REVIEW_CONFIDENCE_THRESHOLD="$(uberdev_read_int_in_range review.confidence_threshold UBERDEV_REVIEW_THRESHOLD 0 100 80)" || return 2
    REVIEW_FLEET_CAP="$(uberdev_read_int_in_range fanout_concurrency.post_impl_review UBERDEV_FANOUT_POST_IMPL_REVIEW 1 50 6)" || return 2
    VERIFY_PHASE1_PATH="$REVIEW_FLEET_RUN_DIR/post-impl-review-final.md"
    VERIFY_PHASE1_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$VERIFY_PHASE1_PATH" --minimum 1 --maximum 16777216)" || return 74
    VERIFY_DISPOSITION_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE1_DISPOSITION_PATH" --minimum 1 --maximum 16777216)" || return 74
    VERIFY_CLAIMS_DIR="$REVIEW_FLEET_RUN_DIR/verification-claims-iter${REVIEW_ITERATION}"
    VERIFY_CLAIMS_RECEIPT_PATH="$REVIEW_FLEET_RUN_DIR/verification-claims-iter${REVIEW_ITERATION}.json"
    python3 -I -B "$CODE_FIXER_CONTRACT" project-verification-claims \
      --findings-path "$VERIFY_PHASE1_PATH" --findings-sha256 "$VERIFY_PHASE1_SHA256" \
      --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$VERIFY_DISPOSITION_SHA256" \
      --claims-dir "$VERIFY_CLAIMS_DIR" >"$VERIFY_CLAIMS_RECEIPT_PATH" || return 74
    VERIFY_COUNT="$(jq -r '.verify_count' "$VERIFY_CLAIMS_RECEIPT_PATH")" || return 74
    case "$VERIFY_COUNT" in ''|*[!0-9]*) return 74 ;; esac
    # The sidecar is a SIBLING of the disposition under an exact basename;
    # publish-verification refuses any other location. Created empty HERE so the
    # publish is an identity-checked replace of a file this command made.
    VERIFY_SIDECAR_PATH="$(dirname "$PHASE1_DISPOSITION_PATH")/phase1-verification.json"
    [ -e "$VERIFY_SIDECAR_PATH" ] || ( umask 077 && : >"$VERIFY_SIDECAR_PATH" ) || return 74
    # Rows past the cap are neither dispatched nor dropped — see
    # REVIEW_FLEET_VERIFY_TOTAL_CAP in lib/review-fleet-args.sh. A gate that
    # aborted on a large finding set would make a bad review un-reviewable; one
    # that silently dropped rows would cull without saying so.
    VERIFY_DISPATCH_COUNT="$VERIFY_COUNT"
    [ "$VERIFY_DISPATCH_COUNT" -le "$REVIEW_FLEET_VERIFY_TOTAL_CAP" ] \
      || VERIFY_DISPATCH_COUNT="$REVIEW_FLEET_VERIFY_TOTAL_CAP"
    VERIFY_LEDGER="$REVIEW_FLEET_RUN_DIR/review-fleet-verify-iter${REVIEW_ITERATION}.jsonl"
    VERIFY_CLAIM_LEDGER="$REVIEW_FLEET_RUN_DIR/review-fleet-verify-claims-iter${REVIEW_ITERATION}.txt"
    # TWO short-circuits skip the Workflow call entirely. Both still publish a
    # sidecar: a run that recorded nothing is indistinguishable downstream from
    # a run that culled nothing.
    if [ "$VERIFY_COUNT" -eq 0 ]; then
      # Nothing eligible: an empty roster, published as an empty array.
      printf '[]' | python3 -I -B "$CODE_FIXER_CONTRACT" publish-verification \
        --findings-path "$VERIFY_PHASE1_PATH" --findings-sha256 "$VERIFY_PHASE1_SHA256" \
        --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$VERIFY_DISPOSITION_SHA256" \
        --verification-path "$VERIFY_SIDECAR_PATH" --threshold "$REVIEW_CONFIDENCE_THRESHOLD" >/dev/null || return 74
      VERIFY_DISPATCH=0
    elif [ "$REVIEW_CONFIDENCE_THRESHOLD" -eq 0 ]; then
      # KILL SWITCH. No claim is dispatched and no agent runs, but every
      # eligible row is still recorded SURVIVES/gate-disabled so the artifact
      # names what was NOT verified.
      jq -c '[.claims[] | {finding_index: .finding_index, reason: "gate-disabled"}]' "$VERIFY_CLAIMS_RECEIPT_PATH" \
        | python3 -I -B "$CODE_FIXER_CONTRACT" publish-verification \
          --findings-path "$VERIFY_PHASE1_PATH" --findings-sha256 "$VERIFY_PHASE1_SHA256" \
          --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$VERIFY_DISPOSITION_SHA256" \
          --verification-path "$VERIFY_SIDECAR_PATH" --threshold 0 >/dev/null || return 74
      VERIFY_DISPATCH=0
    else
      VERIFY_DISPATCH=1
      jq -r --argjson n "$VERIFY_DISPATCH_COUNT" '.claims[0:$n][].claim_path' "$VERIFY_CLAIMS_RECEIPT_PATH" >"$VERIFY_CLAIM_LEDGER" || return 74
      REVIEW_FLEET_VERIFY_CONTRACT_PATH="$(review_fleet_contract_path "$UBERDEV_REVIEW_PLUGIN_ROOT" finding-verifier-v1)" || return 2
      REVIEW_FLEET_VERIFY_RUBRIC_PATH="$UBERDEV_REVIEW_PLUGIN_ROOT/shared/finding-confidence-rubric-v1.md"
      [ -r "$REVIEW_FLEET_VERIFY_RUBRIC_PATH" ] || return 2
      # mkdir -p per child, one CSPRNG nonce per child in the roster order the
      # script consumes, one bind-workflow-launch per child — all BEFORE
      # dispatch, the only moment a binding can be minted that the child could
      # not influence.
      review_fleet_bind_verify "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
        "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
        "$VERIFY_CLAIM_LEDGER" "$VERIFY_LEDGER" || return 74
      uberdev_emit_workflow_args review-fleet \
        mode=review-pr \
        stage=verify \
        run_id="$RUN_ID" \
        runId="$RUN_ID" \
        runDirAbs="$REVIEW_FLEET_RUN_DIR" \
        pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
        repoRootAbs="$REVIEW_FLEET_WORKTREE" \
        workingDirAbs="$REVIEW_FLEET_WORKTREE" \
        prNumber="$PR_NUMBER" \
        repoSlug="$REVIEW_REPO_SLUG" \
        reviewIteration="$REVIEW_ITERATION" \
        diffPathAbs="$DIFF_ARTIFACT_PATH" \
        verifyCount="$REVIEW_FLEET_VERIFY_COUNT" \
        verifyCap="$REVIEW_FLEET_VERIFY_TOTAL_CAP" \
        verifyClaimPrefixAbs="$VERIFY_CLAIMS_DIR/verify-" \
        verifyContractPathAbs="$REVIEW_FLEET_VERIFY_CONTRACT_PATH" \
        verifyRubricPathAbs="$REVIEW_FLEET_VERIFY_RUBRIC_PATH" \
        verifyPrContextPathAbs="$REVIEW_FLEET_RUN_DIR/pr-context.md" \
        fanoutCap="$REVIEW_FLEET_CAP" \
        maxAgents=40 \
        workspaceMode=caller \
        worktreeAbs="$REVIEW_FLEET_WORKTREE" \
        branchName= \
        runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
    fi
    ```

    `branchName` is emitted EMPTY on purpose, for the same reason the Phase 1
    fanout emits it empty: `bind-workflow-launch` records `branch: ""`, and
    `_validate_bound_workflow_child_status` requires the child's `status.json`
    branch to equal the binding's — a non-empty value here would make every
    child's status refuse.

    **Workflow mandate** (skip entirely when the fence set `VERIFY_DISPATCH=0`):
    the fence above validated
    `[ -f "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js" ]`. Relay the JSON
    between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2 — no
    LLM-composed handoffs) into ONE `Workflow` call naming
    `skills/review-fleet/workflow.js`. Do not summarise it, do not re-order it,
    do not add a key. **The threshold is not in that envelope and must never be
    added to it** — a verifier told the cutoff calibrates to it.

    On return, re-read every child's frozen bytes, apply the threshold
    controller-side, and publish. This is a fresh shell, so it re-derives every
    path from disk rather than from the fence above:

    ```bash uberdev-executable origin=review-pr
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-fleet-args.sh" || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    REVIEW_CONFIDENCE_THRESHOLD="$(uberdev_read_int_in_range review.confidence_threshold UBERDEV_REVIEW_THRESHOLD 0 100 80)" || return 2
    VERIFY_PHASE1_PATH="$REVIEW_FLEET_RUN_DIR/post-impl-review-final.md"
    VERIFY_PHASE1_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$VERIFY_PHASE1_PATH" --minimum 1 --maximum 16777216)" || return 74
    VERIFY_DISPOSITION_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE1_DISPOSITION_PATH" --minimum 1 --maximum 16777216)" || return 74
    VERIFY_SIDECAR_PATH="$(dirname "$PHASE1_DISPOSITION_PATH")/phase1-verification.json"
    VERIFY_CLAIMS_RECEIPT_PATH="$REVIEW_FLEET_RUN_DIR/verification-claims-iter${REVIEW_ITERATION}.json"
    VERIFY_LEDGER="$REVIEW_FLEET_RUN_DIR/review-fleet-verify-iter${REVIEW_ITERATION}.jsonl"
    VERIFY_OPINIONS_PATH="$REVIEW_FLEET_RUN_DIR/review-fleet-verify-opinions-iter${REVIEW_ITERATION}.json"
    : >"$VERIFY_OPINIONS_PATH" || return 74
    VERIFY_ROW_INDEX=0
    while IFS= read -r VERIFY_ROW; do
      [ -n "$VERIFY_ROW" ] || continue
      VERIFY_ROW_INDEX=$((VERIFY_ROW_INDEX + 1))
      VERIFY_FINDING_INDEX="$(jq -r --argjson i "$VERIFY_ROW_INDEX" '.claims[$i - 1].finding_index' "$VERIFY_CLAIMS_RECEIPT_PATH")" || return 74
      VERIFY_RESULT_PATH="$(jq -r '.result' <<<"$VERIFY_ROW")" || return 74
      # A child that returned nothing usable NEVER culls. The validator is the
      # canonical boundary; its refusal is the honest answer, not a licence to
      # invent a score.
      if VERIFY_PAIR="$(uberdev_child_validate_finding_verifier_result "$VERIFY_RESULT_PATH")"; then
        jq -cn --argjson i "$VERIFY_FINDING_INDEX" \
          --argjson s "${VERIFY_PAIR%% *}" --arg r "${VERIFY_PAIR##* }" \
          '{finding_index:$i, score:$s, reason:$r}' >>"$VERIFY_OPINIONS_PATH" || return 74
      else
        jq -cn --argjson i "$VERIFY_FINDING_INDEX" \
          '{finding_index:$i, reason:"verifier-unavailable"}' >>"$VERIFY_OPINIONS_PATH" || return 74
      fi
    done <"$VERIFY_LEDGER"
    # Rows past the dispatch cap were never sent to a verifier. Record them,
    # never drop them.
    jq -s -c --slurpfile receipt "$VERIFY_CLAIMS_RECEIPT_PATH" --argjson n "$VERIFY_ROW_INDEX" \
      '. + [$receipt[0].claims[$n:][] | {finding_index: .finding_index, reason: "over-cap-unverified"}]' \
      "$VERIFY_OPINIONS_PATH" \
      | python3 -I -B "$CODE_FIXER_CONTRACT" publish-verification \
        --findings-path "$VERIFY_PHASE1_PATH" --findings-sha256 "$VERIFY_PHASE1_SHA256" \
        --disposition-path "$PHASE1_DISPOSITION_PATH" --disposition-sha256 "$VERIFY_DISPOSITION_SHA256" \
        --verification-path "$VERIFY_SIDECAR_PATH" --threshold "$REVIEW_CONFIDENCE_THRESHOLD" \
      >"$REVIEW_FLEET_RUN_DIR/verification-receipt-iter${REVIEW_ITERATION}.json" || return 74
    # One audit row per verified finding, so a suppressed blocker is nameable
    # from the repo-root audit stream and not only from the run directory.
    # Fail-soft by construction — a missing audit row must never fail a review
    # that otherwise passed.
    while IFS= read -r VERIFY_AUDIT_ROW; do
      [ -n "$VERIFY_AUDIT_ROW" ] || continue
      review_fleet_audit_append "$REVIEW_FLEET_WORKTREE" "$VERIFY_AUDIT_ROW"
    done <<EOF_VERIFY_AUDIT
$(jq -r --arg pr "$PR_NUMBER" --arg run "$RUN_ID" --argjson t "$REVIEW_CONFIDENCE_THRESHOLD" \
   '.findings_verification[] | {event:"review_finding_verified", pr:$pr, run_id:$run,
     finding_index:.finding_index, location:.location, summary_sha256:.summary_sha256,
     score:.score, verdict:.verdict, reason:.reason, threshold:$t} | tostring' \
   "$VERIFY_SIDECAR_PATH")
EOF_VERIFY_AUDIT
    ```

    `phase1-verification.json` is the artifact `findings-to-issues` binds as
    `verification_path` in Phase 2.5 below, and the `verification` sub-block of
    `phases.phase2_5` (step 7) reports `threshold`, `verified` and `culled` from
    `verification-receipt-iter<N>.json` so a human and `trust-trail-evaluator`
    can both see what a GREEN run suppressed.

6b. **Phase 2.5 — Findings-to-Issues sub-phase** (skip iff `DEFER_ISSUES_PHASE=0` OR `defer_issues_enabled=false`)

    Reads the run aggregate artifacts produced by Phase 1 (`post-impl-review-final.md`) and Phase 2 (`simplify-final.md`), filters all issue-eligible deferred rows (`severity ∈ {blocker, critical, important, major} AND disposition != APPLIED`), maps them to BLOCKER / CRITICAL / MAJOR tiers, and persists them as durable GitHub issues with HTML-comment fingerprint dedupe. Default-on. The parent halts only when at least one BLOCKER is deferred or when the `MAX_NEW` cap truncates a BLOCKER/CRITICAL row; major/important filings and non-overflow critical filings remain non-halting.

    **Effective-enabled gate:** the sub-phase runs only when BOTH the CLI flag AND the config key are ON. Either knob disables (CLI flag `DEFER_ISSUES_PHASE=1` AND config `DEFER_ISSUES_CONFIG=true`).

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    # Read the config-level enum (default: "true" — always-on per Q3).
    source "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh"
    DEFER_ISSUES_CONFIG=$(uberdev_read_enum defer_issues_enabled UBERDEV_DEFER_ISSUES_ENABLED 'true|false' 'true')

    # Effective-enabled: AND of CLI flag and config key. Either knob disables.
    if [ "$DEFER_ISSUES_PHASE" = "1" ] && [ "$DEFER_ISSUES_CONFIG" = "true" ]; then
      DEFER_ISSUES_EFFECTIVE=1
    else
      DEFER_ISSUES_EFFECTIVE=0
    fi
    ```

    **Dispatch variable bindings.** Before the routed dispatch, bind the
    command-owned worktree and run paths. The child derives and validates
    repository identity itself. `review_fleet_rehydrate` is the binder — the
    hand-rolled `WORKING_DIR_ABS`/`RESEARCH_DIR_ABS` pair that used to live here
    was a second copy of the run-path algebra, and it did not survive to the
    fence that read it anyway:

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    ```

    **Dispatch one routed findings child:**

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
    # fence advances and persists it; this fresh shell's `:-1` default would
    # otherwise re-key pass 2 onto pass 1's already-published artifact names.
    review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
    # verification_path is OPTIONAL and is passed only when Step 6b.0 actually
    # published a sidecar. Naming a path nothing wrote would make the child
    # refuse `input-malformed` on every run that skipped the gate.
    # `${ARR[@]+"${ARR[@]}"}` because an empty array under `set -u` on bash 3.2
    # is an unbound-variable error, not an empty expansion.
    DEFER_VERIFICATION_ARGS=()
    if [ -s "$RESEARCH_DIR_ABS/phase1-verification.json" ]; then
      DEFER_VERIFICATION_ARGS=(verification_path "$(review_json_string "$RESEARCH_DIR_ABS/phase1-verification.json")")
    fi
    DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.defer.findings \
      phase1_path "$(review_json_string "$RESEARCH_DIR_ABS/post-impl-review-final.md")" \
      phase2_path "$(review_json_string "$RESEARCH_DIR_ABS/simplify-final.md")" \
      phase1_disposition_path "$(review_json_string "$PHASE1_DISPOSITION_PATH")" \
      phase2_disposition_path "$(review_json_string "$PHASE2_DISPOSITION_PATH")" \
      working_dir "$(review_json_string "$WORKTREE_ROOT")" \
      ${DEFER_VERIFICATION_ARGS[@]+"${DEFER_VERIFICATION_ARGS[@]}"} \
      pr_number "$PR_NUMBER")"
    review_child_single review_pr.defer.findings "$(uberdev_child_instance_id "review-pr-${RUN_ID}-defer-findings-iter${REVIEW_ITERATION}-attempt01")" "$DEFER_INPUTS" null "$RESEARCH_DIR_ABS/defer" "$REVIEW_PR_TIMEOUT"
    ```

    **2.5w. The defer child on the Workflow-native transport** (run this INSTEAD
    of the `review_child_single review_pr.defer.findings` dispatch above, and
    only when `UBERDEV_CARRIER_BACKEND=workflow`)

    The defer edge has exactly one bindable producer — `bind-workflow-persistence-launch`
    — and it pins the Phase 2 aggregate and disposition by path and digest and
    **re-counts the deferred blockers from those pinned bytes**. That count, not
    a declared one, is what `DEFER_REQUIRE_CLEAN` gates on. The Phase 1 pair
    still travels as a prompt input (the child files from both), but the binding
    pins the Phase 2 pair, mirroring `/uberdev:simplify` exactly; the routed
    path here pins neither, so this is strictly more proof than the transport it
    replaces, not less.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
    [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
    mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
    # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
    # fence advances and persists it; this fresh shell's `:-1` default would
    # otherwise re-key pass 2 onto pass 1's already-published artifact names.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    DEFER_PHASE1_PATH="$RESEARCH_DIR_ABS/post-impl-review-final.md"
    DEFER_PHASE2_PATH="$RESEARCH_DIR_ABS/simplify-final.md"
    DEFER_PHASE2_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$DEFER_PHASE2_PATH" --minimum 1 --maximum 16777216)" || return 74
    DEFER_PHASE2_DISPOSITION_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$PHASE2_DISPOSITION_PATH" --minimum 1 --maximum 16777216)" || return 74
    DEFERRED_BLOCKER_COUNT="$(python3 -I -B "$CODE_FIXER_CONTRACT" count-deferred-blockers \
      --findings-path "$DEFER_PHASE2_PATH" --findings-sha256 "$DEFER_PHASE2_SHA256" \
      --disposition-path "$PHASE2_DISPOSITION_PATH" --disposition-sha256 "$DEFER_PHASE2_DISPOSITION_SHA256")" || return 74
    case "$DEFERRED_BLOCKER_COUNT" in ''|*[!0-9]*) return 74 ;; esac
    DEFER_REQUIRE_CLEAN=0
    [ "$DEFERRED_BLOCKER_COUNT" -eq 0 ] || DEFER_REQUIRE_CLEAN=1
    # The documented MAX_NEW=10 cap for this command (step 7 table). Passed as a
    # declared scalar rather than left to the script default so the two cannot
    # drift apart silently.
    DEFER_MAX_NEW=10
    # Empty when Step 6b.0 published nothing this iteration; the script omits
    # the line from the child prompt entirely rather than naming a missing file.
    DEFER_VERIFICATION_PATH=''
    [ -s "$REVIEW_FLEET_RUN_DIR/phase1-verification.json" ] \
      && DEFER_VERIFICATION_PATH="$REVIEW_FLEET_RUN_DIR/phase1-verification.json"
    REVIEW_FLEET_DEFER_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-defer-iter${REVIEW_ITERATION}.launch.json"
    review_fleet_bind_persistence "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
      "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
      "$DEFER_PHASE2_PATH" "$DEFER_PHASE2_SHA256" \
      "$PHASE2_DISPOSITION_PATH" "$DEFER_PHASE2_DISPOSITION_SHA256" \
      "$DEFERRED_BLOCKER_COUNT" "$DEFER_REQUIRE_CLEAN" "$REVIEW_FLEET_DEFER_SIDECAR" || return 74
    uberdev_emit_workflow_args review-fleet \
      mode=review-pr \
      stage=defer \
      run_id="$RUN_ID" \
      runId="$RUN_ID" \
      runDirAbs="$REVIEW_FLEET_RUN_DIR" \
      pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
      repoRootAbs="$REVIEW_FLEET_WORKTREE" \
      workingDirAbs="$REVIEW_FLEET_WORKTREE" \
      prNumber="$PR_NUMBER" \
      repoSlug="$REVIEW_REPO_SLUG" \
      reviewIteration="$REVIEW_ITERATION" \
      phase1PathAbs="$DEFER_PHASE1_PATH" \
      phase2PathAbs="$DEFER_PHASE2_PATH" \
      phase1DispositionPathAbs="$PHASE1_DISPOSITION_PATH" \
      phase2DispositionPathAbs="$PHASE2_DISPOSITION_PATH" \
      verificationPathAbs="$DEFER_VERIFICATION_PATH" \
      maxNew="$DEFER_MAX_NEW" \
      maxAgents=40 \
      workspaceMode=caller \
      worktreeAbs="$REVIEW_FLEET_WORKTREE" \
      branchName= \
      runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
    ```

    **Workflow mandate:** relay the JSON between
    `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

    ```
    Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
    ```

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    # REVIEW_ITERATION off disk BEFORE anything is keyed on it. Phase 3's re-entry
    # fence advances and persists it; this fresh shell's `:-1` default would
    # otherwise re-key pass 2 onto pass 1's already-published artifact names.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    REVIEW_FLEET_DEFER_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-defer-iter${REVIEW_ITERATION}.launch.json"
    REVIEW_DEFER_LAUNCH_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_DEFER_SIDECAR" binding)" || return 74
    REVIEW_DEFER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-persistence-terminal \
      --launch-binding-json "$REVIEW_DEFER_LAUNCH_BINDING")" || return 74
    DEFER_STATUS_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status_sha256"],end="")' "$REVIEW_DEFER_TERMINAL")" || return 74
    DEFER_RESULT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result_sha256"],end="")' "$REVIEW_DEFER_TERMINAL")" || return 74
    DEFER_PERSISTENCE_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-persistence-result \
      --launch-binding-json "$REVIEW_DEFER_LAUNCH_BINDING" \
      --status-sha256 "$DEFER_STATUS_SHA256" \
      --result-sha256 "$DEFER_RESULT_SHA256")" || {
      # A refused, malformed or unbindable persistence result is normalized to
      # MALFORMED and handled by the status gate below — never read as "no
      # deferred findings".
      DEFER_PERSISTENCE_STATUS=MALFORMED
      DEFER_PERSISTENCE_RECEIPT=
    }
    if [ -n "${DEFER_PERSISTENCE_RECEIPT:-}" ]; then
      DEFER_PERSISTENCE_STATUS="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["status"],end="")' "$DEFER_PERSISTENCE_RECEIPT")" || return 74
      PHASE2_5_HALTED="$(python3 -I -B -c 'import json,sys; print(str(json.loads(sys.argv[1])["halted"]).lower(),end="")' "$DEFER_PERSISTENCE_RECEIPT")" || return 74
    else
      PHASE2_5_HALTED=true
    fi
    ```

    Feed `DEFER_PERSISTENCE_STATUS` into `review_apply_phase2_5_status` below —
    the same gate the routed path uses, unchanged. The counts and URLs for the
    Step 7 table come from the script's `issues` return; the HALT decision does
    not. `PHASE2_5_HALTED` above is the validated persistence receipt's,
    computed from the child's own frozen result bytes.

    **Capture the return YAML** into shell variables `CREATED_URLS_JSON`, `COMMENTED_URLS_JSON`, `SKIPPED_CLOSED_JSON`, `BLOCKED_BY_DEDUPE_JSON`, `OVERFLOW_COUNT`, `BY_SEVERITY_BLOCKER`, `BY_SEVERITY_CRITICAL`, `BY_SEVERITY_MAJOR`, `HALTED_DUE_TO_OVERFLOW`, `PHASE2_5_HALTED` for the Step 7 Final Aggregation table AND the new GREEN/YELLOW/RED predicate (Trust-Signal Emission section). Validate the YAML before treating absent arrays as zero issues.

    Publication/origin/parse failures are infrastructure failures, not a
    zero-finding result. The controller applies this executable status gate:

    ```bash uberdev-executable origin=review-pr
    review_apply_phase2_5_status() {
      local child_status="${@:1:1}"
      [ "$#" -ge 1 ] || return 2
      case "$child_status" in
        DONE|DONE_WITH_CONCERNS) return 0 ;;
        REFUSED)
          PHASE2_5_STATUS=blocked
          PHASE2_5_HALTED=true
          PHASE2_5_INFRA_FAILURE=true
          OUTCOME=halted
          PHASE2_5_FAILURE_REASON=findings_to_issues_refused
          return 74
          ;;
        MALFORMED)
          PHASE2_5_STATUS=blocked
          PHASE2_5_HALTED=true
          PHASE2_5_INFRA_FAILURE=true
          OUTCOME=halted
          PHASE2_5_FAILURE_REASON=findings_to_issues_malformed
          return 74
          ;;
        *) return 2 ;;
      esac
    }
    ```

    A malformed return is normalized to `MALFORMED`. If
    `review_apply_phase2_5_status` returns non-zero, record the blocked Phase
    2.5 row and terminate with exit 2 before any trust-trail anchor, label, or
    audit approval artifact. `REFUSED` cannot be overridden interactively.
    Only a configured skip is non-halting and GREEN-eligible.

    ### 6b.1 Phase 2.5 halt handling (RFC 0002 §3.5)

    Immediately after capturing the agent return YAML, branch on `PHASE2_5_HALTED`:

    ```bash
    if [ "${PHASE2_5_HALTED:-false}" = "true" ]; then
      # Phase 2.5 filed at least one BLOCKER tier issue OR truncated a BLOCKER/CRITICAL.
      # Surface a user-visible halt block; the RED trust-trail emission downstream
      # will skip the label + trailer.
      :
    fi
    ```

    **User-visible halt prose** (rendered to stderr regardless of `TURBO`):

    ```
    /uberdev:review-pr — Phase 2.5 halt (RFC 0002)
      blocker filings:   $BY_SEVERITY_BLOCKER
      critical filings:  $BY_SEVERITY_CRITICAL
      overflow halt:     $HALTED_DUE_TO_OVERFLOW (truncated count: $OVERFLOW_COUNT)
      filed issues:      <render created_urls + commented_urls as bullet list with tier>
      trust trail:       RED — no Reviewed-by trailer, no uberdev-approved label
      /merge will:       INVALID until issues resolved OR --accept-blocker-deferred passed
    ```

    **Interactive (`TURBO=0` AND stdin is a TTY) — AskUserQuestion:**

    ```
    ToolSearch({ query: "select:AskUserQuestion" })   // mandatory deferred-tool load (same gate as 6c.6)
    AskUserQuestion({
      question: "Phase 2.5 filed $BY_SEVERITY_BLOCKER blocker issue(s). Trust trail will emit RED — /merge will block this PR until resolved. How to proceed?",
      options: [
        { label: "Print /solve suggestion + RED", description: "Render '/uberdev:solve <highest-priority issue URL>' suggestion to stderr; emit RED trail; exit 1. User runs /solve in a follow-up turn." },
        { label: "Skip — RED trail",              description: "Issues stay open, RED trail emitted, /merge blocked until resolved. Exit 1." },
        { label: "Override — emit GREEN",         description: "Log override_reason in audit JSON; /merge requires --i-know-what-im-doing flag to proceed" }
      ],
      multiSelect: false
    })
    ```

    **ToolSearch fail-fast.** When `ToolSearch` fails to load `AskUserQuestion`, `/review-pr` aborts with stderr error — **NEVER silently auto-pick** (mirrors `orchestrator/SKILL.md:190-193` and 6c.6 HALT). The deterministic shell:

    ```
    if ! ToolSearch("select:AskUserQuestion") >/dev/null 2>&1; then
      echo "error: AskUserQuestion tool unavailable — Phase 2.5 halt-choice cannot be presented; aborting" >&2
      audit halt_tool_unavailable data.tool="AskUserQuestion"
      exit 1
    fi
    ```

    Capture the choice into `PHASE2_5_HALT_CHOICE ∈ {solve_suggestion, skip, override}`.

    **Non-interactive (`TURBO=1` OR no TTY):** default to `solve_suggestion` (it preserves actionable information for the operator who later reads the run log) with the prose summary above. `override` is interactive-only by design — an unattended override poisons the trust trail with no human review.

    **`solve_suggestion` rendering** — emit one stderr line per filed BLOCKER URL: `next: /uberdev:solve <URL>`. The user runs the suggested command in a follow-up turn; `/review-pr` itself does not background-dispatch `/solve` (sub-process dispatch from inside a halted review run is out of scope per RFC 0002 §7.1 — defaults to hard-stop to avoid cascading agent loops).

    **`override` audit field:** if `PHASE2_5_HALT_CHOICE == "override"`, set `OVERRIDE_REASON="user-selected-emit-green-on-blocker-deferred"` for the audit JSON. Otherwise `OVERRIDE_REASON=null`. The override only suppresses the RED downgrade in the trust-trail emission step; it does NOT close the filed issues — `/merge` reads the override flag on the audit JSON and requires `--i-know-what-im-doing` to merge anyway.

    `PHASE2_5_HALTED=false` (the common path — no blocker, no critical/blocker overflow) skips this entire block; control falls through to Step 6c.

    **Skip-path behaviour** (when `DEFER_ISSUES_EFFECTIVE=0`):
    - Do NOT call `routed child (subagent_type: uberdev:findings-to-issues, …)`.
    - The Step 7 Final Aggregation "Issues filed" row shows `(skipped: --no-defer-issues)` when `DEFER_ISSUES_PHASE=0`, OR `(skipped: defer_issues_enabled=false)` when the config key is the cause. When both knobs disable, the message names both causes joined by " and " (e.g. `(skipped: --no-defer-issues and defer_issues_enabled=false)`).

6c. **Phase 3 — CI Health** (skip iff `CI_FIX_PHASE=0` is set AND mode is probe-only — see flag handling below)

    Phase 3 runs after Phase 2 and before trust-signal emission. It probes live CI on the post-Phase-2 HEAD, monitors pending runs, classifies red runs into one of six failure classes (`CI_FAILURE_CLASS_ENUM` defined in `plugins/uberdev/skills/merge-pipeline/SKILL.md` Constants), routes to specialized fixer agents for resolvable classes, and halts via `AskUserQuestion` (or audit-only under `--turbo`) for the two classes no code change can resolve. The trust-signal anchor commit (Step 7) is gated on Phase 3's outcome.

    Loop counter and cap defined in 6c.7 LOOP GUARD below (`CI_FIX_LOOP_CAP = 3`, declared in `merge-pipeline/SKILL.md` Constants). On cap exhaustion → `OUTCOME=loop_cap_exhausted`, exit 1. **The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge-pipeline/SKILL.md` "PARK is the terminal floor" prose is restated here.**

    **Transport — Phase 3 dispatches through `skills/review-fleet/workflow.js`,
    like the other four stages (#383).** Four stages, four separate
    `Workflow(...)` calls in the worst case:

    | Sub-step | Stage | Child |
    |---|---|---|
    | 6c.3 CLASSIFY | `stage=ci-classify` | one `uberdev:ci-failure-classifier` |
    | 6c.4 ROUTE (`code_bug`/`env_drift`) | `stage=ci-fix`, `ciFixerEdgeId=review_pr.ci.fix_code` | one `uberdev:ci-code-fixer` |
    | 6c.4 ROUTE (`stale_base`) | `stage=ci-fix`, `ciFixerEdgeId=review_pr.ci.rebase` | one `uberdev:ci-rebase-handler` |
    | CONFLICT-RESOLVE | `stage=ci-conflicts` | N `uberdev:conflict-resolver` |
    | 6c.5 defer_refusal | `stage=ci-defer` | one `uberdev:findings-to-issues` |

    Everything else in Phase 3 — 6c.1 PROBE, 6c.2 MONITOR, the routing decision,
    `gh run rerun`, the rebase lease, `git add` / `rebase --continue`, the
    force-push, 6c.6 HALT and the loop counters — dispatches no agent and stays
    in this command's Bash, which is where it already was.

    **The seam holds.** `skills/review-fleet/SKILL.md`: *the script dispatches
    and waits, and that is all it does.* Every digest, every artifact
    validation and every `git`/`gh` mutation runs HERE, through
    `lib/code_fixer_contract.py`. None of it moves into the script and none of
    it moves into a relay agent — a Workflow script has no filesystem, so every
    disk fact it wanted would have to come back through an LLM. Phase 3 is the
    arm where breaking that is cheapest-looking and most expensive: the failure
    mode is not a crash, it is a **force-push authorised by a number an agent
    typed**, with every downstream equality check still reading as verified.

    Three stage boundaries are PROOF POINTS, not agent-budget seams:

    - `ci-classify` → `ci-fix`. `validate-ci-classification` re-reads the
      child's frozen result bytes and enforces four things the script cannot:
      the class is in `CI_FAILURE_CLASS_ENUM`, the class/anchor pairing is
      legal, a `code_bug`/`env_drift` anchor names an **existing repository
      file**, and `REFUSED` is terminal without being mislabelled
      `contract_invalid`. The MUTATING arm is routed on that answer. Reading the
      class off the classify child's structured return instead would delete all
      four checks and route the mutating arm on an LLM's word.
    - `ci-fix` → `ci-conflicts`. The conflicted-file set is enumerated HERE, by
      the controller, and never taken from the rebase child's return. The
      question is asked through `review_fleet_unmerged_paths` →
      `code_fixer_contract.py list-ci-unmerged-paths`, so membership is decided
      by `_ci_is_unmerged_pair` — the same definition the rebase judge used when
      it called this a conflict, covering every unmerged status pair rather than
      the both-modified one alone (#398).
    - `ci-conflicts` → the push. `git add -- <paths>` (the `--` is load-bearing:
      a conflicted path named like a flag must not be read as one),
      `git rebase --continue` and the
      single `--force-with-lease` push all run here, against a lease this
      command captured before the dispatch. That push is **6c.4w.3**, and it is
      the ONE fence in Phase 3 that moves a remote ref: `fix_code` `APPLIED`,
      clean `REBASED` and `CONFLICT → all RESOLVED` all reach that same fence.
      Neither fixer agent pushes — both were written as preparers — so a
      terminal that does not reach 6c.4w.3 leaves its commits local and the next
      6c.1 PROBE re-selects the same red run off an unchanged remote head.

    **6c.2 MONITOR cannot become a stage.** `Date.now()` / `new Date()` throw
    inside a Workflow script and `now_iso` is frozen at preflight (RFC 0012
    DR-7), so the 480 s per-fence and `CI_MONITOR_DEADLINE_SEC` across-fence
    budgets are not expressible there. They are Bash-only by construction, not
    by preference.

    Under `CI_FIX_PHASE=0` (`--no-ci-fix`) PROBE, MONITOR and CLASSIFY still run
    for audit telemetry; only ROUTE, POST-FIX and HALT are skipped, and the
    outcome is forced to `green`/`halted`. That skip is **enforced in shell** at
    the head of the 6c.4 ROUTE fence — it used to be orchestrator prose with no
    reader anywhere in this file.

    ### 6c.1 PROBE — gh pr checks JSON probe

    Run authority is iteration-local. The caller never supplies `CI_RUN_ID`;
    each red probe selects it from the failed check row's immutable `link` and
    `event` fields. The selector applies the same drop-only-cancel grouping as
    `PROBE_VERDICT`, accepts only positive GitHub Actions run IDs for the current
    repository, prefers the PR-associated `pull_request` run over a same-head
    `push` sibling, and fails closed on an unknown event, external check, or
    cross-repository link.

    ```bash
    review_clear_ci_run_selection() {
      CI_RUN_ID=
      CI_RUN_EVENT=
      CI_RUN_CHECK_LINK=
      CI_RUN_CHECK_NAME=
      unset CI_CLASSIFICATION_HEAD_SHA CI_ROUTE_HEAD_SHA
    }
    review_select_failed_ci_run() {
      local probe_json="${@:1:1}" repo_slug="${@:2:1}"
      python3 -I -B - "$repo_slug" 3<<<"$probe_json" <<'PY'
import json,os,re,sys
from urllib.parse import urlsplit

repo_slug=sys.argv[1]
try:
    rows=json.load(os.fdopen(3))
except (json.JSONDecodeError,UnicodeDecodeError):
    raise SystemExit(2)
if not isinstance(rows,list) or not rows or not re.fullmatch(r'[^/\s]+/[^/\s]+',repo_slug):
    raise SystemExit(2)
known_buckets={'pass','skipping','pending','fail','cancel'}
groups={}
for row in rows:
    if not isinstance(row,dict):
        raise SystemExit(2)
    name=row.get('name')
    bucket=row.get('bucket')
    if not isinstance(name,str) or not name or not isinstance(bucket,str) or bucket not in known_buckets:
        raise SystemExit(2)
    groups.setdefault(name,[]).append(row)
kept=[]
for group in groups.values():
    kept.extend(
        [row for row in group if row['bucket']!='cancel']
        if any(row['bucket']!='cancel' for row in group)
        else group
    )
failed=[row for row in kept if row['bucket'] in {'fail','cancel'}]
if not failed:
    raise SystemExit(2)
candidates=[]
link_pattern=re.compile(r'^/([^/]+)/([^/]+)/actions/runs/([1-9][0-9]*)(?:/job/[1-9][0-9]*)?/?$')
for row in failed:
    event=row.get('event')
    link=row.get('link')
    workflow=row.get('workflow')
    if event not in {'pull_request','push'} or not isinstance(link,str) or not link:
        raise SystemExit(2)
    # `name` joins the control-character test because it LEAVES this function
    # now (#418): it is the fourth output column and then a single-line run-dir
    # carrier, so a TAB in it would split the column and a newline would
    # truncate the record -- both spelled as success.
    if not isinstance(workflow,str) or any(ord(char)<32 or ord(char)==127 for char in event+link+workflow+row['name']):
        raise SystemExit(2)
    parsed=urlsplit(link)
    match=link_pattern.fullmatch(parsed.path)
    if parsed.scheme!='https' or parsed.netloc.lower()!='github.com' or match is None:
        raise SystemExit(2)
    linked_slug=f'{match.group(1)}/{match.group(2)}'
    if linked_slug.lower()!=repo_slug.lower():
        raise SystemExit(2)
    run_id=match.group(3)
    candidates.append((0 if event=='pull_request' else 1,workflow,row['name'],int(run_id),event,link))
if not candidates:
    raise SystemExit(2)
# FOUR columns. The selected row's NAME is the only producer of `check_name`
# anywhere in this file: the REFUSED arm files it into a CRITICAL issue so a
# human can see WHICH check refused, and it consumed `${check_name:-unknown}`
# against a name nothing had ever bound (#418). It is already this function's
# tie-break key, so emitting it invents no second answer about which check
# failed.
_,_,check_name,run_id,event,link=min(candidates)
print(f'{run_id}\t{event}\t{link}\t{check_name}')
PY
    }
    review_clear_ci_run_selection
    ```

    **Pre-flight rate-limit check:** the floor `200` below is `CI_PROBE_RATE_LIMIT_FLOOR` (declared in `merge-pipeline/SKILL.md` Constants — kept numeric inline because bash does not dereference markdown constants).

    ```bash
    RATE_REMAINING="$(gh api rate_limit --jq .resources.core.remaining 2>/dev/null)"
    # Validate gh succeeded AND returned a non-empty integer before comparison —
    # a depleted/adversarial GH API budget MUST NOT silently downgrade to a
    # GREEN-eligible outcome. Empty string or non-numeric output triggers the
    # ci_probe_unreachable carve-out (omit phases.phase3 block; Step 7 proceeds
    # as if probe was unreachable, NOT as skipped_no_checks).
    if ! [[ "$RATE_REMAINING" =~ ^[0-9]+$ ]]; then
      audit ci_probe_unreachable subreason=rate_limit_query_failed
      # phases.phase3 block omitted entirely (carve-out); skip to Step 7
    elif [ "$RATE_REMAINING" -lt 200 ]; then
      audit ci_probe_unreachable subreason=rate_limit_low remaining=$RATE_REMAINING
      # Treat rate-limit-low as ci_probe_unreachable carve-out — NOT a
      # GREEN-eligible skipped_no_checks. A depleted GH API budget (potentially
      # adversarial in CI) silently passing trust-signal is the security
      # regression this guard prevents. phases.phase3 block omitted; Step 7
      # proceeds as if gh were unreachable.
      # skip remaining 6c sub-steps; jump to Step 7
    fi
    ```

    **Probe call:**

    **Field contract (gh ≥ 2.83.1):** `gh pr checks --json` exposes `name`, `state`, `bucket`, `link`, `event`, and `workflow` — there is **no** `status` and **no** `conclusion` field (those were removed upstream; reading them errors `unknown JSON field`). `bucket` is gh's own canonical categorization of `state`; `link` and `event` are the immutable controller inputs used to identify the exact Actions run when classification is required:

    | `bucket` | `state` values folded into it (gh `aggregateChecks`) | meaning here |
    |---|---|---|
    | `pass` | `SUCCESS` | green |
    | `skipping` | `SKIPPED`, `NEUTRAL` | green-eligible (skipped/neutral never block) |
    | `pending` | `EXPECTED`, `REQUESTED`, `WAITING`, `QUEUED`, `PENDING`, `IN_PROGRESS`, `STALE` | still running → MONITOR |
    | `fail` | `ERROR`, `FAILURE`, `TIMED_OUT`, `ACTION_REQUIRED` | red |
    | `cancel` | `CANCELLED` | red |

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    PROBE_JSON="$(gh pr checks "$PR_NUMBER" --json name,state,bucket,link,event,workflow 2>&1)" || PROBE_RC=$?
    # Validate PROBE_JSON is parseable JSON BEFORE the terminal-mapping
    # branches below try to interpret it. On gh failure (non-zero exit),
    # PROBE_JSON contains stderr text; jq parsing would silently produce
    # null and the prose below would treat it as "no checks" instead of
    # "probe failed" — masking a real outage as a GREEN-eligible skip.
    if [ "${PROBE_RC:-0}" -ne 0 ] && ! jq empty <<<"$PROBE_JSON" 2>/dev/null; then
      audit ci_probe_unreachable subreason=gh_failed_${PROBE_RC}
      # phases.phase3 block omitted entirely; skip to Step 7
    fi
    # Classify off bucket (gh's canonical state→bucket fold). A single jq pass
    # collapses the array to one of: empty / green / pending / red. Never
    # line-grep the buckets — parse as JSON.
    #
    # Benign-cancel same-name dedupe (#302), NARROWED to its motivating scope:
    # test.yml fires on BOTH push and pull_request, so one head SHA carries two
    # same-name check runs per job. Once #309's concurrency group lands, every
    # superseded push run reports bucket=cancel NEXT TO the authoritative
    # completed run — counting that benign cancel as red would manufacture a
    # permanent RED for every superseded push (which is why #309 MUST land after
    # this dedupe). group_by the check name (always present per the --json field
    # contract above); within a name-group, DROP the `cancel` rows IFF a non-cancel
    # sibling exists — a cancel only survives when it is the ONLY state for that
    # name (a genuine cancellation, still red). Everything else is kept verbatim
    # and fed UNCHANGED through the red>pending>green fold. This is deliberately
    # NOT best-state-wins: best-state-wins would let a completed push `pass`
    # launder its still-running (`pending`) or failed (`fail`) pull_request sibling
    # into the GREEN fast-path that skips MONITOR/CLASSIFY — re-opening the
    # GREEN-describes-code-CI-never-validated window this bundle exists to close
    # (the pull_request / merge-commit run is the authoritative one; a passed push
    # run must never mask it). Only the benign `cancel` row is laundered; fail and
    # pending stay un-maskable. `red` still outranks `pending` across the surviving
    # rows, and an unknown/missing bucket folds to red (fail-safe — never silently
    # green) so a broken gh field contract cannot downgrade the trust gate.
    PROBE_VERDICT="$(jq -r '
      def known_good: .bucket == "pass" or .bucket == "skipping";
      if (type != "array") or (length == 0) then "empty"
      else
        [ group_by(.name)[]
          | (if any(.[]; .bucket != "cancel") then map(select(.bucket != "cancel")) else . end)
          | .[] ] as $kept
        | if   any($kept[]; .bucket == "fail" or .bucket == "cancel") then "red"
          elif any($kept[]; .bucket == "pending")                     then "pending"
          elif all($kept[]; known_good)                               then "green"
          else "red" end
      end
    ' <<<"$PROBE_JSON" 2>/dev/null)"
    # THE VERDICT CROSSES ON DISK (#418). 6c.4 ROUTE's probe-only (`--no-ci-fix`)
    # arm is a DIFFERENT harness shell, so its `${PROBE_VERDICT:-unknown}` read
    # the EMPTY string on every run: it audited `ci_probe_only_skipped
    # state=unknown` and, comparing "" against `green`, forced OUTCOME=halted
    # even when this very jq had just answered `green`. Same run-dir carrier
    # idiom as ci-push-target.tsv / ci-fix-phase.txt, and the recorded token is
    # this jq's own output verbatim so no second vocabulary appears.
    #
    # The plugin root is re-derived here the way 6c.4's same-repository push
    # gate re-derives it: the setup fence's binding is a SHELL variable and this
    # is a different shell, so a fence that newly depends on a library must
    # resolve the root itself or it fails where nothing failed before.
    # THE CARRY MUST NOT OUTRANK THE CARVE-OUT. The `gh`-unreachable and
    # rate-limit-low branches above do NOT exit this fence -- they audit
    # `ci_probe_unreachable` and the run proceeds to Step 7 with the phases.phase3
    # block omitted. The jq then leaves PROBE_VERDICT empty (it parsed stderr, not
    # checks), and an unconditional persist-or-halt here would convert that
    # documented carve-out into a phase halt: a `gh` outage would go from "Phase 3
    # is omitted" to "Phase 3 failed", on a fence that observed nothing. So the
    # write is attempted only when there IS a verdict in the documented
    # vocabulary; anything else is recorded as a TYPED miss and left to ROUTE,
    # whose reader halts if that phase ever runs.
    case "${PROBE_VERDICT:-}" in
      empty | green | pending | red)
        CI_PROBE_VERDICT_RUN_DIR=
        if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
          CI_PROBE_VERDICT_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || CI_PROBE_VERDICT_RUN_DIR=
        fi
        if [ -n "$CI_PROBE_VERDICT_RUN_DIR" ]; then
          # A run dir that IS bound, with a verdict in hand, and still cannot take
          # the carrier halts HERE: the gh call has already been spent, and the
          # only reader downstream is a mutating phase that must not guess.
          if ! review_fleet_write_ci_probe_verdict "$CI_PROBE_VERDICT_RUN_DIR/ci-probe-verdict.txt" "$PROBE_VERDICT"; then
            echo "error: /uberdev:review-pr — Phase 3 classified the probe as '$PROBE_VERDICT' but could not persist it to $CI_PROBE_VERDICT_RUN_DIR/ci-probe-verdict.txt; refusing to hand ROUTE a verdict it cannot read." >&2
            audit ci_phase_outcome data.outcome=halted data.subreason=ci_probe_verdict_uncarried
            OUTCOME=halted
            exit 1
          fi
        else
          # No run dir bound => this fence is running OUTSIDE a Phase 3 run. The
          # verdict is still bound for a same-shell caller and the miss is TYPED
          # rather than silent; ROUTE's reader then halts because the carrier is
          # absent, so the failure is closed either way.
          audit ci_probe_verdict_uncarried data.reason=no_run_dir
        fi
        ;;
      *)
        audit ci_probe_verdict_uncarried data.reason=no_verdict
        ;;
    esac
    ```

    **Settle window for empty-checks (#302).** A JUST-pushed head (the Step 6a post-fixer push, or any fresh PR push) reports "no checks" for the first ~10–30 s while GitHub fans the workflow runs out — mapping that window straight to `skipped_no_checks` makes a GREEN-eligible outcome out of CI that was about to start. When the probe resolves `empty` (the jq `empty` verdict OR gh's `no checks reported on the` stderr signature) AND the head commit is younger than the settle threshold, re-probe before accepting `skipped_no_checks`. Literals: `CI_SETTLE_AGE_SEC = 120` and `CI_SETTLE_REPROBES = 3` (declared HERE — `/review-pr`-owned settle constants, kept numeric inline like the other 6c literals); re-probe interval 30 s (mirrors `CI_WATCH_INTERVAL_SEC`).

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    if [ "$PROBE_VERDICT" = "empty" ] || printf '%s' "$PROBE_JSON" | grep -q 'no checks reported on the'; then
      HEAD_AGE_SEC=$(( $(date +%s) - $(git show -s --format=%ct HEAD) ))
      SETTLE_REPROBES_USED=0
      # Re-probe while: still empty AND head younger than CI_SETTLE_AGE_SEC (120)
      # AND fewer than CI_SETTLE_REPROBES (3) re-probes used. Each pass sleeps 30s,
      # re-runs the PROBE call + PROBE_VERDICT classification above verbatim, and
      # audits the attempt. An old head (>= 120s) with no checks is genuinely
      # checks-unconfigured — fall through to skipped_no_checks immediately.
      while { [ "$PROBE_VERDICT" = "empty" ] || printf '%s' "$PROBE_JSON" | grep -q 'no checks reported on the'; } \
            && [ "$HEAD_AGE_SEC" -lt 120 ] \
            && [ "$SETTLE_REPROBES_USED" -lt 3 ]; do
        sleep 30
        SETTLE_REPROBES_USED=$((SETTLE_REPROBES_USED + 1))
        # Re-run the 6c.1 PROBE call and PROBE_VERDICT jq classification above
        # (same command, same jq program — re-binds PROBE_JSON + PROBE_VERDICT).
        audit ci_probe_started subreason=settle_reprobe attempt=$SETTLE_REPROBES_USED head_age_sec=$HEAD_AGE_SEC
        HEAD_AGE_SEC=$(( $(date +%s) - $(git show -s --format=%ct HEAD) ))
      done
      # Only an empty verdict that SURVIVED the settle window (window expired or
      # re-probes exhausted) maps to skipped_no_checks in the terminal table below;
      # carry settle_reprobes_used + head_age_sec in the ci_probe_skipped_no_checks
      # audit payload for post-mortem.
      #
      # A re-probe REBINDS the verdict, so the carrier written above is now the
      # pre-settle answer. Refresh it here, inside the arm that owns the
      # re-probe, and only from a verdict this fence actually re-derived: the
      # write sits INSIDE the settle arm, which a fresh shell never enters (the
      # guard's own `$PROBE_VERDICT` is unbound there -- false under the arm's
      # own terms, and a hard abort under `set -u`). So it cannot overwrite a
      # good carrier with an empty one, and the writer refuses anything outside
      # the four documented tokens regardless.
      # Same vocabulary gate as the initial write, and for the same reason: a
      # re-probe can itself hit the `gh` outage the carve-out covers, and a
      # settle window is not a licence to turn that into a phase halt.
      case "${PROBE_VERDICT:-}" in
        empty | green | pending | red)
          if [ -n "${RESEARCH_DIR_ABS:-}" ] && CI_SETTLE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)"; then
            if ! review_fleet_write_ci_probe_verdict "$CI_SETTLE_RUN_DIR/ci-probe-verdict.txt" "$PROBE_VERDICT"; then
              echo "error: /uberdev:review-pr — Phase 3 re-probed to '$PROBE_VERDICT' but could not refresh $CI_SETTLE_RUN_DIR/ci-probe-verdict.txt." >&2
              audit ci_phase_outcome data.outcome=halted data.subreason=ci_probe_verdict_uncarried
              OUTCOME=halted
              exit 1
            fi
          else
            audit ci_probe_verdict_uncarried data.reason=no_run_dir
          fi
          ;;
        *)
          audit ci_probe_verdict_uncarried data.reason=no_verdict
          ;;
      esac
    fi
    ```

    Terminal mappings (parsed as JSON; never line-grepped; bucket conditions apply AFTER the same-name benign-cancel dedupe above — only cancel rows with a non-cancel sibling are dropped; fail/pending are never masked):

    | `PROBE_JSON` content | `PROBE_VERDICT` | OUTCOME | Audit event |
    |---|---|---|---|
    | stderr matches `no checks reported on the` (or empty `[]`) AND the settle window above is exhausted (head age ≥ 120 s, or 3 re-probes used) | `empty` | `skipped_no_checks` | `ci_probe_skipped_no_checks` (payload carries `settle_reprobes_used` + `head_age_sec`) |
    | all deduped names `bucket ∈ {pass, skipping}` | `green` | `green` or `green_after_fix` (`review_fleet_ci_green_outcome`) | `ci_phase_outcome` (terminal, payload `data.outcome=$OUTCOME` — fast-path skip past MONITOR/CLASSIFY) |
    | any deduped name `bucket == pending` (and none `fail`/`cancel`) | `pending` | (proceed to MONITOR) | `ci_probe_started` |
    | any deduped name `bucket ∈ {fail, cancel}` | `red` | (proceed to MONITOR + classify if all settled) | `ci_probe_started` |
    | `gh` exit non-zero AND no usable JSON | — | (carve-out — `phases.phase3` block omitted from audit JSON; Step 7 proceeds as if `OUTCOME=skipped_no_checks`) | `ci_probe_unreachable` |

    The `gh pr checks` output MUST be parsed as JSON, never line-grepped.

    The `green` row above is the only terminal in this table, and it used to be
    prose — a table cell reading `green`. Prose cannot assign an `OUTCOME`, and
    this is the arm a **post-fix re-probe** most often takes: after a fix push
    the flow re-enters at Step 4, Phase 1 re-approves, control returns here, and
    the fast path skips MONITOR entirely. So the terminal most likely to be
    looking at an autopilot-rewritten head was the one with no executable
    terminal at all (#400).

    ```bash uberdev-executable origin=review-pr
    # BEGIN ci-probe-green-terminal-v1
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    # Everything this fence needs is established INSIDE the green arm, not at the
    # top: `pending` and `red` are non-terminal here (they proceed to MONITOR,
    # which establishes its own), so demanding RUN_ID and a resolvable run dir on
    # those paths would be a hard failure in a fence that had no question to
    # answer. 6c.2 validates eagerly for the opposite reason -- it is about to
    # spend up to 480 s watching CI, and finding out afterwards is worse.
    if [ "${PROBE_VERDICT:-}" = green ]; then
      # The ledger that separates `green` from `green_after_fix` lives on disk
      # under this run's research dir, and the fence prologue above has already
      # resolved that dir with `cd … && pwd -P` -- so this is a rename, not a
      # second path algebra. NEVER a second uberdev_command_workspace_prepare:
      # see the note in 6c.2.
      #
      # The RUN_ID guard that used to live here is now unreachable-by-construction:
      # review_fleet_rehydrate refuses the fence outright when it can neither
      # carry nor recover a run identity, so an empty RUN_ID can no longer
      # resolve the ledger under a nonexistent path and have "does not exist"
      # answered as `green`.
      CI_PROBE_RUN_DIR="$RESEARCH_DIR_ABS"
      OUTCOME="$(review_fleet_ci_green_outcome "$CI_PROBE_RUN_DIR" "${CI_FIX_PHASE:-1}")" || {
        # An unreadable ledger is NOT "no fixes" -- defaulting here reports a
        # force-pushed autopilot head as a clean one. Halt instead.
        audit ci_phase_outcome data.outcome=halted data.subreason=ci_loop_state_unreadable
        OUTCOME=halted
        exit 1
      }
      audit ci_phase_outcome data.outcome="$OUTCOME"
    fi
    # END ci-probe-green-terminal-v1
    ```

    ### 6c.2 MONITOR — bounded `gh pr checks --watch` passes

    The literals `1200` and `30` below are `CI_MONITOR_TIMEOUT_SEC` and `CI_WATCH_INTERVAL_SEC` respectively (declared in `merge-pipeline/SKILL.md` Constants — kept numeric inline because bash does not dereference markdown constants). `CI_MONITOR_PASS_SEC` (`240`), `CI_MONITOR_FENCE_SEC` (`480`), `CI_MONITOR_MIN_PASS_SEC` (`30`) and `CI_MONITOR_PASSES_MAX` (`48`) are declared HERE — `/review-pr`-owned monitor constants, exactly like the `CI_SETTLE_AGE_SEC` / `CI_SETTLE_REPROBES` settle literals in 6c.1 above.

    **Why the watch is split into passes AND across fences (#302).** Every `bash` block in this command is executed as ONE harness call, and that harness caps a single call at `600000` ms. A single `timeout 1200 gh pr checks --watch` therefore never reaches its own `timeout`: on a genuinely slow CI the *harness* kills the call at ≤ 600 s and reports a code that is neither gh's `0` nor its documented `8`. Mapping "non-zero, non-8" straight to red then dispatched `ci-failure-classifier` and `ci-code-fixer` against CI that had not failed — a fabricated red on every long run.

    Bounding each `timeout` is only half of that fix. A loop that *accumulates* 1200 s of passes still spends them inside one harness call, so on the very CI this targets — anything slower than ~600 s — the harness still kills the fence, and because `CI_MONITOR_VERDICT` and the elapsed counter are fence-scoped shell state the kill destroys them too. The `pending → OUTCOME=halted` arm would then be unreachable in exactly the scenario it exists for. So the budget is enforced in two nested layers:

    - **Per fence:** `CI_MONITOR_FENCE_SEC` = 480 s (two 240 s passes), plus at most one `CI_MONITOR_MIN_PASS_SEC` floor sleep — a hard ceiling of ~510 s, comfortably inside the 600 s harness cap. No harness kill, ever.
    - **Across fences:** the 1200 s total travels as an absolute `CI_MONITOR_DEADLINE_SEC` and a running `CI_MONITOR_PASSES_USED`, both printed on the `resume` path and rebound by the orchestrator on re-entry. That is the same cross-fence carry `RUN_ID` uses, and it is immune to the fence-scoped-state class because nothing survives *inside* the shell.

    Three fences (480 + 480 + 240) therefore spend the full 20 minutes as at most five watch passes, and "the budget ran out" stays a distinct, first-class outcome instead of being laundered into "a check failed" or lost to a harness kill.

    ```bash
    # BEGIN ci-monitor-bounded-loop-v1
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    # Fence-scoped state, re-established HERE. Nothing survives from 6c.1, and
    # the ledger that separates `green` from `green_after_fix` lives on disk
    # under this run's research dir -- which the prologue above resolved with
    # `cd … && pwd -P` and cross-checked against the run's own workspace
    # descriptor. Never a second uberdev_command_workspace_prepare: without
    # RUN_ID that re-mints a different ID off the post-fix HEAD and forks
    # .uberdev/research/<RUN_ID>; with RUN_ID it hits the single-shot
    # reservation and exits 2. A garbage or absent RUN_ID is a HARD failure
    # inside review_fleet_rehydrate, before this line runs, so it can no longer
    # degrade into a path that merely fails to exist -- whose answer would be
    # the silently-wrong `green`.
    CI_MONITOR_RUN_DIR="$RESEARCH_DIR_ABS"
    CI_MONITOR_PASS_SEC=240          # one watch pass
    CI_MONITOR_FENCE_SEC=480         # this FENCE's share of the budget (2 passes)
    CI_MONITOR_MIN_PASS_SEC=30       # = CI_WATCH_INTERVAL_SEC; minimum-progress floor
    CI_MONITOR_PASSES_MAX=48         # clock-independent backstop (1200/30 = 40 real passes)
    CI_MONITOR_STARTED_SEC="$(date +%s)"
    # Cross-fence carry. The 20-minute budget outlives any single harness call,
    # so it is an absolute DEADLINE plus a pass count that this fence RECEIVES
    # and RE-EMITS — never a fence-local accumulator that a harness kill would
    # silently destroy along with the verdict it was supposed to produce.
    CI_MONITOR_DEADLINE_SEC="${CI_MONITOR_DEADLINE_SEC:-$(( CI_MONITOR_STARTED_SEC + 1200 ))}"
    CI_MONITOR_PASSES_USED="${CI_MONITOR_PASSES_USED:-0}"
    CI_MONITOR_FENCE_DEADLINE_SEC=$(( CI_MONITOR_STARTED_SEC + CI_MONITOR_FENCE_SEC ))
    if [ "$CI_MONITOR_FENCE_DEADLINE_SEC" -gt "$CI_MONITOR_DEADLINE_SEC" ]; then
      CI_MONITOR_FENCE_DEADLINE_SEC="$CI_MONITOR_DEADLINE_SEC"
    fi
    CI_MONITOR_VERDICT=pending       # pending | green | red | resume
    CI_MONITOR_RC=8
    while : ; do
      CI_MONITOR_NOW_SEC="$(date +%s)"
      # Total budget spent, or the backstop tripped → terminal, halted.
      if [ "$CI_MONITOR_NOW_SEC" -ge "$CI_MONITOR_DEADLINE_SEC" ] || \
         [ "$CI_MONITOR_PASSES_USED" -ge "$CI_MONITOR_PASSES_MAX" ]; then
        CI_MONITOR_VERDICT=pending
        break
      fi
      # This fence's share is spent but the budget is not → hand back, don't halt.
      if [ "$CI_MONITOR_NOW_SEC" -ge "$CI_MONITOR_FENCE_DEADLINE_SEC" ]; then
        CI_MONITOR_VERDICT=resume
        break
      fi
      CI_MONITOR_WINDOW_SEC=$(( CI_MONITOR_FENCE_DEADLINE_SEC - CI_MONITOR_NOW_SEC ))
      if [ "$CI_MONITOR_WINDOW_SEC" -gt "$CI_MONITOR_PASS_SEC" ]; then
        CI_MONITOR_WINDOW_SEC="$CI_MONITOR_PASS_SEC"
      fi
      CI_MONITOR_RC=0
      timeout "$CI_MONITOR_WINDOW_SEC" gh pr checks "$PR_NUMBER" --watch --interval 30 || CI_MONITOR_RC=$?
      CI_MONITOR_PASSES_USED=$(( CI_MONITOR_PASSES_USED + 1 ))
      CI_MONITOR_PASS_ELAPSED_SEC=$(( $(date +%s) - CI_MONITOR_NOW_SEC ))
      if [ "$CI_MONITOR_RC" -eq 0 ]; then
        CI_MONITOR_VERDICT=green
        break
      fi
      # 8 is gh's documented "Checks pending" code. 124 is `timeout`'s own kill
      # code, and a pass that burned its FULL window is indistinguishable from
      # that truncation (a harness kill reports its own code, not 124). All three
      # mean "still running when we stopped watching" — pending, NEVER red. Only
      # a non-zero, non-8 code that came back EARLY is gh reporting a check that
      # actually failed.
      # Written as a full `if` rather than `[ … ] && break`: the short-circuit
      # form leaves the statement at rc 1 whenever the test is false, which
      # aborts the whole fence under `set -e`.
      if [ "$CI_MONITOR_RC" -ne 8 ] && [ "$CI_MONITOR_RC" -ne 124 ] && \
         [ "$CI_MONITOR_PASS_ELAPSED_SEC" -lt "$CI_MONITOR_WINDOW_SEC" ]; then
        CI_MONITOR_VERDICT=red
        break
      fi
      # Minimum-progress floor. A pass that returns in ~0s (gh handing back 8
      # immediately, a watch that finds nothing to watch) otherwise re-enters
      # with zero accumulated wall clock and no sleep — an unbounded hot loop
      # against the GitHub API. Sleeping the remainder makes every pass advance
      # the budget by at least CI_WATCH_INTERVAL_SEC.
      if [ "$CI_MONITOR_PASS_ELAPSED_SEC" -lt "$CI_MONITOR_MIN_PASS_SEC" ]; then
        sleep $(( CI_MONITOR_MIN_PASS_SEC - CI_MONITOR_PASS_ELAPSED_SEC ))
      fi
    done
    # Elapsed is derived from the shared deadline, so it stays a TOTAL across
    # every fence rather than restarting at 0 on each re-entry.
    CI_MONITOR_ELAPSED_SEC=$(( 1200 - ( CI_MONITOR_DEADLINE_SEC - $(date +%s) ) ))
    case "$CI_MONITOR_VERDICT" in
      green)
        # WHICH green. The watch reports only that CI passed; whether an
        # autopilot rewrote the head it passed on is recorded in the fix-push
        # ledger, which this fence never wrote and cannot infer. One derivation,
        # in the library, called by every green terminal (#400).
        OUTCOME="$(review_fleet_ci_green_outcome "$CI_MONITOR_RUN_DIR" "${CI_FIX_PHASE:-1}")" || {
          # An unreadable ledger is NOT "no fixes". Defaulting here would report
          # a force-pushed autopilot head as a clean one; halt instead.
          audit ci_phase_outcome data.outcome=halted data.subreason=ci_loop_state_unreadable
          OUTCOME=halted
          exit 1
        }
        audit ci_monitor_green outcome=$OUTCOME passes=$CI_MONITOR_PASSES_USED elapsed_sec=$CI_MONITOR_ELAPSED_SEC
        ;;
      red)
        audit ci_monitor_red passes=$CI_MONITOR_PASSES_USED elapsed_sec=$CI_MONITOR_ELAPSED_SEC rc=$CI_MONITOR_RC
        ;;
      resume)
        # Deliberately NOT an audit event and NOT an OUTCOME: nothing terminal
        # happened. Recording a phase outcome here would report a CI verdict the
        # monitor never reached. The carry below is the whole handoff.
        echo "notice: CI monitor fence budget spent, total budget remains — re-run this fence with CI_MONITOR_DEADLINE_SEC=$CI_MONITOR_DEADLINE_SEC CI_MONITOR_PASSES_USED=$CI_MONITOR_PASSES_USED" >&2
        ;;
      *)
        OUTCOME=halted
        audit ci_monitor_timeout subreason=monitor_timeout passes=$CI_MONITOR_PASSES_USED elapsed_sec=$CI_MONITOR_ELAPSED_SEC
        ;;
    esac
    # END ci-monitor-bounded-loop-v1
    ```

    **When `CI_MONITOR_VERDICT=resume`, the fence is NOT done.** Re-run this
    exact `bash` block as a NEW harness call, with `CI_MONITOR_DEADLINE_SEC` and
    `CI_MONITOR_PASSES_USED` bound to the two values the `notice:` line printed.
    Repeat until the block returns `green`, `red`, or `pending`. Do not fall
    through to CLASSIFY, do not set `OUTCOME`, and do not anchor a trust trail
    on a `resume` — it carries no verdict.

    **`--watch` takes NO `--json`:** gh refuses `--watch` together with `--json` (`cannot use --watch with --json flag`, verified live on gh 2.83.1) — that is why the field list is absent here even though 6c.1 PROBE reads `--json name,state,bucket,link,event,workflow`. MONITOR keys off the **exit code** (gh's documented `gh pr checks` contract), not parsed JSON, so it needs no field projection. Wall-clock cap: **20 minutes** total (`1200` = `CI_MONITOR_TIMEOUT_SEC`), spent as at most five `CI_MONITOR_PASS_SEC`-bounded passes across at most three `CI_MONITOR_FENCE_SEC`-bounded fences. The watch terminates on its own once every check leaves the `pending` bucket. Verdict mapping:

    | `CI_MONITOR_VERDICT` | how it is reached | OUTCOME | Audit event |
    |---|---|---|---|
    | `green` | any pass exits `0` — all checks green | `green` | `ci_monitor_green` |
    | `red` | a pass exits non-zero, non-8 **and returned before consuming its full `CI_MONITOR_WINDOW_SEC` window** | (proceed to CLASSIFY) | `ci_monitor_red` |
    | `resume` | this fence's `CI_MONITOR_FENCE_SEC` share is spent and the 1200 s total is not | **none — not terminal** | none (`notice:` carry line only) |
    | `pending` | the 1200 s total was exhausted (or `CI_MONITOR_PASSES_MAX` tripped) while every pass reported `8`, `124`, or a full-window truncation | `halted` | `ci_monitor_timeout` (`data.subreason=monitor_timeout`) |

    `resume` is the only non-terminal verdict; it emits no audit event precisely because no phase outcome has occurred yet. `halted` is the canonical `CI_OUTCOME_ENUM` member, not a `halted_timeout` synthetic. `--fail-fast` is **NOT** used (the classifier needs the complete failure picture). The 30-second `--interval` floor (`CI_WATCH_INTERVAL_SEC`) is intentional (rate-limit guard), and `CI_MONITOR_MIN_PASS_SEC` re-uses that same 30 s as the loop's minimum-progress floor so a pass that returns instantly cannot spin the loop against the API. `CI_MONITOR_PASSES_MAX` is the clock-independent backstop underneath it: even if `date` never advanced, the loop cannot exceed 48 watch invocations.

    On a `red` MONITOR verdict, refresh the check projection before
    CLASSIFY. A pending-only initial probe can become red while `--watch` is
    running; retaining the pre-watch JSON would leave no failed row from which
    to derive the authoritative run. The refreshed projection uses the exact
    6c.1 field set and replaces (never appends to) `PROBE_JSON`:

    ```bash
    unset PROBE_RC
    PROBE_JSON="$(gh pr checks "$PR_NUMBER" --json name,state,bucket,link,event,workflow 2>&1)" || PROBE_RC=$?
    if [ "${PROBE_RC:-0}" -ne 0 ] && ! jq empty <<<"$PROBE_JSON" 2>/dev/null; then
      # MONITOR has already established red CI. That evidence is monotonic:
      # a later metadata outage cannot reuse the initial-probe unreachable
      # carve-out or omit Phase 3. Preserve status=ran with a halted outcome.
      OUTCOME=halted
      audit ci_phase_outcome outcome=halted subreason=post_monitor_refresh_failed
      exit 1
    fi
    ```

    ### 6c.3 CLASSIFY — routed ci-failure-classifier

    First derive the exact failed Actions run from the refreshed check
    projection. `CI_RUN_ID` is never accepted from setup/environment state:

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    if IFS=$'\t' read -r CI_RUN_ID CI_RUN_EVENT CI_RUN_CHECK_LINK CI_RUN_CHECK_NAME < <(
        review_select_failed_ci_run "$PROBE_JSON" "$REVIEW_REPO_SLUG"
      ) && [[ "$CI_RUN_ID" =~ ^[1-9][0-9]*$ ]] \
        && [[ "$CI_RUN_EVENT" =~ ^(pull_request|push)$ ]] \
        && [ -n "$CI_RUN_CHECK_LINK" ] && [ -n "$CI_RUN_CHECK_NAME" ]; then
      :
    else
      review_clear_ci_run_selection
      audit ci_phase_outcome outcome=halted subreason=classification_run_selection_invalid
      OUTCOME=halted
      exit 1
    fi
    # THE NAME CROSSES ON DISK (#418). The REFUSED arm's aggregate writer is
    # thousands of lines and many shells away, and it consumed
    # `${check_name:-unknown}` -- a name NOTHING in this file had ever bound, so
    # every CI-refusal issue the autopilot filed named `unknown` as the check
    # that failed. Same run-dir carrier idiom as ci-push-target.tsv /
    # ci-fix-phase.txt / ci-fixer-terminal.json, written by the fence that binds
    # the value.
    #
    # A resolved answer this run PAID a gh call for and cannot persist halts
    # here, not at the reader: the alternative is discovering it after the fixer
    # has already refused, when the only remaining move is to file a CRITICAL
    # issue that names no check.
    #
    # `[ -n … ]` BEFORE the `cd`, never `cd "$RESEARCH_DIR_ABS"` alone: these
    # fences run under /bin/zsh, where `cd ""` SUCCEEDS and leaves the shell in
    # the current directory (bash refuses it as a null directory). Unguarded,
    # an unbound run dir would silently write the carrier into the repository
    # working tree — untracked residue the mutating verbs then refuse over, from
    # a fence that reported success.
    CI_SELECTION_RUN_DIR=
    if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
      CI_SELECTION_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || CI_SELECTION_RUN_DIR=
    fi
    [ -n "$CI_SELECTION_RUN_DIR" ] || {
      echo "error: /uberdev:review-pr — Phase 3 CLASSIFY cannot resolve the run directory to record the failed check's name." >&2
      audit ci_phase_outcome data.outcome=halted data.subreason=ci_check_name_uncarried
      OUTCOME=halted
      exit 1
    }
    review_fleet_write_ci_check_name "$CI_SELECTION_RUN_DIR/ci-check-name.txt" "$CI_RUN_CHECK_NAME" || {
      echo "error: /uberdev:review-pr — Phase 3 selected failed check '$CI_RUN_CHECK_NAME' but could not persist it to $CI_SELECTION_RUN_DIR/ci-check-name.txt; refusing to file a refusal issue that cannot name the check." >&2
      audit ci_phase_outcome data.outcome=halted data.subreason=ci_check_name_uncarried
      OUTCOME=halted
      exit 1
    }
    ```

    Then bind the classifier to one immutable PR-head identity before reading
    the selected run's log or dispatching the child. The local worktree HEAD and
    live PR head must always identify the same full SHA. Run identity is
    **event-aware**:

    - `push`: the selected run's repository, branch, event, and `head_sha` must
      directly equal the live PR-head identity.
    - `pull_request`: GitHub may report a synthetic merge `head_sha`; do not
      compare it directly to the branch SHA. Instead, require the run's
      `pull_requests` metadata to contain `PR_NUMBER` with the exact live
      `head.sha` and `head.ref`, plus matching repository/event/branch fields.

    An unknown event, stale association, different PR/repository, or moved
    local/live head fails closed. `review_capture_ci_classification_head` emits
    only the branch-head SHA on success or one stable bounded failure class on
    failure; it never relays `git`/`gh` diagnostics.

    ```bash
    review_capture_ci_classification_head() {
      local expected_head="${@:1:1}" local_head live_identity live_head live_branch
      local target_head run_json run_failure
      local_head="$(git -C "$WORKTREE_ROOT" rev-parse HEAD 2>/dev/null)" || {
        printf 'classification_local_head_query_failed'
        return 1
      }
      live_identity="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" \
        --json headRefOid,headRefName \
        --jq '"\(.headRefOid)\t\(.headRefName)"' 2>/dev/null)" || {
        printf 'classification_live_head_query_failed'
        return 1
      }
      IFS=$'\t' read -r live_head live_branch <<<"$live_identity"
      if [[ ! "$local_head" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'classification_local_head_malformed'
        return 1
      fi
      if [[ ! "$live_head" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'classification_live_head_malformed'
        return 1
      fi
      if [ -z "$live_branch" ]; then
        printf 'classification_live_branch_malformed'
        return 1
      fi
      if [[ ! "$CI_RUN_ID" =~ ^[1-9][0-9]*$ ]]; then
        printf 'classification_run_id_malformed'
        return 1
      fi
      if [[ ! "$CI_RUN_EVENT" =~ ^(pull_request|push)$ ]]; then
        printf 'classification_run_event_malformed'
        return 1
      fi
      if [ -n "$expected_head" ]; then
        if [[ ! "$expected_head" =~ ^[0-9a-f]{40}$ ]]; then
          printf 'classification_expected_head_malformed'
          return 1
        fi
        if [ "$local_head" != "$expected_head" ]; then
          printf 'classification_local_head_moved'
          return 1
        fi
        if [ "$live_head" != "$expected_head" ]; then
          printf 'classification_live_head_moved'
          return 1
        fi
        target_head="$expected_head"
      else
        if [ "$live_head" != "$local_head" ]; then
          printf 'classification_live_head_mismatch'
          return 1
        fi
        target_head="$local_head"
      fi
      run_json="$(gh api "repos/$REVIEW_REPO_SLUG/actions/runs/$CI_RUN_ID" 2>/dev/null)" || {
        printf 'classification_run_metadata_query_failed'
        return 1
      }
      if run_failure="$(
        python3 -I -B - "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$CI_RUN_ID" \
          "$CI_RUN_EVENT" "$target_head" "$live_branch" \
          "$([ -n "$expected_head" ] && printf moved || printf mismatch)" \
          3<<<"$run_json" 2>/dev/null <<'PY'
import json,os,re,sys
repo_slug,pr_number,run_id,selected_event,target_head,live_branch,phase=sys.argv[1:]
def fail(reason):
    print(reason,end='')
    raise SystemExit(2)
try:
    value=json.load(os.fdopen(3))
except (json.JSONDecodeError,UnicodeDecodeError,OSError):
    fail('classification_run_metadata_malformed')
if not isinstance(value,dict):
    fail('classification_run_metadata_malformed')
if value.get('id')!=int(run_id):
    fail('classification_run_id_mismatch')
repository=value.get('repository')
if not isinstance(repository,dict) or str(repository.get('full_name','')).lower()!=repo_slug.lower():
    fail('classification_run_repository_mismatch')
if value.get('event')!=selected_event:
    fail('classification_run_event_mismatch')
run_head=value.get('head_sha')
run_branch=value.get('head_branch')
if not isinstance(run_head,str) or re.fullmatch(r'[0-9a-f]{40}',run_head) is None:
    fail('classification_run_head_malformed')
suffix='moved' if phase=='moved' else 'mismatch'
if selected_event=='push':
    if run_branch!=live_branch or run_head!=target_head:
        fail(f'classification_run_head_{suffix}')
elif selected_event=='pull_request':
    # pull_requests must contain PR_NUMBER at the exact live branch-head.
    associations=value.get('pull_requests')
    if not isinstance(associations,list):
        fail('classification_run_metadata_malformed')
    matched=False
    for association in associations:
        if not isinstance(association,dict) or association.get('number')!=int(pr_number):
            continue
        head=association.get('head')
        if isinstance(head,dict) and head.get('sha')==target_head and head.get('ref')==live_branch:
            matched=True
            break
    if run_branch!=live_branch or not matched:
        fail(f'classification_run_pr_{suffix}')
else:
    fail('classification_run_event_mismatch')
PY
      )"; then
        :
      else
        printf '%s' "${run_failure:-classification_run_metadata_malformed}"
        return 1
      fi
      printf '%s' "$local_head"
    }
    if CI_CLASSIFICATION_HEAD_SHA="$(review_capture_ci_classification_head)"; then
      :
    else
      # NEVER an empty subreason. The helper prints one bounded failure class on
      # every refusal it OWNS, but a helper that is missing, killed, or dies
      # before its first `printf` yields an empty capture -- and the audit row
      # then names no cause at all, which is strictly worse than no row.
      CI_CLASSIFICATION_HEAD_FAILURE="${CI_CLASSIFICATION_HEAD_SHA:-classification_head_probe_unavailable}"
      audit ci_phase_outcome outcome=halted subreason="$CI_CLASSIFICATION_HEAD_FAILURE"
      OUTCOME=halted
      exit 1
    fi
    ```

    Read only failed-job logs via
    `gh run view <run-id> --repo <owner/repo> --log-failed`. Pipe that stream
    directly into one bounded transformer: there is no raw staging pathname,
    producer receipt, reopen, or cleanup unlink. The transformer reads at most
    49,153 bytes, validates strict UTF-8 and the selected PR/run/head identity,
    escapes `<` and `&`, then emits the canonical inline input JSON. The exact
    `log_content` MUST be wrapped in:

    ```
    <external-untrusted-input source="github-actions-log-pr-<N>-run-<id>">
    …bounded failed-job log content…
    </external-untrusted-input>
    ```

    The immutable classifier authority is the exact tuple
    (`pr_number`, `run_id`, `head_sha`, `log_content`, `log_sha256`).
    `log_sha256` covers the exact UTF-8 bytes the child receives. The builder,
    handoff publisher, and handoff consumer each independently require the
    envelope's PR/run identity and digest to match, and each enforces the
    49,152-byte serialized input ceiling.

    Capture and dispatch the classifier:

    ```bash
    review_json_member() {
      [ "$#" -eq 2 ] || return 2
      python3 -I -B -c '
import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
print(json.dumps(value[sys.argv[2]],separators=(",",":")),end="")
' "${@:1:1}" "${@:2:1}"
    }
    review_capture_ci_log_authority() {
      (
        set -o pipefail
        gh run view "$CI_RUN_ID" --repo "$REVIEW_REPO_SLUG" --log-failed 2>/dev/null \
          | python3 -I -B -c '
import hashlib,json,re,sys
pr_number,run_id,head_sha=sys.argv[1:]
def fail(reason,code=2):
    print(reason,end="")
    raise SystemExit(code)
if (re.fullmatch(r"[1-9][0-9]*",pr_number) is None
        or re.fullmatch(r"[1-9][0-9]*",run_id) is None
        or re.fullmatch(r"[0-9a-f]{40}",head_sha) is None):
    fail("classification_log_identity_mismatch")
chunks=[]
total=0
while total<=49152:
    chunk=sys.stdin.buffer.read(min(8192,49153-total))
    if not chunk:
        break
    chunks.append(chunk)
    total+=len(chunk)
    if total>49152:
        fail("classification_log_input_oversize",3)
raw=b"".join(chunks)
if not raw:
    fail("classification_log_capture_invalid")
try:
    body=raw.decode("utf-8")
except UnicodeDecodeError:
    fail("classification_log_capture_invalid")
if not body or "\x00" in body:
    fail("classification_log_capture_invalid")
body=body.replace("&","&amp;").replace("<","&lt;")
source=json.dumps(f"github-actions-log-pr-{pr_number}-run-{run_id}")
content="<external-untrusted-input source="+source+">\n"+body
if not content.endswith("\n"):
    content+="\n"
content+="</external-untrusted-input>\n"
inputs={
    "pr_number":int(pr_number),
    "run_id":run_id,
    "head_sha":head_sha,
    "log_content":content,
    "log_sha256":hashlib.sha256(content.encode("utf-8")).hexdigest(),
}
serialized=json.dumps(inputs,sort_keys=True,separators=(",",":"))
if len(serialized.encode("utf-8"))>49152:
    fail("classification_log_input_oversize",3)
print(serialized,end="")
' "$PR_NUMBER" "$CI_RUN_ID" "$CI_CLASSIFICATION_HEAD_SHA"
      )
    }
    if CI_LOG_AUTHORITY_JSON="$(review_capture_ci_log_authority)"; then
      :
    else
      CI_LOG_AUTHORITY_FAILURE="${CI_LOG_AUTHORITY_JSON:-classification_log_capture_failed}"
      case "$CI_LOG_AUTHORITY_FAILURE" in
        classification_log_capture_failed|classification_log_identity_mismatch|classification_log_capture_invalid|classification_log_input_oversize) ;;
        *) CI_LOG_AUTHORITY_FAILURE=classification_log_capture_failed ;;
      esac
      audit ci_classify_returned subreason="$CI_LOG_AUTHORITY_FAILURE"
      OUTCOME=halted
      exit 1
    fi
    CI_CLASSIFY_INPUTS="$(uberdev_child_inputs_build review_pr.ci.classify \
      pr_number "$(review_json_member "$CI_LOG_AUTHORITY_JSON" pr_number)" \
      run_id "$(review_json_member "$CI_LOG_AUTHORITY_JSON" run_id)" \
      head_sha "$(review_json_member "$CI_LOG_AUTHORITY_JSON" head_sha)" \
      log_content "$(review_json_member "$CI_LOG_AUTHORITY_JSON" log_content)" \
      log_sha256 "$(review_json_member "$CI_LOG_AUTHORITY_JSON" log_sha256)")" || {
      audit ci_classify_returned subreason=classification_inputs_invalid
      OUTCOME=halted
      exit 1
    }
    ```

    **6c.3w.1 — mint the CI authority, bind the child, emit the envelope.**

    `CI_CLASSIFY_INPUTS` is the SAME immutable projection the routed transport
    used — `lib/child-inputs.py` still re-validates the classifier authority's
    PR/run identity, its envelope shape and its digest. What changes is where it
    lands: it is written into the child directory the script derives, and
    `prepare-ci-authority` pins those exact bytes by path and sha256. That pin
    is why the CI edges get their own capture verb: a GH-Actions log is fetched
    once and is unreachable afterwards, so freezing only the child's two outputs
    would prove it wrote something and prove nothing about what it read.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
    [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
    mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
    # Shape-check the mint receipt before anything is allowed to depend on it:
    # exactly four members, the path we asked for, the edge we asked for, and a
    # 64-hex digest. Same guard shape as the Phase 1 authority receipt.
    review_ci_authority_digest() {
      [ "$#" -ge 3 ] || return 2
      python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
if (set(value)!={"authority_path","authority_sha256","edge_id","phase"}
        or value["authority_path"]!=sys.argv[2]
        or value["edge_id"]!=sys.argv[3]
        or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None):
    raise SystemExit(74)
print(value["authority_sha256"],end="")' "${@:1:1}" "${@:2:1}" "${@:3:1}"
    }
    # BOTH counters off disk, before ANY artifact pathname is derived from
    # them. Iteration 2 of the CI loop re-enters this fence in a fresh shell,
    # where `${CI_FIX_LOOP_ITER:-1}` is 1 again -- so it recomputed iteration
    # 1's authority pathname, and `prepare-ci-authority` publishes no-clobber:
    # `authority_preexists`, `return 74`, no audit event, CI_FIX_LOOP_CAP=3
    # unreachable in practice. Same single source of truth the push fence and
    # the CONFLICT arm already read.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    CI_CLASSIFY_SLUG="$(review_fleet_ci_slug ci-classify "${CI_FIX_LOOP_ITER:-1}")" || return 2
    CI_CLASSIFY_CHILD_DIR="$(review_fleet_child_dir "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" "$CI_CLASSIFY_SLUG")" || return 2
    mkdir -p "$CI_CLASSIFY_CHILD_DIR" || return 2
    # The child's input document is pinned by digest two lines later, so an
    # empty or truncated value would be faithfully pinned as garbage. `--minimum
    # 1` accepts a lone newline, and `prepare-ci-authority` then refuses
    # `ci_authority_invalid` rc=74 with NO audit event — the exact failure the
    # counter fix above eliminated everywhere else. Both siblings already fail
    # closed on this (CI_FIXER_INPUTS in 6c.4w.1, CI_DEFER_INPUTS in ci-defer);
    # the FIRST Phase 3 stage was the one that did not.
    printf '%s' "${CI_CLASSIFY_INPUTS:-}" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || { audit ci_classify_returned subreason=classification_inputs_invalid; OUTCOME=halted; exit 1; }
    ( umask 077 && printf '%s\n' "$CI_CLASSIFY_INPUTS" >"$CI_CLASSIFY_CHILD_DIR/input.json" ) || return 74
    CI_CLASSIFY_INPUT_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$CI_CLASSIFY_CHILD_DIR/input.json" --minimum 1 --maximum 1048576)" || return 74
    CI_AUTHORITY_PATH="$REVIEW_FLEET_RUN_DIR/ci-authority-classify-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.json"
    CI_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-ci-authority \
      --edge-id review_pr.ci.classify \
      --pr-number "$PR_NUMBER" --run-id "$CI_RUN_ID" --head-sha "$CI_CLASSIFICATION_HEAD_SHA" \
      --working-dir "$REVIEW_FLEET_WORKTREE" \
      --input-path "$CI_CLASSIFY_CHILD_DIR/input.json" --input-sha256 "$CI_CLASSIFY_INPUT_SHA256" \
      --authority-output-path "$CI_AUTHORITY_PATH")" || return 74
    CI_AUTHORITY_SHA256="$(review_ci_authority_digest "$CI_AUTHORITY_RECEIPT" "$CI_AUTHORITY_PATH" review_pr.ci.classify)" || return 74
    REVIEW_FLEET_CI_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-ci-classify-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launch.json"
    review_fleet_bind_ci review_pr.ci.classify "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
      "${CI_FIX_LOOP_ITER:-1}" "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
      "$CI_AUTHORITY_PATH" "$CI_AUTHORITY_SHA256" '' "$REVIEW_FLEET_CI_SIDECAR" || return 74
    uberdev_emit_workflow_args review-fleet \
      mode=review-pr \
      stage=ci-classify \
      run_id="$RUN_ID" \
      runId="$RUN_ID" \
      runDirAbs="$REVIEW_FLEET_RUN_DIR" \
      pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
      repoRootAbs="$REVIEW_FLEET_WORKTREE" \
      workingDirAbs="$REVIEW_FLEET_WORKTREE" \
      prNumber="$PR_NUMBER" \
      repoSlug="$REVIEW_REPO_SLUG" \
      reviewIteration="$REVIEW_ITERATION" \
      ciLoopIter="${CI_FIX_LOOP_ITER:-1}" \
      ciAuthorityPathAbs="$CI_AUTHORITY_PATH" \
      ciAuthoritySha256="$CI_AUTHORITY_SHA256" \
      ciInputSha256="$CI_CLASSIFY_INPUT_SHA256" \
      ciRunId="$CI_RUN_ID" \
      ciHeadSha="$CI_CLASSIFICATION_HEAD_SHA" \
      maxAgents=40 \
      workspaceMode=caller \
      worktreeAbs="$REVIEW_FLEET_WORKTREE" \
      branchName= \
      runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
    ```

    **Workflow mandate:** relay the JSON between
    `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

    ```
    Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
    ```

    **6c.3w.2 — capture the terminal and judge the classification.** The
    script's return is a report, not evidence: the routing scalar the mutating
    arm keys on comes from `validate-ci-classification`, which re-reads the
    child's frozen result bytes here.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    review_ci_json_member() {
      [ "$#" -ge 2 ] || return 2
      python3 -I -B -c 'import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
member=value[sys.argv[2]]
print(member if isinstance(member,str) else json.dumps(member,separators=(",",":")),end="")' "${@:1:1}" "${@:2:1}"
    }
    review_apply_ci_classification_status() {
      # NOT `local status=` — under /bin/zsh, which is how the harness runs a
      # command `bash` fence on macOS, `status` is the read-only alias for `$?`
      # and `local status=…` is a FATAL error that kills the whole fence, not
      # just the function. Every routing decision below would then be
      # unreachable, with no audit event and no OUTCOME.
      local child_status="${@:1:1}" rationale="${@:2:1}"
      [ "$#" -ge 1 ] || return 2
      case "$child_status" in
        AMBIGUOUS)
          audit ci_classify_ambiguous_routing_as_flaky original_status=AMBIGUOUS
          return 0
          ;;
        REFUSED)
          audit ci_classify_returned subreason=classifier_refused rationale="$rationale"
          OUTCOME=halted
          return 78
          ;;
        CLASSIFIED) return 0 ;;
        *)
          audit ci_classify_returned subreason=contract_invalid
          OUTCOME=halted
          return 79
          ;;
      esac
    }
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    REVIEW_FLEET_CI_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-ci-classify-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launch.json"
    CI_CLASSIFY_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" binding)" || {
      audit ci_classify_returned subreason=classifier_binding_unreadable
      OUTCOME=halted
      exit 1
    }
    CI_CLASSIFY_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-ci-terminal \
      --launch-binding-json "$CI_CLASSIFY_BINDING" --edge-id review_pr.ci.classify)" || {
      CI_CLASSIFY_CHILD_RC=$?
      audit ci_classify_returned subreason=classifier_child_failed exit_code="$CI_CLASSIFY_CHILD_RC"
      OUTCOME=halted
      exit 1
    }
    CI_CLASSIFY_STATUS_SHA256="$(review_ci_json_member "$CI_CLASSIFY_TERMINAL" status_sha256)" || return 74
    CI_CLASSIFY_RESULT_SHA256="$(review_ci_json_member "$CI_CLASSIFY_TERMINAL" result_sha256)" || return 74
    CI_CLASSIFICATION_JSON="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-ci-classification \
      --launch-binding-json "$CI_CLASSIFY_BINDING" \
      --status-sha256 "$CI_CLASSIFY_STATUS_SHA256" \
      --result-sha256 "$CI_CLASSIFY_RESULT_SHA256" 2>"$REVIEW_FLEET_RUN_DIR/ci-classify.err")" || {
      CI_CLASSIFY_REASON="$(tr -d '\n' <"$REVIEW_FLEET_RUN_DIR/ci-classify.err" 2>/dev/null)"
      case "$CI_CLASSIFY_REASON" in
        ci_classification_refused)          CI_CLASSIFY_REASON=classifier_refused ;;
        ci_classification_log_mismatch)     CI_CLASSIFY_REASON=classification_log_mismatch ;;
        *)                                  CI_CLASSIFY_REASON=contract_invalid ;;
      esac
      audit ci_classify_returned subreason="$CI_CLASSIFY_REASON"
      OUTCOME=halted
      exit 1
    }
    classification_status="$(review_ci_json_member "$CI_CLASSIFICATION_JSON" status)" || return 74
    failure_class="$(review_ci_json_member "$CI_CLASSIFICATION_JSON" failure_class)" || return 74
    signal_anchor="$(review_ci_json_member "$CI_CLASSIFICATION_JSON" signal_anchor)" || return 74
    classifier_rationale="$(review_ci_json_member "$CI_CLASSIFICATION_JSON" rationale)" || return 74
    review_apply_ci_classification_status "$classification_status" "$classifier_rationale" || exit 1
    # THE ROUTING PAIR CROSSES ON DISK (#418). 6c.4 ROUTE and the REFUSED arm's
    # aggregate writer are both DIFFERENT shells: ROUTE's `case $failure_class`
    # saw the empty string and fell through to `ci_fix_dispatch_unknown_class`
    # on every run, and the aggregate's `${failure_class:-unknown}` /
    # `${signal_anchor:-unknown:1}` filed every CI-refusal issue with the
    # classifier's entire output replaced by placeholders. The values recorded
    # here are the VALIDATED ones -- `validate-ci-classification` stays the only
    # judge that turns child bytes into a routing scalar; this records its
    # answer, it does not re-derive one.
    #
    # AFTER review_apply_ci_classification_status, never before: a REFUSED
    # classification exits above, so no refusal can leave a routing pair on disk
    # for a later fence to pick up.
    review_fleet_write_ci_classification \
      "$REVIEW_FLEET_RUN_DIR/ci-classification.json" \
      "$failure_class" "$signal_anchor" || {
      echo "error: /uberdev:review-pr — Phase 3 validated the classification ($failure_class) but could not persist it to $REVIEW_FLEET_RUN_DIR/ci-classification.json; refusing to hand ROUTE a class it cannot read." >&2
      audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_uncarried
      OUTCOME=halted
      exit 1
    }
    if CI_ROUTE_HEAD_SHA="$(review_capture_ci_classification_head \
        "$CI_CLASSIFICATION_HEAD_SHA")"; then
      unset CI_ROUTE_HEAD_SHA
    else
      # Same fail-closed default as the 6c.3 capture above: an empty capture
      # here produced `AUDIT ci_phase_outcome outcome=halted subreason=` --
      # Phase 3 halting immediately after a SUCCESSFUL classification with the
      # audit trail naming no cause.
      CI_CLASSIFICATION_HEAD_FAILURE="${CI_ROUTE_HEAD_SHA:-classification_head_probe_unavailable}"
      audit ci_phase_outcome outcome=halted subreason="$CI_CLASSIFICATION_HEAD_FAILURE"
      OUTCOME=halted
      exit 1
    fi
    ```

    Audit `ci_classify_dispatched` on dispatch; `ci_classify_returned` on return
    (with `data.failure_class ∈ CI_FAILURE_CLASS_ENUM`).

    The agent returns YAML — see `plugins/uberdev/agents/ci-failure-classifier.md`
    for the canonical contract. On `status: AMBIGUOUS` (no regex matched),
    `validate-ci-classification` reports the AMBIGUOUS status with
    `failure_class: flaky`, and the caller emits
    `ci_classify_ambiguous_routing_as_flaky` before routing it as flaky (re-run
    once, then halt). The original AMBIGUOUS state must surface in the
    post-mortem trail; conflating it with a known-transient `flaky`
    classification without a distinct audit signal loses root-cause context if
    the flaky re-run also fails.

    **The classifier contract now lives in `lib/code_fixer_contract.py`, not in
    this file (#383).** It used to be a `python3` heredoc inside this markdown,
    which meant the predicate governing whether a MUTATING fixer runs was
    LLM-rendered prose with no test of its own. It is unchanged in substance:
    `CLASSIFIED` requires one of the six `CI_FAILURE_CLASS_ENUM` values and a
    legal class/anchor pairing; `AMBIGUOUS` requires null class + null anchor;
    `REFUSED` requires null class + null anchor plus a non-empty rationale and
    halts as `classifier_refused` rather than being mislabelled
    `contract_invalid`. For `code_bug` / `env_drift` the anchor must name an
    **existing repository file** beneath the worktree; telemetry-only classes
    may use `gh-run-<id>:<line>`. `:121`, `file:0`, absolute and traversal
    paths, blank anchors, unknown classes and duplicate controller fields are
    all contract violations, and an invalid result is never repaired into
    `platform_outage` or `flaky`. `tests/code-fixer-contract.test.sh` exercises
    every one of those refusals against real bytes.

    ### 6c.4 ROUTE — failure_class → downstream agent

    The routing DECISION is a controller proof and stays here; only the two arms
    that dispatch an agent become a Workflow stage. `flaky`,
    `billing_quota` and `platform_outage` have no agent at all, which is why
    they are absent from the script's `CI_FIX_ARMS` table: a controller that
    emitted `stage=ci-fix` for one of them hits `unknown_ci_fixer_edge` rather
    than a silently-picked arm.

    **The push target is bound first, through the same-repository push gate**
    (`lib/review-push-target.sh`). ROUTE is where the branch pair, the fetch and
    the `--force-with-lease` value are now decided, so this is where a fork PR
    has to be refused — before the fetch, before the lease, and with a typed
    audit event instead of a raw `git push` error. `$PR_NUMBER` was already
    bound at 6c.1 PROBE.

    ```bash
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    # CROSS-REPOSITORY GATE (#395). One gh call still returns both refs (one
    # core-bucket request, not two — that matters under tight rate-limit
    # budgets), but the projection now carries the head-repository identity too,
    # and the branch names are only bound when that identity IS this repository.
    #
    # `origin` is the repository the PR was opened AGAINST. For a fork PR
    # `headRefName` names a branch in the CONTRIBUTOR's repository, so ROUTE's
    # `git fetch origin`, the `refs/remotes/origin/<head>` lease it captures and
    # 6c.4w.3's leased push all address a ref that either does not exist or is
    # an unrelated same-named branch in the base repo. Phase 1 and Phase 2
    # refuse that shape before publishing (`review_publish_same_repo_pr_head`);
    # this is Phase 3's copy of the guarantee, and it runs BEFORE the lease is
    # captured because a lease over a ref the run could not identify proves
    # nothing.
    #
    # The resolver lives in lib/ rather than in this fence deliberately: the
    # templater substitutes every positional of a rendered command fence (#404),
    # so a helper that takes arguments cannot survive here.
    REVIEW_PUSH_TARGET_LIB="$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-push-target.sh"
    CI_PUSH_TARGET_RC=0
    if [ -r "$REVIEW_PUSH_TARGET_LIB" ] && . "$REVIEW_PUSH_TARGET_LIB"; then
      REPO_ROOT="$(git rev-parse --show-toplevel)"
      REVIEW_REPO_SLUG="${REVIEW_REPO_SLUG:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
      CI_PUSH_TARGET="$(review_resolve_same_repo_push_target \
        "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$REPO_ROOT")" || CI_PUSH_TARGET_RC=$?
    else
      # An unreadable gate is not a reason to push unguarded — it is the same
      # halt as an unidentifiable target, with its own stderr line so the
      # operator can tell a broken install from a fork PR.
      CI_PUSH_TARGET_RC=79
      echo "error: /uberdev:review-pr — Phase 3 could not load the same-repository push gate: $REVIEW_PUSH_TARGET_LIB" >&2
    fi
    if [ "$CI_PUSH_TARGET_RC" -ne 0 ]; then
      case "$CI_PUSH_TARGET_RC" in
        78)
          CI_PUSH_TARGET_SUBREASON=ci_push_target_cross_repository
          echo "error: /uberdev:review-pr — Phase 3 cannot push PR #$PR_NUMBER: its head branch lives in another repository (fork). Re-run the CI fix from a checkout of the head repository, or land the fix as a PR from this one." >&2
          ;;
        *)
          CI_PUSH_TARGET_SUBREASON=ci_push_target_unresolved
          echo "error: /uberdev:review-pr — Phase 3 could not identify PR #$PR_NUMBER's push target (resolver rc=$CI_PUSH_TARGET_RC); refusing to fetch, lease or push a ref it cannot name." >&2
          ;;
      esac
      audit ci_phase_outcome data.outcome=halted data.subreason=$CI_PUSH_TARGET_SUBREASON
      exit 1
    fi
    IFS=$'\t' read -r pr_head_branch base_branch <<<"$CI_PUSH_TARGET"
    # THE PAIR CROSSES ON DISK, NOT IN THESE TWO SCALARS (#399). ROUTE below is
    # a DIFFERENT harness shell, so `pr_head_branch` / `base_branch` are gone
    # before it runs: its `${pr_head_branch:-}` guard read the empty string on
    # every single run and halted `ci_fix_dispatch_refs_unreadable`
    # unconditionally, which made fix_code, stale_base, the CONFLICT-RESOLVE arm
    # and the single leased push unreachable the moment #399 made ROUTE
    # reachable at all. Same run-dir carrier idiom as ci-loop-state.json /
    # ci-last-push.json / ci-fix-launch-pointer.txt, and the line written is the
    # resolver's own TAB-separated output verbatim so this fence invents no
    # second encoding of the pair.
    #
    # Deliberately NOT via lib/review-fleet-args.sh: this gate must stay
    # executable on its own (tests/review-pr-phase3-ci.test.sh S32-RT.14/15
    # extracts and runs exactly this fence under bash and zsh), and a gate that
    # first needs a dispatch library is a gate no test can execute — which is
    # how #395 shipped invisible.
    CI_PUSH_TARGET_RUN_DIR=
    if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
      CI_PUSH_TARGET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || CI_PUSH_TARGET_RUN_DIR=
    fi
    if [ -n "$CI_PUSH_TARGET_RUN_DIR" ]; then
      # A run dir that IS bound and still cannot take the carrier halts HERE,
      # not at ROUTE: the gh call has already been spent, so a silent non-write
      # would strand an answer this run paid for.
      if ! ( umask 077 && printf '%s\n' "$CI_PUSH_TARGET" >"$CI_PUSH_TARGET_RUN_DIR/ci-push-target.tsv" ); then
        echo "error: /uberdev:review-pr — Phase 3 resolved PR #$PR_NUMBER's push target but could not persist it to $CI_PUSH_TARGET_RUN_DIR/ci-push-target.tsv; refusing to hand ROUTE a target it cannot read." >&2
        audit ci_phase_outcome data.outcome=halted data.subreason=ci_push_target_uncarried
        exit 1
      fi
    else
      # No run dir bound => this fence is running OUTSIDE a Phase 3 run (the
      # S32-RT self-containment cover is exactly that shape). The pair is still
      # bound for a same-shell caller and the miss is TYPED rather than silent;
      # ROUTE's reader then halts `ci_fix_dispatch_refs_unreadable` because the
      # carrier is absent, so the failure is closed either way.
      audit ci_push_target_uncarried data.reason=no_run_dir
    fi
    ```

    Both halts are terminal for the run: `ci_push_target_cross_repository` (fork
    head — `data.subreason` is typed so an audit consumer can route it) and
    `ci_push_target_unresolved` (`gh` unreachable, or a projection this run
    cannot trust). The second is deliberately NOT the `ci_probe_unreachable`
    carve-out that 6c.1 PROBE applies to a `gh` outage: a probe that cannot read
    checks may proceed, a push that cannot name its ref may not.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    # EVERY cross-fence scalar this fence needs comes off disk FIRST, from the
    # one run dir every other Phase 3 fence already reads (#399). Nothing below
    # may reference a name a previous fence merely bound in its own shell.
    CI_ROUTE_RUN_DIR=
    if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
      CI_ROUTE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || CI_ROUTE_RUN_DIR=
    fi
    [ -n "$CI_ROUTE_RUN_DIR" ] || { echo "error: /uberdev:review-pr — Phase 3 ROUTE cannot resolve the run directory; refusing to run the mutating fix phase without its carriers." >&2; audit ci_phase_outcome data.outcome=halted data.subreason=ci_route_run_dir_unreadable; OUTCOME=halted; exit 1; }
    # --no-ci-fix, ENFORCED IN SHELL. CI_FIX_PHASE had no reader anywhere in
    # this file: PROBE/MONITOR/CLASSIFY-run-but-ROUTE-is-skipped was
    # orchestrator prose only, so the documented mode was unenforceable (#383).
    # It then had a reader and no reachable PRODUCER (#399): Step 1 binds it in
    # a fence that ended thousands of lines and many shells earlier, so
    # `${CI_FIX_PHASE:-1}` resolved to 1 on EVERY run and `--no-ci-fix` silently
    # mutated code and force-pushed anyway. The DOCUMENTED default is still 1,
    # but only when Step 1 actually recorded it: "the flag was absent" and "this
    # fence cannot tell" are different answers, and only the first is allowed to
    # reach a code-mutating, remote-writing arm. An unreadable, empty or
    # out-of-vocabulary carrier is the second, and it halts.
    CI_FIX_PHASE_CARRIER="$CI_ROUTE_RUN_DIR/ci-fix-phase.txt"
    CI_FIX_PHASE=
    if [ -r "$CI_FIX_PHASE_CARRIER" ]; then
      IFS= read -r CI_FIX_PHASE <"$CI_FIX_PHASE_CARRIER" || true
    fi
    case "${CI_FIX_PHASE:-}" in
      0 | 1) ;;
      *)
        echo "error: /uberdev:review-pr — Phase 3 could not read the --no-ci-fix decision from $CI_FIX_PHASE_CARRIER; refusing to default a code-mutating, force-pushing phase ON when the user's flag is unknown." >&2
        audit ci_phase_outcome data.outcome=halted data.subreason=ci_fix_phase_unreadable
        OUTCOME=halted
        exit 1
        ;;
    esac
    if [ "${CI_FIX_PHASE:-1}" = 0 ]; then
      # 6c.1 PROBE bound the verdict in ITS shell, so `${PROBE_VERDICT:-unknown}`
      # here recorded `state=unknown` on every probe-only run and, comparing ""
      # against `green`, halted a `--no-ci-fix` review of GREEN CI (#418). The
      # verdict now comes off the carrier PROBE wrote, and an unreadable one is
      # "cannot tell", never "not green": this arm ASSIGNS the phase outcome, so
      # a guess here is a trust-signal answer nobody measured.
      CI_PROBE_VERDICT="$(review_fleet_read_ci_probe_verdict "$CI_ROUTE_RUN_DIR/ci-probe-verdict.txt")" || {
        echo "error: /uberdev:review-pr — Phase 3 could not read the probe verdict from $CI_ROUTE_RUN_DIR/ci-probe-verdict.txt; refusing to answer green or halted for a probe this fence cannot see." >&2
        audit ci_phase_outcome data.outcome=halted data.subreason=ci_probe_verdict_unreadable
        OUTCOME=halted
        exit 1
      }
      audit ci_probe_only_skipped state="$CI_PROBE_VERDICT"
      # The ONE surviving literal `OUTCOME=green`, and it is deliberate: this is
      # `review_fleet_ci_green_outcome`'s fix_phase=0 case, whose answer is
      # STATICALLY green -- probe-only skips every fixer arm, so by construction
      # no fixer ran. Calling the helper here would make RUN_ID a hard
      # requirement of a fence that needs no ledger to be right, for no extra
      # information. The equivalence is asserted behaviourally (E8g, S2-RT.16,
      # S2B-RT.3), and S3.4 pins this as the only literal left in the file.
      if [ "$CI_PROBE_VERDICT" = green ]; then OUTCOME=green; else OUTCOME=halted; fi
      return 0
    fi
    # The classifier's routing pair, off the carrier 6c.3w.2 wrote. Bound HERE,
    # above every consumer, for the same reason the push target is: `case
    # $failure_class` and the fix_code inputs below both ran against the empty
    # string, so `code_bug` fell through to `ci_fix_dispatch_unknown_class` and
    # the whole fixer routing table was unreachable the moment #399 made ROUTE
    # reachable at all (#418). `${...:-}` on the two scalars is deliberately
    # absent so a later edit cannot re-introduce a silent forward reference that
    # "defaults" cleanly.
    CI_CLASSIFICATION_CARRIER="$CI_ROUTE_RUN_DIR/ci-classification.json"
    failure_class="$(review_fleet_read_ci_classification "$CI_CLASSIFICATION_CARRIER" failure_class)" || {
      echo "error: /uberdev:review-pr — Phase 3 ROUTE could not read the validated failure class from $CI_CLASSIFICATION_CARRIER; refusing to route a mutating fixer on a class it cannot name." >&2
      audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_unreadable
      OUTCOME=halted
      exit 1
    }
    # The anchor is read with the SAME halt: an AMBIGUOUS classification carries
    # an empty anchor legitimately (routed as flaky, which needs none), so
    # emptiness is not the failure -- an unreadable RECORD is.
    signal_anchor="$(review_fleet_read_ci_classification "$CI_CLASSIFICATION_CARRIER" signal_anchor)" || {
      echo "error: /uberdev:review-pr — Phase 3 ROUTE could not read the validated signal anchor from $CI_CLASSIFICATION_CARRIER; refusing to hand a fixer an anchor it cannot name." >&2
      audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_unreadable
      OUTCOME=halted
      exit 1
    }
    CI_FIX_INPUTS="$(uberdev_child_inputs_build review_pr.ci.fix_code \
      failure_class "$(review_json_string "$failure_class")" \
      signal_anchor "$(review_json_string "$signal_anchor")" \
      run_id "$(review_json_string "$CI_RUN_ID")" \
      head_sha "$(review_json_string "$CI_CLASSIFICATION_HEAD_SHA")" \
      working_dir "$(review_json_string "$WORKTREE_ROOT")" \
      pr_number "$PR_NUMBER")" || { audit ci_fix_dispatch_inputs_invalid reason=fix_code; OUTCOME=halted; exit 1; }
    # BOTH refs, ONE gh call, and BOTH are bound BEFORE they are used — but the
    # call is the CROSS-REPOSITORY GATE fence above, not a second ungated
    # `gh pr view` here. That gate is the only site allowed to name this PR's
    # head branch, because `origin` is the repository the PR was opened AGAINST
    # and a fork PR's `headRefName` belongs to someone else's repository (#395).
    # `base_branch` used to be a forward reference here as well: it was bound
    # only in the CONFLICT-RESOLVE arm, which runs strictly after ROUTE, so the
    # old `git merge-base HEAD "origin/${base_branch}"` either aborted under
    # `set -u` or silently resolved `origin/` to nothing and poisoned base_sha
    # (#383).
    #
    # The gate ran in a DIFFERENT shell, so neither name is READABLE across the
    # boundary — and reading `${pr_head_branch:-}` here was not a defensive
    # spelling of the same value, it was the empty string on every run (#399).
    # The pair now travels the way every other Phase 3 value travels: the gate
    # writes its own resolver output to the run dir and this fence reads that
    # file. `${…:-}` on the two scalars is gone deliberately, so a future edit
    # cannot re-introduce a silent forward reference that "defaults" cleanly.
    CI_PUSH_TARGET_CARRIER="$CI_ROUTE_RUN_DIR/ci-push-target.tsv"
    CI_PUSH_TARGET=
    if [ -r "$CI_PUSH_TARGET_CARRIER" ]; then
      IFS= read -r CI_PUSH_TARGET <"$CI_PUSH_TARGET_CARRIER" || true
    fi
    CI_PR_HEAD_BRANCH=
    CI_BASE_BRANCH=
    CI_PUSH_TARGET_EXTRA=
    IFS=$'\t' read -r CI_PR_HEAD_BRANCH CI_BASE_BRANCH CI_PUSH_TARGET_EXTRA <<<"$CI_PUSH_TARGET" || true
    # A THIRD field means the carrier is not the two-column line the gate wrote,
    # so it is refused rather than silently truncated into a push target: a
    # two-variable `read` would have folded `head<TAB>base<TAB>junk` into
    # base="base<TAB>junk" and fetched a ref named after the junk.
    [ -n "$CI_PR_HEAD_BRANCH" ] && [ -n "$CI_BASE_BRANCH" ] && [ -z "$CI_PUSH_TARGET_EXTRA" ] || { echo "error: /uberdev:review-pr — Phase 3 ROUTE could not read PR #$PR_NUMBER's push target from $CI_PUSH_TARGET_CARRIER; refusing to fetch, lease or push a ref it cannot name." >&2; audit ci_fix_dispatch_refs_unreadable; OUTCOME=halted; exit 1; }
    git -C "$WORKTREE_ROOT" fetch origin "$CI_PR_HEAD_BRANCH" "$CI_BASE_BRANCH" || { audit ci_fix_dispatch_fetch_failed; OUTCOME=halted; exit 1; }
    # origin/<HEAD>, never origin/<base>. The lease's safety property IS the PR
    # head's prior tip; capturing the base's tip satisfies the lease
    # tautologically and never detects a concurrent head push
    # (agents/ci-rebase-handler.md "Lease form (load-bearing)").
    CI_LEASE_SHA="$(git -C "$WORKTREE_ROOT" rev-parse "refs/remotes/origin/$CI_PR_HEAD_BRANCH")" || { audit ci_fix_dispatch_lease_unreadable; OUTCOME=halted; exit 1; }
    CI_BASE_SHA="$(git -C "$WORKTREE_ROOT" merge-base \
      "refs/remotes/origin/$CI_PR_HEAD_BRANCH" "refs/remotes/origin/$CI_BASE_BRANCH")" || { audit ci_fix_dispatch_base_unreadable; OUTCOME=halted; exit 1; }
    # THE BASE BRANCH'S TIP, captured as its own value and never folded into the
    # merge-base above. The two are different nouns and only one of them can
    # prove where a rebase LANDED (#438).
    #
    # `CI_BASE_SHA` is the merge-base. The moment the base branch is itself
    # rewritten, that merge-base collapses to the shared fork point with the
    # default branch -- and every candidate rebase target contains the fork
    # point, so the contract's ancestry assertion passes for a rebase onto
    # `main` exactly as it does for a rebase onto the branch the PR is stacked
    # on. The tip is the ref `agents/ci-rebase-handler.md` Step 4 actually tells
    # the child to rebase onto, so it is the value the result must contain.
    #
    # It crosses the SAME dead shell as the lease, so it travels the SAME way:
    # pinned into the digest-pinned rebase authority at 6c.4w.1 and read back
    # with `read-ci-authority-member` at 6c.4w.3. It is a REQUIRED member there
    # (code_fixer_contract.py CI_AUTHORITY_REQUIRED_MEMBERS), so a value lost
    # between fences is refused at the mint rather than defaulted at the push --
    # the #418/#419 discipline, applied to the value that fixes #438.
    #
    # That covers MINT -> PUSH. The ROUTE -> MINT hop below is NOT covered, and
    # this value does not fix it: `CI_LEASE_SHA`, `CI_BASE_SHA`,
    # `CI_PR_HEAD_BRANCH`, `CI_BASE_BRANCH`, `CI_FIXER_EDGE_ID`,
    # `CI_FIXER_INPUTS`, `failure_class` and `signal_anchor` all reach 6c.4w.1 as
    # bare scalars out of this shell, and the tip joins that queue rather than
    # jumping it. The hop is fail-closed (every one of them is a required member
    # refused at mint when empty), so nothing defaults -- but the whole cluster
    # has to move together, and the command-wide cross-fence rebuild is #427.
    # Do not read #438 as having closed it.
    CI_BASE_TIP_SHA="$(git -C "$WORKTREE_ROOT" rev-parse "refs/remotes/origin/$CI_BASE_BRANCH")" || { audit ci_fix_dispatch_base_tip_unreadable; OUTCOME=halted; exit 1; }
    CI_REBASE_INPUTS="$(uberdev_child_inputs_build review_pr.ci.rebase \
      working_dir "$(review_json_string "$WORKTREE_ROOT")" \
      pr_number "$PR_NUMBER" \
      head_sha "$(review_json_string "$CI_CLASSIFICATION_HEAD_SHA")" \
      base_sha "$(review_json_string "$CI_BASE_SHA")")" || { audit ci_fix_dispatch_inputs_invalid reason=rebase; OUTCOME=halted; exit 1; }
    case $failure_class in
      code_bug | env_drift)
        CI_FIXER_EDGE_ID=review_pr.ci.fix_code
        CI_FIXER_INPUTS="$CI_FIX_INPUTS"
        CI_FIXER_SLUG_BASE=ci-fix-code
        ;;
      stale_base)
        CI_FIXER_EDGE_ID=review_pr.ci.rebase
        CI_FIXER_INPUTS="$CI_REBASE_INPUTS"
        CI_FIXER_SLUG_BASE=ci-rebase
        ;;
      flaky)
        # No agent, no stage: a re-run is a `gh` call, not a child.
        if gh run rerun "$CI_RUN_ID"; then
          audit ci_flaky_rerun_queued run_id="$CI_RUN_ID"
        else
          # gh run rerun can fail on auth/rate-limit/max-reruns; silently
          # dropping the exit code lets the loop hit CI_FIX_LOOP_CAP with no
          # actual fix attempts. Halt cleanly so the user sees the rerun
          # failure.
          audit ci_flaky_rerun_failed run_id="$CI_RUN_ID"
          audit ci_phase_outcome data.outcome=halted data.subreason=flaky_rerun_failed
          OUTCOME=halted
          exit 1
        fi
        # max 1 retry per distinct check (RERUN_FLAKY_CAP=1); does NOT
        # increment CI_FIX_LOOP_ITER.
        CI_FIXER_EDGE_ID=
        ;;
      billing_quota | platform_outage)
        # No agent either: 6c.6 HALT is an AskUserQuestion in the main turn.
        CI_FIXER_EDGE_ID=
        CI_HALT_CLASS="$failure_class"
        audit ci_phase_halt_class class="$failure_class"
        ;;
      *)
        # Default-case guard: defensive against future CI_FAILURE_CLASS_ENUM
        # extension landing without a paired ROUTE arm. Silent fallthrough
        # would let the loop hit CI_FIX_LOOP_CAP with no fix attempts;
        # classifier-side an unknown class is already a contract violation, so
        # audit + halt + exit 1 is the correct floor.
        audit ci_fix_dispatch_unknown_class reason=$failure_class
        OUTCOME=halted
        exit 1
        ;;
    esac
    ```

    When `CI_FIXER_EDGE_ID` is empty the routing is finished: `flaky` re-probes
    at 6c.1 and the two human-action classes go to 6c.6 HALT. Otherwise run
    6c.4w below.

    **6c.4w.1 — mint the CI authority for the routed arm, bind, emit.**

    The rebase authority carries the LEASE. It is a member of a document
    published no-clobber by `prepare-ci-authority` and pinned into the binding
    by digest — it is never an envelope scalar and the script never sees it,
    because the script never pushes. `prepare-ci-authority` refuses a rebase
    authority with an empty `lease_sha` **at mint**, so a missing lease costs a
    refusal before the Workflow call rather than after a child has run.

    It carries `base_tip_sha` on exactly the same terms, and for the same class
    of reason (#438). `base_sha` is the pre-rebase MERGE-BASE; `base_tip_sha` is
    `refs/remotes/origin/<base_branch>` as ROUTE observed it, which is the ref
    the child is told to rebase onto. Only the tip can prove where a rebase
    landed once the base branch has itself been rewritten — at that point the
    merge-base collapses to the shared fork point, and every candidate rebase
    target contains it. Both are required members, so neither can go missing
    across the dead shell between ROUTE and this fence and reappear as a default.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
    [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
    mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
    review_ci_authority_digest() {
      [ "$#" -ge 3 ] || return 2
      python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
if (set(value)!={"authority_path","authority_sha256","edge_id","phase"}
        or value["authority_path"]!=sys.argv[2]
        or value["edge_id"]!=sys.argv[3]
        or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None):
    raise SystemExit(74)
print(value["authority_sha256"],end="")' "${@:1:1}" "${@:2:1}" "${@:3:1}"
    }
    # ROUTE ran in a DIFFERENT shell. Every scalar it produced that this fence
    # consumes is either re-checked by prepare-ci-authority below (failure
    # class, anchor, base sha, branches, lease -- all required members, all
    # refused at mint when empty) or checked HERE, because these two are not.
    #
    # The slug base keys the child DIRECTORY on this side, while
    # review_fleet_bind_ci re-derives it from the EDGE on its side. A lost value
    # would leave the two disagreeing about where the child writes, and the
    # controller would then look for artifacts in a directory nothing wrote to.
    # `${…:-}` on the case WORD, not only in the `*)` arm's reason: under
    # `set -u` the word is expanded before any arm is chosen, so a bare
    # `"$CI_FIXER_SLUG_BASE"` killed the fence with a raw unbound-variable
    # message in precisely the case this guard documents — no
    # `ci_fix_dispatch_slug_base_invalid`, no `reason=empty`, no cleanup.
    case "${CI_FIXER_SLUG_BASE:-}" in
      ci-fix-code | ci-rebase) ;;
      *) audit ci_fix_dispatch_slug_base_invalid reason="${CI_FIXER_SLUG_BASE:-empty}"; OUTCOME=halted; exit 1 ;;
    esac
    # The child's input document is pinned by digest a line later, so an empty
    # or truncated value would be faithfully pinned as garbage and only
    # discovered by the child, one dispatch too late.
    printf '%s' "${CI_FIXER_INPUTS:-}" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || { audit ci_fix_dispatch_inputs_invalid reason="${CI_FIXER_SLUG_BASE:-empty}"; OUTCOME=halted; exit 1; }
    # Counters off disk BEFORE any pathname is keyed on them -- see 6c.3w.1.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    CI_FIXER_SLUG="$(review_fleet_ci_slug "$CI_FIXER_SLUG_BASE" "${CI_FIX_LOOP_ITER:-1}")" || return 2
    CI_FIXER_CHILD_DIR="$(review_fleet_child_dir "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" "$CI_FIXER_SLUG")" || return 2
    mkdir -p "$CI_FIXER_CHILD_DIR" || return 2
    ( umask 077 && printf '%s\n' "$CI_FIXER_INPUTS" >"$CI_FIXER_CHILD_DIR/input.json" ) || return 74
    CI_FIXER_INPUT_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$CI_FIXER_CHILD_DIR/input.json" --minimum 1 --maximum 1048576)" || return 74
    CI_FIXER_HEAD_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
    CI_FIXER_TREE_BEFORE="$(git -C "$WORKTREE_ROOT" rev-parse 'HEAD^{tree}')" || return 74
    case "$CI_FIXER_SLUG_BASE" in
      ci-fix-code) CI_AUTHORITY_PATH="$REVIEW_FLEET_RUN_DIR/ci-authority-fix-code-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.json" ;;
      *)           CI_AUTHORITY_PATH="$REVIEW_FLEET_RUN_DIR/ci-authority-rebase-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.json" ;;
    esac
    if [ "$CI_FIXER_EDGE_ID" = review_pr.ci.fix_code ]; then
      CI_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-ci-authority \
        --edge-id review_pr.ci.fix_code \
        --pr-number "$PR_NUMBER" --run-id "$CI_RUN_ID" --head-sha "$CI_CLASSIFICATION_HEAD_SHA" \
        --working-dir "$REVIEW_FLEET_WORKTREE" \
        --input-path "$CI_FIXER_CHILD_DIR/input.json" --input-sha256 "$CI_FIXER_INPUT_SHA256" \
        --failure-class "$failure_class" --signal-anchor "$signal_anchor" \
        --parent-sha "$CI_FIXER_HEAD_BEFORE" --parent-tree-sha "$CI_FIXER_TREE_BEFORE" \
        --lease-sha "$CI_LEASE_SHA" --pr-branch "$CI_PR_HEAD_BRANCH" \
        --authority-output-path "$CI_AUTHORITY_PATH")" || return 74
    else
      CI_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-ci-authority \
        --edge-id review_pr.ci.rebase \
        --pr-number "$PR_NUMBER" --run-id "$CI_RUN_ID" --head-sha "$CI_CLASSIFICATION_HEAD_SHA" \
        --working-dir "$REVIEW_FLEET_WORKTREE" \
        --input-path "$CI_FIXER_CHILD_DIR/input.json" --input-sha256 "$CI_FIXER_INPUT_SHA256" \
        --base-sha "$CI_BASE_SHA" --base-tip-sha "$CI_BASE_TIP_SHA" \
        --lease-sha "$CI_LEASE_SHA" \
        --pr-branch "$CI_PR_HEAD_BRANCH" --base-branch "$CI_BASE_BRANCH" \
        --authority-output-path "$CI_AUTHORITY_PATH")" || return 74
    fi
    CI_AUTHORITY_SHA256="$(review_ci_authority_digest "$CI_AUTHORITY_RECEIPT" "$CI_AUTHORITY_PATH" "$CI_FIXER_EDGE_ID")" || return 74
    REVIEW_FLEET_CI_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-ci-fix-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launch.json"
    review_fleet_bind_ci "$CI_FIXER_EDGE_ID" "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
      "${CI_FIX_LOOP_ITER:-1}" "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
      "$CI_AUTHORITY_PATH" "$CI_AUTHORITY_SHA256" "$CI_FIXER_HEAD_BEFORE" "$REVIEW_FLEET_CI_SIDECAR" || return 74
    # THE POINTER. Every later reader of this sidecar (6c.4w.2, the CONFLICT
    # arm's step 2, and 6c.4w.3 THE SINGLE LEASED PUSH) follows this fixed-name
    # file instead of recomputing the counter-keyed filename. The restage inside
    # the CONFLICT arm legitimately advances CI_FIX_LOOP_ITER on disk while this
    # sidecar keeps the name it was written under, so recomputation and reality
    # diverge by exactly one after any multi-stage rebase -- and the push fence
    # then aborted `ci_fixer_binding_unreadable` and destroyed the rebase.
    review_fleet_write_ci_pointer "$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer.txt" \
      "$REVIEW_FLEET_CI_SIDECAR" || return 74
    uberdev_emit_workflow_args review-fleet \
      mode=review-pr \
      stage=ci-fix \
      run_id="$RUN_ID" \
      runId="$RUN_ID" \
      runDirAbs="$REVIEW_FLEET_RUN_DIR" \
      pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
      repoRootAbs="$REVIEW_FLEET_WORKTREE" \
      workingDirAbs="$REVIEW_FLEET_WORKTREE" \
      prNumber="$PR_NUMBER" \
      repoSlug="$REVIEW_REPO_SLUG" \
      reviewIteration="$REVIEW_ITERATION" \
      ciLoopIter="${CI_FIX_LOOP_ITER:-1}" \
      ciFixerEdgeId="$CI_FIXER_EDGE_ID" \
      ciFailureClass="$failure_class" \
      ciSignalAnchor="$signal_anchor" \
      ciAuthorityPathAbs="$CI_AUTHORITY_PATH" \
      ciAuthoritySha256="$CI_AUTHORITY_SHA256" \
      ciInputSha256="$CI_FIXER_INPUT_SHA256" \
      ciRunId="$CI_RUN_ID" \
      ciHeadSha="$CI_CLASSIFICATION_HEAD_SHA" \
      ciBaseSha="$CI_BASE_SHA" \
      ciPrBranch="$CI_PR_HEAD_BRANCH" \
      ciBaseBranch="$CI_BASE_BRANCH" \
      maxAgents=40 \
      workspaceMode=caller \
      worktreeAbs="$REVIEW_FLEET_WORKTREE" \
      branchName= \
      runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
    ```

    **Workflow mandate:** relay the JSON between
    `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

    ```
    Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
    ```

    **6c.4w.2 — capture the terminal and judge the mutation.** The script's
    `fixerStatus` is a hint for logging only. `validate-ci-mutation-outcome`
    derives the real terminal from git: for `fix_code` it checks the pinned
    parent, that at most one new commit exists, that its subject is
    `fix(ci): ` or `chore(deps): `, and that the touched-path set is the
    anchor's own file plus at most one lockfile. For `rebase` it checks that
    HEAD moved, that the pinned base is an ancestor, and — before this command
    pushes anything — that `refs/remotes/origin/<head>` still equals the pinned
    lease. That last check is what makes the rebase agent's demotion from
    pusher to preparer enforceable rather than aspirational.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    review_ci_json_member() {
      [ "$#" -ge 2 ] || return 2
      python3 -I -B -c 'import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
member=value[sys.argv[2]]
print(member if isinstance(member,str) else json.dumps(member,separators=(",",":")),end="")' "${@:1:1}" "${@:2:1}"
    }
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    # The sidecar is found through the pointer 6c.4w.1 published, never
    # recomputed from the counters -- see the pointer comment in 6c.4w.1.
    REVIEW_FLEET_CI_SIDECAR="$(review_fleet_read_ci_pointer "$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer.txt")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
    CI_FIXER_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" binding)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
    CI_FIXER_HEAD_BEFORE="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" head_before)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
    CI_FIXER_EDGE_ID="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .edge_id)" || return 74
    # NOT jq for the authority: reading it with jq would read it WITHOUT
    # re-checking the digest, and the digest re-check is the entire point.
    CI_AUTHORITY_PATH="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .ci_authority_path)" || return 74
    CI_AUTHORITY_SHA256="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .ci_authority_sha256)" || return 74
    CI_FIXER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-ci-terminal \
      --launch-binding-json "$CI_FIXER_BINDING" --edge-id "$CI_FIXER_EDGE_ID")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_terminal_invalid; exit 1; }
    CI_FIXER_STATUS_SHA256="$(review_ci_json_member "$CI_FIXER_TERMINAL" status_sha256)" || return 74
    CI_FIXER_RESULT_SHA256="$(review_ci_json_member "$CI_FIXER_TERMINAL" result_sha256)" || return 74
    CI_FIXER_HEAD_AFTER="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
    CI_REMOTE_HEAD_SHA=
    if [ "$CI_FIXER_EDGE_ID" = review_pr.ci.rebase ]; then
      CI_PR_BRANCH="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
        --authority-path "$CI_AUTHORITY_PATH" --authority-sha256 "$CI_AUTHORITY_SHA256" \
        --member pr_branch)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_authority_unreadable; exit 1; }
      git -C "$WORKTREE_ROOT" fetch origin "$CI_PR_BRANCH" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_rebase_remote_unreadable; exit 1; }
      CI_REMOTE_HEAD_SHA="$(git -C "$WORKTREE_ROOT" rev-parse "refs/remotes/origin/$CI_PR_BRANCH")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_rebase_remote_unreadable; exit 1; }
    fi
    CI_MUTATION_OUTCOME="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-ci-mutation-outcome \
      --launch-binding-json "$CI_FIXER_BINDING" \
      --status-sha256 "$CI_FIXER_STATUS_SHA256" --result-sha256 "$CI_FIXER_RESULT_SHA256" \
      --working-dir "$WORKTREE_ROOT" \
      --head-before "$CI_FIXER_HEAD_BEFORE" --head-after "$CI_FIXER_HEAD_AFTER" \
      --remote-head-sha "$CI_REMOTE_HEAD_SHA" 2>"$REVIEW_FLEET_RUN_DIR/ci-fix.err")" || {
      CI_MUTATION_REASON="$(tr -d '\n' <"$REVIEW_FLEET_RUN_DIR/ci-fix.err" 2>/dev/null)"
      # A mid-rebase abort is a guarded BASH line here, not a cleanup agent: an
      # agent dispatched to clean up after a dead agent is a second thing that
      # can die, and this fence runs unconditionally after the call returns.
      #
      # It is reached ONLY on a refusal. A conflicted rebase is NOT one: the
      # rebase judge has a CONFLICT terminal precisely so the state the child was
      # ordered to leave behind (agents/ci-rebase-handler.md Step 5, "leave the
      # rebase IN PROGRESS") is a validated outcome rather than an error. Without
      # that terminal this line ran on every conflicted rebase and destroyed the
      # exact rebase the CONFLICT-RESOLVE arm below needs.
      #
      # `review_fleet_rebase_dir`, NOT `[ -d "$(git … --git-path rebase-merge)" ]`:
      # `--git-path` prints `.git/rebase-merge` RELATIVE to the -C directory, so
      # the bare `-d` test was answered by the harness shell's own cwd and this
      # cleanup silently became a no-op from any directory but the repo root.
      if review_fleet_rebase_dir "$WORKTREE_ROOT" >/dev/null; then
        git -C "$WORKTREE_ROOT" rebase --abort || true
      fi
      audit ci_phase_outcome data.outcome=halted data.subreason="${CI_MUTATION_REASON:-ci_mutation_invalid}"
      OUTCOME=halted
      exit 1
    }
    CI_FIXER_TERMINAL_STATUS="$(review_ci_json_member "$CI_MUTATION_OUTCOME" status)" || return 74
    # The refusal rationale rides the SAME validated receipt, so the ci-defer
    # arm below never has to re-read the child's result itself. Empty on every
    # terminal but fix_code REFUSED.
    CI_FIXER_TERMINAL_RATIONALE="$(review_ci_json_member "$CI_MUTATION_OUTCOME" rationale)" || return 74
    # BOTH scalars are SURFACED, because neither consumer is in this shell
    # (#399). 6c.5's routing table is executed by the orchestrator, which cannot
    # observe a variable this fence bound and never emitted — so the terminal it
    # must branch on was invisible on every path. And the REFUSED arm's
    # synthetic-aggregate fence is a fresh shell whose
    # `${CI_FIXER_TERMINAL_RATIONALE:-unspecified}` was therefore ALWAYS
    # `unspecified`, filing every CI-refusal issue with the reason erased.
    #
    # Two surfaces, both already used by this phase, no third invented: the
    # typed audit event is how the orchestrator sees it, and the run-dir record
    # is how the later fence reads it — the same pair the push record uses
    # (`review_fleet_write_ci_push` + `audit ci_fix_pushed`).
    ( umask 077 && jq -cn \
        --arg status "$CI_FIXER_TERMINAL_STATUS" \
        --arg rationale "$CI_FIXER_TERMINAL_RATIONALE" \
        '{status:$status,rationale:$rationale}' \
        >"$REVIEW_FLEET_RUN_DIR/ci-fixer-terminal.json" ) || return 74
    audit ci_fix_terminal data.status="$CI_FIXER_TERMINAL_STATUS" data.rationale="${CI_FIXER_TERMINAL_RATIONALE:-unspecified}"
    ```

    `CI_FIXER_TERMINAL_STATUS` — **not** the agent's self-reported status — is
    what 6c.5 branches on. It is one of `APPLIED` / `NO_CHANGE` / `REFUSED` (fix_code),
    `REBASED` / `CONFLICT` (rebase). The agent's own YAML is a hint for logging;
    every routing decision below reads this validated scalar.

    **Read it from `ci_fix_terminal` / `ci-fixer-terminal.json`, never from the
    variable.** The fence above ends where its shell ends. Until #399 the
    terminal was the last assignment in that fence and was never echoed,
    audited or written down, so the one scalar 6c.5's whole routing table keys
    on could not be observed by the thing doing the routing — every branch below
    was formally unreachable, including the CONFLICT arm and the REFUSED arm's
    issue filing. The `audit ci_fix_terminal` event carries `data.status` and
    `data.rationale` for the orchestrator; `$RESEARCH_DIR_ABS/ci-fixer-terminal.json`
    carries the same two members for any later fence, and the REFUSED arm below
    re-reads them from there rather than trusting an inherited name.

    `REFUSED` is the one terminal git cannot derive on its own, and conflating
    it with `NO_CHANGE` is what made the whole ci-defer stage dead code. A
    refusing `ci-code-fixer` makes no commit, so `head_after == head_before`
    either way; `validate-ci-mutation-outcome` therefore reads the child's
    `status: REFUSED` declaration out of the result bytes it has already pinned
    by digest, and returns `REFUSED` plus a sanitised `rationale`. That is not a
    relaxation of "never branch on the self-report": the declaration is only
    ever consulted when HEAD did **not** move, so it can downgrade a no-commit
    terminal into a halt and can never turn an unmoved HEAD into a push.

    Audit `ci_fix_dispatched` (with `data.by_agent ∈ {ci-code-fixer, ci-rebase-handler}`) on every dispatch. The `RERUN_FLAKY_CAP = 1` constant (declared in `merge-pipeline/SKILL.md`) bounds flake retries inside a single iteration; the loop counter is unaffected.

    **6c.4w.3 — THE SINGLE LEASED PUSH.** This is the only fence in Phase 3 that
    moves a remote ref, and all three terminals that produce new history reach
    it: `fix_code` `APPLIED`, `rebase` `REBASED`, and
    `CONFLICT → all RESOLVED → rebase --continue`. There is no second lease and
    no second push — the CONFLICT-RESOLVE arm's step 4 *is* this fence, invoked
    a second time after it stages and continues.

    Neither fixer agent pushes: `agents/ci-code-fixer.md` never writes to a
    remote and `agents/ci-rebase-handler.md` was demoted from pusher to preparer
    with `git push` on its denylist. Before this step existed, that demotion left
    the clean-rebase and `APPLIED` terminals with *nothing* pushing at all — the
    rebased commits stayed local, the next 6c.1 PROBE re-selected the same red
    run off an unchanged remote head, and the loop burned to
    `loop_cap_exhausted`.

    The fence is self-contained by construction: every scalar it needs comes off
    disk (the launch sidecar) or out of the digest-pinned authority. The lease is
    read with `read-ci-authority-member`, never `jq` — jq would read the file
    without re-checking the digest, and the digest re-check is the entire point
    for a value that authorises a force-push against a PR head.

    It finds that sidecar through the fixed-name POINTER 6c.4w.1 writes, not by
    recomputing the sidecar's counter-keyed filename. The two answers are not the
    same after a CONFLICT-arm restage: the restage advances `CI_FIX_LOOP_ITER` on
    disk — deliberately, because the restage IS a loop iteration and that is what
    bounds it — while the sidecar keeps the name it was minted under. Recomputing
    it here looked for `…-ci2.launch.json` when only `…-ci1.launch.json` had ever
    been written, so the third terminal this fence exists to serve aborted
    `ci_fixer_binding_unreadable`, ran `git rebase --abort`, and destroyed every
    resolved conflict with nothing pushed.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
    review_ci_push_abort() {
      if review_fleet_rebase_dir "$WORKTREE_ROOT" >/dev/null; then
        git -C "$WORKTREE_ROOT" rebase --abort || true
      fi
      audit ci_phase_outcome data.outcome=halted data.subreason="${@:1:1}"
      OUTCOME=halted
      exit 1
    }
    # ONE reader for the counter pair, shared with every other Phase 3 fence:
    # two spellings of "read the counters" is how half of them ended up not
    # reading them at all. It also supplies the first-iteration default, so an
    # absent state file cannot leave REVIEW_ITERATION unset under `set -u`.
    review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
    # The ci-fix sidecar is located through the POINTER 6c.4w.1 published, not
    # by recomputing its counter-keyed filename. Those two answers diverge by
    # exactly one after a CONFLICT-arm restage — the restage advances
    # CI_FIX_LOOP_ITER on disk (it IS a loop iteration) while the sidecar keeps
    # the name it was written under — and this fence then aborted
    # `ci_fixer_binding_unreadable` and ran `git rebase --abort`, destroying
    # every resolved conflict with nothing pushed. The counters above are still
    # read off disk: the `.launched` ledger below IS re-minted per restage wave,
    # so that one is correctly keyed on the current counter.
    REVIEW_FLEET_CI_SIDECAR="$(review_fleet_read_ci_pointer "$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer.txt")" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_FIXER_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" binding)" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_FIXER_HEAD_BEFORE="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" head_before)" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_FIXER_EDGE_ID="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .edge_id)" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_AUTHORITY_PATH="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .ci_authority_path)" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_AUTHORITY_SHA256="$(printf '%s' "$CI_FIXER_BINDING" | jq -er .ci_authority_sha256)" || review_ci_push_abort ci_fixer_binding_unreadable
    CI_LEASE_SHA="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
      --authority-path "$CI_AUTHORITY_PATH" --authority-sha256 "$CI_AUTHORITY_SHA256" \
      --member lease_sha)" || review_ci_push_abort ci_authority_unreadable
    CI_PR_HEAD_BRANCH="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
      --authority-path "$CI_AUTHORITY_PATH" --authority-sha256 "$CI_AUTHORITY_SHA256" \
      --member pr_branch)" || review_ci_push_abort ci_authority_unreadable
    # Both are required members of BOTH mutating authorities, so an empty one
    # here means the pin itself is wrong -- refuse rather than push `origin ""`
    # with `--force-with-lease=":"`, which is what a missing value degrades to.
    case "$CI_LEASE_SHA" in
      *[!0-9a-f]*) review_ci_push_abort ci_authority_unreadable ;;
      *) [ "${#CI_LEASE_SHA}" -eq 40 ] || review_ci_push_abort ci_authority_unreadable ;;
    esac
    [ -n "$CI_PR_HEAD_BRANCH" ] || review_ci_push_abort ci_authority_unreadable
    git -C "$WORKTREE_ROOT" check-ref-format --branch "$CI_PR_HEAD_BRANCH" >/dev/null 2>&1 || review_ci_push_abort ci_authority_unreadable
    # Derived HERE, after the rebase/commit has settled, so nothing depends on a
    # sha computed in an earlier shell.
    NEW_HEAD_SHA="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
    # THREE-valued, because "git could not answer" must not read as "no rebase":
    # rc 0 = live rebase, rc 1 = none, rc 2 = the probe itself failed. The old
    # `[ -d "$(git … --git-path rebase-merge)" ]` asked the question of the
    # harness shell's own cwd — `--git-path` prints `.git/rebase-merge`, a path
    # relative to the -C directory — so from any directory but the repo root it
    # answered "no rebase" mid-rebase and this guard force-pushed the interior
    # state (for a first-commit conflict, the BASE branch tip) onto the PR head.
    CI_REBASE_PROBE_RC=0
    review_fleet_rebase_dir "$WORKTREE_ROOT" >/dev/null || CI_REBASE_PROBE_RC=$?
    case "$CI_REBASE_PROBE_RC" in
      0) review_ci_push_abort rebase_still_in_progress ;;  # interior state as the PR head
      1) ;;
      *) review_ci_push_abort ci_rebase_state_unreadable ;;
    esac
    # NO_CHANGE has no push. `_validate_ci_fix_code_outcome` returns it when
    # head_after == head_before, and 6c.5's prose says "do NOT run 6c.4w.3" —
    # prose with no reader. Pushing an unchanged HEAD satisfies the lease,
    # exits 0 ("Everything up-to-date"), and writes `ci_fix_pushed` naming a
    # commit that fixed nothing, so Phase 1 re-enters on identical code and the
    # loop burns an iteration. Every terminal that legitimately reaches this
    # fence moved HEAD: APPLIED adds one commit, REBASED requires HEAD to have
    # moved, and CONFLICT reaches here only after `rebase --continue`.
    if [ "$CI_FIXER_HEAD_BEFORE" = "$NEW_HEAD_SHA" ]; then
      review_ci_push_abort ci_fix_no_change
    fi
    # THE BASE-TIP PROOF (#438). `validate-ci-mutation-outcome` judges the
    # rebase, but the CONFLICT terminal reaches THIS fence a SECOND time after
    # `rebase --continue` and the judge does not run again -- so the post-continue
    # head was never base-tip-checked by anything. Proving it here covers all
    # three terminals uniformly and does not depend on when the judge ran.
    #
    # The pin is the base branch's tip as ROUTE observed it, read back out of the
    # digest-pinned authority exactly as the lease is. `merge-base --is-ancestor`
    # against it answers the one question the lease cannot: the lease proves
    # nobody else moved the PR HEAD, while this proves the head about to be
    # force-pushed is still descended from the branch the PR is based on. A
    # rebase onto the wrong target satisfies the lease perfectly.
    #
    # Rebase edge only: `fix_code` commits on top of the existing head and does
    # not change base ancestry, and its authority carries no tip to check.
    if [ "$CI_FIXER_EDGE_ID" = review_pr.ci.rebase ]; then
      CI_BASE_TIP_SHA="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
        --authority-path "$CI_AUTHORITY_PATH" --authority-sha256 "$CI_AUTHORITY_SHA256" \
        --member base_tip_sha)" || review_ci_push_abort ci_authority_unreadable
      # A required member of the rebase authority, so an empty value here means
      # the pin itself is wrong. Refuse rather than run `--is-ancestor ""`, which
      # is an error git reports the same way it reports a real refusal.
      case "$CI_BASE_TIP_SHA" in
        *[!0-9a-f]*) review_ci_push_abort ci_authority_unreadable ;;
        *) [ "${#CI_BASE_TIP_SHA}" -eq 40 ] || review_ci_push_abort ci_authority_unreadable ;;
      esac
      git -C "$WORKTREE_ROOT" merge-base --is-ancestor "$CI_BASE_TIP_SHA" "$NEW_HEAD_SHA" \
        || review_ci_push_abort ci_push_head_detached_from_base
    fi
    if [ "$CI_FIXER_EDGE_ID" = review_pr.ci.fix_code ]; then
      CI_FIX_BY_AGENT=ci-code-fixer
    elif [ -s "$REVIEW_FLEET_RUN_DIR/ci-conflicts-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launched" ]; then
      CI_FIX_BY_AGENT="ci-rebase-handler+conflict-resolver"
    else
      CI_FIX_BY_AGENT=ci-rebase-handler
    fi
    # THE DEPENDENT-PR GATE (#438). `--force-with-lease` and `--force-if-includes`
    # protect exactly ONE thing: this PR's own head. They say nothing about who
    # BASES on that branch. A leased push that rewrites a branch another open PR
    # is stacked on returns 0 and reports success -- while that PR's merge-base
    # collapses and its diff silently grows to include commits its author never
    # wrote. There was no audit event and no halt, because there was no reader.
    #
    # The question is a LIVE fact about the remote, so it is asked HERE, in the
    # fence that pushes, and not at the cross-repository gate ~2000 lines and one
    # child dispatch earlier: an answer from before the child ran describes a
    # repository state that no longer exists.
    #
    # ASKED ONLY OF A PUSH THAT REWRITES. Both mutating edges land in this one
    # fence, and only one of them rewrites history: `_validate_ci_fix_code_outcome`
    # pins the `fix_code` terminal to exactly one commit whose parent is
    # `head_before`, so that edge's push is an APPEND. Appending cannot move any
    # dependent PR's merge-base -- the new commits are not reachable from that
    # PR's head, so its merge-base and therefore its diff are unchanged. Halting
    # an append would refuse a push that harms nobody, and would take Phase 3 CI
    # autofix permanently offline on exactly the stacked branches #438 exists to
    # protect.
    #
    # The discriminator is the SHAPE of the push, never the name of the edge:
    # `--force-with-lease` below has already fixed the remote ref at
    # `$CI_LEASE_SHA`, so "the lease is an ancestor of the new head" IS "this
    # push fast-forwards". A CONFLICT-terminal rebase that happens to
    # fast-forward is equally harmless and is equally let through; a `fix_code`
    # run that somehow did NOT fast-forward is equally gated. If the ancestry
    # probe itself fails, git answers rc>1, the `else` arm runs, and the gate
    # asks its question anyway -- "cannot tell whether this rewrites" falls
    # through to the STRICTER branch, never past it.
    if git -C "$WORKTREE_ROOT" merge-base --is-ancestor "$CI_LEASE_SHA" "$NEW_HEAD_SHA"; then
      : # fast-forward: append-only, no dependent PR's base can move
    else
      # `gh` is PINNED to the repository the push targets, and that repository is
      # named by the very remote the push names -- `origin` of `$WORKTREE_ROOT`.
      # Left unpinned, `gh` resolves a repository from the cwd's remotes on its
      # own precedence (upstream > github > origin) and also honours `$GH_REPO`
      # and `remote.<n>.gh-resolved`, so a fork chain, a contributor clone or a
      # stale `gh repo set-default` makes it answer about a DIFFERENT repository
      # -- returning a well-formed empty array, which is a fail-OPEN answer in a
      # fail-closed gate. The `--repo` flag outranks both of those sources
      # (verified against gh 2.83.1), so pinning it is sufficient.
      CI_PUSH_REMOTE_URL="$(git -C "$WORKTREE_ROOT" remote get-url origin)" \
        || review_ci_push_abort ci_dependent_pr_probe_unreadable
      # owner/name is the last two path segments with any `.git` suffix removed --
      # the same shape `gh` itself derives from a remote URL, and it covers the
      # scp-form (`git@host:owner/name.git`) and URL forms alike because both
      # `:` and `/` separate segments. An unparseable remote is "cannot tell
      # which repository I am about to rewrite", which is the outage answer.
      # NO INDENTED PYTHON LINES. `tests/review-pr-phase3-ci.test.sh` S34-FENCE
      # extracts THIS fence and runs it for real, and its extractor strips four
      # leading spaces from every line — which is exactly the four spaces a
      # nested python block would use. An indented block therefore arrives as an
      # IndentationError under execution, halting the gate
      # `ci_dependent_pr_probe_unreadable` on every run. Single-line `if` and a
      # comprehension keep every statement at column zero.
      CI_PUSH_REPO_SLUG="$(python3 -I -B -c 'import re,sys
url=re.sub(r"\.git$","",sys.argv[1].strip().rstrip("/")).rstrip("/")
slug="/".join([p for p in re.split(r"[:/]",url) if p][-2:])
if re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+",slug) is None: raise SystemExit(74)
sys.stdout.write(slug)' "$CI_PUSH_REMOTE_URL")" \
        || review_ci_push_abort ci_dependent_pr_probe_unreadable
      # This HALTS on a `gh` failure; it is deliberately NOT the `ci_probe_unreachable`
      # carve-out 6c.1 PROBE applies to a `gh` outage. That carve-out is justified
      # entirely by the probe being READ-ONLY -- an unreachable probe costs a trust
      # signal, not a repository. This gate stands in front of a FORCE-PUSH, and
      # "gh is down" is a different answer from "no PR is stacked on this branch".
      # Same rule, same reason as 6c.4w.0: a probe that cannot read checks may
      # proceed, a push that cannot clear its ref may not.
      #
      # The two outcomes get DIFFERENT typed subreasons on purpose, so an audit
      # consumer can tell "there is a stacked PR" from "I could not ask".
      CI_DEPENDENT_PRS="$(gh pr list --repo "$CI_PUSH_REPO_SLUG" --base "$CI_PR_HEAD_BRANCH" --state open --json number)" \
        || review_ci_push_abort ci_dependent_pr_probe_unreadable
      # rc alone is not enough: a failing `gh` writes prose where the JSON
      # projection should be, and an empty/garbage payload must never read as "no
      # dependents". Shape first, then count -- the `jq length || echo 0` idiom
      # this repository has been bitten by maps a crashed producer onto zero.
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CI_DEPENDENT_PRS" || review_ci_push_abort ci_dependent_pr_probe_unreadable
      CI_DEPENDENT_PR_COUNT="$(jq -r 'length' <<<"$CI_DEPENDENT_PRS")" || review_ci_push_abort ci_dependent_pr_probe_unreadable
      case "$CI_DEPENDENT_PR_COUNT" in '' | *[!0-9]*) review_ci_push_abort ci_dependent_pr_probe_unreadable ;; esac
      [ "$CI_DEPENDENT_PR_COUNT" -eq 0 ] || review_ci_push_abort ci_push_would_rewrite_stacked_base
    fi
    # Explicit-form lease + --force-if-includes. The bare `--force-with-lease`
    # shorthand (which uses @{upstream}) stays forbidden, and so does bare
    # `--force`: only this pair compares the remote against the SHA the
    # controller captured before the child ran.
    # Braced for the same reason as the trust-anchor publish above: under zsh
    # an unbraced `$NEW_HEAD_SHA:refs/...` loses the colon to the `:r` modifier.
    CI_PUSH_STDERR="$(git -C "$WORKTREE_ROOT" push origin "${NEW_HEAD_SHA}:refs/heads/${CI_PR_HEAD_BRANCH}" \
         --force-with-lease="$CI_PR_HEAD_BRANCH":"$CI_LEASE_SHA" \
         --force-if-includes 2>&1 1>/dev/null)" || CI_PUSH_RC=$?
    if [ -n "${CI_PUSH_RC:-}" ]; then
      # Distinguish lease-mismatch (race with an external push during the
      # resume window) from generic push failure (auth, pre-receive hook,
      # rate-limit, network). Both halt; different data.subreason so audit
      # consumers can route.
      if printf '%s' "$CI_PUSH_STDERR" | grep -qE '\[rejected\].*(stale info|fetch first|non-fast-forward)'; then
        review_ci_push_abort rebase_lease_mismatch
      fi
      review_ci_push_abort rebase_push_failed
    fi
    # The push record crosses into the Phase 1 re-entry fence ON DISK, for the
    # same fresh-shell reason the loop counters do.
    review_fleet_write_ci_push "$REVIEW_FLEET_RUN_DIR/ci-last-push.json" \
      "$NEW_HEAD_SHA" "$CI_FIX_BY_AGENT" || return 74
    audit ci_fix_pushed data.commit_sha="$NEW_HEAD_SHA" data.by_agent="$CI_FIX_BY_AGENT"
    ```

    - On push success: fall through to "Phase 1 re-entry" below.
    - On a head that is no longer descended from the base branch tip the
      authority pinned: `data.subreason=ci_push_head_detached_from_base`, exit 1.
      The rebase landed somewhere other than the branch this PR is based on;
      the lease cannot see that, because the lease only guards this PR's head.
    - On a REWRITING push to a branch another open PR is based on:
      `data.subreason=ci_push_would_rewrite_stacked_base`, exit 1. Nothing is
      pushed. A fast-forward push is not gated — it cannot move a dependent
      PR's merge-base — so this halt never fires on the `fix_code` edge.
    - When the dependent-PR question cannot be asked at all (`gh` failure,
      non-array payload, unparseable `origin` URL):
      `data.subreason=ci_dependent_pr_probe_unreadable`, exit 1. "I could not
      ask" is a different answer from "nobody is stacked", and unlike 6c.1's
      read-only probe this one stands in front of a force-push, so it does
      **not** take the `ci_probe_unreachable` carve-out.
    - On lease mismatch (`origin/$CI_PR_HEAD_BRANCH` no longer matches the
      pinned lease): `git rebase --abort` if one is live,
      `data.subreason=rebase_lease_mismatch`, exit 1. An external push landed
      during the window; the user re-issues `/review-pr` against the new HEAD.
    - On any other push failure: `data.subreason=rebase_push_failed`, exit 1.

    ### 6c.5 POST-FIX — re-enter Phase 1 fanout

    **Branch on the VALIDATED terminal, never on the agent's self-report.** The
    scalar is `CI_FIXER_TERMINAL_STATUS` from 6c.4w.2 —
    `validate-ci-mutation-outcome`'s answer, derived from real git state. Only
    `APPLIED` (fix_code) and `REBASED` (rebase) produce new history that
    warrants a push and Phase 1 re-entry. `CONFLICT` (rebase) triggers the
    CONFLICT-RESOLVE arm below; refusal statuses halt Phase 3. The agent return
    contracts below name the same terminals, and the agent's own YAML is
    logging only — a `ci-rebase-handler` that reported `REBASED` over a
    conflicted rebase is judged `CONFLICT` here and routed accordingly:

    - `CI_FIXER_TERMINAL_STATUS=APPLIED` — `ci-code-fixer` `status: APPLIED` (commit SHA returned, no remote write per `agents/ci-code-fixer.md` Step 6) → run **6c.4w.3 THE SINGLE LEASED PUSH**, then fall through to "Phase 1 re-entry" below.
    - `CI_FIXER_TERMINAL_STATUS=NO_CHANGE` — the fixer made no commit at all **and declared no refusal**. There is nothing to push and nothing new to review: do **not** run 6c.4w.3, do **not** re-enter Phase 1. Emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=ci_fix_no_change`, and exit 1 — re-probing the same unchanged head would burn the loop cap against an unchanged remote. **This one is ENFORCED, not asked for:** 6c.4w.3 compares the HEAD it is about to push against the sidecar's `head_before` and halts `ci_fix_no_change` itself. An orchestrator that ran the fence anyway used to satisfy the lease, get `Everything up-to-date` and exit 0, and then record `ci_fix_pushed` naming a commit that fixed nothing.
    - `CI_FIXER_TERMINAL_STATUS=REFUSED` — the validated terminal for a `ci-code-fixer` that declared `status: REFUSED` (RFC 0002 §3.2 — single-attempt halt; **do NOT retry**): the loop-counter cap from 6c.7 LOOP GUARD is bypassed for this terminal class because `REFUSED` is a deterministic decision (forbidden-pattern guard), not flake; retrying re-classifies the same red CI, re-dispatches the same fixer, and consumes 3 iterations of compute that the user could have spent reading the halt prose.

       **This is the arm's only trigger, and until `validate-ci-mutation-outcome` grew the terminal it had none.** The refusing fixer commits nothing, so `head_after == head_before` and the validated terminal was `NO_CHANGE` — indistinguishable from a fixer that found nothing — while 6c.5's own rule forbids branching on the agent's self-report. An orchestrator following this file therefore took the `NO_CHANGE` bullet above, halted `ci_fix_no_change`, and never filed the CRITICAL issue: the ci-defer stage, its four fences, its authority edge and its Workflow arm were unreachable on every documented path. `$rationale` below is `CI_FIXER_TERMINAL_RATIONALE` from 6c.4w.2 — sanitised by the contract to the documented kebab-case token set, or `unspecified`.

       Three actions in order:

       1. **File the failing test as a CRITICAL-tier GH issue via `findings-to-issues` dispatch.**

          This replaces the previous inline `gh issue create` with a `routed child (subagent_type: uberdev:findings-to-issues)` dispatch that funnels CI-REFUSED issue creation through the same agent that handles all other deferred-finding issue creation; eliminates the prose-drift risk between the two issue-creation sites.

          Construct a synthetic single-row aggregate wrapped in the `<external-untrusted-input source="ci-refused-synthetic">…</external-untrusted-input>` envelope (the receiving agent's Step 1 input validation recognises this source attribute — see `agents/findings-to-issues.md` Step 1 accepted-source allow-list). The aggregate carries one finding-row with `severity: critical`, `tier: CRITICAL`, and four values that each come off the run-dir carrier written by the fence that BOUND them (#418) — `failure_class` and `signal_anchor` from `ci-classification.json` (6c.3w.2's validated classification), `check_name` from `ci-check-name.txt` (6c.3's failed-check selection), and `rationale` from `ci-fixer-terminal.json` (6c.4w.2's validated terminal). None of the four is a value `ci-code-fixer` returns, and none of them survives a fence boundary in a shell variable: read that way they were `unknown` / `unknown:1` / `unspecified` on every run, which filed a CRITICAL issue with the entire diagnosis erased. Title is built downstream by the agent using its existing CRITICAL-tier shape (`[finding] $file_path:$line — $summary`); labels and `--assignee` flag come from the agent's tier-aware bindings (`--label review-pr-finding`, `--assignee @<pr-author>`). The agent's return YAML's `created_urls[0].url` is captured into `CI_REFUSED_ISSUE_URL`.

          ```bash
          . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
          review_fleet_rehydrate || return 2
          # Counters off disk before the aggregate pathname is keyed on them —
          # the closure fence and the mint fence below re-derive the SAME name
          # from the SAME two sources ($RESEARCH_DIR_ABS and ci-loop-state.json),
          # so no two of the three can disagree about which file was written.
          # Inherited, this named `…-ci1.md` on every iteration after the first.
          review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
          # The terminal comes off the SAME disk the counters do (#399). This is
          # a different shell from 6c.4w.2, so the inherited
          # `${CI_FIXER_TERMINAL_RATIONALE:-unspecified}` below was literally
          # always `unspecified` — every CI-refusal issue was filed with the
          # refusal reason erased, and the halt subreason with it. Refusing an
          # unreadable record is the only safe answer: a synthetic CRITICAL
          # issue that names no cause is worse than a typed halt.
          #
          # It reads it HERE and not in the closure fence below on purpose: this
          # fence is the one that writes the aggregate, so this is the fence
          # whose output is wrong when the rationale is missing. Keeping the
          # halt out of the closure builder also keeps that builder a pure
          # payload oracle — `tests/review-child-inputs.test.sh` executes it in
          # isolation, and a builder that first demands three Phase 3 artifacts
          # is a builder no oracle can execute.
          CI_FIXER_TERMINAL_CARRIER="$(cd "$RESEARCH_DIR_ABS" && pwd -P)/ci-fixer-terminal.json" || return 74
          [ -s "$CI_FIXER_TERMINAL_CARRIER" ] || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_terminal_uncarried; exit 1; }
          CI_FIXER_TERMINAL_STATUS="$(jq -er '.status' <"$CI_FIXER_TERMINAL_CARRIER")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_terminal_uncarried; exit 1; }
          CI_FIXER_TERMINAL_RATIONALE="$(jq -er '.rationale' <"$CI_FIXER_TERMINAL_CARRIER")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_terminal_uncarried; exit 1; }
          # This arm exists for exactly one terminal. Reaching it on any other
          # one means the orchestrator routed off a stale or mis-read value, and
          # filing a CRITICAL refusal issue for a fixer that did not refuse is
          # not a recoverable mistake.
          [ "$CI_FIXER_TERMINAL_STATUS" = REFUSED ] || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_terminal_mismatch; exit 1; }
          # The other three finding-row values, off the carriers written by the
          # fences that BOUND them (#418). Read as shell variables they were the
          # empty string here — a different shell again — so the aggregate went
          # out as `unknown` / `unknown:1`: an issue that names neither the
          # failure class, nor the check, nor the file:line, filed at CRITICAL
          # against a human. That is the same failure as the erased rationale
          # above, and it takes the same answer: refuse, typed, rather than file
          # a diagnosis nobody can act on.
          # `[ -n … ]` first: under /bin/zsh `cd ""` succeeds and stays put, so
          # an unbound run dir would read the carriers from whatever directory
          # this fence happened to start in.
          CI_REFUSED_CARRIER_DIR=
          if [ -n "${RESEARCH_DIR_ABS:-}" ]; then
            CI_REFUSED_CARRIER_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || CI_REFUSED_CARRIER_DIR=
          fi
          [ -n "$CI_REFUSED_CARRIER_DIR" ] || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_unreadable; exit 1; }
          CI_REFUSED_FAILURE_CLASS="$(review_fleet_read_ci_classification "$CI_REFUSED_CARRIER_DIR/ci-classification.json" failure_class)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_unreadable; exit 1; }
          CI_REFUSED_SIGNAL_ANCHOR="$(review_fleet_read_ci_classification "$CI_REFUSED_CARRIER_DIR/ci-classification.json" signal_anchor)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_classification_unreadable; exit 1; }
          CI_REFUSED_CHECK_NAME="$(review_fleet_read_ci_check_name "$CI_REFUSED_CARRIER_DIR/ci-check-name.txt")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_check_name_unreadable; exit 1; }
          CI_REFUSED_AGGREGATE_PATH="$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md"
          if ! (umask 077; set -C; : >"$CI_REFUSED_AGGREGATE_PATH"); then
            audit ci_phase_outcome data.outcome=halted data.subreason=ci_refused_aggregate_create_failed
            exit 1
          fi
          # The rationale is the VALIDATED one from 6c.4w.2
          # (CI_FIXER_TERMINAL_RATIONALE), not a re-read of the child's YAML:
          # `validate-ci-mutation-outcome` already sanitised it to the
          # documented kebab-case token set, and the same value feeds the halt
          # prose and `data.subreason=ci_fixer_refused_<rationale>` below. Every
          # positional below is now a carrier-read scalar with its own halt, so
          # `${...:-<placeholder>}` is gone from all four: a defaulted diagnosis
          # is indistinguishable from a real one once the issue is filed.
          python3 -I -B - "$CI_REFUSED_AGGREGATE_PATH" "$CI_REFUSED_FAILURE_CLASS" \
            "$CI_REFUSED_CHECK_NAME" "$CI_REFUSED_SIGNAL_ANCHOR" "$CI_FIXER_TERMINAL_RATIONALE" <<'PY'
import json,os,stat,sys
path,failure_class,check_name,signal_anchor,rationale=sys.argv[1:]
if any(len(value)>8192 or any(char in value for char in '\r\n\0') for value in (failure_class,check_name,signal_anchor,rationale)):
    raise SystemExit(2)
entry=os.lstat(path); uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode) or entry.st_nlink!=1
        or (uid is not None and entry.st_uid!=uid) or entry.st_size!=0
        or (os.name!='nt' and stat.S_IMODE(entry.st_mode)!=0o600)):
    raise SystemExit(2)
row={'severity':'critical','tier':'CRITICAL','agent_name':'ci-code-fixer',
     'failure_class':failure_class,'check_name':check_name,'location':signal_anchor,
     'summary':'CI fixer refused the classified failure','rationale':rationale,
     'disposition':'REFUSED'}
payload=('<external-untrusted-input source="ci-refused-synthetic">\n- '
         +json.dumps(row,sort_keys=True,separators=(',',':'))
         +'\n</external-untrusted-input>\n').encode('utf-8')
fd=os.open(path,os.O_WRONLY|getattr(os,'O_NOFOLLOW',0))
try:
    opened=os.fstat(fd); current=os.lstat(path)
    if (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino): raise SystemExit(2)
    if os.write(fd,payload)!=len(payload): raise SystemExit(2)
    os.fsync(fd)
finally:
    os.close(fd)
with open(path,'rb') as stream:
    if not stream.read(128).startswith(b'<external-untrusted-input source="ci-refused-synthetic">'):
        raise SystemExit(2)
PY
          if [ "$?" -ne 0 ]; then
            audit ci_phase_outcome data.outcome=halted data.subreason=ci_refused_aggregate_write_failed
            exit 1
          fi
          ```

          The closure is built in its OWN fence, the way every other
          `review_pr.ci.*` edge builds one. It re-derives
          `CI_REFUSED_AGGREGATE_PATH` from the same two run-invariant sources
          the mint fence below uses (`$RESEARCH_DIR_ABS` and
          `ci-loop-state.json`) rather than inheriting it, because the fence
          above has already ended.

          ```bash
          . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
          review_fleet_rehydrate || return 2
          # Counters off disk before the aggregate pathname is keyed on them, in
          # THIS fence — the aggregate-mint fence above and the launch-mint
          # fence below each read them for themselves, so all three land on the
          # same name without any of them inheriting it.
          review_fleet_load_ci_counters "$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 74
          CI_REFUSED_AGGREGATE_PATH="$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md"
          CI_DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.ci.defer_refusal \
            phase1_path "$(review_json_string "$CI_REFUSED_AGGREGATE_PATH")" \
            working_dir "$(review_json_string "$WORKTREE_ROOT")" \
            pr_number "$PR_NUMBER")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_defer_inputs_invalid; exit 1; }
          ```

          **ci-defer stage — mint, bind, emit.**

          ```bash uberdev-executable origin=review-pr
          . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
          review_fleet_rehydrate || return 2
          REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
          [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
          . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
          . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
          REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
          REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
          mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
          review_ci_authority_digest() {
            [ "$#" -ge 3 ] || return 2
            python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
if (set(value)!={"authority_path","authority_sha256","edge_id","phase"}
        or value["authority_path"]!=sys.argv[2]
        or value["edge_id"]!=sys.argv[3]
        or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None):
    raise SystemExit(74)
print(value["authority_sha256"],end="")' "${@:1:1}" "${@:2:1}" "${@:3:1}"
          }
          # Self-contained, exactly like the classify/fix mint fences: counters
          # off disk, the aggregate pathname re-derived from them, and the run
          # identity read back out of the digest-pinned ci-fix authority.
          # Inherited, all of those were empty in a fresh shell and
          # `review_fleet_child_dir "$RUN" "" "$SLUG"` returns rc=2.
          #
          # The child input CLOSURE is the one value that stays in its own
          # builder fence, and that is deliberate and uniform: all five
          # review_pr.ci.* edges build their closure in a plain fence and mint
          # here, and tests/review-child-inputs.test.sh extracts exactly one
          # fence per edge and executes it as an isolated payload oracle. So the
          # guard, not a re-derivation, is what makes the boundary safe — an
          # unset CI_DEFER_INPUTS would otherwise write a 1-byte input.json that
          # passes `--minimum 1` and is then pinned by digest as garbage.
          review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
          CI_REFUSED_AGGREGATE_PATH="$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md"
          [ -s "$CI_REFUSED_AGGREGATE_PATH" ] || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_refused_aggregate_missing; exit 1; }
          printf '%s' "${CI_DEFER_INPUTS:-}" | jq -e 'type == "object"' >/dev/null 2>&1 \
            || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_defer_inputs_invalid; exit 1; }
          CI_FIX_SIDECAR="$(review_fleet_read_ci_pointer "$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer.txt")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
          CI_FIX_BINDING="$(review_fleet_read_sidecar "$CI_FIX_SIDECAR" binding)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
          CI_FIX_AUTHORITY_PATH="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_path)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
          CI_FIX_AUTHORITY_SHA256="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_sha256)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
          CI_RUN_ID="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
            --authority-path "$CI_FIX_AUTHORITY_PATH" --authority-sha256 "$CI_FIX_AUTHORITY_SHA256" \
            --member run_id)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_authority_unreadable; exit 1; }
          CI_CLASSIFICATION_HEAD_SHA="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
            --authority-path "$CI_FIX_AUTHORITY_PATH" --authority-sha256 "$CI_FIX_AUTHORITY_SHA256" \
            --member head_sha)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_authority_unreadable; exit 1; }
          CI_DEFER_SLUG="$(review_fleet_ci_slug ci-defer "${CI_FIX_LOOP_ITER:-1}")" || return 2
          CI_DEFER_CHILD_DIR="$(review_fleet_child_dir "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" "$CI_DEFER_SLUG")" || return 2
          mkdir -p "$CI_DEFER_CHILD_DIR" || return 2
          ( umask 077 && printf '%s\n' "$CI_DEFER_INPUTS" >"$CI_DEFER_CHILD_DIR/input.json" ) || return 74
          CI_DEFER_INPUT_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$CI_DEFER_CHILD_DIR/input.json" --minimum 1 --maximum 1048576)" || return 74
          CI_REFUSED_AGGREGATE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$CI_REFUSED_AGGREGATE_PATH" --minimum 1 --maximum 1048576)" || return 74
          CI_AUTHORITY_PATH="$REVIEW_FLEET_RUN_DIR/ci-authority-defer-refusal-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.json"
          CI_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-ci-authority \
            --edge-id review_pr.ci.defer_refusal \
            --pr-number "$PR_NUMBER" --run-id "$CI_RUN_ID" --head-sha "$CI_CLASSIFICATION_HEAD_SHA" \
            --working-dir "$REVIEW_FLEET_WORKTREE" \
            --input-path "$CI_DEFER_CHILD_DIR/input.json" --input-sha256 "$CI_DEFER_INPUT_SHA256" \
            --authority-output-path "$CI_AUTHORITY_PATH")" || return 74
          CI_AUTHORITY_SHA256="$(review_ci_authority_digest "$CI_AUTHORITY_RECEIPT" "$CI_AUTHORITY_PATH" review_pr.ci.defer_refusal)" || return 74
          REVIEW_FLEET_CI_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-ci-defer-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launch.json"
          review_fleet_bind_ci review_pr.ci.defer_refusal "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
            "${CI_FIX_LOOP_ITER:-1}" "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
            "$CI_AUTHORITY_PATH" "$CI_AUTHORITY_SHA256" '' "$REVIEW_FLEET_CI_SIDECAR" || return 74
          uberdev_emit_workflow_args review-fleet \
            mode=review-pr \
            stage=ci-defer \
            run_id="$RUN_ID" \
            runId="$RUN_ID" \
            runDirAbs="$REVIEW_FLEET_RUN_DIR" \
            pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
            repoRootAbs="$REVIEW_FLEET_WORKTREE" \
            workingDirAbs="$REVIEW_FLEET_WORKTREE" \
            prNumber="$PR_NUMBER" \
            repoSlug="$REVIEW_REPO_SLUG" \
            reviewIteration="$REVIEW_ITERATION" \
            ciLoopIter="${CI_FIX_LOOP_ITER:-1}" \
            ciAuthorityPathAbs="$CI_AUTHORITY_PATH" \
            ciAuthoritySha256="$CI_AUTHORITY_SHA256" \
            ciInputSha256="$CI_DEFER_INPUT_SHA256" \
            ciAggregatePathAbs="$CI_REFUSED_AGGREGATE_PATH" \
            ciAggregateSha256="$CI_REFUSED_AGGREGATE_SHA256" \
            ciRunId="$CI_RUN_ID" \
            ciHeadSha="$CI_CLASSIFICATION_HEAD_SHA" \
            maxNew=10 \
            maxAgents=40 \
            workspaceMode=caller \
            worktreeAbs="$REVIEW_FLEET_WORKTREE" \
            branchName= \
            runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
          ```

          **Workflow mandate:** relay the JSON between
          `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

          ```
          Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
          ```

          **ci-defer capture.** The script's `issues` return supplies counts and
          URLs for the Step 7 table only; the terminal comes from the child's own
          frozen result bytes. `validate-ci-persistence-result` shares the fence
          parser with `validate-persistence-result` but NOT its schema-v2 blocker
          recount — this stage's aggregate is the one-row `ci-refused-synthetic`
          envelope, which that recount cannot parse.

          ```bash uberdev-executable origin=review-pr
          . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
          review_fleet_rehydrate || return 2
          . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
          REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
          review_ci_json_member() {
            [ "$#" -ge 2 ] || return 2
            python3 -I -B -c 'import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
member=value[sys.argv[2]]
print(member if isinstance(member,str) else json.dumps(member,separators=(",",":")),end="")' "${@:1:1}" "${@:2:1}"
          }
          review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
          REVIEW_FLEET_CI_SIDECAR="$REVIEW_FLEET_RUN_DIR/review-fleet-ci-defer-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launch.json"
          CI_DEFER_BINDING="$(review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" binding)" || { CI_REFUSED_ISSUE_URL=""; CI_DEFER_STATUS=MALFORMED; }
          if [ "${CI_DEFER_STATUS:-}" != MALFORMED ]; then
            CI_DEFER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-ci-terminal \
              --launch-binding-json "$CI_DEFER_BINDING" --edge-id review_pr.ci.defer_refusal)" \
              || CI_DEFER_STATUS=MALFORMED
          fi
          if [ "${CI_DEFER_STATUS:-}" != MALFORMED ]; then
            CI_DEFER_STATUS_SHA256="$(review_ci_json_member "$CI_DEFER_TERMINAL" status_sha256)" || return 74
            CI_DEFER_RESULT_SHA256="$(review_ci_json_member "$CI_DEFER_TERMINAL" result_sha256)" || return 74
            CI_DEFER_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-ci-persistence-result \
              --launch-binding-json "$CI_DEFER_BINDING" \
              --status-sha256 "$CI_DEFER_STATUS_SHA256" --result-sha256 "$CI_DEFER_RESULT_SHA256")" \
              || CI_DEFER_STATUS=MALFORMED
          fi
          if [ "${CI_DEFER_STATUS:-}" = MALFORMED ]; then
            # Fail-soft on the ISSUE, fail-loud on the HALT: the CI-REFUSED halt
            # prose and audit record below still emit, with an empty issue slot.
            echo "warning: findings-to-issues dispatch REFUSED — rationale: ci_defer_terminal_invalid; CI-REFUSED issue NOT filed (halt prose + audit will still emit)" >&2
            CI_REFUSED_ISSUE_URL=""
          else
            # THE SUCCESS PATH, which had no assignment at all: the only two
            # sites that ever bound CI_REFUSED_ISSUE_URL were the MALFORMED
            # branches, so the halt prose's `filed issue:` line and the audit
            # field `phases.phase3.ci_refused_issue_url` referenced an unbound
            # variable exactly when the filing had WORKED. The URL now rides the
            # validated receipt (`created_urls[0].url`, shape-checked by
            # `validate-ci-persistence-result`), never a re-parse of the child's
            # YAML here. Empty when the child filed nothing.
            CI_REFUSED_ISSUE_URL="$(review_ci_json_member "$CI_DEFER_RECEIPT" created_url)" || return 74
          fi
          ```

          `CI_REFUSED_AGGREGATE_PATH` is a fresh command-owned artifact at `$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md`, created with `umask 077` and noclobber before writing the envelope. It must remain beneath the canonical run research directory so the child handoff's `path` validation accepts it; do not use system `mktemp` or any path outside `$WORKTREE_ROOT`. Its first 128 bytes contain the literal envelope marker shown above (source attribute `ci-refused-synthetic`).

          After dispatch returns, the caller captures TWO fields — but neither from a re-parse of the agent's YAML here. `CI_REFUSED_ISSUE_URL` comes off the VALIDATED receipt's `created_url` member (`validate-ci-persistence-result` extracts `created_urls[0].url` from the frozen result bytes and shape-checks it against `https://github.com/<owner>/<repo>/issues/<n>`; empty string when the child filed nothing), and `$rationale` is `CI_FIXER_TERMINAL_RATIONALE` from 6c.4w.2 — the `ci-code-fixer`'s refusal reason, which is the one this arm's prose and audit subreason are about.

          If the agent's return YAML contains `status: REFUSED`, the caller emits one explicit stderr line — parameterised on the agent's actual `rationale` so all four REFUSED classes (`input-malformed`, `rate-limit-probe-failed`, `rate-limit-budget-insufficient`, `secret-scan-lib-unavailable`) surface accurately — and proceeds to actions 2 + 3 with `CI_REFUSED_ISSUE_URL=""` (the halt prose still emits; the audit record still fires; the issue URL slot is just empty).

          The literal `warning:` text shape is the contract — the operator searches their run logs for the `warning: findings-to-issues dispatch REFUSED` prefix:

          ```
          warning: findings-to-issues dispatch REFUSED — rationale: $rationale; CI-REFUSED issue NOT filed (halt prose + audit will still emit)
          ```

       2. **Emit user-visible halt prose** (stderr, regardless of `TURBO` — mirrors the `billing_quota` / `platform_outage` 6c.6 HALT shape):

          ```
          /uberdev:review-pr — Phase 3 halt: ci-code-fixer REFUSED
            failure class:   $CI_REFUSED_FAILURE_CLASS
            signal anchor:   $CI_REFUSED_SIGNAL_ANCHOR
            rationale:       $CI_FIXER_TERMINAL_RATIONALE (e.g. forbidden-pattern-no-verify)
            filed issue:     $CI_REFUSED_ISSUE_URL
            next step:       /uberdev:solve $CI_REFUSED_ISSUE_URL  (or fix manually)
          ```

          The three diagnosis lines name the carrier-read scalars from action 1,
          not `$failure_class` / `$signal_anchor` / `$rationale`: those were
          bound in fences this prose's shell never shared, so the halt message
          the operator actually saw carried three empty fields (#418).

       3. **Audit + exit** — emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=ci_fixer_refused_<rationale>` (lowercase, dashes-to-underscores normalised, e.g. `forbidden-pattern-no-verify` → `ci_fixer_refused_forbidden_pattern_no_verify`); record `CI_REFUSED_ISSUE_URL` in the audit JSON under `phases.phase3.ci_refused_issue_url`; exit 1.

       Under `TURBO=1`, the same three actions fire — the prose goes to stderr, the issue is still filed (no `AskUserQuestion` involved here; this is a deterministic halt, not a user-choice gate), and exit 1 surfaces to the orchestrator chain.
    - `CI_FIXER_TERMINAL_STATUS=REBASED` — `ci-rebase-handler` `status: REBASED, new_head_sha: <40-hex>`; the rebase applied cleanly and NOTHING is on the remote yet, because that agent was demoted from pusher to preparer (`agents/ci-rebase-handler.md`, `git push` on its denylist, and no lease-SHA capture of its own) → run **6c.4w.3 THE SINGLE LEASED PUSH**, then fall through to "Phase 1 re-entry" below. Do not re-add an agent-held lease here: an LLM choosing the SHA git compares against is exactly the hole that demotion closes.
    - `CI_FIXER_TERMINAL_STATUS=CONFLICT` — `ci-rebase-handler` `status: CONFLICT, conflict_count: <int>`, rebase left **IN PROGRESS** (Step 5 forbids `git rebase --abort`; that live mid-rebase state IS the `ci-conflicts` stage's input) → execute the **CONFLICT-RESOLVE arm** below (steps 1–3), then **6c.4w.3**, BEFORE Phase 1 re-entry. The return carries a COUNT, never a path list — the arm's step 1 enumerates the paths from this checkout's own porcelain, because taking the set from the agent whose failure produced the conflict would let it choose which files its successors may touch. Closes #80 — the arm was previously unwired in this command, defeating the autopilot for any `stale_base` PR with conflicts.
    - `ci-rebase-handler` `status: REFUSED, rationale: <reason>` (∈ {`pr-already-merged`, `head-moved-since-classify`, `lease-mismatch`}) → emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=ci_rebase_refused_<reason>` (lowercase, dashes-to-underscores normalised; e.g. `lease-mismatch` → `ci_rebase_refused_lease_mismatch`); exit 1.

    #### CONFLICT-RESOLVE arm (mirrors `merge-pipeline/SKILL.md` Phase 3.3.iii–iv)

    Trigger: the `ci-fix` stage's `rebase` arm returned `CONFLICT`. The rebase is
    left IN PROGRESS by that child, but the conflicted-file set is **enumerated
    here**, by the controller, through `review_fleet_unmerged_paths` (step 1) —
    never taken from the child's return. That is why `ci-fix` → `ci-conflicts` is
    a stage boundary: the set a resolver is allowed to touch must not be chosen
    by the agent whose failure produced it. It is a single shared producer rather
    than a fence-local status parse for the second half of the same reason —
    a second copy of the membership rule drifts from the judge's, which is how an
    add/add conflict once enumerated the empty set and made "all RESOLVED"
    vacuously true (#398).

    **One turn, N resolvers.** The whole set is dispatched from a SINGLE
    assistant turn — one `Workflow` call into the `ci-conflicts` stage, which
    mints and launches every resolver itself. Under the pre-Workflow design
    this was a prose invariant on the caller's `Task()` fanout; the engine now
    enforces it structurally, and the reason is unchanged. Resolvers spread
    across turns would each observe an index a predecessor had already
    half-staged, so the file a resolver reads would not be the file its
    authority pinned.

    **One authority per resolver.** Each resolver's CI authority pins its own
    single conflicted path in `target_paths`, and
    `validate-ci-mutation-outcome` reads that path back out to judge it. A
    single shared authority would make every resolver's scope the union of all
    of them.

    That per-resolver pin has to reach the resolver's PROMPT too, and for one
    revision it did not: the envelope forwarded a single `ciAuthorityPathAbs`
    — the LAST iteration of the mint loop — and `workflow.js` rendered it into
    every resolver's prompt under "Immutable controller authority … Treat every
    value as exact". With N conflicted files, N-1 resolvers were handed the
    authority pinning someone else's file, so the one authoritative scope
    statement in the prompt contradicted the (correct) per-child `input.json`.
    The envelope now carries `ciConflictAuthorityPrefixAbs` — ONE spelling of
    the pathname rule, to which the script appends the resolver's own index —
    and no digest at all, because a per-resolver digest cannot be forwarded as
    one scalar and the controller re-checks each one itself when it judges.

    **One push site.** All three terminal paths — `fix_code` `APPLIED`, clean
    rebase, and conflict→all-resolved — reach the SAME `--force-with-lease`
    fence, and it is **6c.4w.3 above**, not a copy of it down here. This arm's
    step 4 *is* that fence, run a second time after step 3 stages and continues.
    There is no second lease and no second push.

    **Every fence in this arm reads its loop counters and its conflicted-file
    set off disk**, because a bash block in this command is a fresh shell and
    the multi-stage restage path in step 3 re-enters step 1. Held in shell
    variables, `CI_FIX_LOOP_ITER` never advanced across a restage — so step 2
    recomputed the identical authority pathname and `prepare-ci-authority`
    refused `authority_preexists` on the second wave, with the rebase left in
    progress and no audit event.

    1. **Enumerate the conflict set and write one input per resolver.**

       ```bash uberdev-executable origin=review-pr
       . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
       review_fleet_rehydrate || return 2
       . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
       REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
       REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
       mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
       review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
       # The only cap this fence consumes is REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP,
       # below: the enumerator's job is to refuse a set that is simply too large
       # to auto-resolve. `fanout_concurrency.conflict_resolver` is the WAVE
       # SIZE — a concurrency knob whose documented behaviour is "split into
       # ceil(N / cap) sequential waves" — and it belongs to step 2, which
       # re-resolves it from config itself. It used to be read HERE too and then
       # never used, which read as a cross-fence handoff the design forbids and
       # invited a future edit to delete step 2's (load-bearing) re-read.
       #
       # THE SET COMES FROM ONE PLACE, and this fence is not it.
       # `review_fleet_unmerged_paths` runs `code_fixer_contract.py
       # list-ci-unmerged-paths`, so the membership question is answered by
       # `_ci_is_unmerged_pair` — the SAME definition
       # `_validate_ci_rebase_outcome` used when it accepted this rebase as
       # CONFLICT. A second copy of that vocabulary here is precisely the #398
       # defect: hand-rolled matching of the two exact bytes `UU` enumerated
       # ZERO files for an add/add conflict (porcelain `AA`, which is what git
       # records when neither side has a common ancestor blob), so this fence
       # aborted `rebase_conflict_set_empty` on the very mid-rebase state the
       # judge had just called a conflict — and, in the staging fence below, made
       # "all RESOLVED" vacuously true over an empty set. Routing through the
       # producer also inherits `_ci_porcelain_entries`' rename/copy-origin
       # skipping (a rename emits TWO NUL fields for ONE entry) and its
       # offset-2 space check, neither of which a shell copy would get for free.
       #
       # THREE outcomes, not two: rc 1 is "the probe answered, nothing is
       # unmerged" and rc 2 is "the probe itself failed" (python3 missing, git
       # state unreadable). Collapsing them is the same silent-empty class, so
       # they halt under DIFFERENT subreasons.
       #
       # The set has to survive into step 3's staging fence, three fences and one
       # Workflow call later, so the enumerator writes it straight to disk:
       # NUL-delimited (a conflicted path may contain a space or a newline),
       # never a shell array, and read back with `read -r -d ''` because these
       # fences run under /bin/zsh, where bash's array-slurp builtin does not
       # exist and fails to an EMPTY array with nothing consuming its 127.
       CONFLICT_PATHS_FILE="$REVIEW_FLEET_RUN_DIR/ci-conflict-paths-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.zlist"
       CONFLICT_ENUM_RC=0
       review_fleet_unmerged_paths "$WORKTREE_ROOT" "$CODE_FIXER_CONTRACT" \
         "$CONFLICT_PATHS_FILE" || CONFLICT_ENUM_RC=$?
       case "$CONFLICT_ENUM_RC" in
         0) ;;
         1) git -C "$WORKTREE_ROOT" rebase --abort || true
            audit ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_set_empty
            exit 1 ;;
         *) git -C "$WORKTREE_ROOT" rebase --abort || true
            audit ci_phase_outcome data.outcome=halted data.subreason=rebase_enumerate_failed
            exit 1 ;;
       esac
       conflicted_files=()
       while IFS= read -r -d '' CONFLICT_ROW; do
         conflicted_files+=("$CONFLICT_ROW")
       done <"$CONFLICT_PATHS_FILE"
       if [ "${#conflicted_files[@]}" -eq 0 ]; then
         git -C "$WORKTREE_ROOT" rebase --abort || true
         audit ci_phase_outcome data.outcome=halted data.subreason=rebase_enumerate_failed
         exit 1
       fi
       # Refuse HERE, with a reason that names the real cause, rather than
       # minting N authorities and N bindings and letting the script abort on
       # `bad_ci_conflict_count` — a refusal whose data names the count and
       # never says the set was simply too large to auto-resolve.
       if [ "${#conflicted_files[@]}" -gt "$REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP" ]; then
         git -C "$WORKTREE_ROOT" rebase --abort || true
         audit ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_set_too_large
         exit 1
       fi
       ```

    2. **Mint one authority + one binding per conflicted file, then emit.**

       ```bash uberdev-executable origin=review-pr
       . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
       review_fleet_rehydrate || return 2
       . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
       . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" || return 2
       REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
       REVIEW_FLEET_WORKTREE="$(cd "$WORKTREE_ROOT" && pwd -P)" || return 2
       review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
       # EVERY cross-fence scalar this fence needs, re-derived HERE.
       #
       # 6c.4 ROUTE, 6c.3w.2 and step 1 are all dead shells by now, and under
       # `set -u` a nested `$(review_json_string "$CI_BASE_SHA")` kills only the
       # INNER subshell: the parent stays rc=0 and the child's pinned input.json
       # gets an EMPTY value with no error at all. `CONFLICT_RESOLVER_CAP` was
       # worse — a bare unset expansion in the argument list, which under
       # `set -u` kills the fence with a raw "unbound variable", no audit and no
       # rebase cleanup. The branches, the base sha and the run identity all
       # live as required members of the digest-pinned ci-fix rebase authority,
       # so they are read back through `read-ci-authority-member` (never `jq` —
       # jq would read the document without re-checking the digest) and the cap
       # is re-resolved from config, which is idempotent by construction.
       CONFLICT_RESOLVER_CAP="$(uberdev_read_int_in_range fanout_concurrency.conflict_resolver UBERDEV_FANOUT_CONFLICT_RESOLVER 1 50 10)" || CONFLICT_RESOLVER_CAP=10
       CI_FIX_SIDECAR="$(review_fleet_read_ci_pointer "$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer.txt")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
       CI_FIX_BINDING="$(review_fleet_read_sidecar "$CI_FIX_SIDECAR" binding)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
       CI_REBASE_AUTHORITY_PATH="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_path)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
       CI_REBASE_AUTHORITY_SHA256="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_sha256)" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_fixer_binding_unreadable; exit 1; }
       for CI_AUTHORITY_MEMBER in pr_branch base_branch base_sha run_id head_sha; do
         CI_AUTHORITY_VALUE="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
           --authority-path "$CI_REBASE_AUTHORITY_PATH" --authority-sha256 "$CI_REBASE_AUTHORITY_SHA256" \
           --member "$CI_AUTHORITY_MEMBER")" || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_authority_unreadable; exit 1; }
         [ -n "$CI_AUTHORITY_VALUE" ] || { audit ci_phase_outcome data.outcome=halted data.subreason=ci_authority_unreadable; exit 1; }
         case "$CI_AUTHORITY_MEMBER" in
           pr_branch)   CI_PR_HEAD_BRANCH="$CI_AUTHORITY_VALUE" ;;
           base_branch) CI_BASE_BRANCH="$CI_AUTHORITY_VALUE" ;;
           base_sha)    CI_BASE_SHA="$CI_AUTHORITY_VALUE" ;;
           run_id)      CI_RUN_ID="$CI_AUTHORITY_VALUE" ;;
           head_sha)    CI_CLASSIFICATION_HEAD_SHA="$CI_AUTHORITY_VALUE" ;;
         esac
       done
       CONFLICT_PATHS_FILE="$REVIEW_FLEET_RUN_DIR/ci-conflict-paths-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.zlist"
       conflicted_files=()
       while IFS= read -r -d '' CONFLICT_PATH; do
         conflicted_files+=("$CONFLICT_PATH")
       done <"$CONFLICT_PATHS_FILE"
       [ "${#conflicted_files[@]}" -gt 0 ] || { audit ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_paths_missing; exit 1; }
       REVIEW_FLEET_WORKFLOW_JS="$UBERDEV_REVIEW_PLUGIN_ROOT/skills/review-fleet/workflow.js"
       [ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; return 2; }
       mkdir -p "$REVIEW_FLEET_RUN_DIR/children" || return 2
       review_ci_authority_digest() {
         [ "$#" -ge 3 ] || return 2
         python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
if (set(value)!={"authority_path","authority_sha256","edge_id","phase"}
        or value["authority_path"]!=sys.argv[2]
        or value["edge_id"]!=sys.argv[3]
        or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None):
    raise SystemExit(74)
print(value["authority_sha256"],end="")' "${@:1:1}" "${@:2:1}" "${@:3:1}"
       }
       CONFLICT_AUTHORITY_LEDGER="$REVIEW_FLEET_RUN_DIR/ci-conflict-authorities-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.tsv"
       ( umask 077 && : >"$CONFLICT_AUTHORITY_LEDGER" ) || return 74
       # ONE spelling of the per-resolver authority pathname crosses into the
       # script: this prefix, to which the script appends `<index>.json`. The
       # loop below mints exactly `${CONFLICT_AUTHORITY_PREFIX}${CONFLICT_INDEX}.json`.
       CONFLICT_AUTHORITY_PREFIX="$REVIEW_FLEET_RUN_DIR/ci-authority-resolve-conflict-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}-"
       CONFLICT_INDEX=0
       for CONFLICT_PATH in "${conflicted_files[@]}"; do
         CONFLICT_INDEX=$((CONFLICT_INDEX + 1))
         CONFLICT_SLUG="$(review_fleet_ci_slug "$(printf 'ci-conflict-%02d' "$CONFLICT_INDEX")" "${CI_FIX_LOOP_ITER:-1}")" || return 2
         CONFLICT_CHILD_DIR="$(review_fleet_child_dir "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" "$CONFLICT_SLUG")" || return 2
         mkdir -p "$CONFLICT_CHILD_DIR" || return 2
         CONFLICT_INPUTS="$(uberdev_child_inputs_build review_pr.ci.resolve_conflict \
           file_path "$(review_json_string "$CONFLICT_PATH")" \
           working_dir "$(review_json_string "$WORKTREE_ROOT")" \
           pr_branch "$(review_json_string "$CI_PR_HEAD_BRANCH")" \
           integration_branch "$(review_json_string "$CI_BASE_BRANCH")" \
           base_sha "$(review_json_string "$CI_BASE_SHA")")" || return 74
         ( umask 077 && printf '%s\n' "$CONFLICT_INPUTS" >"$CONFLICT_CHILD_DIR/input.json" ) || return 74
         CONFLICT_INPUT_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$CONFLICT_CHILD_DIR/input.json" --minimum 1 --maximum 1048576)" || return 74
         CONFLICT_AUTHORITY_PATH="${CONFLICT_AUTHORITY_PREFIX}${CONFLICT_INDEX}.json"
         CONFLICT_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-ci-authority \
           --edge-id review_pr.ci.resolve_conflict \
           --pr-number "$PR_NUMBER" --run-id "$CI_RUN_ID" --head-sha "$CI_CLASSIFICATION_HEAD_SHA" \
           --working-dir "$REVIEW_FLEET_WORKTREE" \
           --input-path "$CONFLICT_CHILD_DIR/input.json" --input-sha256 "$CONFLICT_INPUT_SHA256" \
           --base-sha "$CI_BASE_SHA" --pr-branch "$CI_PR_HEAD_BRANCH" --base-branch "$CI_BASE_BRANCH" \
           --target-path "$CONFLICT_PATH" \
           --authority-output-path "$CONFLICT_AUTHORITY_PATH")" || return 74
         CONFLICT_AUTHORITY_SHA256="$(review_ci_authority_digest "$CONFLICT_AUTHORITY_RECEIPT" "$CONFLICT_AUTHORITY_PATH" review_pr.ci.resolve_conflict)" || return 74
         printf '%s\t%s\n' "$CONFLICT_AUTHORITY_PATH" "$CONFLICT_AUTHORITY_SHA256" >>"$CONFLICT_AUTHORITY_LEDGER" || return 74
       done
       CONFLICT_LAUNCHED="$REVIEW_FLEET_RUN_DIR/ci-conflicts-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launched"
       review_fleet_bind_ci_conflicts "$REVIEW_FLEET_RUN_DIR" "$REVIEW_ITERATION" \
         "${CI_FIX_LOOP_ITER:-1}" "$REVIEW_FLEET_WORKTREE" "$CODE_FIXER_CONTRACT" \
         "$CONFLICT_AUTHORITY_LEDGER" "$CONFLICT_LAUNCHED" || return 74
       uberdev_emit_workflow_args review-fleet \
         mode=review-pr \
         stage=ci-conflicts \
         run_id="$RUN_ID" \
         runId="$RUN_ID" \
         runDirAbs="$REVIEW_FLEET_RUN_DIR" \
         pluginRootAbs="$UBERDEV_REVIEW_PLUGIN_ROOT" \
         repoRootAbs="$REVIEW_FLEET_WORKTREE" \
         workingDirAbs="$REVIEW_FLEET_WORKTREE" \
         prNumber="$PR_NUMBER" \
         repoSlug="$REVIEW_REPO_SLUG" \
         reviewIteration="$REVIEW_ITERATION" \
         ciLoopIter="${CI_FIX_LOOP_ITER:-1}" \
         ciConflictAuthorityPrefixAbs="$CONFLICT_AUTHORITY_PREFIX" \
         ciRunId="$CI_RUN_ID" \
         ciHeadSha="$CI_CLASSIFICATION_HEAD_SHA" \
         ciBaseSha="$CI_BASE_SHA" \
         ciPrBranch="$CI_PR_HEAD_BRANCH" \
         ciBaseBranch="$CI_BASE_BRANCH" \
         ciConflictCount="$REVIEW_FLEET_CONFLICT_COUNT" \
         ciConflictCap="$REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP" \
         ciConflictWave="$CONFLICT_RESOLVER_CAP" \
         maxAgents=40 \
         workspaceMode=caller \
         worktreeAbs="$REVIEW_FLEET_WORKTREE" \
         branchName= \
         runNonces="$REVIEW_FLEET_NONCE_POOL" || return 74
       ```

       **Workflow mandate:** relay the JSON between
       `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** into:

       ```
       Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
       ```

    3. **Capture every resolver, then stage and continue.** The push is not
       here: it is 6c.4w.3, the one site all three terminals share.

       ```bash uberdev-executable origin=review-pr
       . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
       review_fleet_rehydrate || return 2
       . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
       REVIEW_FLEET_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || return 2
       review_ci_json_member() {
         [ "$#" -ge 2 ] || return 2
         python3 -I -B -c 'import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
member=value[sys.argv[2]]
print(member if isinstance(member,str) else json.dumps(member,separators=(",",":")),end="")' "${@:1:1}" "${@:2:1}"
       }
       review_ci_conflict_abort() {
         # review_fleet_rebase_dir, never a bare `-d "$(git … --git-path …)"`:
         # that spelling resolves `.git/rebase-merge` against the FENCE's cwd,
         # so from anywhere but the repo root this cleanup silently did nothing
         # and left the worktree mid-rebase.
         if review_fleet_rebase_dir "$WORKTREE_ROOT" >/dev/null; then
           git -C "$WORKTREE_ROOT" rebase --abort || true
         fi
         audit ci_phase_outcome data.outcome=halted data.subreason="${@:1:1}"
         OUTCOME=halted
         exit 1
       }
       CI_LOOP_STATE="$REVIEW_FLEET_RUN_DIR/ci-loop-state.json"
       # THE SHARED READER, like every other Phase 3 fence. This one open-coded
       # it and, unlike the helper, carried no else-branch default — and on the
       # FIRST CI iteration there is no ci-loop-state.json yet (only the
       # re-entry fence and this fence's own restage branch ever write it), so
       # `${REVIEW_ITERATION}` on the next line was a bare unbound expansion
       # under `set -u`: rc=126, zero audit events, `review_ci_conflict_abort`
       # never reached, worktree left mid-rebase. The CONFLICT arm could not
       # complete even once. Two spellings of "read the counters" is exactly the
       # defect review_fleet_load_ci_counters exists to end.
       review_fleet_load_ci_counters "$REVIEW_FLEET_RUN_DIR" || return 74
       # The accumulators are not counters and the helper does not own them;
       # they are read here only so the restage branch below can rewrite the
       # state file without dropping them.
       CI_FIX_PUSHES_JSON='[]'
       CI_CLASSES_JSON='[]'
       if [ -r "$CI_LOOP_STATE" ]; then
         CI_FIX_PUSHES_JSON="$(review_fleet_read_ci_state "$CI_LOOP_STATE" fix_pushes)" || return 74
         CI_CLASSES_JSON="$(review_fleet_read_ci_state "$CI_LOOP_STATE" failure_classes_seen)" || return 74
       fi
       CONFLICT_LAUNCHED="$REVIEW_FLEET_RUN_DIR/ci-conflicts-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.launched"
       [ -s "$CONFLICT_LAUNCHED" ] || review_ci_conflict_abort rebase_conflict_ledger_missing
       # The staged set comes off DISK, from step 1's own unmerged-pair
       # enumeration. Held in
       # a shell array it was empty here, and `git add --` with zero pathspecs
       # prints "Nothing specified, nothing added." and exits 0 — so the guard
       # below never fired and the `rebase --continue` that followed failed on a
       # still-unmerged index, forever.
       CONFLICT_PATHS_FILE="$REVIEW_FLEET_RUN_DIR/ci-conflict-paths-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.zlist"
       [ -s "$CONFLICT_PATHS_FILE" ] || review_ci_conflict_abort rebase_conflict_paths_missing
       conflicted_files=()
       while IFS= read -r -d '' CONFLICT_PATH; do
         conflicted_files+=("$CONFLICT_PATH")
       done <"$CONFLICT_PATHS_FILE"
       [ "${#conflicted_files[@]}" -gt 0 ] || review_ci_conflict_abort rebase_conflict_paths_missing
       CI_HEAD_BEFORE_CONTINUE="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 74
       while IFS= read -r CONFLICT_ROW; do
         [ -n "$CONFLICT_ROW" ] || continue
         CONFLICT_BINDING="$(printf '%s' "$CONFLICT_ROW" | jq -er .binding)" || review_ci_conflict_abort rebase_conflict_ledger_malformed
         CONFLICT_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-ci-terminal \
           --launch-binding-json "$CONFLICT_BINDING" --edge-id review_pr.ci.resolve_conflict)" \
           || review_ci_conflict_abort rebase_conflict_refused
         CONFLICT_STATUS_SHA256="$(review_ci_json_member "$CONFLICT_TERMINAL" status_sha256)" || return 74
         CONFLICT_RESULT_SHA256="$(review_ci_json_member "$CONFLICT_TERMINAL" result_sha256)" || return 74
         python3 -I -B "$CODE_FIXER_CONTRACT" validate-ci-mutation-outcome \
           --launch-binding-json "$CONFLICT_BINDING" \
           --status-sha256 "$CONFLICT_STATUS_SHA256" --result-sha256 "$CONFLICT_RESULT_SHA256" \
           --working-dir "$WORKTREE_ROOT" \
           --head-before "$CI_HEAD_BEFORE_CONTINUE" --head-after "$CI_HEAD_BEFORE_CONTINUE" \
           >/dev/null || review_ci_conflict_abort rebase_conflict_ambiguous
       done <"$CONFLICT_LAUNCHED"
       git -C "$WORKTREE_ROOT" add -- "${conflicted_files[@]}" || review_ci_conflict_abort rebase_continue_failed
       if ! git -C "$WORKTREE_ROOT" -c core.editor=true rebase --continue; then
         # Two sub-cases. (a) Multi-stage rebase: continuation surfaced a NEW
         # conflict set -> re-enter step 1 against the NEW list (conflict-resolver
         # REFUSES paths outside its pre-computed set, so the OLD list must not be
         # reused). Bounded by CI_FIX_LOOP_CAP; NOT a separate retry path.
         # (b) Non-conflict failure (pre-commit hook, signing) -> halt.
         #
         # THE SAME PRODUCER STEP 1 USES, for the same reason: this counter
         # decides between RESTAGE and abort, so a pair it cannot see is a
         # re-conflict that reads as zero — control would fall to
         # `review_ci_conflict_abort rebase_continue_failed`, which runs
         # `git rebase --abort` and throws away the stage-1 resolution the
         # resolvers just produced, under a subreason naming the wrong cause. A
         # multi-stage rebase whose SECOND stage conflicts add/add is enough to
         # hit it, and a hand-rolled pair list here is the #398 defect wearing a
         # different variable name. `review_fleet_unmerged_paths` answers through
         # `_ci_is_unmerged_pair`, inherits the rename/copy-origin skipping (a
         # rename emits two NUL fields for one entry) and stays three-valued, so
         # "git could not answer" halts as `rebase_enumerate_failed` instead of
         # masquerading as "nothing left to resolve".
         CI_RESTAGE_PATHS="$REVIEW_FLEET_RUN_DIR/ci-restage-probe-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER:-1}.zlist"
         CI_RESTAGE_ENUM_RC=0
         review_fleet_unmerged_paths "$WORKTREE_ROOT" "$CODE_FIXER_CONTRACT" \
           "$CI_RESTAGE_PATHS" || CI_RESTAGE_ENUM_RC=$?
         case "$CI_RESTAGE_ENUM_RC" in
           0|1) ;;
           *) review_ci_conflict_abort rebase_enumerate_failed ;;
         esac
         CI_RECONFLICT=0
         if [ "$CI_RESTAGE_ENUM_RC" -eq 0 ]; then
           while IFS= read -r -d '' CONFLICT_ROW; do
             CI_RECONFLICT=$((CI_RECONFLICT + 1))
           done <"$CI_RESTAGE_PATHS"
         fi
         if [ "$CI_RECONFLICT" -gt 0 ]; then
           # The restage IS a loop iteration, and saying so is what makes it
           # bounded. Without this the counter never moved, so the re-entered
           # step 2 recomputed the SAME authority pathname and
           # prepare-ci-authority refused `authority_preexists` on wave 2 — with
           # `return 74`, no audit event, and the rebase left in progress.
           CI_FIX_LOOP_ITER=$((${CI_FIX_LOOP_ITER:-1} + 1))
           if [ "$CI_FIX_LOOP_ITER" -gt 3 ]; then   # CI_FIX_LOOP_CAP
             audit ci_loop_cap_reached iterations="$CI_FIX_LOOP_ITER"
             review_ci_conflict_abort rebase_conflict_restage_cap
           fi
           review_fleet_write_ci_state "$CI_LOOP_STATE" "$CI_FIX_LOOP_ITER" \
             "$REVIEW_ITERATION" "$CI_FIX_PUSHES_JSON" "$CI_CLASSES_JSON" || return 74
           audit ci_conflict_restage count="$CI_RECONFLICT" iteration="$CI_FIX_LOOP_ITER"
           return 0
         fi
         review_ci_conflict_abort rebase_continue_failed
       fi
       ```

    4. **The single leased push — run 6c.4w.3.** There is no fence here: a
       second copy of the push would be a second lease, and the arm exists to
       prove there is only one. Re-run the **6c.4w.3 THE SINGLE LEASED PUSH**
       fence above verbatim. It re-reads the loop counters, the `ci-fix` launch
       sidecar and the digest-pinned rebase authority off disk, so it is
       indifferent to which terminal sent it here, and it refuses if a rebase is
       still in progress. It records `data.by_agent="ci-rebase-handler+conflict-resolver"`
       when this arm's `.launched` ledger exists.

       - Any resolver returning AMBIGUOUS or REFUSED, or leaving its own file
         with unresolved conflict markers, is caught by
         `validate-ci-mutation-outcome` in step 3 and aborts with
         `rebase_conflict_ambiguous` / `rebase_conflict_refused` before anything
         is staged.
       - A failed *enumeration* — `review_fleet_unmerged_paths` rc 2 (python3
         missing, git state unreadable), in step 1 or in step 3's restage probe —
         aborts with `data.subreason=rebase_enumerate_failed`, a deliberately
         different subreason from `rebase_conflict_set_empty` (step 1 found
         nothing unmerged) and from `rebase_continue_failed` (the continuation
         failed with nothing left to resolve). "Git could not answer" and "there
         is genuinely nothing unmerged" are opposite facts, and collapsing them
         is the #398 defect in miniature.

    5. **No additional retry path.** The arm is single-shot per `ci-fix` dispatch and bounded by `CI_FIX_LOOP_CAP` from 6c.7 LOOP GUARD. The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge-pipeline/SKILL.md` (in "PARK is the terminal floor" prose) applies here.

    **Phase 1 re-entry** (after a fix push lands — covers `ci-code-fixer`
    `APPLIED`, the rebase arm's `REBASED`, and `CONFLICT → all RESOLVED →
    push-success`).

    After a fixer pushes a remediation commit, the new HEAD MUST re-enter the
    **per-push trust-trail flow** — Phase 1 (post-impl-review fanout) and Phase 2
    (simplify fanout) re-run on the post-fix diff before Phase 3 re-probes. The
    trust-trail anchor commit is always the **absolute last** step, so the
    trailer's referenced SHA covers reviewed code only.

    Re-entry goes to **Step 4 (Phase 1 dispatch)**, never to Step 1, and
    `RUN_ID` is never re-minted. That is not an optimisation, it is the only
    correct path, for two independent reasons:

    - Re-running the executable setup **without** `RUN_ID` in the environment
      recomputes `REVIEW_RUN_ID_REQUEST` from `date -u` plus
      `git rev-parse --short HEAD` — and the fix push just changed HEAD — so it
      would mint a *different* ID, forking `.uberdev/research/<RUN_ID>/` and
      `.uberdev/runs/<RUN_ID>/` mid-run and orphaning the `locked` marker
      `/uberdev:goal` reads.
    - Re-running it **with** `RUN_ID` set (`RUN_ID_WAS_EXPLICIT=1`) hits the
      atomic reservation seeing its own directory and exiting 2 —
      *caller-supplied RUN_ID collision; refusing reuse*. There is no re-entrant
      reservation path.

    The `phases.phase1` and `phases.phase2` audit fields are **rewritten** each
    iteration; only `phases.phase3.iterations` and `phases.phase3.fix_pushes`
    accumulate — and they now accumulate in a file, because every `bash` block in
    this command is a fresh shell and a counter in a shell variable is gone
    before the cap is next checked.

    ```bash uberdev-executable origin=review-pr
    . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
    review_fleet_rehydrate || return 2
    . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh" || return 2
    CI_LOOP_STATE="$RESEARCH_DIR_ABS/ci-loop-state.json"
    if [ -r "$CI_LOOP_STATE" ]; then
      CI_FIX_LOOP_ITER="$(review_fleet_read_ci_state "$CI_LOOP_STATE" ci_loop_iter)" || return 74
      REVIEW_ITERATION="$(review_fleet_read_ci_state "$CI_LOOP_STATE" review_iteration)" || return 74
      CI_FIX_PUSHES_JSON="$(review_fleet_read_ci_state "$CI_LOOP_STATE" fix_pushes)" || return 74
      CI_CLASSES_JSON="$(review_fleet_read_ci_state "$CI_LOOP_STATE" failure_classes_seen)" || return 74
    else
      CI_FIX_LOOP_ITER="${CI_FIX_LOOP_ITER:-1}"
      REVIEW_ITERATION="${REVIEW_ITERATION:-1}"
      CI_FIX_PUSHES_JSON='[]'
      CI_CLASSES_JSON='[]'
    fi
    # The pushed sha and its author come from the push fence's own record, not
    # from $NEW_HEAD_SHA: 6c.4w.3 is a different shell, so that variable was
    # empty here and `phases.phase3.fix_pushes` accumulated rows naming no
    # commit at all — an audit trail that reads as a push and proves nothing.
    CI_LAST_PUSH="$RESEARCH_DIR_ABS/ci-last-push.json"
    NEW_HEAD_SHA="$(review_fleet_read_ci_push "$CI_LAST_PUSH" sha)" || return 74
    CI_FIX_BY_AGENT="$(review_fleet_read_ci_push "$CI_LAST_PUSH" by_agent)" || return 74
    CI_FIX_PUSHES_JSON="$(jq -c --arg sha "$NEW_HEAD_SHA" --arg by "$CI_FIX_BY_AGENT" \
      '. + [{sha:$sha,by_agent:$by}]' <<<"$CI_FIX_PUSHES_JSON")" || return 74
    # The class comes out of the DIGEST-PINNED ci-fix authority, of which it is
    # a required member, exactly as the ci-defer arm and CONFLICT step 2 read
    # their run identity. `${failure_class:-unknown}` soft-defaulted a scalar
    # bound three stages earlier, so `phases.phase3.failure_classes_seen` read
    # `["unknown"]` on every run and the post-mortem lost the one class the loop
    # actually burned its iterations on. `flaky` and the two human-action
    # classes never reach this fence (they have no push), so the ci-fix
    # authority always exists by the time it is read here.
    CI_FIX_SIDECAR="$(review_fleet_read_ci_pointer "$RESEARCH_DIR_ABS/ci-fix-launch-pointer.txt")" || return 74
    CI_FIX_BINDING="$(review_fleet_read_sidecar "$CI_FIX_SIDECAR" binding)" || return 74
    CI_FIX_AUTHORITY_PATH="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_path)" || return 74
    CI_FIX_AUTHORITY_SHA256="$(printf '%s' "$CI_FIX_BINDING" | jq -er .ci_authority_sha256)" || return 74
    # `read-ci-authority-member`, never `jq`: jq would read the document without
    # re-checking the digest, and the digest re-check is the entire point.
    # `failure_class` is a member of the fix_code authority only; the rebase
    # authority's class is `stale_base` by construction.
    if CI_RECORDED_CLASS="$(python3 -I -B "$CODE_FIXER_CONTRACT" read-ci-authority-member \
        --authority-path "$CI_FIX_AUTHORITY_PATH" --authority-sha256 "$CI_FIX_AUTHORITY_SHA256" \
        --member failure_class 2>/dev/null)" && [ -n "$CI_RECORDED_CLASS" ]; then
      :
    else
      CI_RECORDED_CLASS=stale_base
    fi
    CI_CLASSES_JSON="$(jq -c --arg class "$CI_RECORDED_CLASS" \
      'if index($class) then . else . + [$class] end' <<<"$CI_CLASSES_JSON")" || return 74
    CI_FIX_LOOP_ITER=$((CI_FIX_LOOP_ITER + 1))
    # REVIEW_ITERATION advances IN LOCKSTEP, and this is the ONLY site that
    # increments either counter. Phase 1 and Phase 2 re-run on the post-fix diff,
    # so their child directories must be new: childDirAbs() keys on
    # reviewIteration ALONE, and without this the second pass rebinds iteration
    # 1's result.md paths and capture-bound-child freezes STALE bytes while every
    # equality still passes. That is not a crash, it is a clean green built on
    # iteration 1's evidence.
    REVIEW_ITERATION=$((REVIEW_ITERATION + 1))
    if [ "$CI_FIX_LOOP_ITER" -gt 3 ]; then   # CI_FIX_LOOP_CAP, merge-pipeline/SKILL.md Constants
      audit ci_loop_cap_reached iterations="$CI_FIX_LOOP_ITER"
      OUTCOME=loop_cap_exhausted
      exit 1                                 # no anchor commit
    fi
    review_fleet_write_ci_state "$CI_LOOP_STATE" "$CI_FIX_LOOP_ITER" "$REVIEW_ITERATION" \
      "$CI_FIX_PUSHES_JSON" "$CI_CLASSES_JSON" || return 74
    # MANDATORY after every head-changing fixer/rebase/conflict-resolution push:
    # the next 6c.1 probe must derive a new run ID from the NEW head's checks.
    review_clear_ci_run_selection
    ```

    Audit `ci_fix_pushed` (with `data.commit_sha` full 40-hex) when a fixer push
    lands. On Phase 1 re-entry returning APPROVE → loop to 6c.1 (counts toward
    `CI_FIX_LOOP_CAP`). On Phase 1 re-entry rejecting → exit 1 with
    `OUTCOME=halted` (carry `data.subreason=post_fix_review_rejected`).

    ### 6c.6 HALT — turbo-aware (billing_quota / platform_outage)

    Two failure classes (`billing_quota`, `platform_outage`) require human action no agent can take. The remediation prose surfaces a third human-readable cause — secret rotation — to the operator as guidance text only; classifier-side, secret/auth-token failures map to `billing_quota` (quota / token-store) or `platform_outage` (identity-provider transient) within the 6-class enum. Behaviour branches on `--turbo`:

    **Interactive (`--turbo` absent):**

    ```
    ToolSearch({ query: "select:AskUserQuestion" })  // mandatory deferred-tool load
    AskUserQuestion({
      question: "CI failure class <X> cannot be resolved by code change. Required action: <remediation — may include 'rotate stale secret/auth token' as human-readable guidance>. After fixing, re-run /review-pr. Proceed?",
      options: [
        {label: "Stop", description: "Exit /review-pr with code 1; no trust signal."},
        {label: "Skip Phase 3", description: "Continue to Step 7 with OUTCOME=halted; no trust signal emitted."}
      ]
    })
    ```

    If `ToolSearch` fails, `/review-pr` aborts with stderr error — **NEVER silently auto-pick** (mirrors `orchestrator/SKILL.md:190-193`). Either user choice ultimately ends in `OUTCOME=halted`, exit 1.

    **Turbo (`--turbo` present):**

    ```
    log "warning: Phase 3 halt class <X> in --turbo mode; cannot prompt; emitting halt audit + exit 1" >&2
    audit ci_phase_outcome data.outcome=halted data.class=<X>
    OUTCOME=halted; exit 1
    ```

    ### 6c.7 LOOP GUARD

    Counter `CI_FIX_LOOP_ITER` starts at `1` at Phase 3 entry — the executable setup binds `CI_FIX_LOOP_ITER="${CI_FIX_LOOP_ITER:-1}"`, and every child instance ID reads that same 1-based value (`…-iter${CI_FIX_LOOP_ITER:-1}-attempt01`), so the first iteration IS iteration 1. Each fix-and-push increments. Cap = `CI_FIX_LOOP_CAP` (declared in `merge-pipeline/SKILL.md` Constants — value `3`), i.e. at most 3 iterations per run.

    - Iteration < 3, terminal outcome → emit `ci_phase_outcome` audit (with `data.outcome ∈ CI_OUTCOME_ENUM`), return to Step 7.
    - Iteration == 3, still red → audit `ci_loop_cap_reached`; `OUTCOME=loop_cap_exhausted`; exit 1; no anchor commit.
    - **MUST NOT introduce any additional retry path** (anti-pattern guard restated from `merge-pipeline/SKILL.md` "PARK is the terminal floor" prose).

    Each iteration increments only on a **distinct commit SHA change** (HEAD SHA changed since this iteration's start). Re-runs of the same SHA on `flaky` paths use `RERUN_FLAKY_CAP=1` per distinct check — they do NOT increment `CI_FIX_LOOP_ITER`.

    ### Phase 3 audit JSON shape

    Today's audit JSON (`.uberdev/runs/<run-id>/review-pr-verdict.json`) gains a `phases.phase3` block:

    ```json
    "phase3": {
      "status": "ran" | "skipped_no_checks" | "unreachable",
      "outcome": "green" | "green_after_fix" | "skipped_no_checks" | "halted" | "loop_cap_exhausted",
      "iterations": <int>,
      "failure_classes_seen": ["code_bug", "..."],
      "fix_pushes": [{"sha": "<40-hex>", "by_agent": "ci-code-fixer" | "ci-rebase-handler"}]
    }
    ```

    Note: `--no-ci-fix` mode (Step 1, `CI_FIX_PHASE=0`) keeps PROBE/MONITOR/CLASSIFY running for audit telemetry, so `phase3.status` resolves via the same PROBE-driven assignment (`ran` if probe ran end-to-end, `skipped_no_checks` if probe reported no checks, `unreachable` if `gh` failed). There is no `skipped_no_ci_fix` member because no path produces it — `--no-ci-fix` only skips ROUTE/POST-FIX/HALT and forces OUTCOME to `green`/`halted`, but the status field still records what PROBE saw.

    The `phases.phase3` block is **omitted entirely** when `gh` is unreachable (carve-out); a `ci_probe_unreachable` audit line is emitted to the JSONL audit log instead, and Step 7 trust-signal emission proceeds as if Phase 3 returned `skipped_no_checks`. Security trade-off: outage in `gh` MUST NOT block release; the trail still records the unreachability for `/merge`'s consumer to read out-of-band.

7. **Final Aggregation — distinguish review-phase vs simplify-phase findings**

   After Phase 1 fixes land and (if enabled) Phase 2 simplify edits land, summarize both phases in a single table that **distinguishes review-phase findings from simplify-phase findings**:

   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

8. **Provide Action Plan**

   Organize findings, with the review-phase vs simplify-phase distinction preserved in every row:

   ```markdown
   # PR Review Summary

   ## Phase outcomes
   | Phase | Status | Verdict | Auto-applied | Advisory findings |
   |---|---|---|---|---|
   | Phase 1 — Review + Fix | ran | APPROVE / REVISIONS_REQUIRED / REJECT | <commit shas> | <count> |
   | Phase 2 — Simplify     | ran / blocked / skipped | APPROVE / REVISIONS_REQUIRED / REJECT (omit if status≠ran) | <commit sha or ∅> | <count> |
   | Issues filed (Phase 2.5) | Rendered from the agent's return YAML, broken down by tier per RFC 0002 §3.4: `BLOCKER: <n>` / `CRITICAL: <n>` / `MAJOR: <n>` (each line omitted when count is 0). Sum line: `<total> created + <total> commented` followed by the trust-trail state implication — `(halt: trust trail RED)` when `halted=true`, `(critical-deferred: trust trail YELLOW)` when only `by_severity.critical > 0`, `(silent file: trust trail GREEN)` otherwise. `overflow_count` additional findings exceeded `MAX_NEW=10` cap; suffix `(BROKEN-FEATURE HALT)` when `halted_due_to_overflow=true`. `len(blocked_by_dedupe)` blocked by dedupe-lookup failure or fail-CLOSED branch. Full URL list with `(tier)` annotation in the "Issues filed (links)" block below. Skip path: `(skipped: --no-defer-issues)` when `DEFER_ISSUES_PHASE=0`, OR `(skipped: defer_issues_enabled=false)` when the config disables, OR both joined by " and " when both knobs are off. |

   **Issues filed (links):**

   Rendered from `created_urls[]` + `commented_urls[]` of the findings-to-issues agent return. Each line: `- [` + `file:line` + `](`URL`)` — e.g., `- [src/auth.ts:42](https://github.com/owner/repo/issues/123)`.

   `Verdict` reuses the canonical `uberdev:post-impl-review` reviewer enum (APPROVE | REVISIONS_REQUIRED | REJECT). `Status` is orthogonal: `ran` (the fanout completed), `blocked` (fanout failure — see "Non-blocking" above), `skipped` (`--no-simplify` was set).

   ## Critical Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Important Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Suggestions (X found)
   - [phase: review | simplify] [agent-name]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR

   ## Recommended Action
   1. Fix critical issues first
   2. Address important issues
   3. Consider suggestions
   4. Re-run review after fixes
   ```

## Trust-Signal Emission (RFC 0002 — tiered GREEN / YELLOW / RED)

After the final aggregation table renders, evaluate the trust-trail predicate. RFC 0002 promotes the prior binary GREEN/non-GREEN model to a three-state model:

```
GREEN  := (Phase 1 verdict == "APPROVE")
        AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
        AND (Phase 2.5 by_severity.blocker == 0)                    [RFC 0002 §3.4]
        AND (Phase 2.5 by_severity.critical == 0)                   [RFC 0002 §3.4 — disambiguates against YELLOW]
        AND (Phase 2.5 halted == false)                             [RFC 0002 §3.4]
        AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})

YELLOW := (Phase 1 verdict == "APPROVE")
        AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
        AND (Phase 2.5 by_severity.blocker == 0)                    [no blocker; non-zero critical is the YELLOW signal]
        AND (Phase 2.5 halted == false)
        AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})
        AND (Phase 2.5 by_severity.critical > 0)                    [RFC 0002 §3.4 — required for YELLOW]

RED    := NOT GREEN AND NOT YELLOW

OVERRIDE_GREEN := PHASE2_5_HALT_CHOICE == "override"                [RFC 0002 §3.5 — interactive opt-in only]
                AND would_have_been_RED_due_to_phase2_5_only

# Concrete definition of `would_have_been_RED_due_to_phase2_5_only`:
#   (Phase 1 verdict == "APPROVE")
#   AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
#   AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})
#   AND (Phase 2.5 halted == true OR Phase 2.5 by_severity.blocker > 0)
#
# Rationale: the override flag is allowed to suppress RED ONLY when phase2_5 is
# the SOLE cause — never when Phase 1/2/3 also fail. This is the
# "/merge will require --i-know-what-im-doing" trail.
```

The GREEN and YELLOW predicates are now syntactically mutually exclusive (GREEN explicitly requires `critical == 0`; YELLOW explicitly requires `critical > 0`). A run cannot satisfy both. The `case "$TRUST_TRAIL_STATE"` block in the State Assignment step above (artifact 1) deterministically picks one based on the cardinality of `BY_SEVERITY_CRITICAL`.

The Phase 2.5 conjuncts (`by_severity.blocker == 0` AND `halted == false`) are **predicate-level breaking** (CHANGELOG `### Changed` callout in v0.26.0). A previously-green `/review-pr` run that filed blocker issues via `findings-to-issues` (PR #112) now correctly gates the trust-trail anchor RED. The Phase 3 conjunct preserves the v0.21.0 break (red CI gates GREEN). The audit JSON gains `phases.phase2_5` (additive; legacy audit JSON without this block is treated as STALE by `trust-trail-evaluator` per RFC 0002 §3.6.4).

**Three-way branch on the predicate**:

- **GREEN (or OVERRIDE_GREEN)** → emit the GREEN artifact triplet (anchor commit with trailer + `uberdev-approved` label + audit JSON `verdict: "APPROVE"`). When OVERRIDE_GREEN was the cause, the audit JSON records `phases.phase2_5.override_reason="user-selected-emit-green-on-blocker-deferred"` so `/merge`'s trust-trail-evaluator can see the override and require `--i-know-what-im-doing` to proceed.

- **YELLOW** → emit the YELLOW artifact triplet (anchor commit with `severity=critical-deferred count=N` suffix on the trailer + `uberdev-approved-with-concerns` label + audit JSON `verdict: "APPROVE"` with `phases.phase2_5.by_severity.critical > 0`). `/merge` requires `--accept-critical-deferred` to proceed past a YELLOW trail.

- **RED** → emit no anchor commit, no label add, no `Reviewed-by:` trailer. Remove `uberdev-approved` and `uberdev-approved-with-concerns` labels from the PR if previously set (idempotent — `gh pr edit --remove-label` no-ops on absent labels). Write the audit JSON with `verdict` set to the failing verdict (Phase 1's verdict OR `"BLOCKED"` when Phase 2.5 is the cause); the JSON is still written so `/merge`'s trust-trail-evaluator has a fresh `phases.phase2_5` block to read. Exit 1.

The remainder of this section describes the GREEN/YELLOW emission shape (RED skips the entire artifact triplet — see exit-code contract):

1. **Trust-trail-anchor commit** — emit ONE empty commit at HEAD whose body carries the trailer pointing at its parent. The parent SHA — captured **before** the anchor commit — is the load-bearing trust artifact for `/merge` Phase 1.4 trust resolution (see `skills/merge-pipeline/SKILL.md` Constants `REVIEW_PR_TRAILER_PREFIX`):

   **State assignment (RFC 0002 §3.4 — must run BEFORE the three case statements below).** Compute `TRUST_TRAIL_STATE` from the predicate; the three downstream case statements in artifacts 1 and 2 read this single source-of-truth variable:

   ```bash
   . "${UBERDEV_REVIEW_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}}/lib/review-fleet-args.sh" || return 2
   review_fleet_rehydrate || return 2
   # Final anti-race gate: the reviewed snapshot must still be both local HEAD
   # and the selected PR's live head before any anchor, label, or audit trust
   # artifact is emitted.
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" \
     "$REVIEWED_HEAD_SHA" "$WORKTREE_ROOT" || {
       echo "error: PR head changed after review; suppressing trust emission" >&2
       OUTCOME=halted
       exit 2
     }

   # Evaluate the GREEN predicate first; YELLOW is a strict sub-case
   # ("all GREEN preconditions met AND critical>0"); RED is everything else.
   # OVERRIDE_GREEN flips RED→GREEN when PHASE2_5_HALT_CHOICE == "override"
   # AND phase2_5 was the SOLE cause of the otherwise-GREEN-preconditions failing.
   would_be_green_without_phase2_5=false
   if [ "$PHASE1_VERDICT" = "APPROVE" ] \
      && { [ "$PHASE2_STATUS" = "ran/APPROVE" ] || [ "$PHASE2_STATUS" = "skipped" ]; } \
      && { [ "$PHASE3_OUTCOME" = "green" ] || [ "$PHASE3_OUTCOME" = "green_after_fix" ] || [ "$PHASE3_OUTCOME" = "skipped_no_checks" ]; }; then
     would_be_green_without_phase2_5=true
   fi

   if   $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALTED:-false}" = "false" ] \
        && [ "${BY_SEVERITY_BLOCKER:-0}" = "0" ] \
        && [ "${BY_SEVERITY_CRITICAL:-0}" = "0" ]; then
     TRUST_TRAIL_STATE=GREEN
   elif $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALTED:-false}" = "false" ] \
        && [ "${BY_SEVERITY_BLOCKER:-0}" = "0" ] \
        && [ "${BY_SEVERITY_CRITICAL:-0}" -gt 0 ]; then
     TRUST_TRAIL_STATE=YELLOW
   elif $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALT_CHOICE:-}" = "override" ]; then
     # OVERRIDE_GREEN: operator selected emit-GREEN-on-blocker-deferred AND
     # phase2_5 was the sole cause of RED (all other phases satisfy GREEN).
     # `/merge` requires --i-know-what-im-doing to land this trail.
     TRUST_TRAIL_STATE=GREEN
     OVERRIDE_REASON="user-selected-emit-green-on-blocker-deferred"
   else
     TRUST_TRAIL_STATE=RED
   fi
   ```

   Audit-trail invariant: `OVERRIDE_REASON` is set ONLY by the OVERRIDE_GREEN branch above; all other branches leave it as `null` (the audit JSON `phases.phase2_5.override_reason` field defaults to `null`). This makes the override discoverable downstream by `/merge`'s `trust-trail-evaluator` per RFC 0002 §3.6.

   **Trailer suffix selection (RFC 0002 §3.4):**

   ```bash
   case "$TRUST_TRAIL_STATE" in
     GREEN)
       TRAILER_SUFFIX=""
       ;;
     YELLOW)
       TRAILER_SUFFIX=" severity=critical-deferred count=${BY_SEVERITY_CRITICAL}"
       ;;
     # RED skips this entire emission section — handled by the predicate branch above
   esac
   ```

   ```bash
   review_validate_trust_anchor() {
     [ "$#" -eq 4 ] || return 2
     local reviewed_head_sha="${@:1:1}" parent_sha="${@:2:1}" anchor_sha="${@:3:1}" expected_message_sha256="${@:4:1}"
     local observed_head observed_parents observed_message_sha256 residue_receipt
     [[ "$reviewed_head_sha" =~ ^[0-9a-f]{40}$ && "$parent_sha" =~ ^[0-9a-f]{40}$ && "$anchor_sha" =~ ^[0-9a-f]{40}$ && "$expected_message_sha256" =~ ^[0-9a-f]{64}$ ]] || return 2
     [ "$parent_sha" = "$reviewed_head_sha" ] || return 79
     observed_head="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 79
     [ "$observed_head" = "$anchor_sha" ] || return 79
     observed_parents="$(git -C "$WORKTREE_ROOT" rev-list --parents -n 1 "$anchor_sha")" || return 79
     [ "$observed_parents" = "$anchor_sha $parent_sha" ] || return 79
     git -C "$WORKTREE_ROOT" diff --quiet "$parent_sha" "$anchor_sha" -- || return 79
     observed_message_sha256="$(python3 -I -B "$CODE_FIXER_CONTRACT" commit-message-digest --working-dir "$WORKTREE_ROOT" --commit-sha "$anchor_sha")" || return 79
     [ "$observed_message_sha256" = "$expected_message_sha256" ] || return 79
     residue_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-residue --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS")" || return 79
     [ "$residue_receipt" = '{"status":"clean"}' ] || return 79
   }

   TRUST_RESIDUE_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-residue --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS")" || {
     echo "error: MUTATED_BLOCKED — residual repository state suppresses trust emission" >&2
     FIXER_TERMINAL_STATE=MUTATED_BLOCKED
     OUTCOME=halted
     exit 2
   }
   [ "$TRUST_RESIDUE_RECEIPT" = '{"status":"clean"}' ] || {
     echo "error: MUTATED_BLOCKED — malformed residue receipt suppresses trust emission" >&2
     FIXER_TERMINAL_STATE=MUTATED_BLOCKED
     OUTCOME=halted
     exit 2
   }
   PARENT_SHA="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || exit 2
   if ! [ "$PARENT_SHA" = "$REVIEWED_HEAD_SHA" ]; then
     echo "error: MUTATED_BLOCKED — trust-trail parent is not the reviewed head" >&2
     FIXER_TERMINAL_STATE=MUTATED_BLOCKED
     OUTCOME=halted
     exit 2
   fi
   # The base half of the trust trail (#440). `Reviewed-by:` names WHAT was
   # reviewed and at WHICH head; without a base the trailer describes a delta
   # with only one endpoint, so `gh pr edit <N> --base <other-branch>` swaps the
   # reviewed delta for an arbitrary one while every trust artifact stays
   # byte-identical. Read off the Phase 1 carrier — this fence is ~4000 lines and
   # 52 fences downstream of the bind, so `$BASE_SHA` here is the empty string.
   . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/review-fleet-args.sh" || exit 2
   REVIEW_BASE_RUN_DIR="$(cd "$RESEARCH_DIR_ABS" && pwd -P)" || exit 2
   REVIEW_BASE_IDENTITY="$(review_fleet_read_review_base "$REVIEW_BASE_RUN_DIR/review-base-identity.tsv")" || {
     echo "error: MUTATED_BLOCKED — the reviewed-base identity is unreadable at $REVIEW_BASE_RUN_DIR/review-base-identity.tsv; refusing to emit a base-blind trust anchor." >&2
     audit review_base_unreadable data.phase=trust_anchor
     FIXER_TERMINAL_STATE=MUTATED_BLOCKED
     OUTCOME=halted
     exit 2
   }
   REVIEWED_BASE_SHA="${REVIEW_BASE_IDENTITY%%$(printf '\t')*}"
   REVIEWED_BASE_REF="${REVIEW_BASE_IDENTITY#*$(printf '\t')}"
   ANCHOR_MESSAGE="$(printf 'chore(review-pr): trust trail anchor for #%s\n\nReviewed-by: uberdev/review-pr@%s%s\nReviewed-base: uberdev/review-pr@%s ref=%s' "$PR_NUMBER" "$PARENT_SHA" "$TRAILER_SUFFIX" "$REVIEWED_BASE_SHA" "$REVIEWED_BASE_REF")" || exit 2
   ANCHOR_MESSAGE_SHA256="$(python3 -I -B -c 'import hashlib,sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest(),end="")' "$ANCHOR_MESSAGE")" || exit 2
   [[ "$ANCHOR_MESSAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 2
   if ! git -C "$WORKTREE_ROOT" commit --allow-empty --cleanup=verbatim -m "$ANCHOR_MESSAGE"; then
     echo "error: trust-trail anchor commit failed; suppressing trust emission" >&2
     OUTCOME=halted
     exit 2
   fi
   LOCAL_ANCHOR_SHA="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || exit 2
   if ! review_validate_trust_anchor "$REVIEWED_HEAD_SHA" "$PARENT_SHA" "$LOCAL_ANCHOR_SHA" "$ANCHOR_MESSAGE_SHA256"; then
     echo "error: MUTATED_BLOCKED — trust-trail anchor head/parent/tree/message/residue validation failed" >&2
     FIXER_TERMINAL_STATE=MUTATED_BLOCKED
     OUTCOME=halted
     exit 2
   fi
   if ! review_publish_same_repo_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$REVIEWED_HEAD_SHA" "$LOCAL_ANCHOR_SHA" "$WORKTREE_ROOT" "$CODE_FIXER_CONTRACT" "$RESEARCH_DIR_ABS"; then
     # Push failed (network, auth, rate limit, hook rejection, non-fast-forward, …).
     # The immutable anchor SHA is pushed to the explicit, validated PR branch;
     # symbolic HEAD is never publication authority. The gate then requires the
     # remote ref, live PR head, and local HEAD to equal that exact SHA. Without
     # this guard, the audit JSON could name a SHA absent from the remote, and
     # `/merge` Phase 1.4 would later fail with a cryptic `trust_trail_agent_invalid_input`
     # (subreason `trailer_sha_not_in_local_clone`). Per artifact-emission-failure prose
     # below, exit 2 — treat as `blocked`-equivalent so the trust-signal contract is
     # never silently broken. Re-run /review-pr after resolving the push failure.
     echo "error: immutable trust-trail anchor publication or equality proof failed. Re-run /review-pr after resolving." >&2
     exit 2
   fi
   ANCHOR_SHA="$LOCAL_ANCHOR_SHA"   # full 40-char validated anchor identity, proven equal to the post-emission remote ref + live/local PR head. This is the anchor commit's own SHA, NOT the trailer's PARENT_SHA payload, and is used in artifact 3's audit JSON `"sha"` field.
   ```

   Why an empty anchor commit (and not a per-simplify-commit trailer or `git commit --amend`):
   - **Empty diff proven after hooks** (`--allow-empty` plus `review_validate_trust_anchor`). `--allow-empty` alone does not force emptiness when a hook or concurrent writer stages bytes, so the controller verifies the exact parent and an empty tree diff before push. `trust-trail-evaluator` PASSes via the empty-cumulative-diff path: `git merge-base --is-ancestor <PARENT_SHA> HEAD` → YES, `git diff <PARENT_SHA> HEAD` → empty → `PASS`. Independent of how many Phase 1 / Phase 2 commits landed.
   - **Always a fresh new commit on top.** `git commit --amend` is **NEVER** used, so push **never** requires `--force-with-lease`. Works identically whether Phase 1 / Phase 2 already pushed mid-run or batched their pushes.
   - **Self-pinning trailer.** The trailer references the anchor's parent — the actual end-of-run HEAD before the anchor — so the SHA is captured *deterministically* at the only moment it can be written without chicken-and-egg. No reliance on amend-recompute or sibling-equivalence heuristics on the agent side.
   - **Both endpoints of the reviewed delta, not one (#440).** `Reviewed-by:` alone names a head; a review is a statement about a *delta*, and a delta needs a base. Without `Reviewed-base:` a GREEN survives `gh pr edit <N> --base <other-branch>` untouched: no push occurs, so `headRefOid` cannot move; the trailer is bytes inside an immutable commit object; the `uberdev-approved` label is a bare literal with no payload. All three structural primitives return their PASS values while a delta nobody reviewed rides in. The base identity therefore travels in the **commit body**, next to the head identity — not only in the audit JSON, which is gitignored local telemetry and corroborator-only per D1.

   The anchor commit goes through pre-commit hooks normally — never `--no-verify`. Author = current `git config user.email` / `user.name`; the trailers are procedural attribution to the `/review-pr` command. Per global CLAUDE.md, the anchor commit MUST NOT include a `Co-Authored-By: Claude` trailer or any `🤖 Generated with Claude Code` footer. The two trailer payloads — `Reviewed-by: uberdev/review-pr@<40-hex>` and `Reviewed-base: uberdev/review-pr@<40-hex> ref=<base-ref-name>` — are the only trailers in the body. `review_validate_trust_anchor` authenticates the SHA-256 of the complete post-hook subject/body bytes against `ANCHOR_MESSAGE_SHA256`, so **both** payloads are covered by the same digest: exact equality of the `Reviewed-by` payload to `PARENT_SHA` and of the `Reviewed-base` payload to the carried Phase 1 base identity, before proceeding to artifact 2.

2. **Label** — tier-aware. GREEN runs add `uberdev-approved` (canonical literal — see `skills/merge-pipeline/SKILL.md` Constants `UBERDEV_APPROVED_LABEL`). YELLOW runs add `uberdev-approved-with-concerns` (RFC 0002 §3.4). Each label is **provisioned fail-loud via `gh label create --force` immediately before the add** (issue #170 — `gh pr edit --add-label` CANNOT auto-create a repo label and exits non-zero when the label is missing, which on a fresh repo aborts the whole trust-signal emission; same assume-label-exists class as #168). `--force` is idempotent: it updates an existing label's colour/description and never errors on "already exists", so a non-zero `gh label create` exit is always a genuine failure (auth / repo write-or-triage scope / API). Adding the label to the PR is itself idempotent — `gh` no-ops if the label is already on the PR.

   ```bash
   case "$TRUST_TRAIL_STATE" in
     GREEN)  TRUST_LABEL="uberdev-approved"
             TRUST_LABEL_COLOR="0E8A16"
             TRUST_LABEL_DESC="Trust trail: /uberdev:review-pr verified GREEN. Auto-managed — set by /review-pr, read by /merge." ;;
     YELLOW) TRUST_LABEL="uberdev-approved-with-concerns"
             TRUST_LABEL_COLOR="FBCA04"
             TRUST_LABEL_DESC="Trust trail: /review-pr YELLOW: deferred CRITICAL; /merge needs --accept-critical-deferred." ;;
   esac
   # Belt-and-braces: clear the OPPOSITE-tier label if present, so a re-run that
   # downgrades GREEN→YELLOW (or upgrades YELLOW→GREEN) doesn't leave a stale
   # contradictory label on the PR. Failures here are fail-soft (the new label
   # add below is the authoritative artifact).
   case "$TRUST_TRAIL_STATE" in
     GREEN)  gh pr edit <N> --remove-label uberdev-approved-with-concerns 2>/dev/null || true ;;
     YELLOW) gh pr edit <N> --remove-label uberdev-approved 2>/dev/null || true ;;
   esac
   ```

   ```bash
   # Provision the trust label BEFORE adding it (#170). `gh pr edit --add-label`
   # CANNOT auto-create a repo label and exits non-zero when it is missing — on a
   # fresh repo (or any repo where the trust labels were never created) this
   # aborts the whole trust-signal emission. `--force` makes this idempotent (it
   # updates an existing label's colour/description, never errors on "already
   # exists"), so a non-zero exit here is a genuine failure (auth / missing repo
   # write-or-triage scope / API error). Fail-loud + exit 2 mirrors the --add-label
   # guard below: the label is the load-bearing trust artifact /merge reads, so
   # emission cannot proceed without it. (Same assume-label-exists class as #168,
   # but fail-loud rather than swallowed.)
   if ! gh label create --force "$TRUST_LABEL" --color "$TRUST_LABEL_COLOR" --description "$TRUST_LABEL_DESC"; then
     echo "error: failed to provision the '$TRUST_LABEL' trust label (gh pr edit --add-label cannot auto-create it). Check gh auth and repo write/triage permission." >&2
     exit 2
   fi
   # Mirror artifact 1's push-failure guard: if `gh pr edit` exits non-zero
   # (network, auth, rate limit, label-permission denial), bash continues silently
   # and the audit JSON below gets written without the label being applied.
   # `/merge` Phase 1.4 PATH_2 sub-condition (a) then fails downstream with a cryptic
   # `trust_trail_label_missing`. Per artifact-emission-failure prose below, exit 2.
   if ! gh pr edit <N> --add-label "$TRUST_LABEL"; then
     echo "error: trust-trail label add failed (gh pr edit ... exited non-zero). Re-run /review-pr after resolving." >&2
     exit 2
   fi
   ```

   ```bash
   # Note: kept as a SEPARATE gh pr edit call (not combined with the
   # --add-label uberdev-approved call above) so that the differential
   # error contract is preserved: --add-label is exit-2-on-failure
   # (trust-signal artifact), while --remove-label is fail-soft per D4.
   # New (#95): clear the review-pr:pending backstop label on green outcome.
   # Fail-soft per spec D4 — /uberdev:review-pr may be invoked directly outside
   # a finish-branch chain, so the label may legitimately be absent; an exit-2
   # guard would falsely fail green direct-invocation runs.
   if ! gh pr edit <N> --remove-label review-pr:pending 2>/dev/null; then
     echo "note: review-pr:pending label not present (either never set or already cleared)" >&2
   fi
   ```

   **Pending-label clearance** — the `gh pr edit <N> --remove-label review-pr:pending` call pairs with the `--add-label uberdev-approved` above; together they form the green-outcome trust-signal handoff. See `REVIEW_PR_PENDING_LABEL` in `skills/merge-pipeline/SKILL.md` Constants. The label is set by `finish-branch/SKILL.md` immediately before this Skill is dispatched (issue #95). It is intentionally preserved on REVISIONS_REQUIRED, agent crash, or non-green exit so `/merge` Step 1.4.5's label-present probe can backstop the missed review on the next integration run.

3. **Audit JSON** — write to `.uberdev/runs/<run-id>/review-pr-verdict.json`. The `"sha"` field MUST be `${ANCHOR_SHA}` from artifact 1 (the post-emission `headRefOid`, equal to the anchor commit's own SHA). It is NOT `${PARENT_SHA}` — the trailer payload references the pre-anchor parent, but the JSON `"sha"` references the anchor itself, matching what `gh pr view --json headRefOid` returns immediately after the push:

```json
{
  "pr": <int>,
  "sha": "${ANCHOR_SHA}",
  "base": {"sha": "${REVIEWED_BASE_SHA}", "ref": "${REVIEWED_BASE_REF}"},
  "verdict": "APPROVE" | "REVISIONS_REQUIRED" | "REJECT" | "BLOCKED",
  "trust_trail_state": "GREEN" | "YELLOW" | "RED",
  "phases": {
    "phase1": {"status": "ran", "verdict": "APPROVE"},
    "phase2": {"status": "ran/APPROVE" | "skipped", "verdict": "APPROVE" | null},
    "phase2_5": {
      "status": "ran" | "skipped" | "blocked",
      "issues_filed": <int>,
      "by_severity": {
        "blocker":  <int>,
        "critical": <int>,
        "major":    <int>
      },
      "overflow_count": <int>,
      "halted_due_to_overflow": <bool>,
      "halted": <bool>,
      "filed_issue_urls": ["https://github.com/<owner>/<repo>/issues/<N>", ...],
      "override_reason": null | "user-selected-emit-green-on-blocker-deferred",
      "verification": {
        "threshold": <int 0-100>,
        "verified": <int>,
        "culled": <int>
      }
    },
    "phase3": {
      "status": "ran" | "skipped_no_checks" | "unreachable",
      "outcome": "green" | "green_after_fix" | "skipped_no_checks" | "halted" | "loop_cap_exhausted",
      "iterations": <int>,
      "failure_classes_seen": [],
      "fix_pushes": [],
      "ci_refused_issue_url": null | "https://github.com/.../issues/<N>"
    }
  },
  "timestamp": "<ISO8601>"
}
```

Assemble that exact object in `AUDIT_JSON_PAYLOAD`, then publish it through the
fresh-shell receipt fence:

```bash
# BEGIN review-verdict-final-fence-v1
REVIEW_FINAL_FENCE_RC=0
python3 -I -B - \
  "$REVIEW_RUN_RESERVATION_RECEIPT" \
  "$AUDIT_JSON_PAYLOAD" \
  "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/run_manifest.py" <<'PY' || REVIEW_FINAL_FENCE_RC=$?
import base64
import importlib.util
import json
import os
import re
import stat
import sys

receipt_text, payload_text, module_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("uberdev_review_final_manifest", module_path)
if spec is None or spec.loader is None:
    print(f"error: review run manifest is not loadable: {module_path}", file=sys.stderr)
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
except Exception as error:
    print(f"error: review run manifest failed to import: {error}", file=sys.stderr)
    raise SystemExit(2)

def decode_receipt(value):
    if not value.startswith("v1:") or re.fullmatch(r"v1:[A-Za-z0-9_-]+", value) is None:
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    token = value[3:]
    raw = base64.b64decode(
        token + "=" * (-len(token) % 4), altchars=b"-_", validate=True
    )
    receipt = json.loads(raw)
    if not isinstance(receipt, dict) or set(receipt) != {
        "markers", "run_dir", "run_dir_identity", "run_id", "runs_root",
        "runs_root_identity", "schema",
    }:
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    if (
        receipt["schema"] != "review-run-reservation-v1"
        or json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode() != raw
        or re.fullmatch(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+", receipt["run_id"] or "") is None
    ):
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    for key in ("runs_root_identity", "run_dir_identity"):
        identity = receipt[key]
        if (
            not isinstance(identity, list)
            or len(identity) != 2
            or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in identity)
        ):
            raise module.ManifestRejected("review_reservation_receipt_invalid")
    runs_root = os.path.abspath(receipt["runs_root"])
    run_dir = os.path.abspath(receipt["run_dir"])
    if (
        runs_root != receipt["runs_root"]
        or run_dir != receipt["run_dir"]
        or run_dir != os.path.join(runs_root, receipt["run_id"])
        or os.path.basename(runs_root) != "runs"
        or os.path.basename(os.path.dirname(runs_root)) != ".uberdev"
        or set(receipt["markers"]) != {"locked", "pr-context.json"}
    ):
        raise module.ManifestRejected("review_reservation_receipt_invalid")
    for marker in receipt["markers"].values():
        if (
            not isinstance(marker, dict)
            or set(marker) != {"identity", "sha256", "size"}
            or not isinstance(marker["identity"], list)
            or len(marker["identity"]) != 6
            or any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in marker["identity"])
            or re.fullmatch(r"[0-9a-f]{64}", marker["sha256"] or "") is None
            or isinstance(marker["size"], bool)
            or not isinstance(marker["size"], int)
            or marker["size"] < 0
            or marker["identity"][2] != marker["size"]
        ):
            raise module.ManifestRejected("review_reservation_receipt_invalid")
    return receipt

def require_directory(entry, identity):
    uid_fn = getattr(os, "geteuid", None)
    uid = uid_fn() if uid_fn is not None else None
    if (
        not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or getattr(entry, "st_reparse_tag", 0)
        or (entry.st_dev, entry.st_ino) != tuple(identity)
        or (uid is not None and entry.st_uid != uid)
    ):
        raise module.ManifestRejected("review_reservation_directory_changed")

def validate_marker(run_dir, name, marker):
    _payload, identity = module.secure_capture_published(
        os.path.join(run_dir, name),
        marker["sha256"],
        marker["size"],
        marker["size"],
    )
    if list(identity) != marker["identity"]:
        raise module.ManifestRejected("review_reservation_marker_changed")

try:
    receipt = decode_receipt(receipt_text)
    payload = json.loads(payload_text)
    if not isinstance(payload, dict):
        raise module.ManifestRejected("review_verdict_payload_invalid")
    encoded = (
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode()
    runs_root = receipt["runs_root"]
    run_dir = receipt["run_dir"]
    module._reject_symlinked_ancestors(run_dir)
    module._reject_windows_reparse_ancestors(run_dir)
    require_directory(os.lstat(runs_root), receipt["runs_root_identity"])
    require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
    for name, marker in receipt["markers"].items():
        validate_marker(run_dir, name, marker)

    module.secure_publish_exact_no_clobber(
        os.path.join(run_dir, "review-pr-verdict.json"),
        encoded,
        receipt["run_dir_identity"],
    )
except (OSError, TypeError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    print(f"error: could not publish review verdict: {error}", file=sys.stderr)
    raise SystemExit(2)

# Publication is durable and exact-name/no-clobber from here on. Retiring the
# two reservation markers is CLEANUP, and it gets its OWN failure class: sharing
# the publication handler above made a cleanup fault print "could not publish
# review verdict" and exit 2, so callers concluded the verdict was never written
# and re-ran the review — against a run directory whose verdict artifact already
# exists, which the exact-name publisher then refuses, wedging the PR. Revalidate
# both marker identities before retiring only those receipt-bound names.
try:
    for name, marker in receipt["markers"].items():
        validate_marker(run_dir, name, marker)
    if module._uses_native_windows_filesystem():
        for name, marker in receipt["markers"].items():
            current = os.lstat(os.path.join(run_dir, name))
            if list(module._artifact_identity(current)) != marker["identity"]:
                raise module.ManifestRejected("review_reservation_marker_changed")
            os.unlink(os.path.join(run_dir, name))
        require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
    else:
        run_descriptor = module._open_directory_fd(run_dir)
        try:
            require_directory(os.fstat(run_descriptor), receipt["run_dir_identity"])
            for name, marker in receipt["markers"].items():
                current = os.stat(name, dir_fd=run_descriptor, follow_symlinks=False)
                if list(module._artifact_identity(current)) != marker["identity"]:
                    raise module.ManifestRejected("review_reservation_marker_changed")
                os.unlink(name, dir_fd=run_descriptor)
            os.fsync(run_descriptor)
            require_directory(os.lstat(run_dir), receipt["run_dir_identity"])
        finally:
            os.close(run_descriptor)
except (OSError, TypeError, ValueError, module.ManifestRejected, module.ManifestRuntimeError) as error:
    print(
        f"error: verdict_published_marker_retire_failed: {error}",
        file=sys.stderr,
    )
    raise SystemExit(3)
PY
case "$REVIEW_FINAL_FENCE_RC" in
  0) ;;
  3)
    echo "error: the review verdict WAS published, but its reservation markers could not be retired (verdict_published_marker_retire_failed)" >&2
    echo "note: do NOT re-run /uberdev:review-pr for this run — the verdict artifact already exists and the exact-name publisher will refuse to replace it. /uberdev:goal treats the stale markers as in-flight until its grace window expires or the next run's reservation reaper clears them." >&2
    exit 3
    ;;
  *)
    echo "error: review verdict publication failed; refusing to replace or reuse an existing artifact" >&2
    exit 2
    ;;
esac
unset AUDIT_JSON_PAYLOAD
# END review-verdict-final-fence-v1
```

The fence rehydrates and validates the setup receipt in a fresh shell, captures
both marker bytes against their recorded digests and identities, canonicalizes
the JSON, and calls the shared `secure_publish_exact_no_clobber` primitive for
the fixed `review-pr-verdict.json` basename. The publisher never truncates,
replaces, or unlinks that pathname, including after a partial-write or sync
failure. Only after successful publication does the fence revalidate and remove
`locked` and `pr-context.json`; the reserved run directory and verdict remain.
A collision, directory retarget, short write, identity change, or sync failure
**during publication** exits 2 (nothing was written — re-running is safe). A
failure **during the post-publication marker retire** exits 3
(`verdict_published_marker_retire_failed`) — the verdict is already on disk, so
re-running would hit the no-clobber refusal; the stale markers are reclaimed by
`/uberdev:goal`'s grace window or by the next run's
`review_reap_stale_run_reservations` pass.

The `verification` sub-block (RFC 0017 / #431) is ADDITIVE: no existing
`phase2_5` field changes shape, because `trust-trail-evaluator.md` pins the
current domains and `lib/goal-state.sh` parses them. It reports what Step 6b.0
suppressed — `threshold` is the cutoff the run used, `verified` is the number of
eligible Phase 1 blocker findings that got a verification row, and `culled` is
how many of those were recorded `CULLED` and therefore never filed. Culling a
blocker can flip a run RED -> GREEN; that is intended (a false-positive blocker
that keeps a run RED hard-fails `/merge` forever), and this block is the price:
every suppression is countable here, named in
`.uberdev/research/<RUN_ID>/phase1-verification.json`, and carried as a
`review_finding_verified` row in the repo-root audit stream.

**`phases.phase2_5` block (RFC 0002 §3.4)** — present on every run where the Phase 2.5 sub-phase was reachable (i.e., Phase 1 + Phase 2 didn't crash before Step 6b). `status: "skipped"` when `DEFER_ISSUES_EFFECTIVE=0` (CLI flag or config disabled the sub-phase); `status: "blocked"` when the agent return YAML failed to parse; `status: "ran"` otherwise. The `halted`, `by_severity`, and `override_reason` fields are the load-bearing inputs for `/merge`'s `trust-trail-evaluator` per RFC 0002 §3.6. Legacy audit JSON (pre-v0.26.0) without this block → trust-trail-evaluator emits STALE, prompting `/review-pr` re-run.

**`base` member (#440)** — top-level sibling of `sha`, and the audit-JSON mirror of the anchor commit's `Reviewed-base:` trailer. `base.sha` is the 40-hex merge-base the whole review was scoped to (`review_resolve_phase1_base`'s output, carried on `review-base-identity.tsv`); `base.ref` is the name of the branch that merge-base was taken against (`baseRefName` at Phase 1 entry). Base identity is a property of the *run*, not of any one phase, which is why it sits at the JSON root next to `sha` rather than inside `phases`. Legacy audit JSON without a `base` member cannot say what the review was scoped to, so `/merge`'s artifact parser maps it to the existing `legacy` audit state and trust-trail-evaluator emits STALE, prompting a `/review-pr` re-run — the identical additive-block migration the `phases.phase2_5` block used in v0.26.0, deliberately reusing that state token rather than inventing a second convention. A `base` member that is PRESENT but shape-invalid (non-object, non-40-hex `sha`, empty or control-character-bearing `ref`) is `malformed`, not `legacy`: "the field predates this schema" and "the field is corrupt" are different answers and only the first is recoverable by a re-run.

**`trust_trail_state` field (RFC 0002 §3.4)** — top-level GREEN/YELLOW/RED discriminator, redundant with the `phases.*` blocks but exposed at the JSON root for faster downstream gating (`/merge` can branch on a single string instead of recomputing the predicate from each phase block).

**`phases.phase3.ci_refused_issue_url` (RFC 0002 §3.2)** — populated when Phase 3 halted on `ci-code-fixer` `status: REFUSED` and the failing test was filed as a CRITICAL-tier issue. `null` on all other Phase 3 outcomes.

The JSON is **local debug telemetry only** — `.uberdev/` is gitignored, so the JSON does NOT cross-clone. `/merge` consumes the trailer as the load-bearing trust artifact and treats the JSON as a corroborating presence check. See `skills/merge-pipeline/SKILL.md` Phase 1.4 Path 2 for the consumer side.

On any artifact-emission failure (anchor commit fails — pre-commit hook rejection, push rejection, network failure; label add fails; JSON write fails): exit 2 (treat as `blocked`-equivalent because the trust-signal contract is broken). Print the failing `git` / `gh` / filesystem stderr; suggest re-running `/review-pr`.

### Run-ID format

For a standalone invocation, `<run-id>` is derived once in executable setup
from a UTC-second timestamp, the selected worktree's short HEAD, and an
8-character cryptographic hex discriminator. The final discriminator is chosen
by the atomic directory reservation, with at most
`RUN_ID_RESERVATION_MAX_ATTEMPTS` attempts. An explicitly supplied ID is never
reminted or reused: an existing directory is a collision and exits 2.

Before any path concatenation, validate `<run-id>` against the regex:

```
^[0-9]{8}-[0-9]{6}-[a-f0-9]+$
```

See `skills/merge-pipeline/SKILL.md` Constants `RUN_ID_REGEX`. If the regex match fails (defensive — should never trigger with internally-generated values), exit 2 and print: `BUG: run-id <value> does not match ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ — file an issue`. The regex constraint forecloses path-traversal if a future iteration ever sources `<run-id>` from external input.

## Exit-Code Contract

| Exit code | Condition |
|-----------|-----------|
| `0` | GREEN OR YELLOW OR OVERRIDE_GREEN — Phase 1 verdict == `APPROVE` AND Phase 2 status ∈ {`ran/APPROVE`, `skipped`} AND Phase 3 outcome ∈ {`green`, `green_after_fix`, `skipped_no_checks`} AND (Phase 2.5 halted == false OR Phase 2.5 halt was overridden) |
| `1` | Phase 1 verdict ∈ {`REJECT`, `REVISIONS_REQUIRED`} (regardless of Phase 2) OR **Phase 3 outcome ∈ {`halted`, `loop_cap_exhausted`}** OR **Phase 2.5 halted == true AND PHASE2_5_HALT_CHOICE ∈ {solve_suggestion, skip}** (RFC 0002 §3.4 — `override` takes the OVERRIDE_GREEN path and exits 0) |
| `2` | Phase 2 status == `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure) OR Phase 2.5 status == `blocked` (agent return YAML parse failure) OR Step 6a post-fixer push failure (blocked-equivalent — Phase 3 would probe a stale remote SHA) |
| `3` | `verdict_published_marker_retire_failed` — the verdict artifact WAS published durably, but the two reservation markers could not be retired afterwards. Distinct from `2` on purpose: `2` means "no verdict exists, re-run me", `3` means "the verdict exists, do NOT re-run me" (the exact-name publisher would refuse). Callers treat the run's verdict as authoritative and let `/uberdev:goal`'s grace window or the next run's reservation reaper clear the markers. |

Exit code `2` is a **behavioral break** from the previous always-exit-0 contract. Callers that scripted `/review-pr` against the old "always exits successfully" prose must either ignore the exit code (preserve old behavior) or branch on it (use new behavior). The new contract surfaces silent reviewer-crash failures that the trust signal exists to eliminate. Documented in CHANGELOG.

The exit code is rooted in Phase 2 *status*, not Phase 2 *verdict* — a `ran/APPROVE` exit-0 may still contain advisory `REVISIONS_REQUIRED` simplify findings surfaced in the aggregation table (step 7).

Phase 3 reuses exit `1` (no new exit code introduced — Q2 decision). The audit JSON `phases.phase3.outcome` field disambiguates Phase 3 halt from Phase 1 reject.

## Usage Examples:

**Full review (default):**
```
/uberdev:review-pr
```

**Specific aspects:**
```
/uberdev:review-pr tests errors
# Reviews only test coverage and error handling

/uberdev:review-pr comments
# Reviews only code comments

/uberdev:review-pr simplify
# Simplifies code after passing review
```

**Sequential override** (default is parallel):
```
/uberdev:review-pr all sequential
# Force one-at-a-time dispatch — use only for interactive walkthroughs
```

**Skip Phase 2 simplify pass** (legacy single-pass behavior):
```
/uberdev:review-pr --no-simplify
# Run only Phase 1 review-and-fix; skip the mandatory simplify fanout.
# Use when only correctness review is wanted (e.g. pre-merge gate after a
# /simplify pass already ran). Combinable with aspect args:
/uberdev:review-pr tests errors --no-simplify
```

**Skip Phase 3 CI fix loop** (probe-only mode):
```
/uberdev:review-pr --no-ci-fix
# Run Phase 1 + Phase 2 + Phase 3 PROBE/MONITOR/CLASSIFY (audit-only).
# Use for fast iterative review loops where you don't want fix attempts.
# Combinable with aspect args:
/uberdev:review-pr tests errors --no-ci-fix
```

**Skip Phase 2.5 findings-to-issues sub-phase** (suppress deferred-critical issue filing):
- `/uberdev:review-pr --no-defer-issues` — runs the full review chain (Phase 1 + Phase 2 + Phase 3) but skips the Phase 2.5 findings-to-issues sub-phase. Final summary table shows `(skipped: --no-defer-issues)`.
- `/uberdev:review-pr tests errors --no-defer-issues` — same as above with additional review aspects.

## Agent Descriptions:

### Phase 1 reviewers (7 — fanned out by `Skill(uberdev:post-impl-review)`)

**uberdev:comment-analyzer**:
- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**uberdev:pr-test-analyzer**:
- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**uberdev:silent-failure-hunter**:
- Finds silent failures
- Reviews catch blocks
- Checks error logging

**uberdev:type-design-analyzer**:
- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**uberdev:code-reviewer**:
- Detects bugs and issues
- Reviews correctness and design
- Written project conventions are NOT this lens (#433) — they belong to `convention-compliance`, which must quote the rule

**uberdev:convention-compliance**:
- Reviews the change against the project's own written rules (`AGENTS.md`, `CLAUDE.md`, lint configs) from a controller-supplied allowlist
- Quotes the exact rule text in every finding, under a declared `detail` grammar
- A finding whose quote is not verbatim in the cited file is culled by a deterministic gate before aggregation, and the cull is logged

**uberdev:code-reviewer (general lens)**:
- 7th fanout slot — re-dispatched against the same agent file with a "general code-quality" framing in the brief (see `skills/post-impl-review/SKILL.md` Step 2 dispatch table)

### Phase 2 lens dispatcher (3 lens-parameterised routed child calls calls)

**uberdev:code-simplifier** (named lens — `subagent_type: uberdev:code-simplifier`):
- Simplifies complex code (Reuse / Quality / Efficiency lens via `## Lens emphasis:`)
- Improves clarity and readability
- Applies project standards
- Preserves functionality (audit-only persona — does not modify files)

### Apply-loop fixer (Phase 1 + Phase 2)

**uberdev:code-fixer** (`subagent_type: uberdev:code-fixer`):
- Reads the post-impl-review aggregate or simplify aggregate — each file carries its own envelope as leading/trailing file bytes (`<external-untrusted-input source="post-impl-review-aggregate">` for Phase 1, `source="simplify-aggregate"` for Phase 2); the dispatch passes the path or the enveloped bytes verbatim, never re-wrapped
- Applies minimal-scope edits and creates at most one routed conventional commit
- Phase 1 commit type: `fix:` (derived only from `review_pr.fix.phase1` + `review_fix`)
- Phase 2 commit type: `refactor:` (R8.6 invariant — no override; one commit per run)
- Returns commit SHAs and per-finding disposition table; advisory findings surface in the final aggregation table

### Phase 3 agents (CI Health — dispatched per-class from Step 6c.4 ROUTE)

**uberdev:ci-failure-classifier** (`subagent_type: uberdev:ci-failure-classifier`):
- Classifies one failed GitHub Actions check log into one of six classes (`CI_FAILURE_CLASS_ENUM`)
- Reads log under `<external-untrusted-input>` envelope; never quotes lines verbatim
- Returns YAML with `failure_class` + `signal_anchor` (file:line pointer)

**uberdev:ci-code-fixer** (`subagent_type: uberdev:ci-code-fixer`):
- Applies root-cause fix for `code_bug` or `env_drift` classes
- Refuses on forbidden patterns (`--no-verify`, test-skip, error-swallow, secret-mask, new-file-creation, multi-lockfile-churn)
- Commits as `fix(ci):` (code_bug) or `chore(deps):` (env_drift); never pushes (caller handles)

**uberdev:ci-rebase-handler** (`subagent_type: uberdev:ci-rebase-handler`):
- Rebases the PR branch onto its base for `stale_base` class, and **stops there** — #383 demoted it from pusher to preparer
- Does **not** push. `git push` in any form is on its explicit denylist. The `--force-with-lease=<branch>:<sha> --force-if-includes` pair (the sanctioned exception to `merge-pipeline/SKILL.md`'s never-`--force-with-lease`-against-PR-head invariant) is captured and consumed by the CONTROLLER, which is the whole safety property: the lease's value must not be one an agent chose
- No lock file. The lease is the cross-run concurrency guard, and `git rebase` refuses on its own when `.git/rebase-merge` already exists — a controller-held `flock` cannot work here, because every `bash` block is a fresh shell and the file descriptor dies with the fence
- Returns `CONFLICT` with a `conflict_count`, leaving the rebase IN PROGRESS, for the controller to enumerate the unmerged paths itself (all seven porcelain pairs — 6c.4w CONFLICT-RESOLVE step 1) and fan out `conflict-resolver` agents in a SINGLE assistant turn

## Notes:

`/uberdev:review-pr` is a **post-push** command. The executable setup resolves
`PR_NUMBER` from the live PR (`gh pr view --json number`), Phase 1 reviews the
`<merge-base>..<reviewed-head-sha>` range of that PR, Phase 2.5 files deferred
findings against it, Phase 3 probes its CI checks, and Step 7 anchors the trust
trailer on a commit pushed to its branch. There is no pre-PR mode: the two tail
sections that used to tell the reader to "run early, before creating PR" and
walked through `Before committing` / `Before creating PR` flows predated the PR
contract and contradicted every one of those steps (#302). Use
`/uberdev:solve`, `/uberdev:turbo`, or `/uberdev:simplify` for pre-push work;
`finish-branch` chains into this command once the PR exists.

- Aspect tokens (`code`, `errors`, `tests`, …) narrow *emphasis*, never the
  fanout — all 7 Phase 1 reviewers always run
- Agents run autonomously and return detailed reports
- Each agent focuses on its specialty for deep analysis
- Results are actionable with specific file:line references
- Agents use appropriate models for their complexity
- All agents available in `/agents` list
