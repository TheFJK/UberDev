#!/usr/bin/env bash
# Shape-check for the `codex` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_codex). Verifies: codex is in the backend enum; the
# availability probe exists; preflight resolves codex (explicit + auto when
# CODEX_HOME set / claude absent); the dispatch_one switch routes codex;
# the backend execs `codex exec` (not claude) with --sandbox workspace-write,
# --json, -o, nohup-detached, PID-captured like the background arm; and the
# goal-state liveness poll is backend-aware (kill -0 for codex/background).
# RFC 0012 §3.4 codex-port.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
GOAL_LIB="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
PLUGIN_HOOKS="$REPO_ROOT/codex/uberdev-codex/hooks/hooks.json"
PLUGIN_ROOT="$REPO_ROOT/codex/uberdev-codex"
CODEX_DISPATCH_LIB="$PLUGIN_ROOT/lib/dispatch.sh"
AGENT_DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/agent-dispatch.sh"
CODEX_AGENT_DISPATCH_LIB="$PLUGIN_ROOT/lib/agent-dispatch.sh"
CODEX_GOAL_LIB="$PLUGIN_ROOT/lib/goal-state.sh"
CODEX_CONFIG_LIB="$PLUGIN_ROOT/lib/config-read.sh"
WORKTREE_RECEIPTS="$REPO_ROOT/plugins/uberdev/lib/worktree_receipts.py"

grep -Fq 'child-receipts.py:is_link_or_reparse' "$DISPATCH_LIB" || {
  echo 'dispatch runtime-root comment does not name the reparse-aware receipt helper' >&2
  exit 1
}
grep -Fq 'run_manifest.py:_secure_open_regular' "$DISPATCH_LIB" || {
  echo 'dispatch runtime-root comment does not name the reparse-aware manifest helper' >&2
  exit 1
}

# Behavioral fixtures intentionally narrow PATH to stub git/codex. Preserve a
# validated interpreter argv first so dispatch exercises the real portable
# resolver contract instead of depending on which Python launcher survives in
# each fixture directory (notably native Windows runners).
_UBERDEV_PYTHON_PREFIX=''
if _UBERDEV_PYTHON_EXE="$(command -v python3 2>/dev/null)" && [ -n "$_UBERDEV_PYTHON_EXE" ]; then
  :
elif _UBERDEV_PYTHON_EXE="$(command -v python 2>/dev/null)" && [ -n "$_UBERDEV_PYTHON_EXE" ]; then
  :
elif _UBERDEV_PYTHON_EXE="$(command -v py 2>/dev/null)" && [ -n "$_UBERDEV_PYTHON_EXE" ]; then
  _UBERDEV_PYTHON_PREFIX='-3'
else
  echo "error: Python 3 is required for dispatch-codex fixtures" >&2
  exit 1
fi
export _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX

native_python() {
  if [ -n "$_UBERDEV_PYTHON_PREFIX" ]; then
    "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$@"
  else
    "$_UBERDEV_PYTHON_EXE" "$@"
  fi
}

# Git Bash's mktemp may spell the current user's temp root through an 8.3
# alias. Successful authority fixtures must model production, where the run
# root and agent outputs have already crossed a trusted native-Python realpath
# boundary. Raw Git Bash spellings are exercised separately as negatives.
canonical_test_path() {
  local path="$1"
  case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
    MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
      path="$(cygpath -m "$path")" || return $?
      ;;
  esac
  native_python -I -B -c \
    'import os,sys; print(os.path.realpath(sys.argv[1]).replace(os.path.sep,"/"),end="")' \
    "$path"
}

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        pattern: $pattern"; FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        pattern: $pattern (must not appear)"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

pass_msg() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; FAIL=$((FAIL + 1)); }
extract_function_body() {
  local fn="$1" file="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" {in_body=1; depth=0}
    in_body {
      print
      depth += gsub(/\{/, "{")
      depth -= gsub(/\}/, "}")
      if (depth == 0) exit
    }
  ' "$file"
}

receipt_start_head() {
  printf '%s' "${1##*:}"
}

receipt_tombstone() {
  python3 -I -B - "$1" "$2" <<'PY'
import hashlib,os,sys
receipt,token=sys.argv[1:]
digest=hashlib.sha256(b"uberdev.worktree-owner.retired-v1\0"+token.encode("ascii")).hexdigest()
print(os.path.join(os.path.dirname(receipt),f".worktree-owner.retired-v1-{digest}.json"),end="")
PY
}

receipt_inspect() {
  local repo="$1" relative="$2" branch="$3" receipt="$4" token="$5"
  local native_helper="$WORKTREE_RECEIPTS"
  case "$native_helper" in /*|[A-Za-z]:[\\/]*) ;; *) return 2 ;; esac
  [ -f "$native_helper" ] || return 2
  case "${MSYSTEM:-}:$(uname -s 2>/dev/null)" in
    MINGW*:*|MSYS*:*|CYGWIN*:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
      native_helper="$(cygpath -m "$native_helper")" || return $?
      ;;
  esac
  MSYS_NO_PATHCONV=1 native_python -I -B "$native_helper" inspect \
    --repo "$repo" --relative "$relative" --branch "$branch" \
    --receipt "$receipt" --start-head "$(receipt_start_head "$token")" --token "$token"
}

receipt_is_retired() {
  [ "$(receipt_inspect "$@" 2>/dev/null)" = '{"state":"retired"}' ]
}

retire_preserved_fixture() {
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" failed' \
    _ "$DISPATCH_LIB" "$1" "$2" "$3" "$4" "$5"
}

for receipt_dispatch_mirror in "$DISPATCH_LIB" "$CODEX_DISPATCH_LIB"; do
  assert_grep "$receipt_dispatch_mirror" \
    '_UBERDEV_DISPATCH_LIB_DIR/worktree_receipts\.py' \
    "worktree receipt lifecycle uses the absolute sibling helper ($(basename "$(dirname "$(dirname "$receipt_dispatch_mirror")")"))"
  assert_grep_not "$receipt_dispatch_mirror" \
    '_uberdev_dispatch_discard_codex_worktree_receipt|os\.unlink\(path' \
    "dispatch never path-unlinks an ownership receipt ($(basename "$(dirname "$(dirname "$receipt_dispatch_mirror")")"))"
done

fixture_receipt_guard_audit() {
  local source_path="$1" fixture_receipt_guard_scan fixture_receipt_guard_rc
  if fixture_receipt_guard_scan="$(native_python -I -B - "$source_path" 2>&1 <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text().splitlines()
wrapper = "_uberdev_dispatch_worktree_" + "receipt_helper"
real_wrapper = wrapper + "_real"
python_launch = "_uberdev_dispatch_" + "python -I -B"
receipt_script = "$_UBERDEV_DISPATCH_LIB_DIR/" + "worktree_receipts.py"
direct_launches = []
saved_aliases = []
delegations = []
delegate_pattern = re.compile(
    re.escape(real_wrapper) + r'\s+(?:"\$@"|create(?:\s|\\|$))'
)
for lineno, line in enumerate(source, 1):
    code = line.split("#", 1)[0]
    if not code.strip():
        continue
    if python_launch in code and receipt_script in code:
        direct_launches.append(lineno)
    if "declare -f " + wrapper in code and real_wrapper in code:
        saved_aliases.append(lineno)
    if delegate_pattern.search(code):
        delegations.append(lineno)

errors = []
if direct_launches:
    errors.append(
        f"expected 0 direct native-helper launches, found {len(direct_launches)} "
        f"(lines: {' '.join(map(str, direct_launches))})"
    )
if len(saved_aliases) != 8:
    errors.append(
        f"expected 8 saved production-helper aliases, found {len(saved_aliases)} "
        f"(lines: {' '.join(map(str, saved_aliases))})"
    )
if len(delegations) != 11:
    errors.append(
        f"expected 11 production-helper delegations, found {len(delegations)} "
        f"(lines: {' '.join(map(str, delegations))})"
    )
if errors:
    print("; ".join(errors), end="")
    raise SystemExit(42)
PY
  )"; then
    if [ -n "$fixture_receipt_guard_scan" ]; then
      printf 'unexpected scanner output: %s' "$fixture_receipt_guard_scan"
      return 2
    fi
    return 0
  else
    fixture_receipt_guard_rc=$?
    if [ "$fixture_receipt_guard_rc" -eq 42 ]; then
      printf '%s' "$fixture_receipt_guard_scan"
      return 1
    fi
    printf 'scanner rc=%s: %s' "$fixture_receipt_guard_rc" \
      "$(printf '%s' "$fixture_receipt_guard_scan" | tr '\n' ' ')"
    return 2
  fi
}

fixture_receipt_guard_errors="$(fixture_receipt_guard_audit "$0")"
fixture_receipt_guard_rc=$?
case "$fixture_receipt_guard_rc" in
  0)
    pass_msg "test fixture receipt-helper overrides delegate every real launch through production"
    ;;
  1)
    fail_msg "test fixture receipt-helper overrides delegate every real launch through production" \
      "$fixture_receipt_guard_errors"
    ;;
  *)
    fail_msg "test fixture receipt-helper override audit executes successfully" \
      "$fixture_receipt_guard_errors"
    ;;
esac

fixture_receipt_guard_missing="$REPO_ROOT/tests/.dispatch-codex-missing-source"
fixture_receipt_guard_failure="$(fixture_receipt_guard_audit "$fixture_receipt_guard_missing")"
fixture_receipt_guard_failure_rc=$?
case "$fixture_receipt_guard_failure_rc:$fixture_receipt_guard_failure" in
  2:scanner\ rc=*)
    pass_msg "test fixture receipt-helper audit fails closed on source read errors"
    ;;
  *)
    fail_msg "test fixture receipt-helper audit fails closed on source read errors" \
      "rc=$fixture_receipt_guard_failure_rc result=$fixture_receipt_guard_failure"
    ;;
esac

fixture_receipt_guard_failure="$(fixture_receipt_guard_audit "$WORKTREE_RECEIPTS")"
fixture_receipt_guard_failure_rc=$?
case "$fixture_receipt_guard_failure_rc:$fixture_receipt_guard_failure" in
  1:*expected\ 8\ saved\ production-helper\ aliases,\ found\ 0*expected\ 11\ production-helper\ delegations,\ found\ 0*)
    pass_msg "test fixture receipt-helper audit rejects a vacuous zero-delegation source"
    ;;
  *)
    fail_msg "test fixture receipt-helper audit rejects a vacuous zero-delegation source" \
      "rc=$fixture_receipt_guard_failure_rc result=$fixture_receipt_guard_failure"
    ;;
esac

RECEIPT_INSPECT_GUARD_TMP=''
if RECEIPT_INSPECT_GUARD_TMP="$(mktemp -d)" \
    && [ -n "$RECEIPT_INSPECT_GUARD_TMP" ]; then
  if (
    export MSYSTEM=MINGW64
    cygpath() {
      printf '%s\n' "$*" >"$RECEIPT_INSPECT_GUARD_TMP/conversions"
      [ "$1" = -m ] && [ "$2" = "$WORKTREE_RECEIPTS" ] \
        && printf 'C:/Trusted/worktree_receipts.py'
    }
    native_python() {
      printf '%s\n' "${MSYS_NO_PATHCONV:-}" >"$RECEIPT_INSPECT_GUARD_TMP/env"
      printf '%s\n' "$@" >"$RECEIPT_INSPECT_GUARD_TMP/args"
    }
    python3() {
      : >"$RECEIPT_INSPECT_GUARD_TMP/unexpected-python3"
      return 91
    }
    receipt_inspect 'C:/Canonical/Repo' \
      '.claude/worktrees/solve-issue-335-inspect-guard' \
      'worktree-solve-issue-335-inspect-guard' \
      'C:/Canonical/Runtime/receipt.json' \
      '0123456789abcdef0123456789abcdef:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  ) && [ "$(cat "$RECEIPT_INSPECT_GUARD_TMP/conversions")" = "-m $WORKTREE_RECEIPTS" ] \
    && native_python -I -B - "$RECEIPT_INSPECT_GUARD_TMP" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
assert not (root / "unexpected-python3").exists()
assert (root / "env").read_text().splitlines() == ["1"]
assert (root / "args").read_text().splitlines() == [
    "-I",
    "-B",
    "C:/Trusted/worktree_receipts.py",
    "inspect",
    "--repo",
    "C:/Canonical/Repo",
    "--relative",
    ".claude/worktrees/solve-issue-335-inspect-guard",
    "--branch",
    "worktree-solve-issue-335-inspect-guard",
    "--receipt",
    "C:/Canonical/Runtime/receipt.json",
    "--start-head",
    "a" * 40,
    "--token",
    "0123456789abcdef0123456789abcdef:" + "a" * 40,
]
PY
  then
    pass_msg "receipt inspection converts only its trusted helper and preserves authority argv"
  else
    fail_msg "receipt inspection converts only its trusted helper and preserves authority argv"
  fi
  if [ -n "$RECEIPT_INSPECT_GUARD_TMP" ]; then
    rm -rf "$RECEIPT_INSPECT_GUARD_TMP"
  fi
else
  fail_msg "receipt inspection guard fixture creates a nonempty temporary directory"
fi

echo "== Native receipt helper preserves authority spelling =="
NATIVE_AUTHORITY_TMP="$(mktemp -d)"
for receipt_dispatch_mirror in "$DISPATCH_LIB" "$CODEX_DISPATCH_LIB"; do
  mirror_name="$(basename "$(dirname "$(dirname "$receipt_dispatch_mirror")")")"
  native_authority_args="$NATIVE_AUTHORITY_TMP/$mirror_name.args"
  native_authority_conversions="$NATIVE_AUTHORITY_TMP/$mirror_name.conversions"
  native_authority_env="$NATIVE_AUTHORITY_TMP/$mirror_name.env"
  if MSYSTEM=MINGW64 bash -c '
    . "$1"
    args_file="$2"
    conversions_file="$3"
    env_file="$4"
    cygpath() {
      printf "%s\n" "$*" >>"$conversions_file"
      case "$*" in
        "-m "*"/worktree_receipts.py") printf "C:/Trusted/worktree_receipts.py" ;;
        *) return 92 ;;
      esac
    }
    _uberdev_dispatch_python() {
      printf "%s\n" "${MSYS_NO_PATHCONV:-}" >"$env_file"
      printf "%s\n" "$@" >"$args_file"
    }
    _uberdev_dispatch_worktree_receipt_helper create \
      --repo /git-bash/repo \
      --relative .claude/worktrees/solve-issue-335-native-authority \
      --branch worktree-solve-issue-335-native-authority \
      --receipt /git-bash/runtime/receipt.json \
      --start-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ' _ "$receipt_dispatch_mirror" "$native_authority_args" "$native_authority_conversions" \
      "$native_authority_env" \
      && native_python -I -B - \
        "$native_authority_args" "$native_authority_conversions" \
        "$native_authority_env" <<'PY'
import pathlib
import sys

args_path, conversions_path, env_path = map(pathlib.Path, sys.argv[1:])
assert args_path.read_text().splitlines() == [
    "-I",
    "-B",
    "C:/Trusted/worktree_receipts.py",
    "create",
    "--repo",
    "/git-bash/repo",
    "--relative",
    ".claude/worktrees/solve-issue-335-native-authority",
    "--branch",
    "worktree-solve-issue-335-native-authority",
    "--receipt",
    "/git-bash/runtime/receipt.json",
    "--start-head",
    "a" * 40,
]
conversions = conversions_path.read_text().splitlines()
assert len(conversions) == 1
assert conversions[0].startswith("-m ")
assert conversions[0].endswith("/worktree_receipts.py")
assert env_path.read_text().splitlines() == ["1"]
PY
  then
    pass_msg "receipt helper converts only its trusted script and preserves authority argv ($mirror_name)"
  else
    fail_msg "receipt helper preserves authority argv across native launch" "$mirror_name"
  fi

  native_authority_fail_marker="$NATIVE_AUTHORITY_TMP/$mirror_name.python-called"
  if MSYSTEM=MINGW64 bash -c '
    . "$1"
    marker="$2"
    cygpath() { return 93; }
    _uberdev_dispatch_python() { : >"$marker"; }
    _uberdev_dispatch_worktree_receipt_helper create \
      --repo /git-bash/repo \
      --relative .claude/worktrees/solve-issue-335-native-authority \
      --branch worktree-solve-issue-335-native-authority \
      --receipt /git-bash/runtime/receipt.json \
      --start-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ' _ "$receipt_dispatch_mirror" "$native_authority_fail_marker" >/dev/null 2>&1; then
    fail_msg "receipt helper fails closed when trusted helper conversion fails" "$mirror_name returned success"
  elif [ -e "$native_authority_fail_marker" ]; then
    fail_msg "receipt helper fails before native Python when helper conversion fails" "$mirror_name invoked Python"
  else
    pass_msg "receipt helper fails closed before native Python on helper conversion failure ($mirror_name)"
  fi
done
rm -rf "$NATIVE_AUTHORITY_TMP"

for codex_dispatch_mirror in "$DISPATCH_LIB" "$CODEX_DISPATCH_LIB"; do
  if extract_function_body _uberdev_dispatch_codex "$codex_dispatch_mirror" \
      | grep -Fq '${BG_TURBO_ENV[@]+"${BG_TURBO_ENV[@]}"}'; then
    pass_msg "Codex optional turbo env is safe under Bash 3.2 nounset ($(basename "$(dirname "$(dirname "$codex_dispatch_mirror")")"))"
  else
    fail_msg "Codex optional turbo env is safe under Bash 3.2 nounset" "$codex_dispatch_mirror"
  fi
done

if [ "$(native_python -I -B -c 'import os; print(os.name, end="")')" = nt ]; then
  echo "== Native Windows Git Bash receipt boundary =="
  WINDOWS_BOUNDARY_TMP="$(mktemp -d)"
  mkdir -p "$WINDOWS_BOUNDARY_TMP/RepoCanonical" "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical"
  chmod 700 "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical"
  (
    cd "$WINDOWS_BOUNDARY_TMP/RepoCanonical" || exit 1
    git init -q
    git config user.name 'UberDev Windows Boundary'
    git config user.email 'uberdev-windows-boundary@example.invalid'
    printf 'base\n' >base.txt
    git add base.txt
    git commit -qm base
  )
  windows_boundary_head="$(git -C "$WINDOWS_BOUNDARY_TMP/RepoCanonical" rev-parse HEAD)"
  windows_boundary_relative='.claude/worktrees/solve-issue-335-windows-boundary'
  windows_boundary_branch='worktree-solve-issue-335-windows-boundary'
  windows_raw_receipt="$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-raw.owner.json"
  windows_raw_stderr="$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-raw.stderr"
  windows_raw_output="$(bash -c '
    . "$1"
    _uberdev_dispatch_worktree_receipt_helper create \
      --repo "$2" --relative "$3" --branch "$4" \
      --receipt "$5" --start-head "$6"
  ' _ "$DISPATCH_LIB" "$WINDOWS_BOUNDARY_TMP/RepoCanonical" \
    "$windows_boundary_relative" "$windows_boundary_branch" \
    "$windows_raw_receipt" "$windows_boundary_head" \
    2>"$windows_raw_stderr")"
  windows_raw_rc=$?
  if [ "$windows_raw_rc" -eq 3 ] \
      && [ -z "$windows_raw_output" ] \
      && [ ! -e "$windows_raw_receipt" ] \
      && [ "$(cat "$windows_raw_stderr")" = 'uberdev worktree receipt: invalid authority' ]; then
    pass_msg "receipt helper preserves and rejects raw Git Bash authority paths"
  else
    fail_msg "receipt helper rejects raw Git Bash authority without argv rewriting" \
      "rc=$windows_raw_rc stdout=$windows_raw_output stderr=$(tr '\n' ';' <"$windows_raw_stderr")"
  fi

  windows_repo_native="$(canonical_test_path "$WINDOWS_BOUNDARY_TMP/RepoCanonical")"
  windows_runtime_native="$(canonical_test_path "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical")"
  windows_boundary_receipt="$windows_runtime_native/windows-boundary.owner.json"
  windows_boundary_stderr="$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-boundary.stderr"
  windows_boundary_output="$(bash -c '
    . "$1"
    _uberdev_dispatch_worktree_receipt_helper create \
      --repo "$2" --relative "$3" --branch "$4" \
      --receipt "$5" --start-head "$6"
  ' _ "$DISPATCH_LIB" "$windows_repo_native" \
    "$windows_boundary_relative" "$windows_boundary_branch" \
    "$windows_boundary_receipt" "$windows_boundary_head" \
    2>"$windows_boundary_stderr")"
  windows_boundary_rc=$?
  windows_boundary_state="$(printf '%s' "$windows_boundary_output" \
    | native_python -I -B -c 'import json,sys; print(json.load(sys.stdin).get("state", ""), end="")' \
      2>/dev/null)"
  if [ "$windows_boundary_rc" -eq 0 ] \
      && [ "$windows_boundary_state" = active ] \
      && [ -f "$windows_boundary_receipt" ] \
      && [ ! -s "$windows_boundary_stderr" ]; then
    pass_msg "canonical native authority paths reach receipt creation unchanged"
  else
    fail_msg "canonical native authority paths reach receipt creation unchanged" \
      "rc=$windows_boundary_rc state=$windows_boundary_state stderr=$(tr '\n' ';' <"$windows_boundary_stderr")"
  fi

  windows_short_repo="$(cygpath -m "$WINDOWS_BOUNDARY_TMP/RepoCanonical")"
  windows_short_repo_rc=$?
  windows_short_receipt="$(cygpath -m "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-short.owner.json")"
  windows_short_receipt_rc=$?
  if [ "$windows_short_repo_rc" -ne 0 ] \
      || [ -z "$windows_short_repo" ] \
      || [ "$windows_short_receipt_rc" -ne 0 ] \
      || [ -z "$windows_short_receipt" ]; then
    fail_msg "native Windows prepares short-name authority alias probe" \
      "cygpath conversion failed or returned empty (repo rc=$windows_short_repo_rc receipt rc=$windows_short_receipt_rc)"
  elif [ "$windows_short_repo" != "$windows_repo_native" ] \
      || [ "${windows_short_receipt%/*}" != "$windows_runtime_native" ]; then
    windows_short_stderr="$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-short.stderr"
    if bash -c '
      . "$1"
      _uberdev_dispatch_worktree_receipt_helper create \
        --repo "$2" --relative "$3" --branch "$4" \
        --receipt "$5" --start-head "$6"
    ' _ "$DISPATCH_LIB" "$windows_short_repo" \
      '.claude/worktrees/solve-issue-335-windows-short' \
      'worktree-solve-issue-335-windows-short' \
      "$windows_short_receipt" "$windows_boundary_head" \
      >"$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-short.stdout" \
      2>"$windows_short_stderr"; then
      fail_msg "native Windows rejects short-name authority aliases" "short alias accepted"
    elif [ ! -e "$windows_short_receipt" ] \
        && [ ! -s "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/windows-short.stdout" ] \
        && [ "$(cat "$windows_short_stderr")" = 'uberdev worktree receipt: invalid authority' ]; then
      pass_msg "native Windows rejects short-name authority aliases"
    else
      fail_msg "native Windows rejects short-name authority aliases" \
        "stderr=$(tr '\n' ';' <"$windows_short_stderr")"
    fi
  else
    pass_msg "native Windows has no distinct short-name authority alias to reject"
  fi

  windows_case_errors=''
  for windows_case_mode in repo parent; do
    windows_case_receipt="$windows_runtime_native/case-$windows_case_mode.owner.json"
    windows_case_repo="$windows_repo_native"
    windows_case_parent="$windows_runtime_native"
    if [ "$windows_case_mode" = repo ]; then
      windows_case_repo="${windows_repo_native%/RepoCanonical}/repocanonical"
    else
      windows_case_parent="${windows_runtime_native%/RuntimeCanonical}/runtimecanonical"
      windows_case_receipt="$windows_case_parent/case-$windows_case_mode.owner.json"
    fi
    windows_case_stderr="$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/case-$windows_case_mode.stderr"
    bash -c '
      . "$1"
      _uberdev_dispatch_worktree_receipt_helper create \
        --repo "$2" --relative "$3" --branch "$4" \
        --receipt "$5" --start-head "$6"
    ' _ "$DISPATCH_LIB" "$windows_case_repo" \
      ".claude/worktrees/solve-issue-335-windows-case-$windows_case_mode" \
      "worktree-solve-issue-335-windows-case-$windows_case_mode" \
      "$windows_case_receipt" "$windows_boundary_head" \
      >"$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/case-$windows_case_mode.stdout" \
      2>"$windows_case_stderr"
    windows_case_rc=$?
    [ "$windows_case_rc" -eq 3 ] \
      || windows_case_errors="$windows_case_errors $windows_case_mode-rc-$windows_case_rc"
    [ ! -e "$windows_case_receipt" ] \
      || windows_case_errors="$windows_case_errors $windows_case_mode-receipt"
    [ ! -s "$WINDOWS_BOUNDARY_TMP/RuntimeCanonical/case-$windows_case_mode.stdout" ] \
      || windows_case_errors="$windows_case_errors $windows_case_mode-stdout"
    [ "$(cat "$windows_case_stderr")" = 'uberdev worktree receipt: invalid authority' ] \
      || windows_case_errors="$windows_case_errors $windows_case_mode-stderr"
  done
  if [ -z "$windows_case_errors" ]; then
    pass_msg "native Windows rejects differently cased repo and receipt-parent aliases"
  else
    fail_msg "native Windows rejects differently cased repo and receipt-parent aliases" \
      "$windows_case_errors"
  fi
  rm -rf "$WINDOWS_BOUNDARY_TMP"
fi

echo "== Secure default runtime and unique Codex child identities =="
RUNTIME_TMP="$(mktemp -d)"
RUNTIME_ROOT="$(TMPDIR="$RUNTIME_TMP" bash -c 'unset UBERDEV_TMPDIR; . "$1"; _uberdev_dispatch_runtime_root' _ "$DISPATCH_LIB")"
if python3 -I - "$RUNTIME_TMP" "$RUNTIME_ROOT" <<'PY'
import os, pathlib, stat, sys
base, root = map(pathlib.Path, sys.argv[1:])
entry = root.stat()
assert root.parent.resolve() == base.resolve()
uid_fn = getattr(os, "geteuid", None)
if uid_fn is not None:
    assert entry.st_uid == uid_fn()
if os.name != "nt":
    assert stat.S_IMODE(entry.st_mode) == 0o700
PY
then
  pass_msg "default runtime root is private, user-owned, and mode 0700"
else
  fail_msg "default runtime root is private, user-owned, and mode 0700" "$RUNTIME_ROOT"
fi
IDENTITY_A="$(UBERDEV_AGENT_INSTANCE_ID=review-code-a1 bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
IDENTITY_B="$(UBERDEV_AGENT_INSTANCE_ID=review-types-a1 bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
if [ -n "$IDENTITY_A" ] && [ -n "$IDENTITY_B" ] && [ "$IDENTITY_A" != "$IDENTITY_B" ] \
    && [[ "$IDENTITY_A" == review-code-a1-* ]] && [[ "$IDENTITY_B" == review-types-a1-* ]]; then
  pass_msg "Codex worktree identity is deterministically unique per fanout instance"
else
  fail_msg "Codex worktree identity is deterministically unique per fanout instance" "a=$IDENTITY_A b=$IDENTITY_B"
fi
rm -rf "$RUNTIME_TMP"

RUNTIME_LINK_TMP="$(mktemp -d)"
printf 'do-not-touch\n' >"$RUNTIME_LINK_TMP/target"
ln -s "$RUNTIME_LINK_TMP/target" "$RUNTIME_LINK_TMP/uberdev-$(id -u)"
if TMPDIR="$RUNTIME_LINK_TMP" bash -c 'unset UBERDEV_TMPDIR; . "$1"; _uberdev_dispatch_runtime_root' _ "$DISPATCH_LIB" >/dev/null 2>&1; then
  fail_msg "default runtime root rejects a pre-created symlink" "symlink was accepted"
elif [ "$(cat "$RUNTIME_LINK_TMP/target")" = do-not-touch ]; then
  pass_msg "default runtime root rejects a pre-created symlink without modifying its target"
else
  fail_msg "default runtime root rejects a pre-created symlink" "symlink target was modified"
fi
rm -rf "$RUNTIME_LINK_TMP"

RUNTIME_FILE_TMP="$(mktemp -d)"
RUNTIME_FILE="$RUNTIME_FILE_TMP/not-a-directory"
printf 'occupied\n' >"$RUNTIME_FILE"
set +e
RUNTIME_FILE_ERROR="$(UBERDEV_TMPDIR="$RUNTIME_FILE" bash -c \
  '. "$1"; _uberdev_dispatch_runtime_root' _ "$DISPATCH_LIB" 2>&1)"
RUNTIME_FILE_RC=$?
RUNTIME_AUDIT="$RUNTIME_FILE_TMP/audit.log"
RUNTIME_DISPATCH_ERROR="$(UBERDEV_TMPDIR="$RUNTIME_FILE" bash -c '
  . "$1"
  AUDIT_CAPTURE="$2"
  _uberdev_audit_emit() { printf "%s\t%s\n" "$1" "$2" >"$AUDIT_CAPTURE"; }
  UBERDEV_RESOLVED_BACKEND=codex
  uberdev_dispatch_one 335 small /dev/null
' _ "$DISPATCH_LIB" "$RUNTIME_AUDIT" 2>&1)"
RUNTIME_DISPATCH_RC=$?
set -e
if [ "$RUNTIME_FILE_RC" -ne 0 ] \
    && printf '%s\n' "$RUNTIME_FILE_ERROR" | grep -Fq 'unsafe runtime root (not-directory)' \
    && [ "$RUNTIME_DISPATCH_RC" -ne 0 ] \
    && printf '%s\n' "$RUNTIME_DISPATCH_ERROR" | grep -Fq 'unsafe runtime root (not-directory)' \
    && grep -Fq $'dispatch_setup_failed\t' "$RUNTIME_AUDIT" \
    && grep -Fq '"phase":"runtime_root"' "$RUNTIME_AUDIT"; then
  pass_msg "runtime-root rejection is actionable and records dispatch setup failure"
else
  fail_msg "runtime-root rejection is actionable and audited" "$RUNTIME_FILE_ERROR $RUNTIME_DISPATCH_ERROR"
fi
rm -rf "$RUNTIME_FILE_TMP"

# Exercise the actual platform fallback rather than an injected TMPDIR. On
# macOS /tmp is commonly a symlink to a root-owned platform directory; on
# Linux it is normally root-owned directly. In either case only the EUID-owned
# 0700 child is accepted as the runtime root.
PLATFORM_RUNTIME_ROOT="$(env -u TMPDIR -u UBERDEV_TMPDIR bash -c \
  '. "$1"; _uberdev_dispatch_runtime_root' _ "$DISPATCH_LIB")"
PLATFORM_TEMP_ROOT="$(env -u TMPDIR -u UBERDEV_TMPDIR python3 -I -c \
  'import os,tempfile; print(os.path.realpath(tempfile.gettempdir()),end="")')"
if python3 -I - "$PLATFORM_RUNTIME_ROOT" "$PLATFORM_TEMP_ROOT" <<'PY'
import os, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
platform = pathlib.Path(sys.argv[2])
entry = root.stat()
assert root.parent.resolve() == platform.resolve(), (root, platform)
uid_fn = getattr(os, "geteuid", None)
if uid_fn is not None:
    assert entry.st_uid == uid_fn()
if os.name != "nt":
    assert stat.S_IMODE(entry.st_mode) == 0o700
PY
then
  pass_msg "no-TMPDIR fallback creates a private child under the platform temporary root"
else
  fail_msg "no-TMPDIR fallback creates a private child under the platform temporary root" "$PLATFORM_RUNTIME_ROOT"
fi

echo "== Exact Codex child worktree cleanup preserves results =="
CLEANUP_TMP="$(canonical_test_path "$(mktemp -d)")" || exit 1
mkdir -p "$CLEANUP_TMP/repo" "$CLEANUP_TMP/runtime"
chmod 700 "$CLEANUP_TMP/runtime"
(
  cd "$CLEANUP_TMP/repo"
  git init -q
  git config user.name 'UberDev Test'
  git config user.email 'uberdev-test@example.invalid'
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm base
)

# A receipt is creation authority only when both the target path and branch
# were absent before launch. Pre-existing clean artifacts at the starting commit
# must remain untouched instead of becoming eligible for force cleanup.
collision_instance='cleanup-preexisting-worktree-a1'
collision_slug="$(UBERDEV_AGENT_INSTANCE_ID="$collision_instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
collision_relative=".claude/worktrees/solve-issue-335-$collision_slug"
collision_branch="worktree-solve-issue-335-$collision_slug"
collision_receipt="$CLEANUP_TMP/runtime/preexisting-worktree.owner.json"
git -C "$CLEANUP_TMP/repo" worktree add -q "$collision_relative" -b "$collision_branch"
if bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$collision_relative" "$collision_branch" "$collision_receipt" >/dev/null 2>&1; then
  fail_msg "pre-existing clean worktree cannot mint cleanup authority" "receipt creation succeeded"
elif [ -d "$CLEANUP_TMP/repo/$collision_relative" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$collision_branch" \
    && [ ! -e "$collision_receipt" ]; then
  pass_msg "pre-existing clean worktree cannot mint cleanup authority"
else
  fail_msg "pre-existing clean worktree remains untouched" "path, branch, or receipt state changed"
fi
git -C "$CLEANUP_TMP/repo" worktree remove --force "$collision_relative"
git -C "$CLEANUP_TMP/repo" branch -D "$collision_branch" >/dev/null

branch_collision_instance='cleanup-preexisting-branch-a1'
branch_collision_slug="$(UBERDEV_AGENT_INSTANCE_ID="$branch_collision_instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
branch_collision_relative=".claude/worktrees/solve-issue-335-$branch_collision_slug"
branch_collision_branch="worktree-solve-issue-335-$branch_collision_slug"
branch_collision_receipt="$CLEANUP_TMP/runtime/preexisting-branch.owner.json"
git -C "$CLEANUP_TMP/repo" branch "$branch_collision_branch"
if bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$branch_collision_relative" "$branch_collision_branch" "$branch_collision_receipt" >/dev/null 2>&1; then
  fail_msg "pre-existing branch cannot mint cleanup authority" "receipt creation succeeded"
elif git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$branch_collision_branch" \
    && [ ! -e "$CLEANUP_TMP/repo/$branch_collision_relative" ] \
    && [ ! -e "$branch_collision_receipt" ]; then
  pass_msg "pre-existing branch cannot mint cleanup authority"
else
  fail_msg "pre-existing branch remains untouched" "path, branch, or receipt state changed"
fi
git -C "$CLEANUP_TMP/repo" branch -D "$branch_collision_branch" >/dev/null

echo "== Codex receipt creation and exact-SHA add are one transaction =="
transaction_relative='.claude/worktrees/solve-issue-335-transaction-collision'
transaction_branch='worktree-solve-issue-335-transaction-collision'
transaction_target="$CLEANUP_TMP/repo/$transaction_relative"
transaction_barrier="$CLEANUP_TMP/runtime/transaction-collision-barrier"
mkdir -p "$transaction_barrier"
transaction_pids=''
for transaction_actor in a b; do
  (
    : >"$transaction_barrier/ready-$transaction_actor"
    transaction_wait=0
    while [ "$(find "$transaction_barrier" -type f -name 'ready-*' | wc -l | tr -d ' ')" -lt 2 ] \
        && [ "$transaction_wait" -lt 400 ]; do
      sleep 0.01
      transaction_wait=$((transaction_wait + 1))
    done
    set +e
    bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6"' \
      _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_relative" "$transaction_branch" \
      "$CLEANUP_TMP/runtime/transaction-$transaction_actor.owner.json" \
      "$CLEANUP_TMP/runtime/transaction-$transaction_actor.git.log" \
      >"$CLEANUP_TMP/runtime/transaction-$transaction_actor.out" \
      2>"$CLEANUP_TMP/runtime/transaction-$transaction_actor.err"
    printf '%s\n' "$?" >"$CLEANUP_TMP/runtime/transaction-$transaction_actor.rc"
  ) &
  transaction_pids="$transaction_pids $!"
done
for transaction_pid in $transaction_pids; do wait "$transaction_pid" || true; done
transaction_winner=''
transaction_loser=''
transaction_loser_rc=''
for transaction_actor in a b; do
  transaction_rc="$(cat "$CLEANUP_TMP/runtime/transaction-$transaction_actor.rc")"
  if [ "$transaction_rc" -eq 0 ]; then
    transaction_winner="$transaction_actor"
  else
    transaction_loser="$transaction_actor"
    transaction_loser_rc="$transaction_rc"
  fi
done
transaction_collision_errors=''
[ -n "$transaction_winner" ] && [ -n "$transaction_loser" ] \
  || transaction_collision_errors="$transaction_collision_errors winner-loser-classification"
[ "$transaction_loser_rc" = 3 ] \
  || transaction_collision_errors="$transaction_collision_errors loser-rc-$transaction_loser_rc"
transaction_token=''
if [ -n "$transaction_winner" ]; then
  transaction_token="$(python3 -I -B - \
      "$CLEANUP_TMP/runtime/transaction-$transaction_winner.out" <<'PY' 2>/dev/null || true
import json,pathlib,sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert set(value)=={"state","token"} and value["state"]=="active"
print(value["token"],end="")
PY
)"
fi
[ -n "$transaction_token" ] \
  || transaction_collision_errors="$transaction_collision_errors winner-output"
[ -d "$transaction_target" ] \
  || transaction_collision_errors="$transaction_collision_errors winner-worktree"
git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$transaction_branch" \
  || transaction_collision_errors="$transaction_collision_errors winner-branch"
[ -n "$transaction_winner" ] \
  && [ -f "$CLEANUP_TMP/runtime/transaction-$transaction_winner.owner.json" ] \
  || transaction_collision_errors="$transaction_collision_errors winner-receipt"
[ -n "$transaction_loser" ] \
  && [ ! -e "$CLEANUP_TMP/runtime/transaction-$transaction_loser.owner.json" ] \
  || transaction_collision_errors="$transaction_collision_errors loser-authority"
if [ -n "$transaction_token" ]; then
  [ "$(git -C "$transaction_target" rev-parse HEAD 2>/dev/null)" = "$(receipt_start_head "$transaction_token")" ] \
    || transaction_collision_errors="$transaction_collision_errors nonexact-start"
fi
if [ -z "$transaction_collision_errors" ]; then
  pass_msg "two colliding dispatch transactions leave one exact-SHA winner and no loser cleanup authority"
else
  fail_msg "receipt creation and worktree add are one collision-safe metadata transaction" \
    "$transaction_collision_errors a_rc=$(cat "$CLEANUP_TMP/runtime/transaction-a.rc") b_rc=$(cat "$CLEANUP_TMP/runtime/transaction-b.rc")"
fi
if [ -n "$transaction_token" ] && [ -n "$transaction_winner" ]; then
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_relative" "$transaction_branch" \
    "$CLEANUP_TMP/runtime/transaction-$transaction_winner.owner.json" "$transaction_token" \
    || true
fi

transaction_order_relative='.claude/worktrees/solve-issue-335-transaction-order'
transaction_order_branch='worktree-solve-issue-335-transaction-order'
transaction_order_receipt="$CLEANUP_TMP/runtime/transaction-order.owner.json"
transaction_order_log="$CLEANUP_TMP/runtime/transaction-order.events"
transaction_order_start="$(git -C "$CLEANUP_TMP/repo" rev-parse HEAD)"
: >"$transaction_order_log"
set +e
TRANSACTION_ORDER_LOG="$transaction_order_log" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_semaphore_mutex_acquire | sed "1s/_uberdev_semaphore_mutex_acquire/_uberdev_semaphore_mutex_acquire_real/")"
  eval "$(declare -f _uberdev_semaphore_mutex_release | sed "1s/_uberdev_semaphore_mutex_release/_uberdev_semaphore_mutex_release_real/")"
  eval "$(declare -f _uberdev_dispatch_codex_worktree_absent_locked | sed "1s/_uberdev_dispatch_codex_worktree_absent_locked/_uberdev_dispatch_codex_worktree_absent_locked_real/")"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  _uberdev_semaphore_mutex_acquire() { printf "acquire\n" >>"$TRANSACTION_ORDER_LOG"; _uberdev_semaphore_mutex_acquire_real "$@"; }
  _uberdev_semaphore_mutex_release() { printf "release\n" >>"$TRANSACTION_ORDER_LOG"; _uberdev_semaphore_mutex_release_real "$@"; }
  _uberdev_dispatch_codex_worktree_absent_locked() { printf "absence\n" >>"$TRANSACTION_ORDER_LOG"; _uberdev_dispatch_codex_worktree_absent_locked_real "$@"; }
  _uberdev_dispatch_worktree_receipt_helper() {
    [ "$1" != create ] || printf "create\n" >>"$TRANSACTION_ORDER_LOG"
    _uberdev_dispatch_worktree_receipt_helper_real "$@"
  }
  git() {
    if [ "$1" = worktree ] && [ "$2" = add ]; then
      last="${!#}"
      printf "add:%s\n" "$last" >>"$TRANSACTION_ORDER_LOG"
    fi
    command git "$@"
  }
  _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_order_relative" "$transaction_order_branch" \
  "$transaction_order_receipt" "$CLEANUP_TMP/runtime/transaction-order.git.log" \
  >"$CLEANUP_TMP/runtime/transaction-order.out"
transaction_order_rc=$?
set -e
transaction_order_token="$(python3 -I -B - "$CLEANUP_TMP/runtime/transaction-order.out" <<'PY' 2>/dev/null || true
import json,pathlib,sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["state"]=="active"
print(value["token"],end="")
PY
)"
if [ "$transaction_order_rc" -eq 0 ] \
    && [ -n "$transaction_order_token" ] \
    && [ "$(cat "$transaction_order_log")" = \
      "$(printf 'acquire\nabsence\ncreate\nadd:%s\nrelease' "$transaction_order_start")" ]; then
  pass_msg "setup orders acquire, absence proof, receipt create, exact-SHA add, then release"
else
  fail_msg "receipt publication and exact-SHA add share one ordered transaction" \
    "rc=$transaction_order_rc events=$(tr '\n' ';' <"$transaction_order_log")"
fi
if [ -n "$transaction_order_token" ]; then
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_order_relative" "$transaction_order_branch" \
    "$transaction_order_receipt" "$transaction_order_token"
fi

transaction_partial_relative='.claude/worktrees/solve-issue-335-transaction-partial'
transaction_partial_branch='worktree-solve-issue-335-transaction-partial'
transaction_partial_receipt="$CLEANUP_TMP/runtime/transaction-partial.owner.json"
transaction_partial_log="$CLEANUP_TMP/runtime/transaction-partial.events"
: >"$transaction_partial_log"
set +e
TRANSACTION_PARTIAL_LOG="$transaction_partial_log" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_semaphore_mutex_acquire | sed "1s/_uberdev_semaphore_mutex_acquire/_uberdev_semaphore_mutex_acquire_real/")"
  eval "$(declare -f _uberdev_semaphore_mutex_release | sed "1s/_uberdev_semaphore_mutex_release/_uberdev_semaphore_mutex_release_real/")"
  eval "$(declare -f _uberdev_dispatch_codex_worktree_absent_locked | sed "1s/_uberdev_dispatch_codex_worktree_absent_locked/_uberdev_dispatch_codex_worktree_absent_locked_real/")"
  eval "$(declare -f _uberdev_dispatch_cleanup_codex_worktree_locked | sed "1s/_uberdev_dispatch_cleanup_codex_worktree_locked/_uberdev_dispatch_cleanup_codex_worktree_locked_real/")"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  _uberdev_semaphore_mutex_acquire() { printf "acquire\n" >>"$TRANSACTION_PARTIAL_LOG"; _uberdev_semaphore_mutex_acquire_real "$@"; }
  _uberdev_semaphore_mutex_release() { printf "release\n" >>"$TRANSACTION_PARTIAL_LOG"; _uberdev_semaphore_mutex_release_real "$@"; }
  _uberdev_dispatch_codex_worktree_absent_locked() { printf "absence\n" >>"$TRANSACTION_PARTIAL_LOG"; _uberdev_dispatch_codex_worktree_absent_locked_real "$@"; }
  _uberdev_dispatch_cleanup_codex_worktree_locked() { printf "cleanup\n" >>"$TRANSACTION_PARTIAL_LOG"; _uberdev_dispatch_cleanup_codex_worktree_locked_real "$@"; }
  _uberdev_dispatch_worktree_receipt_helper() {
    case "$1" in create|retire) printf "%s\n" "$1" >>"$TRANSACTION_PARTIAL_LOG" ;; esac
    _uberdev_dispatch_worktree_receipt_helper_real "$@"
  }
  git() {
    if [ "$1" = worktree ] && [ "$2" = add ]; then
      printf "add\n" >>"$TRANSACTION_PARTIAL_LOG"
      command git "$@" || return $?
      return 1
    fi
    case "$*" in
      "worktree remove"*) printf "remove\n" >>"$TRANSACTION_PARTIAL_LOG" ;;
      "branch -D"*) printf "branch\n" >>"$TRANSACTION_PARTIAL_LOG" ;;
    esac
    command git "$@"
  }
  _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_partial_relative" "$transaction_partial_branch" \
  "$transaction_partial_receipt" "$CLEANUP_TMP/runtime/transaction-partial.git.log" \
  >"$CLEANUP_TMP/runtime/transaction-partial.out"
transaction_partial_rc=$?
set -e
transaction_partial_token="$(python3 -I -B - "$CLEANUP_TMP/runtime/transaction-partial.out" <<'PY' 2>/dev/null || true
import json,pathlib,sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["state"]=="retired"
print(value["token"],end="")
PY
)"
if [ "$transaction_partial_rc" -eq 1 ] \
    && [ -n "$transaction_partial_token" ] \
    && [ "$(cat "$transaction_partial_log")" = \
      $'acquire\nabsence\ncreate\nadd\ncleanup\nremove\nbranch\nretire\nrelease' ] \
    && [ ! -e "$CLEANUP_TMP/repo/$transaction_partial_relative" ] \
    && ! git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$transaction_partial_branch" \
    && receipt_is_retired "$CLEANUP_TMP/repo" "$transaction_partial_relative" \
      "$transaction_partial_branch" "$transaction_partial_receipt" "$transaction_partial_token"; then
  pass_msg "failed add cleans exact partial W/B and retires P before the single mutex release"
else
  fail_msg "failed add recovery remains inside its receipt-creating transaction" \
    "rc=$transaction_partial_rc events=$(tr '\n' ';' <"$transaction_partial_log")"
fi

transaction_head_relative='.claude/worktrees/solve-issue-335-transaction-head'
transaction_head_branch='worktree-solve-issue-335-transaction-head'
transaction_head_receipt="$CLEANUP_TMP/runtime/transaction-head.owner.json"
transaction_head_start="$(git -C "$CLEANUP_TMP/repo" rev-parse HEAD)"
set +e
MUTABLE_HEAD_REPO="$CLEANUP_TMP/repo" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  _uberdev_dispatch_worktree_receipt_helper() {
    local output rc
    if output="$(_uberdev_dispatch_worktree_receipt_helper_real "$@")"; then rc=0; else rc=$?; fi
    if [ "$1" = create ] && [ "$rc" -eq 0 ]; then
      printf "advanced\n" >"$MUTABLE_HEAD_REPO/transaction-head.txt"
      command git -C "$MUTABLE_HEAD_REPO" add transaction-head.txt
      command git -C "$MUTABLE_HEAD_REPO" commit -qm "advance head during setup"
    fi
    printf "%s\n" "$output"
    return "$rc"
  }
  _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_head_relative" "$transaction_head_branch" \
  "$transaction_head_receipt" "$CLEANUP_TMP/runtime/transaction-head.git.log" \
  >"$CLEANUP_TMP/runtime/transaction-head.out"
transaction_head_rc=$?
set -e
transaction_head_token="$(python3 -I -B - "$CLEANUP_TMP/runtime/transaction-head.out" <<'PY' 2>/dev/null || true
import json,pathlib,sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["state"]=="active"
print(value["token"],end="")
PY
)"
transaction_head_after="$(git -C "$CLEANUP_TMP/repo" rev-parse HEAD)"
if [ "$transaction_head_rc" -eq 0 ] \
    && [ -n "$transaction_head_token" ] \
    && [ "$(receipt_start_head "$transaction_head_token")" = "$transaction_head_start" ] \
    && [ "$transaction_head_after" != "$transaction_head_start" ] \
    && [ "$(git -C "$CLEANUP_TMP/repo/$transaction_head_relative" rev-parse HEAD)" = "$transaction_head_start" ]; then
  pass_msg "worktree add uses the captured receipt SHA even when repository HEAD advances"
else
  fail_msg "mutable HEAD cannot retarget a receipt-authorized worktree add" \
    "rc=$transaction_head_rc start=$transaction_head_start after=$transaction_head_after"
fi
if [ -n "$transaction_head_token" ]; then
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_head_relative" "$transaction_head_branch" \
    "$transaction_head_receipt" "$transaction_head_token"
fi

transaction_preexisting_relative='.claude/worktrees/solve-issue-335-transaction-preexisting'
transaction_preexisting_branch='worktree-solve-issue-335-transaction-preexisting'
transaction_preexisting_receipt="$CLEANUP_TMP/runtime/transaction-preexisting.owner.json"
transaction_preexisting_helper_log="$CLEANUP_TMP/runtime/transaction-preexisting.helper"
: >"$transaction_preexisting_helper_log"
git -C "$CLEANUP_TMP/repo" worktree add -q "$transaction_preexisting_relative" \
  -b "$transaction_preexisting_branch"
set +e
TRANSACTION_PREEXISTING_HELPER_LOG="$transaction_preexisting_helper_log" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  _uberdev_dispatch_worktree_receipt_helper() {
    printf "%s\n" "$1" >>"$TRANSACTION_PREEXISTING_HELPER_LOG"
    _uberdev_dispatch_worktree_receipt_helper_real "$@"
  }
  _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6" >/dev/null
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_preexisting_relative" \
  "$transaction_preexisting_branch" "$transaction_preexisting_receipt" \
  "$CLEANUP_TMP/runtime/transaction-preexisting.git.log"
transaction_preexisting_rc=$?
set -e
if [ "$transaction_preexisting_rc" -eq 3 ] \
    && [ ! -s "$transaction_preexisting_helper_log" ] \
    && [ -d "$CLEANUP_TMP/repo/$transaction_preexisting_relative" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$transaction_preexisting_branch" \
    && [ ! -e "$transaction_preexisting_receipt" ]; then
  pass_msg "preexisting collision is rejected under lock before receipt publication"
else
  fail_msg "absence proof precedes every receipt create" \
    "rc=$transaction_preexisting_rc helper=$(tr '\n' ';' <"$transaction_preexisting_helper_log")"
fi
git -C "$CLEANUP_TMP/repo" worktree remove --force "$transaction_preexisting_relative"
git -C "$CLEANUP_TMP/repo" branch -D "$transaction_preexisting_branch" >/dev/null

transaction_unconfirmed_relative='.claude/worktrees/solve-issue-335-transaction-unconfirmed'
transaction_unconfirmed_branch='worktree-solve-issue-335-transaction-unconfirmed'
transaction_unconfirmed_receipt="$CLEANUP_TMP/runtime/transaction-unconfirmed.owner.json"
transaction_unconfirmed_attempts="$CLEANUP_TMP/runtime/transaction-unconfirmed.attempts"
transaction_unconfirmed_old_token_file="$CLEANUP_TMP/runtime/transaction-unconfirmed.old-token"
: >"$transaction_unconfirmed_attempts"
set +e
TRANSACTION_UNCONFIRMED_ATTEMPTS="$transaction_unconfirmed_attempts" \
  TRANSACTION_UNCONFIRMED_OLD_TOKEN="$transaction_unconfirmed_old_token_file" bash -c '
    . "$1"
    eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
    _uberdev_dispatch_worktree_receipt_helper() {
      local output rc count
      if [ "$1" != create ]; then
        _uberdev_dispatch_worktree_receipt_helper_real "$@"
        return $?
      fi
      printf "attempt\n" >>"$TRANSACTION_UNCONFIRMED_ATTEMPTS"
      count="$(wc -l <"$TRANSACTION_UNCONFIRMED_ATTEMPTS" | tr -d " ")"
      if output="$(_uberdev_dispatch_worktree_receipt_helper_real "$@")"; then rc=0; else rc=$?; fi
      if [ "$count" -eq 1 ] && [ "$rc" -eq 0 ]; then
        old_token="$(_uberdev_dispatch_python -I -B -c \
          "import json,sys; print(json.loads(sys.argv[1])[\"token\"],end=\"\")" "$output")" || return 3
        printf "%s" "$old_token" >"$TRANSACTION_UNCONFIRMED_OLD_TOKEN"
        _uberdev_dispatch_python -I -B - "$output" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
value["state"]="active_unconfirmed"
print(json.dumps(value,separators=(",",":"),sort_keys=True))
PY
        return 2
      fi
      printf "%s\n" "$output"
      return "$rc"
    }
    _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6"
  ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_unconfirmed_relative" \
    "$transaction_unconfirmed_branch" "$transaction_unconfirmed_receipt" \
    "$CLEANUP_TMP/runtime/transaction-unconfirmed.git.log" \
    >"$CLEANUP_TMP/runtime/transaction-unconfirmed.out"
transaction_unconfirmed_rc=$?
set -e
transaction_unconfirmed_token="$(python3 -I -B - "$CLEANUP_TMP/runtime/transaction-unconfirmed.out" <<'PY' 2>/dev/null || true
import json,pathlib,sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text()); assert value["state"]=="active"
print(value["token"],end="")
PY
)"
transaction_unconfirmed_old_token="$(cat "$transaction_unconfirmed_old_token_file" 2>/dev/null || true)"
transaction_unconfirmed_old_tombstone=''
[ -z "$transaction_unconfirmed_old_token" ] \
  || transaction_unconfirmed_old_tombstone="$(receipt_tombstone "$transaction_unconfirmed_receipt" "$transaction_unconfirmed_old_token")"
if [ "$transaction_unconfirmed_rc" -eq 0 ] \
    && [ "$(wc -l <"$transaction_unconfirmed_attempts" | tr -d ' ')" -eq 2 ] \
    && [ -n "$transaction_unconfirmed_token" ] \
    && [ -n "$transaction_unconfirmed_old_token" ] \
    && [ "$transaction_unconfirmed_token" != "$transaction_unconfirmed_old_token" ] \
    && [ -f "$transaction_unconfirmed_old_tombstone" ] \
    && [ -d "$CLEANUP_TMP/repo/$transaction_unconfirmed_relative" ]; then
  pass_msg "post-publish rc2 is inspected and retired before a bounded fresh create retry"
else
  fail_msg "active_unconfirmed create evidence is never blindly retried" \
    "rc=$transaction_unconfirmed_rc attempts=$(cat "$transaction_unconfirmed_attempts")"
fi
if [ -n "$transaction_unconfirmed_token" ]; then
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_unconfirmed_relative" \
    "$transaction_unconfirmed_branch" "$transaction_unconfirmed_receipt" "$transaction_unconfirmed_token"
fi

cleanup_failures=''
for terminal_state in completed failed timed_out cancelled; do
  instance="cleanup-$terminal_state-a1"
  slug="$(UBERDEV_AGENT_INSTANCE_ID="$instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
  relative=".claude/worktrees/solve-issue-335-$slug"
  branch="worktree-solve-issue-335-$slug"
  receipt="$CLEANUP_TMP/runtime/$terminal_state.owner.json"
  token="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$relative" "$branch" "$receipt")" || {
      cleanup_failures="$cleanup_failures receipt-create-$terminal_state"; continue;
    }
  git -C "$CLEANUP_TMP/repo" worktree add -q "$relative" -b "$branch" || {
    cleanup_failures="$cleanup_failures worktree-add-$terminal_state"; continue;
  }
  result="$CLEANUP_TMP/runtime/$terminal_state-result.md"
  printf 'preserved %s result\n' "$terminal_state" > "$result"
  if ! bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" "$7"' \
      _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$relative" "$branch" "$receipt" "$token" "$terminal_state"; then
    cleanup_failures="$cleanup_failures cleanup-$terminal_state"
  fi
  [ ! -e "$CLEANUP_TMP/repo/$relative" ] || cleanup_failures="$cleanup_failures path-$terminal_state"
  git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$branch" \
    && cleanup_failures="$cleanup_failures branch-$terminal_state"
  [ ! -e "$receipt" ] || cleanup_failures="$cleanup_failures receipt-$terminal_state"
  receipt_is_retired "$CLEANUP_TMP/repo" "$relative" "$branch" "$receipt" "$token" \
    || cleanup_failures="$cleanup_failures tombstone-$terminal_state"
  grep -q "preserved $terminal_state result" "$result" \
    || cleanup_failures="$cleanup_failures result-$terminal_state"
done
if [ -z "$cleanup_failures" ]; then
  pass_msg "completed/failed/timed_out/cancelled cleanup removes only the child worktree+branch and preserves results"
else
  fail_msg "completed/failed/timed_out/cancelled cleanup removes only the child worktree+branch and preserves results" "$cleanup_failures"
fi

echo "== Worktree receipt retirement state machine is fail-closed =="
create_contract_errors=''
for create_mode in malformed unexpected rc2 rc3; do
  create_relative=".claude/worktrees/solve-issue-335-create-$create_mode"
  create_branch="worktree-solve-issue-335-create-$create_mode"
  create_receipt="$CLEANUP_TMP/runtime/create-$create_mode.owner.json"
  set +e
  CREATE_MODE="$create_mode" bash -c '
    . "$1"
    _uberdev_dispatch_worktree_receipt_helper() {
      case "$CREATE_MODE" in
        malformed) printf "not-json\n"; return 0 ;;
        unexpected) printf "{\"state\":\"retired\"}\n"; return 0 ;;
        rc2) return 2 ;;
        rc3) return 3 ;;
      esac
    }
    _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5" >/dev/null
  ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$create_relative" "$create_branch" "$create_receipt"
  create_rc=$?
  set -e
  case "$create_mode:$create_rc" in malformed:3|unexpected:3|rc2:2|rc3:3) ;; *)
    create_contract_errors="$create_contract_errors $create_mode-rc-$create_rc" ;;
  esac
  [ ! -e "$CLEANUP_TMP/repo/$create_relative" ] \
    || create_contract_errors="$create_contract_errors $create_mode-path"
  git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$create_branch" \
    && create_contract_errors="$create_contract_errors $create_mode-branch"
done
if [ -z "$create_contract_errors" ]; then
  pass_msg "receipt create structurally rejects malformed/unexpected JSON and preserves helper rc2/rc3"
else
  fail_msg "receipt create output and rc contract is strict" "$create_contract_errors"
fi

transaction_create_errors=''
for transaction_create_mode in rc2 rc3; do
  transaction_create_relative=".claude/worktrees/solve-issue-335-transaction-create-$transaction_create_mode"
  transaction_create_branch="worktree-solve-issue-335-transaction-create-$transaction_create_mode"
  transaction_create_receipt="$CLEANUP_TMP/runtime/transaction-create-$transaction_create_mode.owner.json"
  transaction_create_attempts="$CLEANUP_TMP/runtime/transaction-create-$transaction_create_mode.attempts"
  : >"$transaction_create_attempts"
  set +e
  TRANSACTION_CREATE_MODE="$transaction_create_mode" \
    TRANSACTION_CREATE_ATTEMPTS="$transaction_create_attempts" bash -c '
      . "$1"
      _uberdev_dispatch_worktree_receipt_helper() {
        [ "$1" != create ] || printf "attempt\n" >>"$TRANSACTION_CREATE_ATTEMPTS"
        [ "$1" != create ] || return "${TRANSACTION_CREATE_MODE#rc}"
        return 3
      }
      _uberdev_dispatch_create_codex_worktree "$2" "$3" "$4" "$5" "$6" >/dev/null
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$transaction_create_relative" \
      "$transaction_create_branch" "$transaction_create_receipt" \
      "$CLEANUP_TMP/runtime/transaction-create-$transaction_create_mode.git.log"
  transaction_create_rc=$?
  set -e
  transaction_create_expected_attempts=3
  [ "$transaction_create_mode" != rc3 ] || transaction_create_expected_attempts=1
  [ "$transaction_create_rc" -eq "${transaction_create_mode#rc}" ] \
    || transaction_create_errors="$transaction_create_errors $transaction_create_mode-rc-$transaction_create_rc"
  [ "$(wc -l <"$transaction_create_attempts" | tr -d ' ')" -eq "$transaction_create_expected_attempts" ] \
    || transaction_create_errors="$transaction_create_errors $transaction_create_mode-attempts"
  [ ! -e "$CLEANUP_TMP/repo/$transaction_create_relative" ] \
    && [ ! -e "$transaction_create_receipt" ] \
    || transaction_create_errors="$transaction_create_errors $transaction_create_mode-artifacts"
done
if [ -z "$transaction_create_errors" ]; then
  pass_msg "receipt create retries rc2 boundedly while internal rc3 is terminal after one attempt"
else
  fail_msg "receipt create rc2/rc3 retry classification is exact" "$transaction_create_errors"
fi

make_contract_fixture() {
  local label="$1" add_worktree="${2:-1}"
  CONTRACT_RELATIVE=".claude/worktrees/solve-issue-335-contract-$label"
  CONTRACT_BRANCH="worktree-solve-issue-335-contract-$label"
  CONTRACT_RECEIPT="$CLEANUP_TMP/runtime/contract-$label.owner.json"
  CONTRACT_TOKEN="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT")"
  if [ "$add_worktree" -eq 1 ]; then
    git -C "$CLEANUP_TMP/repo" worktree add -q "$CONTRACT_RELATIVE" -b "$CONTRACT_BRANCH"
  fi
}

cleanup_with_mutator_log() {
  local expected_rc="$1" mode="$2" log="$3" rc
  shift 3
  set +e
  CLEANUP_HELPER_MODE="$mode" CLEANUP_MUTATOR_LOG="$log" bash -c '
    . "$1"
    eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
    git() {
      case "$*" in *"worktree remove"*|*"branch -D"*) printf "mutator:%s\n" "$*" >>"$CLEANUP_MUTATOR_LOG" ;; esac
      command git "$@"
    }
    _uberdev_dispatch_worktree_receipt_helper() {
      if [ "$1" = inspect ]; then
        case "$CLEANUP_HELPER_MODE" in
          malformed) printf "not-json\n"; return 0 ;;
          rc2) return 2 ;;
          rc3) return 3 ;;
        esac
      fi
      _uberdev_dispatch_worktree_receipt_helper_real "$@"
    }
    _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
  ' _ "$DISPATCH_LIB" "$@"
  rc=$?
  set -e
  [ "$rc" -eq "$expected_rc" ]
}

inspect_contract_errors=''
for inspect_mode in malformed rc2 rc3; do
  make_contract_fixture "inspect-$inspect_mode"
  inspect_log="$CLEANUP_TMP/runtime/inspect-$inspect_mode.mutators"
  : >"$inspect_log"
  inspect_expected=3; [ "$inspect_mode" != rc2 ] || inspect_expected=2
  cleanup_with_mutator_log "$inspect_expected" "$inspect_mode" "$inspect_log" \
      "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
    || inspect_contract_errors="$inspect_contract_errors $inspect_mode-rc"
  [ ! -s "$inspect_log" ] || inspect_contract_errors="$inspect_contract_errors $inspect_mode-mutated"
  [ -d "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" ] && [ -f "$CONTRACT_RECEIPT" ] \
    || inspect_contract_errors="$inspect_contract_errors $inspect_mode-evidence"
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
    "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
done
if [ -z "$inspect_contract_errors" ]; then
  pass_msg "receipt inspect malformed/rc2/rc3 failures preserve authority with zero Git mutators"
else
  fail_msg "receipt inspect failures are classified before mutation" "$inspect_contract_errors"
fi

terminal_authority_errors=''
for authority_state in both neither wrong-token; do
  make_contract_fixture "authority-$authority_state"
  authority_tombstone="$(receipt_tombstone "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN")"
  authority_saved="$CONTRACT_RECEIPT.saved"
  authority_token="$CONTRACT_TOKEN"
  case "$authority_state" in
    both) cp "$CONTRACT_RECEIPT" "$authority_tombstone" ;;
    neither) mv "$CONTRACT_RECEIPT" "$authority_saved" ;;
    wrong-token) authority_token="00000000000000000000000000000000:$(receipt_start_head "$CONTRACT_TOKEN")" ;;
  esac
  authority_log="$CLEANUP_TMP/runtime/authority-$authority_state.mutators"
  : >"$authority_log"
  cleanup_with_mutator_log 3 actual "$authority_log" \
      "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT" "$authority_token" \
    || terminal_authority_errors="$terminal_authority_errors $authority_state-rc"
  [ ! -s "$authority_log" ] || terminal_authority_errors="$terminal_authority_errors $authority_state-mutated"
  [ -d "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" ] \
    || terminal_authority_errors="$terminal_authority_errors $authority_state-path"
  case "$authority_state" in
    both) rm -f "$authority_tombstone" ;;
    neither) mv "$authority_saved" "$CONTRACT_RECEIPT" ;;
  esac
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
    "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
done
if [ -z "$terminal_authority_errors" ]; then
  pass_msg "both/neither/wrong-identity authorities fail terminally before Git mutation"
else
  fail_msg "ambiguous or wrong receipt authority is terminal" "$terminal_authority_errors"
fi

crash_state_errors=''
for crash_state in branch-only empty registry-only; do
  crash_add=0; [ "$crash_state" != registry-only ] || crash_add=1
  make_contract_fixture "crash-$crash_state" "$crash_add"
  if [ "$crash_state" = branch-only ]; then
    git -C "$CLEANUP_TMP/repo" branch "$CONTRACT_BRANCH"
  elif [ "$crash_state" = registry-only ]; then
    mv "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" \
      "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE.missing-at-cleanup"
  fi
  if ! bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" setup_failed' \
      _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
      "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"; then
    crash_state_errors="$crash_state_errors $crash_state-cleanup"
  fi
  [ ! -e "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" ] \
    || crash_state_errors="$crash_state_errors $crash_state-path"
  git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$CONTRACT_BRANCH" \
    && crash_state_errors="$crash_state_errors $crash_state-branch"
  receipt_is_retired "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
    "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
    || crash_state_errors="$crash_state_errors $crash_state-tombstone"
done
if [ -z "$crash_state_errors" ]; then
  pass_msg "active P recovers path-absent registry/branch, branch-only, and fully-absent crash states"
else
  fail_msg "active receipt crash-state recovery is complete" "$crash_state_errors"
fi

make_contract_fixture retired-retry
bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
  _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
  "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
retired_log="$CLEANUP_TMP/runtime/retired-retry.mutators"
: >"$retired_log"
retired_violation_log="$CLEANUP_TMP/runtime/retired-retry.violations"
: >"$retired_violation_log"
set +e
RETIRED_GIT_LOG="$retired_log" RETIRED_GIT_VIOLATIONS="$retired_violation_log" bash -c '
  . "$1"
  retired_expected_repo="$2"; retired_expected_branch="$4"
  git() {
    printf "%s\n" "$*" >>"$RETIRED_GIT_LOG"
    case "$*" in
      "-C $retired_expected_repo rev-parse --git-common-dir"|\
      "worktree list --porcelain"|\
      "-C $retired_expected_repo show-ref --verify --quiet refs/heads/$retired_expected_branch") command git "$@" ;;
      *) printf "%s\n" "$*" >>"$RETIRED_GIT_VIOLATIONS"; return 97 ;;
    esac
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
  "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
retired_retry_rc=$?
set -e
if [ "$retired_retry_rc" -eq 0 ] \
    && [ ! -s "$retired_violation_log" ] \
    && [ "$(wc -l <"$retired_log" | tr -d ' ')" -eq 3 ] \
    && receipt_is_retired "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
      "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"; then
  pass_msg "T-only cleanup retry uses only the explicit read-only Git allowlist"
else
  fail_msg "T-only cleanup retry is an idempotent read-only recovery" \
    "rc=$retired_retry_rc git=$(tr '\n' ';' <"$retired_log") violations=$(tr '\n' ';' <"$retired_violation_log")"
fi

retired_config_log="$CLEANUP_TMP/runtime/retired-retry-config.git"
retired_config_violations="$CLEANUP_TMP/runtime/retired-retry-config.violations"
: >"$retired_config_log"; : >"$retired_config_violations"
set +e
RETIRED_GIT_LOG="$retired_config_log" RETIRED_GIT_VIOLATIONS="$retired_config_violations" bash -c '
  . "$1"
  retired_expected_repo="$2"; retired_expected_branch="$4"
  git() {
    printf "%s\n" "$*" >>"$RETIRED_GIT_LOG"
    case "$*" in
      "-C $retired_expected_repo rev-parse --git-common-dir"|\
      "worktree list --porcelain"|\
      "-C $retired_expected_repo show-ref --verify --quiet refs/heads/$retired_expected_branch") command git "$@" ;;
      *) printf "%s\n" "$*" >>"$RETIRED_GIT_VIOLATIONS"; return 97 ;;
    esac
  }
  eval "$(declare -f _uberdev_dispatch_cleanup_codex_worktree_locked | sed "1s/_uberdev_dispatch_cleanup_codex_worktree_locked/_uberdev_dispatch_cleanup_codex_worktree_locked_real/")"
  _uberdev_dispatch_cleanup_codex_worktree_locked() {
    git -C "$1" config uberdev.retired-probe touched || return $?
    _uberdev_dispatch_cleanup_codex_worktree_locked_real "$@"
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
  "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
retired_config_rc=$?
set -e
if [ "$retired_config_rc" -eq 97 ] \
    && grep -Fxq -- "-C $CLEANUP_TMP/repo config uberdev.retired-probe touched" "$retired_config_violations" \
    && ! git -C "$CLEANUP_TMP/repo" config --get uberdev.retired-probe >/dev/null; then
  pass_msg "T-only Git allowlist rejects and records even a harmless config mutation"
else
  fail_msg "T-only Git allowlist catches every non-read-only Git invocation" \
    "rc=$retired_config_rc violations=$(tr '\n' ';' <"$retired_config_violations")"
fi

retired_conflict_errors=''
mkdir -p "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE"
: >"$retired_log"
cleanup_with_mutator_log 3 actual "$retired_log" \
    "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
  || retired_conflict_errors="$retired_conflict_errors path-rc"
[ -d "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" ] && [ ! -s "$retired_log" ] \
  || retired_conflict_errors="$retired_conflict_errors path-preservation"
rmdir "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE"
git -C "$CLEANUP_TMP/repo" branch "$CONTRACT_BRANCH"
: >"$retired_log"
cleanup_with_mutator_log 3 actual "$retired_log" \
    "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
  || retired_conflict_errors="$retired_conflict_errors branch-rc"
git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$CONTRACT_BRANCH" \
  && [ ! -s "$retired_log" ] || retired_conflict_errors="$retired_conflict_errors branch-preservation"
git -C "$CLEANUP_TMP/repo" branch -D "$CONTRACT_BRANCH" >/dev/null
git -C "$CLEANUP_TMP/repo" worktree add -q "$CONTRACT_RELATIVE" -b "$CONTRACT_BRANCH"
mv "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" \
  "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE.registry-conflict"
: >"$retired_log"
cleanup_with_mutator_log 3 actual "$retired_log" \
    "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
  || retired_conflict_errors="$retired_conflict_errors registry-rc"
contract_registry_target="$(python3 -I -B -c \
  'import os,sys; print(os.path.abspath(os.path.join(os.path.realpath(sys.argv[1]),*sys.argv[2].split("/"))),end="")' \
  "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE")"
git -C "$CLEANUP_TMP/repo" worktree list --porcelain \
  | grep -Fqx "worktree $contract_registry_target" \
  && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$CONTRACT_BRANCH" \
  && [ ! -s "$retired_log" ] || retired_conflict_errors="$retired_conflict_errors registry-preservation"
git -C "$CLEANUP_TMP/repo" worktree remove --force "$CONTRACT_RELATIVE"
git -C "$CLEANUP_TMP/repo" branch -D "$CONTRACT_BRANCH" >/dev/null
if [ -z "$retired_conflict_errors" ]; then
  pass_msg "retired authority rejects resurrected path/registry/branch read-only and preserves conflicts"
else
  fail_msg "retired-state conflict verification never mutates" "$retired_conflict_errors"
fi

make_contract_fixture ordering
ordering_log="$CLEANUP_TMP/runtime/retirement-order.log"
: >"$ordering_log"
if ORDERING_LOG="$ordering_log" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  git() {
    case "$*" in *"worktree remove"*) printf "remove\n" >>"$ORDERING_LOG" ;; *"branch -D"*) printf "branch\n" >>"$ORDERING_LOG" ;; esac
    command git "$@"
  }
  eval "$(declare -f _uberdev_semaphore_mutex_acquire | sed "1s/_uberdev_semaphore_mutex_acquire/_uberdev_semaphore_mutex_acquire_real/")"
  eval "$(declare -f _uberdev_semaphore_mutex_release | sed "1s/_uberdev_semaphore_mutex_release/_uberdev_semaphore_mutex_release_real/")"
  _uberdev_semaphore_mutex_acquire() { printf "acquire\n" >>"$ORDERING_LOG"; _uberdev_semaphore_mutex_acquire_real "$@"; }
  _uberdev_semaphore_mutex_release() { printf "release\n" >>"$ORDERING_LOG"; _uberdev_semaphore_mutex_release_real "$@"; }
  _uberdev_dispatch_worktree_receipt_helper() {
    [ "$1" != inspect ] || printf "inspect\n" >>"$ORDERING_LOG"
    [ "$1" != retire ] || printf "retire\n" >>"$ORDERING_LOG"
    _uberdev_dispatch_worktree_receipt_helper_real "$@"
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
    "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN" \
    && [ "$(cat "$ordering_log")" = $'acquire\ninspect\nremove\nbranch\nretire\nrelease' ]; then
  pass_msg "cleanup orders mutex acquire, inspect, exact worktree/branch removal, P-to-T retirement, then release"
else
  fail_msg "receipt retirement is inside the Git metadata transaction" "$(tr '\n' ';' <"$ordering_log")"
fi

make_contract_fixture foreign-public
foreign_token_file="$CLEANUP_TMP/runtime/foreign-public.token.json"
if FOREIGN_TOKEN_FILE="$foreign_token_file" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_worktree_receipt_helper | sed "1s/_uberdev_dispatch_worktree_receipt_helper/_uberdev_dispatch_worktree_receipt_helper_real/")"
  _uberdev_dispatch_worktree_receipt_helper() {
    if [ "$1" = retire ]; then
      retired="$(_uberdev_dispatch_worktree_receipt_helper_real "$@")" || return $?
      [ "$retired" = "{\"state\":\"retired\"}" ] || return 3
      shift
      repo=""; relative=""; branch=""; receipt=""; start=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --repo) repo="$2"; shift 2 ;; --relative) relative="$2"; shift 2 ;;
          --branch) branch="$2"; shift 2 ;; --receipt) receipt="$2"; shift 2 ;;
          --start-head) start="$2"; shift 2 ;; --token) shift 2 ;; *) return 3 ;;
        esac
      done
      _uberdev_dispatch_worktree_receipt_helper_real create \
        --repo "$repo" --relative "$relative" --branch "$branch" \
        --receipt "$receipt" --start-head "$start" >"$FOREIGN_TOKEN_FILE" || return $?
      printf "{\"state\":\"retired\"}\n"
      return 0
    fi
    _uberdev_dispatch_worktree_receipt_helper_real "$@"
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
  "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"; then
  foreign_token="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"],end="")' "$foreign_token_file")"
  foreign_old_log="$CLEANUP_TMP/runtime/foreign-public-old.git"
  foreign_old_violations="$CLEANUP_TMP/runtime/foreign-public-old.violations"
  : >"$foreign_old_log"; : >"$foreign_old_violations"
  set +e
  RETIRED_GIT_LOG="$foreign_old_log" RETIRED_GIT_VIOLATIONS="$foreign_old_violations" bash -c '
    . "$1"
    retired_expected_repo="$2"; retired_expected_branch="$4"
    git() {
      printf "%s\n" "$*" >>"$RETIRED_GIT_LOG"
      case "$*" in
        "-C $retired_expected_repo rev-parse --git-common-dir"|\
        "worktree list --porcelain"|\
        "-C $retired_expected_repo show-ref --verify --quiet refs/heads/$retired_expected_branch") command git "$@" ;;
        *) printf "%s\n" "$*" >>"$RETIRED_GIT_VIOLATIONS"; return 97 ;;
      esac
    }
    _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
  ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
    "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
  foreign_old_rc=$?
  set -e
  if [ "$foreign_old_rc" -eq 0 ] \
      && [ ! -s "$foreign_old_violations" ] \
      && [ "$(wc -l <"$foreign_old_log" | tr -d ' ')" -eq 3 ] \
      && [ -f "$CONTRACT_RECEIPT" ]; then
    git -C "$CLEANUP_TMP/repo" worktree add -q "$CONTRACT_RELATIVE" \
      -b "$CONTRACT_BRANCH" "$(receipt_start_head "$foreign_token")"
    foreign_live_log="$CLEANUP_TMP/runtime/foreign-public-live.git"
    foreign_live_violations="$CLEANUP_TMP/runtime/foreign-public-live.violations"
    : >"$foreign_live_log"; : >"$foreign_live_violations"
    set +e
    RETIRED_GIT_LOG="$foreign_live_log" RETIRED_GIT_VIOLATIONS="$foreign_live_violations" bash -c '
      . "$1"
      retired_expected_repo="$2"; retired_expected_branch="$4"
      git() {
        printf "%s\n" "$*" >>"$RETIRED_GIT_LOG"
        case "$*" in
          "-C $retired_expected_repo rev-parse --git-common-dir"|\
          "worktree list --porcelain"|\
          "-C $retired_expected_repo show-ref --verify --quiet refs/heads/$retired_expected_branch") command git "$@" ;;
          *) printf "%s\n" "$*" >>"$RETIRED_GIT_VIOLATIONS"; return 97 ;;
        esac
      }
      _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
      "$CONTRACT_RECEIPT" "$CONTRACT_TOKEN"
    foreign_live_old_rc=$?
    set -e
    if [ "$foreign_live_old_rc" -eq 3 ] \
        && [ ! -s "$foreign_live_violations" ] \
        && [ -d "$CLEANUP_TMP/repo/$CONTRACT_RELATIVE" ] \
        && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$CONTRACT_BRANCH" \
        && [ -f "$CONTRACT_RECEIPT" ] \
        && bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
          _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
          "$CONTRACT_RECEIPT" "$foreign_token" \
        && receipt_is_retired "$CLEANUP_TMP/repo" "$CONTRACT_RELATIVE" "$CONTRACT_BRANCH" \
          "$CONTRACT_RECEIPT" "$foreign_token"; then
      pass_msg "T_A dominates P_B only before B adds; live B is preserved and later retires independently"
    else
      fail_msg "old A retry cannot mutate a newer live B generation" \
        "old_rc=$foreign_live_old_rc violations=$(tr '\n' ';' <"$foreign_live_violations")"
    fi
  else
    fail_msg "T_A retry with canonical P_B and no W/B is Git-read-only and leaves P_B" \
      "rc=$foreign_old_rc violations=$(tr '\n' ';' <"$foreign_old_violations")"
  fi
else
  fail_msg "A retirement permits foreign public receipt publication without pathname unlink"
fi

dirty_slug="$(UBERDEV_AGENT_INSTANCE_ID=cleanup-dirty-a1 bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
dirty_relative=".claude/worktrees/solve-issue-335-$dirty_slug"
dirty_branch="worktree-solve-issue-335-$dirty_slug"
dirty_receipt="$CLEANUP_TMP/runtime/dirty.owner.json"
dirty_token="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
  _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$dirty_relative" "$dirty_branch" "$dirty_receipt")"
git -C "$CLEANUP_TMP/repo" worktree add -q "$dirty_relative" -b "$dirty_branch"
printf 'dirty tracked change\n' > "$CLEANUP_TMP/repo/$dirty_relative/base.txt"
if bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$dirty_relative" "$dirty_branch" "$dirty_receipt" "$dirty_token"; then
  fail_msg "successful dirty child is preserved fail-closed" "cleanup silently discarded dirty worktree"
elif [ -d "$CLEANUP_TMP/repo/$dirty_relative" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$dirty_branch" \
    && [ -f "$dirty_receipt" ]; then
  pass_msg "successful dirty child is preserved fail-closed"
else
  fail_msg "successful dirty child is preserved fail-closed" "worktree, branch, or ownership receipt was lost"
fi
git -C "$CLEANUP_TMP/repo" worktree remove --force "$dirty_relative"
git -C "$CLEANUP_TMP/repo" branch -D "$dirty_branch" >/dev/null
retire_preserved_fixture "$CLEANUP_TMP/repo" "$dirty_relative" "$dirty_branch" \
  "$dirty_receipt" "$dirty_token"

committed_slug="$(UBERDEV_AGENT_INSTANCE_ID=cleanup-committed-a1 bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
committed_relative=".claude/worktrees/solve-issue-335-$committed_slug"
committed_branch="worktree-solve-issue-335-$committed_slug"
committed_receipt="$CLEANUP_TMP/runtime/committed.owner.json"
committed_token="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
  _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$committed_relative" "$committed_branch" "$committed_receipt")"
git -C "$CLEANUP_TMP/repo" worktree add -q "$committed_relative" -b "$committed_branch"
printf 'committed child change\n' > "$CLEANUP_TMP/repo/$committed_relative/child.txt"
git -C "$CLEANUP_TMP/repo/$committed_relative" add child.txt
git -C "$CLEANUP_TMP/repo/$committed_relative" commit -qm 'test: preserve committed child'
if bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$committed_relative" "$committed_branch" "$committed_receipt" "$committed_token"; then
  fail_msg "clean committed child is preserved fail-closed" "cleanup silently discarded the child commit"
elif [ -d "$CLEANUP_TMP/repo/$committed_relative" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$committed_branch" \
    && [ -f "$committed_receipt" ]; then
  pass_msg "clean committed child is preserved fail-closed"
else
  fail_msg "clean committed child is preserved fail-closed" "worktree, branch, or ownership receipt was lost"
fi
git -C "$CLEANUP_TMP/repo" worktree remove --force "$committed_relative"
git -C "$CLEANUP_TMP/repo" branch -D "$committed_branch" >/dev/null
retire_preserved_fixture "$CLEANUP_TMP/repo" "$committed_relative" "$committed_branch" \
  "$committed_receipt" "$committed_token"

mkdir -p "$CLEANUP_TMP/bin"
REAL_CLEANUP_GIT="$(command -v git)"
cat > "$CLEANUP_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FAIL_GIT_PROBE:-}" ]; then
    exit 2
  fi
done
exec "$REAL_CLEANUP_GIT" "$@"
SH
chmod +x "$CLEANUP_TMP/bin/git"
for failed_probe in status show-ref; do
  probe_slug="$(UBERDEV_AGENT_INSTANCE_ID="cleanup-probe-$failed_probe-a1" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
  probe_relative=".claude/worktrees/solve-issue-335-$probe_slug"
  probe_branch="worktree-solve-issue-335-$probe_slug"
  probe_receipt="$CLEANUP_TMP/runtime/probe-$failed_probe.owner.json"
  probe_token="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$probe_relative" "$probe_branch" "$probe_receipt")"
  git -C "$CLEANUP_TMP/repo" worktree add -q "$probe_relative" -b "$probe_branch"
  if PATH="$CLEANUP_TMP/bin:$PATH" REAL_CLEANUP_GIT="$REAL_CLEANUP_GIT" FAIL_GIT_PROBE="$failed_probe" \
      bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
        _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$probe_relative" "$probe_branch" "$probe_receipt" "$probe_token"; then
    fail_msg "failed git $failed_probe probe preserves cleanup evidence" "cleanup returned success"
  elif [ -d "$CLEANUP_TMP/repo/$probe_relative" ] \
      && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$probe_branch" \
      && [ -f "$probe_receipt" ]; then
    pass_msg "failed git $failed_probe probe preserves cleanup evidence"
  else
    fail_msg "failed git $failed_probe probe preserves cleanup evidence" "worktree, branch, or ownership receipt was lost"
  fi
  git -C "$CLEANUP_TMP/repo" worktree remove --force "$probe_relative"
  git -C "$CLEANUP_TMP/repo" branch -D "$probe_branch" >/dev/null
  retire_preserved_fixture "$CLEANUP_TMP/repo" "$probe_relative" "$probe_branch" \
    "$probe_receipt" "$probe_token"
done

make_mutex_cleanup_fixture() {
  local label="$1"
  MUTEX_SLUG="$(UBERDEV_AGENT_INSTANCE_ID="cleanup-mutex-$label-a1" bash -c \
    '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
  MUTEX_RELATIVE=".claude/worktrees/solve-issue-335-$MUTEX_SLUG"
  MUTEX_BRANCH="worktree-solve-issue-335-$MUTEX_SLUG"
  MUTEX_RECEIPT="$CLEANUP_TMP/runtime/mutex-$label.owner.json"
  MUTEX_TOKEN="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT")"
  git -C "$CLEANUP_TMP/repo" worktree add -q "$MUTEX_RELATIVE" -b "$MUTEX_BRANCH"
}

retry_mutex_cleanup() {
  UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3 bash -c \
    '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN"
}

make_mutex_cleanup_fixture acquire-failure
set +e
bash -c '
  . "$1"
  _uberdev_semaphore_mutex_acquire() { return 75; }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN"
MUTEX_ACQUIRE_RC=$?
set -e
if [ "$MUTEX_ACQUIRE_RC" -eq 75 ] \
    && [ -d "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$MUTEX_BRANCH" \
    && [ -f "$MUTEX_RECEIPT" ]; then
  pass_msg "git metadata mutex acquisition failure preserves exact cleanup evidence"
else
  fail_msg "git metadata mutex acquisition failure preserves exact cleanup evidence" "rc=$MUTEX_ACQUIRE_RC"
fi
retry_mutex_cleanup

make_mutex_cleanup_fixture release-failure
MUTEX_RELEASE_STDERR="$CLEANUP_TMP/runtime/mutex-release-failure.stderr"
set +e
bash -c '
  . "$1"
  _uberdev_semaphore_mutex_release() { return 31; }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
  2>"$MUTEX_RELEASE_STDERR"
MUTEX_RELEASE_RC=$?
set -e
if [ "$MUTEX_RELEASE_RC" -eq 2 ] \
    && [ ! -e "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] \
    && ! git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$MUTEX_BRANCH" \
    && [ ! -e "$MUTEX_RECEIPT" ] \
    && receipt_is_retired "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
      "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
    && [ "$(cat "$MUTEX_RELEASE_STDERR")" = \
      'uberdev codex cleanup: mutex release failed after cleanup transaction' ]; then
  pass_msg "git metadata mutex release failure is bounded, distinct, and retains the retired tombstone"
else
  fail_msg "git metadata mutex release failure is bounded, distinct, and preserves recovery evidence" \
    "rc=$MUTEX_RELEASE_RC diagnostic=$(tr '\n' ';' <"$MUTEX_RELEASE_STDERR")"
fi
if retry_mutex_cleanup && [ ! -e "$MUTEX_RECEIPT" ]; then
  pass_msg "cleanup retry reclaims a dead mutex and commits the retained receipt"
else
  fail_msg "cleanup retry reclaims a dead mutex and commits the retained receipt"
fi

make_mutex_cleanup_fixture receipt-failure
MUTEX_RECEIPT_STDERR="$CLEANUP_TMP/runtime/mutex-receipt-failure.stderr"
set +e
bash -c '
  . "$1"
  _uberdev_dispatch_retire_codex_worktree_receipt() { return 2; }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
  2>"$MUTEX_RECEIPT_STDERR"
MUTEX_RECEIPT_RC=$?
set -e
if [ "$MUTEX_RECEIPT_RC" -eq 2 ] \
    && [ ! -e "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] \
    && ! git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$MUTEX_BRANCH" \
    && [ -f "$MUTEX_RECEIPT" ] \
    && [ "$(cat "$MUTEX_RECEIPT_STDERR")" = \
      $'uberdev codex cleanup: transient attempt 1/3; retrying in 0.05s\nuberdev codex cleanup: transient attempt 2/3; retrying in 0.10s\nuberdev codex cleanup: receipt retirement failed after cleanup transaction' ]; then
  pass_msg "receipt retirement failure is bounded, distinct, and retains active recovery evidence"
else
  fail_msg "receipt retirement failure is bounded, distinct, and retains recovery evidence" \
    "rc=$MUTEX_RECEIPT_RC diagnostic=$(tr '\n' ';' <"$MUTEX_RECEIPT_STDERR")"
fi
retry_mutex_cleanup

make_mutex_cleanup_fixture retire-cross-invocation
retire_cross_first_attempts="$CLEANUP_TMP/runtime/retire-cross-first.attempts"
retire_cross_fresh_attempts="$CLEANUP_TMP/runtime/retire-cross-fresh.attempts"
: >"$retire_cross_first_attempts"; : >"$retire_cross_fresh_attempts"
set +e
RETIRE_CROSS_ATTEMPTS="$retire_cross_first_attempts" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_retire_codex_worktree_receipt | sed "1s/_uberdev_dispatch_retire_codex_worktree_receipt/_uberdev_dispatch_retire_codex_worktree_receipt_real/")"
  _uberdev_dispatch_retire_codex_worktree_receipt() {
    printf "attempt\n" >>"$RETIRE_CROSS_ATTEMPTS"
    _uberdev_dispatch_retire_codex_worktree_receipt_real "$@" || return $?
    return 2
  }
  _uberdev_dispatch_with_git_metadata_mutex "$2" retire-cross-first \
    _uberdev_dispatch_cleanup_codex_worktree_locked "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
  "$MUTEX_RECEIPT" "$MUTEX_TOKEN"
retire_cross_first_rc=$?
set -e
retire_cross_mid_state=invalid
receipt_is_retired "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
  "$MUTEX_RECEIPT" "$MUTEX_TOKEN" && retire_cross_mid_state=retired
set +e
RETIRE_CROSS_ATTEMPTS="$retire_cross_fresh_attempts" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_retire_codex_worktree_receipt | sed "1s/_uberdev_dispatch_retire_codex_worktree_receipt/_uberdev_dispatch_retire_codex_worktree_receipt_real/")"
  _uberdev_dispatch_retire_codex_worktree_receipt() {
    printf "attempt\n" >>"$RETIRE_CROSS_ATTEMPTS"
    _uberdev_dispatch_retire_codex_worktree_receipt_real "$@"
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
  "$MUTEX_RECEIPT" "$MUTEX_TOKEN"
retire_cross_fresh_rc=$?
set -e
if [ "$retire_cross_first_rc" -eq 2 ] \
    && [ "$retire_cross_mid_state" = retired ] \
    && [ "$(wc -l <"$retire_cross_first_attempts" | tr -d ' ')" -eq 1 ] \
    && [ "$retire_cross_fresh_rc" -eq 0 ] \
    && [ "$(wc -l <"$retire_cross_fresh_attempts" | tr -d ' ')" -eq 1 ] \
    && receipt_is_retired "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
      "$MUTEX_RECEIPT" "$MUTEX_TOKEN"; then
  pass_msg "fresh T-only cleanup replays retire to complete a prior process directory sync"
else
  fail_msg "cross-invocation T-only recovery cannot trust an unconfirmed tombstone" \
    "first_rc=$retire_cross_first_rc mid=$retire_cross_mid_state fresh_rc=$retire_cross_fresh_rc fresh_attempts=$(cat "$retire_cross_fresh_attempts")"
fi

make_mutex_cleanup_fixture retire-post-move
retire_post_move_attempts="$CLEANUP_TMP/runtime/retire-post-move.attempts"
: >"$retire_post_move_attempts"
set +e
RETIRE_POST_MOVE_ATTEMPTS="$retire_post_move_attempts" bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_retire_codex_worktree_receipt | sed "1s/_uberdev_dispatch_retire_codex_worktree_receipt/_uberdev_dispatch_retire_codex_worktree_receipt_real/")"
  _uberdev_dispatch_retire_codex_worktree_receipt() {
    printf "attempt\n" >>"$RETIRE_POST_MOVE_ATTEMPTS"
    _uberdev_dispatch_retire_codex_worktree_receipt_real "$1" "$2" "$3" "$4" "$5" "$6" || return $?
    [ "$(wc -l <"$RETIRE_POST_MOVE_ATTEMPTS" | tr -d " ")" -gt 1 ] || return 2
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
  "$MUTEX_RECEIPT" "$MUTEX_TOKEN"
retire_post_move_rc=$?
set -e
if [ "$retire_post_move_rc" -eq 0 ] \
    && [ "$(wc -l <"$retire_post_move_attempts" | tr -d ' ')" -eq 2 ] \
    && receipt_is_retired "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" \
      "$MUTEX_RECEIPT" "$MUTEX_TOKEN"; then
  pass_msg "post-move retire rc2 replays exact retirement before committing cleanup"
else
  fail_msg "retire rc2 cannot be mistaken for a durable T-only success" \
    "rc=$retire_post_move_rc attempts=$(cat "$retire_post_move_attempts")"
fi

make_mutex_cleanup_fixture transient-retry
set +e
bash -c '
  . "$1"
  eval "$(declare -f _uberdev_dispatch_cleanup_codex_worktree_locked | sed "1s/_uberdev_dispatch_cleanup_codex_worktree_locked/_uberdev_dispatch_cleanup_codex_worktree_locked_real/")"
  retry_count=0
  _uberdev_dispatch_cleanup_codex_worktree_locked() {
    retry_count=$((retry_count + 1))
    printf "%s\n" "$retry_count" >>"$7"
    [ "$retry_count" -gt 1 ] || return 2
    _uberdev_dispatch_cleanup_codex_worktree_locked_real "$1" "$2" "$3" "$4" "$5" "$6"
  }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed "$7"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
  "$CLEANUP_TMP/runtime/transient-retry.attempts"
MUTEX_TRANSIENT_RC=$?
set -e
if [ "$MUTEX_TRANSIENT_RC" -eq 0 ] \
    && [ "$(wc -l <"$CLEANUP_TMP/runtime/transient-retry.attempts" | tr -d ' ')" -eq 2 ] \
    && [ ! -e "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] \
    && [ ! -e "$MUTEX_RECEIPT" ]; then
  pass_msg "transient rc2 cleanup retries under one mutex then commits the receipt"
else
  fail_msg "transient rc2 cleanup retries under one mutex then commits the receipt" \
    "rc=$MUTEX_TRANSIENT_RC attempts=$(cat "$CLEANUP_TMP/runtime/transient-retry.attempts" 2>/dev/null)"
fi

make_mutex_cleanup_fixture exhausted-retry
set +e
bash -c '
  . "$1"
  _uberdev_dispatch_cleanup_codex_worktree_locked() { printf "attempt\n" >>"$7"; return 2; }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed "$7"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
  "$CLEANUP_TMP/runtime/exhausted-retry.attempts"
MUTEX_EXHAUSTED_RC=$?
set -e
if [ "$MUTEX_EXHAUSTED_RC" -eq 2 ] \
    && [ "$(wc -l <"$CLEANUP_TMP/runtime/exhausted-retry.attempts" | tr -d ' ')" -eq 3 ] \
    && [ -d "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] && [ -f "$MUTEX_RECEIPT" ]; then
  pass_msg "exhausted transient cleanup retries preserve exact recovery evidence"
else
  fail_msg "exhausted transient cleanup retries preserve exact recovery evidence" \
    "rc=$MUTEX_EXHAUSTED_RC attempts=$(cat "$CLEANUP_TMP/runtime/exhausted-retry.attempts" 2>/dev/null)"
fi
retry_mutex_cleanup

make_mutex_cleanup_fixture preservation-stop
set +e
bash -c '
  . "$1"
  _uberdev_dispatch_cleanup_codex_worktree_locked() { printf "attempt\n" >>"$7"; return 3; }
  _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed "$7"
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$MUTEX_RELATIVE" "$MUTEX_BRANCH" "$MUTEX_RECEIPT" "$MUTEX_TOKEN" \
  "$CLEANUP_TMP/runtime/preservation-stop.attempts"
MUTEX_PRESERVATION_RC=$?
set -e
if [ "$MUTEX_PRESERVATION_RC" -eq 3 ] \
    && [ "$(wc -l <"$CLEANUP_TMP/runtime/preservation-stop.attempts" | tr -d ' ')" -eq 1 ] \
    && [ -d "$CLEANUP_TMP/repo/$MUTEX_RELATIVE" ] && [ -f "$MUTEX_RECEIPT" ]; then
  pass_msg "dirty or advanced preservation rc3 is never retried"
else
  fail_msg "dirty or advanced preservation rc3 is never retried" \
    "rc=$MUTEX_PRESERVATION_RC attempts=$(cat "$CLEANUP_TMP/runtime/preservation-stop.attempts" 2>/dev/null)"
fi
retry_mutex_cleanup

generic_mutex_errors=''
for generic_provider_rc in 0 42; do
  GENERIC_RELEASE_LOG="$CLEANUP_TMP/runtime/generic-release-$generic_provider_rc.log"
  set +e
  GENERIC_MUTEX_OUT="$(bash -c '
    . "$1"
    _uberdev_dispatch_git_metadata_mutex_scope() { printf "%s" "$2"; }
    _uberdev_semaphore_mutex_acquire() { return 0; }
    generic_release_log="$4"
    _uberdev_semaphore_mutex_release() { printf "release\\n" >>"$generic_release_log"; return 31; }
    _uberdev_dispatch_with_git_metadata_mutex /unused generic-test bash -c \
      '\''printf "provider-output-%s\\n" "$1"; exit "$1"'\'' _ "$3"
  ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/runtime/generic-scope" "$generic_provider_rc" \
    "$GENERIC_RELEASE_LOG" 2>"$CLEANUP_TMP/runtime/generic-stderr-$generic_provider_rc.log")"
  GENERIC_MUTEX_RC=$?
  set -e
  expected_generic_rc="$generic_provider_rc"
  [ "$generic_provider_rc" -ne 0 ] || expected_generic_rc=2
  [ "$GENERIC_MUTEX_RC" -eq "$expected_generic_rc" ] \
    || generic_mutex_errors="$generic_mutex_errors rc-$generic_provider_rc-$GENERIC_MUTEX_RC"
  printf '%s\n' "$GENERIC_MUTEX_OUT" | grep -Fq "provider-output-$generic_provider_rc" \
    || generic_mutex_errors="$generic_mutex_errors output-$generic_provider_rc"
  grep -Fxq 'uberdev git metadata mutex: release failed after transaction' \
    "$CLEANUP_TMP/runtime/generic-stderr-$generic_provider_rc.log" \
    || generic_mutex_errors="$generic_mutex_errors release-log-$generic_provider_rc"
  [ "$(wc -l <"$GENERIC_RELEASE_LOG" | tr -d ' ')" -eq 2 ] \
    || generic_mutex_errors="$generic_mutex_errors exit-retry-$generic_provider_rc"
done
if [ -z "$generic_mutex_errors" ]; then
  pass_msg "generic Git metadata mutex preserves provider rc/output and surfaces release failure"
else
  fail_msg "generic Git metadata mutex preserves provider rc/output and surfaces release failure" "$generic_mutex_errors"
fi

GENERIC_DEAD_STDERR="$CLEANUP_TMP/runtime/generic-dead-owner.stderr"
set +e
bash -c '
  . "$1"
  _uberdev_semaphore_mutex_release() { return 31; }
  _uberdev_dispatch_with_git_metadata_mutex "$2" release-reclaim sh -c '\''printf command-ok'\''
' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" >"$CLEANUP_TMP/runtime/generic-dead-owner.stdout" \
  2>"$GENERIC_DEAD_STDERR"
GENERIC_DEAD_RC=$?
set -e
GENERIC_DEAD_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo")"
set +e
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 bash -c \
  '. "$1"; _uberdev_semaphore_mutex_acquire "$2" && _uberdev_semaphore_mutex_release "$2"' \
  _ "$DISPATCH_LIB" "$GENERIC_DEAD_SCOPE"
GENERIC_RECLAIM_RC=$?
set -e
if [ "$GENERIC_DEAD_RC" -eq 2 ] \
    && [ "$(cat "$CLEANUP_TMP/runtime/generic-dead-owner.stdout")" = command-ok ] \
    && grep -Fxq 'uberdev git metadata mutex: release failed after transaction' "$GENERIC_DEAD_STDERR" \
    && [ "$GENERIC_RECLAIM_RC" -eq 0 ] && [ ! -e "$GENERIC_DEAD_SCOPE/.mutex" ]; then
  pass_msg "successful command plus release failure is infrastructure-nonzero and its dead owner is reclaimed"
else
  fail_msg "successful command plus release failure is infrastructure-nonzero and reclaimable" \
    "command_rc=$GENERIC_DEAD_RC reclaim_rc=$GENERIC_RECLAIM_RC stderr=$(cat "$GENERIC_DEAD_STDERR")"
fi

NATIVE_ADD_CAPTURE="$CLEANUP_TMP/runtime/native-add-target.capture"
NATIVE_ADD_POSIX='/tmp/runner-temp/repo/.claude/worktrees/native-add-target'
NATIVE_ADD_EXPECTED='C:/Users/runner/AppData/Local/Temp/repo/.claude/worktrees/native-add-target'
if MSYSTEM=MINGW64 NATIVE_ADD_CAPTURE="$NATIVE_ADD_CAPTURE" \
    NATIVE_ADD_POSIX="$NATIVE_ADD_POSIX" NATIVE_ADD_EXPECTED="$NATIVE_ADD_EXPECTED" \
    bash -c '
      . "$1"
      cygpath() {
        [ "$1" = -m ] && [ "$2" = "$NATIVE_ADD_POSIX" ] || return 91
        printf "%s\n" "$NATIVE_ADD_EXPECTED"
      }
      git() {
        printf "pathconv=%s\nargv=%s\n" "${MSYS_NO_PATHCONV:-}" "$*" >"$NATIVE_ADD_CAPTURE"
      }
      _uberdev_dispatch_git_worktree_add_locked "$3" "$NATIVE_ADD_POSIX" native-add-branch "$2"
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/runtime/native-add-target.git.log" "$CLEANUP_TMP/repo" \
    && grep -Fxq 'pathconv=1' "$NATIVE_ADD_CAPTURE" \
    && grep -Fxq "argv=worktree add $NATIVE_ADD_EXPECTED -b native-add-branch" "$NATIVE_ADD_CAPTURE"; then
  pass_msg "native Git worktree add receives one normalized Windows target"
else
  fail_msg "native Git worktree add receives one normalized Windows target" \
    "capture=$(tr '\n' ';' <"$NATIVE_ADD_CAPTURE" 2>/dev/null)"
fi

for RELEASE_ADD_KIND in child nonchild; do
  RELEASE_ADD_RELATIVE=".claude/worktrees/solve-issue-335-release-failure-$RELEASE_ADD_KIND"
  RELEASE_ADD_TARGET="$CLEANUP_TMP/repo/$RELEASE_ADD_RELATIVE"
  RELEASE_ADD_BRANCH="worktree-solve-issue-335-release-failure-$RELEASE_ADD_KIND"
  RELEASE_ADD_LOG="$CLEANUP_TMP/runtime/release-failure-$RELEASE_ADD_KIND.git.log"
  RELEASE_ADD_STDERR="$CLEANUP_TMP/runtime/release-failure-$RELEASE_ADD_KIND.stderr"
  RELEASE_ADD_RECEIPT="$CLEANUP_TMP/runtime/release-failure-$RELEASE_ADD_KIND.owner.json"
  RELEASE_ADD_TOKEN=''
  if [ "$RELEASE_ADD_KIND" = child ]; then
    RELEASE_ADD_TOKEN="$(bash -c \
      '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
      _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$RELEASE_ADD_RELATIVE" \
      "$RELEASE_ADD_BRANCH" "$RELEASE_ADD_RECEIPT")"
  fi
  set +e
  bash -c '
    . "$1"
    _uberdev_semaphore_mutex_release() { return 31; }
    _uberdev_dispatch_git_worktree_add "$2" "$3" "$4" "$5"
  ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$RELEASE_ADD_TARGET" \
    "$RELEASE_ADD_BRANCH" "$RELEASE_ADD_LOG" 2>"$RELEASE_ADD_STDERR"
  RELEASE_ADD_RC=$?
  set -e
  RELEASE_ADD_RECOVERY_RC=0
  if [ "$RELEASE_ADD_KIND" = child ]; then
    UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 bash -c '
      . "$1"
      _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$RELEASE_ADD_RELATIVE" \
      "$RELEASE_ADD_BRANCH" "$RELEASE_ADD_RECEIPT" "$RELEASE_ADD_TOKEN" \
      || RELEASE_ADD_RECOVERY_RC=$?
  else
    UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1 bash -c '
      . "$1"
      _uberdev_dispatch_with_git_metadata_mutex "$2" release-recovery bash -c '\''
        cd "$1" || exit 2
        git worktree remove --force "$2" || exit $?
        git branch -D "$3" >/dev/null
      '\'' _ "$2" "$3" "$4"
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$RELEASE_ADD_TARGET" "$RELEASE_ADD_BRANCH" \
      || RELEASE_ADD_RECOVERY_RC=$?
  fi
  if [ "$RELEASE_ADD_RC" -eq 2 ] \
      && grep -Fxq 'uberdev git metadata mutex: release failed after transaction' "$RELEASE_ADD_STDERR" \
      && [ "$RELEASE_ADD_RECOVERY_RC" -eq 0 ] \
      && [ ! -e "$RELEASE_ADD_TARGET" ] \
      && ! git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$RELEASE_ADD_BRANCH" \
      && { [ "$RELEASE_ADD_KIND" = nonchild ] || [ ! -e "$RELEASE_ADD_RECEIPT" ]; }; then
    pass_msg "$RELEASE_ADD_KIND add stays tracked across release failure and exact recovery"
  else
    fail_msg "$RELEASE_ADD_KIND add stays tracked across release failure and exact recovery" \
      "add_rc=$RELEASE_ADD_RC recovery_rc=$RELEASE_ADD_RECOVERY_RC stderr=$(cat "$RELEASE_ADD_STDERR")"
  fi
done

release_dispatch_instance='release-failure-dispatch-a1'
release_dispatch_slug="$(UBERDEV_AGENT_INSTANCE_ID="$release_dispatch_instance" bash -c \
  '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
release_dispatch_relative=".claude/worktrees/solve-issue-336-$release_dispatch_slug"
release_dispatch_branch="worktree-solve-issue-336-$release_dispatch_slug"
release_dispatch_status="$CLEANUP_TMP/runtime/release-failure-dispatch.status.json"
release_dispatch_receipt="$release_dispatch_status.worktree-owner.json"
release_dispatch_stderr="$CLEANUP_TMP/runtime/release-failure-dispatch.stderr"
release_dispatch_provider="$CLEANUP_TMP/runtime/release-failure-dispatch.provider"
printf 'release failure prompt\n' >"$CLEANUP_TMP/runtime/release-failure-dispatch.prompt"
set +e
(
  cd "$CLEANUP_TMP/repo"
  UBERDEV_AGENT_CHILD_OWNED=1 \
  UBERDEV_AGENT_INSTANCE_ID="$release_dispatch_instance" \
  UBERDEV_AGENT_STATUS_FILE="$release_dispatch_status" \
  UBERDEV_AGENT_RESULT_FILE="$CLEANUP_TMP/runtime/release-failure-dispatch.result" \
  RELEASE_DISPATCH_PROVIDER="$release_dispatch_provider" \
    bash -c '
      . "$1"
      _uberdev_semaphore_mutex_release() { return 31; }
      _uberdev_dispatch_launch_adapter() { : >"$RELEASE_DISPATCH_PROVIDER"; return 99; }
      _uberdev_dispatch_codex 336 small "$2"
    ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/runtime/release-failure-dispatch.prompt"
) 2>"$release_dispatch_stderr"
release_dispatch_rc=$?
set -e
release_dispatch_token="$(python3 -I -B -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["token"],end="")' \
  "$release_dispatch_receipt" 2>/dev/null || true)"
if [ "$release_dispatch_rc" -eq 74 ] \
    && [ ! -e "$release_dispatch_provider" ] \
    && [ -d "$CLEANUP_TMP/repo/$release_dispatch_relative" ] \
    && git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$release_dispatch_branch" \
    && [ -n "$release_dispatch_token" ] \
    && [ "$(cat "$release_dispatch_stderr")" = \
      'uberdev git metadata mutex: release failed after transaction' ] \
    && grep -Fxq 'uberdev codex setup: recoverable worktree transaction failure' \
      "$release_dispatch_status.log"; then
  pass_msg "successful add plus release failure never launches provider and preserves recoverable P/W/B"
else
  fail_msg "release failure after add is supervisory and preserves exact setup evidence" \
    "rc=$release_dispatch_rc stderr=$(tr '\n' ';' <"$release_dispatch_stderr")"
fi
if [ -n "$release_dispatch_token" ]; then
  bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" setup_failed' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$release_dispatch_relative" "$release_dispatch_branch" \
    "$release_dispatch_receipt" "$release_dispatch_token"
fi

echo "== Non-child add and child cleanup share one Git metadata transaction =="
CONCURRENT_BIN="$CLEANUP_TMP/concurrent-bin"
mkdir -p "$CONCURRENT_BIN"
cat >"$CONCURRENT_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --git-common-dir ]; then
  pre="$CONCURRENT_GIT_PREACQUIRE_DIR"
  mkdir -p "$pre"
  mkdir "$pre/arrival-$PPID" 2>/dev/null || true
  printf 'pending\towner=%s\n' "$PPID" >>"$CONCURRENT_GIT_EVENT_LOG"
  count="$(find "$pre" -mindepth 1 -maxdepth 1 -type d -name 'arrival-*' | wc -l | tr -d ' ')"
  if [ "$count" -ge 2 ] && mkdir "$pre/released" 2>/dev/null; then
    printf 'barrier-release\tcount=%s\n' "$count" >>"$CONCURRENT_GIT_EVENT_LOG"
  fi
  tries=0
  while [ ! -d "$pre/released" ] && [ "$tries" -lt 1000 ]; do
    tries=$((tries + 1))
    sleep 0.01
  done
  if [ ! -d "$pre/released" ]; then
    printf 'barrier-timeout\towner=%s\tcount=%s\n' "$PPID" "$count" \
      >>"$CONCURRENT_GIT_COLLISION_LOG"
    exit 88
  fi
  exec "$CONCURRENT_REAL_GIT" "$@"
fi

phase=''
case "${1:-}:${2:-}" in
  worktree:add) phase=add ;;
  worktree:remove) phase=remove ;;
  worktree:list) phase=list ;;
  branch:-D) phase=branch ;;
esac
[ -n "$phase" ] || exec "$CONCURRENT_REAL_GIT" "$@"

common_dir="$("$CONCURRENT_REAL_GIT" rev-parse --git-common-dir)"
case "$common_dir" in /*) ;; *) common_dir="$PWD/$common_dir" ;; esac
common_dir="$(cd "$common_dir" && pwd -P)"
sentinel="$common_dir/.uberdev-add-cleanup-critical"
owner_file="$sentinel/owner"
collision() {
  actual="$(cat "$owner_file" 2>/dev/null || printf missing)"
  printf 'overlap\towner=%s\tactual=%s\tphase=%s\targv=%s\n' \
    "$PPID" "$actual" "$phase" "$*" >>"$CONCURRENT_GIT_COLLISION_LOG"
  exit 89
}

case "$phase" in
  add)
    if ! mkdir "$sentinel" 2>/dev/null; then collision "$@"; fi
    chmod 700 "$sentinel"
    printf '%s\n' "$PPID" >"$owner_file"
    ;;
  list|remove)
    if [ -f "$owner_file" ]; then
      [ "$(cat "$owner_file")" = "$PPID" ] || collision "$@"
    else
      if ! mkdir "$sentinel" 2>/dev/null; then collision "$@"; fi
      chmod 700 "$sentinel"
      printf '%s\n' "$PPID" >"$owner_file"
    fi
    ;;
  *)
    [ -f "$owner_file" ] || collision "$@"
    [ "$(cat "$owner_file")" = "$PPID" ] || collision "$@"
    ;;
esac
printf 'critical\towner=%s\tphase=%s\n' "$PPID" "$phase" >>"$CONCURRENT_GIT_EVENT_LOG"

# The bypass round deliberately holds its first entrant until the second has
# attempted entry, proving this detector observes overlap instead of passing by
# scheduler luck. Production rounds never use this test-only control.
if [ "${CONCURRENT_GIT_EXPECT_COLLISION:-0}" = 1 ] && { [ "$phase" = add ] || [ "$phase" = remove ]; }; then
  tries=0
  while ! grep -q '^overlap' "$CONCURRENT_GIT_COLLISION_LOG" 2>/dev/null \
      && [ "$tries" -lt 1000 ]; do
    tries=$((tries + 1))
    sleep 0.01
  done
fi

if "$CONCURRENT_REAL_GIT" "$@"; then rc=0; else rc=$?; fi
if [ "$phase" = add ] || [ "$phase" = branch ]; then
  printf 'critical\towner=%s\tphase=release\n' "$PPID" >>"$CONCURRENT_GIT_EVENT_LOG"
  rm -f "$owner_file"
  rmdir "$sentinel"
fi
exit "$rc"
SH
chmod +x "$CONCURRENT_BIN/git"

run_add_cleanup_round() {
  local mode="$1" label="$2" child_relative child_branch child_receipt child_token
  local add_relative add_branch add_log pre events collisions add_pid cleanup_pid add_rc cleanup_rc
  local provider_started provider_held provider_released provider_pid provider_ok=1
  child_relative=".claude/worktrees/solve-issue-335-concurrent-child-$label"
  child_branch="worktree-solve-issue-335-concurrent-child-$label"
  child_receipt="$CLEANUP_TMP/runtime/concurrent-child-$label.owner.json"
  child_token="$(bash -c '. "$1"; _uberdev_dispatch_create_codex_worktree_receipt "$2" "$3" "$4" "$5"' \
    _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$child_relative" "$child_branch" "$child_receipt")"
  git -C "$CLEANUP_TMP/repo" worktree add -q "$child_relative" -b "$child_branch"
  add_relative=".claude/worktrees/concurrent-add-$label"
  add_branch="worktree-concurrent-add-$label"
  add_log="$CLEANUP_TMP/runtime/concurrent-add-$label.log"
  pre="$CLEANUP_TMP/runtime/concurrent-$label-pre"
  events="$CLEANUP_TMP/runtime/concurrent-$label-events.log"
  collisions="$CLEANUP_TMP/runtime/concurrent-$label-collisions.log"
  provider_started="$CLEANUP_TMP/runtime/concurrent-$label-provider-started"
  provider_held="$CLEANUP_TMP/runtime/concurrent-$label-provider-held"
  provider_released="$CLEANUP_TMP/runtime/concurrent-$label-provider-released"
  provider_pid="$CLEANUP_TMP/runtime/concurrent-$label-provider-pid"
  mkdir -p "$pre"
  : >"$events"; : >"$collisions"

  if [ "$mode" = bypass ]; then
    PATH="$CONCURRENT_BIN:$PATH" CONCURRENT_REAL_GIT="$REAL_CLEANUP_GIT" \
      CONCURRENT_GIT_PREACQUIRE_DIR="$pre" CONCURRENT_GIT_EVENT_LOG="$events" \
      CONCURRENT_GIT_COLLISION_LOG="$collisions" CONCURRENT_GIT_EXPECT_COLLISION=1 \
      bash -c '
        . "$1"
        git -C "$2" rev-parse --git-common-dir >/dev/null || exit $?
        native_target="$(_uberdev_dispatch_native_cli_path "$3")" || exit $?
        cd "$2" || exit 2
        MSYS_NO_PATHCONV=1 git worktree add "$native_target" -b "$4" >"$5" 2>&1
      ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CLEANUP_TMP/repo/$add_relative" \
        "$add_branch" "$add_log" &
    add_pid=$!
    PATH="$CONCURRENT_BIN:$PATH" CONCURRENT_REAL_GIT="$REAL_CLEANUP_GIT" \
      CONCURRENT_GIT_PREACQUIRE_DIR="$pre" CONCURRENT_GIT_EVENT_LOG="$events" \
      CONCURRENT_GIT_COLLISION_LOG="$collisions" CONCURRENT_GIT_EXPECT_COLLISION=1 \
      bash -c '
        . "$1"
        git -C "$2" rev-parse --git-common-dir >/dev/null || exit $?
        _uberdev_dispatch_cleanup_codex_worktree_locked "$2" "$3" "$4" "$5" "$6" completed
      ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$child_relative" "$child_branch" "$child_receipt" "$child_token" &
    cleanup_pid=$!
  else
    PATH="$CONCURRENT_BIN:$PATH" CONCURRENT_REAL_GIT="$REAL_CLEANUP_GIT" \
      CONCURRENT_GIT_PREACQUIRE_DIR="$pre" CONCURRENT_GIT_EVENT_LOG="$events" \
      CONCURRENT_GIT_COLLISION_LOG="$collisions" \
      bash -c '
        . "$1"
        if [ "$6" = claude ]; then
          _uberdev_dispatch_with_git_metadata_mutex "$2" claude-bootstrap-test bash -c \
            '\''
              cd "$1" || exit 2
              git worktree add "$2" -b "$3" >"$4" 2>&1 || exit $?
              (
                printf "%s\\n" "$BASHPID" >"$8"
                locks="$1/.git/.uberdev-worktree-metadata-locks"
                if find "$locks" -name .mutex -print 2>/dev/null | grep -q .; then
                  printf "held\\n" >"$6"
                else
                  printf "missing\\n" >"$6"
                fi
                printf "started\\n" >"$5"
                tries=0
                while find "$locks" -name .mutex -print 2>/dev/null | grep -q . \
                    && [ "$tries" -lt 1000 ]; do
                  tries=$((tries + 1)); sleep 0.01
                done
                [ "$tries" -lt 1000 ] || exit 88
                printf "released\\n" >"$7"
                sleep 5
              ) </dev/null >/dev/null 2>&1 &
              tries=0
              while [ ! -e "$5" ] && [ "$tries" -lt 1000 ]; do
                tries=$((tries + 1)); sleep 0.01
              done
              [ -e "$5" ]
            '\'' _ "$2" "$3" "$4" "$5" "$7" "$8" "$9" "${10}"
        else
          _uberdev_dispatch_git_worktree_add "$2" "$3" "$4" "$5"
        fi
      ' _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$CLEANUP_TMP/repo/$add_relative" "$add_branch" "$add_log" "$label" \
        "$provider_started" "$provider_held" "$provider_released" "$provider_pid" &
    add_pid=$!
    PATH="$CONCURRENT_BIN:$PATH" CONCURRENT_REAL_GIT="$REAL_CLEANUP_GIT" \
      CONCURRENT_GIT_PREACQUIRE_DIR="$pre" CONCURRENT_GIT_EVENT_LOG="$events" \
      CONCURRENT_GIT_COLLISION_LOG="$collisions" \
      bash -c '. "$1"; _uberdev_dispatch_cleanup_codex_worktree "$2" "$3" "$4" "$5" "$6" completed' \
        _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo" "$child_relative" "$child_branch" "$child_receipt" "$child_token" &
    cleanup_pid=$!
  fi
  set +e
  wait "$add_pid"; add_rc=$?
  wait "$cleanup_pid"; cleanup_rc=$?
  set -e

  if [ "$mode" = mutex ] && [ "$label" = claude ]; then
    tries=0
    while [ ! -e "$provider_released" ] && [ "$tries" -lt 1000 ]; do
      tries=$((tries + 1)); sleep 0.01
    done
    live_provider_pid="$(cat "$provider_pid" 2>/dev/null)"
    if [ "$(cat "$provider_held" 2>/dev/null)" != held ] \
        || [ "$(cat "$provider_released" 2>/dev/null)" != released ] \
        || ! kill -0 "$live_provider_pid" 2>/dev/null; then
      provider_ok=0
    fi
    case "$live_provider_pid" in ''|*[!0-9]*) ;; *) kill "$live_provider_pid" 2>/dev/null || true ;; esac
  fi

  if [ "$mode" = bypass ]; then
    if { [ "$add_rc" -ne 0 ] || [ "$cleanup_rc" -ne 0 ]; } \
        && grep -q '^overlap' "$collisions" \
        && ! grep -q '^barrier-timeout' "$collisions" \
        && python3 -I -B - "$events" <<'PY'
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
pending=[line.split("owner=",1)[1] for line in lines if line.startswith("pending\towner=")]
assert len(pending)==len(set(pending))==2,pending
assert [line for line in lines if line.startswith("barrier-release\t")]==["barrier-release\tcount=2"],lines
PY
    then
      pass_msg "add-vs-cleanup detector rejects an unprotected overlap"
    else
      fail_msg "add-vs-cleanup detector rejects an unprotected overlap" \
        "add_rc=$add_rc cleanup_rc=$cleanup_rc events=$(tr '\n' ';' <"$events") collisions=$(cat "$collisions")"
    fi
  elif python3 -I -B - "$events" "$collisions" <<'PY'
import collections,pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert not pathlib.Path(sys.argv[2]).read_text(),pathlib.Path(sys.argv[2]).read_text()
pending=[line.split("owner=",1)[1] for line in lines if line.startswith("pending\towner=")]
assert len(pending)==len(set(pending))==2,pending
assert [line for line in lines if line.startswith("barrier-release\t")]==["barrier-release\tcount=2"],lines
events=collections.defaultdict(list)
for line in lines:
    if not line.startswith("critical\t"): continue
    fields=dict(field.split("=",1) for field in line.split("\t")[1:])
    events[fields["owner"]].append(fields["phase"])
assert sorted(events.values())==sorted([["add","release"],["list","remove","list","branch","release"]]),events
PY
  then
    if [ "$add_rc" -eq 0 ] && [ "$cleanup_rc" -eq 0 ] \
        && [ -d "$CLEANUP_TMP/repo/$add_relative" ] \
        && [ ! -e "$CLEANUP_TMP/repo/$child_relative" ] \
        && [ ! -e "$child_receipt" ] && [ "$provider_ok" -eq 1 ]; then
      pass_msg "$label worktree add and Codex cleanup serialize across concurrent workflows"
    else
      fail_msg "$label worktree add and Codex cleanup serialize across concurrent workflows" \
        "add_rc=$add_rc cleanup_rc=$cleanup_rc events=$(tr '\n' ';' <"$events") collisions=$(cat "$collisions")"
    fi
  else
    fail_msg "$label worktree add and Codex cleanup serialize across concurrent workflows" \
      "event contract failed: $(tr '\n' ';' <"$events") collisions=$(cat "$collisions")"
  fi

  # Exact fixture recovery between the negative and positive rounds.
  rm -rf "$CLEANUP_TMP/repo/.git/.uberdev-add-cleanup-critical"
  if [ -d "$CLEANUP_TMP/repo/$child_relative" ]; then
    git -C "$CLEANUP_TMP/repo" worktree remove --force "$child_relative"
  fi
  git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$child_branch" \
    && git -C "$CLEANUP_TMP/repo" branch -D "$child_branch" >/dev/null
  if [ -f "$child_receipt" ]; then
    retire_preserved_fixture "$CLEANUP_TMP/repo" "$child_relative" "$child_branch" \
      "$child_receipt" "$child_token"
  fi
  if [ -d "$CLEANUP_TMP/repo/$add_relative" ]; then
    git -C "$CLEANUP_TMP/repo" worktree remove --force "$add_relative"
  fi
  git -C "$CLEANUP_TMP/repo" show-ref --verify --quiet "refs/heads/$add_branch" \
    && git -C "$CLEANUP_TMP/repo" branch -D "$add_branch" >/dev/null
}

run_add_cleanup_round bypass negative
run_add_cleanup_round mutex codex
run_add_cleanup_round mutex background
run_add_cleanup_round mutex wezterm
run_add_cleanup_round mutex claude

MUTEX_SCOPE="$(bash -c '. "$1"; _uberdev_dispatch_git_metadata_mutex_scope "$2"' \
  _ "$DISPATCH_LIB" "$CLEANUP_TMP/repo")"
if python3 -I -B - "$MUTEX_SCOPE" <<'PY'
import os,pathlib,stat,sys
scope=pathlib.Path(sys.argv[1]); entry=scope.stat()
uid_fn=getattr(os,"geteuid",None)
if uid_fn is not None: assert entry.st_uid==uid_fn()
if os.name!="nt": assert stat.S_IMODE(entry.st_mode)==0o700
assert not (scope/".mutex").exists()
PY
then
  pass_msg "git metadata mutex scope is private and has no live generation after cleanup"
else
  fail_msg "git metadata mutex scope is private and has no live generation after cleanup" "$MUTEX_SCOPE"
fi
rm -rf "$CLEANUP_TMP"

echo "== Codex setup failures clean child-owned worktrees end to end =="
SETUP_FAILURE_TMP="$(canonical_test_path "$(mktemp -d)")" || exit 1
mkdir -p "$SETUP_FAILURE_TMP/repo/nested/invocation" "$SETUP_FAILURE_TMP/runtime"
chmod 700 "$SETUP_FAILURE_TMP/runtime"
(
  cd "$SETUP_FAILURE_TMP/repo"
  git init -q
  git config user.name 'UberDev Test'
  git config user.email 'uberdev-test@example.invalid'
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm base
)
printf 'valid prompt\n' > "$SETUP_FAILURE_TMP/prompt.txt"
setup_failure_errors=''
for setup_failure in prompt_read python_launcher; do
  instance="setup-$setup_failure-a1"
  slug="$(UBERDEV_AGENT_INSTANCE_ID="$instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
  relative=".claude/worktrees/solve-issue-335-$slug"
  branch="worktree-solve-issue-335-$slug"
  status="$SETUP_FAILURE_TMP/runtime/$setup_failure-status.json"
  result="$SETUP_FAILURE_TMP/runtime/$setup_failure-result.md"
  prompt="$SETUP_FAILURE_TMP/prompt.txt"
  [ "$setup_failure" != prompt_read ] || prompt="$SETUP_FAILURE_TMP/missing-prompt.txt"
  if (
    cd "$SETUP_FAILURE_TMP/repo/nested/invocation"
    UBERDEV_AGENT_STATUS_FILE="$status" UBERDEV_AGENT_RESULT_FILE="$result" \
      UBERDEV_AGENT_CHILD_OWNED=1 UBERDEV_AGENT_INSTANCE_ID="$instance" \
      bash -c '
        . "$1"
        if [ "$3" = python_launcher ]; then
          _uberdev_dispatch_resolve_python() { return 1; }
        fi
        _uberdev_dispatch_codex 335 small "$2"
      ' _ "$DISPATCH_LIB" "$prompt" "$setup_failure"
  ); then
    setup_failure_errors="$setup_failure_errors unexpected-success-$setup_failure"
  fi
  [ ! -e "$SETUP_FAILURE_TMP/repo/$relative" ] \
    || setup_failure_errors="$setup_failure_errors worktree-$setup_failure"
  git -C "$SETUP_FAILURE_TMP/repo" show-ref --verify --quiet "refs/heads/$branch" \
    && setup_failure_errors="$setup_failure_errors branch-$setup_failure"
  [ ! -e "$status.worktree-owner.json" ] \
    || setup_failure_errors="$setup_failure_errors receipt-$setup_failure"
done
if [ -z "$setup_failure_errors" ]; then
  pass_msg "missing-prompt and launcher-resolution failures remove child worktree, branch, and receipt"
else
  fail_msg "missing-prompt and launcher-resolution failures remove child worktree, branch, and receipt" "$setup_failure_errors"
fi

# A nonzero `git worktree add` may still leave both the branch and directory
# behind. The pre-created receipt remains authoritative until exact cleanup is
# proven, so this partial-creation path cannot silently discard its evidence.
PARTIAL_BIN="$SETUP_FAILURE_TMP/partial-bin"
mkdir -p "$PARTIAL_BIN"
PARTIAL_REAL_GIT="$(command -v git)"
cat > "$PARTIAL_BIN/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = worktree ] && [ "$2" = add ]; then
  "$PARTIAL_REAL_GIT" "$@" || exit $?
  exit 1
fi
exec "$PARTIAL_REAL_GIT" "$@"
SH
chmod +x "$PARTIAL_BIN/git"
partial_instance='setup-partial-worktree-a1'
partial_slug="$(UBERDEV_AGENT_INSTANCE_ID="$partial_instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
partial_relative=".claude/worktrees/solve-issue-335-$partial_slug"
partial_branch="worktree-solve-issue-335-$partial_slug"
partial_status="$SETUP_FAILURE_TMP/runtime/partial-status.json"
set +e
(
  cd "$SETUP_FAILURE_TMP/repo/nested/invocation"
  PATH="$PARTIAL_BIN:$PATH" PARTIAL_REAL_GIT="$PARTIAL_REAL_GIT" \
    UBERDEV_AGENT_STATUS_FILE="$partial_status" \
    UBERDEV_AGENT_RESULT_FILE="$SETUP_FAILURE_TMP/runtime/partial-result.md" \
    UBERDEV_AGENT_CHILD_OWNED=1 UBERDEV_AGENT_INSTANCE_ID="$partial_instance" \
    bash -c '. "$1"; _uberdev_dispatch_codex 335 small "$2"' \
      _ "$DISPATCH_LIB" "$SETUP_FAILURE_TMP/prompt.txt"
)
partial_rc=$?
set -e
partial_errors=''
[ "$partial_rc" -eq 1 ] || partial_errors="$partial_errors rc-$partial_rc"
[ ! -e "$SETUP_FAILURE_TMP/repo/$partial_relative" ] || partial_errors="$partial_errors worktree"
git -C "$SETUP_FAILURE_TMP/repo" show-ref --verify --quiet "refs/heads/$partial_branch" \
  && partial_errors="$partial_errors branch"
[ ! -e "$partial_status.worktree-owner.json" ] || partial_errors="$partial_errors receipt"
if [ -z "$partial_errors" ]; then
  pass_msg "partial worktree-add failure performs receipt-authorized cleanup"
else
  fail_msg "partial worktree-add failure performs receipt-authorized cleanup" "$partial_errors"
fi

# A failed cleanup is a distinct supervisory failure. The absolute worktree
# target, branch, and ownership receipt remain intact as recovery evidence even
# when review-pr was invoked below the repository root.
cleanup_instance='setup-cleanup-failure-a1'
cleanup_slug="$(UBERDEV_AGENT_INSTANCE_ID="$cleanup_instance" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
cleanup_relative=".claude/worktrees/solve-issue-335-$cleanup_slug"
cleanup_branch="worktree-solve-issue-335-$cleanup_slug"
cleanup_status="$SETUP_FAILURE_TMP/runtime/cleanup-failure-status.json"
cleanup_repo_root="$(git -C "$SETUP_FAILURE_TMP/repo" rev-parse --show-toplevel)"
set +e
(
  cd "$SETUP_FAILURE_TMP/repo/nested/invocation"
  UBERDEV_AGENT_STATUS_FILE="$cleanup_status" \
    UBERDEV_AGENT_RESULT_FILE="$SETUP_FAILURE_TMP/runtime/cleanup-failure-result.md" \
    UBERDEV_AGENT_CHILD_OWNED=1 UBERDEV_AGENT_INSTANCE_ID="$cleanup_instance" \
    bash -c '
      . "$1"
      _uberdev_dispatch_cleanup_codex_worktree() { return 2; }
      _uberdev_dispatch_codex 335 small "$2"
    ' _ "$DISPATCH_LIB" "$SETUP_FAILURE_TMP/missing-cleanup-prompt.txt"
)
cleanup_rc=$?
set -e
cleanup_failure_errors=''
[ "$cleanup_rc" -eq 74 ] || cleanup_failure_errors="$cleanup_failure_errors rc-$cleanup_rc"
[ -d "$SETUP_FAILURE_TMP/repo/$cleanup_relative" ] || cleanup_failure_errors="$cleanup_failure_errors missing-worktree"
git -C "$SETUP_FAILURE_TMP/repo" show-ref --verify --quiet "refs/heads/$cleanup_branch" \
  || cleanup_failure_errors="$cleanup_failure_errors missing-branch"
[ -f "$cleanup_status.worktree-owner.json" ] || cleanup_failure_errors="$cleanup_failure_errors missing-receipt"
grep -Fq "worktree=$cleanup_repo_root/$cleanup_relative" "$cleanup_status.log" \
  || cleanup_failure_errors="$cleanup_failure_errors missing-diagnostic"
if [ -z "$cleanup_failure_errors" ]; then
  pass_msg "subdirectory setup-cleanup failure returns supervisory rc and preserves exact recovery evidence"
else
  fail_msg "subdirectory setup-cleanup failure returns supervisory rc and preserves exact recovery evidence" "$cleanup_failure_errors"
fi
git -C "$SETUP_FAILURE_TMP/repo" worktree remove --force "$cleanup_relative"
git -C "$SETUP_FAILURE_TMP/repo" branch -D "$cleanup_branch" >/dev/null
cleanup_token="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"],end="")' "$cleanup_status.worktree-owner.json")"
retire_preserved_fixture "$SETUP_FAILURE_TMP/repo" "$cleanup_relative" "$cleanup_branch" \
  "$cleanup_status.worktree-owner.json" "$cleanup_token"
rm -rf "$SETUP_FAILURE_TMP"

echo "== Codex supervisor PID-capture failure is fully unwound =="
PID_CAPTURE_TMP="$(canonical_test_path "$(mktemp -d)")" || exit 1
mkdir -p "$PID_CAPTURE_TMP/repo" "$PID_CAPTURE_TMP/run" "$PID_CAPTURE_TMP/bin" "$PID_CAPTURE_TMP/tmp"
chmod 700 "$PID_CAPTURE_TMP/run" "$PID_CAPTURE_TMP/tmp"
(
  cd "$PID_CAPTURE_TMP/repo"
  git init -q
  git config user.name 'UberDev Test'
  git config user.email 'uberdev-test@example.invalid'
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm base
)
printf 'pid capture prompt\n' >"$PID_CAPTURE_TMP/run/prompt.txt"
cat >"$PID_CAPTURE_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$PID_CAPTURE_PROVIDER_PID_FILE"
trap 'exit 143' HUP INT TERM
while :; do sleep 1; done
SH
chmod +x "$PID_CAPTURE_TMP/bin/codex"
pid_capture_emergency_cleanup() {
  local provider_pid attempts=0
  provider_pid="$(cat "$PID_CAPTURE_TMP/provider.pid" 2>/dev/null)"
  case "$provider_pid" in ''|*[!0-9]*|0) return 0 ;; esac
  kill -0 "$provider_pid" 2>/dev/null || return 0
  kill -TERM "$provider_pid" 2>/dev/null || true
  while kill -0 "$provider_pid" 2>/dev/null && [ "$attempts" -lt 40 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if kill -0 "$provider_pid" 2>/dev/null; then
    kill -KILL "$provider_pid" 2>/dev/null || true
    attempts=0
    while kill -0 "$provider_pid" 2>/dev/null && [ "$attempts" -lt 40 ]; do
      sleep 0.05
      attempts=$((attempts + 1))
    done
  fi
  ! kill -0 "$provider_pid" 2>/dev/null
}
PID_CAPTURE_NUMERIC_SUPPORTED=0
if bash -c '. "$1"; _uberdev_dispatch_numeric_supervision_supported codex' \
    _ "$DISPATCH_LIB"; then
  PID_CAPTURE_NUMERIC_SUPPORTED=1
fi
if [ "$PID_CAPTURE_NUMERIC_SUPPORTED" -eq 0 ]; then
  # Native Windows numeric backends are rejected by the public preflight
  # because the adapter cannot yet prove process-tree cancellation there.
  # Do not bypass that contract and then require the unsupported cancellation
  # layer to unwind the detached test provider.
  PID_CAPTURE_UNSUPPORTED_ERRORS=''
  if PID_CAPTURE_PREFLIGHT_OUT="$(
    cd "$PID_CAPTURE_TMP/repo"
    PATH="$PID_CAPTURE_TMP/bin:$PATH" UBERDEV_DISPATCH_BACKEND_REQUESTED=codex \
      bash -c '
        . "$1"
        unset UBERDEV_RESOLVED_BACKEND
        ! uberdev_dispatch_preflight review-pr || exit 1
        [ -z "${UBERDEV_RESOLVED_BACKEND+x}" ]
      ' _ "$DISPATCH_LIB" 2>&1
  )"; then
    printf '%s\n' "$PID_CAPTURE_PREFLIGHT_OUT" | grep -Fq \
      "lacks verifiable process-tree supervision on native Windows" \
      || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS preflight-reason"
  else
    PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS preflight"
  fi
  [ ! -e "$PID_CAPTURE_TMP/provider.pid" ] || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS provider"
  [ ! -e "$PID_CAPTURE_TMP/run/status.json" ] || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS status"
  [ ! -e "$PID_CAPTURE_TMP/run/result.md" ] || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS result"
  [ ! -e "$PID_CAPTURE_TMP/run/status.json.worktree-owner.json" ] \
    || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS receipt"
  PID_CAPTURE_STATE_GLOB=( "$PID_CAPTURE_TMP/run"/.agent-state-* )
  [ ! -e "${PID_CAPTURE_STATE_GLOB[0]}" ] || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS lifecycle"
  [ ! -d "$PID_CAPTURE_TMP/repo/.claude/worktrees" ] \
    || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS worktree"
  git -C "$PID_CAPTURE_TMP/repo" show-ref | grep -Fq 'refs/heads/worktree-solve-issue-335-' \
    && PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS branch"
  pid_capture_emergency_cleanup \
    || PID_CAPTURE_UNSUPPORTED_ERRORS="$PID_CAPTURE_UNSUPPORTED_ERRORS emergency-cleanup"
  if [ -z "$PID_CAPTURE_UNSUPPORTED_ERRORS" ]; then
    pass_msg "native Windows rejects unsupported Codex supervision before launch"
  else
    fail_msg "native Windows rejects unsupported Codex supervision before launch" \
      "$PID_CAPTURE_UNSUPPORTED_ERRORS $PID_CAPTURE_PREFLIGHT_OUT"
  fi
else
PID_CAPTURE_REQUEST="$(python3 -I -B - "$PID_CAPTURE_TMP/run" "$PID_CAPTURE_TMP/repo" <<'PY'
import json,sys
run,repo=sys.argv[1:]
print(json.dumps({
 'schema_version':1,'run_dir':run,'run_id':'codex-pid-capture-failure',
 'repository_id':repo,'backend':'codex','workflow':'review-pr','phase':'review',
 'role':'code-reviewer','task_tier':'small','risk_signals':[],
 'routing_mode':'inherit','issue_or_pr':335,'issue_num':335,'capacity':1,
 'timeout_s':30,'workspace_mode':'isolated'
},sort_keys=True,separators=(',',':')))
PY
)"
PID_CAPTURE_INSTANCE=codex-pid-capture-failure
PID_CAPTURE_SLUG="$(UBERDEV_AGENT_INSTANCE_ID="$PID_CAPTURE_INSTANCE" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
PID_CAPTURE_OUT="$(
  cd "$PID_CAPTURE_TMP/repo"
  PATH="$PID_CAPTURE_TMP/bin:$PATH" UBERDEV_TMPDIR="$PID_CAPTURE_TMP/tmp" \
    PID_CAPTURE_PROVIDER_PID_FILE="$PID_CAPTURE_TMP/provider.pid" \
    bash -c '
      . "$1"
      _uberdev_agent_dispatch_backend() {
        UBERDEV_AGENT_ROUTING_MODE=inherit
        UBERDEV_AGENT_EFFECTIVE_POLICY=inherit
        UBERDEV_AGENT_ROUTE_MODEL=
        UBERDEV_AGENT_ROUTE_EFFORT=
        UBERDEV_AGENT_SERVICE_TIER=default
        UBERDEV_AGENT_SANDBOX=workspace-write
        UBERDEV_AGENT_RESULT_FILE="$5"
        UBERDEV_AGENT_STATUS_FILE="$6"
        UBERDEV_AGENT_CHILD_OWNED=1
        export UBERDEV_AGENT_ROUTING_MODE UBERDEV_AGENT_EFFECTIVE_POLICY UBERDEV_AGENT_ROUTE_MODEL UBERDEV_AGENT_ROUTE_EFFORT
        export UBERDEV_AGENT_SERVICE_TIER UBERDEV_AGENT_SANDBOX UBERDEV_AGENT_RESULT_FILE UBERDEV_AGENT_STATUS_FILE UBERDEV_AGENT_CHILD_OWNED
        _uberdev_dispatch_codex "$2" "$3" "$4"
      }
      _uberdev_dispatch_capture_supervisor_pid() {
        i=0
        while [ ! -s "$PID_CAPTURE_PROVIDER_PID_FILE" ] && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
        [ -s "$PID_CAPTURE_PROVIDER_PID_FILE" ] || return 2
        return 1
      }
      set +e
      uberdev_agent_dispatch "$2" "$3/prompt.txt" "$3/result.md" "$3/status.json"
      rc=$?
      set -e
      provider_pid="$(cat "$PID_CAPTURE_PROVIDER_PID_FILE" 2>/dev/null)"
      provider_live=0
      if [ -n "$provider_pid" ] && kill -0 "$provider_pid" 2>/dev/null; then provider_live=1; fi
      printf "rc=%s\\nprovider_pid=%s\\nprovider_live=%s\\nstatus=%s\\n" \
        "$rc" "$provider_pid" "$provider_live" "$(cat "$3/status.json" 2>/dev/null)"
    ' _ "$DISPATCH_LIB" "$PID_CAPTURE_REQUEST" "$PID_CAPTURE_TMP/run"
)"
PID_CAPTURE_ERRORS=''
PID_CAPTURE_STATE_DIR=''
PID_CAPTURE_STATE_DIR="$(bash -c '. "$1"; _uberdev_agent_prepare_state_dir "$2"' \
  _ "$DISPATCH_LIB" "$PID_CAPTURE_TMP/run")" \
  || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS state-dir"
pid_capture_emergency_cleanup || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS emergency-cleanup"
printf '%s\n' "$PID_CAPTURE_OUT" | grep -Fq 'rc=2' || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS rc"
printf '%s\n' "$PID_CAPTURE_OUT" | grep -Fq 'provider_live=0' || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS provider-live"
printf '%s\n' "$PID_CAPTURE_OUT" | grep -Fq '"state":"cancelled"' || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS terminal-status"
[ ! -e "$PID_CAPTURE_TMP/repo/.claude/worktrees/solve-issue-335-$PID_CAPTURE_SLUG" ] || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS worktree"
git -C "$PID_CAPTURE_TMP/repo" show-ref --verify --quiet "refs/heads/worktree-solve-issue-335-$PID_CAPTURE_SLUG" \
  && PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS branch"
[ ! -e "$PID_CAPTURE_TMP/run/status.json.worktree-owner.json" ] || PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS receipt"
grep -R -q 'run_id=codex-pid-capture-failure' "$PID_CAPTURE_STATE_DIR/semaphore-v1" 2>/dev/null \
  && PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS lease"
if ! python3 -I -B - "$PID_CAPTURE_STATE_DIR/agent-lifecycle.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8')]
events=[row for row in rows if row.get('run_id')=='codex-pid-capture-failure']
assert [row.get('event') for row in events]==['route_decided','agent_started','cancelled'],events
PY
then
  PID_CAPTURE_ERRORS="$PID_CAPTURE_ERRORS lifecycle"
fi
if [ -z "$PID_CAPTURE_ERRORS" ]; then
  pass_msg "PID-capture failure cancels the provider, emits terminal lifecycle, releases the exact lease, and removes child artifacts"
else
  fail_msg "PID-capture failure is fully supervised" "$PID_CAPTURE_ERRORS $PID_CAPTURE_OUT"
fi
fi
rm -rf "$PID_CAPTURE_TMP"

echo "== Caller workspace mode commits in place without cleanup ownership =="
CALLER_TMP="$(mktemp -d)"
mkdir -p "$CALLER_TMP/bin" "$CALLER_TMP/repo" "$CALLER_TMP/runtime"
chmod 700 "$CALLER_TMP/runtime"
(
  cd "$CALLER_TMP/repo"
  git init -q
  git config user.name 'UberDev Test'
  git config user.email 'uberdev-test@example.invalid'
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm base
)
CALLER_BEFORE="$(git -C "$CALLER_TMP/repo" rev-parse HEAD)"
CALLER_GIT="$(command -v git)"
cat > "$CALLER_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
cat >/dev/null
printf 'caller child\n' > caller.txt
"$CALLER_GIT" add caller.txt
"$CALLER_GIT" commit -qm 'test: caller child commit'
printf 'caller result\n' > "$out"
SH
chmod +x "$CALLER_TMP/bin/codex"
printf 'caller prompt\n' > "$CALLER_TMP/prompt.txt"
CALLER_STATUS="$CALLER_TMP/runtime/caller-status.json"
(
  cd "$CALLER_TMP/repo"
  PATH="$CALLER_TMP/bin:/usr/bin:/bin" CALLER_GIT="$CALLER_GIT" \
    UBERDEV_AGENT_STATUS_FILE="$CALLER_STATUS" \
    UBERDEV_AGENT_RESULT_FILE="$CALLER_TMP/runtime/caller-result.md" \
    UBERDEV_AGENT_WORKSPACE_MODE=caller UBERDEV_AGENT_WORKSPACE_DIR="$CALLER_TMP/repo" \
    UBERDEV_AGENT_CHILD_OWNED=1 \
    bash -c '. "$1"; _uberdev_dispatch_codex 335 small "$2"; i=0; while [ "$i" -lt 400 ]; do status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"; case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac; sleep 0.025; i=$((i+1)); done' \
      _ "$DISPATCH_LIB" "$CALLER_TMP/prompt.txt"
)
CALLER_AFTER="$(git -C "$CALLER_TMP/repo" rev-parse HEAD)"
caller_failures=''
[ "$CALLER_BEFORE" != "$CALLER_AFTER" ] || caller_failures="$caller_failures no-commit"
[ -f "$CALLER_TMP/repo/caller.txt" ] || caller_failures="$caller_failures missing-file"
[ "$(git -C "$CALLER_TMP/repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] || caller_failures="$caller_failures child-worktree"
[ ! -e "$CALLER_STATUS.worktree-owner.json" ] || caller_failures="$caller_failures ownership-receipt"
[ -d "$CALLER_TMP/repo" ] || caller_failures="$caller_failures caller-cleaned"
python3 -I - "$CALLER_STATUS" "$CALLER_TMP/repo" <<'PY' || caller_failures="$caller_failures bad-status"
import json,os,pathlib,sys
status=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['state']=='completed' and status['workspace_mode']=='caller'
assert os.path.samefile(status['worktree'],sys.argv[2])
assert status['branch']=='' and os.path.samefile(status['log'],sys.argv[1]+'.log')
PY
if [ -z "$caller_failures" ]; then
  pass_msg "caller mode advances the caller branch without child worktree, branch, receipt, or cleanup"
else
  fail_msg "caller mode advances the caller branch without child worktree, branch, receipt, or cleanup" "$caller_failures $(cat "$CALLER_STATUS" 2>/dev/null)"
fi
rm -rf "$CALLER_TMP"

echo "== Codex packaged runtime mirrors source libs =="
if cmp -s "$DISPATCH_LIB" "$CODEX_DISPATCH_LIB"; then
  pass_msg "packaged Codex dispatch.sh is byte-identical to source runtime lib"
else
  fail_msg "packaged Codex dispatch.sh drifted from source runtime lib"
fi
if cmp -s "$AGENT_DISPATCH_LIB" "$CODEX_AGENT_DISPATCH_LIB"; then
  pass_msg "packaged Codex agent-dispatch.sh is byte-identical to source runtime lib"
else
  fail_msg "packaged Codex agent-dispatch.sh drifted from source runtime lib"
fi
if cmp -s "$GOAL_LIB" "$CODEX_GOAL_LIB"; then
  pass_msg "packaged Codex goal-state.sh is byte-identical to source runtime lib"
else
  fail_msg "packaged Codex goal-state.sh drifted from source runtime lib"
fi
if [ -r "$CODEX_CONFIG_LIB" ]; then
  pass_msg "packaged Codex config-read.sh exists for workflow-args runtime"
else
  fail_msg "packaged Codex config-read.sh missing"
fi
for relative in lib/config-read.sh lib/model_routing.py lib/run_manifest.py lib/live-semaphore.sh policy/model-routing-v1.json; do
  if cmp -s "$REPO_ROOT/plugins/uberdev/$relative" "$PLUGIN_ROOT/$relative"; then
    pass_msg "packaged Codex $relative is byte-identical to canonical runtime"
  else
    fail_msg "packaged Codex $relative drifted from canonical runtime"
  fi
done

PACKAGE_TMP="$(mktemp -d)"
cp -R "$PLUGIN_ROOT" "$PACKAGE_TMP/uberdev-codex"
mkdir -p "$PACKAGE_TMP/home" "$PACKAGE_TMP/codex-home" "$PACKAGE_TMP/outside"
PACKAGE_SMOKE_LOG="$PACKAGE_TMP/smoke.log"
if HOME="$PACKAGE_TMP/home" CODEX_HOME="$PACKAGE_TMP/codex-home" PWD="$PACKAGE_TMP" \
  REPO_SENTINEL="$REPO_ROOT" PACKAGE_COPY="$PACKAGE_TMP/uberdev-codex" OUTSIDE_DIR="$PACKAGE_TMP/outside" \
  INHERIT_REQUEST='{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"inherit"}' \
  ADAPTIVE_REQUEST='{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"adaptive"}' \
  bash -c '
    set -euo pipefail
    cd "$OUTSIDE_DIR"
    . "$PACKAGE_COPY/lib/dispatch.sh"
    command -v uberdev_read_model_routing >/dev/null
    uberdev_read_model_routing
    [ "$UBERDEV_ROUTING_MODE" = inherit ]
    inherit=$(uberdev_agent_resolve_request "$INHERIT_REQUEST")
    adaptive=$(uberdev_agent_resolve_request "$ADAPTIVE_REQUEST")
    python3 -I - "$inherit" "$adaptive" "$PACKAGE_COPY" "$REPO_SENTINEL" <<'''PY'''
import json, pathlib, sys
inherit, adaptive = map(json.loads, sys.argv[1:3])
assert inherit["model"] is None and inherit["reasoning_effort"] is None
assert adaptive["logical_route"] == "frontier" and adaptive["reasoning_effort"] == "max"
package, repo = map(pathlib.Path, sys.argv[3:5])
assert package.resolve() != repo.resolve()
PY
    case "$_UBERDEV_AGENT_ROUTER:$_UBERDEV_AGENT_POLICY:$_UBERDEV_AGENT_MANIFEST_TOOL" in *"$REPO_SENTINEL"*) exit 9 ;; esac
  ' >"$PACKAGE_SMOKE_LOG" 2>&1; then
  pass_msg "clean copied Codex package is a self-contained routing runtime"
else
  fail_msg "clean copied Codex package is a self-contained routing runtime" "$(tail -20 "$PACKAGE_SMOKE_LOG")"
fi
rm -rf "$PACKAGE_TMP"

echo "== Enum + probe =="
assert_grep "$DISPATCH_LIB" \
  'auto\|claude-bg\|wezterm\|background\|codex' \
  "backend enum includes codex"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_codex_available\(\)' \
  "codex availability probe is defined"
assert_grep "$DISPATCH_LIB" \
  'command -v codex' \
  "codex probe checks the codex binary on PATH"

echo "== Preflight resolves codex =="
assert_grep "$DISPATCH_LIB" \
  'resolved="codex"; reason="explicit"' \
  "preflight accepts explicit --backend=codex"
assert_grep "$DISPATCH_LIB" \
  'auto-codex-env' \
  "preflight auto-resolves codex when CODEX_HOME is set"
assert_grep "$DISPATCH_LIB" \
  'auto-no-claude' \
  "preflight auto-resolves codex when claude is absent but codex present"

CODEX_MISSING_OUT="$(mktemp)"
if CODEX_HOME=/tmp/codex-home PATH=/usr/bin:/bin UBERDEV_DISPATCH_BACKEND_REQUESTED=auto bash -c \
  '. "$1"; uberdev_dispatch_preflight' _ "$DISPATCH_LIB" >"$CODEX_MISSING_OUT" 2>&1; then
  fail_msg "auto preflight fails loudly when CODEX_HOME is set but codex is absent" "preflight returned success"
elif [ "$PID_CAPTURE_NUMERIC_SUPPORTED" -eq 0 ] \
    && grep -q "native Windows requires WezTerm" "$CODEX_MISSING_OUT"; then
  pass_msg "auto preflight fails on the native-Windows supervision capability gate"
elif [ "$PID_CAPTURE_NUMERIC_SUPPORTED" -eq 1 ] \
    && grep -q "CODEX_HOME" "$CODEX_MISSING_OUT" \
    && grep -q "codex" "$CODEX_MISSING_OUT"; then
  pass_msg "auto preflight fails loudly when CODEX_HOME is set but codex is absent"
else
  fail_msg "auto preflight failure matches the host supervision capability" "$(cat "$CODEX_MISSING_OUT")"
fi
rm -f "$CODEX_MISSING_OUT"

echo "== dispatch_one routes codex =="
assert_grep "$DISPATCH_LIB" \
  'codex\)[[:space:]]+_uberdev_dispatch_codex' \
  "dispatch_one switch routes codex to _uberdev_dispatch_codex"

echo "== _uberdev_dispatch_codex mechanism (mirrors background, execs codex) =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_codex\(\)' \
  "_uberdev_dispatch_codex function is defined"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_git_worktree_add "\$REPOSITORY_ROOT"' \
  "codex backend serializes every isolated worktree add through the repository mutex"
CODEX_DISPATCH_BODY="$(extract_function_body _uberdev_dispatch_codex "$DISPATCH_LIB")"
if printf '%s\n' "$CODEX_DISPATCH_BODY" | grep -Fq 'MSYS_NO_PATHCONV=1 git worktree add'; then
  fail_msg "codex backend has no direct non-child worktree-add bypass" \
    "_uberdev_dispatch_codex still invokes git worktree add directly"
else
  pass_msg "codex backend has no direct non-child worktree-add bypass"
fi
assert_grep "$DISPATCH_LIB" \
  'codex --ask-for-approval never exec' \
  "codex backend launches headless codex exec with top-level approval policy (NOT claude -p)"
assert_grep "$DISPATCH_LIB" \
  '--sandbox workspace-write' \
  "codex backend passes --sandbox workspace-write for autonomous edits"
assert_grep_not "$DISPATCH_LIB" \
  'codex exec[[:space:]]+\\?[[:space:]]*--ask-for-approval' \
  "codex backend does not pass top-level-only approval policy after exec"
assert_grep "$DISPATCH_LIB" \
  '--json' \
  "codex backend passes --json for progress streaming"
assert_grep "$DISPATCH_LIB" \
  'model_reasoning_effort=' \
  "codex backend can pass an explicit reasoning effort override"
assert_grep "$DISPATCH_LIB" \
  'service_tier=' \
  "codex backend always passes the independently resolved service tier"
assert_grep "$DISPATCH_LIB" \
  'features\.multi_agent=false' \
  "codex leaf dispatch disables descendant multi-agent fanout"
assert_grep_not "$DISPATCH_LIB" \
  'agents\.max_depth=0' \
  "codex leaf dispatch avoids the invalid zero-depth override"
assert_grep "$DISPATCH_LIB" \
  '< "\$PROMPT_FILE"' \
  "codex backend redirects the validated prompt file to stdin"
assert_grep "$DISPATCH_LIB" \
  'nohup' \
  "codex backend detaches via nohup (same as background)"
assert_grep "$DISPATCH_LIB" \
  'disown' \
  "codex backend disowns the detached process"
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_prepare_tmp_target "\$RESULT_FILE" "\$ISSUE_NUM" "codex"' \
  "codex backend guards the predictable result file before passing it to codex exec"
assert_grep "$DISPATCH_LIB" \
  'write_status running null' \
  "codex backend wrapper records running state before launching codex"
assert_grep "$DISPATCH_LIB" \
  'write_status "\$CODEX_STATE" "\$CODEX_RC"' \
  "codex wrapper records codex exec exit code in the status file"
assert_grep "$AGENT_DISPATCH_LIB" \
  "tempfile\.mkstemp\(prefix='\.agent-status\.',dir=parent\)" \
  "shared status writer stages status JSON in the destination directory"
assert_grep "$AGENT_DISPATCH_LIB" \
  'os\.replace\(temporary,path\)' \
  "shared status writer publishes status JSON atomically"
if grep -Fq '_uberdev_agent_publish_status_record "$STATUS_FILE" provider codex' "$DISPATCH_LIB" \
   && grep -Fq '\"backend\":\"codex\"' "$DISPATCH_LIB"; then
  pass_msg "codex backend status-file + audit payload carries backend=codex"
else
  fail_msg "codex backend status-file + audit payload carries backend=codex"
fi
assert_grep "$DISPATCH_LIB" \
  'WRAPPER_PID="\$\{UBERDEV_WRAPPER_PID:-\$\$\}"' \
  "codex wrapper status uses the detached supervisor PID with a shell-PID fallback"

echo "== Codex backend does NOT thread claude-specific flags =="
CODEX_BODY="$(extract_function_body '_uberdev_dispatch_codex' "$DISPATCH_LIB")"
if printf '%s\n' "$CODEX_BODY" | grep -qE '\<(PERM_FLAG|EFFORT_FLAG|claude -p)\>'; then
  fail_msg "codex backend body does not reference Claude-only flags or claude -p" \
    "$(printf '%s\n' "$CODEX_BODY" | grep -nE '\<(PERM_FLAG|EFFORT_FLAG|claude -p)\>')"
else
  pass_msg "codex backend body does not reference Claude-only flags or claude -p"
fi
if printf '%s\n' "$CODEX_BODY" | grep -qF 'WRAPPER_PID="${UBERDEV_WRAPPER_PID:-$$}"' \
   && ! printf '%s\n' "$CODEX_BODY" | grep -qF 'kill -0 "$DISPATCH_ID"'; then
  pass_msg "codex backend status contract tracks the detached supervisor instead of parent-side liveness probing"
else
  fail_msg "codex backend status contract tracks the detached supervisor instead of parent-side liveness probing"
fi

echo "== goal-state backend-awareness =="
assert_grep "$GOAL_LIB" \
  'claude-bg\|wezterm\|background\|codex' \
  "goal-state UBERDEV_RESOLVED_BACKEND allowlist includes codex"
assert_grep "$GOAL_LIB" \
  'terminal completed/failed states return "not busy"' \
  "goal-state codex solver liveness treats terminal statuses as not busy"
assert_grep "$GOAL_LIB" \
  'solve-codex-status-\$n\.json' \
  "goal-state codex solver liveness reads solve-codex-status-N.json"
CODEX_STATUS_BODY="$(extract_function_body 'uberdev_goal_codex_status_for_issue' "$GOAL_LIB")"
if printf '%s\n' "$CODEX_STATUS_BODY" | awk '
  /unreadable Codex status file for issue/ {seen=1}
  seen && /^[[:space:]]*return[[:space:]]+2([[:space:]]*(#.*)?)?$/ {found=1; exit}
  seen && /^  fi$/ && !found {exit}
  END {exit found ? 0 : 1}
'; then
  pass_msg "goal-state codex status helper fails closed on unreadable non-empty status files"
else
  fail_msg "goal-state codex status helper fails closed on unreadable non-empty status files"
fi

echo "== solve-launcher backend-conditional version gate =="
assert_grep "$LAUNCHER" \
  'UBERDEV_RESOLVED_BACKEND.*codex' \
  "solve-launcher gates on the resolved backend being codex"
assert_grep "$LAUNCHER" \
  'command -v codex' \
  "solve-launcher requires codex CLI when codex backend resolved"
assert_grep "$LAUNCHER" \
  'PLUGIN_ROOT' \
  "solve-launcher sources dispatch.sh via PLUGIN_ROOT (Codex) fallback"
assert_grep "$LAUNCHER" \
  'solve-codex-stdout-\$ISSUE_NUM\.log' \
  "solve-launcher prints codex log path in final summary"
assert_grep "$LAUNCHER" \
  'solve-codex-result-\$ISSUE_NUM\.md' \
  "solve-launcher prints codex result path in final summary"

echo "== Codex backend does not require timeout/gtimeout =="
NO_TIMEOUT_BIN="$(mktemp -d)"
cat > "$NO_TIMEOUT_BIN/codex" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$NO_TIMEOUT_BIN/codex"
if UBERDEV_RESOLVED_BACKEND=codex PATH="$NO_TIMEOUT_BIN" /bin/bash -c \
  '. "$1"; uberdev_dispatch_resolve_env codex' _ "$DISPATCH_LIB" >/tmp/codex-no-timeout-out 2>&1; then
  pass_msg "codex dispatch env resolution skips timeout/gtimeout requirement"
else
  fail_msg "codex dispatch env resolution skips timeout/gtimeout requirement" "$(cat /tmp/codex-no-timeout-out)"
fi
rm -rf "$NO_TIMEOUT_BIN"

echo "== Public launcher parser accepts codex =="
PARSER_OUT="$(mktemp)"
if bash "$LAUNCHER" --auto-mode=0 -- --backend=codex >"$PARSER_OUT" 2>&1; then
  echo "  FAIL  parser-only invocation should exit with usage when no issue is supplied"; FAIL=$((FAIL + 1))
elif grep -q "not in {auto,claude-bg,wezterm,background" "$PARSER_OUT"; then
  echo "  FAIL  public launcher rejected --backend=codex"; cat "$PARSER_OUT"; FAIL=$((FAIL + 1))
elif grep -q "routing_cli_invalid_issue" "$PARSER_OUT"; then
  echo "  PASS  public launcher parser accepts --backend=codex and then rejects the missing issue"; PASS=$((PASS + 1))
else
  echo "  FAIL  public launcher parser produced unexpected output"; cat "$PARSER_OUT"; FAIL=$((FAIL + 1))
fi
rm -f "$PARSER_OUT"

echo "== goal-state reads codex status files =="
TMPD="$(mktemp -d)"
printf '%s\n' '{"issue":42,"backend":"codex","pid":"999999"}' > "$TMPD/solve-codex-status-42.json"
PID_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
if [ "$PID_OUT" = "999999" ]; then
  echo "  PASS  goal-state PID helper reads solve-codex-status-N.json for codex backend"; PASS=$((PASS + 1))
else
  echo "  FAIL  goal-state PID helper did not read codex status file (got '$PID_OUT')"; FAIL=$((FAIL + 1))
fi

printf '%s\n' '{"issue":42,"backend":"codex","pid":"0"}' > "$TMPD/solve-codex-status-42.json"
PID_ZERO_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null || true
)"
if [ -z "$PID_ZERO_OUT" ]; then
  pass_msg "goal-state PID helper refuses pid 0"
else
  fail_msg "goal-state PID helper refuses pid 0" "got '$PID_ZERO_OUT'"
fi

rm -f "$TMPD/solve-codex-status-42.json"
printf '%s\n' '{"issue":42,"backend":"background","pid":"111111"}' > "$TMPD/solve-bg-status-42.json"
PID_FALLBACK_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null || true
)"
if [ -z "$PID_FALLBACK_OUT" ]; then
  pass_msg "goal-state PID helper refuses cross-backend fallback status files"
else
  fail_msg "goal-state PID helper refuses cross-backend fallback status files" "got '$PID_FALLBACK_OUT'"
fi

printf '%s\n' '{"issue":42,"backend":"background","pid":"222222"}' > "$TMPD/solve-codex-status-42.json"
PID_BACKEND_MISMATCH_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; _uberdev_goal_pid_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null || true
)"
if [ -z "$PID_BACKEND_MISMATCH_OUT" ]; then
  pass_msg "goal-state PID helper validates backend field before trusting pid"
else
  fail_msg "goal-state PID helper validates backend field before trusting pid" "got '$PID_BACKEND_MISMATCH_OUT'"
fi
printf '%s\n' '{"issue":42,"backend":"codex","state":"failed","exit_code":17,"pid":"222222","log":"/tmp/log","result":"/tmp/result"}' > "$TMPD/solve-codex-status-42.json"
CODEX_STATUS_OUT="$(
  UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; uberdev_goal_codex_status_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" 2>/dev/null
)"
case "$CODEX_STATUS_OUT" in
  failed$'\t'17$'\t'/tmp/log$'\t'/tmp/result)
    pass_msg "goal-state exposes terminal codex failed status with exit/log/result" ;;
  *)
    fail_msg "goal-state exposes terminal codex failed status with exit/log/result" "got '$CODEX_STATUS_OUT'" ;;
esac
rm -f "$TMPD/solve-codex-status-42.json"
CODEX_MISSING_STATUS_OUT="/tmp/uberdev-codex-missing-status-out.$$"
CODEX_MISSING_STATUS_ERR="/tmp/uberdev-codex-missing-status-err.$$"
if UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; uberdev_goal_codex_status_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" >"$CODEX_MISSING_STATUS_OUT" 2>"$CODEX_MISSING_STATUS_ERR"; then
  fail_msg "goal-state treats missing codex status as not ready" "unexpected success: $(cat "$CODEX_MISSING_STATUS_OUT")"
else
  CODEX_MISSING_STATUS_RC=$?
  if [ "$CODEX_MISSING_STATUS_RC" -eq 1 ] \
    && [ ! -s "$CODEX_MISSING_STATUS_OUT" ] \
    && [ ! -s "$CODEX_MISSING_STATUS_ERR" ]; then
    pass_msg "goal-state treats missing codex status as not ready"
  else
    fail_msg "goal-state treats missing codex status as not ready" \
      "rc=$CODEX_MISSING_STATUS_RC out=$(cat "$CODEX_MISSING_STATUS_OUT") err=$(cat "$CODEX_MISSING_STATUS_ERR")"
  fi
fi
rm -f "$CODEX_MISSING_STATUS_OUT" "$CODEX_MISSING_STATUS_ERR"
: > "$TMPD/solve-codex-status-42.json"
CODEX_EMPTY_STATUS_OUT="/tmp/uberdev-codex-empty-status-out.$$"
CODEX_EMPTY_STATUS_ERR="/tmp/uberdev-codex-empty-status-err.$$"
if UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
    '. "$1"; . "$2"; uberdev_goal_codex_status_for_issue 42' \
    _ "$DISPATCH_LIB" "$GOAL_LIB" >"$CODEX_EMPTY_STATUS_OUT" 2>"$CODEX_EMPTY_STATUS_ERR"; then
  fail_msg "goal-state treats zero-byte codex status as not ready" "unexpected success: $(cat "$CODEX_EMPTY_STATUS_OUT")"
else
  CODEX_EMPTY_STATUS_RC=$?
  if [ "$CODEX_EMPTY_STATUS_RC" -eq 1 ] \
    && [ ! -s "$CODEX_EMPTY_STATUS_OUT" ] \
    && [ ! -s "$CODEX_EMPTY_STATUS_ERR" ]; then
    pass_msg "goal-state treats zero-byte codex status as not ready"
  else
    fail_msg "goal-state treats zero-byte codex status as not ready" \
      "rc=$CODEX_EMPTY_STATUS_RC out=$(cat "$CODEX_EMPTY_STATUS_OUT") err=$(cat "$CODEX_EMPTY_STATUS_ERR")"
  fi
fi
rm -f "$CODEX_EMPTY_STATUS_OUT" "$CODEX_EMPTY_STATUS_ERR"
printf '%s\n' '{"issue":42,"backend":"codex","state":"failed","exit_code":17,"pid":"222222","log":"/tmp/log","result":"/tmp/result"}' > "$TMPD/solve-codex-status-42.json"
chmod 000 "$TMPD/solve-codex-status-42.json"
if [ -r "$TMPD/solve-codex-status-42.json" ]; then
  chmod 600 "$TMPD/solve-codex-status-42.json"
  pass_msg "goal-state unreadable-status runtime fixture skipped when chmod cannot remove readability"
else
  CODEX_UNREADABLE_STATUS_OUT="/tmp/uberdev-codex-unreadable-status-out.$$"
  CODEX_UNREADABLE_STATUS_ERR="/tmp/uberdev-codex-unreadable-status-err.$$"
  if UBERDEV_TMPDIR="$TMPD" UBERDEV_RESOLVED_BACKEND=codex bash -c \
      '. "$1"; . "$2"; uberdev_goal_codex_status_for_issue 42' \
      _ "$DISPATCH_LIB" "$GOAL_LIB" >"$CODEX_UNREADABLE_STATUS_OUT" 2>"$CODEX_UNREADABLE_STATUS_ERR"; then
    chmod 600 "$TMPD/solve-codex-status-42.json"
    fail_msg "goal-state treats unreadable non-empty codex status as invalid" "unexpected success: $(cat "$CODEX_UNREADABLE_STATUS_OUT")"
  else
    CODEX_UNREADABLE_STATUS_RC=$?
    chmod 600 "$TMPD/solve-codex-status-42.json"
    if [ "$CODEX_UNREADABLE_STATUS_RC" -eq 2 ] \
      && [ ! -s "$CODEX_UNREADABLE_STATUS_OUT" ] \
      && grep -q 'unreadable Codex status file for issue 42' "$CODEX_UNREADABLE_STATUS_ERR"; then
      pass_msg "goal-state treats unreadable non-empty codex status as invalid"
    else
      fail_msg "goal-state treats unreadable non-empty codex status as invalid" \
        "rc=$CODEX_UNREADABLE_STATUS_RC out=$(cat "$CODEX_UNREADABLE_STATUS_OUT") err=$(cat "$CODEX_UNREADABLE_STATUS_ERR")"
    fi
  fi
  rm -f "$CODEX_UNREADABLE_STATUS_OUT" "$CODEX_UNREADABLE_STATUS_ERR"
fi
rm -rf "$TMPD"

echo "== _uberdev_dispatch_codex behavior with real git and stubbed codex =="
BEH_TMP="$(canonical_test_path "$(mktemp -d)")" || exit 1
mkdir -p "$BEH_TMP/bin" "$BEH_TMP/repo" "$BEH_TMP/tmp"
chmod 700 "$BEH_TMP/tmp"
BEH_GIT="$(command -v git)"
BEH_GIT_DIR="$(dirname "$BEH_GIT")"
(
  cd "$BEH_TMP/repo"
  "$BEH_GIT" init -q
  "$BEH_GIT" config user.name 'UberDev Test'
  "$BEH_GIT" config user.email 'uberdev-test@example.invalid'
  printf 'base\n' > base.txt
  "$BEH_GIT" add base.txt
  "$BEH_GIT" commit -qm base
)
cat > "$BEH_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
if /usr/bin/env | /usr/bin/grep -Eq '^BASH_FUNC_(python3|run_python)%%='; then
  printf 'exported-python-bridge\n' >> "$CODEX_CAPTURE"
  exit 98
fi
{
  printf 'argv:'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\nUBERDEV_TURBO=%s\n' "${UBERDEV_TURBO:-}"
} >> "$CODEX_CAPTURE"
IFS= read -r stdin_body || true
printf 'stdin=%s\n' "$stdin_body" >> "$CODEX_CAPTURE"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sleep "${CODEX_STUB_SLEEP:-1}"
[ "${CODEX_STUB_DIRTY:-0}" != 1 ] || printf 'preserve cleanup evidence\n' > codex-dirty.txt
[ "${CODEX_STUB_EMPTY:-0}" = 1 ] || { [ -n "$out" ] && printf 'codex final result\n' > "$out"; }
exit "${CODEX_STUB_RC:-0}"
SH
chmod +x "$BEH_TMP/bin/codex"
cat > "$BEH_TMP/bin/py" <<SH
#!/bin/sh
[ "\$1" = -3 ] || exit 97
shift
if [ -n "$_UBERDEV_PYTHON_PREFIX" ]; then
  exec "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "\$@"
else
  exec "$_UBERDEV_PYTHON_EXE" "\$@"
fi
SH
chmod +x "$BEH_TMP/bin/py"
for runtime_command in env nohup cat sleep rm uname grep stat id ps basename dirname mkdir; do
  ln -s "$(command -v "$runtime_command")" "$BEH_TMP/bin/$runtime_command"
done
BEH_RUNTIME_PATH="$BEH_TMP/bin:$BEH_GIT_DIR:/usr/bin:/bin"
printf 'prompt body for codex' > "$BEH_TMP/prompt.txt"
BEH_OUT="$(
  cd "$BEH_TMP/repo" && \
  PATH="$BEH_RUNTIME_PATH" \
  UBERDEV_TMPDIR="$BEH_TMP/tmp" \
  UBERDEV_AGENT_CHILD_OWNED=1 \
  UBERDEV_AGENT_INSTANCE_ID=review-code-a1 \
  AUTO_MODE=1 \
  CODEX_CAPTURE="$BEH_TMP/codex-capture.txt" \
  bash -c '
    . "$1"
    PATH=../bin
    unset _UBERDEV_PYTHON_EXE _UBERDEV_PYTHON_PREFIX
    _uberdev_dispatch_resolve_python || exit 1
    resolved_python="$_UBERDEV_PYTHON_EXE"
    PATH="$3"; export PATH
    run_python() {
      if [ -n "$_UBERDEV_PYTHON_PREFIX" ]; then
        command "$_UBERDEV_PYTHON_EXE" "$_UBERDEV_PYTHON_PREFIX" "$@"
      else
        command "$_UBERDEV_PYTHON_EXE" "$@"
      fi
    }
    python3() {
      run_python "$@"
    }
    export -f run_python python3
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    status_file="$UBERDEV_TMPDIR/solve-codex-status-42.json"
    i=0; running=""
    while [ "$i" -lt 200 ]; do
      running="$(cat "$status_file" 2>/dev/null)"
      [[ "$running" == *\"state\":\"running\"* ]] && break
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 400 ]; do
      terminal="$(cat "$status_file" 2>/dev/null)"
      case "$terminal" in
        *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;;
      esac
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ -n "$pid" ] && _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do
      sleep 0.025; i=$((i + 1))
    done
    printf "rc=%s\npid=%s\nresolved=%s\nrunning=%s\n" "$rc" "$pid" "$resolved_python" "$running"
    printf "status=%s\n" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)"
    printf "result=%s\n" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$BEH_TMP/prompt.txt" "$BEH_RUNTIME_PATH"
)"
beh_pid="$(printf '%s\n' "$BEH_OUT" | sed -n 's/^pid=//p')"
BEH_SLUG="$(UBERDEV_AGENT_INSTANCE_ID=review-code-a1 bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
BEH_PYTHON_EXPECTED="$(cd "$BEH_TMP/bin" && pwd -P)/py"
if [ -n "$beh_pid" ] \
    && printf '%s\n' "$BEH_OUT" | grep -Fq 'rc=0' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq "resolved=$BEH_PYTHON_EXPECTED" \
    && printf '%s\n' "$BEH_OUT" | grep -Fq 'running=' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq '"state":"running"' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq "\"pid\":\"$beh_pid\"" \
    && printf '%s\n' "$BEH_OUT" | grep -Fq 'status=' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq '"state":"completed"' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq '"exit_code":0' \
    && printf '%s\n' "$BEH_OUT" | grep -Fq 'result=codex final result' \
    && ! grep -Fq 'exported-python-bridge' "$BEH_TMP/codex-capture.txt" \
    && [ ! -e "$BEH_TMP/repo/.claude/worktrees/solve-issue-42-$BEH_SLUG" ] \
    && [ ! -e "$BEH_TMP/tmp/solve-codex-status-42.json.worktree-owner.json" ]; then
  pass_msg "codex py -3 wrapper publishes running/result/terminal receipts and cleans ownership without exporting its bridge"
else
  fail_msg "codex py -3 wrapper publishes running/result/terminal receipts and cleans ownership without exporting its bridge" "$BEH_OUT"
fi
if grep -Fq -- 'argv: [--ask-for-approval] [never] [exec]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '--sandbox] [workspace-write]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[-m] [gpt-5.6-sol]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[-c] [model_reasoning_effort="medium"]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[-c] [service_tier="default"]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[-c] [features.multi_agent=false]' "$BEH_TMP/codex-capture.txt" \
   && ! grep -Fq -- '[-c] [agents.max_depth=0]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[--json] [-o]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- '[-]' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- 'UBERDEV_TURBO=1' "$BEH_TMP/codex-capture.txt" \
   && grep -Fq -- 'stdin=prompt body for codex' "$BEH_TMP/codex-capture.txt"; then
  pass_msg "codex dispatch passes exact routed leaf argv and prompt on stdin"
else
  fail_msg "codex dispatch passes exact routed leaf argv and prompt on stdin" \
    "$(cat "$BEH_TMP/codex-capture.txt" 2>/dev/null)"
fi
if printf '%s\n' "$BEH_OUT" | grep -Eq '"pid":"[0-9]+"'; then
  pass_msg "codex dispatch status pid is numeric"
else
  fail_msg "codex dispatch status pid is numeric" "$BEH_OUT"
fi

EMPTY_INSTANCE=review-empty-result-a1
EMPTY_SLUG="$(UBERDEV_AGENT_INSTANCE_ID="$EMPTY_INSTANCE" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
EMPTY_OUT="$(
  cd "$BEH_TMP/repo" && \
  PATH="$BEH_RUNTIME_PATH" \
  UBERDEV_TMPDIR="$BEH_TMP/tmp" \
  UBERDEV_AGENT_CHILD_OWNED=1 \
  UBERDEV_AGENT_INSTANCE_ID="$EMPTY_INSTANCE" \
  CODEX_STUB_EMPTY=1 CODEX_STUB_SLEEP=0 \
  CODEX_CAPTURE="$BEH_TMP/codex-empty-capture.txt" \
  bash -c '
    . "$1"
    _uberdev_dispatch_codex 46 small "$2"
    rc=$?; pid="${DISPATCH_ID:-}"; status_file="$UBERDEV_TMPDIR/solve-codex-status-46.json"
    i=0
    while [ "$i" -lt 400 ]; do
      terminal="$(cat "$status_file" 2>/dev/null)"
      case "$terminal" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ -n "$pid" ] && _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
    printf "rc=%s\nstatus=%s\n" "$rc" "$(cat "$status_file" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$BEH_TMP/prompt.txt"
)"
if printf '%s\n' "$EMPTY_OUT" | grep -Fq 'rc=0' \
    && printf '%s\n' "$EMPTY_OUT" | grep -Fq '"state":"failed"' \
    && printf '%s\n' "$EMPTY_OUT" | grep -Fq '"exit_code":65' \
    && [ ! -s "$BEH_TMP/tmp/solve-codex-result-46.md" ] \
    && [ ! -e "$BEH_TMP/repo/.claude/worktrees/solve-issue-46-$EMPTY_SLUG" ] \
    && [ ! -e "$BEH_TMP/tmp/solve-codex-status-46.json.worktree-owner.json" ]; then
  pass_msg "successful Codex exit with an empty result fails terminally and cleans child ownership"
else
  fail_msg "successful Codex exit with an empty result fails terminally and cleans child ownership" "$EMPTY_OUT"
fi

COMBINED_INSTANCE=review-provider-and-cleanup-failure-a1
COMBINED_SLUG="$(UBERDEV_AGENT_INSTANCE_ID="$COMBINED_INSTANCE" bash -c '. "$1"; _uberdev_dispatch_instance_slug' _ "$DISPATCH_LIB")"
# Keep the provider immediate so the launcher must accept the canonical
# provider-plus-cleanup terminal receipt instead of relying on process timing.
COMBINED_OUT="$(
  cd "$BEH_TMP/repo" && \
  PATH="$BEH_RUNTIME_PATH" \
  UBERDEV_TMPDIR="$BEH_TMP/tmp" \
  UBERDEV_AGENT_CHILD_OWNED=1 \
  UBERDEV_AGENT_INSTANCE_ID="$COMBINED_INSTANCE" \
  CODEX_STUB_RC=42 CODEX_STUB_SLEEP=0 CODEX_STUB_DIRTY=1 \
  CODEX_CAPTURE="$BEH_TMP/codex-combined-capture.txt" \
  bash -c '
    . "$1"
    _uberdev_dispatch_codex 47 small "$2"
    rc=$?; pid="${DISPATCH_ID:-}"; status_file="$UBERDEV_TMPDIR/solve-codex-status-47.json"
    i=0
    while [ "$i" -lt 400 ]; do
      terminal="$(cat "$status_file" 2>/dev/null)"
      case "$terminal" in *\"state\":\"failed\"*) break ;; esac
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ -n "$pid" ] && _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
    printf "rc=%s\nstatus=%s\n" "$rc" "$(cat "$status_file" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$BEH_TMP/prompt.txt"
)"
COMBINED_STATUS="$BEH_TMP/tmp/solve-codex-status-47.json"
COMBINED_RESULT="$BEH_TMP/tmp/solve-codex-result-47.md"
COMBINED_LOG="$COMBINED_STATUS.log"
COMBINED_RECEIPT="$COMBINED_STATUS.worktree-owner.json"
COMBINED_WORKTREE="$BEH_TMP/repo/.claude/worktrees/solve-issue-47-$COMBINED_SLUG"
COMBINED_DISPATCH_RC="$(printf '%s\n' "$COMBINED_OUT" | sed -n 's/^rc=//p')"
COMBINED_ERRORS=''
case "$COMBINED_DISPATCH_RC" in
  0) ;;
  *) COMBINED_ERRORS="$COMBINED_ERRORS dispatch-rc-$COMBINED_DISPATCH_RC" ;;
esac
if ! COMBINED_VERIFY_OUT="$(python3 -I - "$COMBINED_STATUS" "$COMBINED_RESULT" "$COMBINED_LOG" \
    "$COMBINED_RECEIPT" "$COMBINED_WORKTREE" "$BEH_TMP/repo" "$COMBINED_SLUG" 2>&1 <<'PY'
import json,os,pathlib,sys
status_path,result_path,log_path,receipt_path,worktree_path,repo_path,slug=sys.argv[1:]
status=json.loads(pathlib.Path(status_path).read_text())
receipt=json.loads(pathlib.Path(receipt_path).read_text())
assert status['state']=='failed' and status['exit_code']==74 and status['provider_exit_code']==42
assert status['branch']==f'worktree-solve-issue-47-{slug}' and status['workspace_mode']=='isolated'
assert receipt['branch']==status['branch'] and receipt['relative']==f'.claude/worktrees/solve-issue-47-{slug}'
for actual,expected in (
    (status['worktree'],worktree_path),
    (status['log'],log_path),
    (status['result'],result_path),
    (receipt['worktree'],worktree_path),
    (receipt['repo'],repo_path),
):
    assert os.path.samefile(actual,expected),(actual,expected)
assert 'failed to clean child worktree' in pathlib.Path(log_path).read_text()
PY
)"; then
  COMBINED_ERRORS="$COMBINED_ERRORS verifier:$COMBINED_VERIFY_OUT"
fi
git -C "$BEH_TMP/repo" show-ref --verify --quiet \
  "refs/heads/worktree-solve-issue-47-$COMBINED_SLUG" \
  || COMBINED_ERRORS="$COMBINED_ERRORS branch"
if [ -z "$COMBINED_ERRORS" ]; then
  pass_msg "provider failure plus cleanup failure publishes cleanup rc with provider context and preserves evidence"
else
  fail_msg "provider failure plus cleanup failure remains durably distinguishable" \
    "$COMBINED_ERRORS $COMBINED_OUT"
fi
rm -rf "$BEH_TMP"

echo "== Codex inherit carrier omits model and effort pins =="
INHERIT_TMP="$(mktemp -d)"
mkdir -p "$INHERIT_TMP/bin" "$INHERIT_TMP/repo/.git" "$INHERIT_TMP/tmp"
chmod 700 "$INHERIT_TMP/tmp"
cat > "$INHERIT_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then printf '.git\n'; exit 0; fi
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then mkdir -p "$3"; exit 0; fi
if [ "$1" = "worktree" ] && [ "$2" = "remove" ] && [ "$3" = "--force" ]; then rm -rf "$4"; exit 0; fi
exit 1
SH
cat > "$INHERIT_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
{
  printf 'argv:'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\n'
} > "$CODEX_CAPTURE"
IFS= read -r body || true
printf 'stdin=%s\n' "$body" >> "$CODEX_CAPTURE"
exit 0
SH
chmod +x "$INHERIT_TMP/bin/git" "$INHERIT_TMP/bin/codex"
printf 'inherit prompt' > "$INHERIT_TMP/prompt.txt"
(
  cd "$INHERIT_TMP/repo"
  PATH="$INHERIT_TMP/bin:/usr/bin:/bin" UBERDEV_TMPDIR="$INHERIT_TMP/tmp" \
    UBERDEV_AGENT_ROUTING_MODE=inherit UBERDEV_AGENT_SERVICE_TIER=fast CODEX_CAPTURE="$INHERIT_TMP/capture.txt" \
    bash -c '. "$1"; _uberdev_dispatch_codex 43 small "$2"; pid=$DISPATCH_ID; i=0; while [ "$i" -lt 400 ]; do status="$(cat "$UBERDEV_TMPDIR/solve-codex-status-43.json" 2>/dev/null)"; case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac; sleep 0.025; i=$((i+1)); done; i=0; while _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i+1)); done' \
    _ "$DISPATCH_LIB" "$INHERIT_TMP/prompt.txt"
)
if grep -Fq -- '[-m]' "$INHERIT_TMP/capture.txt" \
   || grep -Fq -- 'model_reasoning_effort=' "$INHERIT_TMP/capture.txt"; then
  fail_msg "inherit Codex carrier omits model and reasoning pins" "$(cat "$INHERIT_TMP/capture.txt")"
elif grep -Fq -- '[-c] [service_tier="fast"]' "$INHERIT_TMP/capture.txt" \
   && grep -Fq -- 'stdin=inherit prompt' "$INHERIT_TMP/capture.txt"; then
  pass_msg "inherit Codex carrier omits model and reasoning pins"
else
  fail_msg "inherit Codex carrier preserves independent service tier and stdin" "$(cat "$INHERIT_TMP/capture.txt")"
fi

rm -f "$INHERIT_TMP/capture.txt"
(
  cd "$INHERIT_TMP/repo"
  PATH="$INHERIT_TMP/bin:/usr/bin:/bin" UBERDEV_TMPDIR="$INHERIT_TMP/tmp" \
    UBERDEV_AGENT_ROUTING_MODE=shadow UBERDEV_AGENT_EFFECTIVE_POLICY=inherit \
    UBERDEV_AGENT_ROUTE_MODEL=gpt-5.6-sol UBERDEV_AGENT_ROUTE_EFFORT=medium \
    UBERDEV_AGENT_SERVICE_TIER=fast CODEX_CAPTURE="$INHERIT_TMP/capture.txt" \
    bash -c '. "$1"; _uberdev_dispatch_codex 44 small "$2"; pid=$DISPATCH_ID; i=0; while [ "$i" -lt 400 ]; do status="$(cat "$UBERDEV_TMPDIR/solve-codex-status-44.json" 2>/dev/null)"; case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac; sleep 0.025; i=$((i+1)); done; i=0; while _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i+1)); done' \
    _ "$DISPATCH_LIB" "$INHERIT_TMP/prompt.txt"
)
if grep -Fq -- '[-m]' "$INHERIT_TMP/capture.txt" \
   || grep -Fq -- 'model_reasoning_effort=' "$INHERIT_TMP/capture.txt"; then
  fail_msg "shadow Codex carrier executes inherit without model and reasoning pins" "$(cat "$INHERIT_TMP/capture.txt")"
elif grep -Fq -- '[-c] [service_tier="fast"]' "$INHERIT_TMP/capture.txt"; then
  pass_msg "shadow Codex carrier executes inherit without model and reasoning pins"
else
  fail_msg "shadow Codex carrier preserves independent service tier" "$(cat "$INHERIT_TMP/capture.txt")"
fi
rm -rf "$INHERIT_TMP"

echo "== _uberdev_dispatch_codex failure and delayed-wrapper behavior =="
FAIL_TMP="$(mktemp -d)"
mkdir -p "$FAIL_TMP/bin" "$FAIL_TMP/repo/.git" "$FAIL_TMP/tmp"
chmod 700 "$FAIL_TMP/tmp"
cp "$BEH_TMP/bin/git" "$FAIL_TMP/bin/git" 2>/dev/null || cat > "$FAIL_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then printf '.git\n'; exit 0; fi
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  mkdir -p "$3"
  exit 0
fi
if [ "$1" = "worktree" ] && [ "$2" = "remove" ] && [ "$3" = "--force" ]; then
  rm -rf "$4"
  exit 0
fi
exit 1
SH
cat > "$FAIL_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'codex refused\n' > "$out"
exit 17
SH
chmod +x "$FAIL_TMP/bin/git" "$FAIL_TMP/bin/codex"
printf 'prompt body for failure' > "$FAIL_TMP/prompt.txt"
FAIL_OUT="$(
  cd "$FAIL_TMP/repo" && \
  PATH="$FAIL_TMP/bin:/usr/bin:/bin" \
  UBERDEV_TMPDIR="$FAIL_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    i=0
    while [ "$i" -lt 400 ]; do
      status="$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)"
      case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ -n "$pid" ] && _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
    printf "rc=%s\nstatus=%s\nresult=%s\n" "$rc" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$FAIL_TMP/prompt.txt"
)"
if printf '%s\n' "$FAIL_OUT" | grep -Fq 'rc=0' \
   && printf '%s\n' "$FAIL_OUT" | grep -Fq '"state":"failed"' \
   && printf '%s\n' "$FAIL_OUT" | grep -Fq '"exit_code":17' \
   && printf '%s\n' "$FAIL_OUT" | grep -Fq 'result=codex refused'; then
  pass_msg "codex dispatch records failed child status without treating dispatch as failed"
else
  fail_msg "codex dispatch records failed child status without treating dispatch as failed" "$FAIL_OUT"
fi
rm -rf "$FAIL_TMP"

echo "== _uberdev_dispatch_codex immediate terminal handoff =="
unix_ps_pattern='ps -o ''stat= -p'
if grep -Fq "$unix_ps_pattern" "$0"; then
  fail_msg "Codex fixtures avoid Unix-only process-table polling"
else
  pass_msg "Codex fixtures await canonical terminal evidence portably"
fi
IMMEDIATE_ACCEPT_BODY="$(extract_function_body _uberdev_dispatch_accept_immediate_terminal "$DISPATCH_LIB")"
WAIT_OWNED_BODY="$(extract_function_body _uberdev_dispatch_wait_owned_session "$DISPATCH_LIB")"
DISPATCH_PROCESS_IDENTITY_BODY="$(extract_function_body _uberdev_dispatch_process_identity "$DISPATCH_LIB")"
RESOLVED_IDENTITY_TMP="$(mktemp -d)"
ln -s "$(command -v basename)" "$RESOLVED_IDENTITY_TMP/basename"
ln -s "$(command -v dirname)" "$RESOLVED_IDENTITY_TMP/dirname"
RESOLVED_IDENTITY_OUT="$(
  PATH="$RESOLVED_IDENTITY_TMP" /bin/bash -c '
    . "$1"
    pid_file="$2/native.pid"
    _uberdev_dispatch_python -I -B -c '\''import os,pathlib,sys,time
if hasattr(os,"setsid"): os.setsid()
path=pathlib.Path(sys.argv[1]); path.write_text(str(os.getpid()),encoding="ascii")
time.sleep(30)'\'' "$pid_file" >/dev/null 2>&1 &
    launch_pid=$!
    i=0
    while [ ! -s "$pid_file" ] && [ "$i" -lt 200 ]; do
      _uberdev_dispatch_python -I -B -c '\''import time; time.sleep(0.025)'\''
      i=$((i + 1))
    done
    native_pid=""
    [ ! -s "$pid_file" ] || read -r native_pid <"$pid_file"
    identity="$(_uberdev_dispatch_process_identity "$native_pid" 2>/dev/null || true)"
    _uberdev_dispatch_python -I -B -c '\''import os,signal,sys; os.kill(int(sys.argv[1]),signal.SIGTERM)'\'' \
      "$native_pid" 2>/dev/null || true
    wait "$launch_pid" 2>/dev/null || true
    printf "%s\n%s\n" "$native_pid" "$identity"
  ' _ "$DISPATCH_LIB" "$RESOLVED_IDENTITY_TMP"
)"
RESOLVED_IDENTITY_PID="$(printf '%s\n' "$RESOLVED_IDENTITY_OUT" | sed -n '1p')"
RESOLVED_IDENTITY_VALUE="$(printf '%s\n' "$RESOLVED_IDENTITY_OUT" | sed -n '2p')"
if printf '%s\n' "$IMMEDIATE_ACCEPT_BODY" | grep -Fq 'process-identity' \
   && printf '%s\n' "$DISPATCH_PROCESS_IDENTITY_BODY" | grep -Fq '_uberdev_dispatch_python' \
   && printf '%s\n' "$WAIT_OWNED_BODY" | grep -Fq '_uberdev_dispatch_process_identity' \
   && [[ "$RESOLVED_IDENTITY_VALUE" == "$RESOLVED_IDENTITY_PID|$RESOLVED_IDENTITY_PID|$RESOLVED_IDENTITY_PID|"* ]] \
   && ! printf '%s\n%s\n' "$IMMEDIATE_ACCEPT_BODY" "$WAIT_OWNED_BODY" | grep -Fq 'os.kill'; then
  pass_msg "Windows dispatch liveness uses the non-signaling native identity probe"
else
  fail_msg "Windows dispatch liveness uses the non-signaling native identity probe" \
    "pid=$RESOLVED_IDENTITY_PID identity=$RESOLVED_IDENTITY_VALUE"
fi
rm -rf "$RESOLVED_IDENTITY_TMP"
IMMEDIATE_DUAL_TMP="$(mktemp -d)"
printf 'terminal result\n' > "$IMMEDIATE_DUAL_TMP/result.md"
immediate_dual_probe() {
  bash -c '. "$1"; _uberdev_dispatch_accept_immediate_terminal codex 99999999 "$2" "$3" >/dev/null' \
    _ "$DISPATCH_LIB" "$1" "$IMMEDIATE_DUAL_TMP/result.md"
}
immediate_dual_failures=''
for provider_rc in 0 42; do
  printf '{"backend":"codex","state":"failed","exit_code":74,"pid":"99999999","provider_exit_code":%s}\n' \
    "$provider_rc" > "$IMMEDIATE_DUAL_TMP/status.json"
  immediate_dual_probe "$IMMEDIATE_DUAL_TMP/status.json" \
    || immediate_dual_failures="$immediate_dual_failures rejected-$provider_rc"
done
printf '%s\n' '{"backend":"codex","state":"failed","exit_code":74,"pid":"99999999"}' \
  > "$IMMEDIATE_DUAL_TMP/status.json"
immediate_dual_probe "$IMMEDIATE_DUAL_TMP/status.json" \
  || immediate_dual_failures="$immediate_dual_failures rejected-legacy"
for invalid_status in \
  '{"backend":"codex","state":"failed","exit_code":74,"pid":"99999999","provider_exit_code":true}' \
  '{"backend":"codex","state":"failed","exit_code":73,"pid":"99999999","provider_exit_code":0}' \
  '{"backend":"codex","state":"completed","exit_code":0,"pid":"99999999","provider_exit_code":0}'
do
  printf '%s\n' "$invalid_status" > "$IMMEDIATE_DUAL_TMP/status.json"
  ! immediate_dual_probe "$IMMEDIATE_DUAL_TMP/status.json" \
    || immediate_dual_failures="$immediate_dual_failures accepted-invalid"
done
if [ -z "$immediate_dual_failures" ]; then
  pass_msg "immediate dual-failure receipts accept exact provider exit codes under the cleanup invariant"
else
  fail_msg "immediate dual-failure receipt schema is strict and complete" "$immediate_dual_failures"
fi
rm -rf "$IMMEDIATE_DUAL_TMP"
IMMEDIATE_TMP="$(mktemp -d)"
mkdir -p "$IMMEDIATE_TMP/bin" "$IMMEDIATE_TMP/repo/.git" "$IMMEDIATE_TMP/tmp"
chmod 700 "$IMMEDIATE_TMP/tmp"
cat > "$IMMEDIATE_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --git-common-dir ]; then printf '.git\n'; exit 0; fi
if [ "$1" = worktree ] && [ "$2" = add ]; then mkdir -p "$3"; exit 0; fi
if [ "$1" = worktree ] && [ "$2" = remove ] && [ "$3" = --force ]; then rm -rf "$4"; exit 0; fi
exit 1
SH
cat > "$IMMEDIATE_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
body="$(cat)"
printf 'immediate %s result\n' "$body" > "$out"
case "$body" in *failed*) exit 19 ;; *) exit 0 ;; esac
SH
chmod +x "$IMMEDIATE_TMP/bin/git" "$IMMEDIATE_TMP/bin/codex"
IMMEDIATE_OUT="$(
  cd "$IMMEDIATE_TMP/repo" &&
  PATH="$IMMEDIATE_TMP/bin:/usr/bin:/bin" UBERDEV_TMPDIR="$IMMEDIATE_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    IMMEDIATE_TERMINAL_EVIDENCE_BUDGET_S=30
    # Force the real launcher into the already-terminal branch without an
    # artificial sleep: wait reaps the exact wrapper before reporting that its
    # owned session can no longer be observed. Native Windows detached Bash
    # startup can be slow under runner load, so wait on a named bounded budget;
    # expiry is a diagnostic failure, never evidence that the session is owned.
    _uberdev_dispatch_wait_owned_session() {
      local status log_tail started=$SECONDS
      while [ $((SECONDS - started)) -lt "$IMMEDIATE_TERMINAL_EVIDENCE_BUDGET_S" ]; do
        status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
        case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) return 1 ;; esac
        sleep 0.025
      done
      log_tail="$(tail -n 20 "$UBERDEV_AGENT_STATUS_FILE.log" 2>/dev/null | tr "\n" ";")"
      printf "immediate terminal evidence timeout: budget_s=%s pid=%s status_file=%s status=%s log_tail=%s\n" \
        "$IMMEDIATE_TERMINAL_EVIDENCE_BUDGET_S" "${DISPATCH_ID:-none}" \
        "$UBERDEV_AGENT_STATUS_FILE" "${status:-missing}" "${log_tail:-empty}" >&2
      return 1
    }
    failures=0; details=""
    for outcome in completed failed completed failed completed failed; do
      issue=$((issue + 1))
      printf "%s\n" "$outcome" > "$UBERDEV_TMPDIR/prompt-$issue.txt"
      UBERDEV_AGENT_STATUS_FILE="$UBERDEV_TMPDIR/status-$issue.json"
      UBERDEV_AGENT_RESULT_FILE="$UBERDEV_TMPDIR/result-$issue.md"
      export UBERDEV_AGENT_STATUS_FILE UBERDEV_AGENT_RESULT_FILE
      _uberdev_dispatch_codex "$issue" small "$UBERDEV_TMPDIR/prompt-$issue.txt"
      rc=$?
      status="$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
      case "$outcome:$rc:$status" in
        completed:0:*\"state\":\"completed\"*)
          [[ "$status" == *\"exit_code\":0* ]] || failures=$((failures + 1)) ;;
        failed:0:*\"state\":\"failed\"*)
          [[ "$status" == *\"exit_code\":19* ]] || failures=$((failures + 1)) ;;
        *) failures=$((failures + 1)); details="$details outcome=$outcome rc=$rc pid=${DISPATCH_ID:-none} status=$status" ;;
      esac
      [ -n "${DISPATCH_ID:-}" ] || failures=$((failures + 1))
      [[ "$status" == *\"pid\":\"$DISPATCH_ID\"* ]] || failures=$((failures + 1))
    done
    terminal_pid="$DISPATCH_ID"
    ! _uberdev_dispatch_accept_immediate_terminal background "$terminal_pid" "$UBERDEV_AGENT_STATUS_FILE" "$UBERDEV_AGENT_RESULT_FILE" >/dev/null 2>&1 || failures=$((failures + 1))
    ! _uberdev_dispatch_accept_immediate_terminal codex "$((terminal_pid + 1))" "$UBERDEV_AGENT_STATUS_FILE" "$UBERDEV_AGENT_RESULT_FILE" >/dev/null 2>&1 || failures=$((failures + 1))
    terminal_status_file="$UBERDEV_AGENT_STATUS_FILE"
    IMMEDIATE_TERMINAL_EVIDENCE_BUDGET_S=0
    UBERDEV_AGENT_STATUS_FILE="$UBERDEV_TMPDIR/status-timeout-diagnostic.json"
    timeout_diagnostic="$(_uberdev_dispatch_wait_owned_session 2>&1)"
    timeout_rc=$?
    IMMEDIATE_TERMINAL_EVIDENCE_BUDGET_S=30
    UBERDEV_AGENT_STATUS_FILE="$terminal_status_file"
    case "$timeout_rc:$timeout_diagnostic" in
      1:*"budget_s=0"*"status=missing"*"log_tail=empty"*) ;;
      *) failures=$((failures + 1)); details="$details timeout-rc=$timeout_rc timeout-diagnostic=$timeout_diagnostic" ;;
    esac
    # Publish the native process PID explicitly. On Git Bash, `$!` is an MSYS
    # namespace handle while the production liveness probe uses native Windows
    # PIDs, so a plain `sleep &` would test the wrong namespace.
    live_pid_file="$UBERDEV_TMPDIR/live-native.pid"
    _uberdev_dispatch_python -I -c '\''import os,sys,time
with open(sys.argv[1],"w",encoding="ascii") as handle:
 handle.write(str(os.getpid())); handle.flush(); os.fsync(handle.fileno())
time.sleep(30)'\'' "$live_pid_file" &
    live_launch_pid=$!
    i=0; while [ ! -s "$live_pid_file" ] && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
    live_pid="$(cat "$live_pid_file" 2>/dev/null)"
    printf "{\"backend\":\"codex\",\"state\":\"completed\",\"exit_code\":0,\"pid\":\"%s\"}\n" "$live_pid" > "$UBERDEV_AGENT_STATUS_FILE"
    if _uberdev_dispatch_accept_immediate_terminal codex "$live_pid" "$UBERDEV_AGENT_STATUS_FILE" "$UBERDEV_AGENT_RESULT_FILE" >/dev/null 2>&1; then
      failures=$((failures + 1))
      details="$details known-live-native-pid-terminal-accepted pid=${live_pid:-missing} status=$(cat "$UBERDEV_AGENT_STATUS_FILE" 2>/dev/null)"
    fi
    _uberdev_dispatch_python -I -c '\''import os,signal,sys; os.kill(int(sys.argv[1]),signal.SIGTERM)'\'' "$live_pid" 2>/dev/null || true
    wait "$live_launch_pid" 2>/dev/null || true
    printf "failures=%s%s\n" "$failures" "$details"
  ' _ "$DISPATCH_LIB"
)"
case "$IMMEDIATE_OUT" in
  *'failures=0'*) pass_msg "codex preserves exact handles for repeated immediate completed and failed terminals" ;;
  *) fail_msg "codex preserves exact handles for repeated immediate completed and failed terminals" "$IMMEDIATE_OUT" ;;
esac
rm -rf "$IMMEDIATE_TMP"

RACE_TMP="$(mktemp -d)"
mkdir -p "$RACE_TMP/bin" "$RACE_TMP/repo/.git" "$RACE_TMP/tmp"
chmod 700 "$RACE_TMP/tmp"
cat > "$RACE_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then printf '.git\n'; exit 0; fi
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  mkdir -p "$3"
  exit 0
fi
if [ "$1" = "worktree" ] && [ "$2" = "remove" ] && [ "$3" = "--force" ]; then
  rm -rf "$4"
  exit 0
fi
exit 1
SH
cat > "$RACE_TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'fast failed codex result\n' > "$out"
exit 23
SH
cat > "$RACE_TMP/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -gt 0 ]; then
  exec /bin/cat "$@"
fi
tmp="$(mktemp)"
/bin/cat > "$tmp"
if grep -q '"state":"running"' "$tmp"; then
  sleep 1
fi
/bin/cat "$tmp"
rm -f "$tmp"
SH
chmod +x "$RACE_TMP/bin/git" "$RACE_TMP/bin/codex" "$RACE_TMP/bin/cat"
printf 'prompt body fast fail' > "$RACE_TMP/prompt.txt"
RACE_OUT="$(
  cd "$RACE_TMP/repo" && \
  PATH="$RACE_TMP/bin:/usr/bin:/bin" \
  UBERDEV_TMPDIR="$RACE_TMP/tmp" \
  /bin/bash -c '
    . "$1"
    _uberdev_dispatch_codex 42 small "$2"
    rc=$?
    pid="${DISPATCH_ID:-}"
    i=0
    while [ "$i" -lt 400 ]; do
      status="$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)"
      case "$status" in *\"state\":\"completed\"*|*\"state\":\"failed\"*) break ;; esac
      sleep 0.025; i=$((i + 1))
    done
    i=0
    while [ -n "$pid" ] && _uberdev_dispatch_wait_owned_session "$pid" && [ "$i" -lt 200 ]; do sleep 0.025; i=$((i + 1)); done
    printf "rc=%s\npid=%s\nstatus=%s\nresult=%s\n" "$rc" "$pid" "$(cat "$UBERDEV_TMPDIR/solve-codex-status-42.json" 2>/dev/null)" "$(cat "$UBERDEV_TMPDIR/solve-codex-result-42.md" 2>/dev/null)"
  ' _ "$DISPATCH_LIB" "$RACE_TMP/prompt.txt"
)"
if printf '%s\n' "$RACE_OUT" | grep -Fq 'rc=0' \
   && printf '%s\n' "$RACE_OUT" | grep -Fq '"state":"failed"' \
   && printf '%s\n' "$RACE_OUT" | grep -Fq '"exit_code":23' \
   && printf '%s\n' "$RACE_OUT" | grep -Fq 'result=fast failed codex result'; then
  pass_msg "codex dispatch never overwrites terminal child status with stale running status"
else
  fail_msg "codex dispatch never overwrites terminal child status with stale running status" "$RACE_OUT"
fi
rm -rf "$RACE_TMP"

echo "== Codex plugin package is self-contained =="
if [ -r "$PLUGIN_ROOT/lib/dispatch.sh" ] && [ -r "$PLUGIN_ROOT/lib/solve-launcher.sh" ] && [ -x "$PLUGIN_ROOT/hooks/session-start" ]; then
  echo "  PASS  Codex plugin bundles runtime lib and executable session-start hook"; PASS=$((PASS + 1))
else
  echo "  FAIL  Codex plugin missing runtime lib or executable session-start hook"; FAIL=$((FAIL + 1))
fi
if grep -q '\${PLUGIN_ROOT}/hooks/session-start' "$PLUGIN_HOOKS"; then
  echo "  PASS  Codex hook points at plugin-local session-start"; PASS=$((PASS + 1))
else
  echo "  FAIL  Codex hook does not point at plugin-local session-start"; FAIL=$((FAIL + 1))
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
