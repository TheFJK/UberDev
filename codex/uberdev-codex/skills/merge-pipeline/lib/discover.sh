# shellcheck shell=bash
# Generated under R1+R2 root fix (see CHANGELOG v0.19.3)
#
# Why this exists: gh's spinner / progress bytes leak into stdout when /merge
# pipes `gh ... --json` into an external `jq`, which crashes the pipeline with
# "Invalid string: control characters from U+0000 through U+001F must be
# escaped". R1 collapses every gh|jq pipeline into `gh ... --jq '<filter>'`
# (in-process; no FD pollution). R2 lifts the three discovery sites out of
# SKILL.md prose into this real lib so the model cannot improvise a `2>&1`
# back in. Each function emits a `discovery_gh_failed` audit event on failure.

if [ "${_UBERDEV_MERGE_DISCOVER_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_MERGE_DISCOVER_LOADED=1

# _uberdev_discover_audit_path
# Resolve the audit-log path. Tests redirect via UBERDEV_AUDIT_LOG_PATH;
# production defaults to .uberdev/audit.jsonl (best-effort, pre-lock context).
_uberdev_discover_audit_path() {
  printf '%s' "${UBERDEV_AUDIT_LOG_PATH:-.uberdev/audit.jsonl}"
}

# _uberdev_discover_iso_ts
# Emit a UTC ISO8601 timestamp. POSIX-portable on macOS bash 3.2 (BSD date).
_uberdev_discover_iso_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _uberdev_discover_json_escape_stream
# Read stdin and emit JSON-escaped output (backslash, quote, \n \r \t
# escaped; other C0/C1 + DEL dropped via tr). Shared body of
# _uberdev_discover_truncate and _uberdev_discover_json_escape_str — keeps
# the escape rules in one place so a future fix (e.g. \b / \f handling)
# cannot drift between the two paths. Bash 3.2 + POSIX tools only
# (no GNU-sed multiline-label extensions — BSD sed on macOS rejects
# `:a;N;$!ba`, which would silently produce unescaped raw newlines and
# corrupt the JSONL audit log).
_uberdev_discover_json_escape_stream() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C awk '
        BEGIN { ORS = ""; out = "" }
        {
          line = $0
          gsub(/\\/, "\\\\", line)
          gsub(/"/, "\\\"", line)
          gsub(/\r/, "\\r", line)
          gsub(/\t/, "\\t", line)
          out = out (NR > 1 ? "\\n" : "") line
        }
        END { print out }
      '
}

# _uberdev_discover_truncate FILE
# Echo the first 512 bytes of FILE, JSON-escaped via the shared escape
# stream. Empty string when FILE is unreadable (best-effort).
_uberdev_discover_truncate() {
  local file="$1"
  if [ ! -r "$file" ]; then
    printf ''
    return 0
  fi
  head -c 512 "$file" 2>/dev/null | _uberdev_discover_json_escape_stream
}

# _uberdev_discover_json_escape_str STRING
# Emit STRING JSON-escaped via the shared escape stream. Defense-in-depth
# for enum-shaped fields (reason, step) interpolated into audit-log JSON
# via bare-string printf. Today every call site passes a static enum
# literal, so this is unreachable given current callers — but the function
# signatures do not enforce that discipline, and a future caller passing a
# dynamic string would otherwise corrupt the audit log.
_uberdev_discover_json_escape_str() {
  printf '%s' "$1" | _uberdev_discover_json_escape_stream
}

# _uberdev_discover_emit_audit REASON STEP EXIT_CODE STDERR_FILE [PR_NUMBER]
# Best-effort append of one discovery_gh_failed event to the audit log.
# Pre-lock context — no run_id required (mirrors Step 1.0a's
# uberdev_config_read precedent of writing to .uberdev/audit.jsonl directly).
# Never fails the caller if the log write fails (`|| true`).
_uberdev_discover_emit_audit() {
  local reason="$1"
  local step="$2"
  local exit_code="$3"
  local stderr_file="$4"
  local pr_number="${5:-}"
  local audit_path
  audit_path="$(_uberdev_discover_audit_path)"
  local audit_dir
  audit_dir="$(dirname "$audit_path")"
  local stderr_truncated
  stderr_truncated="$(_uberdev_discover_truncate "$stderr_file")"
  local ts
  ts="$(_uberdev_discover_iso_ts)"
  # Sanitise numerics so a non-integer exit_code / pr_number cannot inject
  # malformed-or-attacker-shaped JSON into the audit log (defense in depth —
  # both fields come from gh-validated sources today, but the contract is
  # bare-numeric in the JSON shape per the AUDIT_EVENT_ENUM doc).
  case "$exit_code" in ''|*[!0-9-]*) exit_code=-1 ;; esac
  case "$pr_number" in ''|*[!0-9]*) pr_number="" ;; esac
  # JSON-escape string fields. Today's callers pass static enum literals
  # (reason ∈ {gh_failed, jq_failed}; step ∈ {1.0.5, 1.2.5, 1.4}), so these
  # escapes are no-ops in practice — the helper is here so the function
  # contract no longer relies on caller discipline. stderr_truncated is
  # already escaped by _uberdev_discover_truncate above.
  local reason_escaped step_escaped
  reason_escaped="$(_uberdev_discover_json_escape_str "$reason")"
  step_escaped="$(_uberdev_discover_json_escape_str "$step")"
  # Ensure parent dir exists (best-effort).
  mkdir -p "$audit_dir" 2>/dev/null || true
  if [ -n "$pr_number" ]; then
    printf '{"ts":"%s","event":"discovery_gh_failed","data":{"reason":"%s","step":"%s","exit_code":%s,"gh_stderr":"%s","pr_number":%s}}\n' \
      "$ts" "$reason_escaped" "$step_escaped" "$exit_code" "$stderr_truncated" "$pr_number" \
      >> "$audit_path" 2>/dev/null || true
  else
    printf '{"ts":"%s","event":"discovery_gh_failed","data":{"reason":"%s","step":"%s","exit_code":%s,"gh_stderr":"%s"}}\n' \
      "$ts" "$reason_escaped" "$step_escaped" "$exit_code" "$stderr_truncated" \
      >> "$audit_path" 2>/dev/null || true
  fi
}

# _uberdev_discover_warn STEP_LABEL EXIT_CODE STDERR_FILE
# Emit one stderr breadcrumb (truncated to 512 bytes of stderr).
_uberdev_discover_warn() {
  local label="$1"
  local exit_code="$2"
  local stderr_file="$3"
  local truncated
  if [ -r "$stderr_file" ]; then
    truncated="$(head -c 512 "$stderr_file" 2>/dev/null \
                 | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  else
    truncated=""
  fi
  printf 'warning: %s (gh exit %s): %s\n' "$label" "$exit_code" "$truncated" >&2
}

# discover_bare_fast_path CURRENT_BRANCH
# Stdout: integer N (count of open non-draft PRs whose HEAD = current_branch).
# Exit:   0 on success (incl. N=0); 1 on gh-or-jq failure.
# Stderr: warning on failure (see _uberdev_discover_warn).
# Audit:  discovery_gh_failed with step="1.0.5" on failure.
# Implementation: in-process `gh ... --jq 'length'` (R1 root fix — no
# external jq pipe, eliminating FD-pollution surface).
discover_bare_fast_path() {
  local current_branch="$1"
  local gh_err
  gh_err="$(mktemp)"
  # Function-scoped trap; bash 3.2 supports RETURN trap idiom.
  # shellcheck disable=SC2064  # intentional immediate expansion of $gh_err
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr list \
    --head "$current_branch" \
    --state open \
    --search 'draft:false' \
    --json number,headRefOid \
    --jq 'length' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "bare-mode discovery failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.0.5" "$gh_exit" "$gh_err"
    return 1
  fi

  # Validate result is an integer (jq 'length' on a non-array → would have
  # exited non-zero above; defensive numeric check guards against future
  # gh-CLI changes that emit informational stdout text alongside JSON).
  case "$result" in
    ''|*[!0-9]*)
      _uberdev_discover_warn "bare-mode discovery returned non-integer" "$gh_exit" "$gh_err"
      _uberdev_discover_emit_audit "jq_failed" "1.0.5" "$gh_exit" "$gh_err"
      return 1
      ;;
  esac

  printf '%s\n' "$result"
  return 0
}

# discover_multi INTEGRATION_BRANCH
# Stdout: JSON array of candidate PRs (or '[]' on failure — Step 1.7's
#         clean-exit-0 contract still applies).
# Exit:   0 always (gh-or-jq failure → '[]' + audit event).
# Stderr: warning on failure.
# Audit:  discovery_gh_failed with step="1.2.5" on failure.
# Implementation: gh's in-process --jq filter does the isDraft==false
# belt-and-suspenders filter; no external jq pipe.
discover_multi() {
  local integration_branch="$1"
  local gh_err
  gh_err="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr list \
    --base "$integration_branch" \
    --state open \
    --search 'draft:false' \
    --json number,title,headRefOid,headRefName,baseRefName,isDraft,createdAt,reviewDecision,labels,body,author,headRepositoryOwner \
    --jq '[.[] | select(.isDraft==false)]' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "multi-discover failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.2.5" "$gh_exit" "$gh_err"
    printf '[]\n'
    return 0
  fi

  # Empty stdout on a 0-exit gh is unexpected (jq identity on empty would
  # have errored); treat as jq_failed and fall back to '[]'.
  if [ -z "$result" ]; then
    _uberdev_discover_warn "multi-discover returned empty stdout" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "jq_failed" "1.2.5" "$gh_exit" "$gh_err"
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "$result"
  return 0
}

# pr_view_projection PR_NUMBER
# Stdout: JSON object with the 15 fields Step 1.4 trust gate consumes.
# Exit:   0 on success; 1 on gh-or-jq failure.
# Stderr: warning on failure.
# Audit:  discovery_gh_failed with step="1.4" and pr_number=<N> on failure.
# Implementation: identity --jq '.' filter routes the projection through
# gh's in-process JSON parser before reaching stdout (R1 root fix —
# downstream callers can safely use `<<<"$PR_JSON"` herestrings because
# the bytes are clean by construction).
pr_view_projection() {
  local pr_number="$1"
  local gh_err
  gh_err="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr view "$pr_number" \
    --json state,isDraft,reviewDecision,statusCheckRollup,headRepository,maintainerCanModify,isCrossRepository,headRefName,headRefOid,baseRefName,body,commits,labels,createdAt,author \
    --jq '.' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "pr_view_projection #$pr_number failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.4" "$gh_exit" "$gh_err" "$pr_number"
    return 1
  fi

  if [ -z "$result" ]; then
    _uberdev_discover_warn "pr_view_projection #$pr_number returned empty stdout" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "jq_failed" "1.4" "$gh_exit" "$gh_err" "$pr_number"
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

# Resolve this sourced library's plugin root without assuming Bash. zsh exposes
# the current sourced pathname through its prompt-expansion `%x`; Bash exposes
# BASH_SOURCE. The eval keeps zsh-only syntax out of Bash's parser.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_UBERDEV_MERGE_DISCOVER_SOURCE=${(%):-%x}'
else
  _UBERDEV_MERGE_DISCOVER_SOURCE="${BASH_SOURCE[0]}"
fi
_UBERDEV_MERGE_DISCOVER_PLUGIN_ROOT="$(
  cd "$(dirname "$_UBERDEV_MERGE_DISCOVER_SOURCE")/../../.." 2>/dev/null &&
    pwd -P
)"

# review_verdict_discovery_state RC
# Convert the selector's exhaustive result code into the only three caller
# states. Any unrecognised/non-numeric infrastructure status is indeterminate.
review_verdict_discovery_state() {
  case "${1:-}" in
    0) printf 'found\n' ;;
    1) printf 'absent\n' ;;
    *) printf 'indeterminate\n' ;;
  esac
  return 0
}

# SINGLE binding of the private capture-directory basename prefix. Three parties
# need this one fact — the shell that mints the directory (`mktemp -d`), the
# shell that removes an interpreter-never-started leftover (a basename guard so
# `rm -rf` can only ever touch a directory this file minted), and the Python side
# that refuses to publish into or clean up anything outside such a directory.
# It used to be restated three ways with nothing proving they agreed; a drifted
# copy would silently disarm one of the two guards while both still "looked"
# correct. It is transported to Python through the environment (below) rather
# than re-typed there. `python3 -I` implies `-E`, which ignores only PYTHON*
# variables, so a non-PYTHON name crosses the boundary intact.
UBERDEV_VERDICT_CAPTURE_PREFIX="uberdev-review-verdict."

# _uberdev_review_verdict_python COMMAND [...]
# One closed Python boundary owns root binding, secure byte capture, duplicate-
# key-safe JSON parsing, timestamp ranking, snapshot publication, and carrier
# recapture. It imports the existing run_manifest primitives directly; no new
# runtime interface is introduced.
_uberdev_review_verdict_python() {
  local command="$1"
  shift
  UBERDEV_VERDICT_CAPTURE_PREFIX="$UBERDEV_VERDICT_CAPTURE_PREFIX" \
  python3 -I -B - "$command" "$_UBERDEV_MERGE_DISCOVER_PLUGIN_ROOT" "$@" <<'PY'
import fnmatch
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys

command, plugin_root, *args = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "uberdev_merge_review_verdict",
    os.path.join(plugin_root, "lib", "run_manifest.py"),
)
if spec is None or spec.loader is None:
    print("indeterminate: secure artifact runtime unavailable", file=sys.stderr)
    raise SystemExit(2)
runtime = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runtime
try:
    spec.loader.exec_module(runtime)
except Exception:
    # Loading the secure artifact runtime is NOT proof that no verdict exists.
    # Left unguarded this raises before the funnel below is installed, and an
    # unhandled exception exits 1 -- which the shell maps to exhaustive ABSENT,
    # i.e. "no verdict for this PR", which /merge treats as gate_pass. A missing
    # or version-skewed run_manifest.py must fail closed as INDETERMINATE.
    print("indeterminate: secure artifact runtime failed to load", file=sys.stderr)
    raise SystemExit(2)

RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-f0-9]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
MAXIMUM_SIZE = 1024 * 1024
OVERRIDE = "user-selected-emit-green-on-blocker-deferred"
# Transported from the shell (see UBERDEV_VERDICT_CAPTURE_PREFIX above), never
# re-typed: the shell mints the directory, this side guards publication and
# removal against it, and a drifted second copy would disarm one guard silently.
# An absent or empty value is INDETERMINATE — never a permissive default, which
# would make the `startswith` guards below match every path.
CAPTURE_DIR_PREFIX = os.environ.get("UBERDEV_VERDICT_CAPTURE_PREFIX", "")
if not CAPTURE_DIR_PREFIX:
    print(
        "indeterminate: private capture-directory prefix was not provided by the caller",
        file=sys.stderr,
    )
    raise SystemExit(2)
# Segments that stand for "any single directory name" in an expected_shape.
WILDCARD_SEGMENTS = frozenset({"run_id", "worktree"})
# One entry per searched root: (root_name, expected_shape). expected_shape names
# every path segment beneath the root; the depth pin and the fnmatch glob are
# DERIVED from it (see derive_root_layout_pins below). They used to be stored
# here as two extra tuple fields, which restated one segment count three ways
# with nothing proving the three agreed. A disagreement silently produced zero
# candidates, and zero candidates funnels through `raise SystemExit(1)` --
# exhaustive ABSENT, which /merge treats as gate_pass. Derivation makes the
# three views incapable of disagreeing.
ROOT_LAYOUTS = (
    (".uberdev/runs", ("run_id", "review-pr-verdict.json")),
    (
        ".claude/worktrees",
        ("worktree", ".uberdev", "runs", "run_id", "review-pr-verdict.json"),
    ),
    (
        ".worktrees",
        ("worktree", ".uberdev", "runs", "run_id", "review-pr-verdict.json"),
    ),
    (
        "worktrees",
        ("worktree", ".uberdev", "runs", "run_id", "review-pr-verdict.json"),
    ),
)


class VerdictError(Exception):
    pass


def fail(reason):
    print(f"indeterminate: {reason}", file=sys.stderr)
    raise SystemExit(2)


# The documented depth/glob contract, mirrored by the four globs enumerated in
# `discover_review_verdict_json`'s header, sub-condition (d) prose, and
# tests/merge.test.sh M63.worktree-glob.*. It is an ASSERTION TARGET, never an
# input: derive_root_layout_pins computes the pins from ROOT_LAYOUTS and refuses
# to run if the computed table and this one disagree.
EXPECTED_ROOT_LAYOUT_PINS = {
    ".uberdev/runs": (2, ".uberdev/runs/*/review-pr-verdict.json"),
    ".claude/worktrees": (
        5,
        ".claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json",
    ),
    ".worktrees": (5, ".worktrees/*/.uberdev/runs/*/review-pr-verdict.json"),
    "worktrees": (5, "worktrees/*/.uberdev/runs/*/review-pr-verdict.json"),
}


def derive_root_layout_pins():
    """Derive `{root_name: (exact_depth, exact_path)}` from ROOT_LAYOUTS.

    Every failure here routes through `fail()` -> SystemExit(2) -> INDETERMINATE.
    A bare module-scope `assert` would exit 1, and exit 1 is reserved for the two
    deliberate `raise SystemExit(1)` sites that mean "scan completed, no
    candidate" -- i.e. proven absence, i.e. /merge gate_pass. A layout-contract
    break must never be able to spell itself as proven absence.
    """

    derived = {}
    # The loop variables are deliberately NOT named root_name/expected_shape:
    # tests/merge.test.sh M63 requires EXACTLY ONE loop header binding those two
    # names over ROOT_LAYOUTS, which is how it proves all four roots still feed
    # one bounded walk inside scan_roots.
    for layout_root, layout_shape in ROOT_LAYOUTS:
        if layout_root in derived:
            fail(f"duplicate root layout: {layout_root}")
        if not layout_shape:
            fail(f"root layout has an empty shape: {layout_root}")
        if "run_id" not in layout_shape:
            fail(f"root layout has no run_id segment: {layout_root}")
        derived[layout_root] = (
            len(layout_shape),
            layout_root
            + "/"
            + "/".join(
                "*" if segment in WILDCARD_SEGMENTS else segment
                for segment in layout_shape
            ),
        )
    if derived != EXPECTED_ROOT_LAYOUT_PINS:
        fail("derived root layout pins disagree with the documented contract")
    return derived


ROOT_LAYOUT_PINS = derive_root_layout_pins()


def raw_identity(entry):
    return (
        entry.st_dev,
        entry.st_ino,
        entry.st_size,
        getattr(entry, "st_mtime_ns", int(entry.st_mtime * 1_000_000_000)),
        getattr(entry, "st_ctime_ns", int(entry.st_ctime * 1_000_000_000)),
        entry.st_mode,
    )


def followed_identity(path):
    entry = os.stat(path)
    return raw_identity(entry)


def lexical_identity(path):
    entry = os.lstat(path)
    return raw_identity(entry)


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise VerdictError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_payload(payload):
    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda token: (_ for _ in ()).throw(
                VerdictError(f"non-finite number: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, VerdictError) as exc:
        raise VerdictError("malformed JSON") from exc
    if not isinstance(value, dict):
        raise VerdictError("top-level JSON must be an object")
    pr = value.get("pr")
    if isinstance(pr, bool) or not isinstance(pr, int) or pr < 1:
        raise VerdictError("top-level pr must be a positive integer")
    return value, pr


def parse_phase2_5(value):
    phases = value.get("phases")
    if phases is None:
        return ("legacy", False, 0, 0, None, False)
    if not isinstance(phases, dict):
        raise VerdictError("phases must be an object or null")
    if "phase2_5" not in phases:
        return ("legacy", False, 0, 0, None, False)
    phase = phases["phase2_5"]
    if not isinstance(phase, dict):
        raise VerdictError("phase2_5 must be an object")

    halted = phase.get("halted")
    if halted is None:
        halted = False
    elif not isinstance(halted, bool):
        raise VerdictError("phase2_5.halted must be boolean or null")

    severity = phase.get("by_severity")
    if severity is None:
        severity = {}
    elif not isinstance(severity, dict):
        raise VerdictError("phase2_5.by_severity must be an object or null")

    counts = []
    for key in ("blocker", "critical"):
        count = severity.get(key)
        if count is None:
            count = 0
        elif isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise VerdictError(
                f"phase2_5.by_severity.{key} must be a non-negative integer or null"
            )
        counts.append(count)

    override = phase.get("override_reason")
    if override is not None and override != OVERRIDE:
        raise VerdictError("phase2_5.override_reason has an invalid value")

    # Carried so /goal can gate its Phase 3 truncation on the same authority
    # /review-pr recorded. Same strict discipline as `halted`: absent/null is
    # False, any non-boolean is a contract violation, never a silent default.
    overflow = phase.get("halted_due_to_overflow")
    if overflow is None:
        overflow = False
    elif not isinstance(overflow, bool):
        raise VerdictError(
            "phase2_5.halted_due_to_overflow must be boolean or null"
        )
    return ("current", halted, counts[0], counts[1], override, overflow)


def validate_target(value):
    artifact_sha = value.get("sha")
    if not isinstance(artifact_sha, str) or SHA_RE.fullmatch(artifact_sha) is None:
        raise VerdictError("top-level sha must be 40 lowercase hexadecimal characters")
    return artifact_sha, parse_phase2_5(value)


def receipt_identity(value):
    """Rebind the receipt's six-element identity array to a typed identity.

    The array arrives from receipt JSON, so every element is untrusted. The
    domain checks (integer, not bool, non-negative inode/size/mode) live in
    `ArtifactIdentity.__post_init__`; `artifact_identity_from_receipt` is the
    only sanctioned way to cross that boundary, so a malformed array can no
    longer be laundered into an identity that later compares equal to a real
    one.
    """

    identity = value.get("snapshot_identity")
    if not isinstance(identity, list):
        raise VerdictError("snapshot identity malformed")
    try:
        return runtime.artifact_identity_from_receipt(identity)
    except runtime.ManifestRejected as exc:
        raise VerdictError("snapshot identity malformed") from exc


def parse_receipt(raw):
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise VerdictError("snapshot receipt malformed") from exc
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise VerdictError("snapshot receipt schema mismatch")
    path = value.get("snapshot_path")
    digest = value.get("snapshot_sha256")
    if not isinstance(path, str) or not os.path.isabs(path):
        raise VerdictError("snapshot path malformed")
    if not isinstance(digest, str) or DIGEST_RE.fullmatch(digest) is None:
        raise VerdictError("snapshot digest malformed")
    return value, path, digest, receipt_identity(value)


def validate_suffix(root_name, candidate, expected_shape):
    relative = os.path.relpath(candidate, root_name)
    parts = tuple(relative.split(os.sep))
    if (
        relative == os.pardir
        or relative.startswith(os.pardir + os.sep)
        or any(part in ("", ".", os.pardir) for part in parts)
        or len(parts) != len(expected_shape)
    ):
        raise VerdictError("find result escaped or violated the root layout")
    for actual, expected in zip(parts, expected_shape):
        if expected not in {"run_id", "worktree"} and actual != expected:
            raise VerdictError("find result violated the root layout")
    run_id = parts[expected_shape.index("run_id")]
    return parts, run_id


def scan_root_layout(root_name, exact_depth, exact_path):
    """Enumerate ROOT at exactly `exact_depth`, keeping entries matching `exact_path`.

    Replaces `find -H ROOT -mindepth N -maxdepth N -path GLOB -print0`. The
    external binary is not usable here: this module runs under whatever
    interpreter the host provides, and on native Windows `subprocess` resolves
    a bare "find" against the system PATH, where C:\\Windows\\System32\\find.exe -- an
    unrelated text-search tool -- precedes Git Bash's POSIX find. That made every
    scan fail with "FIND: Parameter format not correct", so /goal and /merge
    discovery returned INDETERMINATE for every lookup on Windows.

    Semantics preserved exactly:
      * `-H`  -- the command-line root is the ONLY followed link; descent uses
                 follow_symlinks=False, matching find's default no-follow.
      * `-mindepth N -maxdepth N` -- only entries at exactly depth N are emitted,
                 and nothing below depth N is traversed.
      * `-path GLOB` -- fnmatchcase against the printed path, where `*` spans `/`
                 exactly as in find; the path is composed with `/` so the glob is
                 separator-independent on Windows.
      * any file type is emitted at the pinned depth (find does not filter by
                 type here); regularity is enforced later during secure capture.

    Results are sorted, which is stricter than find's directory order.

    Returns `(matches, errors)`. An OSError anywhere in the subtree is recorded
    as one `(reason, subject, errno)` triple and the walk CONTINUES: aborting on
    the first error meant a single unreadable stale worktree under `.worktrees`
    stopped the whole enumeration, so a perfectly good verdict under the
    canonical `.uberdev/runs` root was never even looked at. Accumulating keeps
    the diagnosis complete while staying fail-closed -- `scan_roots` raises once
    when the accumulator is non-empty, so a partial scan is still INDETERMINATE
    and never mistaken for absence.
    """
    matches = []
    errors = []
    pending = [(root_name, root_name.replace(os.sep, "/"), 0)]
    while pending:
        native, posix, depth = pending.pop()
        if depth == exact_depth:
            if fnmatch.fnmatchcase(posix, exact_path):
                matches.append(native)
            continue
        try:
            with os.scandir(native) as entries:
                children = list(entries)
        except OSError as exc:
            errors.append(("root scan failed", root_name, exc.errno))
            continue
        for entry in children:
            child_native = os.path.join(native, entry.name)
            child_posix = posix + "/" + entry.name
            if depth + 1 == exact_depth:
                pending.append((child_native, child_posix, depth + 1))
                continue
            try:
                descend = entry.is_dir(follow_symlinks=False)
            except OSError as exc:
                errors.append(("root scan failed", root_name, exc.errno))
                continue
            if descend:
                pending.append((child_native, child_posix, depth + 1))
    matches.sort()
    return matches, errors


def describe_scan_failures(failures):
    """Render every accumulated failure as `<reason>: <root> (errno N)`.

    Each root that failed is named exactly once per reason so the operator sees
    the full picture from one INDETERMINATE line, not just whichever root the
    old first-error abort happened to reach first.
    """

    rendered = []
    for reason, subject, error_number in failures:
        text = f"{reason}: {subject}"
        if error_number is not None:
            text += f" (errno {error_number})"
        if text not in rendered:
            rendered.append(text)
    return "; ".join(rendered)


def scan_roots():
    candidates = []
    bound_roots = []
    failures = []
    for root_name, expected_shape in ROOT_LAYOUTS:
        exact_depth, exact_path = ROOT_LAYOUT_PINS[root_name]
        try:
            root_lexical_entry = os.lstat(root_name)
        except FileNotFoundError:
            continue
        except OSError as exc:
            failures.append(("root inspect failed", root_name, exc.errno))
            continue
        try:
            lexical_before = raw_identity(root_lexical_entry)
            followed_before = followed_identity(root_name)
        except OSError as exc:
            failures.append(("root inspect failed", root_name, exc.errno))
            continue
        try:
            root_entry = os.stat(root_name)
        except OSError as exc:
            failures.append(("root target unavailable", root_name, exc.errno))
            continue
        if not stat.S_ISDIR(root_entry.st_mode):
            failures.append(("root is not a directory", root_name, None))
            continue
        physical_root = os.path.realpath(root_name)
        scan_results = scan_root_layout(root_name, exact_depth, exact_path)
        scan_matches, scan_errors = scan_results
        failures.extend(scan_errors)
        try:
            drifted = (
                lexical_identity(root_name) != lexical_before
                or followed_identity(root_name) != followed_before
                or os.path.realpath(root_name) != physical_root
            )
        except OSError as exc:
            failures.append(("root identity drifted", root_name, exc.errno))
            continue
        if drifted:
            failures.append(("root identity drifted", root_name, None))
            continue
        bound_roots.append(
            (root_name, physical_root, lexical_before, followed_before)
        )
        for candidate in scan_matches:
            parts, run_id = validate_suffix(root_name, candidate, expected_shape)
            if RUN_ID_RE.fullmatch(run_id) is None:
                continue
            physical_candidate = os.path.join(physical_root, *parts)
            candidates.append((run_id, physical_candidate))
    # Fail-closed, once, naming every failing root. Reached only after every
    # root has been given its chance, so the diagnosis is complete.
    #
    # Accumulation improves the DIAGNOSTIC, deliberately not the OUTCOME. A
    # "use whatever the readable roots produced" partial-success model is a
    # fail-open here and cannot be adopted: selection ranks candidates by
    # timestamp, and `discover` already treats an unknown artifact that is
    # newer than (or tied with) the winner as INDETERMINATE precisely because
    # such an artifact could outrank it. An unreadable root is the same
    # epistemic state with less information — it may hold a newer verdict for
    # this PR, so a verdict picked from the readable roots cannot be shown to
    # be the current one. Honouring it would let one chmod-000 stale worktree
    # silently downgrade /merge onto a superseded (possibly BLOCKER-carrying)
    # verdict. Missing roots are NOT failures — FileNotFoundError `continue`s
    # above — so the common single-root repo never reaches this branch.
    if failures:
        raise VerdictError(describe_scan_failures(failures))
    return candidates, bound_roots


def verify_bound_roots(bound_roots):
    for root_name, physical_root, lexical_before, followed_before in bound_roots:
        try:
            if (
                lexical_identity(root_name) != lexical_before
                or followed_identity(root_name) != followed_before
                or os.path.realpath(root_name) != physical_root
            ):
                raise VerdictError(f"root identity drifted: {root_name}")
        except OSError as exc:
            raise VerdictError(f"root identity drifted: {root_name}") from exc


def discover(expected_pr, capture_dir):
    candidates, bound_roots = scan_roots()
    if not candidates:
        raise SystemExit(1)
    targets = []
    unknown_timestamps = []
    for run_id, path in candidates:
        timestamp = run_id[:15]
        try:
            payload, _identity = runtime.secure_capture_regular(
                path, 2, MAXIMUM_SIZE
            )
            value, candidate_pr = parse_payload(payload)
        except Exception:
            unknown_timestamps.append(timestamp)
            continue
        if candidate_pr != expected_pr:
            continue
        try:
            artifact_sha, phase = validate_target(value)
        except VerdictError:
            unknown_timestamps.append(timestamp)
            continue
        targets.append((timestamp, payload, artifact_sha, phase))
    verify_bound_roots(bound_roots)
    if not targets:
        if unknown_timestamps:
            raise VerdictError("candidate identity or selected shape is unknown")
        raise SystemExit(1)

    selected_timestamp = max(target[0] for target in targets)
    if any(timestamp >= selected_timestamp for timestamp in unknown_timestamps):
        raise VerdictError(
            "identity unknown at or after the selected target timestamp"
        )
    selected = [target for target in targets if target[0] == selected_timestamp]
    selected_payload = selected[0][1]
    if any(target[1] != selected_payload for target in selected[1:]):
        raise VerdictError(
            "expected-PR artifacts tied at the selected timestamp diverge"
        )
    artifact_sha = selected[0][2]
    state, halted, blocker, critical, override, overflow = selected[0][3]

    snapshot_path, snapshot_identity, snapshot_digest = (
        runtime.secure_publish_captured(
            os.path.join(capture_dir, "review-pr-verdict.json"),
            selected_payload,
        )
    )
    recaptured, recaptured_identity = runtime.secure_capture_published(
        snapshot_path, snapshot_digest, 2, MAXIMUM_SIZE
    )
    if recaptured != selected_payload or recaptured_identity != snapshot_identity:
        raise VerdictError("published snapshot failed its immediate receipt check")
    return {
        "schema_version": 1,
        "run_timestamp": selected_timestamp,
        "snapshot_path": snapshot_path,
        "snapshot_sha256": snapshot_digest,
        "snapshot_identity": runtime.artifact_identity_receipt_components(
            snapshot_identity
        ),
        "pr": expected_pr,
        "artifact_sha": artifact_sha,
        "audit_state": state,
        "phase2_5_halted": halted,
        "phase2_5_blocker_count": blocker,
        "phase2_5_critical_count": critical,
        "phase2_5_override_reason": override,
        "phase2_5_halted_due_to_overflow": overflow,
    }


def discard_private_capture_dir(capture_dir):
    """Remove the private capture directory on every non-clean discover exit.

    `secure_publish_captured` deliberately never unlinks its attempt file, so
    once publication has run the mktemp directory is NOT empty and the shell's
    `rmdir` always failed -- silently, because it was `2>/dev/null || true`.
    Every non-clean exit therefore leaked a complete copy of the selected
    verdict under $TMPDIR. Only the interpreter that published knows the attempt
    name it chose, so the removal belongs here; the shell keeps a
    prefix-guarded fallback for the kill-before-Python case.

    Cleanup failure must never mask the original failure, so a rejection here
    only adds one stderr breadcrumb naming the leaked absolute path.
    """

    try:
        runtime.secure_remove_private_capture_dir(capture_dir, CAPTURE_DIR_PREFIX)
    except BaseException as exc:  # noqa: BLE001 - diagnostic only, never fatal
        print(
            f"warning: leaked private verdict capture directory {capture_dir}: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )


try:
    if command == "discover":
        if len(args) != 2 or re.fullmatch(r"[1-9][0-9]*", args[0]) is None:
            fail("PR number must be a positive integer")
        expected_pr = int(args[0])
        capture_dir = os.path.abspath(args[1])
        try:
            receipt = discover(expected_pr, capture_dir)
        except BaseException:
            discard_private_capture_dir(capture_dir)
            raise
        # end="" so native-Windows text mode cannot append \r\n: $() strips the
        # trailing \n but leaves the \r, and both consumers compare the receipt
        # byte-for-byte against its recapture.
        print(json.dumps(receipt, sort_keys=True, separators=(",", ":")), end="")
    elif command == "recapture":
        if len(args) != 1:
            fail("snapshot receipt argument missing")
        _receipt, path, digest, expected_identity = parse_receipt(args[0])
        _payload, observed_identity = runtime.secure_capture_published(
            path, digest, 2, MAXIMUM_SIZE
        )
        if observed_identity != expected_identity:
            raise VerdictError("snapshot identity drifted")
        print(args[0])
    elif command == "cleanup":
        if len(args) != 1:
            fail("snapshot receipt argument missing")
        _receipt, path, digest, expected_identity = parse_receipt(args[0])
        parent = os.path.dirname(path)
        if not os.path.basename(parent).startswith(CAPTURE_DIR_PREFIX):
            raise VerdictError("snapshot cleanup directory is not controller-owned")
        _payload, observed_identity = runtime.secure_capture_published(
            path, digest, 2, MAXIMUM_SIZE
        )
        if observed_identity != expected_identity:
            raise VerdictError("snapshot identity drifted before cleanup")
        current = os.lstat(path)
        if runtime._artifact_identity(current) != expected_identity:
            raise VerdictError("snapshot path drifted before cleanup")
        os.unlink(path)
        os.rmdir(parent)
    else:
        fail("unknown secure verdict command")
except SystemExit:
    raise
except (VerdictError, runtime.ManifestRejected, runtime.ManifestRuntimeError, OSError) as exc:
    fail(str(exc))
except Exception as exc:
    # Catch-all so no unhandled exception can reach the interpreter and exit 1.
    # Exit 1 is reserved for the two deliberate `raise SystemExit(1)` sites that
    # mean "scan completed, no candidate for this PR". Anything else -- an
    # AttributeError from version skew, a ValueError from a malformed layout
    # tuple, a RecursionError -- is an undetermined result, not proven absence.
    fail(f"unexpected selector failure: {type(exc).__name__}")
PY
}

# discover_review_verdict_json PR_NUMBER
# Stdout: one closed JSON receipt containing the securely published carrier
#         path/digest/identity plus the expected PR, validated 40-hex artifact
#         SHA, and fully typed Phase 2.5 tuple. No source pathname is exposed.
# Exit:   FOUND=0, exhaustive ABSENT=1, INDETERMINATE=2 (invalid input,
#         incomplete scan, root drift, ambiguous timestamp, or unknown bytes).
# Search surface — the four documented layouts (single source of truth for
# the glob set; sub-condition (d) prose + the Common Mistakes bullet mirror
# this enumeration; tests/merge.test.sh M63.worktree-glob.* locks all
# surfaces). Each `find` pins -mindepth/-maxdepth to the documented segment
# count so the -path glob is segment-exact (a bare find -path `*` would
# cross `/` boundaries):
#   .uberdev/runs/*/review-pr-verdict.json                      (canonical root)
#   .claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json  (/solve, /turbo)
#   .worktrees/*/.uberdev/runs/*/review-pr-verdict.json         (using-git-worktrees, hidden)
#   worktrees/*/.uberdev/runs/*/review-pr-verdict.json          (using-git-worktrees, visible)
# Why find, not glob: the previous SKILL.md fence used a `compgen -G` OR-chain
# — a bashism that silently misfires under the zsh Bash tool (#294
# _uberdev_goal_glob_worktree class; issue #303 / RFC 0012 §3.2 item 2).
# `find` is an external binary with identical semantics under bash 3.2, zsh,
# and CI bash. A root that does not exist is skipped at the pre-scan lstat
# (FileNotFoundError -> continue). find errors are NOT suppressed: any scan
# failure, root-identity drift, or capture failure is INDETERMINATE, never
# absence — do not reintroduce a 2>/dev/null here.
# Hardening (D4/F8): the <run-id> path segment is validated against
# RUN_ID_REGEX (^[0-9]{8}-[0-9]{6}-[a-f0-9]+$) via grep -E before the
# candidate participates in selection (no [[ =~ ]] — BASH_REMATCH is a
# bashism); the prefix segments are never concatenated from untrusted input.
# Identity-safe tie-break: only the YYYYMMDD-HHMMSS timestamp prefix ranks.
# At the selected timestamp, every expected-PR artifact must have identical
# captured bytes. A newer/equal unknown suppresses a target; without a target,
# any unknown makes absence unprovable. Known other-PR artifacts are ignored.
discover_review_verdict_json() {
  local pr_number="$1"
  # Herestring, not `printf | grep -q`: `grep -q` exits the moment it matches,
  # so the producer can take SIGPIPE (141). This library is SOURCED into the
  # caller's shell, so if that caller has `set -o pipefail` the pipeline status
  # becomes 141 and the guard rejects a perfectly VALID PR number as malformed
  # input — INDETERMINATE=2, which parks the PR. The window is small (this
  # payload is a handful of bytes) and load-dependent, which is exactly what
  # makes it undiagnosable from the symptom; the herestring removes the pipe.
  if ! grep -qE '^[1-9][0-9]*$' <<<"$pr_number"; then
    printf 'indeterminate: PR number must be a positive integer\n' >&2
    return 2
  fi
  # The prefix is the sole authority for BOTH the mktemp template and the
  # basename guard on the `rm -rf` below. An empty binding would widen that
  # guard's `case` pattern to `*` — assert instead of degrading silently.
  if [ -z "${UBERDEV_VERDICT_CAPTURE_PREFIX:-}" ]; then
    printf 'indeterminate: capture-directory prefix binding is missing (lib/discover.sh sourced incompletely?)\n' >&2
    return 2
  fi
  local capture_dir receipt rc
  if ! capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/${UBERDEV_VERDICT_CAPTURE_PREFIX}XXXXXX")"; then
    printf 'indeterminate: unable to allocate stable verdict capture directory\n' >&2
    return 2
  fi
  if receipt="$(_uberdev_review_verdict_python discover "$pr_number" "$capture_dir")"; then
    printf '%s\n' "$receipt"
    return 0
  else
    rc=$?
  fi
  # Failure path. The Python side already removed the private capture directory
  # (it is the only party that knows the attempt filename secure_publish_captured
  # chose, and that attempt file is deliberately never unlinked — which is why
  # the old `rmdir ... 2>/dev/null || true` ALWAYS failed and silently leaked a
  # full mode-0400 copy of the selected verdict into $TMPDIR on every non-clean
  # exit). This block only covers kill-before-Python: an interpreter that was
  # signalled, or never started, leaves an empty directory behind. The basename
  # prefix guard keeps the removal bound to a directory this function minted.
  case "${capture_dir##*/}" in
    "$UBERDEV_VERDICT_CAPTURE_PREFIX"*)
      rm -rf -- "$capture_dir" 2>/dev/null || true
      ;;
  esac
  if [ -e "$capture_dir" ]; then
    printf 'warning: leaked private verdict capture directory: %s\n' \
      "$capture_dir" >&2
  fi
  case "$rc" in
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# recapture_review_verdict_snapshot RECEIPT_JSON
# Re-bind the published carrier to both its digest and six-field identity.
# Any replacement (including byte-identical), mutation, symlink, non-regular
# node, ownership change, or malformed receipt is INDETERMINATE=2.
recapture_review_verdict_snapshot() {
  _uberdev_review_verdict_python recapture "$1" || return 2
}

# cleanup_review_verdict_snapshot RECEIPT_JSON
# Remove only an unchanged carrier inside its private mktemp-owned directory.
cleanup_review_verdict_snapshot() {
  _uberdev_review_verdict_python cleanup "$1" || return 2
}

# emit_gate_fail PR_NUMBER REASON
# Discovery-adjacent helper. Appends one gate_fail event to the audit log
# with {event:"gate_fail",pr:<N>,data:{reason:"<reason>"}} and writes a
# stderr breadcrumb. Mirrors the inline gate_fail pattern used elsewhere
# in /merge so Step 1.4's `pr_view_projection` failure path can short-
# circuit cleanly when the projection lib call fails.
emit_gate_fail() {
  local pr_number="$1"
  local reason="$2"
  # Bare-numeric pr_number in JSON; sanitise non-integer input to 0 so the
  # emitted line stays valid JSON regardless of caller bugs.
  case "$pr_number" in ''|*[!0-9]*) pr_number=0 ;; esac
  # JSON-escape reason. Today's only caller passes the static enum
  # GATE_FAIL_REASON_ENUM literal "pr_view_unreachable" — escape is a no-op
  # there. Defense-in-depth so the function contract no longer relies on
  # caller discipline (mirrors _uberdev_discover_emit_audit).
  local reason_escaped
  reason_escaped="$(_uberdev_discover_json_escape_str "$reason")"
  local audit_path
  audit_path="$(_uberdev_discover_audit_path)"
  local audit_dir
  audit_dir="$(dirname "$audit_path")"
  local ts
  ts="$(_uberdev_discover_iso_ts)"
  mkdir -p "$audit_dir" 2>/dev/null || true
  printf '{"ts":"%s","event":"gate_fail","pr":%s,"data":{"reason":"%s"}}\n' \
    "$ts" "$pr_number" "$reason_escaped" \
    >> "$audit_path" 2>/dev/null || true
  printf 'gate_fail: PR #%s reason=%s\n' "$pr_number" "$reason" >&2
}
