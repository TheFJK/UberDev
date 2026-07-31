#!/usr/bin/env bash
# Tests for issue #209 — every tests/*.test.sh that sources
# _lib_assert_structural.sh must do so with a fail-loud guard, so a missing
# or unreadable helper aborts with rc=2 instead of producing a vacuous-green
# run.
#
# Why: the suite uses the repo's deliberate `set -u; set -o pipefail` +
# manual PASS/FAIL counter convention (NOT `set -e`; see install.test.sh
# header for the rationale). Without the guard, an absent helper makes
# `source` print to stderr, the structural `assert_in_section` /
# `assert_subagent_type` / `assert_count` calls fail with rc=127, but the
# test can still `exit 0` if its locally-defined `assert_grep` checks all
# pass — silent green.
#
# The fix is mechanical and repo-wide: every source line must end with
#   || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }
# matching the existing FATAL-preflight convention these files already use
# for `.md` inputs (cf. install.test.sh:26-29, aliases.test.sh:49-54).
#
# This test is a structural drift guard: it auto-discovers any current or
# future tests/*.test.sh that sources the helper and asserts the guard is
# present on the same line. Adding a new test that sources the helper
# without the guard fails this check at CI time.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
HELPER="$TESTS_DIR/_lib_assert_structural.sh"

if [ ! -r "$HELPER" ]; then
  echo "FATAL: _lib_assert_structural.sh missing/unreadable: $HELPER" >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "FATAL: tests/ directory missing: $TESTS_DIR" >&2
  exit 2
fi

PASS=0
FAIL=0

# Source-site detection: matches both the `. <path>` (POSIX dot) and
# `source <path>` (bash) forms, with any leading whitespace. Stops at the
# `.sh` suffix so the literal guard tail (`|| { ... exit 2; }`) is captured
# on the same line as part of the surrounding string match.
SOURCE_RE='^[[:space:]]*(\.|source)[[:space:]]+[^|&;]*_lib_assert_structural\.sh'

# The literal guard tail every source site must carry. The exact FATAL
# message is part of the contract — operators grep for it in CI logs to
# pinpoint a missing-helper failure mode, so don't accept paraphrases.
GUARD_FRAGMENT='|| { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }'

echo "== A1: every tests/*.test.sh sourcing _lib_assert_structural.sh has the fail-loud guard =="

# Walk every tests/*.test.sh via the shell glob (handles spaces in the repo
# path — e.g. "/Volumes/FJK SSD/" — without any NUL-delimited gymnastics
# that depend on a GNU vs BSD sort/grep -z split). For each file, every
# line matching the source pattern is asserted to carry the guard tail.
SAW_ANY_SOURCING_FILE=0
for f in "$TESTS_DIR"/*.test.sh; do
  # Skip files that don't source the helper at all (most of the suite).
  grep -qE -e "$SOURCE_RE" "$f" 2>/dev/null || continue
  SAW_ANY_SOURCING_FILE=1
  # Per-line scan — a file may source the helper more than once across
  # test fixtures (rare today, but the guard must be present on every
  # source line, not just one).
  while IFS=: read -r lineno line; do
    if grep -qF -- "$GUARD_FRAGMENT" <<<"$line"; then
      echo "  PASS  $(basename "$f"):$lineno carries the fail-loud guard"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $(basename "$f"):$lineno sources _lib_assert_structural.sh without the fail-loud guard"
      echo "        file:   $f"
      echo "        line:   $line"
      echo "        expect: ... || { echo \"FATAL: _lib_assert_structural.sh missing/unreadable\" >&2; exit 2; }"
      FAIL=$((FAIL + 1))
    fi
  done < <(grep -nE -e "$SOURCE_RE" "$f")
done

if [ "$SAW_ANY_SOURCING_FILE" -eq 0 ]; then
  echo "  FAIL  no tests/*.test.sh files source _lib_assert_structural.sh — this drift guard would not detect a regression"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A2: CI shell harnesses have no undeclared ripgrep runtime dependency =="
RG_HITS="$(python3 -I - "$TESTS_DIR" "$0" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1]); current=pathlib.Path(sys.argv[2]).resolve()
command="r"+"g"
pattern=re.compile(r"(^|[;&|()\\s])"+command+r"(?=\\s|$)")
hits=[]
for path in sorted(root.glob("*.test.sh")):
    if path.resolve()==current: continue
    for number,line in enumerate(path.read_text(encoding="utf-8").splitlines(),1):
        if line.lstrip().startswith("#"): continue
        if pattern.search(line): hits.append(f"{path.name}:{number}:{line.strip()}")
print("\\n".join(hits))
PY
)"
if [ -n "$RG_HITS" ]; then
  echo "  FAIL  CI harnesses invoke ripgrep without installing it"
  printf '        %s\n' "$RG_HITS"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  CI harnesses use repository-portable text tools"
  PASS=$((PASS + 1))
fi

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
